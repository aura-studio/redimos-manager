import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/browser_page.dart';
import 'package:redimos_manager/src/cmd_console.dart';
import 'package:redimos_manager/src/configure_page.dart';
import 'package:redimos_manager/src/endpoint_browser.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/playground_page.dart';
import 'package:redimos_manager/src/table_page.dart';

import 'fake_core.dart';
import 'fake_resp_server.dart';
import 'screen_fixtures.dart' as fx;

class _EndpointStateCore extends FakeNativeCore {
  final loads = <Completer<Map<String, dynamic>>>[];

  @override
  Future<Map<String, dynamic>> epListTables(RedimosConfig config) {
    final load = Completer<Map<String, dynamic>>();
    loads.add(load);
    return load.future;
  }
}

class _TableStateCore extends FakeNativeCore {
  bool failMetadata = false;

  @override
  TableMeta tableMeta(RedimosConfig config) => failMetadata
      ? TableMeta(ok: false, error: 'metadata unavailable')
      : TableMeta(
          ok: true,
          table: config.table,
          targets: [
            TableTarget(
              name: config.table,
              kind: 'table',
              pk: TableKeyRef(name: 'pk', type: 'S'),
            ),
          ],
        );

  @override
  TablePage tablePage(Map<String, dynamic> request) => TablePage(
        ok: true,
        cols: const ['pk'],
        rows: const [],
      );
}

Widget _app(Widget child) => MaterialApp(
      theme: fx.goldenTheme(Brightness.dark),
      home: Scaffold(body: child),
    );

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(_app(child));
}

Rect _rect(WidgetTester tester, String key) =>
    tester.getRect(find.byKey(ValueKey(key)));

Rect _stateBodyRect(WidgetTester tester, String shellKey) => tester.getRect(
      find
          .descendant(
            of: find.byKey(ValueKey(shellKey)),
            matching: find.byType(ClipRect),
          )
          .first,
    );

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  int attempts = 60,
}) async {
  for (var i = 0; i < attempts; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for expected widget');
}

void main() {
  setUp(() {
    appLang.value = AppLang.en;
  });

  testWidgets('Browser keeps its viewport bounds while connecting and loading',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = FakeRespServer();
    await tester.runAsync(server.start);
    final config = fx.fixtureConfigAt(server.port);

    await _pump(
      tester,
      BrowserPageView(config: config, running: false, core: fx.fakeCore),
    );
    final stopped = _stateBodyRect(tester, 'browser-page-state');

    await _pump(
      tester,
      BrowserPageView(config: config, running: true, core: fx.fakeCore),
    );
    final loading = _stateBodyRect(tester, 'browser-page-state');
    expect(loading, stopped);

    await _waitFor(tester, find.text('cache'));
    final populated = _stateBodyRect(tester, 'browser-page-state');
    expect(populated, stopped);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(server.close);
  });

  testWidgets('Console toolbar, viewport, and input keep fixed bounds',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = FakeRespServer();
    await tester.runAsync(server.start);

    List<Rect> geometry() => [
          _rect(tester, 'cmd-console-toolbar-anchor'),
          _stateBodyRect(tester, 'cmd-console-state'),
          _rect(tester, 'cmd-console-input-anchor'),
        ];

    await _pump(
      tester,
      CmdConsole(host: '127.0.0.1', port: server.port, running: false),
    );
    final stopped = geometry();

    await _pump(
      tester,
      CmdConsole(
        host: '127.0.0.1',
        port: server.port,
        running: false,
        statusReason: 'startup failed',
      ),
    );
    expect(geometry(), stopped);

    await _pump(
      tester,
      CmdConsole(host: '127.0.0.1', port: server.port, running: true),
    );
    expect(geometry(), stopped);

    await _waitFor(tester, find.text('redimos-cli'));
    expect(geometry(), stopped);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(server.close);
  });

  testWidgets('Playground keeps toolbar and body anchors when stopped',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final config = fx.fixtureConfig();

    await _pump(
      tester,
      PlaygroundView(
        core: fx.fakeCore,
        config: config,
        kind: 'redis',
        running: false,
      ),
    );
    final stopped = [
      _rect(tester, 'playground-toolbar-anchor'),
      _stateBodyRect(tester, 'playground-state'),
    ];

    await _pump(
      tester,
      PlaygroundView(
        core: fx.fakeCore,
        config: config,
        kind: 'redis',
        running: true,
      ),
    );
    final content = [
      _rect(tester, 'playground-toolbar-anchor'),
      _stateBodyRect(tester, 'playground-state'),
    ];
    expect(content, stopped);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Configure switch animates paint inside fixed bounds',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      ConfigEditor(
        config: fx.fixtureConfig(),
        onSave: (_) async {},
        onDelete: (_) async {},
      ),
    );

    final switchFinder = find.byType(AnimatedContainer).first;
    final beforeRect = tester.getRect(switchFinder);
    final beforeDecoration = tester
        .widget<AnimatedContainer>(switchFinder)
        .decoration! as BoxDecoration;
    expect(beforeRect.size, const Size(34, 19));

    await tester.tap(switchFinder);
    await tester.pump();
    expect(tester.getRect(switchFinder), beforeRect);

    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getRect(switchFinder), beforeRect);

    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getRect(switchFinder), beforeRect);
    final afterDecoration = tester
        .widget<AnimatedContainer>(switchFinder)
        .decoration! as BoxDecoration;
    expect(afterDecoration.color, isNot(beforeDecoration.color));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Endpoint tables anchors survive all list states',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = _EndpointStateCore();
    const endpoint = fx.fixtureEndpoint;

    await _pump(
      tester,
      EndpointTablesView(
        core: core,
        config: endpoint.toStorageConfig(),
        endpoint: endpoint,
      ),
    );

    List<Rect> geometry() => [
          _rect(tester, 'endpoint-tables-header'),
          _stateBodyRect(tester, 'endpoint-tables-state'),
          _rect(tester, 'endpoint-tables-footer'),
        ];

    final loading = geometry();
    core.loads.last.complete({
      'ok': true,
      'awsMode': false,
      'tables': const [
        {'name': 'users', 'missing': false, 'itemCount': 2},
      ],
    });
    await tester.pump();
    expect(geometry(), loading);

    await tester.tap(find.byIcon(Icons.refresh).first);
    await tester.pump();
    core.loads.last.complete({
      'ok': true,
      'awsMode': false,
      'tables': const <Map<String, dynamic>>[],
    });
    await tester.pump();
    expect(geometry(), loading);

    await tester.tap(find.byIcon(Icons.refresh).first);
    await tester.pump();
    core.loads.last.complete({'ok': false, 'error': 'list failed'});
    await tester.pump();
    expect(geometry(), loading);
    expect(find.text('list failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Table Explorer keeps header and viewport across metadata states',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = _TableStateCore();
    final first = fx.fixtureConfig();

    await _pump(tester, TablePageView(core: core, config: first));
    final loading = [
      _rect(tester, 'table-page-header'),
      _stateBodyRect(tester, 'table-page-state'),
    ];

    await tester.pump(const Duration(milliseconds: 16));
    final content = [
      _rect(tester, 'table-page-header'),
      _stateBodyRect(tester, 'table-page-state'),
    ];
    expect(content, loading);

    core.failMetadata = true;
    final second = first.copy()..id = 'c2';
    await _pump(tester, TablePageView(core: core, config: second));
    expect([
      _rect(tester, 'table-page-header'),
      _stateBodyRect(tester, 'table-page-state'),
    ], loading);

    await tester.pump(const Duration(milliseconds: 16));
    expect([
      _rect(tester, 'table-page-header'),
      _stateBodyRect(tester, 'table-page-state'),
    ], loading);
    expect(find.text('metadata unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
