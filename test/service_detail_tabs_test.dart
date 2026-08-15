// Stage 14.4: widget / boundary tests for the four Service detail tabs.
//
// Covers: the full lifecycle-state matrix on Overview (distinct badge +
// valid actions per state, 9.7), identity tiles + in-context error banner
// (9.8), Monitor's per-ID history and no-data state (9.3), and Logs'
// refresh/copy/clear-view interactions, error preservation, and the
// stale-response guard across selection switches (9.4, 9.6). Scripted core —
// no dylib needed.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/service_detail.dart';
import 'package:redimos_manager/src/services_state.dart';
import 'package:redimos_manager/src/ui_primitives.dart';
import 'package:redimos_manager/src/ui_status.dart';
import 'package:redimos_manager/src/ui_theme.dart';

import 'fake_core.dart';

// ---------------------------------------------------------------------------
// Scripted core
// ---------------------------------------------------------------------------

class _ScriptedCore extends FakeNativeCore {
  final startCalls = <String>[];
  final stopCalls = <String>[];
  final restartCalls = <String>[];
  final Map<String, List<String>> linesBy = {};
  ServiceApiException? logsError;

  @override
  List<String> serviceLogs(String id) {
    final err = logsError;
    if (err != null) throw err;
    return linesBy[id] ?? const [];
  }

  @override
  ServiceInfo serviceStart(String id) {
    startCalls.add(id);
    return ServiceInfo.fromJson({
      'config': {'id': id, 'name': id, 'engine': 'java', 'port': 8000},
      'runtime': {'state': 'running', 'ready': true, 'healthy': true},
    });
  }

  @override
  ServiceInfo serviceStop(String id) {
    stopCalls.add(id);
    return ServiceInfo.fromJson({
      'config': {'id': id, 'name': id, 'engine': 'java', 'port': 8000},
      'runtime': {'state': 'stopped'},
    });
  }

  @override
  ServiceInfo serviceRestart(String id) {
    restartCalls.add(id);
    return serviceStart(id);
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

bool _enabled(WidgetTester tester, String key) =>
    tester
        .widget<CodexButton>(find.byKey(ValueKey(key)))
        .onPressed !=
    null;

void main() {
  setUp(() => appLang.value = AppLang.en);
  tearDown(() => appLang.value = AppLang.en);

  // ---- 14.1 Overview: lifecycle-state matrix --------------------------------

  testWidgets('overview renders a distinct badge per lifecycle state',
      (tester) async {
    final labels = <String>{};
    final paints = <CodexStatus>{};
    for (final state in ServiceState.values) {
      await _pump(
        tester,
        ServiceOverviewTab(
          service: _svc(state: state.name),
          onStart: () {},
          onStop: () {},
          onRestart: () {},
        ),
      );
      final badge = tester.widget<CodexStatusBadge>(
        find.byKey(const ValueKey('service-overview-state-badge')),
      );
      expect(badge.label, serviceStateLabel(state));
      labels.add(badge.label);
      paints.add(badge.status);
    }
    // Every one of the 8 states owns a distinct label (9.7).
    expect(labels.length, ServiceState.values.length);
    expect(tester.takeException(), isNull);
  });

  testWidgets('overview enables exactly the valid actions per state',
      (tester) async {
    final starts = <String>[];
    final stops = <String>[];
    final restarts = <String>[];

    Future<void> pumpState(String state) => _pump(
          tester,
          ServiceOverviewTab(
            service: _svc(state: state),
            onStart: () => starts.add(state),
            onStop: () => stops.add(state),
            onRestart: () => restarts.add(state),
          ),
        );

    // stopped: only Start.
    await pumpState('stopped');
    expect(_enabled(tester, 'service-overview-start'), isTrue);
    expect(_enabled(tester, 'service-overview-stop'), isFalse);
    expect(_enabled(tester, 'service-overview-restart'), isFalse);
    await tester.tap(find.byKey(const ValueKey('service-overview-start')));
    expect(starts, ['stopped']);

    // preparing / restarting: live states accept Stop (cancel) but no Start
    // or Restart.
    for (final s in ['preparing', 'restarting']) {
      await pumpState(s);
      expect(_enabled(tester, 'service-overview-start'), isFalse, reason: s);
      expect(_enabled(tester, 'service-overview-stop'), isTrue, reason: s);
      expect(_enabled(tester, 'service-overview-restart'), isFalse, reason: s);
    }

    // stopping / recovering: transitional states outside the live set accept
    // no action (matches the card-level isLive toggle grammar).
    for (final s in ['stopping', 'recovering']) {
      await pumpState(s);
      expect(_enabled(tester, 'service-overview-start'), isFalse, reason: s);
      expect(_enabled(tester, 'service-overview-stop'), isFalse, reason: s);
      expect(_enabled(tester, 'service-overview-restart'), isFalse, reason: s);
    }

    // running: Stop + Restart only.
    await pumpState('running');
    expect(_enabled(tester, 'service-overview-start'), isFalse);
    expect(_enabled(tester, 'service-overview-stop'), isTrue);
    expect(_enabled(tester, 'service-overview-restart'), isTrue);
    await tester.tap(find.byKey(const ValueKey('service-overview-stop')));
    await tester.tap(find.byKey(const ValueKey('service-overview-restart')));
    expect(stops, ['running']);
    expect(restarts, ['running']);

    // failed / error: Start is the recovery path.
    for (final s in ['failed', 'error']) {
      await pumpState(s);
      expect(_enabled(tester, 'service-overview-start'), isTrue, reason: s);
      expect(_enabled(tester, 'service-overview-stop'), isFalse, reason: s);
      expect(_enabled(tester, 'service-overview-restart'), isFalse, reason: s);
    }
    expect(starts, ['stopped']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('overview tiles name identity, port, location, and runtime',
      (tester) async {
    // Java engine: runtime identity is the PID.
    await _pump(
      tester,
      ServiceOverviewTab(
        service: _svc(state: 'running', pid: 4242, ready: true, healthy: true),
        onStart: () {},
        onStop: () {},
        onRestart: () {},
      ),
    );
    expect(find.text('java'), findsOneWidget);
    expect(find.text('8000'), findsOneWidget);
    expect(find.text('PID 4242'), findsOneWidget);
    expect(find.text(tr('svc.ready')), findsOneWidget);
    expect(find.text(tr('svc.healthy')), findsOneWidget);

    // Container engine: runtime identity is the short container ID.
    await _pump(
      tester,
      ServiceOverviewTab(
        service: _svc(
          engine: 'docker',
          state: 'running',
          containerId: 'abcdef1234567890',
        ),
        onStart: () {},
        onStop: () {},
        onRestart: () {},
      ),
    );
    expect(find.text('abcdef123456'), findsOneWidget); // truncated to 12
    expect(tester.takeException(), isNull);
  });

  testWidgets('a lifecycle failure renders in-context, not shell-replacing',
      (tester) async {
    await _pump(
      tester,
      ServiceOverviewTab(
        service: _svc(
          state: 'failed',
          error: 'port 8000 already in use',
          errorCode: 'port_in_use',
        ),
        onStart: () {},
        onStop: () {},
        onRestart: () {},
      ),
    );
    final banner = find.byKey(const ValueKey('service-overview-error'));
    expect(banner, findsOneWidget);
    expect(find.descendant(of: banner, matching: find.textContaining('port_in_use')),
        findsOneWidget);
    expect(
      find.descendant(
          of: banner, matching: find.textContaining('port 8000 already in use')),
      findsOneWidget,
    );
    // The rest of the overview is still fully present (9.8).
    expect(find.byKey(const ValueKey('service-overview-start')), findsOneWidget);
    expect(find.byKey(const ValueKey('service-overview-port')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ---- 14.2 Monitor ----------------------------------------------------------

  testWidgets('monitor shows the no-data state until samples exist',
      (tester) async {
    await _pump(
      tester,
      ServiceMonitorTab(service: _svc(), history: ServiceHistory(90)),
    );
    expect(find.byKey(const ValueKey('service-monitor-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('service-monitor-cpu')), findsNothing);
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
    expect(find.byKey(const ValueKey('service-monitor-empty')), findsNothing);

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
}
