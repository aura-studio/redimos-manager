// Stage 15.4: Service ↔ Endpoint decoupling regression tests.
//
// Requirements 3.1–3.5, 1.5, 1.8, 6.7, 11.4: the two entities are fully
// independent. An Endpoint whose URL textually matches a Service's port must
// NOT gain engine screens, the chrome must not host any singleton dock, CRUD
// on one namespace must never touch the other, and the legacy singleton APIs
// (rm_ddb_*) must not be called anywhere in the app source.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/endpoint_detail.dart';
import 'package:redimos_manager/src/home_chrome.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/service_detail.dart';
import 'package:redimos_manager/src/services_state.dart';
import 'package:redimos_manager/src/ui_theme.dart';

import 'fake_core.dart';
import 'golden_fonts.dart';

// ---------------------------------------------------------------------------
// Fixtures: a Service and an Endpoint that deliberately COLLIDE on port and
// localhost text — the exact trap the old _ddbForEndpoint inference fell for.
// ---------------------------------------------------------------------------

const _collidingEndpoint = DdbEndpoint(
  id: 'ep-1',
  name: 'Local DynamoDB',
  kind: 'local',
  endpoint: 'http://localhost:8000',
);

ServiceInfo _runningService() => ServiceInfo.fromJson({
      'config': {
        'id': 'svc-1',
        'name': 'local-ddb',
        'engine': 'java',
        'port': 8000,
      },
      'runtime': {
        'state': 'running',
        'ready': true,
        'healthy': true,
        'pid': 4242,
        'startedAt': '2026-08-14T12:00:00Z',
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
  await tester.pump(const Duration(milliseconds: 1));
  await tester.pump();
  // Flush the endpoint Table screen's deferred metadata/scan loads (16ms
  // delays) so no timer outlives the widget tree.
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump();
}

// ---------------------------------------------------------------------------
// 3.1–3.4 (v1.2 redesign): Endpoint detail is client-side only — a fixed
// three screens (Configure / Endpoint / Table).
// ---------------------------------------------------------------------------

void _endpointDetailTests() {
  testWidgets(
      'endpoint keeps its client screens even when its URL matches '
      'a running Service\'s port', (tester) async {
    await _pump(
      tester,
      EndpointDetailView(
        core: FakeNativeCore(),
        endpoint: _collidingEndpoint,
        // Configure (the identity pane) leads at 0; the Table screen follows.
        screenIndex: 1,
      ),
    );

    // The client-side screens, keyed by endpoint ID. (IndexedStack
    // off-stages every non-current screen, so look through it.)
    expect(find.byKey(const ValueKey('ep-config-ep-1'), skipOffstage: false),
        findsOneWidget);
    expect(find.byKey(const ValueKey('ep-table-ep-1'), skipOffstage: false),
        findsOneWidget);

    // No engine screens — ever. The old Monitor/Logs tab keys must never
    // reappear, regardless of host/port text in the endpoint URL.
    expect(
        find.byKey(const ValueKey('ep-ddbmon-ep-1'), skipOffstage: false),
        findsNothing);
    expect(
        find.byKey(const ValueKey('ep-ddblog-ep-1'), skipOffstage: false),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a prefix-port URL (":8000" inside ":80000") binds nothing',
      (tester) async {
    // The old inference was port-bounded; the new contract is stronger —
    // there is no inference at all. A URL that even CONTAINS the Service
    // port renders the identical two-screen set.
    await _pump(
      tester,
      EndpointDetailView(
        core: FakeNativeCore(),
        endpoint: const DdbEndpoint(
          id: 'ep-2',
          name: 'Staging',
          kind: 'url',
          endpoint: 'http://127.0.0.1:80000',
        ),
        screenIndex: 1,
      ),
    );
    expect(find.byKey(const ValueKey('ep-table-ep-2'), skipOffstage: false),
        findsOneWidget);
    expect(find.byKey(const ValueKey('ep-ddbmon-ep-2')), findsNothing);
    expect(find.byKey(const ValueKey('ep-ddblog-ep-2')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

// ---------------------------------------------------------------------------
// 1.5 / 6.7: the chrome hosts no singleton dock; the Service list is the only
// engine surface.
// ---------------------------------------------------------------------------

void _chromeTests() {
  testWidgets('the sidebar has no Local DynamoDB dock, only Service cards',
      (tester) async {
    await loadGoldenFonts();
    await _pump(
      tester,
      HomeChrome(
        state: ChromeState(
          entityKind: EntityKind.service,
          configs: const [],
          endpoints: const [_collidingEndpoint],
          statuses: const {},
          selectedConfigId: null,
          selectedEndpointId: null,
          services: [_runningService()],
          selectedServiceId: 'svc-1',
          hoveredCardId: null,
          entityQuery: '',
          tabLabels: const ['Overview'],
          tabIndex: 0,
          stopAllSnapshot: const [],
          lang: AppLang.en,
        ),
        cb: ChromeCallbacks(
          onEntityKind: (_) {},
          onSelectConfig: (_) {},
          onSelectEndpoint: (_) {},
          onHoverCard: (_) {},
          onQueryChanged: (_) {},
          onNewConfig: () {},
          onMidTab: (_) {},
          onStartStop: (_) {},
          onStopAll: () {},
          onRestoreAll: () {},
          onLang: (_) {},
        ),
        child: const SizedBox.expand(),
      ),
    );

    // The Service IS listed (the one engine surface that remains)…
    expect(find.byKey(const ValueKey('entity-card-svc-1')), findsOneWidget);
    // …and the singleton dock is gone for good.
    expect(find.byKey(const ValueKey('local-ddb-panel')), findsNothing);
    expect(find.byKey(const ValueKey('local-ddb-toggle')), findsNothing);
    expect(find.byKey(const ValueKey('local-ddb-body')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

// ---------------------------------------------------------------------------
// 3.1 / 6.7: CRUD on one namespace never touches the other.
// ---------------------------------------------------------------------------

/// A core with two strictly separate registries; every cross-namespace call
/// would show up in the recorded method log.
class _TwoNamespaceCore extends FakeNativeCore {
  final Map<String, ServiceInfo> svcRegistry;
  final Map<String, DdbEndpoint> epRegistry;
  final calls = <String>[];

  _TwoNamespaceCore(this.svcRegistry, this.epRegistry);

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
    calls.add('load');
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
    calls.add('services');
    return (
      services: svcRegistry.values.toList(),
      errors: const [],
      warnings: const [],
    );
  }

  @override
  ServiceInfo serviceSave(ServiceConfig service) {
    calls.add('serviceSave:${service.id}');
    final info = svcRegistry[service.id]!;
    return info;
  }

  @override
  ServiceDeleteResult serviceDelete(String id, {required bool deleteData}) {
    calls.add('serviceDelete:$id');
    svcRegistry.remove(id);
    return ServiceDeleteResult(id: id, dataCleaned: false);
  }

  @override
  ServiceInfo serviceStart(String id) {
    calls.add('serviceStart:$id');
    return svcRegistry[id]!;
  }

  /// Endpoint-side persistence goes through saveConfig (the endpoint tuple).
  @override
  String saveConfig(RedimosConfig c) {
    calls.add('saveConfig:${c.id}');
    return c.id;
  }

  @override
  void deleteConfig(String id) {
    calls.add('deleteConfig:$id');
  }
}

void _crudIndependenceTests() {
  test('Service CRUD never mutates or calls into the Endpoint namespace',
      () async {
    final core = _TwoNamespaceCore(
      {'svc-1': _runningService()},
      {'ep-1': _collidingEndpoint},
    );

    // Endpoint create/edit (saveConfig path) + delete.
    final epConfig = RedimosConfig(
      id: 'c-1',
      name: 'via-endpoint',
      endpoint: 'http://localhost:8000', // collides with svc-1's port
    );
    core.saveConfig(epConfig);
    core.deleteConfig('c-1');

    // The Service registry is untouched: same single Service, same state.
    final snap = core.services();
    expect(snap.services, hasLength(1));
    expect(snap.services.single.id, 'svc-1');
    expect(snap.services.single.runtime.state, ServiceState.running);

    // Service lifecycle + edit.
    core.serviceStart('svc-1');
    core.serviceSave(snap.services.single.config);

    // The Endpoint registry survives untouched.
    final loaded = core.load();
    expect(loaded.endpoints, hasLength(1));
    expect(loaded.endpoints.single.id, 'ep-1');
    expect(loaded.endpoints.single.endpoint, 'http://localhost:8000');

    // Service delete does not cascade to endpoints.
    core.serviceDelete('svc-1', deleteData: false);
    expect(core.load().endpoints, hasLength(1));
    expect(core.services().services, isEmpty);

    // No lifecycle cross-addressing ever happened.
    expect(core.calls.where((c) => c.startsWith('serviceStart')), ['serviceStart:svc-1']);
    expect(
      core.calls,
      isNot(contains(anyOf('serviceStart:ep-1', 'serviceDelete:ep-1'))),
    );
  });

  testWidgets('ServicesState refresh reads only the Service namespace',
      (tester) async {
    final core = _TwoNamespaceCore(
      {'svc-1': _runningService()},
      {'ep-1': _collidingEndpoint},
    );
    final state = ServicesState(core)..select('svc-1');

    // refresh() runs on a zero-duration timer (FakeAsync): fire, elapse, then
    // settle — never await it directly.
    state.refresh();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(state.services, hasLength(1));
    expect(state.services.single.id, 'svc-1');

    // A poll cycle never issued an endpoint/config mutation: the only
    // namespace-touching call was the read.
    expect(core.calls.where((c) => c != 'load'), ['services']);
    state.dispose();
  });
}

// ---------------------------------------------------------------------------
// 3.5: Service detail offers no Endpoint/Browser/PartiQL/Playground shortcut.
// ---------------------------------------------------------------------------

void _serviceDetailShortcutAudit() {
  testWidgets('Service tabs expose no Endpoint-side entry points',
      (tester) async {
    final s = _runningService();
    final state = ServicesState(FakeNativeCore())..select(s.id);

    await _pump(
      tester,
      Column(children: [
        Expanded(child: ServiceMonitorTab(
          service: s,
          history: ServiceHistory(90),
        )),
      ]),
    );
    for (final label in [
      tr('tab.browser'),
      tr('tab.partiql'),
      tr('tab.playground'),
      tr('ep.browse'),
    ]) {
      expect(find.text(label), findsNothing,
          reason: 'Service Monitor must not offer "$label"');
    }

    // Logs tab: actions are refresh/copy/clear only.
    await _pump(
      tester,
      ServiceLogsTab(
        key: const ValueKey('audit-logs'),
        service: s,
        state: state,
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));
    for (final label in [
      tr('tab.browser'),
      tr('tab.partiql'),
      tr('tab.playground'),
    ]) {
      expect(find.text(label), findsNothing,
          reason: 'Service Logs must not offer "$label"');
    }
    state.dispose();
    expect(tester.takeException(), isNull);
  });
}

// ---------------------------------------------------------------------------
// 11.4: source-level guard — the legacy singleton APIs are not called
// anywhere in the app. The Go-side stubs remain (11.5), so only lib/ is
// scanned.
// ---------------------------------------------------------------------------

void _legacyApiGuard() {
  test('no app source calls the legacy singleton DynamoDB APIs', () {
    const banned = [
      'rm_ddb_',
      'ddbGet',
      'ddbSet',
      'ddbStart',
      'ddbStop',
      'ddbLogs',
      'LocalDdbPanel',
      'LocalDdbInfo',
      '_ddbForEndpoint',
    ];
    final hits = <String>[];
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      for (final b in banned) {
        if (src.contains(b)) hits.add('${f.path}: $b');
      }
    }
    expect(hits, isEmpty,
        reason: 'stage 15 removed every legacy singleton call site');
  });
}

void main() {
  setUp(() => appLang.value = AppLang.en);
  tearDown(() => appLang.value = AppLang.en);

  _endpointDetailTests();
  _chromeTests();
  _crudIndependenceTests();
  _serviceDetailShortcutAudit();
  _legacyApiGuard();
}
