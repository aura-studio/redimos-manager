// pixel-fidelity-v23 (CP 2.3–2.7, task #50, CP 9.x chrome wrap) — independent
// capture channel for the pixel-diff pipeline (tool/pixel-diff/). Renders the
// same 8 screens with the same fixtures and pump sequences as
// golden_screens_test.dart (via screen_fixtures.dart) and writes PNGs for
// tool/pixel-diff/diff.js. The golden assertions themselves are untouched.
//
// CP 9.x: captures are wrapped in the app's REAL chrome (HomeChrome — rail /
// entity sidebar / top bar / mid bar / status bar) so the full-frame PNGs can
// be diffed against the full-frame mockups. The mockup sidebar lists two
// instance cards and four endpoint cards, so the capture channel adds the
// extra cards as capture-only fixtures below (the golden fixtures stay
// untouched). Known accepted divergences from the mockups (recorded in
// out/convergence-plan.md): status bar right side ('db0 · redimos' vs the
// mockup's SCAN/keys/latency cluster), endpoint card sub-lines (':port ·
// AWS/host' vs the mockup's 'host:port', no item counts), and the LocalDdbPanel
// dock row
// (post-mockup product feature).
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

void _writePng(String name, Uint8List bytes) {
  final dir = Directory('tool/pixel-diff/out/flutter');
  dir.createSync(recursive: true);
  File('${dir.path}/$name.png').writeAsBytesSync(bytes);
}

/// Pump one screen through [pump], grab the RepaintBoundary identified by
/// [shotKey] and write `tool/pixel-diff/out/flutter/<name>.png` at 2560×1600
/// (pixelRatio 2 over the 1280×800 logical view — same as the goldens).
Future<void> _capture(WidgetTester t, String name, ScreenPump pump,
    {Widget Function(Widget)? chrome,
    Future<void> Function(WidgetTester)? after}) async {
  final key = GlobalKey();
  await pump(t, dark: false, shotKey: key, chrome: chrome);
  _writePng(name, await _boundaryPng(t, key));
  if (after != null) await after(t);
}

/// Same, but the screen talks to a fake RESP server (task #50). Teardown
/// order matters: dispose the widget tree FIRST (cancels reconnect timers,
/// closes the client sockets) and only then close the server — closing the
/// server while the widgets live would fire onClosed and schedule a
/// reconnect Timer inside the FakeAsync zone, failing the test.
Future<void> _captureLoaded(WidgetTester t, String name, LoadedScreenPump pump,
    {Widget Function(Widget)? chrome}) async {
  final server = FakeRespServer();
  await t.runAsync(server.start);
  final key = GlobalKey();
  try {
    await pump(t, dark: false, shotKey: key, server: server, chrome: chrome);
    _writePng(name, await _boundaryPng(t, key));
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
const _captureEpStaging =
    DdbEndpoint(id: 'e2', name: 'staging-aws', kind: 'aws', region: 'us-east-1');
const _captureEpAnalytics = DdbEndpoint(
    id: 'e3', name: 'analytics-cache', kind: 'url', endpoint: 'redis://10.0.4.21:6380');
const _captureEpLegacy = DdbEndpoint(
    id: 'e4', name: 'legacy-cluster', kind: 'url', endpoint: 'redis://10.0.1.7:6379');

// No-op callbacks: the capture channel never taps the chrome.
void _noopEntityKind(EntityKind k) {}
void _noopSelectConfig(RedimosConfig c) {}
void _noopSelectEndpoint(String id) {}
void _noopHover(String? id) {}
void _noopQuery(String q) {}
void _noopStartStop(RedimosConfig c) {}
void _noopInt(int i) {}
void _noopThemeMode(ThemeMode m) {}
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
  onThemeMode: _noopThemeMode,
  onLang: _noopLang,
  onDdbMutated: _noop,
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
      tr('tab.overview'),
      tr('tab.browser'),
      tr('tab.partiql'),
      tr('tab.playground'),
    ];

/// Build the chrome wrapper for one capture. Instance screens: the selected
/// instance card (c1) + its MidBar index. Endpoint screens: the selected
/// endpoint (e1) + its screen index.
Widget Function(Widget) _captureChrome({
  required EntityKind kind,
  required List<String> tabLabels,
  required int tabIndex,
  String? selectedConfigId = 'c1',
  String? selectedEndpointId,
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
          hoveredCardId: null,
          entityQuery: '',
          tabLabels: tabLabels,
          tabIndex: tabIndex,
          stopAllSnapshot: const [],
          ddb: null, // collapsed dock row (mockups predate this feature)
          themeMode: ThemeMode.light,
          lang: AppLang.en,
        ),
        cb: _captureCb,
        core: fx.fakeCore,
        midBarCta: midBarCta,
        child: content,
      );
}

/// The mid-bar CTA needs a context for its tokens — the chrome is built as a
/// closure over the content, so wrap the CTA in a Builder.
Widget _cta(IconData icon, String label) =>
    Builder(builder: (context) => chromeCta(context, icon, label, () {}));

void main() {
  testWidgets('capture inst-browse',
      (t) => _captureLoaded(t, 'inst-browse', fx.pumpInstBrowseLoaded,
          chrome: _captureChrome(
              kind: EntityKind.instance,
              tabLabels: _instTabLabels,
              tabIndex: 0,
              midBarCta: _cta(Icons.add, tr('br.newKey')))));

  testWidgets('capture inst-console',
      (t) => _captureLoaded(t, 'inst-console', fx.pumpInstConsoleLoaded,
          chrome: _captureChrome(
              kind: EntityKind.instance,
              tabLabels: _instTabLabels,
              tabIndex: 1)));

  testWidgets('capture inst-monitor',
      (t) => _capture(t, 'inst-monitor', fx.pumpInstMonitor,
          chrome: _captureChrome(
              kind: EntityKind.instance,
              tabLabels: _instTabLabels,
              tabIndex: 2)));

  testWidgets('capture inst-logs', (t) => _capture(t, 'inst-logs', fx.pumpInstLogs,
      chrome: _captureChrome(
          kind: EntityKind.instance, tabLabels: _instTabLabels, tabIndex: 3),
      // Drop LogsPage's periodic timer once the PNG is written.
      after: (t) => t.pumpWidget(const SizedBox())));

  testWidgets('capture inst-playground',
      (t) => _capture(t, 'inst-playground', fx.pumpInstPlayground,
          chrome: _captureChrome(
              kind: EntityKind.instance,
              tabLabels: _instTabLabels,
              tabIndex: 4)));

  testWidgets('capture inst-config',
      (t) => _capture(t, 'inst-config', fx.pumpInstConfig,
          chrome: _captureChrome(
              kind: EntityKind.instance,
              tabLabels: _instTabLabels,
              tabIndex: 5)));

  testWidgets('capture ep-overview',
      (t) => _capture(t, 'ep-overview', fx.pumpEpOverview,
          chrome: _captureChrome(
              kind: EntityKind.endpoint,
              tabLabels: _epTabLabels,
              tabIndex: 0,
              selectedConfigId: null,
              selectedEndpointId: 'e1')));

  testWidgets('capture ep-browser',
      (t) => _capture(t, 'ep-browser', fx.pumpEpBrowser,
          chrome: _captureChrome(
              kind: EntityKind.endpoint,
              tabLabels: _epTabLabels,
              tabIndex: 1,
              selectedConfigId: null,
              selectedEndpointId: 'e1',
              midBarCta: _cta(Icons.add, 'Item'))));
}
