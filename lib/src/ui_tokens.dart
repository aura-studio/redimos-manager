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

  /// Sky: airy blue-tinted white surfaces, classic blue accent.
  static const AppTokens sky = AppTokens(
    bg: Color(0xFFF2F6FA),
    panel: Color(0xFFFFFFFF),
    panel2: Color(0xFFE8F0F7),
    sidebar: Color(0xFFEDF3F9),
    border: Color(0xFFB9CCDD),
    hairline: Color(0xFFD7E3EE),
    text: Color(0xFF1B2A3A),
    text2: Color(0xFF46586B),
    text3: Color(0xFF6A7D92),
    accent: Color(0xFF2F7DE1),
    onAccent: Color(0xFFFFFFFF),
    hover: Color(0xFFE8F0F7),
    selection: Color(0xFFD3E4F6),
    focus: Color(0xFF1F63B8),
    danger: Color(0xFFC0283B),
    success: Color(0xFF177A46),
    warning: Color(0xFF96620A),
    highlight: Color(0xD9FFFFFF),
    highlightSoft: Color(0x8CFFFFFF),
    railBg: Color(0xFFE7EFF6),
    railBgTop: Color(0xFFECF3F9),
    railBgBottom: Color(0xFFE1EAF3),
    railFg: Color(0xFF6A7D92),
    railFgActive: Color(0xFF1F63B8),
    railActiveBg: Color(0xFFCBE0F4),
    railGlow: Color(0x402F7DE1),
    railIndicatorTop: Color(0xFF2F7DE1),
    railIndicatorBottom: Color(0xFF2F7DE1),
    typeString: _typeLightString,
    typeHash: _typeLightHash,
    typeList: _typeLightList,
    typeSet: _typeLightSet,
    typeZset: _typeLightZset,
    typeStream: _typeLightStream,
    typeJson: _typeLightJson,
  );

  /// Sakura: warm blush-pink surfaces, rose accent.
  static const AppTokens sakura = AppTokens(
    bg: Color(0xFFFBF3F4),
    panel: Color(0xFFFFFBFB),
    panel2: Color(0xFFF6E7E9),
    sidebar: Color(0xFFF8EDEE),
    border: Color(0xFFDDBEC3),
    hairline: Color(0xFFEEDADD),
    text: Color(0xFF3A2028),
    text2: Color(0xFF6E4750),
    text3: Color(0xFF8F6B74),
    accent: Color(0xFFD14D6B),
    onAccent: Color(0xFFFFF7F8),
    hover: Color(0xFFF6E7E9),
    selection: Color(0xFFF5D3DA),
    focus: Color(0xFFAE3551),
    danger: Color(0xFFAD0017),
    success: Color(0xFF1A7A4A),
    warning: Color(0xFF8A5A00),
    highlight: Color(0xD9FFFFFF),
    highlightSoft: Color(0x8CFFFFFF),
    railBg: Color(0xFFF4E5E7),
    railBgTop: Color(0xFFF8EBED),
    railBgBottom: Color(0xFFF0DEE1),
    railFg: Color(0xFF8F6B74),
    railFgActive: Color(0xFFAE3551),
    railActiveBg: Color(0xFFF3CBD4),
    railGlow: Color(0x40D14D6B),
    railIndicatorTop: Color(0xFFD14D6B),
    railIndicatorBottom: Color(0xFFD14D6B),
    typeString: _typeLightString,
    typeHash: _typeLightHash,
    typeList: _typeLightList,
    typeSet: _typeLightSet,
    typeZset: _typeLightZset,
    typeStream: _typeLightStream,
    typeJson: _typeLightJson,
  );

  /// Mint: fresh green-tinted white surfaces, emerald accent.
  static const AppTokens mint = AppTokens(
    bg: Color(0xFFF1F8F4),
    panel: Color(0xFFFDFFFE),
    panel2: Color(0xFFE4F1E9),
    sidebar: Color(0xFFEBF5EF),
    border: Color(0xFFB6D4C2),
    hairline: Color(0xFFD4E7DC),
    text: Color(0xFF183128),
    text2: Color(0xFF3F5A50),
    text3: Color(0xFF64796F),
    accent: Color(0xFF1E9E6A),
    onAccent: Color(0xFFF2FFF9),
    hover: Color(0xFFE4F1E9),
    selection: Color(0xFFCBE9D9),
    focus: Color(0xFF137A50),
    danger: Color(0xFFBF1F38),
    success: Color(0xFF137A42),
    warning: Color(0xFF8A5A00),
    highlight: Color(0xD9FFFFFF),
    highlightSoft: Color(0x8CFFFFFF),
    railBg: Color(0xFFE2EFE7),
    railBgTop: Color(0xFFE9F4ED),
    railBgBottom: Color(0xFFDBEAE1),
    railFg: Color(0xFF64796F),
    railFgActive: Color(0xFF137A50),
    railActiveBg: Color(0xFFC2E4D1),
    railGlow: Color(0x401E9E6A),
    railIndicatorTop: Color(0xFF1E9E6A),
    railIndicatorBottom: Color(0xFF1E9E6A),
    typeString: _typeLightString,
    typeHash: _typeLightHash,
    typeList: _typeLightList,
    typeSet: _typeLightSet,
    typeZset: _typeLightZset,
    typeStream: _typeLightStream,
    typeJson: _typeLightJson,
  );

  /// Lilac: soft violet-tinted white surfaces, purple accent.
  static const AppTokens lilac = AppTokens(
    bg: Color(0xFFF7F4FB),
    panel: Color(0xFFFDFBFF),
    panel2: Color(0xFFEDE6F6),
    sidebar: Color(0xFFF2EDF9),
    border: Color(0xFFCDBFDF),
    hairline: Color(0xFFE2D9EF),
    text: Color(0xFF2A2140),
    text2: Color(0xFF56496E),
    text3: Color(0xFF7A6E92),
    accent: Color(0xFF7A4FD0),
    onAccent: Color(0xFFFBF8FF),
    hover: Color(0xFFEDE6F6),
    selection: Color(0xFFE0D2F2),
    focus: Color(0xFF5E34AE),
    danger: Color(0xFFBC2140),
    success: Color(0xFF177A46),
    warning: Color(0xFF8A5A00),
    highlight: Color(0xD9FFFFFF),
    highlightSoft: Color(0x8CFFFFFF),
    railBg: Color(0xFFEBE3F5),
    railBgTop: Color(0xFFF0E9F8),
    railBgBottom: Color(0xFFE6DCEF),
    railFg: Color(0xFF7A6E92),
    railFgActive: Color(0xFF5E34AE),
    railActiveBg: Color(0xFFDAC7EE),
    railGlow: Color(0x407A4FD0),
    railIndicatorTop: Color(0xFF7A4FD0),
    railIndicatorBottom: Color(0xFF7A4FD0),
    typeString: _typeLightString,
    typeHash: _typeLightHash,
    typeList: _typeLightList,
    typeSet: _typeLightSet,
    typeZset: _typeLightZset,
    typeStream: _typeLightStream,
    typeJson: _typeLightJson,
  );

  /// Honey: warm amber-cream surfaces, orange accent.
  static const AppTokens honey = AppTokens(
    bg: Color(0xFFFBF6EA),
    panel: Color(0xFFFEFCF4),
    panel2: Color(0xFFF5EAD3),
    sidebar: Color(0xFFF8F1E0),
    border: Color(0xFFDCC7A2),
    hairline: Color(0xFFEDDFC2),
    text: Color(0xFF3A2C14),
    text2: Color(0xFF6E5A36),
    text3: Color(0xFF8F7B56),
    accent: Color(0xFFDE8A12),
    onAccent: Color(0xFF2E1F04),
    hover: Color(0xFFF5EAD3),
    selection: Color(0xFFF6E0B4),
    focus: Color(0xFFB46C08),
    danger: Color(0xFFB01E2E),
    success: Color(0xFF177A46),
    warning: Color(0xFF8A5A00),
    highlight: Color(0xD9FFFFFF),
    highlightSoft: Color(0x8CFFFFFF),
    railBg: Color(0xFFF4EAD2),
    railBgTop: Color(0xFFF8EFDC),
    railBgBottom: Color(0xFFF0E4C8),
    railFg: Color(0xFF8F7B56),
    railFgActive: Color(0xFFB46C08),
    railActiveBg: Color(0xFFF2D9A6),
    railGlow: Color(0x40DE8A12),
    railIndicatorTop: Color(0xFFDE8A12),
    railIndicatorBottom: Color(0xFFDE8A12),
    typeString: _typeLightString,
    typeHash: _typeLightHash,
    typeList: _typeLightList,
    typeSet: _typeLightSet,
    typeZset: _typeLightZset,
    typeStream: _typeLightStream,
    typeJson: _typeLightJson,
  );

  /// Lagoon: deep teal surfaces, turquoise accent.
  static const AppTokens lagoon = AppTokens(
    bg: Color(0xFF0E1A1C),
    panel: Color(0xFF142224),
    panel2: Color(0xFF1A2B2D),
    sidebar: Color(0xFF111F21),
    border: Color(0xFF2E4548),
    hairline: Color(0xFF23373A),
    text: Color(0xFFE4F0EE),
    text2: Color(0xFFA6BCB7),
    text3: Color(0xFF869B96),
    accent: Color(0xFF2ED3C6),
    onAccent: Color(0xFF08201E),
    hover: Color(0xFF1A2B2D),
    selection: Color(0xFF1E4442),
    focus: Color(0xFF1FA89D),
    danger: Color(0xFFFF6B6B),
    success: Color(0xFF4CC27A),
    warning: Color(0xFFE8C35A),
    highlight: Color(0x17FFFFFF),
    highlightSoft: Color(0x0DFFFFFF),
    railBg: Color(0xFF0B1516),
    railBgTop: Color(0xFF0E1A1B),
    railBgBottom: Color(0xFF081112),
    railFg: Color(0xFF869B96),
    railFgActive: Color(0xFF7FE8DF),
    railActiveBg: Color(0xFF143A3B),
    railGlow: Color(0x402ED3C6),
    railIndicatorTop: Color(0xFF2ED3C6),
    railIndicatorBottom: Color(0xFF2ED3C6),
    typeString: _typeDarkString,
    typeHash: _typeDarkHash,
    typeList: _typeDarkList,
    typeSet: _typeDarkSet,
    typeZset: _typeDarkZset,
    typeStream: _typeDarkStream,
    typeJson: _typeDarkJson,
  );

  /// Wine: deep burgundy surfaces, rose-red accent.
  static const AppTokens wine = AppTokens(
    bg: Color(0xFF1F1216),
    panel: Color(0xFF271820),
    panel2: Color(0xFF2F1E28),
    sidebar: Color(0xFF24151C),
    border: Color(0xFF4A2E3A),
    hairline: Color(0xFF3A2430),
    text: Color(0xFFF3E7EB),
    text2: Color(0xFFC2AAB4),
    text3: Color(0xFFA08A94),
    accent: Color(0xFFE05D7C),
    onAccent: Color(0xFF2E0A16),
    hover: Color(0xFF2F1E28),
    selection: Color(0xFF4A2434),
    focus: Color(0xFFBC3E5E),
    danger: Color(0xFFFF7A6B),
    success: Color(0xFF6FD3A0),
    warning: Color(0xFFE8C98A),
    highlight: Color(0x17FFFFFF),
    highlightSoft: Color(0x0DFFFFFF),
    railBg: Color(0xFF190E13),
    railBgTop: Color(0xFF1D1218),
    railBgBottom: Color(0xFF150B10),
    railFg: Color(0xFFA08A94),
    railFgActive: Color(0xFFF09AAC),
    railActiveBg: Color(0xFF3E1F2C),
    railGlow: Color(0x40E05D7C),
    railIndicatorTop: Color(0xFFE05D7C),
    railIndicatorBottom: Color(0xFFE05D7C),
    typeString: _typeDarkString,
    typeHash: _typeDarkHash,
    typeList: _typeDarkList,
    typeSet: _typeDarkSet,
    typeZset: _typeDarkZset,
    typeStream: _typeDarkStream,
    typeJson: _typeDarkJson,
  );

  /// Olive: dark moss-green surfaces, chartreuse accent.
  static const AppTokens olive = AppTokens(
    bg: Color(0xFF191B14),
    panel: Color(0xFF212319),
    panel2: Color(0xFF292C1F),
    sidebar: Color(0xFF1D1F16),
    border: Color(0xFF3F4430),
    hairline: Color(0xFF313626),
    text: Color(0xFFECEFE0),
    text2: Color(0xFFB7BDA2),
    text3: Color(0xFF979D84),
    accent: Color(0xFFC0D74E),
    onAccent: Color(0xFF23260F),
    hover: Color(0xFF292C1F),
    selection: Color(0xFF3A4022),
    focus: Color(0xFF9BB22F),
    danger: Color(0xFFFF6B5E),
    success: Color(0xFF57C785),
    warning: Color(0xFFE8C35A),
    highlight: Color(0x17FFFFFF),
    highlightSoft: Color(0x0DFFFFFF),
    railBg: Color(0xFF14160F),
    railBgTop: Color(0xFF181A12),
    railBgBottom: Color(0xFF10120C),
    railFg: Color(0xFF979D84),
    railFgActive: Color(0xFFD8EA8C),
    railActiveBg: Color(0xFF33381E),
    railGlow: Color(0x40C0D74E),
    railIndicatorTop: Color(0xFFC0D74E),
    railIndicatorBottom: Color(0xFFC0D74E),
    typeString: _typeDarkString,
    typeHash: _typeDarkHash,
    typeList: _typeDarkList,
    typeSet: _typeDarkSet,
    typeZset: _typeDarkZset,
    typeStream: _typeDarkStream,
    typeJson: _typeDarkJson,
  );

  /// Neon: near-black cyber surfaces, electric cyan accent.
  static const AppTokens neon = AppTokens(
    bg: Color(0xFF0D0F14),
    panel: Color(0xFF131720),
    panel2: Color(0xFF1A1F2B),
    sidebar: Color(0xFF10131A),
    border: Color(0xFF2C3444),
    hairline: Color(0xFF212838),
    text: Color(0xFFE6EDF7),
    text2: Color(0xFFA8B5C9),
    text3: Color(0xFF8794A8),
    accent: Color(0xFF2BD9E8),
    onAccent: Color(0xFF062228),
    hover: Color(0xFF1A1F2B),
    selection: Color(0xFF1C3446),
    focus: Color(0xFF17AAB8),
    danger: Color(0xFFFF5470),
    success: Color(0xFF3FD68F),
    warning: Color(0xFFF0C04A),
    highlight: Color(0x17FFFFFF),
    highlightSoft: Color(0x0DFFFFFF),
    railBg: Color(0xFF0A0C10),
    railBgTop: Color(0xFF0D1015),
    railBgBottom: Color(0xFF07090C),
    railFg: Color(0xFF8794A8),
    railFgActive: Color(0xFF7FECF5),
    railActiveBg: Color(0xFF142E3A),
    railGlow: Color(0x402BD9E8),
    railIndicatorTop: Color(0xFF2BD9E8),
    railIndicatorBottom: Color(0xFF2BD9E8),
    typeString: _typeDarkString,
    typeHash: _typeDarkHash,
    typeList: _typeDarkList,
    typeSet: _typeDarkSet,
    typeZset: _typeDarkZset,
    typeStream: _typeDarkStream,
    typeJson: _typeDarkJson,
  );

  /// Mocha: coffee-brown surfaces, caramel accent.
  static const AppTokens mocha = AppTokens(
    bg: Color(0xFF1C1512),
    panel: Color(0xFF241B17),
    panel2: Color(0xFF2C221C),
    sidebar: Color(0xFF201814),
    border: Color(0xFF463529),
    hairline: Color(0xFF382A21),
    text: Color(0xFFF1E6DC),
    text2: Color(0xFFC0AE9E),
    text3: Color(0xFF9E8B7A),
    accent: Color(0xFFD9995B),
    onAccent: Color(0xFF2A1706),
    hover: Color(0xFF2C221C),
    selection: Color(0xFF42301F),
    focus: Color(0xFFB87A40),
    danger: Color(0xFFFF7A6B),
    success: Color(0xFF7FCC8B),
    warning: Color(0xFFE8C35A),
    highlight: Color(0x17FFFFFF),
    highlightSoft: Color(0x0DFFFFFF),
    railBg: Color(0xFF16100D),
    railBgTop: Color(0xFF1A1410),
    railBgBottom: Color(0xFF120D0A),
    railFg: Color(0xFF9E8B7A),
    railFgActive: Color(0xFFEFC08E),
    railActiveBg: Color(0xFF37281B),
    railGlow: Color(0x40D9995B),
    railIndicatorTop: Color(0xFFD9995B),
    railIndicatorBottom: Color(0xFFD9995B),
    typeString: _typeDarkString,
    typeHash: _typeDarkHash,
    typeList: _typeDarkList,
    typeSet: _typeDarkSet,
    typeZset: _typeDarkZset,
    typeStream: _typeDarkStream,
    typeJson: _typeDarkJson,
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
// AppStyle (v1.3): the seventeen selectable named palettes. Parchment is the
// historical default; forest…mono come from the bold-recolor mockups, and
// sky…mocha extend the catalogue with five more light and five more dark.
// ---------------------------------------------------------------------------
enum AppStyle {
  parchment,
  forest,
  midnight,
  charcoal,
  brick,
  aubergine,
  mono,
  sky,
  sakura,
  mint,
  lilac,
  honey,
  lagoon,
  wine,
  olive,
  neon,
  mocha,
}

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
      case AppStyle.sky:
        return 'sky';
      case AppStyle.sakura:
        return 'sakura';
      case AppStyle.mint:
        return 'mint';
      case AppStyle.lilac:
        return 'lilac';
      case AppStyle.honey:
        return 'honey';
      case AppStyle.lagoon:
        return 'lagoon';
      case AppStyle.wine:
        return 'wine';
      case AppStyle.olive:
        return 'olive';
      case AppStyle.neon:
        return 'neon';
      case AppStyle.mocha:
        return 'mocha';
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
      case AppStyle.sky:
        return 'Sky';
      case AppStyle.sakura:
        return 'Sakura';
      case AppStyle.mint:
        return 'Mint';
      case AppStyle.lilac:
        return 'Lilac';
      case AppStyle.honey:
        return 'Honey';
      case AppStyle.lagoon:
        return 'Lagoon';
      case AppStyle.wine:
        return 'Wine';
      case AppStyle.olive:
        return 'Olive';
      case AppStyle.neon:
        return 'Neon';
      case AppStyle.mocha:
        return 'Mocha';
    }
  }

  /// Material scaffold brightness: eight light palettes, nine dark ones.
  Brightness get brightness {
    switch (this) {
      case AppStyle.parchment:
      case AppStyle.brick:
      case AppStyle.mono:
      case AppStyle.sky:
      case AppStyle.sakura:
      case AppStyle.mint:
      case AppStyle.lilac:
      case AppStyle.honey:
        return Brightness.light;
      case AppStyle.forest:
      case AppStyle.midnight:
      case AppStyle.charcoal:
      case AppStyle.aubergine:
      case AppStyle.lagoon:
      case AppStyle.wine:
      case AppStyle.olive:
      case AppStyle.neon:
      case AppStyle.mocha:
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
      case AppStyle.sky:
        return AppTokens.sky;
      case AppStyle.sakura:
        return AppTokens.sakura;
      case AppStyle.mint:
        return AppTokens.mint;
      case AppStyle.lilac:
        return AppTokens.lilac;
      case AppStyle.honey:
        return AppTokens.honey;
      case AppStyle.lagoon:
        return AppTokens.lagoon;
      case AppStyle.wine:
        return AppTokens.wine;
      case AppStyle.olive:
        return AppTokens.olive;
      case AppStyle.neon:
        return AppTokens.neon;
      case AppStyle.mocha:
        return AppTokens.mocha;
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
