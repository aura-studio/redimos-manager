import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/table_lifecycle.dart';
import 'package:redimos_manager/src/ui_fields.dart';
import 'package:redimos_manager/src/ui_primitives.dart';
import 'package:redimos_manager/src/ui_status.dart';
import 'package:redimos_manager/src/ui_theme.dart';

import 'fake_core.dart';
import 'viewport_assertions.dart';

class _LifecycleCore extends FakeNativeCore {
  Map<String, dynamic> inspectResponse = const {
    'ok': true,
    'allowed': true,
    'endpoint': 'http://localhost:8000',
    'loopback': true,
    'itemCount': 12,
    'ageDays': 1,
    'dependents': <Map<String, dynamic>>[],
  };
  Map<String, dynamic> precheckResponse = const {
    'ok': true,
    'allowed': true,
    'table': 'orders',
    'endpoint': 'http://localhost:8000',
    'loopback': true,
    'itemCount': 12,
    'ageDays': 1,
    'version': 'v2',
    'dependents': <Map<String, dynamic>>[],
  };

  final inspectCalls = <(RedimosConfig, String)>[];
  final precheckCalls = <String>[];
  final purgeCalls = <(RedimosConfig, String)>[];
  final deleteCalls = <(RedimosConfig, String)>[];
  final recreateCalls = <String>[];

  Completer<Map<String, dynamic>>? purgeResult;
  Completer<Map<String, dynamic>>? deleteResult;
  Completer<Map<String, dynamic>>? recreateResult;

  @override
  Future<Map<String, dynamic>> tableInspect(
    RedimosConfig config,
    String table,
  ) async {
    inspectCalls.add((config, table));
    return inspectResponse;
  }

  @override
  Map<String, dynamic> tablePrecheck(String configId) {
    precheckCalls.add(configId);
    return precheckResponse;
  }

  @override
  Future<Map<String, dynamic>> tablePurge(
    RedimosConfig config,
    String table,
  ) {
    purgeCalls.add((config, table));
    return (purgeResult ??= Completer<Map<String, dynamic>>()).future;
  }

  @override
  Future<Map<String, dynamic>> tableDelete(
    RedimosConfig config,
    String table,
  ) {
    deleteCalls.add((config, table));
    return (deleteResult ??= Completer<Map<String, dynamic>>()).future;
  }

  @override
  Future<Map<String, dynamic>> tableRecreate(String configId) {
    recreateCalls.add(configId);
    return (recreateResult ??= Completer<Map<String, dynamic>>()).future;
  }
}

class _LifecycleEvents {
  final busy = <bool>[];
  final messages = <({String message, bool error})>[];
  int changed = 0;

  void toast(String message, {bool error = false}) {
    messages.add((message: message, error: error));
  }
}

RedimosConfig _config() => RedimosConfig(
      id: 'config-v2',
      name: 'Local V2',
      version: 'v2',
      table: 'orders',
      endpoint: 'http://localhost:8000',
      region: 'local',
    );

TableLifecycle _lifecycle(
  _LifecycleCore core,
  RedimosConfig config,
  _LifecycleEvents events,
) =>
    TableLifecycle(
      core: core,
      config: config,
      toast: events.toast,
      onChanged: () => events.changed++,
      setBusy: events.busy.add,
    );

Future<BuildContext> _pumpHost(
  WidgetTester tester,
  Brightness brightness,
) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(brightness),
      home: const Scaffold(
        body: SizedBox.expand(key: ValueKey('lifecycle-host')),
      ),
    ),
  );
  return tester.element(find.byKey(const ValueKey('lifecycle-host')));
}

CodexButton _confirmButton(WidgetTester tester) => tester.widget<CodexButton>(
      find.byKey(const ValueKey('table-lifecycle-confirm-action')),
    );

Future<void> _finishDialogOperation(
  WidgetTester tester,
  Future<void> operation,
) async {
  await tester.pump();
  await operation;
  await tester.pump();
}

void main() {
  setUp(() => appLang.value = AppLang.en);

  test('authoring config and format helpers preserve domain selection', () {
    final usedBy = <Map<String, dynamic>>[
      {'id': 'v1-config', 'version': 'v1'},
      {'id': 'v2-config', 'version': 'v2'},
    ];

    expect(
      TableLifecycle.authoringConfig(usedBy, 'v1', 'v2-config'),
      'v2-config',
      reason: 'the viewed config has priority over a version match',
    );
    expect(
      TableLifecycle.authoringConfig(usedBy, 'v2', 'missing'),
      'v2-config',
    );
    expect(
        TableLifecycle.authoringConfig(usedBy, 'raw', 'missing'), 'v1-config');
    expect(TableLifecycle.authoringConfig(const [], 'v2', 'missing'), isNull);
    expect(TableLifecycle.fmtInt(1248000), '1,248,000');
    expect(TableLifecycle.fmtBytes(1536), '2 KB');
    expect(TableLifecycle.fmtBytes(3 * 1024 * 1024), '3.0 MB');
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'destroy confirmation keeps friction and shared primitives in ${brightness.name}',
      (tester) async {
        final core = _LifecycleCore()
          ..inspectResponse = const {
            'ok': true,
            'allowed': true,
            'endpoint': 'https://shared.example.test',
            'loopback': false,
            'itemCount': 150000,
            'ageDays': 45,
            'dependents': [
              {'name': 'orders-api', 'running': true},
              {'name': 'offline-worker', 'running': false},
            ],
          };
        final config = _config();
        final events = _LifecycleEvents();
        final lifecycle = _lifecycle(core, config, events);
        final context = await _pumpHost(tester, brightness);

        final operation = lifecycle.delete(context, 'orders');
        await tester.pump();

        expect(
          find.byKey(const ValueKey('table-lifecycle-destroy-confirm')),
          findsOneWidget,
        );
        expect(find.byType(CodexTextField), findsOneWidget);
        expect(find.byType(CodexStatusDot), findsOneWidget);
        expect(
          find.byKey(const ValueKey('table-lifecycle-shared-warning')),
          findsOneWidget,
        );
        expect(
            find.byKey(const ValueKey('table-lifecycle-ack')), findsOneWidget);
        final dialog =
            find.byKey(const ValueKey('table-lifecycle-destroy-confirm'));
        final confirmAction =
            find.byKey(const ValueKey('table-lifecycle-confirm-action'));
        expectInsideTestViewport(
          tester,
          dialog,
          reason: 'the maximum-friction destroy dialog must fit 1280x800',
        );
        expectInsideTestViewport(tester, confirmAction);
        expect(_confirmButton(tester).variant, CodexButtonVariant.danger);
        expect(_confirmButton(tester).onPressed, isNull);
        expect(core.deleteCalls, isEmpty);

        await tester.enterText(find.byType(TextField), 'orders');
        await tester.tap(find.byKey(const ValueKey('table-lifecycle-ack')));
        await tester.pump();
        expect(_confirmButton(tester).onPressed, isNotNull);
        expectHitTestable(
          tester,
          confirmAction,
          reason: 'the enabled destructive action must remain reachable',
        );

        await tester.tap(find.text(tr('ep.cancel')));
        await _finishDialogOperation(tester, operation);

        expect(core.inspectCalls, [(config, 'orders')]);
        expect(core.deleteCalls, isEmpty,
            reason: 'cancelling confirmation must not invoke a write');
        expect(events.busy, [true, false]);
        expect(lifecycle.busy, isFalse);
        expect(events.changed, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('purge forwards exact config and reports progress and success',
      (tester) async {
    final core = _LifecycleCore();
    final config = _config();
    final events = _LifecycleEvents();
    final lifecycle = _lifecycle(core, config, events);
    final context = await _pumpHost(tester, Brightness.dark);

    final operation = lifecycle.purge(context, 'orders');
    await tester.pump();
    expect(_confirmButton(tester).onPressed, isNotNull);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('table-lifecycle-confirm-action')),
        matching: find.text(tr('ep.purge')),
      ),
    );
    await tester.pump();

    expect(core.purgeCalls, [(config, 'orders')]);
    expect(
      find.byKey(const ValueKey('table-lifecycle-progress')),
      findsOneWidget,
    );
    expect(lifecycle.busy, isTrue);

    core.purgeResult!.complete({'ok': true, 'deleted': 7});
    await _finishDialogOperation(tester, operation);

    expect(events.changed, 1);
    expect(events.messages, hasLength(1));
    expect(events.messages.single.error, isFalse);
    expect(events.messages.single.message, contains('7'));
    expect(events.messages.single.message, contains('orders'));
    expect(events.busy, [true, false]);
    expect(lifecycle.busy, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recreate requires name and acknowledgement before exact write',
      (tester) async {
    final core = _LifecycleCore()
      ..precheckResponse = const {
        'ok': true,
        'allowed': true,
        'table': 'orders',
        'endpoint': 'https://shared.example.test',
        'loopback': false,
        'itemCount': 250000,
        'ageDays': 60,
        'version': 'v2',
        'dependents': [
          {'name': 'orders-api', 'running': true},
        ],
      };
    final events = _LifecycleEvents();
    final lifecycle = _lifecycle(core, _config(), events);
    final context = await _pumpHost(tester, Brightness.light);

    final operation = lifecycle.recreate(
      context,
      'authoring-v2',
      provision: false,
    );
    await tester.pump();

    expect(core.precheckCalls, ['authoring-v2']);
    expect(_confirmButton(tester).variant, CodexButtonVariant.danger);
    expect(_confirmButton(tester).onPressed, isNull);
    expect(core.recreateCalls, isEmpty);

    await tester.enterText(find.byType(TextField), 'orders');
    await tester.tap(find.byKey(const ValueKey('table-lifecycle-ack')));
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('table-lifecycle-confirm-action')),
        matching: find.text(tr('ep.recreate')),
      ),
    );
    await tester.pump();

    expect(core.recreateCalls, ['authoring-v2']);
    expect(
      find.byKey(const ValueKey('table-lifecycle-progress')),
      findsOneWidget,
    );

    core.recreateResult!.complete({'ok': true, 'warning': 'restart delayed'});
    await _finishDialogOperation(tester, operation);

    expect(events.changed, 1);
    expect(events.messages.single.message, contains('restart delayed'));
    expect(events.busy, [true, false]);
    expect(lifecycle.busy, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('provision uses primary action and releases busy after failure',
      (tester) async {
    final core = _LifecycleCore()
      ..precheckResponse = const {
        'ok': true,
        'allowed': true,
        'table': 'orders',
        'endpoint': 'http://localhost:8000',
        'loopback': true,
        'itemCount': -1,
        'ageDays': -1,
        'version': 'v2',
        'dependents': <Map<String, dynamic>>[],
      };
    final events = _LifecycleEvents();
    final lifecycle = _lifecycle(core, _config(), events);
    final context = await _pumpHost(tester, Brightness.dark);

    final operation = lifecycle.recreate(
      context,
      'authoring-v2',
      provision: true,
    );
    await tester.pump();

    expect(_confirmButton(tester).variant, CodexButtonVariant.primary);
    expect(_confirmButton(tester).onPressed, isNotNull);
    expect(find.byType(CodexTextField), findsNothing);
    expect(find.byKey(const ValueKey('table-lifecycle-ack')), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('table-lifecycle-confirm-action')),
        matching: find.text(tr('ep.provision')),
      ),
    );
    await tester.pump();
    core.recreateResult!.completeError(StateError('native recreate failed'));
    await _finishDialogOperation(tester, operation);

    expect(core.recreateCalls, ['authoring-v2']);
    expect(events.changed, 0);
    expect(events.messages, hasLength(1));
    expect(events.messages.single.error, isTrue);
    expect(events.messages.single.message, contains('native recreate failed'));
    expect(events.busy, [true, false]);
    expect(lifecycle.busy, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('denied precheck reports error without dialog or write',
      (tester) async {
    final core = _LifecycleCore()
      ..precheckResponse = const {
        'ok': true,
        'allowed': false,
        'reason': 'read-only endpoint',
      };
    final events = _LifecycleEvents();
    final lifecycle = _lifecycle(core, _config(), events);
    final context = await _pumpHost(tester, Brightness.light);

    await lifecycle.recreate(context, 'authoring-v2', provision: false);
    await tester.pump();

    expect(core.precheckCalls, ['authoring-v2']);
    expect(core.recreateCalls, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(events.messages.single.message, 'read-only endpoint');
    expect(events.messages.single.error, isTrue);
    expect(events.busy, isEmpty);
    expect(events.changed, 0);
    expect(lifecycle.busy, isFalse);
    expect(tester.takeException(), isNull);
  });
}
