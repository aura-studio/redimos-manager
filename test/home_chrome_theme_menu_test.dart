import 'dart:io';

import 'package:flutter/material.dart';
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

  testWidgets('topbar shows the style menu with the current style label',
      (tester) async {
    await _pumpChrome(tester);
    expect(find.byKey(const ValueKey('home-topbar-style-slot')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('home-style-menu')), findsOneWidget);
    expect(find.text('Parchment'), findsOneWidget);
    // It sits between stop-all and the language menu.
    final actions =
        tester.getRect(find.byKey(const ValueKey('home-topbar-actions')));
    final stop = tester.getRect(find.byKey(const ValueKey(
        'home-topbar-stop-slot')));
    final style =
        tester.getRect(find.byKey(const ValueKey('home-topbar-style-slot')));
    final lang = tester.getRect(find.byKey(const ValueKey(
        'home-topbar-lang-slot')));
    expect(style.left, greaterThan(stop.left));
    expect(lang.left, greaterThan(style.left));
    expect(actions.contains(style.center), isTrue);
  });

  testWidgets('opening the menu lists exactly seventeen styles with a selection',
      (tester) async {
    await _pumpChrome(tester);
    await tester.tap(find.byKey(const ValueKey('home-style-menu')));
    await tester.pumpAndSettle();
    for (final s in AppStyle.values) {
      expect(find.byKey(ValueKey('home-style-menu-${s.id}-item')),
          findsOneWidget);
      expect(find.text(s.label), findsWidgets);
    }
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

  testWidgets('smoke: HomeChrome builds under all seventeen palettes',
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
      expect(find.text(s.label), findsOneWidget, reason: s.id);
    }
  });
}
