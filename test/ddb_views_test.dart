import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/ddb_views.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/monitor_widgets.dart';
import 'package:redimos_manager/src/ui_states.dart';
import 'package:redimos_manager/src/ui_surfaces.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'fake_core.dart';

class _DdbLogsCore extends FakeNativeCore {
  List<String> lines = const [];
  int calls = 0;

  @override
  List<String> ddbLogs() {
    calls++;
    return List.of(lines);
  }
}

LocalDdbInfo _runningDdb() => LocalDdbInfo(
      config: LocalDdbConfig(
        engine: 'localstack',
        storage: 'persist',
        port: 8000,
        volume: 'ddb-data',
      ),
      status: 'running',
      pid: 4242,
      port: 8123,
      uptimeSec: 3723,
      exitMsg: '',
      restarts: 2,
      cpuPercent: 12.5,
      memBytes: 64 * 1024 * 1024,
      diskPerSec: 3.4 * 1024 * 1024,
      adopted: true,
      probeOk: true,
      latencyMs: 4.25,
      dockerOk: true,
      javaOk: false,
      jarReady: false,
    );

Widget _app(Brightness brightness, Widget child) => MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(body: child),
    );

Future<void> _pump(
  WidgetTester tester, {
  required Brightness brightness,
  required Widget child,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(brightness, child));
  await tester.pump();
}

void main() {
  setUp(() => appLang.value = AppLang.en);

  for (final brightness in Brightness.values) {
    testWidgets(
      'Local DynamoDB Monitor uses semantic metrics in ${brightness.name}',
      (tester) async {
        final ddb = _runningDdb();
        await _pump(
          tester,
          brightness: brightness,
          child: DdbMonitorView(
            ddb: ddb,
            cpuHist: const [8, 10, 12.5],
            memHist: const [56, 60, 64],
            diskHist: const [1, 2, 3.4],
          ),
        );

        final tokens = AppTokens.forBrightness(brightness);
        final sparks =
            tester.widgetList<SparkTile>(find.byType(SparkTile)).toList();
        expect(sparks, hasLength(3));
        expect(sparks.map((spark) => spark.color).toList(), [
          tokens.accent,
          tokens.success,
          tokens.warning,
        ]);
        expect(sparks.map((spark) => spark.value).toList(), [
          '12.5 %',
          '64 MB',
          '3.4 MB/s',
        ]);
        expect(
          sparks.map((spark) => spark.data).toList(),
          [
            const [8.0, 10.0, 12.5],
            const [56.0, 60.0, 64.0],
            const [1.0, 2.0, 3.4],
          ],
        );

        final info =
            tester.widgetList<InfoTile>(find.byType(InfoTile)).toList();
        expect(info, hasLength(7));
        expect(info.map((tile) => tile.value).toList(), [
          '1h 2m',
          '2',
          '4.25 ms',
          tr('home.running'),
          '4242',
          '8123',
          'Docker · LocalStack',
        ]);
        expect(find.text(tr('home.adopted')), findsOneWidget);
        expect(find.byType(CodexSurface), findsNWidgets(10));
        expect(
            find.byKey(const ValueKey('ddb-monitor-scroll')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Local DynamoDB Monitor keeps stopped and missing guards',
      (tester) async {
    await _pump(
      tester,
      brightness: Brightness.dark,
      child: const DdbMonitorView(
        ddb: null,
        cpuHist: [],
        memHist: [],
        diskHist: [],
      ),
    );

    final shell = tester.widget<CodexStateShell>(
      find.byKey(const ValueKey('ddb-monitor-state')),
    );
    expect(shell.state, CodexContentState.empty);
    expect(find.text(tr('home.stopped')), findsOneWidget);

    final running = _runningDdb();
    final stopped = LocalDdbInfo(
      config: running.config,
      status: 'stopped',
      pid: 0,
      port: 0,
      uptimeSec: 0,
      exitMsg: '',
      restarts: 3,
      cpuPercent: 99,
      memBytes: 99,
      diskPerSec: 99,
      probeOk: false,
      latencyMs: 99,
      dockerOk: true,
      javaOk: false,
      jarReady: false,
    );
    await tester.pumpWidget(_app(
      Brightness.dark,
      DdbMonitorView(
        ddb: stopped,
        cpuHist: const [99],
        memHist: const [99],
        diskHist: const [99],
      ),
    ));
    await tester.pump();

    final sparks =
        tester.widgetList<SparkTile>(find.byType(SparkTile)).toList();
    expect(sparks.map((spark) => spark.value), everyElement('—'));
    final info = tester.widgetList<InfoTile>(find.byType(InfoTile)).toList();
    expect(info[2].value, '—',
        reason: 'latency requires a successful live probe');
    expect(info[4].value, '—', reason: 'stopped engines do not expose a PID');
    expect(info[5].value, '8000',
        reason: 'stopped engines use configured port');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Local DynamoDB Logs polls, replaces equal-length tails, and caps 200',
      (tester) async {
    final core = _DdbLogsCore()
      ..lines = List.generate(
          205, (index) => 'initial-${index.toString().padLeft(3, '0')}');

    await _pump(
      tester,
      brightness: Brightness.dark,
      child: DdbLogsView(core: core),
    );

    expect(core.calls, 1);
    expect(find.byKey(const ValueKey('ddb-logs-state')), findsOneWidget);
    expect(find.byType(CodexSurface), findsOneWidget);
    var output =
        tester.widget<SelectableText>(find.byType(SelectableText)).data!;
    expect(output.split('\n'), hasLength(200));
    expect(output, isNot(contains('initial-004')));
    expect(output, startsWith('initial-005'));
    expect(output, endsWith('initial-204'));
    final textStyle =
        tester.widget<SelectableText>(find.byType(SelectableText)).style!;
    expect(textStyle.fontFamily, Ts.monoFamily);

    core.lines = List.generate(
        205, (index) => 'updated-${index.toString().padLeft(3, '0')}');
    await tester.pump(const Duration(milliseconds: 1199));
    expect(core.calls, 1);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();

    expect(core.calls, 2);
    output = tester.widget<SelectableText>(find.byType(SelectableText)).data!;
    expect(output, startsWith('updated-005'),
        reason: 'content comparison must detect a shifted equal-length ring');
    expect(output, endsWith('updated-204'));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1200));
    expect(core.calls, 2,
        reason: 'disposing Logs must cancel its periodic timer');
  });

  testWidgets('Local DynamoDB Logs renders a shared empty state',
      (tester) async {
    final core = _DdbLogsCore();
    await _pump(
      tester,
      brightness: Brightness.light,
      child: DdbLogsView(core: core),
    );

    final shell = tester.widget<CodexStateShell>(
      find.byKey(const ValueKey('ddb-logs-state')),
    );
    expect(shell.state, CodexContentState.empty);
    expect(find.text(tr('home.noOutput')), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    expect(core.calls, 1);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
