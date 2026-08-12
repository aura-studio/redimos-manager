import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'golden_fonts.dart';
import 'screen_fixtures.dart' as fixtures;

void _noop() {}

double _contrastRatio(Color first, Color second) {
  final firstLuminance = first.computeLuminance();
  final secondLuminance = second.computeLuminance();
  final lighter =
      firstLuminance > secondLuminance ? firstLuminance : secondLuminance;
  final darker =
      firstLuminance > secondLuminance ? secondLuminance : firstLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}

void _expectContrast(
  Color foreground,
  Color background,
  double minimum, {
  required String role,
}) {
  expect(
    _contrastRatio(foreground, background),
    greaterThanOrEqualTo(minimum),
    reason: '$role must meet a $minimum:1 contrast ratio',
  );
}

void main() {
  group('appTheme', () {
    for (final brightness in Brightness.values) {
      test('builds the complete $brightness theme', () {
        final theme = appTheme(brightness);
        final expectedTokens = AppTokens.forBrightness(brightness);
        final tokenExtensions =
            theme.extensions.values.whereType<AppTokens>().toList();

        expect(theme.brightness, brightness);
        expect(theme.useMaterial3, isTrue);
        expect(theme.scaffoldBackgroundColor, expectedTokens.bg);
        expect(theme.colorScheme.primary, expectedTokens.accent);
        expect(theme.colorScheme.surface, expectedTokens.panel);
        expect(theme.dividerColor, expectedTokens.hairline);
        expect(theme.textTheme.bodyMedium?.fontFamily, Ts.uiFamily);
        expect(theme.textTheme.bodyMedium?.fontFamilyFallback,
            containsAll(Ts.sansFallback));
        expect(Ts.style().fontFamily, isNull);
        expect(Ts.themedStyle(theme).fontFamily, Ts.uiFamily);
        expect(
          Ts.themedStyle(theme, monoFont: true).fontFamily,
          Ts.monoFamily,
        );
        expect(
          theme.filledButtonTheme.style?.textStyle?.resolve({})?.fontFamily,
          Ts.uiFamily,
        );
        expect(
          theme.outlinedButtonTheme.style?.textStyle?.resolve({})?.fontFamily,
          Ts.uiFamily,
        );
        expect(
          theme.textButtonTheme.style?.textStyle?.resolve({})?.fontFamily,
          Ts.uiFamily,
        );
        expect(theme.popupMenuTheme.textStyle?.fontFamily, Ts.uiFamily);
        expect(theme.dropdownMenuTheme.textStyle?.fontFamily, Ts.uiFamily);
        expect(theme.dialogTheme.titleTextStyle?.fontFamily, Ts.uiFamily);
        expect(theme.tooltipTheme.textStyle?.fontFamily, Ts.uiFamily);
        expect(theme.tabBarTheme.labelStyle?.fontFamily, Ts.uiFamily);
        expect(tokenExtensions, hasLength(1));
        expect(tokenExtensions.single, same(expectedTokens));
        expect(theme.splashFactory, same(NoSplash.splashFactory));
        expect(theme.highlightColor, Colors.transparent);
        expect(theme.iconButtonTheme.style?.minimumSize?.resolve({}),
            const Size(26, 26));
        expect(theme.tabBarTheme.overlayColor?.resolve({}), Colors.transparent);
      });

      test('fixture delegates $brightness to appTheme', () {
        final direct = appTheme(brightness, fontFamily: kGoldenUiFont);
        final fixture = fixtures.goldenTheme(brightness);

        expect(fixture.brightness, direct.brightness);
        expect(fixture.colorScheme, direct.colorScheme);
        expect(fixture.scaffoldBackgroundColor, direct.scaffoldBackgroundColor);
        expect(fixture.dividerTheme, direct.dividerTheme);
        expect(fixture.splashFactory, same(direct.splashFactory));
        for (final states in <Set<WidgetState>>[
          {},
          {WidgetState.hovered},
          {WidgetState.focused},
          {WidgetState.pressed},
          {WidgetState.disabled},
        ]) {
          expect(
            fixture.iconButtonTheme.style?.backgroundColor?.resolve(states),
            direct.iconButtonTheme.style?.backgroundColor?.resolve(states),
          );
          expect(
            fixture.iconButtonTheme.style?.foregroundColor?.resolve(states),
            direct.iconButtonTheme.style?.foregroundColor?.resolve(states),
          );
          expect(
            fixture.iconButtonTheme.style?.side?.resolve(states),
            direct.iconButtonTheme.style?.side?.resolve(states),
          );
          expect(
            fixture.scrollbarTheme.thickness?.resolve(states),
            direct.scrollbarTheme.thickness?.resolve(states),
          );
          expect(
            fixture.scrollbarTheme.thumbColor?.resolve(states),
            direct.scrollbarTheme.thumbColor?.resolve(states),
          );
        }
        expect(
          fixture.iconButtonTheme.style?.minimumSize?.resolve({}),
          direct.iconButtonTheme.style?.minimumSize?.resolve({}),
        );
        final fixtureIndicator =
            fixture.tabBarTheme.indicator! as UnderlineTabIndicator;
        final directIndicator =
            direct.tabBarTheme.indicator! as UnderlineTabIndicator;
        expect(fixtureIndicator.borderSide, directIndicator.borderSide);
        expect(fixtureIndicator.insets, directIndicator.insets);
        expect(fixtureIndicator.borderRadius, directIndicator.borderRadius);
        expect(fixture.tabBarTheme.labelColor, direct.tabBarTheme.labelColor);
        expect(
          fixture.tabBarTheme.unselectedLabelColor,
          direct.tabBarTheme.unselectedLabelColor,
        );
        expect(fixture.extension<AppTokens>(), direct.extension<AppTokens>());
        expect(fixture.textTheme.bodyMedium?.fontFamily, kGoldenUiFont);
      });
    }

    test('light tokens use warm-neutral surfaces and a dark orange accent', () {
      const tokens = AppTokens.light;

      expect(tokens.accent, const Color(0xFFB84E17));
      expect(tokens.accent, isNot(const Color(0xFF3953C3)));
      expect(tokens.bg.r, greaterThanOrEqualTo(tokens.bg.b));
      expect(tokens.panel.r, greaterThanOrEqualTo(tokens.panel.b));
      expect(tokens.text.r, greaterThanOrEqualTo(tokens.text.b));
      expect(tokens.railBg.r, greaterThanOrEqualTo(tokens.railBg.b));
      expect(tokens.railIndicatorGradient.colors,
          [tokens.railIndicatorTop, tokens.railIndicatorBottom]);
      expect(tokens.railActiveBg, isNot(const Color(0x298BA2FF)));
    });

    test('dark tokens use warm-neutral surfaces and a warm rail accent', () {
      const tokens = AppTokens.dark;

      expect(tokens.accent, const Color(0xFFFCBF35));
      expect(tokens.accent, isNot(const Color(0xFF8BA2FF)));
      expect(tokens.bg.r, greaterThanOrEqualTo(tokens.bg.b));
      expect(tokens.panel.r, greaterThanOrEqualTo(tokens.panel.b));
      expect(tokens.railBg.r, greaterThanOrEqualTo(tokens.railBg.b));
      expect(tokens.railIndicatorGradient.colors,
          [tokens.railIndicatorTop, tokens.railIndicatorBottom]);
      expect(tokens.railActiveBg, isNot(const Color(0x298BA2FF)));
    });

    test('typography uses bundled families, CJK fallback, and tabular figures',
        () {
      final ui = Ts.style();
      final mono = Ts.style(monoFont: true, tabularNums: true);

      expect(Ts.sans.first, Ts.uiFamily);
      expect(Ts.mono.first, Ts.monoFamily);
      expect(Ts.sansFallback, contains('PingFang SC'));
      expect(Ts.sansFallback, contains('Microsoft YaHei'));
      expect(Ts.monoFallback, contains('PingFang SC'));
      expect(Ts.monoFallback, contains('Microsoft YaHei'));
      expect(ui.fontFamily, isNull);
      expect(ui.fontFamilyFallback, Ts.sansFallback);
      expect(mono.fontFamily, Ts.monoFamily);
      expect(mono.fontFamilyFallback, Ts.monoFallback);
      expect(mono.fontFeatures, Ts.tabular);
    });

    test('Material component themes follow compact Codex paint rules', () {
      for (final brightness in Brightness.values) {
        final theme = appTheme(brightness);
        final tokens = AppTokens.forBrightness(brightness);
        const idle = <WidgetState>{};
        const hovered = {WidgetState.hovered};
        const focused = {WidgetState.focused};
        const pressed = {WidgetState.pressed};
        const disabled = {WidgetState.disabled};
        const transparent = Color(0x00000000);

        final filled = theme.filledButtonTheme.style!;
        final outlined = theme.outlinedButtonTheme.style!;
        final text = theme.textButtonTheme.style!;
        for (final style in [filled, outlined, text]) {
          expect(style.minimumSize?.resolve(idle), const Size(0, Dim.ctlH));
          expect(style.overlayColor?.resolve(hovered), transparent);
          expect(style.overlayColor?.resolve(pressed), transparent);
          expect(style.elevation?.resolve(idle), 0);
          expect(style.elevation?.resolve(pressed), 0);
          expect(style.shape?.resolve(idle), isA<RoundedRectangleBorder>());
        }
        expect(filled.backgroundColor?.resolve(idle), tokens.accent);
        expect(filled.backgroundColor?.resolve(hovered), isNot(tokens.accent));
        expect(filled.backgroundColor?.resolve(disabled)?.a,
            lessThan(tokens.accent.a));
        expect(filled.foregroundColor?.resolve(idle), tokens.onAccent);
        expect(outlined.backgroundColor?.resolve(hovered), tokens.hover);
        expect(outlined.backgroundColor?.resolve(pressed), tokens.selection);
        expect(outlined.side?.resolve(idle),
            BorderSide(color: tokens.border, width: Dim.borderW));
        expect(outlined.side?.resolve(focused),
            BorderSide(color: tokens.focus, width: Dim.borderW));
        expect(text.backgroundColor?.resolve(hovered), tokens.hover);

        expect(theme.popupMenuTheme.color, tokens.panel);
        expect(theme.popupMenuTheme.surfaceTintColor, transparent);
        expect(theme.menuTheme.style?.backgroundColor?.resolve(idle),
            tokens.panel);
        expect(theme.menuTheme.style?.surfaceTintColor?.resolve(idle),
            transparent);
        expect(
            theme.dropdownMenuTheme.menuStyle?.backgroundColor?.resolve(idle),
            tokens.panel);
        expect(theme.dialogTheme.backgroundColor, tokens.panel);
        expect(theme.dialogTheme.surfaceTintColor, transparent);
        final dialogShape = theme.dialogTheme.shape! as RoundedRectangleBorder;
        expect(dialogShape.side,
            BorderSide(color: tokens.border, width: Dim.borderW));
        expect(dialogShape.borderRadius, BorderRadius.circular(Dim.radiusL));

        final inputBorder =
            theme.inputDecorationTheme.border! as OutlineInputBorder;
        expect(inputBorder.borderSide,
            BorderSide(color: tokens.border, width: Dim.borderW));
        expect(theme.inputDecorationTheme.enabledBorder, isNull);
        expect(theme.inputDecorationTheme.focusedBorder, isNull);
        expect(theme.inputDecorationTheme.errorBorder, isNull);
        expect(theme.inputDecorationTheme.focusedErrorBorder, isNull);
        expect(theme.textSelectionTheme.cursorColor, tokens.focus);
        expect(theme.textSelectionTheme.selectionColor, tokens.selection);
        expect(theme.textSelectionTheme.selectionHandleColor, tokens.accent);

        final indicator = theme.tabBarTheme.indicator! as UnderlineTabIndicator;
        expect(
            indicator.borderSide, BorderSide(color: tokens.accent, width: 2));
        expect(theme.tabBarTheme.overlayColor?.resolve(hovered), transparent);
        expect(theme.tabBarTheme.dividerColor, tokens.hairline);
        final tooltip = theme.tooltipTheme.decoration! as BoxDecoration;
        expect(tooltip.color, tokens.text);
        expect(theme.tooltipTheme.textStyle?.color, tokens.bg);
        expect(theme.scrollbarTheme.thickness?.resolve(idle), 6);
        expect(
            theme.scrollbarTheme.thickness?.resolve({WidgetState.dragged}), 8);
        expect(theme.scrollbarTheme.radius, const Radius.circular(4));
        final idleThumb = theme.scrollbarTheme.thumbColor!.resolve(idle)!;
        final hoveredThumb = theme.scrollbarTheme.thumbColor!.resolve(hovered)!;
        final draggedThumb =
            theme.scrollbarTheme.thumbColor!.resolve({WidgetState.dragged})!;
        expect(draggedThumb.a, greaterThan(hoveredThumb.a));
        expect(hoveredThumb.a, greaterThan(idleThumb.a));
        expect(theme.scrollbarTheme.trackColor?.resolve(idle), transparent);
        expect(
            theme.scrollbarTheme.trackBorderColor?.resolve(idle), transparent);
        expect(theme.scrollbarTheme.thumbVisibility?.resolve(idle), isFalse);
        expect(theme.scrollbarTheme.trackVisibility?.resolve(idle), isFalse);
        expect(theme.scrollbarTheme.interactive, isTrue);
      }
    });

    test('brand accent is distinct from every operational status role', () {
      for (final tokens in [AppTokens.light, AppTokens.dark]) {
        expect(tokens.accent, isNot(tokens.success));
        expect(tokens.accent, isNot(tokens.warning));
        expect(tokens.accent, isNot(tokens.danger));
        expect({tokens.success, tokens.warning, tokens.danger}, hasLength(3));
      }
    });

    test('both themes register complete opaque semantic color roles', () {
      for (final brightness in Brightness.values) {
        final tokens = AppTokens.forBrightness(brightness);
        final theme = appTheme(brightness);
        final roles = <String, Color>{
          'bg': tokens.bg,
          'panel': tokens.panel,
          'panel2': tokens.panel2,
          'sidebar': tokens.sidebar,
          'border': tokens.border,
          'hairline': tokens.hairline,
          'text': tokens.text,
          'text2': tokens.text2,
          'text3': tokens.text3,
          'accent': tokens.accent,
          'onAccent': tokens.onAccent,
          'hover': tokens.hover,
          'selection': tokens.selection,
          'focus': tokens.focus,
          'success': tokens.success,
          'warning': tokens.warning,
          'danger': tokens.danger,
        };

        expect(theme.extension<AppTokens>(), same(tokens));
        for (final role in roles.entries) {
          expect(
            role.value.a,
            1,
            reason:
                '${role.key} must be an opaque canonical role in $brightness',
          );
        }
      }
    });

    test('critical text, accent, focus, and status pairs meet WCAG AA', () {
      for (final brightness in Brightness.values) {
        final tokens = AppTokens.forBrightness(brightness);
        final themeName = brightness.name;

        for (final surface in <(String, Color)>[
          ('background', tokens.bg),
          ('panel', tokens.panel),
        ]) {
          _expectContrast(
            tokens.text,
            surface.$2,
            4.5,
            role: '$themeName primary text on ${surface.$1}',
          );
          _expectContrast(
            tokens.text2,
            surface.$2,
            4.5,
            role: '$themeName secondary text on ${surface.$1}',
          );
          _expectContrast(
            tokens.text3,
            surface.$2,
            4.5,
            role: '$themeName muted text on ${surface.$1}',
          );
          _expectContrast(
            tokens.focus,
            surface.$2,
            3,
            role: '$themeName focus indicator on ${surface.$1}',
          );
        }

        _expectContrast(
          tokens.onAccent,
          tokens.accent,
          4.5,
          role: '$themeName accent foreground',
        );
        for (final status in <(String, Color)>[
          ('success', tokens.success),
          ('warning', tokens.warning),
          ('danger', tokens.danger),
        ]) {
          _expectContrast(
            status.$2,
            tokens.panel,
            4.5,
            role: '$themeName ${status.$1} status on panel',
          );
        }
      }
    });

    test('geometry tokens preserve the fixed desktop shell contract', () {
      expect(Dim.railW, 64);
      expect(Dim.sidebarW, 280);
      expect(Dim.topBarH, 48);
      expect(Dim.midBarH, 44);
      expect(Dim.statusBarH, 24);
      expect(Dim.trailingSlot, 28);
      expect(Dim.wellInsetH, 3);
      expect(Dim.borderW, 1);
      expect([Dim.radiusS, Dim.radiusM, Dim.radiusL], [6, 8, 12]);
    });

    test('light and dark depth tiers differ only in paint', () {
      for (final shadows in [
        (Depth.elev1(Brightness.light), Depth.elev1(Brightness.dark)),
        (Depth.elev2(Brightness.light), Depth.elev2(Brightness.dark)),
        (Depth.elevSide(Brightness.light), Depth.elevSide(Brightness.dark)),
      ]) {
        expect(shadows.$1, hasLength(shadows.$2.length));
        for (var i = 0; i < shadows.$1.length; i++) {
          final light = shadows.$1[i];
          final dark = shadows.$2[i];
          expect(light.offset, dark.offset);
          expect(light.blurRadius, dark.blurRadius);
          expect(light.spreadRadius, dark.spreadRadius);
          expect(light.blurStyle, dark.blurStyle);
          expect(light.color, isNot(dark.color));
        }
      }

      final lightWell =
          Depth.wellTopCli(Brightness.light).gradient! as LinearGradient;
      final darkWell =
          Depth.wellTopCli(Brightness.dark).gradient! as LinearGradient;
      expect(lightWell.begin, darkWell.begin);
      expect(lightWell.end, darkWell.end);
      expect(lightWell.stops, darkWell.stops);
      expect(lightWell.colors.first, isNot(darkWell.colors.first));
      expect(lightWell.colors.last, darkWell.colors.last);
    });

    test('production and fixture files do not construct a second ThemeData',
        () {
      for (final path in ['lib/main.dart', 'test/screen_fixtures.dart']) {
        expect(
          File(path).readAsStringSync(),
          isNot(contains(RegExp(r'ThemeData\s*\('))),
          reason: '$path must delegate complete theme construction to appTheme',
        );
      }
    });
  });

  for (final brightness in Brightness.values) {
    testWidgets('initializes core Material controls in $brightness',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          darkTheme: appTheme(Brightness.dark),
          themeMode:
              brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
          home: DefaultTabController(
            length: 2,
            child: Scaffold(
              appBar: const TabBar(
                tabs: [Tab(text: 'Data'), Tab(text: 'Details')],
              ),
              body: Scrollbar(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const TextField(
                        decoration: InputDecoration(labelText: 'Key')),
                    const SizedBox(height: 8),
                    const FilledButton(onPressed: _noop, child: Text('Run')),
                    const OutlinedButton(
                        onPressed: _noop, child: Text('Cancel')),
                    const IconButton(
                      onPressed: _noop,
                      tooltip: 'Refresh',
                      icon: Icon(Icons.refresh),
                    ),
                    DropdownButton<String>(
                      value: 'db0',
                      items: const [
                        DropdownMenuItem(value: 'db0', child: Text('DB0')),
                        DropdownMenuItem(value: 'db1', child: Text('DB1')),
                      ],
                      onChanged: (_) {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(Scaffold));
      expect(Theme.of(context).brightness, brightness);
      expect(Theme.of(context).extension<AppTokens>(), isNotNull);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.byType(DropdownButton<String>), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('switching brightness preserves page state', (tester) async {
    final brightness = ValueNotifier(Brightness.light);
    addTearDown(brightness.dispose);

    await tester.pumpWidget(
      ValueListenableBuilder<Brightness>(
        valueListenable: brightness,
        builder: (context, value, child) => MaterialApp(
          theme: appTheme(Brightness.light),
          darkTheme: appTheme(Brightness.dark),
          themeMode:
              value == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
          home: child,
        ),
        child: const Scaffold(
          body: TextField(key: ValueKey('stateful-input')),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('stateful-input')),
      'unsaved configuration',
    );
    brightness.value = Brightness.dark;
    await tester.pumpAndSettle();

    expect(find.text('unsaved configuration'), findsOneWidget);
    expect(Theme.of(tester.element(find.byType(TextField))).brightness,
        Brightness.dark);
  });
}
