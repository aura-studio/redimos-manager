import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/home_chrome.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/theme_prefs.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'golden_fonts.dart';

final _config = RedimosConfig(
  id: 'instance-1',
  name: 'local-cache',
  port: 6379,
  endpoint: 'http://localhost:8000',
);

ChromeState _state() => ChromeState(
      entityKind: EntityKind.instance,
      configs: [_config],
      endpoints: const [],
      statuses: const {},
      selectedConfigId: _config.id,
      selectedEndpointId: null,
      services: const [],
      selectedServiceId: null,
      hoveredCardId: null,
      entityQuery: '',
      tabLabels: const ['Browse'],
      tabIndex: 0,
      stopAllSnapshot: const [],
      lang: AppLang.en,
    );

ChromeCallbacks _callbacks() => ChromeCallbacks(
      onEntityKind: (_) {},
      onSelectConfig: (_) {},
      onSelectEndpoint: (_) {},
      onHoverCard: (_) {},
      onQueryChanged: (_) {},
      onNewConfig: () {},
      onMidTab: (_) {},
      onStartStop: (_) {},
      onStopAll: () {},
      onRestoreAll: () {},
      onLang: (_) {},
    );

Future<void> _pumpChrome(
  WidgetTester tester, {
  AppStyle style = AppStyle.parchment,
}) async {
  await loadGoldenFonts();
  // Desktop-sized surface: the 800x600 test default overflows the topbar once
  // the text-width style button joins the action row.
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appThemeForStyle(style, fontFamily: kGoldenUiFont),
      themeAnimationDuration: Duration.zero,
      home: Scaffold(
        body: HomeChrome(
          state: _state(),
          cb: _callbacks(),
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('style-menu-test');
    debugPrefsDir = tmp;
    appStyle.value = AppStyle.parchment;
  });

  tearDown(() {
    appStyle.value = AppStyle.parchment;
    debugPrefsDir = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('the rail R logo doubles as the style menu button',
      (tester) async {
    await _pumpChrome(tester);
    expect(find.byKey(const ValueKey('main-rail-logo')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-style-menu')), findsOneWidget);
    // The menu button is the logo: the logo lives inside it, inside the rail.
    final menu = find.byKey(const ValueKey('home-style-menu'));
    expect(
        find.descendant(of: menu, matching: find.byKey(
            const ValueKey('main-rail-logo'))),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('main-rail')), matching: menu),
        findsOneWidget);
  });

  testWidgets('the topbar carries a matching square style button',
      (tester) async {
    await _pumpChrome(tester);
    final slot = find.byKey(const ValueKey('home-topbar-style-slot'));
    expect(slot, findsOneWidget);
    final button = find.byKey(const ValueKey('home-style-button'));
    expect(find.descendant(of: slot, matching: button), findsOneWidget);
    expect(find.byKey(const ValueKey('home-style-button-palette')),
        findsOneWidget);
    // Same chrome row: stop slot, style slot, lang slot side by side.
    expect(find.byKey(const ValueKey('home-topbar-stop-slot')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-topbar-lang-slot')), findsOneWidget);
  });

  testWidgets('the topbar style button opens the same twelve-style menu',
      (tester) async {
    await _pumpChrome(tester);
    await tester.tap(find.byKey(const ValueKey('home-style-button')));
    await tester.pumpAndSettle();
    for (final s in AppStyle.values) {
      expect(find.byKey(ValueKey('home-style-menu-${s.id}-item')),
          findsOneWidget);
    }
    // Keyboard preview works from this entry too: arrow down re-themes in
    // memory without writing, Esc reverts to the persisted style.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(appStyle.value, AppStyle.midnight);
    expect(File('${tmp.path}/theme.json').existsSync(), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(appStyle.value, AppStyle.parchment);
  });

  testWidgets('opening the menu lists exactly twelve styles with a selection',
      (tester) async {
    await _pumpChrome(tester);
    await tester.tap(find.byKey(const ValueKey('home-style-menu')));
    await tester.pumpAndSettle();
    for (final s in AppStyle.values) {
      expect(find.byKey(ValueKey('home-style-menu-${s.id}-item')),
          findsOneWidget);
      expect(find.text(s.label), findsWidgets);
    }
    // The selection pill stays inset from the popup's rounded corners — a
    // flush row reads as overflowing the dropdown (user-reported glitch).
    final row = tester.widget<Container>(
        find.byKey(const ValueKey('home-style-menu-parchment-row')));
    expect(row.margin, const EdgeInsets.symmetric(horizontal: 6));
  });

  testWidgets('selecting Mono switches appStyle and persists theme.json',
      (tester) async {
    await _pumpChrome(tester);
    await tester.tap(find.byKey(const ValueKey('home-style-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-style-menu-mono-item')));
    await tester.pumpAndSettle();
    expect(appStyle.value, AppStyle.mono);
    final f = File('${tmp.path}/theme.json');
    expect(f.existsSync(), isTrue);
    expect(f.readAsStringSync(), '{"style":"mono"}');
  });

  testWidgets('re-selecting the current style writes nothing', (tester) async {
    await _pumpChrome(tester);
    await tester.tap(find.byKey(const ValueKey('home-style-menu')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('home-style-menu-parchment-item')));
    await tester.pumpAndSettle();
    expect(appStyle.value, AppStyle.parchment);
    expect(File('${tmp.path}/theme.json').existsSync(), isFalse);
  });

  testWidgets('smoke: HomeChrome builds under all twelve palettes',
      (tester) async {
    for (final s in AppStyle.values) {
      appStyle.value = s;
      await _pumpChrome(tester, style: s);
      final context = tester.element(find.byType(HomeChrome));
      expect(
          identical(
              Theme.of(context).extension<AppTokens>(), s.tokens),
          isTrue,
          reason: s.id);
      expect(find.byKey(const ValueKey('home-style-menu')), findsOneWidget,
          reason: s.id);
    }
  });

  testWidgets('arrow keys live-preview the focused style without saving',
      (tester) async {
    await _pumpChrome(tester);
    await tester.tap(find.byKey(const ValueKey('home-style-menu')));
    await tester.pumpAndSettle();
    expect(appStyle.value, AppStyle.parchment);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(appStyle.value, AppStyle.midnight); // preview applied in memory
    expect(File('${tmp.path}/theme.json').existsSync(), isFalse); // unsaved
  });

  testWidgets('Enter after arrow-key preview commits and persists',
      (tester) async {
    await _pumpChrome(tester);
    await tester.tap(find.byKey(const ValueKey('home-style-menu')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(appStyle.value, AppStyle.midnight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(appStyle.value, AppStyle.midnight);
    expect(File('${tmp.path}/theme.json').readAsStringSync(),
        '{"style":"midnight"}');
  });

  testWidgets('Esc after arrow-key preview reverts to the persisted style',
      (tester) async {
    // Persist lagoon first, then start the session on parchment.
    appStyle.value = AppStyle.lagoon;
    saveAppStyle();
    appStyle.value = AppStyle.parchment;
    await _pumpChrome(tester);
    await tester.tap(find.byKey(const ValueKey('home-style-menu')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(appStyle.value, AppStyle.midnight); // previewing
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(appStyle.value, AppStyle.lagoon); // reverted to disk value
  });
}
