// Golden-test font loader (test-only).
//
// Widget tests render text with the blocky FlutterTest font by default, and
// they do NOT auto-load the pubspec fonts — so the goldens register the real
// faces themselves. pixel-fidelity-v23 (CP 4.9–4.11) switched from the host's
// system fonts (SFNS/SFNSMono, macOS-only) to the project's BUNDLED variable
// fonts (assets/fonts/): the same Inter / JetBrains Mono the app ships and
// the mockup captures inject. This also lifts the goldens' macOS platform
// binding — any host with the repo can now generate/compare them.
//
// CJK (CP 4.15): neither bundled face carries CJK glyphs — the real app
// falls back to the host's PingFang SC (Ts.sans). Widget tests have no
// platform fallback, so Chinese would render as tofu boxes; when the host
// has PingFang (base dir or macOS on-demand asset), register it under
// 'PingFang SC' so captures/goldens match the real app. Hosts without it
// degrade gracefully (tofu in tests only — the real app still falls back).

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _inter = 'assets/fonts/Inter-Variable.ttf';
const _jetbrainsMono = 'assets/fonts/JetBrainsMono-Variable.ttf';

/// The logical family name the goldens pump their themes with.
const kGoldenUiFont = 'ui';

bool _loaded = false;

Future<void> loadGoldenFonts() async {
  if (_loaded) return;
  final interBytes = _bytes(_inter);
  // The theme pumps fontFamily 'ui'; register Inter under that name.
  final ui = FontLoader(kGoldenUiFont)..addFont(interBytes);
  await ui.load();
  // Ts.sans now leads with 'Inter' — register the same bytes under the real
  // family name so fallback resolution in tests matches the app.
  final inter = FontLoader('Inter')..addFont(interBytes);
  await inter.load();
  // Register the bundled JetBrains Mono under the literal name the app code
  // uses in TextStyle (`fontFamily: 'monospace'`, Ts.mono head).
  final mono = FontLoader('monospace')..addFont(_bytes(_jetbrainsMono));
  await mono.load();
  // MaterialIcons (CP 9.x): widget tests do NOT bundle the icon font, so
  // every Icon rendered as a tofu box in captures/goldens while the real app
  // shows true glyphs. Register the SDK-cached face so both sides match;
  // hosts without the cache degrade gracefully (tofu in tests only).
  final materialIcons = _hostMaterialIcons();
  if (materialIcons != null) {
    try {
      final mi = FontLoader('MaterialIcons')..addFont(_bytes(materialIcons));
      await mi.load();
    } catch (e) {
      debugPrint('[golden_fonts] MaterialIcons load skipped: $e');
    }
  }
  // CJK fallback (CP 4.15): the host's PingFang SC, when present, so the
  // Chinese hints render like the real app instead of tofu.
  final pingFang = _hostPingFang();
  if (pingFang != null) {
    try {
      final cjk = FontLoader('PingFang SC')..addFont(_bytes(pingFang));
      await cjk.load();
    } catch (e) {
      // Host face unusable (odd ttc etc.) — tests degrade to tofu; the real
      // app still resolves its own system fallback at runtime.
      debugPrint('[golden_fonts] PingFang SC load skipped: $e');
    }
  }
  _loaded = true;
}

/// Locate the host's PingFang collection: the classic base path, or the
/// macOS on-demand asset store (Sequoia ships it there). null elsewhere.
String? _hostPingFang() {
  const base = '/System/Library/Fonts/PingFang.ttc';
  if (File(base).existsSync()) return base;
  const assetRoot = '/System/Library/AssetsV2/com_apple_MobileAsset_Font7';
  final root = Directory(assetRoot);
  if (!root.existsSync()) return null;
  for (final entry in root.listSync(followLinks: false)) {
    final candidate = File('${entry.path}/AssetData/PingFang.ttc');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}

/// Locate the SDK's MaterialIcons face: $FLUTTER_ROOT when set, else the
/// user-level checkout at ~/flutter (this project's documented install).
String? _hostMaterialIcons() {
  final roots = <String>[];
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.isNotEmpty) roots.add(flutterRoot);
  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) roots.add('$home/flutter');
  for (final r in roots) {
    final candidate =
        '$r/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

Future<ByteData> _bytes(String path) async =>
    File(path).readAsBytesSync().buffer.asByteData();
