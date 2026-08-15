// Stage 13.5: create → edit → start → stop → delete smoke test.
//
// Drives the FULL Service CRUD lifecycle through the Configure editor with a
// stateful scripted core (an in-memory store that keeps runtime state across
// saves, like the real registry). Runs twice: once with the default
// preserve-data delete, once with the explicit double-confirmed cleanup path.
// After delete, selection returns deterministically to the pick placeholder.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/service_configure.dart';
import 'package:redimos_manager/src/ui_theme.dart';

import 'fake_core.dart';

typedef _Entry = ({ServiceConfig config, String state});

class _SmokeCore extends FakeNativeCore {
  final Map<String, _Entry> store = {};
  final startCalls = <String>[];
  final stopCalls = <String>[];
  final deleteCalls = <(String, bool)>[];
  int _seq = 0;

  ServiceInfo _info(String id) {
    final entry = store[id]!;
    return ServiceInfo.fromJson({
      'config': entry.config.toJson(),
      'runtime': {
        'state': entry.state,
        'ready': entry.state == 'running',
        'healthy': entry.state == 'running',
      },
    });
  }

  @override
  ServiceInfo serviceSave(ServiceConfig c) {
    final id = c.id.isEmpty ? 'svc-${++_seq}' : c.id;
    final state = store[id]?.state ?? 'stopped';
    store[id] = (
      config: ServiceConfig(
        id: id,
        name: c.name,
        engine: c.engine,
        port: c.port,
        storage: c.storage,
        engineOptions: c.engineOptions,
        desiredRunning: c.desiredRunning,
      ),
      state: state, // runtime survives config edits, like the real registry
    );
    return _info(id);
  }

  @override
  ServiceInfo serviceStart(String id) {
    startCalls.add(id);
    store[id] = (config: store[id]!.config, state: 'running');
    return _info(id);
  }

  @override
  ServiceInfo serviceStop(String id) {
    stopCalls.add(id);
    store[id] = (config: store[id]!.config, state: 'stopped');
    return _info(id);
  }

  @override
  ServiceDeleteResult serviceDelete(String id, {required bool deleteData}) {
    deleteCalls.add((id, deleteData));
    store.remove(id);
    return ServiceDeleteResult(id: id, dataCleaned: deleteData);
  }
}

Finder _input(String field) =>
    find.byKey(ValueKey('service-config-$field-input'));

void main() {
  setUp(() => appLang.value = AppLang.en);
  tearDown(() => appLang.value = AppLang.en);

  for (final withCleanup in [false, true]) {
    final pathName = withCleanup ? 'explicit cleanup' : 'preserved data';

    testWidgets('create → edit → start → stop → delete ($pathName)',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final core = _SmokeCore();
      ServiceInfo? selected;
      final deletedIds = <String>[];

      // Mirrors main.dart: the detail pane shows the pick placeholder when
      // nothing is selected, and the editor otherwise. Every callback
      // re-renders from the core's truth (the "refresh" step).
      Future<void> pump() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.dark),
            themeAnimationDuration: Duration.zero,
            home: Scaffold(
              body: selected == null
                  ? Center(
                      child: Text(
                        tr('service.pick'),
                        key: const ValueKey('service-pick-placeholder'),
                      ),
                    )
                  : ServiceConfigEditor(
                      key: ValueKey('service-configure-${selected!.id}'),
                      service: selected!,
                      peers: const [],
                      core: core,
                      onSaved: (saved) => selected = saved,
                      onDeleted: (id) {
                        deletedIds.add(id);
                        selected = null; // deterministic post-delete state
                      },
                    ),
            ),
          ),
        );
        await tester.pump();
      }

      // --- CREATE (same defaults as HomePage._newService) -------------------
      selected = core.serviceSave(ServiceConfig(
        name: 'new-service',
        engine: ServiceEngine.java,
        port: 8000,
      ));
      await pump();
      expect(find.byKey(const ValueKey('service-configure-svc-1')),
          findsOneWidget);
      expect(
        tester.widget<TextField>(find.descendant(
          of: _input('name'),
          matching: find.byType(TextField),
        )).controller!.text,
        'new-service',
      );

      // --- EDIT (rename + re-port, save round-trips through the core) -------
      await tester.enterText(_input('name'), 'smoke-ddb');
      await tester.enterText(_input('port'), '8010');
      await tester.tap(find.byKey(const ValueKey('service-config-save')));
      await tester.pump();
      await pump(); // refresh from the core
      expect(core.store['svc-1']!.config.name, 'smoke-ddb');
      expect(core.store['svc-1']!.config.port, 8010);
      expect(core.store['svc-1']!.state, 'stopped');

      // --- START (live runtime locks the identity fields) -------------------
      selected = core.serviceStart('svc-1');
      await pump();
      expect(core.startCalls, ['svc-1']);
      expect(find.byKey(const ValueKey('service-config-locked-hint')),
          findsOneWidget);

      // --- STOP (lock releases; the form still names the same service) ------
      selected = core.serviceStop('svc-1');
      await pump();
      expect(core.stopCalls, ['svc-1']);
      expect(find.byKey(const ValueKey('service-config-locked-hint')),
          findsNothing);

      // --- DELETE (the two confirmation paths) -------------------------------
      await tester.tap(find.byKey(const ValueKey('service-config-delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('service-delete-dialog')),
          findsOneWidget);
      if (withCleanup) {
        await tester.tap(
          find.byKey(const ValueKey('service-delete-data-check')),
        );
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('service-delete-confirm')));
      await tester.pumpAndSettle();
      if (withCleanup) {
        expect(find.byKey(
                const ValueKey('service-delete-destructive-dialog')),
            findsOneWidget);
        await tester.tap(find.byKey(
            const ValueKey('service-delete-destructive-confirm')));
        await tester.pumpAndSettle();
        expect(core.deleteCalls, [('svc-1', true)]);
      } else {
        expect(core.deleteCalls, [('svc-1', false)]);
      }

      // --- Post-delete: deterministic selection back to the placeholder -----
      expect(deletedIds, ['svc-1']);
      expect(core.store, isEmpty);
      await pump();
      expect(find.byKey(const ValueKey('service-pick-placeholder')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
