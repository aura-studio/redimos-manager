import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/main.dart' show MonitorView;
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/monitor_widgets.dart';
import 'package:redimos_manager/src/ui_states.dart';
import 'package:redimos_manager/src/ui_surfaces.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'screen_fixtures.dart' as fx;

class _ExpandableMonitorHarness extends StatefulWidget {
  const _ExpandableMonitorHarness();

  @override
  State<_ExpandableMonitorHarness> createState() =>
      _ExpandableMonitorHarnessState();
}

class _ExpandableMonitorHarnessState extends State<_ExpandableMonitorHarness> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) => MonitorView(
        status: fx.fixtureStatus(),
        cpuHist: fx.mockSparkCpu,
        memHist: fx.mockSparkMem,
        opsHist: fx.mockSparkOps,
        expanded: expanded,
        onToggle: () => setState(() => expanded = !expanded),
      );
}

Widget _app(Brightness brightness, Widget child) => MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(body: child),
    );

void main() {
  setUp(() => appLang.value = AppLang.en);

  for (final brightness in Brightness.values) {
    testWidgets(
      'Monitor renders semantic metrics and empty state in ${brightness.name}',
      (tester) async {
        final status = fx.fixtureStatus();
        await fx.pumpScreen(
          tester,
          dark: brightness == Brightness.dark,
          child: MonitorView(
            status: status,
            cpuHist: fx.mockSparkCpu,
            memHist: fx.mockSparkMem,
            opsHist: fx.mockSparkOps,
            embedded: true,
            instanceName: 'prod-redis-01',
          ),
        );

        final tokens = AppTokens.forBrightness(brightness);
        final sparks =
            tester.widgetList<SparkTile>(find.byType(SparkTile)).toList();
        expect(sparks, hasLength(3));
        expect(sparks.map((tile) => tile.data), [
          fx.mockSparkCpu,
          fx.mockSparkMem,
          fx.mockSparkOps,
        ]);
        expect(sparks.map((tile) => tile.color), [
          tokens.accent,
          tokens.success,
          tokens.warning,
        ]);
        expect(sparks.every((tile) => tile.sparkHeight == 52), isTrue);
        expect(find.byType(CustomPaint), findsNWidgets(3));
        expect(find.byType(InfoTile), findsNWidgets(8));
        expect(find.byType(CodexSectionHeader), findsNWidgets(2));
        expect(find.byType(CodexSurface), findsNWidgets(11));

        final cpuValue = tester.widget<Text>(find.text('12.4%'));
        final memoryValue = tester.widget<Text>(find.text('412 MB'));
        final opsValue = tester.widget<Text>(find.text('1,208'));
        for (final value in [cpuValue, memoryValue, opsValue]) {
          expect(value.style?.fontFamily, Ts.monoFamily);
          expect(value.style?.fontFeatures, Ts.tabular);
        }

        final running = tester.widget<Text>(find.text(tr('home.running')));
        final ready = tester.widget<Text>(find.text(tr('home.ready')));
        expect(running.style?.color, tokens.success);
        expect(ready.style?.color, tokens.success);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(
          _app(
            brightness,
            const MonitorView(
              status: null,
              cpuHist: [],
              memHist: [],
              opsHist: [],
              embedded: true,
            ),
          ),
        );
        expect(find.byType(CodexStateShell), findsOneWidget);
        expect(find.text(tr('fmt.noData')), findsOneWidget);
        expect(find.byIcon(Icons.insights_outlined), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Monitor expansion keeps its header fixed and invokes toggle',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        Brightness.dark,
        const Align(
          alignment: Alignment.topCenter,
          child: _ExpandableMonitorHarness(),
        ),
      ),
    );

    final anchor = find.byKey(const ValueKey('monitor-toggle-anchor'));
    final collapsedHeader = tester.getRect(anchor);
    expect(find.byType(SparkTile), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);

    await tester.tap(anchor);
    await tester.pump();

    expect(tester.getRect(anchor), collapsedHeader);
    expect(find.byType(SparkTile), findsNWidgets(3));
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(anchor);
    await tester.pump();
    expect(tester.getRect(anchor), collapsedHeader);
    expect(find.byType(SparkTile), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
