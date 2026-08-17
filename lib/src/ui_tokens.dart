import 'package:flutter/material.dart';

/// Codex-inspired semantic design tokens. Two static instances, light and dark,
/// are exposed as a ThemeExtension so any widget can read
/// `AppTokens.of(context)` without threading values down the tree.
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.bg,
    required this.panel,
    required this.panel2,
    required this.sidebar,
    required this.border,
    required this.hairline,
    required this.text,
    required this.text2,
    required this.text3,
    required this.accent,
    required this.onAccent,
    required this.hover,
    required this.selection,
    required this.focus,
    required this.danger,
    required this.success,
    required this.warning,
    required this.highlight,
    required this.highlightSoft,
    required this.railBg,
    required this.railBgTop,
    required this.railBgBottom,
    required this.railFg,
    required this.railFgActive,
    required this.railActiveBg,
    required this.railGlow,
    required this.railIndicatorTop,
    required this.railIndicatorBottom,
    required this.typeString,
    required this.typeHash,
    required this.typeList,
    required this.typeSet,
    required this.typeZset,
    required this.typeStream,
    required this.typeJson,
  });

  final Color bg;
  final Color panel;
  final Color panel2;
  final Color sidebar;
  final Color border;
  final Color hairline;
  final Color text;
  final Color text2;
  final Color text3;
  final Color accent;
  final Color onAccent;
  final Color hover;
  final Color selection;
  final Color focus;
  final Color danger;
  final Color success;
  final Color warning;

  /// Top-edge hairline highlight (light: strong white, dark: faint white).
  final Color highlight;
  final Color highlightSoft;

  /// Theme-aware application rail roles. The rail keeps its fixed geometry but
  /// follows the active light/dark paint system instead of using legacy navy.
  final Color railBg;
  final Color railBgTop;
  final Color railBgBottom;
  final Color railFg;
  final Color railFgActive;
  final Color railActiveBg;
  final Color railGlow;
  final Color railIndicatorTop;
  final Color railIndicatorBottom;

  LinearGradient get railGradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [railBgTop, railBg, railBgBottom],
        stops: const [0.0, 0.52, 1.0],
      );

  LinearGradient get railIndicatorGradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [railIndicatorTop, railIndicatorBottom],
      );

  // Type colour phases (seven): STRING/HASH/LIST/SET/ZSET/STREAM/JSON.
  // Light = pastel fill + navy text; dark = saturated fill + white text.
  final RedisTypeColors typeString;
  final RedisTypeColors typeHash;
  final RedisTypeColors typeList;
  final RedisTypeColors typeSet;
  final RedisTypeColors typeZset;
  final RedisTypeColors typeStream;
  final RedisTypeColors typeJson;

  // ------------------------------------------------------------ instances ---
  static const AppTokens light = AppTokens(
    bg: Color(0xFFF7F5F0),
    panel: Color(0xFFFCFBF8),
    panel2: Color(0xFFF1EEE7),
    sidebar: Color(0xFFF3F0EA),
    border: Color(0xFFC9C4BA),
    hairline: Color(0xFFE2DED5),
    text: Color(0xFF25231F),
    text2: Color(0xFF5F5A51),
    text3: Color(0xFF6F695F),
    accent: Color(0xFFB84E17),
    onAccent: Color(0xFFFFFFFF),
    hover: Color(0xFFEEE9E0),
    selection: Color(0xFFF5DEC9),
    focus: Color(0xFFA94312),
    danger: Color(0xFFAD0017),
    success: Color(0xFF137A42),
    warning: Color(0xFF8A5A00),
    highlight: Color(0xD9FFFFFF),
    highlightSoft: Color(0x8CFFFFFF),
    railBg: Color(0xFFEDE9DF),
    railBgTop: Color(0xFFF3F0E9),
    railBgBottom: Color(0xFFE5DFD2),
    railFg: Color(0xFF5D5749),
    railFgActive: Color(0xFF9C400F),
    railActiveBg: Color(0xFFF3D2B3),
    railGlow: Color(0x40B84E17),
    railIndicatorTop: Color(0xFFB84E17),
    railIndicatorBottom: Color(0xFFB84E17),
    // Redis type colours remain data-semantic; neutral text and outlines avoid
    // reintroducing the legacy navy palette through shared badge chrome.
    typeString: RedisTypeColors(
        fill: Color(0xFFC7B0EA),
        fg: Color(0xFF25231F),
        border: Color(0x6625231F)),
    typeHash: RedisTypeColors(
        fill: Color(0xFFCDDDF8),
        fg: Color(0xFF25231F),
        border: Color(0x6625231F)),
    typeList: RedisTypeColors(
        fill: Color(0xFFA5D4C3),
        fg: Color(0xFF0C4A33),
        border: Color(0x6625231F)),
    typeSet: RedisTypeColors(
        fill: Color(0xFFD4BAA7),
        fg: Color(0xFF5C320F),
        border: Color(0x6625231F)),
    typeZset: RedisTypeColors(
        fill: Color(0xFFD9A0C6),
        fg: Color(0xFF63113F),
        border: Color(0x6625231F)),
    typeStream: RedisTypeColors(
        fill: Color(0xFFB8C5DB),
        fg: Color(0xFF20335A),
        border: Color(0x6625231F)),
    typeJson: RedisTypeColors(
        fill: Color(0xFFDFE3EA),
        fg: Color(0xFF5F5A51),
        border: Color(0x6625231F)),
  );

  static const AppTokens dark = AppTokens(
    bg: Color(0xFF151411),
    panel: Color(0xFF1F1E1A),
    panel2: Color(0xFF191815),
    sidebar: Color(0xFF1A1916),
    border: Color(0xFF3B3933),
    hairline: Color(0xFF2D2B27),
    text: Color(0xFFF1EEE7),
    text2: Color(0xFFC5C0B5),
    text3: Color(0xFF928C80),
    accent: Color(0xFFFCBF35),
    onAccent: Color(0xFF241B07),
    hover: Color(0xFF2A2823),
    selection: Color(0xFF3A2E16),
    focus: Color(0xFFFDC851),
    danger: Color(0xFFFF6B6B),
    success: Color(0xFF62C98D),
    warning: Color(0xFFE2A640),
    highlight: Color(0x17FFFFFF),
    highlightSoft: Color(0x0DFFFFFF),
    railBg: Color(0xFF191815),
    railBgTop: Color(0xFF191815),
    railBgBottom: Color(0xFF191815),
    railFg: Color(0xFF928C80),
    railFgActive: Color(0xFFF1EEE7),
    railActiveBg: Color(0xFF3A2E16),
    railGlow: Color(0x00FCBF35),
    railIndicatorTop: Color(0xFFFCBF35),
    railIndicatorBottom: Color(0xFFFCBF35),
    // Redis data-type colours remain semantic, not brand accents.
    // Dark type phases: saturated fill + white text.
    typeString: RedisTypeColors(
        fill: Color(0xFF6A1DC3),
        fg: Color(0xFFFFFFFF),
        border: Color(0x4DFFFFFF)),
    typeHash: RedisTypeColors(
        fill: Color(0xFF364CFF),
        fg: Color(0xFFFFFFFF),
        border: Color(0x4DFFFFFF)),
    typeList: RedisTypeColors(
        fill: Color(0xFF008556),
        fg: Color(0xFFFFFFFF),
        border: Color(0x4DFFFFFF)),
    typeSet: RedisTypeColors(
        fill: Color(0xFF9C5C2B),
        fg: Color(0xFFFFFFFF),
        border: Color(0x4DFFFFFF)),
    typeZset: RedisTypeColors(
        fill: Color(0xFFA00A6B),
        fg: Color(0xFFFFFFFF),
        border: Color(0x4DFFFFFF)),
    typeStream: RedisTypeColors(
        fill: Color(0xFF5A6B85),
        fg: Color(0xFFFFFFFF),
        border: Color(0x4DFFFFFF)),
    typeJson: RedisTypeColors(
        fill: Color(0xFF3F4B5F),
        fg: Color(0xFFFFFFFF),
        border: Color(0x4DFFFFFF)),
  );

  // ------------------------------------------------- style palettes (v1.3) ---
  // Six additional named palettes selectable at runtime via AppStyle. Values
  // are the pixel-QC'd mappings from the bold-recolor mockups (design doc:
  // .kiro/specs/theme-style-selector). `light` (= Parchment) and `dark`
  // (capture layer) above remain untouched.

  /// Forest: deep green surfaces, amber accent.
  static const AppTokens forest = AppTokens(
    bg: Color(0xFF1C241E),
    panel: Color(0xFF232C26),
    panel2: Color(0xFF2A352D),
    sidebar: Color(0xFF202A23),
    border: Color(0xFF3E4C42),
    hairline: Color(0xFF323E35),
    text: Color(0xFFF0EDE2),
    text2: Color(0xFFB8BFB2),
    text3: Color(0xFF9AA594),
    accent: Color(0xFFE8A33D),
    onAccent: Color(0xFF1C241E),
    hover: Color(0xFF2A352D),
    selection: Color(0xFF3A4432),
    focus: Color(0xFFC07F2A),
    danger: Color(0xFFFF6B5E),
    success: Color(0xFF57C785),
    warning: Color(0xFFE8C35A),
    highlight: Color(0x17FFFFFF),
    highlightSoft: Color(0x0DFFFFFF),
    railBg: Color(0xFF171E19),
    railBgTop: Color(0xFF1B231D),
    railBgBottom: Color(0xFF131A15),
    railFg: Color(0xFF9AA594),
    railFgActive: Color(0xFFF0C778),
    railActiveBg: Color(0xFF333F2A),
    railGlow: Color(0x40E8A33D),
    railIndicatorTop: Color(0xFFE8A33D),
    railIndicatorBottom: Color(0xFFE8A33D),
    typeString: _typeDarkString,
    typeHash: _typeDarkHash,
    typeList: _typeDarkList,
    typeSet: _typeDarkSet,
    typeZset: _typeDarkZset,
    typeStream: _typeDarkStream,
    typeJson: _typeDarkJson,
  );

  /// Midnight: deep navy surfaces, bright blue accent.
  static const AppTokens midnight = AppTokens(
    bg: Color(0xFF10151D),
    panel: Color(0xFF161C26),
    panel2: Color(0xFF1C242F),
    sidebar: Color(0xFF131923),
    border: Color(0xFF2E3A4B),
    hairline: Color(0xFF242F3E),
    text: Color(0xFFE8ECF3),
    text2: Color(0xFFA9B4C4),
    text3: Color(0xFF8B97A8),
    accent: Color(0xFF4F8FE8),
    onAccent: Color(0xFFFFFFFF),
    hover: Color(0xFF1C242F),
    selection: Color(0xFF1E3A5C),
    focus: Color(0xFF3A72C4),
    danger: Color(0xFFFF6B6B),
    success: Color(0xFF4CC27A),
    warning: Color(0xFFE8C35A),
    highlight: Color(0x17FFFFFF),
    highlightSoft: Color(0x0DFFFFFF),
    railBg: Color(0xFF0C1118),
    railBgTop: Color(0xFF0F141C),
    railBgBottom: Color(0xFF090D13),
    railFg: Color(0xFF8B97A8),
    railFgActive: Color(0xFF7FB2F0),
    railActiveBg: Color(0xFF1C3250),
    railGlow: Color(0x404F8FE8),
    railIndicatorTop: Color(0xFF4F8FE8),
    railIndicatorBottom: Color(0xFF4F8FE8),
    typeString: _typeDarkString,
    typeHash: _typeDarkHash,
    typeList: _typeDarkList,
    typeSet: _typeDarkSet,
    typeZset: _typeDarkZset,
    typeStream: _typeDarkStream,
    typeJson: _typeDarkJson,
  );

  /// Charcoal: neutral near-black surfaces, amber accent.
  static const AppTokens charcoal = AppTokens(
    bg: Color(0xFF191919),
    panel: Color(0xFF212121),
    panel2: Color(0xFF2A2A2A),
    sidebar: Color(0xFF1E1E1E),
    border: Color(0xFF3D3D3D),
    hairline: Color(0xFF313131),
    text: Color(0xFFF2F0EB),
    text2: Color(0xFFBDBAB2),
    text3: Color(0xFF9C9890),
    accent: Color(0xFFFFB020),
    onAccent: Color(0xFF241B07),
    hover: Color(0xFF2A2A2A),
    selection: Color(0xFF453517),
    focus: Color(0xFFD9950F),
    danger: Color(0xFFFF6B6B),
    success: Color(0xFF4CC27A),
    warning: Color(0xFFE8C35A),
    highlight: Color(0x17FFFFFF),
    highlightSoft: Color(0x0DFFFFFF),
    railBg: Color(0xFF141414),
    railBgTop: Color(0xFF171717),
    railBgBottom: Color(0xFF101010),
    railFg: Color(0xFF9C9890),
    railFgActive: Color(0xFFFFC655),
    railActiveBg: Color(0xFF3A2E16),
    railGlow: Color(0x40FFB020),
    railIndicatorTop: Color(0xFFFFB020),
    railIndicatorBottom: Color(0xFFFFB020),
    typeString: _typeDarkString,
    typeHash: _typeDarkHash,
    typeList: _typeDarkList,
    typeSet: _typeDarkSet,
    typeZset: _typeDarkZset,
    typeStream: _typeDarkStream,
    typeJson: _typeDarkJson,
  );

  /// Brick: cream surfaces, brick-red accent — the boldest light palette.
  static const AppTokens brick = AppTokens(
    bg: Color(0xFFF6EFE3),
    panel: Color(0xFFFFFAF0),
    panel2: Color(0xFFF0E6D2),
    sidebar: Color(0xFFF3EBDC),
    border: Color(0xFFC4AE93),
    hairline: Color(0xFFE3D5BC),
    text: Color(0xFF2E2118),
    text2: Color(0xFF6B5138),
    text3: Color(0xFF7A6248),
    accent: Color(0xFFC0392B),
    onAccent: Color(0xFFFFF6E8),
    hover: Color(0xFFF0E6D2),
    selection: Color(0xFFF5D7B8),
    focus: Color(0xFFA32B1F),
    danger: Color(0xFFAD0017),
    success: Color(0xFF137A42),
    warning: Color(0xFF8A5A00),
    highlight: Color(0xD9FFFFFF),
    highlightSoft: Color(0x8CFFFFFF),
    railBg: Color(0xFFEFE5D2),
    railBgTop: Color(0xFFF4EBD9),
    railBgBottom: Color(0xFFEADFC8),
    railFg: Color(0xFF6B5138),
    railFgActive: Color(0xFFA32B1F),
    railActiveBg: Color(0xFFF2CBAE),
    railGlow: Color(0x40C0392B),
    railIndicatorTop: Color(0xFFC0392B),
    railIndicatorBottom: Color(0xFFC0392B),
    typeString: _typeLightString,
    typeHash: _typeLightHash,
    typeList: _typeLightList,
    typeSet: _typeLightSet,
    typeZset: _typeLightZset,
    typeStream: _typeLightStream,
    typeJson: _typeLightJson,
  );

  /// Aubergine: deep purple surfaces, lavender accent.
  static const AppTokens aubergine = AppTokens(
    bg: Color(0xFF1E1626),
    panel: Color(0xFF261D30),
    panel2: Color(0xFF2E2439),
    sidebar: Color(0xFF231A2C),
    border: Color(0xFF443652),
    hairline: Color(0xFF372B44),
    text: Color(0xFFF0EAF5),
    text2: Color(0xFFB6A9C2),
    text3: Color(0xFF9A8CA8),
    accent: Color(0xFFBB86E0),
    onAccent: Color(0xFF24132E),
    hover: Color(0xFF2E2439),
    selection: Color(0xFF3E2A52),
    focus: Color(0xFFA06BD0),
    danger: Color(0xFFFF7A85),
    success: Color(0xFF6FD3A0),
    warning: Color(0xFFE8C98A),
    highlight: Color(0x17FFFFFF),
    highlightSoft: Color(0x0DFFFFFF),
    railBg: Color(0xFF1A1220),
    railBgTop: Color(0xFF1E1628),
    railBgBottom: Color(0xFF150E1B),
    railFg: Color(0xFF9A8CA8),
    railFgActive: Color(0xFFD3AEF0),
    railActiveBg: Color(0xFF3A2A4C),
    railGlow: Color(0x40BB86E0),
    railIndicatorTop: Color(0xFFBB86E0),
    railIndicatorBottom: Color(0xFFBB86E0),
    typeString: _typeDarkString,
    typeHash: _typeDarkHash,
    typeList: _typeDarkList,
    typeSet: _typeDarkSet,
    typeZset: _typeDarkZset,
    typeStream: _typeDarkStream,
    typeJson: _typeDarkJson,
  );

  /// Mono: black-and-white newspaper — pure white surfaces, black accent, a
  /// single true red reserved for danger, and grayscale type badges.
  static const AppTokens mono = AppTokens(
    bg: Color(0xFFFFFFFF),
    panel: Color(0xFFFFFFFF),
    panel2: Color(0xFFF2F2F0),
    sidebar: Color(0xFFF7F7F5),
    border: Color(0xFF3A3A38),
    hairline: Color(0xFFD8D8D4),
    text: Color(0xFF0A0A0A),
    text2: Color(0xFF3D3D3B),
    text3: Color(0xFF5A5A57),
    accent: Color(0xFF0A0A0A),
    onAccent: Color(0xFFFFFFFF),
    hover: Color(0xFFF2F2F0),
    selection: Color(0xFFDEDEDA),
    focus: Color(0xFF0A0A0A),
    danger: Color(0xFFC0001A),
    success: Color(0xFF0A0A0A),
    warning: Color(0xFF5A5A57),
    highlight: Color(0xD9FFFFFF),
    highlightSoft: Color(0x8CFFFFFF),
    railBg: Color(0xFFF0F0EE),
    railBgTop: Color(0xFFF5F5F3),
    railBgBottom: Color(0xFFE9E9E6),
    railFg: Color(0xFF5A5A57),
    railFgActive: Color(0xFF0A0A0A),
    railActiveBg: Color(0xFFE4E4E0),
    railGlow: Color(0x400A0A0A),
    railIndicatorTop: Color(0xFF0A0A0A),
    railIndicatorBottom: Color(0xFF0A0A0A),
    typeString: _typeMonoString,
    typeHash: _typeMonoHash,
    typeList: _typeMonoList,
    typeSet: _typeMonoSet,
    typeZset: _typeMonoZset,
    typeStream: _typeMonoStream,
    typeJson: _typeMonoJson,
  );

  static AppTokens of(BuildContext context) {
    final ext = Theme.of(context).extension<AppTokens>();
    assert(ext != null, 'AppTokens not registered on the theme');
    return ext!;
  }

  /// Resolve by brightness without context (e.g. inside theme factories).
  static AppTokens forBrightness(Brightness b) =>
      b == Brightness.dark ? dark : light;

  /// Type colour lookup by Redis key-type name.
  RedisTypeColors typeColors(String type) {
    switch (type.toUpperCase()) {
      case 'STRING':
        return typeString;
      case 'HASH':
        return typeHash;
      case 'LIST':
        return typeList;
      case 'SET':
        return typeSet;
      case 'ZSET':
        return typeZset;
      case 'STREAM':
        return typeStream;
      case 'JSON':
      default:
        return typeJson;
    }
  }

  @override
  AppTokens copyWith() =>
      this; // tokens are immutable constants; no partial copy needed

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) =>
      t < 0.5 ? this : (other as AppTokens? ?? this);
}

/// Fill / foreground / outline triple for one Redis key-type phase.
class RedisTypeColors {
  const RedisTypeColors(
      {required this.fill, required this.fg, required this.border});
  final Color fill;
  final Color fg;
  final Color border;
}

// ---------------------------------------------------------------------------
// Dimension scale (R1.2)
// ---------------------------------------------------------------------------
class Dim {
  Dim._();

  static const double railW = 64;
  static const double sidebarW = 280;
  static const double topBarH = 48;
  static const double midBarH = 44;
  static const double statusBarH = 24;
  static const double cliHeadH = 32;
  static const double rowH = 30;
  static const double ctlH = 30;
  static const double tablesSideW = 230;
  static const double trailingSlot = 28;
  static const double wellInsetH = 3;
  static const double borderW = 1;

  static const double radiusS = 6;
  static const double radiusM = 8;
  static const double radiusL = 12;
}

// ---------------------------------------------------------------------------
// Type scale (R1.3): six steps, no micro type. UI = sans, data = mono.
// ---------------------------------------------------------------------------
class Ts {
  Ts._();

  static const double xs = 11;
  static const double sm = 11.5;
  static const double md = 12;
  static const double lg = 12.5;
  static const double xl = 13.5;
  static const double xxl = 15.5;

  /// Bundled production font families. The mono asset is intentionally
  /// registered as `monospace` in pubspec.yaml so legacy editor/data styles and
  /// [style] resolve to the same JetBrains Mono face.
  static const String uiFamily = 'Inter';
  static const String monoFamily = 'monospace';

  /// Platform and CJK fallbacks used after bundled Inter. Keep platform-native
  /// UI faces ahead of broad sans families while explicitly covering Chinese.
  static const List<String> sansFallback = [
    '-apple-system',
    '.SF NS Text',
    'SF Pro Text',
    'Segoe UI',
    'PingFang SC',
    'Microsoft YaHei',
    'Helvetica Neue',
    'Arial',
    'sans-serif',
  ];

  /// Complete UI stack for assertions and non-ThemeData consumers.
  static const List<String> sans = [uiFamily, ...sansFallback];

  /// System mono faces followed by CJK-capable platform fonts. CJK glyphs are
  /// not monospace in the bundled asset, so the explicit fallbacks avoid tofu
  /// while preserving JetBrains Mono for commands, identifiers, and data.
  static const List<String> monoFallback = [
    'ui-monospace',
    'SF Mono',
    'Menlo',
    'Consolas',
    'Courier',
    'PingFang SC',
    'Microsoft YaHei',
    'sans-serif',
  ];

  /// Complete data stack for assertions and direct consumers.
  static const List<String> mono = [monoFamily, ...monoFallback];

  /// Tabular figures for all numeric readouts (metrics, latency, counts).
  static const List<FontFeature> tabular = [FontFeature('tnum')];

  /// CSS half-leading line boxes (CP 5.1): Flutter's default leading
  /// distribution is proportional (ascent-weighted), so any text given an
  /// explicit `height` sits off-centre in its line box versus the CSS mockups,
  /// which use half-leading. even splits the added leading above/below.
  static const TextLeadingDistribution cssLeading =
      TextLeadingDistribution.even;

  /// ThemeData/TextTheme.apply have no leading hook, so stamp [cssLeading]
  /// onto every theme style: the theme-derived DefaultTextStyle then gives
  /// CSS leading semantics to all text that doesn't override it.
  static TextTheme withCssLeading(TextTheme tt) => tt.copyWith(
        displayLarge:
            tt.displayLarge?.copyWith(leadingDistribution: cssLeading),
        displayMedium:
            tt.displayMedium?.copyWith(leadingDistribution: cssLeading),
        displaySmall:
            tt.displaySmall?.copyWith(leadingDistribution: cssLeading),
        headlineLarge:
            tt.headlineLarge?.copyWith(leadingDistribution: cssLeading),
        headlineMedium:
            tt.headlineMedium?.copyWith(leadingDistribution: cssLeading),
        headlineSmall:
            tt.headlineSmall?.copyWith(leadingDistribution: cssLeading),
        titleLarge: tt.titleLarge?.copyWith(leadingDistribution: cssLeading),
        titleMedium: tt.titleMedium?.copyWith(leadingDistribution: cssLeading),
        titleSmall: tt.titleSmall?.copyWith(leadingDistribution: cssLeading),
        bodyLarge: tt.bodyLarge?.copyWith(leadingDistribution: cssLeading),
        bodyMedium: tt.bodyMedium?.copyWith(leadingDistribution: cssLeading),
        bodySmall: tt.bodySmall?.copyWith(leadingDistribution: cssLeading),
        labelLarge: tt.labelLarge?.copyWith(leadingDistribution: cssLeading),
        labelMedium: tt.labelMedium?.copyWith(leadingDistribution: cssLeading),
        labelSmall: tt.labelSmall?.copyWith(leadingDistribution: cssLeading),
      );

  static TextStyle style({
    double size = md,
    FontWeight weight = FontWeight.normal,
    Color? color,
    bool monoFont = false,
    bool tabularNums = false,
    double? height,
    double? letterSpacing,
  }) =>
      TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
        leadingDistribution: cssLeading,
        // CP 4.5 intent: mono text must LEAD with the mono family, else the
        // theme's ui family wins the merge and values render proportional.
        fontFamily: monoFont ? monoFamily : null,
        fontFamilyFallback: monoFont ? monoFallback : sansFallback,
        fontFeatures: tabularNums ? tabular : null,
      );

  /// Resolves an explicit UI face for Material components that install their
  /// own [DefaultTextStyle] instead of inheriting the app-level theme face.
  ///
  /// Keeping [style] inheritable lets deterministic tests inject `ui`, while
  /// this helper prevents those isolated component styles from falling back to
  /// Flutter's block-glyph test font.
  static TextStyle themedStyle(
    ThemeData theme, {
    double size = md,
    FontWeight weight = FontWeight.normal,
    Color? color,
    bool monoFont = false,
    bool tabularNums = false,
    double? height,
    double? letterSpacing,
  }) {
    final result = style(
      size: size,
      weight: weight,
      color: color,
      monoFont: monoFont,
      tabularNums: tabularNums,
      height: height,
      letterSpacing: letterSpacing,
    );
    if (monoFont) return result;
    return result.copyWith(
      fontFamily: theme.textTheme.bodyMedium?.fontFamily ?? uiFamily,
    );
  }
}

// ---------------------------------------------------------------------------
// Depth / elevation helpers (R1.5, R1.6) — Codex-style hairline
// highlights, restrained elevations, sunken wells, and rail separation.
// ---------------------------------------------------------------------------
class Depth {
  Depth._();

  /// Low-contrast shell separation. Light and dark use identical shadow
  /// geometry; only the paint changes, so theme switching cannot alter bounds.
  static List<BoxShadow> elev1(Brightness b) => [
        BoxShadow(
          color: b == Brightness.dark
              ? const Color(0x52000000)
              : const Color(0x14241F18),
          blurRadius: 2,
          offset: const Offset(0, 1),
        ),
      ];

  /// Restrained card elevation. The contact and ambient layers share geometry
  /// across themes and avoid the legacy navy cast.
  static List<BoxShadow> elev2(Brightness b) => [
        BoxShadow(
          color: b == Brightness.dark
              ? const Color(0x4D000000)
              : const Color(0x12241F18),
          blurRadius: 2,
          offset: const Offset(0, 1),
        ),
        BoxShadow(
          color: b == Brightness.dark
              ? const Color(0x33000000)
              : const Color(0x14241F18),
          blurRadius: 8,
          offset: const Offset(0, 4),
        ),
      ];

  /// Sidebar soft right-edge separation with theme-invariant geometry.
  static List<BoxShadow> elevSide(Brightness b) => [
        BoxShadow(
          color: b == Brightness.dark
              ? const Color(0x47000000)
              : const Color(0x14241F18),
          blurRadius: 4,
          offset: const Offset(2, 0),
        ),
      ];

  /// Rail right-edge separation. The warm near-black paint replaces the old
  /// blue-black cast while retaining the existing fixed rail footprint.
  static const List<BoxShadow> railShadow = [
    BoxShadow(color: Color(0x70201C16), blurRadius: 8, offset: Offset(4, 0)),
    BoxShadow(color: Color(0x33110F0C), blurRadius: 2, offset: Offset(1, 0)),
  ];

  /// Rail active item glow. The colour comes from the active theme so the fixed
  /// rail geometry can switch palettes without retaining a legacy blue halo.
  static List<BoxShadow> railItemGlow(Color glow) => [
        BoxShadow(color: glow, blurRadius: 6, spreadRadius: 0),
      ];

  /// Top-edge hairline highlight — Flutter has no inset shadow, so we fake
  /// the top 1px inner highlight with a top border of the highlight colour.
  static Border topHighlight(Color hl) =>
      Border(top: BorderSide(color: hl, width: Dim.borderW));

  /// Sunken-well top inset. Flutter approximates the inner shadow with a short
  /// warm-neutral gradient strip. Geometry is shared by both themes; only the
  /// paint opacity changes.
  static BoxDecoration wellTopCli(Brightness b) => _well(
        b == Brightness.dark
            ? const Color(0x52000000)
            : const Color(0x12241F18),
      );

  static BoxDecoration wellTopLogs(Brightness b) => _well(
        b == Brightness.dark
            ? const Color(0x47000000)
            : const Color(0x10241F18),
      );

  static BoxDecoration _well(Color top) => BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, const Color(0x00000000)],
          stops: const [0.0, 1.0],
        ),
      );
}

// ---------------------------------------------------------------------------
// Material default suppression (pixel-fidelity-v23 CP 7.x)
// ---------------------------------------------------------------------------
/// The v2.3 mockups carry NO Material chrome: no ripples, no 48px icon-button
/// targets, no M3 surface tints, no ornamented inputs. The shared appTheme
/// factory applies this builder for production, goldens, and captures so those
/// rendering paths cannot drift apart.
class MatSuppress {
  MatSuppress._();

  static ThemeData apply(ThemeData td, AppTokens t) {
    const transparent = Color(0x00000000);
    final radius = BorderRadius.circular(Dim.radiusS);
    final shape = RoundedRectangleBorder(borderRadius: radius);
    final controlText =
        Ts.themedStyle(td, size: Ts.md, weight: FontWeight.w600);
    final compactControl = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, Dim.ctlH)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12),
      ),
      visualDensity: const VisualDensity(horizontal: -4),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: WidgetStatePropertyAll(shape),
      textStyle: WidgetStatePropertyAll(controlText),
      overlayColor: const WidgetStatePropertyAll(transparent),
      elevation: const WidgetStatePropertyAll(0),
      surfaceTintColor: const WidgetStatePropertyAll(transparent),
      shadowColor: const WidgetStatePropertyAll(transparent),
    );

    Color? interactionFill(Set<WidgetState> states) {
      if (states.contains(WidgetState.disabled)) return transparent;
      if (states.contains(WidgetState.pressed)) return t.selection;
      if (states.contains(WidgetState.hovered)) return t.hover;
      return transparent;
    }

    return td.copyWith(
      // Codex controls use paint-state feedback rather than Material ink.
      splashFactory: NoSplash.splashFactory,
      highlightColor: transparent,
      hoverColor: transparent,
      focusColor: transparent,
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          minimumSize: const Size(26, 26),
          foregroundColor: t.text2,
          disabledForegroundColor: t.text3.withValues(alpha: 0.55),
          overlayColor: transparent,
        ).copyWith(
          backgroundColor: WidgetStateProperty.resolveWith(interactionFill),
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? BorderSide(color: t.focus, width: Dim.borderW)
                : BorderSide.none,
          ),
          shape: WidgetStatePropertyAll(shape),
        ),
      ),
      iconTheme: IconThemeData(color: t.text2),
      filledButtonTheme: FilledButtonThemeData(
        style: compactControl.copyWith(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? t.accent.withValues(alpha: 0.3)
                : states.contains(WidgetState.pressed)
                    ? Color.alphaBlend(t.text.withValues(alpha: 0.12), t.accent)
                    : states.contains(WidgetState.hovered)
                        ? Color.alphaBlend(
                            t.text.withValues(alpha: 0.07), t.accent)
                        : t.accent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? t.onAccent.withValues(alpha: 0.55)
                : t.onAccent,
          ),
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? BorderSide(color: t.focus, width: Dim.borderW)
                : BorderSide.none,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: compactControl.copyWith(
          backgroundColor: WidgetStateProperty.resolveWith(interactionFill),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? t.text3.withValues(alpha: 0.55)
                : t.text,
          ),
          side: WidgetStateProperty.resolveWith(
            (states) => BorderSide(
              color: states.contains(WidgetState.focused) ? t.focus : t.border,
              width: Dim.borderW,
            ),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: compactControl.copyWith(
          backgroundColor: WidgetStateProperty.resolveWith(interactionFill),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? t.text3.withValues(alpha: 0.55)
                : t.text2,
          ),
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? BorderSide(color: t.focus, width: Dim.borderW)
                : BorderSide.none,
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: t.panel,
        surfaceTintColor: transparent,
        shadowColor: Colors.black.withValues(alpha: 0.28),
        elevation: 8,
        shape: shape.copyWith(side: BorderSide(color: t.border)),
        menuPadding: const EdgeInsets.symmetric(vertical: 4),
        textStyle: Ts.themedStyle(td, size: Ts.md, color: t.text),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(t.panel),
          surfaceTintColor: const WidgetStatePropertyAll(transparent),
          shadowColor: WidgetStatePropertyAll(
            Colors.black.withValues(alpha: 0.28),
          ),
          elevation: const WidgetStatePropertyAll(8),
          shape: WidgetStatePropertyAll(
            shape.copyWith(side: BorderSide(color: t.border)),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 4),
          ),
          visualDensity: VisualDensity.compact,
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: Ts.themedStyle(td, size: Ts.md, color: t.text),
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(t.panel),
          surfaceTintColor: const WidgetStatePropertyAll(transparent),
          shadowColor: WidgetStatePropertyAll(
            Colors.black.withValues(alpha: 0.28),
          ),
          elevation: const WidgetStatePropertyAll(8),
          shape: WidgetStatePropertyAll(
            shape.copyWith(side: BorderSide(color: t.border)),
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 4),
          ),
          visualDensity: VisualDensity.compact,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.panel,
        surfaceTintColor: transparent,
        shadowColor: Colors.black.withValues(alpha: 0.32),
        elevation: 12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Dim.radiusL),
          side: BorderSide(color: t.border),
        ),
        titleTextStyle: Ts.themedStyle(
          td,
          size: Ts.xxl,
          weight: FontWeight.w600,
          color: t.text,
        ),
        contentTextStyle:
            Ts.themedStyle(td, size: Ts.md, color: t.text2, height: 1.4),
        actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: t.text,
          borderRadius: radius,
          boxShadow: Depth.elev1(td.brightness),
        ),
        textStyle: Ts.themedStyle(td, size: Ts.xs, color: t.bg),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        margin: const EdgeInsets.all(8),
        waitDuration: const Duration(milliseconds: 450),
        showDuration: const Duration(seconds: 3),
      ),
      // Keep only the base border slot. Theme-level state borders would outrank
      // widget-level InputBorder.none used by search, console, and editor embeds.
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: false,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
        border: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: t.border),
        ),
        hintStyle: Ts.themedStyle(td, size: Ts.md, color: t.text3),
        labelStyle: Ts.themedStyle(td, size: Ts.md, color: t.text2),
        floatingLabelStyle: Ts.themedStyle(td, size: Ts.sm, color: t.focus),
        errorStyle: Ts.themedStyle(td, size: Ts.xs, color: t.danger),
        prefixIconColor: t.text3,
        suffixIconColor: t.text3,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: t.focus,
        selectionColor: t.selection,
        selectionHandleColor: t.accent,
      ),
      tabBarTheme: TabBarThemeData(
        indicatorSize: TabBarIndicatorSize.tab,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: t.accent, width: 2),
        ),
        overlayColor: const WidgetStatePropertyAll(transparent),
        dividerColor: t.hairline,
        labelColor: t.text,
        unselectedLabelColor: t.text3,
        labelStyle: Ts.themedStyle(td, size: Ts.md, weight: FontWeight.w600),
        unselectedLabelStyle: Ts.themedStyle(td, size: Ts.md),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.dragged) ? 8 : 6,
        ),
        radius: const Radius.circular(4),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => t.text3.withValues(
            alpha: states.contains(WidgetState.dragged)
                ? 0.7
                : states.contains(WidgetState.hovered)
                    ? 0.52
                    : 0.35,
          ),
        ),
        trackColor: const WidgetStatePropertyAll(transparent),
        trackBorderColor: const WidgetStatePropertyAll(transparent),
        thumbVisibility: const WidgetStatePropertyAll(false),
        trackVisibility: const WidgetStatePropertyAll(false),
        interactive: true,
      ),
    );
  }
}

/// Compatibility accessor for existing running/start call sites.
///
/// Operational success always resolves through the canonical semantic role;
/// callers can migrate to `AppTokens.of(context).success` without changing
/// paint behavior.
Color goGreen(BuildContext context) => AppTokens.of(context).success;

// ---------------------------------------------------------------------------
// Shared Redis type-colour triples for the style palettes (v1.3). Dark set =
// saturated fill + white text; light set = pastel fill + dark text; mono set =
// grayscale newspaper badges.
// ---------------------------------------------------------------------------
const _typeDarkString = RedisTypeColors(
    fill: Color(0xFF6A1DC3), fg: Color(0xFFFFFFFF), border: Color(0x4DFFFFFF));
const _typeDarkHash = RedisTypeColors(
    fill: Color(0xFF364CFF), fg: Color(0xFFFFFFFF), border: Color(0x4DFFFFFF));
const _typeDarkList = RedisTypeColors(
    fill: Color(0xFF008556), fg: Color(0xFFFFFFFF), border: Color(0x4DFFFFFF));
const _typeDarkSet = RedisTypeColors(
    fill: Color(0xFF9C5C2B), fg: Color(0xFFFFFFFF), border: Color(0x4DFFFFFF));
const _typeDarkZset = RedisTypeColors(
    fill: Color(0xFFA00A6B), fg: Color(0xFFFFFFFF), border: Color(0x4DFFFFFF));
const _typeDarkStream = RedisTypeColors(
    fill: Color(0xFF5A6B85), fg: Color(0xFFFFFFFF), border: Color(0x4DFFFFFF));
const _typeDarkJson = RedisTypeColors(
    fill: Color(0xFF3F4B5F), fg: Color(0xFFFFFFFF), border: Color(0x4DFFFFFF));

const _typeLightString = RedisTypeColors(
    fill: Color(0xFFC7B0EA), fg: Color(0xFF25231F), border: Color(0x6625231F));
const _typeLightHash = RedisTypeColors(
    fill: Color(0xFFCDDDF8), fg: Color(0xFF25231F), border: Color(0x6625231F));
const _typeLightList = RedisTypeColors(
    fill: Color(0xFFA5D4C3), fg: Color(0xFF0C4A33), border: Color(0x6625231F));
const _typeLightSet = RedisTypeColors(
    fill: Color(0xFFD4BAA7), fg: Color(0xFF5C320F), border: Color(0x6625231F));
const _typeLightZset = RedisTypeColors(
    fill: Color(0xFFD9A0C6), fg: Color(0xFF63113F), border: Color(0x6625231F));
const _typeLightStream = RedisTypeColors(
    fill: Color(0xFFB8C5DB), fg: Color(0xFF20335A), border: Color(0x6625231F));
const _typeLightJson = RedisTypeColors(
    fill: Color(0xFFDFE3EA), fg: Color(0xFF5F5A51), border: Color(0x6625231F));

const _typeMonoString = RedisTypeColors(
    fill: Color(0xFFF0F0EE), fg: Color(0xFF0A0A0A), border: Color(0x660A0A0A));
const _typeMonoHash = RedisTypeColors(
    fill: Color(0xFFE4E4E2), fg: Color(0xFF0A0A0A), border: Color(0x660A0A0A));
const _typeMonoList = RedisTypeColors(
    fill: Color(0xFFD8D8D6), fg: Color(0xFF0A0A0A), border: Color(0x660A0A0A));
const _typeMonoSet = RedisTypeColors(
    fill: Color(0xFFCCCCCA), fg: Color(0xFF0A0A0A), border: Color(0x660A0A0A));
const _typeMonoZset = RedisTypeColors(
    fill: Color(0xFFBFBFBD), fg: Color(0xFF0A0A0A), border: Color(0x660A0A0A));
const _typeMonoStream = RedisTypeColors(
    fill: Color(0xFFB3B3B1), fg: Color(0xFF0A0A0A), border: Color(0x660A0A0A));
const _typeMonoJson = RedisTypeColors(
    fill: Color(0xFFA6A6A4), fg: Color(0xFF0A0A0A), border: Color(0x660A0A0A));

// ---------------------------------------------------------------------------
// AppStyle (v1.3): the seven selectable named palettes. Parchment is the
// historical default; the other six come from the bold-recolor mockups.
// ---------------------------------------------------------------------------
enum AppStyle { parchment, forest, midnight, charcoal, brick, aubergine, mono }

extension AppStyleX on AppStyle {
  /// Stable on-disk identifier written to ~/.redimosmanager/theme.json.
  String get id {
    switch (this) {
      case AppStyle.parchment:
        return 'parchment';
      case AppStyle.forest:
        return 'forest';
      case AppStyle.midnight:
        return 'midnight';
      case AppStyle.charcoal:
        return 'charcoal';
      case AppStyle.brick:
        return 'brick';
      case AppStyle.aubergine:
        return 'aubergine';
      case AppStyle.mono:
        return 'mono';
    }
  }

  /// Display name shown in the topbar style menu.
  String get label {
    switch (this) {
      case AppStyle.parchment:
        return 'Parchment';
      case AppStyle.forest:
        return 'Forest';
      case AppStyle.midnight:
        return 'Midnight';
      case AppStyle.charcoal:
        return 'Charcoal';
      case AppStyle.brick:
        return 'Brick';
      case AppStyle.aubergine:
        return 'Aubergine';
      case AppStyle.mono:
        return 'Mono';
    }
  }

  /// Material scaffold brightness: three light palettes, four dark ones.
  Brightness get brightness {
    switch (this) {
      case AppStyle.parchment:
      case AppStyle.brick:
      case AppStyle.mono:
        return Brightness.light;
      case AppStyle.forest:
      case AppStyle.midnight:
      case AppStyle.charcoal:
      case AppStyle.aubergine:
        return Brightness.dark;
    }
  }

  /// The palette's complete token set. Parchment aliases the historical
  /// `AppTokens.light` so the default path is byte-identical to before.
  AppTokens get tokens {
    switch (this) {
      case AppStyle.parchment:
        return AppTokens.light;
      case AppStyle.forest:
        return AppTokens.forest;
      case AppStyle.midnight:
        return AppTokens.midnight;
      case AppStyle.charcoal:
        return AppTokens.charcoal;
      case AppStyle.brick:
        return AppTokens.brick;
      case AppStyle.aubergine:
        return AppTokens.aubergine;
      case AppStyle.mono:
        return AppTokens.mono;
    }
  }

  /// Parse a persisted id; unknown / empty → null (caller falls back).
  static AppStyle? fromId(String id) {
    for (final s in AppStyle.values) {
      if (s.id == id) return s;
    }
    return null;
  }
}
