// v2.3 golden screen tests (T14) — the 8 design screens × light/dark.
//
// The live app can't be clicked from this toolchain (synthetic OS events never
// reach Flutter's MidBar tabs), so the screens are pumped here directly with a
// fake core and captured as goldens. The PNGs under test/goldens/ are the
// per-screen, per-theme renderings to compare against the v2.3 mockups in
// redis-ui-mockups/v2/pages2/.
//
// macOS-only (the font loader reads SFNS from /System/Library/Fonts).

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/main.dart' show MonitorView;
import 'package:redimos_manager/src/browser_page.dart';
import 'package:redimos_manager/src/cmd_console.dart';
import 'package:redimos_manager/src/configure_page.dart';
import 'package:redimos_manager/src/endpoint_browser.dart';
import 'package:redimos_manager/src/endpoint_detail.dart';
import 'package:redimos_manager/src/logs_page.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/playground_page.dart';

import 'golden_fonts.dart';
import 'screen_fixtures.dart' as fx;

// ---------------------------------------------------------------------------
// Theme + fixtures live in screen_fixtures.dart (shared with the pixel
// capture channel, pixel-fidelity-v23 CP 2.1). _pumpScreen and the golden
// assertions below stay in this file, unchanged.
// ---------------------------------------------------------------------------

ThemeData _goldenTheme(Brightness b) => fx.goldenTheme(b);

/// Pump [child] inside the app-equivalent MaterialApp/Scaffold at the design's
/// 1280×800 logical size (×2 for crisp PNGs).
Future<void> _pumpScreen(WidgetTester tester,
    {required bool dark, required Widget child}) async {
  await loadGoldenFonts();
  tester.view.physicalSize = const Size(2560, 1600);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _goldenTheme(dark ? Brightness.dark : Brightness.light),
    home: Scaffold(body: child),
  ));
}

// ---------------------------------------------------------------------------
// Fixtures (screen_fixtures.dart — shared with the pixel capture channel)
// ---------------------------------------------------------------------------

final _core = fx.fakeCore;

const _endpoint = fx.fixtureEndpoint;

RedimosConfig _cfg() => fx.fixtureConfig();

InstanceStatus _status() => fx.fixtureStatus();

/// The endpoint Overview's probe shows a real measured round-trip ("39 ms"),
/// which varies by a few pixels of glyph between runs — byte-exact goldens can
/// never hold for it. Accept ≤0.5% differing pixels (observed drift ≈0.01%);
/// any real layout regression dwarfs that.
class _TolerantGoldenComparator extends LocalFileComparator {
  _TolerantGoldenComparator(super.baseDir);

  static const double _tolerance = 0.005;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result =
        await GoldenFileComparator.compareLists(imageBytes, await getGoldenBytes(golden));
    if (result.passed || result.diffPercent <= _tolerance) return true;
    final error = await generateFailureOutput(result, golden, basedir);
    throw FlutterError(error);
  }
}

// ---------------------------------------------------------------------------
// Registration: every screen once per theme.
// ---------------------------------------------------------------------------

void main() {
  // Absolute test-file URI: LocalFileComparator's constructor takes the TEST
  // FILE and derives basedir via dirname() — passing the directory itself
  // would strip its last segment and mis-resolve the PNG paths.
  goldenFileComparator = _TolerantGoldenComparator(
      Uri.file('${Directory.current.path}/test/golden_screens_test.dart'));
  void screen(String name, Future<void> Function(WidgetTester t, bool dark) body) {
    testWidgets('golden $name (light)', (t) => body(t, false));
    testWidgets('golden $name (dark)', (t) => body(t, true));
  }

  screen('inst-browse', (t, dark) async {
    await _pumpScreen(t,
        dark: dark,
        child: BrowserPageView(config: _cfg(), running: true, core: _core));
    await t.pump(const Duration(milliseconds: 50));
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/inst-browse-${dark ? 'dark' : 'light'}.png'));
  });

  screen('inst-console', (t, dark) async {
    await _pumpScreen(t,
        dark: dark,
        child: const CmdConsole(host: '127.0.0.1', port: 6379, running: true));
    await t.pump(const Duration(milliseconds: 50));
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/inst-console-${dark ? 'dark' : 'light'}.png'));
  });

  screen('inst-monitor', (t, dark) async {
    await _pumpScreen(t,
        dark: dark,
        child: MonitorView(
          status: _status(),
          cpuHist: fx.mockSparkCpu,
          memHist: fx.mockSparkMem,
          opsHist: fx.mockSparkOps,
          embedded: true,
          instanceName: 'prod-redis-01',
        ));
    await t.pump(const Duration(milliseconds: 50));
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/inst-monitor-${dark ? 'dark' : 'light'}.png'));
  });

  screen('inst-logs', (t, dark) async {
    await _pumpScreen(t,
        dark: dark, child: LogsPage(core: _core, configId: 'c1'));
    await t.pump(const Duration(milliseconds: 50));
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/inst-logs-${dark ? 'dark' : 'light'}.png'));
    // LogsPage runs a 1200ms periodic timer — drop it before teardown.
    await t.pumpWidget(const SizedBox());
  });

  screen('inst-playground', (t, dark) async {
    await _pumpScreen(t,
        dark: dark,
        child: PlaygroundView(core: _core, config: _cfg(), kind: 'redis', running: true));
    await t.pump(const Duration(milliseconds: 50));
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/inst-playground-${dark ? 'dark' : 'light'}.png'));
  });

  screen('inst-config', (t, dark) async {
    await _pumpScreen(t,
        dark: dark,
        child: ConfigEditor(
          config: _cfg(),
          onSave: (_) async {},
          onDelete: (_) async {},
        ));
    await t.pump(const Duration(milliseconds: 50));
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/inst-config-${dark ? 'dark' : 'light'}.png'));
  });

  screen('ep-config', (t, dark) async {
    await _pumpScreen(t,
        dark: dark,
        child: EndpointConfigPane(
          endpoint: _endpoint,
          onSave: (_) async {},
          onDelete: () async {},
        ));
    await t.pump();
    await t.pump();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/ep-config-${dark ? 'dark' : 'light'}.png'));
  });

  screen('ep-browser', (t, dark) async {
    await _pumpScreen(t,
        dark: dark,
        child: EndpointTablesView(
          core: _core,
          config: _endpoint.toStorageConfig(),
          endpoint: _endpoint,
        ));
    await t.pump(const Duration(milliseconds: 50)); // epListTables resolves
    await t.pump();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/ep-browser-${dark ? 'dark' : 'light'}.png'));
  });
}
