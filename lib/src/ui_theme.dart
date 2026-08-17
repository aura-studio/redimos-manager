import 'package:flutter/material.dart';

import 'ui_tokens.dart';

/// The app-wide desktop scrolling contract. Material's behavior preserves
/// native mouse-wheel and trackpad routing, adds transient vertical scrollbars
/// on desktop, and deliberately leaves horizontal bars to bounded data views.
const ScrollBehavior appScrollBehavior = MaterialScrollBehavior();

/// The single complete theme factory used by the app, goldens, and captures.
///
/// [fontFamily] lets deterministic tests inject their registered UI face while
/// production defaults to the bundled Inter family. Both paths retain the same
/// platform/CJK fallback chain and Material component typography.
ThemeData appTheme(
  Brightness brightness, {
  String? fontFamily,
}) =>
    _buildTheme(AppTokens.forBrightness(brightness), brightness,
        fontFamily: fontFamily);

/// Style-driven factory for the seven selectable palettes (v1.3). The
/// Brightness-based [appTheme] above is byte-identical to before and remains
/// the entry point for goldens and the capture layer.
ThemeData appThemeForStyle(
  AppStyle style, {
  String? fontFamily,
}) =>
    _buildTheme(style.tokens, style.brightness, fontFamily: fontFamily);

ThemeData _buildTheme(
  AppTokens tokens,
  Brightness brightness, {
  String? fontFamily,
}) {
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: tokens.bg,
    dividerColor: tokens.hairline,
    fontFamily: fontFamily ?? Ts.uiFamily,
    // colorSchemeSeed would re-derive every role from the accent instead of
    // preserving the deliberately tuned token surfaces.
    colorScheme: brightness == Brightness.dark
        ? const ColorScheme.dark()
            .copyWith(primary: tokens.accent, surface: tokens.panel)
        : const ColorScheme.light()
            .copyWith(primary: tokens.accent, surface: tokens.panel),
    extensions: [tokens],
    fontFamilyFallback: Ts.sansFallback,
    dividerTheme: DividerThemeData(
      thickness: 1,
      space: 1,
      color: tokens.hairline,
    ),
  );

  return MatSuppress.apply(
    base.copyWith(textTheme: Ts.withCssLeading(base.textTheme)),
    tokens,
  );
}
