import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/endpoint_browser.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/logs_page.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/playground_page.dart';

import 'fake_core.dart';
import 'screen_fixtures.dart' as fx;

class _LifecycleCore extends FakeNativeCore {
  final Map<String, List<String>> logsByConfig = {};
  final List<Completer<Map<String, dynamic>>> playgroundRuns = [];
  final List<Completer<Map<String, dynamic>>> endpointLoads = [];

  @override
  List<String> logs(String id) => logsByConfig[id] ?? const [];

  @override
  Future<Map<String, dynamic>> epListTables(RedimosConfig config) {
    final completer = Completer<Map<String, dynamic>>();
    endpointLoads.add(completer);
    return completer.future;
  }

  @override
  Future<Map<String, dynamic>> playgroundRun({
    required String kind,
    required String lang,
    required String script,
    int port = 0,
    String auth = '',
    RedimosConfig? config,
    int timeoutMs = 5000,
  }) {
    final completer = Completer<Map<String, dynamic>>();
    playgroundRuns.add(completer);
    return completer.future;
  }
}

RedimosConfig _config(String id, int port) => RedimosConfig(
      id: id,
      name: 'instance-$id',
      port: port,
      table: 'table-$id',
      region: 'us-east-1',
    );

void main() {
  setUp(() => appLang.value = AppLang.en);

  testWidgets('Logs resets entity-specific lines and filter on config change',
      (tester) async {
    final core = _LifecycleCore()
      ..logsByConfig.addAll({
        'c1': const [
          '08:00:00 INFO first-info',
          '08:00:01 ERROR first-error',
        ],
        'c2': const ['09:00:00 WARN second-warning'],
      });

    await fx.pumpScreen(
      tester,
      dark: true,
      child: LogsPage(core: core, configId: 'c1'),
    );
    await tester.pump();

    expect(find.text('first-info'), findsOneWidget);
    expect(find.text('first-error'), findsOneWidget);

    await tester.tap(find.text('ERROR').first);
    await tester.pump();
    expect(find.text('first-info'), findsNothing);
    expect(find.text('first-error'), findsOneWidget);

    await fx.pumpScreen(
      tester,
      dark: true,
      child: LogsPage(core: core, configId: 'c2'),
    );
    await tester.pump();

    expect(find.text('first-error'), findsNothing);
    expect(find.text('second-warning'), findsOneWidget,
        reason: 'the old ERROR filter must not hide the new entity WARN line');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Endpoint Browser rejects an old endpoint table-list response',
      (tester) async {
    final core = _LifecycleCore();
    const firstEndpoint = DdbEndpoint(
      id: 'e1',
      name: 'endpoint-one',
      kind: 'local',
      endpoint: 'http://localhost:8001',
    );
    const secondEndpoint = DdbEndpoint(
      id: 'e2',
      name: 'endpoint-two',
      kind: 'local',
      endpoint: 'http://localhost:8002',
    );

    await fx.pumpScreen(
      tester,
      dark: true,
      child: EndpointTablesView(
        core: core,
        config: firstEndpoint.toStorageConfig(),
        endpoint: firstEndpoint,
      ),
    );
    expect(core.endpointLoads, hasLength(1));

    await fx.pumpScreen(
      tester,
      dark: true,
      child: EndpointTablesView(
        core: core,
        config: secondEndpoint.toStorageConfig(),
        endpoint: secondEndpoint,
      ),
    );
    expect(core.endpointLoads, hasLength(2));

    core.endpointLoads.last.complete({
      'ok': true,
      'awsMode': false,
      'tables': const [
        {'name': 'new-endpoint-table', 'missing': false, 'itemCount': 2},
      ],
    });
    await tester.pump();
    expect(find.text('new-endpoint-table'), findsOneWidget);

    core.endpointLoads.first.complete({
      'ok': true,
      'awsMode': false,
      'tables': const [
        {'name': 'old-endpoint-table', 'missing': false, 'itemCount': 1},
      ],
    });
    await tester.pump();

    expect(find.text('old-endpoint-table'), findsNothing);
    expect(find.text('new-endpoint-table'), findsOneWidget);
  });

  testWidgets('Playground rejects an old entity run and resets unsaved script',
      (tester) async {
    final core = _LifecycleCore();
    final first = _config('c1', 6379);
    final second = _config('c2', 6380);

    await fx.pumpScreen(
      tester,
      dark: true,
      child: PlaygroundView(
        core: core,
        config: first,
        kind: 'redis',
        running: true,
      ),
    );

    await tester.enterText(find.byType(TextField), 'return "first";');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Run'));
    await tester.pump();
    expect(core.playgroundRuns, hasLength(1));

    await fx.pumpScreen(
      tester,
      dark: true,
      child: PlaygroundView(
        core: core,
        config: second,
        kind: 'redis',
        running: true,
      ),
    );
    await tester.pump();

    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);

    core.playgroundRuns.first.complete({
      'ok': true,
      'logs': const ['old-entity-result'],
      'result': 'old',
      'elapsedMs': 4,
    });
    await tester.pump();
    expect(find.text('old-entity-result'), findsNothing);

    await tester.enterText(find.byType(TextField), 'return "second";');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Run'));
    await tester.pump();
    expect(core.playgroundRuns, hasLength(2));

    core.playgroundRuns.last.complete({
      'ok': true,
      'logs': const ['new-entity-result'],
      'result': 'new',
      'elapsedMs': 5,
    });
    await tester.pump();

    expect(find.text('old-entity-result'), findsNothing);
    expect(find.text('new-entity-result'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
