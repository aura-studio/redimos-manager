// v1.2: widget / boundary tests for the three Service detail tabs.
//
// Covers: Monitor's per-ID history, its '—' tiles before samples exist, and
// the dismissible error banner that replaced Overview's in-context error
// (8.2 — dismiss is per-error-text, a NEW error re-surfaces); Logs'
// refresh/copy/clear-view interactions, error preservation, and the
// stale-response guard across selection switches (10.4, 10.5). The Overview
// tab and its lifecycle-action matrix are gone by design (4.3): start/stop
// live on the sidebar cards only. Scripted core — no dylib needed.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/service_detail.dart';
import 'package:redimos_manager/src/services_state.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'fake_core.dart';

// ---------------------------------------------------------------------------
// Scripted core
// ---------------------------------------------------------------------------

class _ScriptedCore extends FakeNativeCore {
  final Map<String, List<String>> linesBy = {};
  ServiceApiException? logsError;

  @override
  List<String> serviceLogs(String id) {
    final err = logsError;
    if (err != null) throw err;
    return linesBy[id] ?? const [];
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
  int pid = 0,
  String containerId = '',
  bool ready = false,
  bool healthy = false,
  String error = '',
  String errorCode = '',
}) =>
    ServiceInfo.fromJson({
      'config': {'id': id, 'name': name, 'engine': engine, 'port': port},
      'runtime': {
        'state': state,
        'pid': pid,
        'containerId': containerId,
        'ready': ready,
        'healthy': healthy,
        'error': error,
        'errorCode': errorCode,
        if (state == 'running') 'startedAt': '2026-08-14T12:00:00Z',
      },
    });

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.dark),
      themeAnimationDuration: Duration.zero,
      home: Scaffold(body: child),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() => appLang.value = AppLang.en);
  tearDown(() => appLang.value = AppLang.en);

  // ---- Monitor: error banner (the in-context error's only home now, 8.2) ----

  testWidgets('monitor renders a lifecycle failure as a dismissible banner',
      (tester) async {
    ServiceInfo svc(String error, String code) => _svc(
          state: 'failed',
          error: error,
          errorCode: code,
        );

    await _pump(
      tester,
      ServiceMonitorTab(
        service: svc('port 8000 already in use', 'port_in_use'),
        history: ServiceHistory(90),
      ),
    );
    final banner = find.byKey(const ValueKey('service-monitor-error-banner'));
    expect(banner, findsOneWidget);
    expect(
        find.descendant(
            of: banner, matching: find.textContaining('port_in_use')),
        findsOneWidget);
    expect(
      find.descendant(
          of: banner,
          matching: find.textContaining('port 8000 already in use')),
      findsOneWidget,
    );
    // The rest of the monitor is still fully present (in-context, 8.2).
    expect(find.byKey(const ValueKey('service-monitor-cpu')), findsOneWidget);
    expect(find.byKey(const ValueKey('service-monitor-port')), findsOneWidget);

    // Dismiss hides THIS error...
    await tester.tap(find.byKey(const ValueKey('service-monitor-error-dismiss')));
    await tester.pump();
    expect(banner, findsNothing);

    // ...but a NEW error re-surfaces (dismissal is per-error-text).
    await _pump(
      tester,
      ServiceMonitorTab(
        service: svc('java exited with code 1', 'spawn_failed'),
        history: ServiceHistory(90),
      ),
    );
    expect(banner, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a running Service without error shows no banner',
      (tester) async {
    await _pump(
      tester,
      ServiceMonitorTab(
        service: _svc(state: 'running', ready: true, healthy: true),
        history: ServiceHistory(90),
      ),
    );
    expect(find.byKey(const ValueKey('service-monitor-error-banner')),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  // ---- Monitor: tiles ---------------------------------------------------------

  testWidgets('monitor renders placeholder tiles until samples exist',
      (tester) async {
    await _pump(
      tester,
      ServiceMonitorTab(service: _svc(), history: ServiceHistory(90)),
    );
    // All ten tiles are present from the first frame; the three spark cards
    // read '—' while the ring buffer is empty (7.2 fixed order).
    for (final k in [
      'service-monitor-cpu',
      'service-monitor-mem',
      'service-monitor-disk',
      'service-monitor-uptime',
      'service-monitor-restarts',
      'service-monitor-latency',
      'service-monitor-status',
      'service-monitor-health',
      'service-monitor-port',
      'service-monitor-engine',
    ]) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(find.text('—'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('monitor renders only the given Service\'s samples',
      (tester) async {
    final histA = ServiceHistory(90)
      ..sample(ServiceMetrics(cpuPercent: 12.5, memBytes: 256 * 1024 * 1024));
    final histB = ServiceHistory(90)
      ..sample(ServiceMetrics(cpuPercent: 77.0, memBytes: 512 * 1024 * 1024));

    await _pump(
      tester,
      ServiceMonitorTab(service: _svc(id: 'svc-a'), history: histA),
    );
    expect(find.text('12.5%'), findsOneWidget);
    expect(find.text('256 MB'), findsOneWidget);

    // The OTHER Service's buffer never leaks into this view (9.3).
    await _pump(
      tester,
      ServiceMonitorTab(service: _svc(id: 'svc-b'), history: histB),
    );
    expect(find.text('77.0%'), findsOneWidget);
    expect(find.text('512 MB'), findsOneWidget);
    expect(find.text('12.5%'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the ten-tile monitor fits 1280×800 without overflow (6.8)',
      (tester) async {
    final hist = ServiceHistory(90);
    for (var i = 0; i < 60; i++) {
      hist.sample(ServiceMetrics(
        cpuPercent: 10 + i * 0.2,
        memBytes: 300 * 1024 * 1024,
        diskBytesPerSec: 900,
      ));
    }
    await _pump(
      tester,
      ServiceMonitorTab(
        // Worst case: banner + live sparklines + every tile populated.
        service: _svc(
          state: 'failed',
          error: 'bind tcp 0.0.0.0:8000: address already in use',
          errorCode: 'port_in_use',
        ),
        history: hist,
      ),
    );
    expect(find.byKey(const ValueKey('service-monitor-error-banner')),
        findsOneWidget);
    for (final k in [
      'service-monitor-cpu',
      'service-monitor-mem',
      'service-monitor-disk',
      'service-monitor-uptime',
      'service-monitor-restarts',
      'service-monitor-latency',
      'service-monitor-status',
      'service-monitor-health',
      'service-monitor-port',
      'service-monitor-engine',
    ]) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    // A RenderFlex overflow would surface as a test exception (7.4).
    expect(tester.takeException(), isNull);
  });

  // ---- 14.3 Logs ---------------------------------------------------------------

  testWidgets('logs load, refresh, copy, and clear-view without core deletes',
      (tester) async {
    final core = _ScriptedCore()
      ..linesBy['svc-a'] = ['line-1', 'line-2'];
    final state = ServicesState(core)..select('svc-a');

    MethodCall? clipboardCall;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') clipboardCall = call;
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await _pump(tester, ServiceLogsTab(service: _svc(), state: state));
    await tester.pump(const Duration(milliseconds: 1)); // async load (fake clock)
    expect(find.text('line-1'), findsOneWidget);
    expect(find.text('line-2'), findsOneWidget);

    // Refresh picks up new lines.
    core.linesBy['svc-a'] = ['line-1', 'line-2', 'line-3'];
    await tester.tap(find.byKey(const ValueKey('service-logs-refresh')));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('line-3'), findsOneWidget);

    // Copy serializes every visible line.
    await tester.tap(find.byKey(const ValueKey('service-logs-copy')));
    await tester.pump();

    expect(clipboardCall, isNotNull);
    expect(
      (clipboardCall!.arguments as Map)['text'],
      'line-1\nline-2\nline-3',
    );
    expect(find.text(tr('svc.copied')), findsOneWidget);

    // Clear view empties the VIEW only — the core buffer is untouched (9.4).
    await tester.tap(find.byKey(const ValueKey('service-logs-clear')));
    await tester.pump();
    expect(find.byKey(const ValueKey('service-logs-empty')), findsOneWidget);
    expect(core.linesBy['svc-a'], hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty and failing log sources keep context and prior lines',
      (tester) async {
    // Empty source → the explicit empty state.
    final emptyCore = _ScriptedCore();
    final emptyState = ServicesState(emptyCore)..select('svc-a');
    await _pump(tester, ServiceLogsTab(service: _svc(), state: emptyState));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(const ValueKey('service-logs-empty')), findsOneWidget);

    // Failure after a successful load: error shows, prior lines preserved.
    final core = _ScriptedCore()..linesBy['svc-a'] = ['kept-line'];
    final state = ServicesState(core)..select('svc-a');
    await _pump(
      tester,
      ServiceLogsTab(
        key: const ValueKey('logs-kept'), // main.dart keys tabs by Service ID
        service: _svc(),
        state: state,
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('kept-line'), findsOneWidget);

    core.linesBy.remove('svc-a');
    core.logsError = ServiceApiException('io_error', 'pipe broke');
    await tester.tap(find.byKey(const ValueKey('service-logs-refresh')));
    await tester.pump(const Duration(milliseconds: 1));
    final err = find.byKey(const ValueKey('service-logs-error'));
    expect(err, findsOneWidget);
    expect(tester.widget<Text>(err).data, contains('io_error'));
    expect(find.text('kept-line'), findsOneWidget); // preserved (14.3)
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching selection loads only the new Service\'s logs',
      (tester) async {
    final core = _ScriptedCore()
      ..linesBy['svc-a'] = ['alpha-line']
      ..linesBy['svc-b'] = ['beta-line'];
    final state = ServicesState(core)..select('svc-a');

    await _pump(
      tester,
      ServiceLogsTab(key: const ValueKey('logs-svc-a'), service: _svc(id: 'svc-a'), state: state),
    );
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('alpha-line'), findsOneWidget);

    // Selection moves to svc-b: its tab keyed by ID is a fresh view.
    state.select('svc-b');
    await _pump(
      tester,
      ServiceLogsTab(key: const ValueKey('logs-svc-b'), service: _svc(id: 'svc-b'), state: state),
    );
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('beta-line'), findsOneWidget);
    expect(find.text('alpha-line'), findsNothing); // no cross-talk (9.6)

    // A stale request for the OLD id is refused by the generation guard.
    final stale = state.requestLogs('svc-a');
    await tester.pump(const Duration(milliseconds: 1));
    expect(await stale, isNull);
    expect(tester.takeException(), isNull);
  });

  // ---- Logs: severity colouring + auto-scroll (8.4) --------------------------

  testWidgets('log lines are coloured by severity, error reads danger',
      (tester) async {
    final core = _ScriptedCore()
      ..linesBy['svc-a'] = [
        '2026-08-20T12:00:00Z ERROR port in use',
        '2026-08-20T12:00:01Z WARN slow query',
        '2026-08-20T12:00:02Z INFO ready',
        'plain line without a level token',
      ];
    final state = ServicesState(core)..select('svc-a');
    addTearDown(state.dispose);
    await _pump(tester, ServiceLogsTab(service: _svc(), state: state));
    await tester.pump(const Duration(milliseconds: 1));

    final tokens = appTheme(Brightness.dark).extension<AppTokens>()!;
    Color colorOf(String line) => tester.widget<Text>(find.text(line)).style!.color!;
    expect(colorOf('2026-08-20T12:00:00Z ERROR port in use'), tokens.danger);
    expect(colorOf('2026-08-20T12:00:01Z WARN slow query'), tokens.warning);
    expect(colorOf('2026-08-20T12:00:02Z INFO ready'), tokens.text2);
    expect(colorOf('plain line without a level token'), tokens.text3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('auto-scroll follows the tail; scrolling up pauses it (8.4)',
      (tester) async {
    final core = _ScriptedCore()
      ..linesBy['svc-a'] = List.generate(400, (i) => 'log line $i');
    final state = ServicesState(core)..select('svc-a');
    addTearDown(state.dispose);
    await _pump(tester, ServiceLogsTab(service: _svc(), state: state));
    await tester.pump(const Duration(milliseconds: 1)); // load lands
    await tester.pump(); // post-frame jumpTo(maxScrollExtent)

    final logState =
        tester.state<ServiceLogsTabState>(find.byType(ServiceLogsTab));
    // Default: following is ON and the view sits at the tail (10.2).
    expect(logState.autoScroll, isTrue);
    expect(logState.scroll.position.pixels,
        logState.scroll.position.maxScrollExtent);

    // A manual scroll UP pauses following (10.3).
    await tester.drag(
        find.byKey(const ValueKey('service-logs-list')), const Offset(0, 300));
    await tester.pump();
    expect(logState.autoScroll, isFalse);

    // Returning to the bottom resumes following.
    logState.scroll.jumpTo(logState.scroll.position.maxScrollExtent);
    await tester.pump();
    expect(logState.autoScroll, isTrue);
    expect(tester.takeException(), isNull);
  });
}
