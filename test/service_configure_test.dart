// Stage 13.4: Service Configure CRUD widget / interaction / boundary tests.
//
// Covers: engine-conditional fields (path vs volume, heap option),
// client-side validation mirroring the Core rules, Core error-code mapping
// onto fields vs the form banner, the runtime identity lock (2.7), user-input
// preservation across polling refreshes (13.2), revert, and the full delete
// matrix (default preserve, cancel, double destructive confirmation, partial
// delete, manual cleanup, failure). Scripted core — no dylib needed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/service_configure.dart';
import 'package:redimos_manager/src/ui_fields.dart';
import 'package:redimos_manager/src/ui_theme.dart';

import 'fake_core.dart';

// ---------------------------------------------------------------------------
// Scripted core
// ---------------------------------------------------------------------------

class _ScriptedCore extends FakeNativeCore {
  final savedConfigs = <ServiceConfig>[];
  final deleteCalls = <(String, bool)>[];
  ServiceApiException? saveError;
  ServiceApiException? deleteError;
  ServiceDeleteResult Function(String id, bool deleteData)? onDelete;

  @override
  ServiceInfo serviceSave(ServiceConfig service) {
    savedConfigs.add(service);
    final err = saveError;
    if (err != null) throw err;
    return ServiceInfo.fromJson({
      'config': service.toJson(),
      'runtime': {'state': 'stopped', 'ready': false, 'healthy': false},
    });
  }

  @override
  ServiceDeleteResult serviceDelete(String id, {required bool deleteData}) {
    deleteCalls.add((id, deleteData));
    final err = deleteError;
    if (err != null) throw err;
    final scripted = onDelete;
    if (scripted != null) return scripted(id, deleteData);
    return ServiceDeleteResult(id: id, dataCleaned: deleteData);
  }
}

// ---------------------------------------------------------------------------
// Fixtures + harness
// ---------------------------------------------------------------------------

ServiceInfo _svc({
  String id = 'svc-a',
  String name = 'local-ddb',
  String engine = 'java',
  int port = 8000,
  String state = 'stopped',
  String storage = 'memory',
  String path = '',
  String volume = '',
}) =>
    ServiceInfo.fromJson({
      'config': {
        'id': id,
        'name': name,
        'engine': engine,
        'port': port,
        'storage': {'mode': storage, 'path': path, 'volume': volume},
      },
      'runtime': {
        'state': state,
        'ready': state == 'running',
        'healthy': state == 'running',
      },
    });

ServiceInfo _peer({String id = 'svc-b', String name = 'stage-ddb', int port = 8001}) =>
    _svc(id: id, name: name, port: port);

Future<void> _pump(
  WidgetTester tester, {
  required ServiceInfo service,
  List<ServiceInfo> peers = const [],
  required _ScriptedCore core,
  ValueChanged<ServiceInfo>? onSaved,
  ValueChanged<String>? onDeleted,
  Size size = const Size(1280, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.dark),
      themeAnimationDuration: Duration.zero,
      home: Scaffold(
        body: ServiceConfigEditor(
          key: ValueKey('service-configure-${service.id}'),
          service: service,
          peers: peers,
          core: core,
          onSaved: onSaved ?? (_) {},
          onDeleted: onDeleted ?? (_) {},
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder _input(String field) => find.byKey(ValueKey('service-config-$field-input'));

Future<void> _selectIn<T>(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.byType(CodexSelectField<T>));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(CodexSelectField<T>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last); // menu item (field echo is first)
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => appLang.value = AppLang.en);
  tearDown(() => appLang.value = AppLang.en);

  // ---- 13.1 form shape + engine-conditional fields --------------------------

  testWidgets('engine switch swaps location and option fields', (tester) async {
    final core = _ScriptedCore();
    await _pump(tester, service: _svc(storage: 'custom', path: '/tmp/ddb'), core: core);

    // Java: heap option + custom storage shows the PATH field.
    expect(find.byKey(const ValueKey('service-config-heap')), findsOneWidget);
    expect(find.byKey(const ValueKey('service-config-path')), findsOneWidget);
    expect(find.byKey(const ValueKey('service-config-volume')), findsNothing);

    // LocalStack: no engine option fields (SERVICES is pinned to dynamodb by
    // the core); LocalStack owns its storage, so the storage select
    // disappears behind an explanation row (2.4).
    await _selectIn<ServiceEngine>(tester, tr('svc.engine.localstack'));
    expect(find.byKey(const ValueKey('service-config-heap')), findsNothing);
    expect(find.byKey(const ValueKey('service-config-path')), findsNothing);
    expect(find.byKey(const ValueKey('service-config-volume')), findsNothing);
    expect(find.byKey(const ValueKey('service-config-storage')), findsNothing);
    expect(find.byKey(const ValueKey('service-config-localstack-storage')),
        findsOneWidget);

    // Docker: no engine option fields; volume returns for custom storage.
    await _selectIn<ServiceEngine>(tester, tr('svc.engine.docker'));
    expect(find.byKey(const ValueKey('service-config-heap')), findsNothing);
    expect(find.byKey(const ValueKey('service-config-volume')), findsOneWidget);
    expect(find.byKey(const ValueKey('service-config-localstack-storage')),
        findsNothing);

    // In-memory storage hides the location field entirely.
    await _selectIn<ServiceStorageMode>(tester, tr('svc.storage.memory'));
    expect(find.byKey(const ValueKey('service-config-path')), findsNothing);
    expect(find.byKey(const ValueKey('service-config-volume')), findsNothing);
    expect(core.savedConfigs, isEmpty);
    expect(tester.takeException(), isNull);
  });

  // ---- v1.2 storage field matrix (4.9): 3 engines × storage modes ----------

  testWidgets('storage fields follow the engine × mode matrix', (tester) async {
    final core = _ScriptedCore();
    await _pump(tester, service: _svc(), core: core);

    // Java × In-memory: no location field at all.
    expect(find.byKey(const ValueKey('service-config-path')), findsNothing);
    expect(find.byKey(const ValueKey('service-config-volume')), findsNothing);

    // Java × Persisted: the PATH field only.
    await _selectIn<ServiceStorageMode>(tester, tr('svc.storage.persisted'));
    expect(find.byKey(const ValueKey('service-config-path')), findsOneWidget);
    expect(find.byKey(const ValueKey('service-config-volume')), findsNothing);

    // Docker × Persisted: the VOLUME field only, prefilled for an existing
    // ID — the reuse-or-create name (2.2).
    await _selectIn<ServiceEngine>(tester, tr('svc.engine.docker'));
    expect(find.byKey(const ValueKey('service-config-path')), findsNothing);
    expect(find.byKey(const ValueKey('service-config-volume')), findsOneWidget);
    final volumeCtl = tester.widget<TextField>(
      find.descendant(of: _input('volume'), matching: find.byType(TextField)),
    ).controller!;
    expect(volumeCtl.text, 'redimos-service-svc-a-data');

    // Docker × In-memory: location fields vanish again.
    await _selectIn<ServiceStorageMode>(tester, tr('svc.storage.memory'));
    expect(find.byKey(const ValueKey('service-config-volume')), findsNothing);

    // LocalStack: no storage select at all — just the managed explanation,
    // and never a path/volume field (2.4).
    await _selectIn<ServiceEngine>(tester, tr('svc.engine.localstack'));
    expect(find.byKey(const ValueKey('service-config-storage')), findsNothing);
    expect(find.byKey(const ValueKey('service-config-path')), findsNothing);
    expect(find.byKey(const ValueKey('service-config-volume')), findsNothing);
    expect(find.byKey(const ValueKey('service-config-localstack-storage')),
        findsOneWidget);
    expect(core.savedConfigs, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('port 0 names the engine default port under the field',
      (tester) async {
    final core = _ScriptedCore();
    await _pump(tester, service: _svc(port: 0), core: core);

    final hint = find.byKey(const ValueKey('service-config-port-default'));
    expect(hint, findsOneWidget);
    final hintText = find.descendant(of: hint, matching: find.byType(Text));
    expect(tester.widget<Text>(hintText).data, contains('8000'));

    // LocalStack's default port is 4566 (1.3).
    await _selectIn<ServiceEngine>(tester, tr('svc.engine.localstack'));
    expect(tester.widget<Text>(hintText).data, contains('4566'));
    expect(tester.takeException(), isNull);
  });

  // ---- 13.2 client-side validation -----------------------------------------

  testWidgets('client validation blocks invalid saves with field errors',
      (tester) async {
    final core = _ScriptedCore();
    await _pump(tester, service: _svc(), peers: [_peer(port: 8001)], core: core);

    // Blank name.
    await tester.enterText(_input('name'), '   ');
    await tester.tap(find.byKey(const ValueKey('service-config-save')));
    await tester.pump();
    expect(find.byKey(const ValueKey('service-config-name-error')), findsOneWidget);
    expect(find.text(tr('svc.nameRequired')), findsOneWidget);
    expect(core.savedConfigs, isEmpty);

    // Case-folded duplicate of a peer name.
    await tester.enterText(_input('name'), 'STAGE-DDB');
    await tester.tap(find.byKey(const ValueKey('service-config-save')));
    await tester.pump();
    expect(find.text(tr('svc.nameTaken')), findsOneWidget);
    expect(core.savedConfigs, isEmpty);

    // Invalid port values.
    await tester.enterText(_input('name'), 'local-ddb');
    await tester.enterText(_input('port'), 'not-a-port');
    await tester.tap(find.byKey(const ValueKey('service-config-save')));
    await tester.pump();
    expect(find.byKey(const ValueKey('service-config-port-error')), findsOneWidget);
    await tester.enterText(_input('port'), '70000');
    await tester.tap(find.byKey(const ValueKey('service-config-save')));
    await tester.pump();
    expect(find.text(tr('svc.portInvalid')), findsOneWidget);
    expect(core.savedConfigs, isEmpty);

    // Non-zero port colliding with a peer.
    await tester.enterText(_input('port'), '8001');
    await tester.tap(find.byKey(const ValueKey('service-config-save')));
    await tester.pump();
    expect(find.byKey(const ValueKey('service-config-port-error')), findsOneWidget);
    expect(core.savedConfigs, isEmpty);

    // Persisted storage without the engine's required location.
    await tester.enterText(_input('port'), '8000');
    await _selectIn<ServiceStorageMode>(tester, tr('svc.storage.persisted'));
    await tester.enterText(_input('path'), '');
    await tester.tap(find.byKey(const ValueKey('service-config-save')));
    await tester.pump();
    expect(find.byKey(const ValueKey('service-config-path-error')), findsOneWidget);
    expect(core.savedConfigs, isEmpty);

    // Container engines require a volume instead.
    await _selectIn<ServiceEngine>(tester, tr('svc.engine.docker'));
    await tester.enterText(_input('volume'), '');
    await tester.tap(find.byKey(const ValueKey('service-config-save')));
    await tester.pump();
    expect(find.byKey(const ValueKey('service-config-volume-error')), findsOneWidget);
    expect(core.savedConfigs, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('core error codes map onto the responsible field or banner',
      (tester) async {
    final core = _ScriptedCore();
    await _pump(tester, service: _svc(), core: core);

    core.saveError = ServiceApiException('duplicate_name', 'name in use');
    await tester.enterText(_input('name'), 'renamed');
    await tester.tap(find.byKey(const ValueKey('service-config-save')));
    await tester.pump();
    expect(find.byKey(const ValueKey('service-config-name-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('service-config-form-error')), findsNothing);

    core.saveError = ServiceApiException('port_conflict', 'port busy');
    await tester.tap(find.byKey(const ValueKey('service-config-save')));
    await tester.pump();
    expect(find.byKey(const ValueKey('service-config-port-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('service-config-form-error')), findsNothing);

    core.saveError = ServiceApiException('engine_unavailable', 'no docker');
    await tester.tap(find.byKey(const ValueKey('service-config-save')));
    await tester.pump();
    final banner = find.byKey(const ValueKey('service-config-form-error'));
    expect(banner, findsOneWidget);
    expect(tester.widget<Text>(banner).data, contains('engine_unavailable'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('valid save normalizes the payload and fires onSaved',
      (tester) async {
    final core = _ScriptedCore();
    final saved = <ServiceInfo>[];
    await _pump(
      tester,
      service: _svc(storage: 'custom', path: '/tmp/ddb'),
      core: core,
      onSaved: saved.add,
    );

    await tester.enterText(_input('name'), ' renamed-ddb ');
    await tester.enterText(_input('heap'), '512m');
    await tester.tap(find.byKey(const ValueKey('service-config-save')));
    await tester.pump();

    expect(core.savedConfigs, hasLength(1));
    final cfg = core.savedConfigs.single;
    expect(cfg.id, 'svc-a'); // identity preserved — never re-created (2.1)
    expect(cfg.name, 'renamed-ddb'); // trimmed
    expect(cfg.engine, ServiceEngine.java);
    expect(cfg.port, 8000);
    expect(cfg.storage.mode, ServiceStorageMode.custom);
    expect(cfg.storage.path, '/tmp/ddb');
    expect(cfg.storage.volume, ''); // engine-irrelevant location stays clear
    expect(cfg.engineOptions['heap'], '512m');
    expect(saved, hasLength(1));
    expect(find.text(tr('svc.saved')), findsOneWidget); // snackbar
    expect(tester.takeException(), isNull);
  });

  // ---- 13.2 runtime identity lock + input preservation ----------------------

  testWidgets('running service locks identity fields but keeps name editable',
      (tester) async {
    final core = _ScriptedCore();
    await _pump(tester, service: _svc(state: 'running'), core: core);

    expect(find.byKey(const ValueKey('service-config-locked-hint')), findsOneWidget);
    // Disabled selects are flagged enabled=false (CodexSelectField grammar).
    expect(
      tester.widget<CodexSelectField<ServiceEngine>>(
        find.byType(CodexSelectField<ServiceEngine>),
      ).enabled,
      isFalse,
    );
    expect(
      tester.widget<CodexSelectField<ServiceStorageMode>>(
        find.byType(CodexSelectField<ServiceStorageMode>),
      ).enabled,
      isFalse,
    );
    expect(tester.widget<TextField>(
      find.descendant(of: _input('port'), matching: find.byType(TextField)),
    ).enabled, isFalse);
    expect(tester.widget<TextField>(
      find.descendant(of: _input('name'), matching: find.byType(TextField)),
    ).enabled, isTrue);

    // The lock never blocks a rename.
    await tester.enterText(_input('name'), 'renamed-while-running');
    await tester.tap(find.byKey(const ValueKey('service-config-save')));
    await tester.pump();
    expect(core.savedConfigs.single.name, 'renamed-while-running');
    expect(core.savedConfigs.single.port, 8000); // untouched identity
    expect(tester.takeException(), isNull);
  });

  testWidgets('polling refresh of the same service preserves typed input',
      (tester) async {
    final core = _ScriptedCore();
    await _pump(tester, service: _svc(), core: core);
    await tester.enterText(_input('name'), 'half-typed');
    await tester.enterText(_input('port'), '9999');

    // A new runtime snapshot arrives for the SAME id (polling) — nothing the
    // user typed may be lost.
    await _pump(tester, service: _svc(state: 'running'), core: core);
    final nameCtl = tester.widget<TextField>(
      find.descendant(of: _input('name'), matching: find.byType(TextField)),
    ).controller!;
    expect(nameCtl.text, 'half-typed');
    final portCtl = tester.widget<TextField>(
      find.descendant(of: _input('port'), matching: find.byType(TextField)),
    ).controller!;
    expect(portCtl.text, '9999');

    // Revert restores the persisted config and clears errors.
    await tester.tap(find.byKey(const ValueKey('service-config-revert')));
    await tester.pump();
    expect(nameCtl.text, 'local-ddb');
    expect(tester.takeException(), isNull);
  });

  // ---- 13.3 safe delete ------------------------------------------------------

  testWidgets('delete defaults to preserving data with one confirmation',
      (tester) async {
    final core = _ScriptedCore();
    final deleted = <String>[];
    await _pump(tester, service: _svc(), core: core, onDeleted: deleted.add);

    await tester.tap(find.byKey(const ValueKey('service-config-delete')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('service-delete-dialog')), findsOneWidget);
    // Identity + data location are named before any destructive action.
    expect(find.textContaining('local-ddb'), findsWidgets);
    expect(find.textContaining(tr('svc.location.memory')), findsOneWidget);
    final check = tester.widget<Checkbox>(
      find.byKey(const ValueKey('service-delete-data-check')),
    );
    expect(check.value, isFalse); // default: preserve (10.2)

    await tester.tap(find.byKey(const ValueKey('service-delete-confirm')));
    await tester.pumpAndSettle();
    expect(core.deleteCalls, [('svc-a', false)]);
    expect(deleted, ['svc-a']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling the delete dialog keeps the service untouched',
      (tester) async {
    final core = _ScriptedCore();
    final deleted = <String>[];
    await _pump(tester, service: _svc(), core: core, onDeleted: deleted.add);

    await tester.tap(find.byKey(const ValueKey('service-config-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr('home.cancel')));
    await tester.pumpAndSettle();
    expect(core.deleteCalls, isEmpty);
    expect(deleted, isEmpty);
    expect(find.byKey(const ValueKey('service-config-name')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('data cleanup requires the second destructive confirmation',
      (tester) async {
    final core = _ScriptedCore();
    final deleted = <String>[];
    await _pump(tester, service: _svc(), core: core, onDeleted: deleted.add);

    await tester.tap(find.byKey(const ValueKey('service-config-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('service-delete-data-check')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('service-delete-confirm')));
    await tester.pumpAndSettle();

    // The second, explicitly destructive dialog intercepts (10.3).
    expect(find.byKey(const ValueKey('service-delete-destructive-dialog')),
        findsOneWidget);
    expect(core.deleteCalls, isEmpty);

    // Cancelling it aborts the whole delete.
    await tester.tap(find.text(tr('home.cancel')));
    await tester.pumpAndSettle();
    expect(core.deleteCalls, isEmpty);
    expect(deleted, isEmpty);

    // Re-running and confirming both dialogs deletes WITH cleanup.
    await tester.tap(find.byKey(const ValueKey('service-config-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('service-delete-data-check')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('service-delete-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('service-delete-destructive-confirm')),
    );
    await tester.pumpAndSettle();
    expect(core.deleteCalls, [('svc-a', true)]);
    expect(deleted, ['svc-a']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('partial delete keeps the config and surfaces a retry error',
      (tester) async {
    final core = _ScriptedCore();
    final deleted = <String>[];
    core.onDelete = (id, _) => ServiceDeleteResult(id: id, partial: true);
    await _pump(tester, service: _svc(), core: core, onDeleted: deleted.add);

    await tester.tap(find.byKey(const ValueKey('service-config-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('service-delete-confirm')));
    await tester.pumpAndSettle();

    expect(deleted, isEmpty); // never silently completed (10.7)
    final banner = find.byKey(const ValueKey('service-config-form-error'));
    expect(banner, findsOneWidget);
    expect(tester.widget<Text>(banner).data, tr('svc.partialDelete'));
    // The editor is still mounted — the delete is retryable in place.
    expect(find.byKey(const ValueKey('service-config-save')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual cleanup results surface the cleanup instructions',
      (tester) async {
    final core = _ScriptedCore();
    final deleted = <String>[];
    core.onDelete = (id, _) => ServiceDeleteResult(
          id: id,
          manualCleanup: const ['docker volume rm ddb-svc-a'],
        );
    await _pump(tester, service: _svc(), core: core, onDeleted: deleted.add);

    await tester.tap(find.byKey(const ValueKey('service-config-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('service-delete-data-check')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('service-delete-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('service-delete-destructive-confirm')),
    );
    await tester.pumpAndSettle();

    expect(deleted, ['svc-a']);
    expect(find.byKey(const ValueKey('service-delete-cleanup-dialog')),
        findsOneWidget);
    expect(find.textContaining('docker volume rm ddb-svc-a'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('delete failure shows an error and keeps everything',
      (tester) async {
    final core = _ScriptedCore();
    final deleted = <String>[];
    core.deleteError = ServiceApiException('stop_failed', 'still running');
    await _pump(tester, service: _svc(), core: core, onDeleted: deleted.add);

    await tester.tap(find.byKey(const ValueKey('service-config-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('service-delete-confirm')));
    await tester.pumpAndSettle();

    expect(deleted, isEmpty);
    final banner = find.byKey(const ValueKey('service-config-form-error'));
    expect(banner, findsOneWidget);
    expect(tester.widget<Text>(banner).data, contains('stop_failed'));
    expect(find.byKey(const ValueKey('service-config-name')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
