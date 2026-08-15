// Stage 14.5: four-tab navigation + lifecycle smoke test.
//
// A harness mirrors HomePage's Service detail routing (four tabs over ONE
// ServicesState + ID-keyed detail widgets) with a stateful scripted core,
// then proves that switching the selected Service swaps content, logs,
// metrics, and lifecycle actions cleanly — nothing from Service A ever leaks
// into Service B's view, and lifecycle ops address exactly one ID.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/service_configure.dart';
import 'package:redimos_manager/src/service_detail.dart';
import 'package:redimos_manager/src/services_state.dart';
import 'package:redimos_manager/src/ui_primitives.dart';
import 'package:redimos_manager/src/ui_theme.dart';

import 'fake_core.dart';

// ---------------------------------------------------------------------------
// Stateful scripted core: a tiny in-memory registry for two Services.
// ---------------------------------------------------------------------------

class _SmokeCore extends FakeNativeCore {
  final Map<String, String> states = {'svc-a': 'stopped', 'svc-b': 'stopped'};
  final startCalls = <String>[];
  final stopCalls = <String>[];
  final restartCalls = <String>[];

  static const _configs = {
    'svc-a': ('local-ddb', 'java', 8000),
    'svc-b': ('stage-ddb', 'docker', 8001),
  };

  static const _logsBy = {
    'svc-a': ['alpha boot', 'alpha ready'],
    'svc-b': ['beta boot', 'beta ready'],
  };

  ServiceInfo _info(String id) {
    final (name, engine, port) = _configs[id]!;
    final state = states[id]!;
    return ServiceInfo.fromJson({
      'config': {'id': id, 'name': name, 'engine': engine, 'port': port},
      'runtime': {
        'state': state,
        'ready': state == 'running',
        'healthy': state == 'running',
        // Only svc-a carries metrics: a clean marker that Monitor reads the
        // RIGHT per-ID ring buffer.
        if (state == 'running' && id == 'svc-a')
          'metrics': {'cpuPercent': 10.0, 'memBytes': 104857600, 'diskBytesPerSec': 0},
      },
    });
  }

  @override
  ({List<ServiceInfo> services, List<String> errors, List<String> warnings})
      services() => (
            services: states.keys.map(_info).toList(),
            errors: const [],
            warnings: const [],
          );

  @override
  ServiceInfo serviceStart(String id) {
    startCalls.add(id);
    states[id] = 'running';
    return _info(id);
  }

  @override
  ServiceInfo serviceStop(String id) {
    stopCalls.add(id);
    states[id] = 'stopped';
    return _info(id);
  }

  @override
  ServiceInfo serviceRestart(String id) {
    restartCalls.add(id);
    states[id] = 'running';
    return _info(id);
  }

  @override
  List<String> serviceLogs(String id) => _logsBy[id] ?? const [];

  @override
  ServiceInfo serviceSave(ServiceConfig service) => _info(service.id);

  @override
  ServiceDeleteResult serviceDelete(String id, {required bool deleteData}) =>
      ServiceDeleteResult(id: id, dataCleaned: deleteData);
}

// ---------------------------------------------------------------------------
// Harness: mirrors HomePage's Service detail routing.
// ---------------------------------------------------------------------------

class _DetailHarness extends StatefulWidget {
  final _SmokeCore core;
  const _DetailHarness(this.core);

  @override
  State<_DetailHarness> createState() => _DetailHarnessState();
}

class _DetailHarnessState extends State<_DetailHarness> {
  late final ServicesState svc = ServicesState(widget.core);

  @override
  void initState() {
    super.initState();
    svc.addListener(() {
      if (mounted) setState(() {});
    });
    svc.select('svc-a');
    // Same shape as HomePage's timer tick; the fake clock advances in the
    // test's pumps.
    svc.refresh();
  }

  @override
  void dispose() {
    svc.dispose();
    super.dispose();
  }

  void _life(ServiceInfo s, String op) {
    switch (op) {
      case 'start':
        widget.core.serviceStart(s.id);
      case 'stop':
        widget.core.serviceStop(s.id);
      case 'restart':
        widget.core.serviceRestart(s.id);
    }
    svc.refresh();
  }

  Widget _detail() {
    final s = svc.selected;
    if (s == null) return const SizedBox.shrink();
    return switch (svc.selectedTab) {
      0 => ServiceOverviewTab(
          key: ValueKey('overview-${s.id}'),
          service: s,
          onStart: () => _life(s, 'start'),
          onStop: () => _life(s, 'stop'),
          onRestart: () => _life(s, 'restart'),
        ),
      1 => ServiceMonitorTab(
          key: ValueKey('monitor-${s.id}'),
          service: s,
          history: svc.historyOf(s.id),
        ),
      2 => ServiceLogsTab(
          key: ValueKey('logs-${s.id}'),
          service: s,
          state: svc,
        ),
      _ => ServiceConfigEditor(
          key: ValueKey('configure-${s.id}'),
          service: s,
          peers: svc.services.where((p) => p.id != s.id).toList(),
          core: widget.core,
          onSaved: (_) => svc.refresh(),
          onDeleted: (id) {
            svc.onServiceDeleted(id);
            svc.refresh();
          },
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // "Sidebar": two selection targets.
      Row(children: [
        for (final id in ['svc-a', 'svc-b'])
          CodexButton(
            key: ValueKey('smoke-select-$id'),
            variant: CodexButtonVariant.secondary,
            semanticLabel: id,
            onPressed: () => svc.select(id),
            label: Text(id),
          ),
      ]),
      // "MidBar": the four Service tabs.
      Row(children: [
        for (var i = 0; i < 4; i++)
          CodexButton(
            key: ValueKey('smoke-tab-$i'),
            variant: svc.selectedTab == i
                ? CodexButtonVariant.primary
                : CodexButtonVariant.ghost,
            semanticLabel: 'tab $i',
            onPressed: () => svc.selectedTab = i,
            label: Text('$i'),
          ),
      ]),
      Expanded(child: _detail()),
    ]);
  }
}

Future<void> _pump(WidgetTester tester, _SmokeCore core) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.dark),
      themeAnimationDuration: Duration.zero,
      home: Scaffold(body: _DetailHarness(core)),
    ),
  );
  // Advance the fake clock so refresh()/requestLogs() zero-timers fire.
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump();
}

Future<void> _tab(WidgetTester tester, int i) async {
  await tester.tap(find.byKey(ValueKey('smoke-tab-$i')));
  await tester.pump(); // rebuild first: entering Logs schedules an async load
  await tester.pump(const Duration(milliseconds: 1)); // then fire it
  await tester.pump();
}

Future<void> _select(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('smoke-select-$id')));
  await tester.pump(); // rebuild creates the new per-ID detail widget
  await tester.pump(const Duration(milliseconds: 1)); // fire its async loads
  await tester.pump();
}

void main() {
  setUp(() => appLang.value = AppLang.en);
  tearDown(() => appLang.value = AppLang.en);

  testWidgets('four tabs render per-ID content with zero cross-talk',
      (tester) async {
    final core = _SmokeCore();
    core.states['svc-a'] = 'running'; // live: metrics + logs both exercised
    await _pump(tester, core);

    // --- Tab 0 Overview: per-ID identity ------------------------------------
    expect(find.byKey(const ValueKey('overview-svc-a')), findsOneWidget);
    expect(find.text('local-ddb'), findsOneWidget);
    expect(find.text('8000'), findsOneWidget);

    await _select(tester, 'svc-b');
    expect(find.byKey(const ValueKey('overview-svc-b')), findsOneWidget);
    expect(find.text('stage-ddb'), findsOneWidget);
    expect(find.text('8001'), findsOneWidget);
    expect(find.text('local-ddb'), findsNothing);

    // --- Tab 1 Monitor: per-ID history ---------------------------------------
    await _tab(tester, 1);
    // svc-b never ran → no samples → the explicit empty state.
    expect(find.byKey(const ValueKey('service-monitor-empty')), findsOneWidget);
    await _select(tester, 'svc-a');
    // svc-a is running with metrics → its own sparkline value renders.
    expect(find.byKey(const ValueKey('service-monitor-empty')), findsNothing);
    expect(find.text('10.0%'), findsOneWidget);

    // --- Tab 2 Logs: per-ID lines --------------------------------------------
    await _tab(tester, 2);
    expect(find.text('alpha boot'), findsOneWidget);
    expect(find.text('beta boot'), findsNothing);
    await _select(tester, 'svc-b');
    expect(find.text('beta boot'), findsOneWidget);
    expect(find.text('alpha boot'), findsNothing);

    // --- Tab 3 Configure: per-ID form -----------------------------------------
    await _tab(tester, 3);
    expect(find.byKey(const ValueKey('configure-svc-b')), findsOneWidget);
    final nameField = tester.widget<TextField>(find.descendant(
      of: find.byKey(const ValueKey('service-config-name-input')),
      matching: find.byType(TextField),
    ));
    expect(nameField.controller!.text, 'stage-ddb');
    await _select(tester, 'svc-a');
    expect(find.byKey(const ValueKey('configure-svc-a')), findsOneWidget);
    final nameFieldA = tester.widget<TextField>(find.descendant(
      of: find.byKey(const ValueKey('service-config-name-input')),
      matching: find.byType(TextField),
    ));
    expect(nameFieldA.controller!.text, 'local-ddb');

    // The detail tab is a per-KIND slot: switching Services kept it on 3.
    final harness =
        tester.state<_DetailHarnessState>(find.byType(_DetailHarness));
    expect(harness.svc.selectedTab, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lifecycle actions address exactly one Service at a time',
      (tester) async {
    final core = _SmokeCore();
    await _pump(tester, core);

    // svc-a stopped → Start only affects svc-a.
    await _tab(tester, 0);
    await tester.tap(find.byKey(const ValueKey('service-overview-start')));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(core.startCalls, ['svc-a']);
    expect(core.states['svc-a'], 'running');
    expect(core.states['svc-b'], 'stopped'); // sibling untouched

    // svc-b gets its own lifecycle: start, then restart svc-a, then stop b.
    await _select(tester, 'svc-b');
    await tester.tap(find.byKey(const ValueKey('service-overview-start')));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(core.states['svc-b'], 'running');
    expect(core.states['svc-a'], 'running'); // a kept running

    await _select(tester, 'svc-a');
    await tester.tap(find.byKey(const ValueKey('service-overview-restart')));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(core.restartCalls, ['svc-a']);

    await _select(tester, 'svc-b');
    await tester.tap(find.byKey(const ValueKey('service-overview-stop')));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(core.stopCalls, ['svc-b']);
    expect(core.states['svc-b'], 'stopped');
    expect(core.states['svc-a'], 'running'); // never cross-addressed

    // The badge on b's overview reads the stopped state.
    expect(find.text(tr('svc.state.stopped')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
