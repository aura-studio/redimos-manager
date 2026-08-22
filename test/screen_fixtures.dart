// Shared fixtures + pump harness for the v2.3 screen tests.
//
// pixel-fidelity-v23 (CP 2.1): golden_screens_test.dart delegates its theme
// and fixtures here; test/pixel_capture_test.dart reuses the per-screen pump
// sequences so the capture channel renders EXACTLY what the goldens assert.
//
// IMPORTANT: the per-screen pump sequences below must mirror the bodies in
// golden_screens_test.dart. If a golden body changes, update the matching
// pump here too.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/main.dart' show MonitorView;
import 'package:redimos_manager/src/browser_page.dart';
import 'package:redimos_manager/src/cmd_console.dart';
import 'package:redimos_manager/src/configure_page.dart';
import 'package:redimos_manager/src/endpoint_browser.dart';
import 'package:redimos_manager/src/endpoint_detail.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/logs_page.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/playground_page.dart';
import 'package:redimos_manager/src/service_configure.dart';
import 'package:redimos_manager/src/service_detail.dart';
import 'package:redimos_manager/src/services_state.dart';
import 'package:redimos_manager/src/ui_fields.dart';
import 'package:redimos_manager/src/ui_theme.dart';

import 'fake_core.dart';
import 'fake_resp_server.dart';
import 'golden_fonts.dart';

/// The production theme with the deterministic UI font registered by tests.
ThemeData goldenTheme(Brightness brightness) =>
    appTheme(brightness, fontFamily: kGoldenUiFont);

/// Pump [child] inside the app-equivalent MaterialApp/Scaffold at the design's
/// 1280×800 logical size (×2 for crisp PNGs). [shotKey] optionally wraps the
/// Scaffold in a RepaintBoundary for pixel capture (no rendering effect).
/// The boundary goes around the Scaffold, not the screen widget: some screens
/// don't size themselves to fill, but the Scaffold always fills the view —
/// the capture must cover the full 2560×1600 like the goldens do.
///
/// [chrome] (CP 9.x, capture channel only) wraps the content screen in the
/// app's real chrome (rail / entity sidebar / top bar / mid bar / status bar
/// via HomeChrome) so captures match the full-frame mockups. The golden
/// channel never passes it — its full-frame layout stays untouched.
Future<void> pumpScreen(WidgetTester tester,
    {required bool dark,
    required Widget child,
    Key? shotKey,
    Widget Function(Widget content)? chrome}) async {
  await loadGoldenFonts();
  tester.view.physicalSize = const Size(2560, 1600);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final body = chrome == null ? child : chrome(child);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: goldenTheme(dark ? Brightness.dark : Brightness.light),
    scrollBehavior: appScrollBehavior,
    home: shotKey == null
        ? Scaffold(body: body)
        : RepaintBoundary(key: shotKey, child: Scaffold(body: body)),
  ));
}

// ---------------------------------------------------------------------------
// Fixtures (deterministic — dynamic fields frozen, requirements 2.7)
// ---------------------------------------------------------------------------

final fakeCore = FakeNativeCore();

const fixtureEndpoint = DdbEndpoint(
  id: 'e1',
  name: 'Local DDB',
  kind: 'local',
  endpoint: 'http://localhost:8000',
);

RedimosConfig fixtureConfig() => RedimosConfig(
      id: 'c1',
      // v2.3 mockup identity (CP 9.x): the HTML pages show 'prod-redis-01'
      // on 6379 with the redimos-prod table; capture-side text then compares
      // like-for-like. Golden images pick this up too (re-baselined in 10.2).
      name: 'prod-redis-01',
      port: 6379,
      table: 'redimos-prod',
      region: 'us-east-1',
      endpoint: '', // mockup 'Endpoint override' shows its placeholder (empty)
      requirepass: 'demopass-1', // 10 chars -> the mockup's 10 mask dots
      extraFlags: [
        FlagKV(key: 'max-clients', value: '256'),
        FlagKV(key: 'latency-trace', value: 'off'),
      ],
    );

/// Same fixture, pointed at the fake RESP server's ephemeral port (task #50).
RedimosConfig fixtureConfigAt(int port) => RedimosConfig(
      id: 'c1',
      name: 'prod-redis-01',
      port: port,
      table: 'redimos-prod',
      region: 'us-east-1',
      endpoint: '',
      requirepass: 'demopass-1',
      extraFlags: [
        FlagKV(key: 'max-clients', value: '256'),
        FlagKV(key: 'latency-trace', value: 'off'),
      ],
    );

InstanceStatus fixtureStatus() => InstanceStatus(
      id: 'c1',
      status: 'running',
      pid: 48211,
      port: 6379,
      uptimeSec: 8040, // mockup console toolbar: "已连接 2h 14m"
      exitMsg: '',
      autoRestart: true,
      cpuPercent: 12.4,
      // v2.3 mockup (inst-monitor): MEMORY 412 MB · OPS/SEC 1,208. 412 MB is
      // 1024-based (main.dart divides by 1024²), so seed 412×1024×1024.
      memBytes: 432013312,
      runMode: 'native',
      metricsOk: true,
      healthy: true,
      ready: true,
      opsPerSec: 1208,
      // Mockup's Latency p99 tile shows "0.4 ms"; main.dart rounds the value
      // to one decimal, so 0.4 renders exactly the mockup text.
      avgLatencyMs: 0.4,
      throttled: 3,
    );

/// A deterministic wave so the sparklines look alive without randomness.
List<double> fixtureHist(double base, double amp, double phase) =>
    List<double>.generate(60, (i) {
      final v = base + amp * math.sin(i * 0.32 + phase) + (i % 7) * amp * 0.06;
      return v < 0 ? 0 : v;
    });

/// v2.3 mockup sparkline shapes (inst-monitor svg path points, inverted so
/// higher = more). The capture channel seeds the design's exact zigzag; the
/// golden channel mirrors it (pixel-fidelity-v23 CP 9.x).
const mockSparkCpu = <double>[
  14,
  18,
  16,
  26,
  22,
  34,
  28,
  32,
  24,
  36,
  30,
  38,
  32,
  40,
  34,
  37
];
const mockSparkMem = <double>[
  12,
  13,
  15,
  14,
  18,
  17,
  20,
  19,
  22,
  21,
  24,
  23,
  26,
  25,
  27,
  28
];
const mockSparkOps = <double>[
  22,
  16,
  30,
  18,
  34,
  22,
  40,
  26,
  32,
  18,
  36,
  24,
  38,
  28,
  42,
  30
];

// ---------------------------------------------------------------------------
// Service fixtures (stage 16.1 capture channel).
// ---------------------------------------------------------------------------

/// The capture channel's Service: java engine on the design's port 8000.
/// startedAt is seeded RELATIVE to now because the Overview computes its
/// uptime against DateTime.now() — a static timestamp would paint a
/// run-dependent label; the relative seed freezes the label at '2h 14m'
/// (30 s headroom before the minute rolls, far beyond one capture run).
ServiceInfo fixtureServiceRunning() => ServiceInfo.fromJson({
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
        'startedAt': DateTime.now()
            .subtract(const Duration(hours: 2, minutes: 14, seconds: 30))
            .toUtc()
            .toIso8601String(),
        'metrics': {
          'cpuPercent': 18.4,
          'memBytes': 432013312, // 412 MB, the mockup instance-monitor value
          'diskBytesPerSec': 812,
        },
      },
    });

/// A lifecycle failure: in-context error surface (9.8), identity still
/// readable, start available again from the failed state (9.7).
ServiceInfo fixtureServiceFailed() => ServiceInfo.fromJson({
      'config': {
        'id': 'svc-1',
        'name': 'local-ddb',
        'engine': 'java',
        'port': 8000,
      },
      'runtime': {
        'state': 'failed',
        'ready': false,
        'healthy': false,
        'errorCode': 'port_in_use',
        'error': 'bind tcp 0.0.0.0:8000: address already in use',
      },
    });

/// Deterministic waves for the Service monitor's three rings — the same
/// sin-based shapes the instance sparklines use (fixtureHist), no randomness.
ServiceHistory fixtureServiceHistory() {
  final h = ServiceHistory(ServiceHistory.defaultCapacity);
  for (var i = 0; i < 60; i++) {
    final cpu = 18 + 8 * math.sin(i * 0.32 + 0.9) + (i % 7) * 0.4;
    final memMb = 400 + 24 * math.sin(i * 0.21 + 2.1) + (i % 5) * 2.0;
    final disk = 700 + 260 * math.sin(i * 0.27 + 4.2) + (i % 9) * 12.0;
    h.sample(ServiceMetrics(
      cpuPercent: cpu < 0 ? 0 : cpu,
      memBytes: (memMb * 1024 * 1024).round(),
      diskBytesPerSec: disk < 0 ? 0 : disk,
    ));
  }
  return h;
}

/// Capture-side core for the Service screens: deterministic log lines; every
/// other Service API trips FakeNativeCore's loud noSuchMethod.
class CaptureServiceCore extends FakeNativeCore {
  @override
  List<String> serviceLogs(String id) => const [
        '2026-08-14T12:00:00.204Z INFO  ddb-local: starting engine on port 8000',
        '2026-08-14T12:00:00.512Z INFO  ddb-local: storage mode=memory (shared: false)',
        '2026-08-14T12:00:01.118Z INFO  ddb-local: loaded 0 tables from previous session',
        '2026-08-14T12:00:01.402Z INFO  http: listening on 0.0.0.0:8000',
        '2026-08-14T12:00:02.007Z INFO  health: readiness probe ok',
        '2026-08-14T12:00:02.031Z INFO  health: liveness probe ok',
        '2026-08-14T12:00:04.552Z INFO  request CreateTable users → 200 · 14 ms',
        '2026-08-14T12:00:06.918Z INFO  request PutItem users → 200 · 3 ms',
        '2026-08-14T12:00:09.114Z WARN  slow request Query users 214 ms · index byEmail',
        '2026-08-14T12:00:12.690Z INFO  compaction: 0 tables pending · disk idle',
      ];
}

// ---------------------------------------------------------------------------
// Per-screen pump sequences — mirror golden_screens_test.dart bodies.
// ---------------------------------------------------------------------------

Future<void> pumpInstBrowse(WidgetTester t,
    {required bool dark, Key? shotKey, Widget Function(Widget)? chrome}) async {
  await pumpScreen(t,
      dark: dark,
      shotKey: shotKey,
      chrome: chrome,
      child: BrowserPageView(
          config: fixtureConfig(), running: true, core: fakeCore));
  await t.pump(const Duration(milliseconds: 50));
}

Future<void> pumpInstConsole(WidgetTester t,
    {required bool dark, Key? shotKey, Widget Function(Widget)? chrome}) async {
  await pumpScreen(t,
      dark: dark,
      shotKey: shotKey,
      chrome: chrome,
      child: const CmdConsole(host: '127.0.0.1', port: 6379, running: true));
  await t.pump(const Duration(milliseconds: 50));
}

// ---------------------------------------------------------------------------
// Data-loaded-state pumps (task #50 / pixel capture only).
//
// BrowserPageView / CmdConsole / CliDrawer open REAL RESP sockets, so these
// pumps run against test/fake_resp_server.dart and reproduce the v2.3
// mockup's loaded state (keys scanned, user:1001 hash tab open, CLI drawer
// with history; console with the mockup's command history).
//
// Every gesture that triggers socket I/O is dispatched inside t.runAsync —
// the clients await reply-per-command on real sockets, which would stall
// forever in the FakeAsync zone. Real replies land as fake-zone microtasks,
// flushed by the t.pump() that follows each drain.
//
// Known mockup divergences these pumps deliberately do NOT chase (they are
// data/design decorations with no app-side command behind them; recorded in
// the baseline report): sidebar counts 375 vs mockup 1,024 ("375 keys+"),
// alphabetical folder order (cache first, not user), folder labels without
// the ':*' suffix, nested folders for multi-segment keys, keycard has no
// Encoding row, drawer/console elapsed shows integer ms (Stopwatch) not the
// mockup's decimals, console shows 3 history commands (KEYS * would flood
// the stream with 375 lines vs the mockup's folded summary).
// ---------------------------------------------------------------------------

/// Real-async idle window: lets in-flight socket replies arrive, then one
/// pump flushes the queued continuations and rebuilds.
Future<void> _drainIO(WidgetTester t,
    {Duration wait = const Duration(milliseconds: 120)}) async {
  await t.runAsync(() => Future<void>.delayed(wait));
  await t.pump();
}

/// Same fixture config pointed at the fake server (separate declaration keeps
/// the golden-side fixtureConfig() untouched).
Future<void> pumpInstBrowseLoaded(WidgetTester t,
    {required bool dark,
    Key? shotKey,
    required FakeRespServer server,
    Widget Function(Widget)? chrome}) async {
  await pumpScreen(t,
      dark: dark,
      shotKey: shotKey,
      chrome: chrome,
      child: BrowserPageView(
          config: fixtureConfigAt(server.port), running: true, core: fakeCore));

  // 1) connect + initial SCAN — poll until the namespace tree renders.
  var scanned = false;
  for (var i = 0; i < 50 && !scanned; i++) {
    await _drainIO(t, wait: const Duration(milliseconds: 60));
    scanned = find.text('cache').evaluate().isNotEmpty;
  }
  if (!scanned) {
    fail('pumpInstBrowseLoaded: SCAN page never rendered (fake server)');
  }

  // 2) DB picker → DB3 (mockup shows db3): SELECT 3 + a fresh SCAN. The
  //    menu route needs frame pumps to build its items before DB3 is tappable.
  await t.runAsync(() => t.tap(find.byType(CodexSelectField<int>)));
  await t.pump();
  await t.pump(const Duration(milliseconds: 200)); // menu enter animation
  await t.runAsync(() async {
    await t.tap(find.text('DB3').last);
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });
  await t.pump();
  await t.pump(const Duration(milliseconds: 350)); // menu route closes
  await t.pump(const Duration(milliseconds: 50));

  // 3) Folders default OPEN and the tree is alphabetical: the mockup's tree
  //    fits on one screen, but alphabetically the user:* folder (the
  //    mockup's star) lands BELOW the fold once every other folder is
  //    expanded. Collapse everything except queue (its leaf must stay
  //    tappable for the second tab) so the open user folder + leaves render
  //    in view.
  for (final folder in const [
    'cache',
    'config',
    'events',
    'leaderboard',
    'session',
    'tags',
  ]) {
    await t.tap(find.text(folder).first);
    await t.pump();
  }

  // 4) Open user:1001 (hash tab: TYPE → TTL → HLEN → HSCAN), then
  //    queue:email_jobs as the second tab (mockup ktabs), then reactivate
  //    user:1001 (leaf taps dedupe to tab activation).
  await t.runAsync(() async {
    await t.tap(find.text('user:1001').first);
    await Future<void>.delayed(const Duration(milliseconds: 250));
  });
  await t.pump();
  await t.runAsync(() async {
    await t.tap(find.text('queue:email_jobs').first);
    await Future<void>.delayed(const Duration(milliseconds: 250));
  });
  await t.pump();
  await t.tap(find.text('user:1001').first);
  await t.pump();

  // 5) CLI drawer: open the CLI tab (lazy connect). The drawer body only
  //    mounts when _open (cli_drawer.dart `if (_open)`), so pump a frame
  //    between the tap and the first enterText — the TextField doesn't exist
  //    until the rebuild lands.
  await t.runAsync(() async {
    await t.tap(find.text('>_ CLI'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
  final drawerField = find.byWidgetPredicate(
      (w) => w is TextField && (w.decoration?.hintText ?? '') == 'GET key …');
  await t.runAsync(() async {
    await t.enterText(drawerField, 'HGETALL user:1001');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await t.enterText(drawerField, 'TTL user:1001');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await t.enterText(drawerField, 'HGET user:1001 name');
  });
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
}

Future<void> pumpInstConsoleLoaded(WidgetTester t,
    {required bool dark,
    Key? shotKey,
    required FakeRespServer server,
    Widget Function(Widget)? chrome}) async {
  await pumpScreen(t,
      dark: dark,
      shotKey: shotKey,
      chrome: chrome,
      child: CmdConsole(
          host: '127.0.0.1',
          port: server.port,
          running: true,
          // v2.3 mockup .inst-crumb / .empty-note copy, seeded (capture-only
          // pump; the golden channel's pumpInstConsole keeps the defaults).
          instanceName: 'prod-redis-01',
          connectedLabel: '2h 14m',
          initialDb: 3));

  // 1) connect — the welcome banner ('redimos-cli') replaces the spinner.
  var connected = false;
  for (var i = 0; i < 50 && !connected; i++) {
    await _drainIO(t, wait: const Duration(milliseconds: 60));
    connected = find.text('redimos-cli').evaluate().isNotEmpty;
  }
  if (!connected) {
    fail('pumpInstConsoleLoaded: console never connected (fake server)');
  }

  // 2) The mockup's command history (minus KEYS * — see divergence notes).
  final field = find.descendant(
      of: find.byType(CmdConsole), matching: find.byType(TextField));
  await t.tap(field);
  await t.pump();
  for (final cmd in const [
    'HGETALL user:1001',
    'SET session:token:9f3a "e81c…d2" EX 3600',
    'MEMORY USAGE user:1001',
  ]) {
    await t.runAsync(() async {
      await t.enterText(field, cmd);
      await t.testTextInput.receiveAction(TextInputAction.done);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await t.pump();
  }

  // 3) Leave the next command half-typed, like the mockup's input row.
  await t.enterText(field, 'HGET user:1001 ');
  await t.pump();
}

Future<void> pumpInstMonitor(WidgetTester t,
    {required bool dark, Key? shotKey, Widget Function(Widget)? chrome}) async {
  await pumpScreen(t,
      dark: dark,
      shotKey: shotKey,
      chrome: chrome,
      child: MonitorView(
        status: fixtureStatus(),
        cpuHist: mockSparkCpu,
        memHist: mockSparkMem,
        opsHist: mockSparkOps,
        embedded: true,
        instanceName: 'prod-redis-01',
      ));
  await t.pump(const Duration(milliseconds: 50));
}

/// NOTE: LogsPage runs a 1200ms periodic timer — callers must
/// `await t.pumpWidget(const SizedBox())` once the capture/assert is done.
Future<void> pumpInstLogs(WidgetTester t,
    {required bool dark, Key? shotKey, Widget Function(Widget)? chrome}) async {
  await pumpScreen(t,
      dark: dark,
      shotKey: shotKey,
      chrome: chrome,
      child: LogsPage(core: fakeCore, configId: 'c1'));
  await t.pump(const Duration(milliseconds: 50));
}

Future<void> pumpInstPlayground(WidgetTester t,
    {required bool dark, Key? shotKey, Widget Function(Widget)? chrome}) async {
  await pumpScreen(t,
      dark: dark,
      shotKey: shotKey,
      chrome: chrome,
      child: PlaygroundView(
          core: fakeCore,
          config: fixtureConfig(),
          kind: 'redis',
          running: true));
  await t.pump(const Duration(milliseconds: 50));
}

Future<void> pumpInstConfig(WidgetTester t,
    {required bool dark, Key? shotKey, Widget Function(Widget)? chrome}) async {
  await pumpScreen(t,
      dark: dark,
      shotKey: shotKey,
      chrome: chrome,
      child: ConfigEditor(
        config: fixtureConfig(),
        onSave: (_) async {},
        onDelete: (_) async {},
      ));
  await t.pump(const Duration(milliseconds: 50));
}

Future<void> pumpEpConfig(WidgetTester t,
    {required bool dark, Key? shotKey, Widget Function(Widget)? chrome}) async {
  await pumpScreen(t,
      dark: dark,
      shotKey: shotKey,
      chrome: chrome,
      child: EndpointConfigPane(
        endpoint: fixtureEndpoint,
        onSave: (_) async {},
        onDelete: () async {},
      ));
  await t.pump();
  await t.pump();
}

Future<void> pumpEpBrowser(WidgetTester t,
    {required bool dark, Key? shotKey, Widget Function(Widget)? chrome}) async {
  await pumpScreen(t,
      dark: dark,
      shotKey: shotKey,
      chrome: chrome,
      child: EndpointTablesView(
        core: fakeCore,
        config: fixtureEndpoint.toStorageConfig(),
        endpoint: fixtureEndpoint,
      ));
  await t.pump(const Duration(milliseconds: 50)); // epListTables resolves
  await t.pump();
}

// ---------------------------------------------------------------------------
// Service screen pumps (stage 16.1 capture channel). The four Service tabs
// are pure widgets over (ServiceInfo, ServicesState) — no sockets — so the
// pumps only need the FakeAsync zero-timer order for the Logs fetch.
// ---------------------------------------------------------------------------

/// No Services registered: HomePage's detail pane shows the pick hint while
/// the sidebar renders the empty Service list.
Future<void> pumpSvcEmpty(WidgetTester t,
    {required bool dark, Key? shotKey, Widget Function(Widget)? chrome}) async {
  await pumpScreen(t,
      dark: dark,
      shotKey: shotKey,
      chrome: chrome,
      child: Center(child: Text(tr('service.pick'))));
  await t.pump(const Duration(milliseconds: 50));
}

/// v1.2: Overview is gone — a lifecycle failure now surfaces as the Monitor
/// tab's dismissible error banner (requirement 8.2).
Future<void> pumpSvcMonitorError(WidgetTester t,
    {required bool dark, Key? shotKey, Widget Function(Widget)? chrome}) async {
  await pumpScreen(t,
      dark: dark,
      shotKey: shotKey,
      chrome: chrome,
      child: ServiceMonitorTab(
        service: fixtureServiceFailed(),
        history: ServiceHistory(0), // no samples yet — tiles render '—'
      ));
  await t.pump(const Duration(milliseconds: 50));
}

Future<void> pumpSvcMonitor(WidgetTester t,
    {required bool dark, Key? shotKey, Widget Function(Widget)? chrome}) async {
  await pumpScreen(t,
      dark: dark,
      shotKey: shotKey,
      chrome: chrome,
      child: ServiceMonitorTab(
        service: fixtureServiceRunning(),
        history: fixtureServiceHistory(),
      ));
  await t.pump(const Duration(milliseconds: 50));
}

/// requestLogs() hides behind a zero-duration Future (FakeAsync): fire the
/// timer, let the continuation land, then rebuild. The scripted core returns
/// deterministic lines, so the tail is stable run-to-run.
Future<void> pumpSvcLogs(WidgetTester t,
    {required bool dark, Key? shotKey, Widget Function(Widget)? chrome}) async {
  final state = ServicesState(CaptureServiceCore());
  addTearDown(state.dispose);
  state.select('svc-1'); // requestLogs only lands for the selected ID (12.4)
  await pumpScreen(t,
      dark: dark,
      shotKey: shotKey,
      chrome: chrome,
      child: ServiceLogsTab(
        service: fixtureServiceRunning(),
        state: state,
      ));
  await t.pump();
  await t.pump(const Duration(milliseconds: 1)); // fire the zero-timer fetch
  await t.pump();
}

Future<void> pumpSvcConfig(WidgetTester t,
    {required bool dark, Key? shotKey, Widget Function(Widget)? chrome}) async {
  await pumpScreen(t,
      dark: dark,
      shotKey: shotKey,
      chrome: chrome,
      child: ServiceConfigEditor(
        service: fixtureServiceRunning(),
        peers: const [],
        core: fakeCore,
        onSaved: (_) {},
        onDeleted: (_) {},
      ));
  await t.pump(const Duration(milliseconds: 50));
}
