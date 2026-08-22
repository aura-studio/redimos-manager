// pixel-fidelity-v23 (CP 2.3–2.7, task #50, CP 9.x chrome wrap) — independent
// capture channel for the pixel-diff pipeline (tool/pixel-diff/). Renders the
// same 8 screens with the same fixtures and pump sequences as
// golden_screens_test.dart (via screen_fixtures.dart) and writes PNGs for
// tool/pixel-diff/diff.js; stage 16.1 adds 6 Service-entity candidates
// (empty / Overview running / Overview failed / Monitor / Logs / Configure)
// that have no golden counterpart — capture-only deterministic fixtures. The
// golden assertions themselves are untouched.
//
// CP 9.x: captures are wrapped in the app's REAL chrome (HomeChrome — rail /
// entity sidebar / top bar / mid bar / status bar) so the full-frame PNGs can
// be diffed against the full-frame mockups. The mockup sidebar lists two
// instance cards and four endpoint cards, so the capture channel adds the
// extra cards as capture-only fixtures below (the golden fixtures stay
// untouched). Known accepted divergences from the mockups (recorded in
// out/convergence-plan.md): status bar right side ('db0 · redimos' vs the
// mockup's SCAN/keys/latency cluster), endpoint card sub-lines (':port ·
// AWS/host' vs the mockup's 'host:port', no item counts).
//
// Why fixed pump sequences instead of pumpAndSettle: LogsPage runs a 1200ms
// periodic timer, so pumpAndSettle would never settle; the fixture pumps are
// the proven-stable settle points the goldens already rely on.
//
// inst-browse / inst-console additionally run against the fake RESP server
// (test/fake_resp_server.dart) so they capture the mockup's DATA-LOADED state
// instead of "Connecting…" — BrowserPageView/CmdConsole/CliDrawer open real
// sockets, and everything socket-driven is pumped inside t.runAsync there.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/home_chrome.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';

import 'fake_resp_server.dart';
import 'screen_fixtures.dart' as fx;

typedef ScreenPump = Future<void> Function(WidgetTester,
    {required bool dark, Key? shotKey, Widget Function(Widget)? chrome});

typedef LoadedScreenPump = Future<void> Function(WidgetTester,
    {required bool dark,
    Key? shotKey,
    required FakeRespServer server,
    Widget Function(Widget)? chrome});

Future<Uint8List> _boundaryPng(WidgetTester t, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  // toImage/toByteData are REAL async work on the raster thread. They must
  // run outside the FakeAsync zone via runAsync — the same pattern the
  // golden matchers use (flutter_test/src/_matchers_io.dart); a bare await
  // inside FakeAsync stalls for minutes per screen.
  final bytes = await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

Directory _captureDirectory() {
  final configured = Platform.environment['REDIMOS_CAPTURE_DIR'];
  if (configured == null || configured.trim().isEmpty) {
    throw StateError(
      'REDIMOS_CAPTURE_DIR is required; use tool/pixel-diff/capture-flutter.sh',
    );
  }
  final dir = Directory(configured).absolute;
  final segments = dir.path.split(Platform.pathSeparator);
  if (segments.contains('references') || segments.contains('v2.3-archive')) {
    throw StateError(
        'Capture output must not target references or v2.3-archive');
  }
  if (!dir.existsSync()) {
    throw StateError('Capture run directory does not exist: ${dir.path}');
  }
  return dir;
}

void _writePng(String name, bool dark, Uint8List bytes) {
  final theme = dark ? 'dark' : 'light';
  final file = File('${_captureDirectory().path}/$name-$theme.png');
  if (file.existsSync()) {
    throw StateError('Refusing to overwrite capture: ${file.path}');
  }
  file.writeAsBytesSync(bytes, flush: true);
}

/// Pump one screen through [pump], grab the RepaintBoundary identified by
/// [shotKey], and write `<screen>-<theme>.png` at 2560×1600 into the explicit
/// run directory created by capture-flutter.sh.
Future<void> _capture(
  WidgetTester t,
  String name,
  bool dark,
  ScreenPump pump, {
  Widget Function(Widget)? chrome,
  Future<void> Function(WidgetTester)? after,
}) async {
  final key = GlobalKey();
  await pump(t, dark: dark, shotKey: key, chrome: chrome);
  _writePng(name, dark, await _boundaryPng(t, key));
  if (after != null) await after(t);
}

/// Same, but the screen talks to a fake RESP server (task #50). Teardown
/// order matters: dispose the widget tree FIRST (cancels reconnect timers,
/// closes the client sockets) and only then close the server — closing the
/// server while the widgets live would fire onClosed and schedule a
/// reconnect Timer inside the FakeAsync zone, failing the test.
Future<void> _captureLoaded(
  WidgetTester t,
  String name,
  bool dark,
  LoadedScreenPump pump, {
  Widget Function(Widget)? chrome,
}) async {
  final server = FakeRespServer();
  await t.runAsync(server.start);
  final key = GlobalKey();
  try {
    await pump(
      t,
      dark: dark,
      shotKey: key,
      server: server,
      chrome: chrome,
    );
    _writePng(name, dark, await _boundaryPng(t, key));
  } finally {
    await t.pumpWidget(const SizedBox());
    await t.runAsync(server.close);
  }
}

// ---------------------------------------------------------------------------
// CP 9.x — capture-channel chrome (the app's real HomeChrome around the
// content screens). Fixture data mirrors the mockup sidebar population:
// two instance cards, four endpoint cards.
// ---------------------------------------------------------------------------

/// Second instance card (mockup's dev-redis-02). No status entry → grey dot
/// + 'stopped', exactly like the mockup's stopped second instance.
final _captureConfig2 =
    RedimosConfig(id: 'c2', name: 'dev-redis-02', port: 6380, endpoint: '');

/// Extra endpoint cards (mockup sidebar rows 2–4).
const _captureEpStaging = DdbEndpoint(
    id: 'e2', name: 'staging-aws', kind: 'aws', region: 'us-east-1');
const _captureEpAnalytics = DdbEndpoint(
    id: 'e3',
    name: 'analytics-cache',
    kind: 'url',
    endpoint: 'redis://10.0.4.21:6380');
const _captureEpLegacy = DdbEndpoint(
    id: 'e4',
    name: 'legacy-cluster',
    kind: 'url',
    endpoint: 'redis://10.0.1.7:6379');

/// Second Service card (stage 16.1): a stopped localstack engine, so the
/// Service sidebar capture shows one live and one cold card side by side.
ServiceInfo _captureSvcLocalstack() => ServiceInfo.fromJson({
      'config': {
        'id': 'svc-2',
        'name': 'localstack-core',
        'engine': 'localstack',
        'port': 4566,
      },
      'runtime': {'state': 'stopped'},
    });

// No-op callbacks: the capture channel never taps the chrome.
void _noopEntityKind(EntityKind k) {}
void _noopSelectConfig(RedimosConfig c) {}
void _noopSelectEndpoint(String id) {}
void _noopHover(String? id) {}
void _noopQuery(String q) {}
void _noopStartStop(RedimosConfig c) {}
void _noopInt(int i) {}
void _noopLang(AppLang l) {}
void _noop() {}

const _captureCb = ChromeCallbacks(
  onEntityKind: _noopEntityKind,
  onSelectConfig: _noopSelectConfig,
  onSelectEndpoint: _noopSelectEndpoint,
  onHoverCard: _noopHover,
  onQueryChanged: _noopQuery,
  onNewConfig: _noop,
  onMidTab: _noopInt,
  onStartStop: _noopStartStop,
  onStopAll: _noop,
  onRestoreAll: _noop,
  onLang: _noopLang,
);

List<String> get _instTabLabels => [
      tr('ep.browse'), // mockup instance tab reads 'Browse', endpoint 'Browser'
      tr('tab.console'),
      tr('tab.monitor'),
      tr('tab.logs'),
      tr('tab.playground'),
      tr('tab.configure'),
    ];

List<String> get _epTabLabels => [
      tr('tab.configure'),
      tr('tab.endpoint'),
      tr('tab.table'),
    ];

/// v1.2: mirrors HomePage._serviceTabKeys — the Service detail's three
/// fixed screens (Overview was removed).
List<String> get _serviceTabLabels => [
      tr('tab.monitor'),
      tr('tab.logs'),
      tr('tab.configure'),
    ];

/// Build the chrome wrapper for one capture. Instance screens: the selected
/// instance card (c1) + its MidBar index. Endpoint screens: the selected
/// endpoint (e1) + its screen index. Service screens (stage 16.1): the
/// selected Service card (svc-1) + its tab index.
Widget Function(Widget) _captureChrome({
  required bool dark,
  required EntityKind kind,
  required List<String> tabLabels,
  required int tabIndex,
  String? selectedConfigId = 'c1',
  String? selectedEndpointId,
  List<ServiceInfo> services = const [],
  String? selectedServiceId,
  Widget? midBarCta,
}) {
  return (content) => HomeChrome(
        state: ChromeState(
          entityKind: kind,
          configs: [fx.fixtureConfig(), _captureConfig2],
          endpoints: const [
            fx.fixtureEndpoint,
            _captureEpStaging,
            _captureEpAnalytics,
            _captureEpLegacy,
          ],
          statuses: {'c1': fx.fixtureStatus()},
          selectedConfigId: selectedConfigId,
          selectedEndpointId: selectedEndpointId,
          services: services,
          selectedServiceId: selectedServiceId,
          hoveredCardId: null,
          entityQuery: '',
          tabLabels: tabLabels,
          tabIndex: tabIndex,
          stopAllSnapshot: const [],
          lang: AppLang.en,
        ),
        cb: _captureCb,
        midBarCta: midBarCta,
        child: content,
      );
}

/// The mid-bar CTA needs a context for its tokens — the chrome is built as a
/// closure over the content, so wrap the CTA in a Builder.
Widget _cta(IconData icon, String label) =>
    Builder(builder: (context) => chromeCta(context, icon, label, () {}));

void main() {
  for (final dark in [false, true]) {
    final theme = dark ? 'dark' : 'light';

    testWidgets(
      'capture inst-browse $theme',
      (t) => _captureLoaded(
        t,
        'inst-browse',
        dark,
        fx.pumpInstBrowseLoaded,
        chrome: _captureChrome(
          dark: dark,
          kind: EntityKind.instance,
          tabLabels: _instTabLabels,
          tabIndex: 0,
          midBarCta: _cta(Icons.add, tr('br.newKey')),
        ),
      ),
    );

    testWidgets(
      'capture inst-console $theme',
      (t) => _captureLoaded(
        t,
        'inst-console',
        dark,
        fx.pumpInstConsoleLoaded,
        chrome: _captureChrome(
          dark: dark,
          kind: EntityKind.instance,
          tabLabels: _instTabLabels,
          tabIndex: 1,
        ),
      ),
    );

    testWidgets(
      'capture inst-monitor $theme',
      (t) => _capture(
        t,
        'inst-monitor',
        dark,
        fx.pumpInstMonitor,
        chrome: _captureChrome(
          dark: dark,
          kind: EntityKind.instance,
          tabLabels: _instTabLabels,
          tabIndex: 2,
        ),
      ),
    );

    testWidgets(
      'capture inst-logs $theme',
      (t) => _capture(
        t,
        'inst-logs',
        dark,
        fx.pumpInstLogs,
        chrome: _captureChrome(
          dark: dark,
          kind: EntityKind.instance,
          tabLabels: _instTabLabels,
          tabIndex: 3,
        ),
        // Drop LogsPage's periodic timer once the PNG is written.
        after: (t) => t.pumpWidget(const SizedBox()),
      ),
    );

    testWidgets(
      'capture inst-playground $theme',
      (t) => _capture(
        t,
        'inst-playground',
        dark,
        fx.pumpInstPlayground,
        chrome: _captureChrome(
          dark: dark,
          kind: EntityKind.instance,
          tabLabels: _instTabLabels,
          tabIndex: 4,
        ),
      ),
    );

    testWidgets(
      'capture inst-config $theme',
      (t) => _capture(
        t,
        'inst-config',
        dark,
        fx.pumpInstConfig,
        chrome: _captureChrome(
          dark: dark,
          kind: EntityKind.instance,
          tabLabels: _instTabLabels,
          tabIndex: 5,
        ),
      ),
    );

    testWidgets(
      'capture ep-config $theme',
      (t) => _capture(
        t,
        'ep-config',
        dark,
        fx.pumpEpConfig,
        chrome: _captureChrome(
          dark: dark,
          kind: EntityKind.endpoint,
          tabLabels: _epTabLabels,
          tabIndex: 0,
          selectedConfigId: null,
          selectedEndpointId: 'e1',
        ),
      ),
    );

    testWidgets(
      'capture ep-browser $theme',
      (t) => _capture(
        t,
        'ep-browser',
        dark,
        fx.pumpEpBrowser,
        chrome: _captureChrome(
          dark: dark,
          kind: EntityKind.endpoint,
          tabLabels: _epTabLabels,
          tabIndex: 1,
          selectedConfigId: null,
          selectedEndpointId: 'e1',
          midBarCta: _cta(Icons.add, 'Item'),
        ),
      ),
    );

    // Stage 16.1: Service entity candidates — empty list, Overview in the
    // running and failed lifecycle states, Monitor, Logs, Configure.
    testWidgets(
      'capture svc-empty $theme',
      (t) => _capture(
        t,
        'svc-empty',
        dark,
        fx.pumpSvcEmpty,
        chrome: _captureChrome(
          dark: dark,
          kind: EntityKind.service,
          tabLabels: _serviceTabLabels,
          tabIndex: 0,
          selectedConfigId: null,
          selectedEndpointId: null,
        ),
      ),
    );

    testWidgets(
      'capture svc-monitor-error $theme',
      (t) => _capture(
        t,
        'svc-monitor-error',
        dark,
        fx.pumpSvcMonitorError,
        chrome: _captureChrome(
          dark: dark,
          kind: EntityKind.service,
          tabLabels: _serviceTabLabels,
          tabIndex: 0,
          selectedConfigId: null,
          selectedEndpointId: null,
          services: [fx.fixtureServiceFailed(), _captureSvcLocalstack()],
          selectedServiceId: 'svc-1',
        ),
      ),
    );

    testWidgets(
      'capture svc-monitor $theme',
      (t) => _capture(
        t,
        'svc-monitor',
        dark,
        fx.pumpSvcMonitor,
        chrome: _captureChrome(
          dark: dark,
          kind: EntityKind.service,
          tabLabels: _serviceTabLabels,
          tabIndex: 0,
          selectedConfigId: null,
          selectedEndpointId: null,
          services: [fx.fixtureServiceRunning(), _captureSvcLocalstack()],
          selectedServiceId: 'svc-1',
        ),
      ),
    );

    testWidgets(
      'capture svc-logs $theme',
      (t) => _capture(
        t,
        'svc-logs',
        dark,
        fx.pumpSvcLogs,
        chrome: _captureChrome(
          dark: dark,
          kind: EntityKind.service,
          tabLabels: _serviceTabLabels,
          tabIndex: 1,
          selectedConfigId: null,
          selectedEndpointId: null,
          services: [fx.fixtureServiceRunning(), _captureSvcLocalstack()],
          selectedServiceId: 'svc-1',
        ),
      ),
    );

    testWidgets(
      'capture svc-configure $theme',
      (t) => _capture(
        t,
        'svc-configure',
        dark,
        fx.pumpSvcConfig,
        chrome: _captureChrome(
          dark: dark,
          kind: EntityKind.service,
          tabLabels: _serviceTabLabels,
          tabIndex: 2,
          selectedConfigId: null,
          selectedEndpointId: null,
          services: [fx.fixtureServiceRunning(), _captureSvcLocalstack()],
          selectedServiceId: 'svc-1',
        ),
      ),
    );
  }
}
