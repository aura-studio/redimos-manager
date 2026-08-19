// Stage 15.5: Endpoint + Service parallel-operation smoke test.
//
// A harness mirrors HomePage's dual-entity shape (EntityKind + endpoint list /
// selection on one side, ServicesState on the other) over a scripted core with
// two strictly separate registries. It then interleaves operations on both
// sides and proves NONE of the forbidden couplings ever happens: no automatic
// creation, no binding, no selection steal, no navigation jump, and no
// lifecycle cascade from one namespace into the other (3.1–3.5, 6.7).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/endpoint_detail.dart';
import 'package:redimos_manager/src/home_chrome.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/service_detail.dart';
import 'package:redimos_manager/src/services_state.dart';
import 'package:redimos_manager/src/ui_primitives.dart';
import 'package:redimos_manager/src/ui_theme.dart';

import 'fake_core.dart';

// ---------------------------------------------------------------------------
// Scripted core: two disjoint registries + a full call log.
// ---------------------------------------------------------------------------

class _ParallelCore extends FakeNativeCore {
  final Map<String, ServiceInfo> svcRegistry;
  final Map<String, DdbEndpoint> epRegistry;
  final callLog = <String>[];

  _ParallelCore(this.svcRegistry, this.epRegistry);

  ServiceInfo _info(String id, String state) {
    final old = svcRegistry[id]!;
    final fresh = ServiceInfo.fromJson({
      'config': old.config.toJson(),
      'runtime': {
        'state': state,
        'ready': state == 'running',
        'healthy': state == 'running',
      },
    });
    svcRegistry[id] = fresh;
    return fresh;
  }

  @override
  ({
    List<RedimosConfig> configs,
    List<DdbEndpoint> endpoints,
    List<ProxyInstance> instances,
    Settings settings,
    List<String> stopAllSnapshot,
    GlobalStopSnapshot stopAllSnapshotV2,
    List<ServiceConfig> services,
  }) load() {
    callLog.add('load');
    return (
      configs: const <RedimosConfig>[],
      endpoints: epRegistry.values.toList(),
      instances: const <ProxyInstance>[],
      settings: Settings(),
      stopAllSnapshot: const <String>[],
      stopAllSnapshotV2: GlobalStopSnapshot(),
      services: svcRegistry.values.map((s) => s.config).toList(),
    );
  }

  @override
  ({List<ServiceInfo> services, List<String> errors, List<String> warnings})
      services() {
    callLog.add('services');
    return (
      services: svcRegistry.values.toList(),
      errors: const [],
      warnings: const [],
    );
  }

  @override
  ServiceInfo serviceStart(String id) {
    callLog.add('serviceStart:$id');
    return _info(id, 'running');
  }

  @override
  ServiceInfo serviceStop(String id) {
    callLog.add('serviceStop:$id');
    return _info(id, 'stopped');
  }

  @override
  ServiceDeleteResult serviceDelete(String id, {required bool deleteData}) {
    callLog.add('serviceDelete:$id');
    svcRegistry.remove(id);
    return ServiceDeleteResult(id: id, dataCleaned: false);
  }

  @override
  String saveConfig(RedimosConfig c) {
    callLog.add('saveConfig:${c.id}');
    return c.id;
  }
}

ServiceInfo _svc(String id, String name, {int port = 8000, String state = 'stopped'}) =>
    ServiceInfo.fromJson({
      'config': {'id': id, 'name': name, 'engine': 'java', 'port': port},
      'runtime': {
        'state': state,
        'ready': state == 'running',
        'healthy': state == 'running',
      },
    });

// ---------------------------------------------------------------------------
// Harness: mirrors HomePage's dual-entity wiring (nothing more).
// ---------------------------------------------------------------------------

class _ParallelHarness extends StatefulWidget {
  final _ParallelCore core;
  const _ParallelHarness(this.core);

  @override
  State<_ParallelHarness> createState() => _ParallelHarnessState();
}

class _ParallelHarnessState extends State<_ParallelHarness> {
  late final ServicesState svc = ServicesState(widget.core);
  EntityKind kind = EntityKind.endpoint;
  String? selectedEndpointId;

  @override
  void initState() {
    super.initState();
    svc.addListener(() {
      if (mounted) setState(() {});
    });
    selectedEndpointId = widget.core.epRegistry.keys.first;
    svc.refresh();
  }

  @override
  void dispose() {
    svc.dispose();
    super.dispose();
  }

  /// Mirrors HomePage._reload: endpoints come from the core snapshot.
  void _reload() {
    setState(() {
      selectedEndpointId ??= widget.core.epRegistry.isNotEmpty
          ? widget.core.epRegistry.keys.first
          : null;
    });
  }

  /// Mirrors the endpoint-create path: saveConfig + reload. The registry
  /// entry itself is what the Go dedup would persist from the config tuple.
  void addEndpoint(DdbEndpoint e) {
    widget.core.saveConfig(RedimosConfig(id: 'c-${e.id}', endpoint: e.endpoint));
    setState(() => widget.core.epRegistry[e.id] = e);
    _reload();
  }

  void selectEndpoint(String id) =>
      setState(() {
        kind = EntityKind.endpoint;
        selectedEndpointId = id;
      });

  void selectService(String id) => setState(() {
        kind = EntityKind.service;
        svc.select(id);
      });

  void startService(String id) {
    widget.core.serviceStart(id);
    svc.refresh();
  }

  void stopService(String id) {
    widget.core.serviceStop(id);
    svc.refresh();
  }

  void deleteService(String id) {
    widget.core.serviceDelete(id, deleteData: false);
    svc.onServiceDeleted(id);
    svc.refresh();
  }

  Widget _detail() {
    if (kind == EntityKind.endpoint) {
      final e = widget.core.epRegistry[selectedEndpointId];
      if (e == null) return const Text('no endpoint');
      return EndpointDetailView(
        key: ValueKey('endpoint-detail-${e.id}'),
        core: widget.core,
        endpoint: e,
        // Configure leads at 0 (v1 convention); keep Overview on stage as
        // this test did before the pane joined.
        screenIndex: 1,
      );
    }
    final s = svc.selected;
    if (s == null) return const Text('no service');
    return ServiceOverviewTab(
      key: ValueKey('service-overview-${s.id}'),
      service: s,
      onStart: () => startService(s.id),
      onStop: () => stopService(s.id),
      onRestart: () {},
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // "Rail + sidebar": selection buttons for both namespaces.
      Wrap(children: [
        for (final id in widget.core.epRegistry.keys)
          CodexButton(
            key: ValueKey('pick-ep-$id'),
            variant: CodexButtonVariant.secondary,
            semanticLabel: id,
            onPressed: () => selectEndpoint(id),
            label: Text(id),
          ),
        for (final s in svc.services)
          CodexButton(
            key: ValueKey('pick-svc-${s.id}'),
            variant: CodexButtonVariant.secondary,
            semanticLabel: s.id,
            onPressed: () => selectService(s.id),
            label: Text(s.id),
          ),
        CodexButton(
          key: const ValueKey('add-ep-clash'),
          variant: CodexButtonVariant.primary,
          semanticLabel: 'add clashing endpoint',
          onPressed: () => addEndpoint(DdbEndpoint(
            id: 'ep-${widget.core.epRegistry.length + 1}',
            name: 'Clash',
            kind: 'local',
            endpoint: 'http://127.0.0.1:8000', // collides with svc-a's port
          )),
          label: const Text('+ep'),
        ),
        CodexButton(
          key: const ValueKey('start-svc-a'),
          variant: CodexButtonVariant.primary,
          semanticLabel: 'start svc-a',
          onPressed: () => startService('svc-a'),
          label: const Text('start-a'),
        ),
        CodexButton(
          key: const ValueKey('delete-svc-a'),
          variant: CodexButtonVariant.danger,
          semanticLabel: 'delete svc-a',
          onPressed: () => deleteService('svc-a'),
          label: const Text('del-a'),
        ),
      ]),
      Expanded(child: _detail()),
    ]);
  }
}

Future<void> _pump(WidgetTester tester, _ParallelCore core) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.dark),
      themeAnimationDuration: Duration.zero,
      home: Scaffold(body: _ParallelHarness(core)),
    ),
  );
  await tester.pump(); // rebuild
  await tester.pump(const Duration(milliseconds: 1)); // fire zero-timers
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump();
}

void main() {
  setUp(() => appLang.value = AppLang.en);
  tearDown(() => appLang.value = AppLang.en);

  testWidgets(
      'endpoint and Service operations run in parallel with zero coupling',
      (tester) async {
    final core = _ParallelCore(
      {'svc-a': _svc('svc-a', 'local-ddb', state: 'stopped')},
      {
        'ep-1': const DdbEndpoint(
          id: 'ep-1',
          name: 'Local DynamoDB',
          kind: 'local',
          endpoint: 'http://localhost:8000',
        ),
      },
    );
    core.callLog.clear();
    await _pump(tester, core);

    final harness =
        tester.state<_ParallelHarnessState>(find.byType(_ParallelHarness));

    // Baseline: endpoint mode selected, Service list intact.
    expect(harness.kind, EntityKind.endpoint);
    expect(harness.selectedEndpointId, 'ep-1');
    expect(find.byKey(const ValueKey('endpoint-detail-ep-1')), findsOneWidget);
    expect(core.svcRegistry, hasLength(1));

    // 1. NO AUTO-CREATION / BINDING: adding an endpoint whose URL collides
    //    with the Service's port creates no Service and starts nothing.
    await _tap(tester, 'add-ep-clash');
    expect(core.epRegistry, hasLength(2));
    expect(core.svcRegistry, hasLength(1));
    expect(core.svcRegistry['svc-a']!.runtime.state, ServiceState.stopped);
    expect(core.callLog.where((c) => c.startsWith('serviceStart')), isEmpty);
    expect(core.callLog.where((c) => c.startsWith('serviceSave')), isEmpty);

    // 2. NO SELECTION STEAL / NAVIGATION JUMP: opening the Service keeps the
    //    endpoint selection exactly where it was.
    await _tap(tester, 'pick-svc-svc-a');
    expect(harness.kind, EntityKind.service);
    expect(harness.selectedEndpointId, 'ep-1'); // preserved
    expect(find.byKey(const ValueKey('service-overview-svc-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('endpoint-detail-ep-1')), findsNothing);

    // 3. NO LIFECYCLE CASCADE: starting the Service leaves both endpoints
    //    untouched, and the endpoint side never receives a call.
    await _tap(tester, 'start-svc-a');
    expect(core.svcRegistry['svc-a']!.runtime.state, ServiceState.running);
    expect(core.epRegistry, hasLength(2));
    expect(core.callLog,
        isNot(contains(anyOf('saveConfig:ep-1', 'saveConfig:ep-2', 'deleteConfig:ep-1'))));

    // 4. NO TAB FLAP: the endpoint page stays a fixed client-screen set while its
    //    URL's engine is live.
    await _tap(tester, 'pick-ep-ep-1');
    expect(harness.kind, EntityKind.endpoint);
    expect(find.byKey(const ValueKey('endpoint-detail-ep-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('ep-overview-ep-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('ep-ddbmon-ep-1'), skipOffstage: false),
        findsNothing);
    expect(find.byKey(const ValueKey('ep-ddblog-ep-1'), skipOffstage: false),
        findsNothing);

    // 5. NO DELETE CASCADE: deleting the Service keeps every endpoint, and
    //    the endpoint selection survives.
    await _tap(tester, 'delete-svc-a');
    expect(core.svcRegistry, isEmpty);
    expect(core.epRegistry, hasLength(2));
    expect(harness.selectedEndpointId, 'ep-1');
    expect(find.byKey(const ValueKey('endpoint-detail-ep-1')), findsOneWidget);

    // Throughout: the Service namespace was addressed only by its own IDs.
    expect(
      core.callLog.where((c) =>
          c.startsWith('serviceStart:') ||
          c.startsWith('serviceStop:') ||
          c.startsWith('serviceDelete:')),
      ['serviceStart:svc-a', 'serviceDelete:svc-a'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Service-side polling never reads or mutates endpoint state',
      (tester) async {
    final core = _ParallelCore(
      {'svc-a': _svc('svc-a', 'local-ddb', state: 'running')},
      {
        'ep-1': const DdbEndpoint(
          id: 'ep-1',
          name: 'Local DynamoDB',
          kind: 'local',
          endpoint: 'http://localhost:8000',
        ),
      },
    );
    await _pump(tester, core);
    core.callLog.clear();

    // Several poll ticks (the shape of HomePage's 1.5 s timer).
    final harness =
        tester.state<_ParallelHarnessState>(find.byType(_ParallelHarness));
    for (var i = 0; i < 3; i++) {
      harness.svc.refresh();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
    }

    // Every poll touched ONLY the Service read path.
    expect(core.callLog.toSet(), {'services'});
    expect(core.epRegistry, hasLength(1));
    expect(core.svcRegistry['svc-a']!.runtime.state, ServiceState.running);
    expect(tester.takeException(), isNull);
  });
}
