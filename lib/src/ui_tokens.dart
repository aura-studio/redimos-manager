import 'package:flutter/material.dart';

/// v2.3 design tokens (source of truth: base2.css). Two static instances,
/// light and dark, exposed as a ThemeExtension so any widget can read
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

  // Type colour phases (seven): STRING/HASH/LIST/SET/ZSET/STREAM/JSON.
  // Light = pastel fill + navy text; dark = saturated fill + white text.
  final RedisTypeColors typeString;
  final RedisTypeColors typeHash;
  final RedisTypeColors typeList;
  final RedisTypeColors typeSet;
  final RedisTypeColors typeZset;
  final RedisTypeColors typeStream;
  final RedisTypeColors typeJson;

  // ---------------------------------------------------------------- rail ---
  /// The rail stays dark navy regardless of theme (v2.3 constant).
  static const Color railBg = Color(0xFF0F1633);
  static const Color railFg = Color(0xFF8F9AC2);
  static const Color railFgActive = Color(0xFFC3D0FF);
  static const Color railActiveBg = Color(0x298BA2FF); // rgba(139,162,255,.16)
  static const Color railGlow = Color(0x668BA2FF); // rgba(139,162,255,.4)

  /// v2.3 rail vertical gradient (#141c42 → #0f1633 52% → #0c1229).
  static const LinearGradient railGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF141C42), Color(0xFF0F1633), Color(0xFF0C1229)],
    stops: [0.0, 0.52, 1.0],
  );

  /// Rail active left indicator gradient (#d0daff → #8ba2ff).
  static const LinearGradient railIndicatorGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFFD0DAFF), Color(0xFF8BA2FF)],
  );

  // ------------------------------------------------------------ instances ---
  static const AppTokens light = AppTokens(
    bg: Color(0xFFFFFFFF),
    panel: Color(0xFFFFFFFF),
    panel2: Color(0xFFF6F7F9),
    sidebar: Color(0xFFFFFFFF),
    border: Color(0xFFC1CBD9),
    hairline: Color(0xFFE4EAF2),
    text: Color(0xFF173369),
    text2: Color(0xFF415681),
    text3: Color(0xFF7A8BB0),
    accent: Color(0xFF3953C3),
    onAccent: Color(0xFFFFFFFF),
    hover: Color(0xFFE9EDFA),
    selection: Color(0xFFD7E3FA),
    focus: Color(0xFF3953C3),
    danger: Color(0xFFAD0017),
    success: Color(0xFF13A450),
    warning: Color(0xFF9D6901),
    highlight: Color(0xD9FFFFFF), // rgba(255,255,255,.85)
    highlightSoft: Color(0x8CFFFFFF), // rgba(255,255,255,.55)
    // Light type phases: pastel fill, navy-ish text, 1px outline.
    typeString: RedisTypeColors(fill: Color(0xFFC7B0EA), fg: Color(0xFF173369), border: Color(0x7B173369)),
    typeHash: RedisTypeColors(fill: Color(0xFFCDDDF8), fg: Color(0xFF173369), border: Color(0x7B173369)),
    typeList: RedisTypeColors(fill: Color(0xFFA5D4C3), fg: Color(0xFF0C4A33), border: Color(0x7B173369)),
    typeSet: RedisTypeColors(fill: Color(0xFFD4BAA7), fg: Color(0xFF5C320F), border: Color(0x7B173369)),
    typeZset: RedisTypeColors(fill: Color(0xFFD9A0C6), fg: Color(0xFF63113F), border: Color(0x7B173369)),
    typeStream: RedisTypeColors(fill: Color(0xFFB8C5DB), fg: Color(0xFF20335A), border: Color(0x7B173369)),
    typeJson: RedisTypeColors(fill: Color(0xFFDFE3EA), fg: Color(0xFF415681), border: Color(0x7B173369)),
  );

  static const AppTokens dark = AppTokens(
    bg: Color(0xFF121212),
    panel: Color(0xFF202020),
    panel2: Color(0xFF171717),
    sidebar: Color(0xFF161616),
    border: Color(0xFF3D3D3D),
    hairline: Color(0xFF2B2B2B),
    text: Color(0xFFDFE5EF),
    text2: Color(0xFFB5B6C0),
    text3: Color(0xFF7D7F8A),
    accent: Color(0xFF8BA2FF),
    onAccent: Color(0xFF10142E),
    hover: Color(0xFF2B2B2B),
    selection: Color(0xFF002F47),
    focus: Color(0xFF8BA2FF),
    danger: Color(0xFFFF6280),
    success: Color(0xFF5BC69B),
    warning: Color(0xFFFFAF2B),
    highlight: Color(0x17FFFFFF), // rgba(255,255,255,.09)
    highlightSoft: Color(0x0DFFFFFF), // rgba(255,255,255,.05)
    // Dark type phases: saturated fill + white text.
    typeString: RedisTypeColors(fill: Color(0xFF6A1DC3), fg: Color(0xFFFFFFFF), border: Color(0x4DFFFFFF)),
    typeHash: RedisTypeColors(fill: Color(0xFF364CFF), fg: Color(0xFFFFFFFF), border: Color(0x4DFFFFFF)),
    typeList: RedisTypeColors(fill: Color(0xFF008556), fg: Color(0xFFFFFFFF), border: Color(0x4DFFFFFF)),
    typeSet: RedisTypeColors(fill: Color(0xFF9C5C2B), fg: Color(0xFFFFFFFF), border: Color(0x4DFFFFFF)),
    typeZset: RedisTypeColors(fill: Color(0xFFA00A6B), fg: Color(0xFFFFFFFF), border: Color(0x4DFFFFFF)),
    typeStream: RedisTypeColors(fill: Color(0xFF5A6B85), fg: Color(0xFFFFFFFF), border: Color(0x4DFFFFFF)),
    typeJson: RedisTypeColors(fill: Color(0xFF3F4B5F), fg: Color(0xFFFFFFFF), border: Color(0x4DFFFFFF)),
  );

  static AppTokens of(BuildContext context) {
    final ext = Theme.of(context).extension<AppTokens>();
    assert(ext != null, 'AppTokens not registered on the theme');
    return ext!;
  }

  /// Resolve by brightness without context (e.g. inside theme factories).
  static AppTokens forBrightness(Brightness b) => b == Brightness.dark ? dark : light;

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
  AppTokens copyWith() => this; // tokens are immutable constants; no partial copy needed

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) =>
      t < 0.5 ? this : (other as AppTokens? ?? this);
}

/// Fill / foreground / outline triple for one Redis key-type phase.
class RedisTypeColors {
  const RedisTypeColors({required this.fill, required this.fg, required this.border});
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

  /// UI font stack — bundled Inter first (pixel-fidelity-v23 CP 4.7), then
  /// system sans for CJK + platforms without the bundled face
  /// (SF Pro on macOS, Segoe UI on Windows, …).
  static const List<String> sans = [
    'Inter',
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

  /// Data/mono stack — the bundled JetBrains Mono is registered under the
  /// family name `monospace` (pixel-fidelity-v23 CP 4.5), so leading with it
  /// here and in the bare `fontFamily: 'monospace'` styles both resolve to
  /// the same face; system mono fallbacks cover CJK.
  static const List<String> mono = [
    'monospace',
    'ui-monospace',
    'SF Mono',
    'Menlo',
    'Consolas',
    'Courier',
  ];

  /// Tabular figures for all numeric readouts (metrics, latency, counts).
  static const List<FontFeature> tabular = [FontFeature('tnum')];

  /// CSS half-leading line boxes (CP 5.1): Flutter's default leading
  /// distribution is proportional (ascent-weighted), so any text given an
  /// explicit `height` sits off-centre in its line box versus the CSS mockups,
  /// which use half-leading. even splits the added leading above/below.
  static const TextLeadingDistribution cssLeading = TextLeadingDistribution.even;

  /// ThemeData/TextTheme.apply have no leading hook, so stamp [cssLeading]
  /// onto every theme style: the theme-derived DefaultTextStyle then gives
  /// CSS leading semantics to all text that doesn't override it.
  static TextTheme withCssLeading(TextTheme tt) => tt.copyWith(
        displayLarge: tt.displayLarge?.copyWith(leadingDistribution: cssLeading),
        displayMedium: tt.displayMedium?.copyWith(leadingDistribution: cssLeading),
        displaySmall: tt.displaySmall?.copyWith(leadingDistribution: cssLeading),
        headlineLarge: tt.headlineLarge?.copyWith(leadingDistribution: cssLeading),
        headlineMedium: tt.headlineMedium?.copyWith(leadingDistribution: cssLeading),
        headlineSmall: tt.headlineSmall?.copyWith(leadingDistribution: cssLeading),
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
        // theme's ui family wins the merge and values render proportional
        // (and a bare null family degrades to the test env's box glyphs).
        fontFamily: monoFont ? mono.first : null,
        fontFamilyFallback: monoFont ? mono : sans,
        fontFeatures: tabularNums ? tabular : null,
      );
}

// ---------------------------------------------------------------------------
// Depth / elevation helpers (R1.5, R1.6) — v2.3 composite "D": hairline
// highlights + two soft elevations + sunken wells + rail gradients.
// ---------------------------------------------------------------------------
class Depth {
  Depth._();

  /// elev-1: horizontal bars (topbar, midbar). CSS box-shadow blur = 2σ while
  /// Flutter blurRadius = σ, so the CSS values are HALVED (CP 6.1):
  /// light `0 1px 2px rgba(23,51,105,.07)` / dark `0 2px 4px rgba(0,0,0,.55)`.
  static List<BoxShadow> elev1(Brightness b) => b == Brightness.dark
      ? const [BoxShadow(color: Color(0x8C000000), blurRadius: 2, offset: Offset(0, 2))]
      : const [BoxShadow(color: Color(0x12173369), blurRadius: 1, offset: Offset(0, 1))];

  /// elev-2: cards (valuepanes, cmd blocks, spark tiles, info tiles, ov-cards,
  /// cfg-sections). Blur halved (CP 6.2): light `0 1px 2px rgba(23,51,105,.05)`
  /// + `0 4px 14px rgba(23,51,105,.08)` / dark `0 1px 3px rgba(0,0,0,.5)` +
  /// `0 8px 24px rgba(0,0,0,.35)`.
  static List<BoxShadow> elev2(Brightness b) => b == Brightness.dark
      ? const [
          BoxShadow(color: Color(0x80000000), blurRadius: 1.5, offset: Offset(0, 1)),
          BoxShadow(color: Color(0x59000000), blurRadius: 12, offset: Offset(0, 8)),
        ]
      : const [
          BoxShadow(color: Color(0x0D173369), blurRadius: 1, offset: Offset(0, 1)),
          BoxShadow(color: Color(0x14173369), blurRadius: 7, offset: Offset(0, 4)),
        ];

  /// Sidebar soft right-edge shadow. Blur halved (CP 6.3):
  /// light `2px 0 6px rgba(23,51,105,.08)` / dark `2px 0 8px rgba(0,0,0,.5)`.
  static List<BoxShadow> elevSide(Brightness b) => b == Brightness.dark
      ? const [BoxShadow(color: Color(0x80000000), blurRadius: 4, offset: Offset(2, 0))]
      : const [BoxShadow(color: Color(0x14173369), blurRadius: 3, offset: Offset(2, 0))];

  /// Rail's right-edge shadow, layered (CP 6.4). Mockup v2.4 override:
  /// `6px 0 18px -8px rgba(8,12,32,.55)` — blur halved, offset corrected to
  /// the CSS 6px and colour matched; the tight second layer approximates the
  /// -8px spread's darkened contact edge.
  static List<BoxShadow> railShadow = const [
    BoxShadow(color: Color(0x8C080C20), blurRadius: 9, offset: Offset(6, 0)),
    BoxShadow(color: Color(0x33080C20), blurRadius: 3, offset: Offset(1, 0)),
  ];

  /// Rail active item glow — CSS `0 0 12px rgba(139,162,255,.4)`, blur halved
  /// (CP 6.5).
  static List<BoxShadow> railItemGlow = const [
    BoxShadow(color: AppTokens.railGlow, blurRadius: 6, spreadRadius: 0),
  ];

  /// Top-edge hairline highlight — Flutter has no inset shadow, so we fake
  /// the top 1px inner highlight with a top border of the highlight colour.
  static Border topHighlight(Color hl) => Border(top: BorderSide(color: hl, width: 1));

  /// Sunken wells (CP 6.9): Flutter fakes the CSS inset shadow with a top
  /// black→transparent gradient strip. Two tiers matching the mockup —
  /// cli-body `inset 0 2px 5px rgba(23,51,105,.06)` (dark `0 2px 6px
  /// rgba(0,0,0,.45)`) vs logs-body `inset 0 1px 3px rgba(23,51,105,.06)`
  /// (dark `0 1px 4px rgba(0,0,0,.5)`).
  static BoxDecoration wellTopCli(Brightness b) => _well(
      b == Brightness.dark ? const Color(0x73000000) : const Color(0x0F173369));

  static BoxDecoration wellTopLogs(Brightness b) => _well(
      b == Brightness.dark ? const Color(0x80000000) : const Color(0x0F173369));

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
/// targets, no M3 surface tints, no ornamented inputs. Both theme factories —
/// main.dart `_appTheme` and test/screen_fixtures.dart `goldenTheme` — apply
/// this ONE builder, so the live app and the golden/capture channels can
/// never drift apart (the hand-mirrored themes are the known false-green
/// trap).
class MatSuppress {
  MatSuppress._();

  static ThemeData apply(ThemeData td, AppTokens t) {
    final radius = BorderRadius.circular(Dim.radiusS);
    return td.copyWith(
      // CP 7.1 — kill InkWell ripple/highlight; pressed states stay silent,
      // matching the static mockups.
      splashFactory: NoSplash.splashFactory,
      highlightColor: const Color(0x00000000),
      // CP 7.2 — mockup .ibtn/.tbtn: zero padding, compact density, 26px
      // (.ibtn) floor; call sites that want the 30px .tbtn tier already pass
      // explicit constraints, which win over the theme minimum.
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          minimumSize: const Size(26, 26),
          // Mockup .ibtn/.tbtn colour is var(--text-2). This SDK's
          // styleFrom names the icon colour foregroundColor.
          foregroundColor: t.text2,
          // styleFrom derives hover/press overlays from foregroundColor;
          // the mockups are static, so silence those too (CP 7.1).
          overlayColor: const Color(0x00000000),
        ),
      ),
      // CP 7.3 — bare Icon()s read the token grey instead of M3 onSurface.
      iconTheme: IconThemeData(color: t.text2),
      // CP 7.4 — menus were never mocked; dock them to the v2.3 surface
      // tokens (--shadow-lg tier, panel bg, radius-sm) and kill the M3
      // surface-tint chrome.
      popupMenuTheme: PopupMenuThemeData(
        color: t.panel,
        surfaceTintColor: const Color(0x00000000),
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: radius),
        menuPadding: const EdgeInsets.symmetric(vertical: 4),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(t.panel),
          surfaceTintColor: const WidgetStatePropertyAll(Color(0x00000000)),
          elevation: const WidgetStatePropertyAll(8),
          shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: radius)),
          padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(vertical: 4)),
        ),
      ),
      // CP 7.6 — mockup .f-input baseline: 30px control, 0 10px padding,
      // radius-sm, 1px --border. Borderless inputs that sit inside styled
      // containers shield themselves with contentPadding: EdgeInsets.zero
      // (search box, console/CLI input).
      // Base `border` slot ONLY: a theme-level enabledBorder/focusedBorder
      // would outrank a WIDGET-level base border (input_decorator resolves
      // state borders before _getDefaultBorder) and would stamp outline
      // boxes onto InputBorder.none embeds. The base slot is the one the
      // widget's own border wins against.
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
        border: OutlineInputBorder(
            borderRadius: radius, borderSide: BorderSide(color: t.border)),
        hintStyle: Ts.style(size: Ts.md, color: t.text3),
      ),
      // CP 7.7 — no TabBar widgets exist (midbar/cli/ktabs are hand-rolled
      // to the .mtab 2px-accent underline); pin the theme so any future
      // TabBar inherits the same look, with the M3 overlay removed.
      tabBarTheme: TabBarThemeData(
        indicatorSize: TabBarIndicatorSize.label,
        overlayColor: const WidgetStatePropertyAll(Color(0x00000000)),
        dividerColor: t.border,
        labelColor: t.text,
        unselectedLabelColor: t.text3,
      ),
      // CP 7.8 — the mockups render native auto-hiding scrollbars (no CSS
      // scrollbar rules exist). Match a neutral thumb, never force
      // visibility: rest-state captures stay scrollbar-free like the
      // mockups'.
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(4),
        thumbColor: WidgetStatePropertyAll(t.text3.withValues(alpha: 0.35)),
        trackColor: const WidgetStatePropertyAll(Color(0x00000000)),
        trackBorderColor: const WidgetStatePropertyAll(Color(0x00000000)),
        thumbVisibility: const WidgetStatePropertyAll(false),
        trackVisibility: const WidgetStatePropertyAll(false),
      ),
    );
  }
}

// The "running / start" green. greenAccent is bright on dark surfaces but too
// pale on a light background, so use a deeper green there. Panel-only (the
// sidebar LocalDdbPanel) — the dashboard tile grammar lives in
// src/monitor_widgets.dart since the 2026-08-05 separation. (Moved here from
// main.dart in CP 9.x so the extracted home chrome can share it without an
// import cycle.)
Color goGreen(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? Colors.greenAccent
    : const Color(0xFF12994F);
