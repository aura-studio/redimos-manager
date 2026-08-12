import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/logs_page.dart';
import 'package:redimos_manager/src/ui_primitives.dart';
import 'package:redimos_manager/src/ui_states.dart';
import 'package:redimos_manager/src/ui_surfaces.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'fake_core.dart';

class _LogsCore extends FakeNativeCore {
  final List<String> lines = [];
  int pulls = 0;

  @override
  List<String> logs(String id) {
    pulls++;
    return List<String>.of(lines);
  }
}

class _LogsTabHarness extends StatelessWidget {
  const _LogsTabHarness({required this.core});

  final _LogsCore core;

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Column(
          children: [
            const TabBar(
              tabs: [
                Tab(text: 'Logs'),
                Tab(text: 'Other'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  LogsPage(core: core, configId: 'c1'),
                  const ColoredBox(color: Colors.transparent),
                ],
              ),
            ),
          ],
        ),
      );
}

Widget _app(Brightness brightness, Widget child) => MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(body: child),
    );

Future<void> _pumpLogs(
  WidgetTester tester,
  _LogsCore core, {
  Brightness brightness = Brightness.dark,
  Size size = const Size(1280, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _app(brightness, LogsPage(core: core, configId: 'c1')),
  );
  await tester.pump();
}

Future<void> _disposeLogs(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

ScrollableState _logsScrollable(WidgetTester tester) =>
    tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(const ValueKey('logs-list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );

List<String> _manyLines(int count, {int start = 0}) => List.generate(
      count,
      (index) {
        final value = start + index;
        final level = value.isEven ? 'ERROR' : 'INFO';
        return '08:00:${(value % 60).toString().padLeft(2, '0')} '
            '$level message-$value';
      },
    );

void main() {
  setUp(() => appLang.value = AppLang.en);

  for (final brightness in Brightness.values) {
    testWidgets(
      'Logs renders Codex surfaces and semantic severity in ${brightness.name}',
      (tester) async {
        final core = _LogsCore()
          ..lines.addAll(const [
            '08:00:00 INFO info-message',
            '08:00:01 WARN warn-message',
            '08:00:02 ERROR error-message',
            '08:00:03 DEBUG debug-message',
            '08:00:04 unclassified-message',
          ]);

        await _pumpLogs(tester, core, brightness: brightness);

        final tokens = AppTokens.forBrightness(brightness);
        expect(find.byType(CodexStateShell), findsOneWidget);
        expect(find.byType(CodexSurface), findsOneWidget);
        expect(find.byType(CodexButton), findsNWidgets(3));
        expect(find.byKey(const ValueKey('logs-list')), findsOneWidget);

        Color? rowLevelColor(String label, Color expected) => tester
            .widgetList<Text>(find.text(label))
            .map((text) => text.style?.color)
            .where((color) => color == expected)
            .firstOrNull;

        expect(rowLevelColor('WARN', tokens.warning), tokens.warning);
        expect(rowLevelColor('ERROR', tokens.danger), tokens.danger);
        expect(rowLevelColor('INFO', tokens.text2), tokens.text2);
        expect(rowLevelColor('DEBUG', tokens.text3), tokens.text3);

        for (final message in [
          'info-message',
          'warn-message',
          'error-message',
          'debug-message',
          'unclassified-message',
        ]) {
          final text = tester.widget<SelectableText>(
            find.byWidgetPredicate(
              (widget) => widget is SelectableText && widget.data == message,
            ),
          );
          expect(text.style?.fontFamily, Ts.monoFamily);
        }
        expect(tester.takeException(), isNull);

        await _disposeLogs(tester);
      },
    );
  }

  testWidgets('Logs polls at 1200ms and preserves filter and clear cut-off',
      (tester) async {
    final core = _LogsCore()
      ..lines.addAll(const [
        '08:00:00 INFO initial-info',
        '08:00:01 ERROR initial-error',
      ]);

    await _pumpLogs(tester, core);
    expect(core.pulls, 1);

    await tester.tap(find.text('ERROR').first);
    await tester.pump();
    expect(find.text('initial-info'), findsNothing);
    expect(find.text('initial-error'), findsOneWidget);

    core.lines.add('08:00:02 ERROR timer-error');
    await tester.pump(const Duration(milliseconds: 1199));
    expect(core.pulls, 1);
    expect(find.text('timer-error'), findsNothing);

    await tester.pump(const Duration(milliseconds: 1));
    expect(core.pulls, 2);
    expect(find.text('timer-error'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('logs-clear')));
    await tester.pump();
    expect(find.text(tr('home.noOutput')), findsOneWidget);
    expect(find.byKey(const ValueKey('logs-list')), findsNothing);

    core.lines.add('08:00:03 ERROR after-clear');
    await tester.pump(const Duration(milliseconds: 1200));
    expect(core.pulls, 3);
    expect(find.text('initial-error'), findsNothing);
    expect(find.text('timer-error'), findsNothing);
    expect(find.text('after-clear'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _disposeLogs(tester);
  });

  testWidgets('Logs auto-scroll can pause and resume without moving its pane',
      (tester) async {
    final core = _LogsCore()..lines.addAll(_manyLines(160));
    await _pumpLogs(tester, core, size: const Size(1280, 360));

    final state = _logsScrollable(tester);
    expect(state.position.maxScrollExtent, greaterThan(0));
    expect(state.position.pixels, state.position.maxScrollExtent);

    await tester.tap(find.byKey(const ValueKey('logs-auto-scroll')));
    await tester.pump();
    expect(find.byIcon(Icons.pause), findsOneWidget);
    state.position.jumpTo(0);
    await tester.pump();

    core.lines.addAll(_manyLines(24, start: 160));
    await tester.pump(const Duration(milliseconds: 1200));
    expect(state.position.pixels, 0);

    await tester.tap(find.byKey(const ValueKey('logs-auto-scroll')));
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.vertical_align_bottom), findsOneWidget);
    expect(state.position.pixels, state.position.maxScrollExtent);
    expect(tester.takeException(), isNull);

    await _disposeLogs(tester);
  });

  testWidgets(
      'Logs retains filter and scroll offset across real TabBarView tabs',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final core = _LogsCore()..lines.addAll(_manyLines(160));

    await tester.pumpWidget(
      _app(Brightness.dark, _LogsTabHarness(core: core)),
    );
    await tester.pump();

    List<String> visibleMessages() => tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((text) => text.data)
        .whereType<String>()
        .where((text) => text.startsWith('message-'))
        .toList();

    await tester.tap(find.text('ERROR').first);
    await tester.pump();
    final filteredBefore = visibleMessages();
    expect(filteredBefore, isNotEmpty);
    expect(
      filteredBefore.every(
        (message) => int.parse(message.substring('message-'.length)).isEven,
      ),
      isTrue,
    );

    final state = _logsScrollable(tester);
    state.position.jumpTo(state.position.maxScrollExtent / 2);
    await tester.pump();
    final retainedOffset = state.position.pixels;
    expect(retainedOffset, greaterThan(0));

    await tester.tap(find.text('Other'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('Logs'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    final filteredAfter = visibleMessages();
    expect(filteredAfter, isNotEmpty);
    expect(
      filteredAfter.every(
        (message) => int.parse(message.substring('message-'.length)).isEven,
      ),
      isTrue,
    );
    expect(_logsScrollable(tester).position.pixels, retainedOffset);
    expect(tester.takeException(), isNull);

    await _disposeLogs(tester);
  });
}
