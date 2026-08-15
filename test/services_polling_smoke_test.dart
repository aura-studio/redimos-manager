// Stage 11.5: multi-Service fake-core polling smoke. A minimal harness widget
// (cards + selected detail + history readout) sits on ServicesState exactly
// the way the stage-12 sidebar will: ONE periodic timer drives the full
// snapshot, and every card / detail / history stays aligned by immutable
// Service ID through adds, removals, and selection moves (12.1–12.5).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/native.dart';
import 'package:redimos_manager/src/services_state.dart';

class ScriptedCore implements NativeCore {
  List<ServiceInfo> snapshot = const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('ScriptedCore: ${invocation.memberName}');

  @override
  ({List<ServiceInfo> services, List<String> errors, List<String> warnings})
      services() =>
          (services: snapshot, errors: const [], warnings: const []);

  @override
  List<String> serviceLogs(String id) => ['log from $id'];
}

ServiceInfo svc(String id, String name, {String state = 'stopped'}) {
  return ServiceInfo.fromJson({
    'config': {'id': id, 'name': name, 'engine': 'java', 'port': 8000},
    'runtime': {
      'state': state,
      'ready': state == 'running',
      'healthy': state == 'running',
      if (state == 'running')
        'metrics': {'cpuPercent': 9.0, 'memBytes': 64 * 1024 * 1024, 'diskBytesPerSec': 512.0},
    },
  });
}

/// The stage-12 shape in miniature: one timer, cards by ID, a detail bound to
/// the selected ID, and the selected ID's history.
class _SvcHarness extends StatefulWidget {
  const _SvcHarness(this.state);
  final ServicesState state;

  @override
  State<_SvcHarness> createState() => _SvcHarnessState();
}

class _SvcHarnessState extends State<_SvcHarness> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    // The same cadence HomePage uses — one poller for every Service (12.5).
    _poll = Timer.periodic(
        const Duration(milliseconds: 1500), (_) => widget.state.refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (_, __) {
        final st = widget.state;
        final sel = st.selected;
        return MaterialApp(
          home: Column(children: [
            for (final s in st.services)
              Text('card:${s.id}:${s.runtime.state.name}'),
            Text('selected:${sel?.id ?? "none"}'),
            Text('detail:${sel?.config.name ?? "-"}'),
            Text('hist:${sel == null ? 0 : st.historyOf(sel.id).cpuPercent.length}'),
            Text('tab:${st.selectedTab}'),
          ]),
        );
      },
    );
  }
}

void main() {
  testWidgets('cards, selection and history stay ID-aligned across polls',
      (tester) async {
    final core = ScriptedCore();
    final state = ServicesState(core);
    core.snapshot = [
      svc('svc-a', 'Alpha', state: 'running'),
      svc('svc-b', 'Beta'),
    ];

    await tester.pumpWidget(_SvcHarness(state));
    // Boot snapshot via runAsync: testWidgets' FakeAsync zone would deadlock
    // on a bare await of the refresh's zero-duration timer; the steady state
    // afterwards is driven by the harness's periodic timer + pump(duration).
    await tester.runAsync(() => state.refresh());
    await tester.pump();

    expect(find.text('card:svc-a:running'), findsOneWidget);
    expect(find.text('card:svc-b:stopped'), findsOneWidget);
    expect(find.text('selected:none'), findsOneWidget);

    state.select('svc-a');
    await tester.pump();
    expect(find.text('selected:svc-a'), findsOneWidget);
    expect(find.text('detail:Alpha'), findsOneWidget);
    expect(find.text('hist:1'), findsOneWidget); // the boot sample

    // Two more timer ticks: ONLY the running Service accrues history (12.3).
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    expect(find.text('hist:3'), findsOneWidget);
    expect(state.historyOf('svc-b').isEmpty, true); // stopped: frozen at zero

    // The detail tab survives switching to another Service (12.6).
    state.selectedTab = 2;
    state.select('svc-b');
    await tester.pump();
    expect(find.text('selected:svc-b'), findsOneWidget);
    expect(find.text('detail:Beta'), findsOneWidget);
    expect(find.text('hist:0'), findsOneWidget); // svc-b never sampled
    expect(find.text('tab:2'), findsOneWidget);

    // Alpha vanishes (deleted elsewhere); Beta keeps its card + detail, and a
    // later poll removes Beta too — selection falls to none, history is gone.
    core.snapshot = [svc('svc-b', 'Beta')];
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    expect(find.text('card:svc-a:running'), findsNothing);
    expect(find.text('card:svc-b:stopped'), findsOneWidget);
    expect(state.historyOf('svc-a').isEmpty, true);

    core.snapshot = [];
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    expect(find.text('selected:none'), findsOneWidget);
    expect(state.historyOf('svc-b').isEmpty, true);

    state.dispose();
  });
}
