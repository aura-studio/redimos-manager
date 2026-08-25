import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/main.dart' show MonitorView;
import 'package:redimos_manager/src/browser_page.dart';
import 'package:redimos_manager/src/cmd_console.dart';
import 'package:redimos_manager/src/code_editor.dart';
import 'package:redimos_manager/src/configure_page.dart';
import 'package:redimos_manager/src/endpoint_detail.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/logs_page.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/playground_page.dart';

import 'fake_core.dart';
import 'fake_resp_server.dart';
import 'screen_fixtures.dart' as fx;

class _RetentionCore extends FakeNativeCore {
  int endpointListCalls = 0;

  @override
  List<String> logs(String id) => List<String>.generate(
        160,
        (i) => i.isEven
            ? '08:00:${(i % 60).toString().padLeft(2, '0')} ERROR error-$i'
            : '08:00:${(i % 60).toString().padLeft(2, '0')} INFO info-$i',
      );

  @override
  Future<Map<String, dynamic>> epListTables(RedimosConfig config) async {
    endpointListCalls++;
    return super.epListTables(config);
  }
}

class _EmptyTablesCore extends FakeNativeCore {
  @override
  Future<Map<String, dynamic>> epListTables(RedimosConfig config) async =>
      {'ok': true, 'tables': <Map<String, dynamic>>[]};
}

class _TabHarness extends StatefulWidget {
  final List<Widget> children;

  const _TabHarness({super.key, required this.children});

  @override
  State<_TabHarness> createState() => _TabHarnessState();
}

class _TabHarnessState extends State<_TabHarness>
    with SingleTickerProviderStateMixin {
  late final TabController controller = TabController(
    length: widget.children.length,
    vsync: this,
  );

  void select(int index) => controller.animateTo(index);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TabBarView(
        controller: controller,
        physics: const NeverScrollableScrollPhysics(),
        children: widget.children,
      );
}

class _EndpointHarness extends StatefulWidget {
  final FakeNativeCore core;
  final DdbEndpoint endpoint;

  const _EndpointHarness({
    super.key,
    required this.core,
    required this.endpoint,
  });

  @override
  State<_EndpointHarness> createState() => _EndpointHarnessState();
}

class _EndpointHarnessState extends State<_EndpointHarness> {
  int index = 0;
  String? table;

  void select(int value) => setState(() => index = value);

  @override
  Widget build(BuildContext context) => EndpointDetailView(
        core: widget.core,
        endpoint: widget.endpoint,
        screenIndex: index,
        selectedTable: table,
        onOpenTable: (name) => setState(() {
          table = name;
          index = 1;
        }),
      );
}

Future<void> _pumpHarness(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1280, 560),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: fx.goldenTheme(Brightness.dark),
    home: Scaffold(body: child),
  ));
}

Future<void> _selectTab(
  WidgetTester tester,
  GlobalKey<_TabHarnessState> key,
  int index,
) async {
  key.currentState!.select(index);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

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

TextField _textFieldWithText(WidgetTester tester, String text) => tester
    .widgetList<TextField>(find.byType(TextField))
    .firstWhere((field) => field.controller?.text == text);

void main() {
  setUp(() => appLang.value = AppLang.en);

  testWidgets(
      'Monitor, Logs, Playground, and Configure retain local state across tabs',
      (tester) async {
    final core = _RetentionCore();
    final key = GlobalKey<_TabHarnessState>();
    final config = fx.fixtureConfig();

    await _pumpHarness(
      tester,
      _TabHarness(
        key: key,
        children: [
          MonitorView(
            status: fx.fixtureStatus(),
            cpuHist: fx.mockSparkCpu,
            memHist: fx.mockSparkMem,
            opsHist: fx.mockSparkOps,
            embedded: true,
            instanceName: config.name,
          ),
          LogsPage(core: core, configId: config.id),
          PlaygroundView(
            core: core,
            config: config,
            kind: 'redis',
            running: true,
          ),
          ConfigEditor(
            config: config,
            onSave: (_) async {},
            onDelete: (_) async {},
          ),
        ],
      ),
      size: const Size(1280, 360),
    );

    final monitorScroll = find.descendant(
      of: find.byType(MonitorView),
      matching: find.byType(Scrollable),
    );
    await tester.drag(monitorScroll.first, const Offset(0, -180));
    await tester.pump();
    final monitorOffset =
        tester.state<ScrollableState>(monitorScroll.first).position.pixels;
    expect(monitorOffset, greaterThan(0));

    await _selectTab(tester, key, 1);
    await tester.pump();
    await tester.tap(find.text('ERROR').first);
    await tester.pump();
    final visibleInfoLine = find.byWidgetPredicate(
      (widget) =>
          widget is SelectableText &&
          (widget.data?.startsWith('info-') ?? false),
    );
    final visibleErrorLine = find.byWidgetPredicate(
      (widget) =>
          widget is SelectableText &&
          (widget.data?.startsWith('error-') ?? false),
    );
    expect(visibleInfoLine, findsNothing);
    expect(visibleErrorLine, findsWidgets);
    final logsScroll = find.descendant(
      of: find.byType(LogsPage),
      matching: find.byType(Scrollable),
    );
    final logsPosition =
        tester.state<ScrollableState>(logsScroll.first).position;
    logsPosition.jumpTo(logsPosition.maxScrollExtent / 2);
    await tester.pump();
    final logsOffset = logsPosition.pixels;
    expect(logsOffset, greaterThan(0));

    await _selectTab(tester, key, 2);
    final editor = find.descendant(
      of: find.byType(CodeField),
      matching: find.byType(TextField),
    );
    await tester.enterText(editor, 'return "retained playground";');
    await tester.pump();

    await _selectTab(tester, key, 3);
    final nameField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.controller?.text == fx.fixtureConfig().name,
    );
    expect(nameField, findsOneWidget);
    await tester.enterText(nameField, 'unsaved-instance-name');
    await tester.pump();

    await _selectTab(tester, key, 0);
    expect(
      tester.state<ScrollableState>(monitorScroll.first).position.pixels,
      monitorOffset,
    );

    await _selectTab(tester, key, 1);
    expect(visibleInfoLine, findsNothing);
    expect(visibleErrorLine, findsWidgets);
    expect(
      tester.state<ScrollableState>(logsScroll.first).position.pixels,
      logsOffset,
    );

    await _selectTab(tester, key, 2);
    expect(tester.widget<TextField>(editor).controller!.text,
        'return "retained playground";');

    await _selectTab(tester, key, 3);
    expect(_textFieldWithText(tester, 'unsaved-instance-name').controller!.text,
        'unsaved-instance-name');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Browser selection and Console history survive sibling tabs',
      (tester) async {
    final server = FakeRespServer();
    await tester.runAsync(server.start);
    final core = _RetentionCore();
    final key = GlobalKey<_TabHarnessState>();
    final config = fx.fixtureConfigAt(server.port);

    await _pumpHarness(
      tester,
      _TabHarness(
        key: key,
        children: [
          BrowserPageView(config: config, running: true, core: core),
          CmdConsole(
            host: '127.0.0.1',
            port: server.port,
            auth: config.requirepass,
            running: true,
            instanceName: config.name,
          ),
        ],
      ),
      size: const Size(1280, 700),
    );

    await _waitFor(tester, find.text('cache'));
    final browserSearch = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Glob pattern, e.g. user:*',
    );
    await tester.runAsync(() async {
      await tester.enterText(browserSearch, 'user:1001');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    final keyRowText = find.byWidgetPredicate(
      (widget) => widget is Text && widget.data == 'user:1001',
    );
    await _waitFor(tester, keyRowText);
    await tester.runAsync(() async {
      await tester.tap(keyRowText.first);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await _waitFor(tester, find.text('×'));

    await _selectTab(tester, key, 1);
    await _waitFor(tester, find.text('redimos-cli'));
    final consoleInput = find.descendant(
      of: find.byType(CmdConsole),
      matching: find.byType(TextField),
    );
    await tester.runAsync(() async {
      await tester.enterText(consoleInput, 'PING');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.text('PONG'), findsOneWidget);
    await tester.enterText(consoleInput, 'GET draft:key');
    await tester.pump();

    await _selectTab(tester, key, 0);
    expect(
        tester.widget<TextField>(browserSearch).controller!.text, 'user:1001');
    expect(find.text('×'), findsOneWidget,
        reason: 'the selected key workspace remains open');

    await _selectTab(tester, key, 1);
    expect(tester.widget<TextField>(consoleInput).controller!.text,
        'GET draft:key');
    await tester.tap(consoleInput);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(tester.widget<TextField>(consoleInput).controller!.text, 'PING');
    expect(find.text('PONG'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(server.close);
  });

  testWidgets('Endpoint Tables and Table screens retain list and selection',
      (tester) async {
    final core = _RetentionCore();
    final key = GlobalKey<_EndpointHarnessState>();

    await _pumpHarness(
      tester,
      _EndpointHarness(
        key: key,
        core: core,
        endpoint: fx.fixtureEndpoint,
      ),
      size: const Size(1280, 700),
    );
    await tester.pump();
    // Configure leads at 0; only the Table screen's sidebar loads the list.
    expect(core.endpointListCalls, 1);

    key.currentState!.select(1); // Table (the endpoint list tab is gone)
    await tester.pump();
    // No table picked yet: the sidebar lists every table and the data area
    // shows the pick-a-table hint — the "no table configured" error must not
    // render.
    expect(find.text(tr('tbl.noTableConfigured')), findsNothing);
    expect(find.text(tr('tbl.selectTableHint')), findsOneWidget);
    expect(find.byKey(const ValueKey('table-sidebar-tables')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('table-sidebar-row-users')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    // The sidebar row tap selected the table and rendered its scan.
    expect(key.currentState!.index, 1);
    expect(find.byKey(const ValueKey('table-flat-content-endpoint:e1-users')), findsOneWidget);
    expect(find.byKey(const ValueKey('table-sidebar-tables')), findsOneWidget);
    expect(find.byKey(const ValueKey('table-sidebar-row-users')), findsOneWidget);
    expect(find.text('user#1001'), findsOneWidget);

    // Filters live in a popup opened from the top-left button; the table and
    // the tables sidebar stay visible underneath.
    await tester.tap(find.text(tr('tbl.filters')));
    await tester.pump();
    expect(find.byKey(const ValueKey('table-filter-popup')), findsOneWidget);
    expect(find.text('SCAN FILTER'), findsOneWidget);
    expect(find.text('user#1001'), findsOneWidget);
    await tester.tapAt(const Offset(6, 6)); // dismiss via the barrier
    await tester.pump();
    expect(find.byKey(const ValueKey('table-filter-popup')), findsNothing);

    // Editing and duplicating require exactly one selected row; exporting
    // requires at least one.
    OutlinedButton batchButton(String label) =>
        tester.widget<OutlinedButton>(find.ancestor(
          of: find.text(label),
          matching: find.byType(OutlinedButton),
        ));
    expect(batchButton(tr('tbl.exportToCsv')).onPressed, isNull,
        reason: 'export needs a selection');

    final checkboxes = find.byType(Checkbox);
    expect(checkboxes, findsNWidgets(7));
    await tester.tap(checkboxes.at(1));
    await tester.tap(checkboxes.at(2));
    await tester.pump();
    final editButton = find.ancestor(
      of: find.text(tr('tbl.editItem')),
      matching: find.byType(OutlinedButton),
    );
    final duplicateButton = find.ancestor(
      of: find.text(tr('tbl.duplicateItem')),
      matching: find.byType(OutlinedButton),
    );
    expect(tester.widget<OutlinedButton>(editButton).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(duplicateButton).onPressed, isNull);
    expect(batchButton(tr('tbl.exportToCsv')).onPressed, isNotNull,
        reason: 'export is enabled once rows are selected');

    key.currentState!.select(0); // Configure
    await tester.pump();
    expect(find.text('sessions', skipOffstage: false), findsOneWidget,
        reason: 'the tables sidebar stays mounted behind Configure');
    expect(core.endpointListCalls, 1,
        reason: 'switching screens must not reload the list');

    key.currentState!.select(1); // Table
    await tester.pump();
    expect(
      find.text('user#1001'),
      findsOneWidget,
      reason: 'the selected table scan remains mounted',
    );
    expect(core.endpointListCalls, 1);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('endpoint without tables shows a guidance hint', (tester) async {
    final core = _EmptyTablesCore();
    final key = GlobalKey<_EndpointHarnessState>();

    await _pumpHarness(
      tester,
      _EndpointHarness(key: key, core: core, endpoint: fx.fixtureEndpoint),
      size: const Size(1280, 700),
    );
    await tester.pump();

    key.currentState!.select(1); // Table
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump();
    expect(find.text(tr('tbl.noTablesHint')), findsOneWidget);
    expect(find.text(tr('tbl.selectTableHint')), findsNothing);
    expect(tester.takeException(), isNull);

    // Drain the scan's pending 16ms timers before teardown.
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rapid instance tab cycling keeps state and connections stable',
      (tester) async {
    final server = FakeRespServer();
    await tester.runAsync(server.start);
    final core = _RetentionCore();
    final key = GlobalKey<_TabHarnessState>();
    final config = fx.fixtureConfigAt(server.port);

    await _pumpHarness(
      tester,
      _TabHarness(
        key: key,
        children: [
          BrowserPageView(config: config, running: true, core: core),
          CmdConsole(
            host: '127.0.0.1',
            port: server.port,
            auth: config.requirepass,
            running: true,
            instanceName: config.name,
          ),
          MonitorView(
            status: fx.fixtureStatus(),
            cpuHist: fx.mockSparkCpu,
            memHist: fx.mockSparkMem,
            opsHist: fx.mockSparkOps,
            embedded: true,
            instanceName: config.name,
          ),
          LogsPage(core: core, configId: config.id),
          PlaygroundView(
            core: core,
            config: config,
            kind: 'redis',
            running: true,
          ),
          ConfigEditor(
            config: config,
            onSave: (_) async {},
            onDelete: (_) async {},
          ),
        ],
      ),
      size: const Size(1280, 360),
    );

    await _waitFor(tester, find.text('cache'));
    final browserSearch = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Glob pattern, e.g. user:*',
    );
    await tester.enterText(browserSearch, 'draft:*');
    await tester.pump();

    await _selectTab(tester, key, 1);
    await _waitFor(tester, find.text('redimos-cli'));
    await tester.runAsync(() => server.waitForConnections(2));
    final consoleInput = find.descendant(
      of: find.byType(CmdConsole),
      matching: find.byType(TextField),
    );
    await tester.enterText(consoleInput, 'GET unsent:draft');
    await tester.pump();

    await _selectTab(tester, key, 2);
    final monitorScroll = find.descendant(
      of: find.byType(MonitorView),
      matching: find.byType(Scrollable),
    );
    await tester.drag(monitorScroll.first, const Offset(0, -180));
    await tester.pump();
    final monitorOffset =
        tester.state<ScrollableState>(monitorScroll.first).position.pixels;
    expect(monitorOffset, greaterThan(0));

    await _selectTab(tester, key, 3);
    final errorFilter = find.text('ERROR').first;
    final inactiveErrorStyle = tester.widget<Text>(errorFilter).style!;
    await tester.tap(errorFilter);
    await tester.pump();
    final activeErrorStyle = tester.widget<Text>(errorFilter).style!;
    expect(activeErrorStyle.color, isNot(inactiveErrorStyle.color));
    expect(activeErrorStyle.fontWeight, FontWeight.w600);

    await _selectTab(tester, key, 4);
    final editor = find.descendant(
      of: find.byType(CodeField),
      matching: find.byType(TextField),
    );
    await tester.enterText(editor, 'return "rapid-cycle";');
    await tester.pump();

    await _selectTab(tester, key, 5);
    final nameField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.controller?.text == config.name,
    );
    await tester.enterText(nameField, 'rapid-cycle-instance');
    await tester.pump();

    for (var round = 0; round < 3; round++) {
      for (var index = 0; index < 6; index++) {
        await _selectTab(tester, key, index);
      }
    }

    await _selectTab(tester, key, 0);
    expect(tester.widget<TextField>(browserSearch).controller!.text, 'draft:*');

    await _selectTab(tester, key, 1);
    expect(tester.widget<TextField>(consoleInput).controller!.text,
        'GET unsent:draft');

    await _selectTab(tester, key, 2);
    expect(
      tester.state<ScrollableState>(monitorScroll.first).position.pixels,
      monitorOffset,
    );

    await _selectTab(tester, key, 3);
    final retainedErrorStyle = tester.widget<Text>(errorFilter).style!;
    expect(retainedErrorStyle.color, activeErrorStyle.color);
    expect(retainedErrorStyle.fontWeight, FontWeight.w600);

    await _selectTab(tester, key, 4);
    expect(tester.widget<TextField>(editor).controller!.text,
        'return "rapid-cycle";');

    await _selectTab(tester, key, 5);
    expect(_textFieldWithText(tester, 'rapid-cycle-instance').controller!.text,
        'rapid-cycle-instance');
    expect(server.connectionCount, 2,
        reason: 'tab cycling must not reconnect Browser or Console');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(server.close);
  });

  testWidgets('rapid endpoint screen cycling avoids reloads and input loss',
      (tester) async {
    final core = _RetentionCore();
    final key = GlobalKey<_EndpointHarnessState>();

    await _pumpHarness(
      tester,
      _EndpointHarness(
        key: key,
        core: core,
        endpoint: fx.fixtureEndpoint,
      ),
      size: const Size(1280, 700),
    );
    await tester.pump();
    expect(core.endpointListCalls, 1);

    key.currentState!.select(1); // Table (Configure leads at 0)
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('table-sidebar-row-users')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('user#1001'), findsOneWidget);

    // Type into the Configure pane's name field before the cycling.
    key.currentState!.select(0);
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('ep-config-name-input')), 'retained-name');
    await tester.pump();

    for (var round = 0; round < 4; round++) {
      // 2 screens: Configure / Table.
      for (var index = 0; index < 2; index++) {
        key.currentState!.select(index);
        await tester.pump();
      }
    }

    key.currentState!.select(1); // Table
    await tester.pump();
    expect(
      find.text('user#1001'),
      findsOneWidget,
      reason: 'the selected table scan remains mounted after rapid cycling',
    );

    key.currentState!.select(0); // Configure
    await tester.pump();
    expect(
        tester
            .widget<TextField>(find.descendant(
              of: find.byKey(const ValueKey('ep-config-name-input')),
              matching: find.byType(TextField),
            ))
            .controller!
            .text,
        'retained-name');
    expect(core.endpointListCalls, 1,
        reason: 'the table list must load only once');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
