import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/home_chrome.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'fake_core.dart';
import 'golden_fonts.dart';
import 'viewport_assertions.dart';

final _config = RedimosConfig(
  id: 'instance-1',
  name: 'local-cache',
  port: 6379,
  endpoint: 'http://localhost:8000',
);

ChromeState _state({
  required Brightness brightness,
  ThemeMode? themeMode,
  AppLang lang = AppLang.en,
}) =>
    ChromeState(
      entityKind: EntityKind.instance,
      configs: [_config],
      endpoints: const [],
      statuses: const {},
      selectedConfigId: _config.id,
      selectedEndpointId: null,
      hoveredCardId: null,
      entityQuery: '',
      tabLabels: const ['Browse'],
      tabIndex: 0,
      stopAllSnapshot: const [],
      ddb: null,
      themeMode: themeMode ??
          (brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light),
      lang: lang,
    );

ChromeCallbacks _callbacks({
  ValueChanged<ThemeMode>? onThemeMode,
  ValueChanged<AppLang>? onLang,
}) =>
    ChromeCallbacks(
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
      onThemeMode: onThemeMode ?? (_) {},
      onLang: onLang ?? (_) {},
      onDdbMutated: () {},
    );

Future<void> _pumpChrome(
  WidgetTester tester, {
  required Brightness brightness,
  required ChromeState state,
  ChromeCallbacks? callbacks,
}) async {
  await loadGoldenFonts();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme(brightness, fontFamily: kGoldenUiFont),
      themeAnimationDuration: Duration.zero,
      home: Scaffold(
        body: HomeChrome(
          state: state,
          cb: callbacks ?? _callbacks(),
          core: FakeNativeCore(),
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );
}

BoxDecoration _rowDecoration(WidgetTester tester, String keyName) =>
    tester.widget<Container>(find.byKey(ValueKey('$keyName-row'))).decoration!
        as BoxDecoration;

Rect _rowRect(WidgetTester tester, String keyName) =>
    tester.getRect(find.byKey(ValueKey('$keyName-row')));

Finder _popupMaterialFinder(String rowKey) {
  final menuRow = find.byKey(ValueKey(rowKey));
  return find.ancestor(of: menuRow, matching: find.byType(Material)).last;
}

Material _popupMaterial(WidgetTester tester) => tester.widget<Material>(
      _popupMaterialFinder('home-theme-menu-light-row'),
    );

void _expectLabelFits(WidgetTester tester, String keyName) {
  final label = find.byKey(ValueKey('$keyName-label'));
  final row = find.byKey(ValueKey('$keyName-row'));
  final paragraph = tester.renderObject<RenderParagraph>(label);
  expect(paragraph.didExceedMaxLines, isFalse);
  expect(tester.getRect(row).contains(tester.getRect(label).center), isTrue);
}

void main() {
  setUp(() {
    appLang.value = AppLang.en;
  });

  tearDown(() {
    appLang.value = AppLang.en;
  });

  testWidgets('theme popup uses compact semantic shell and stable rows',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    for (final brightness in Brightness.values) {
      final tokens = AppTokens.forBrightness(brightness);
      await _pumpChrome(
        tester,
        brightness: brightness,
        state: _state(brightness: brightness),
      );

      final slot = find.byKey(const ValueKey('home-topbar-theme-slot'));
      expect(tester.getSize(slot), const Size.square(Dim.ctlH));
      final slotBefore = tester.getRect(slot);

      await tester.tap(find.byKey(const ValueKey('home-theme-menu')));
      await tester.pumpAndSettle();

      final menuMaterial = _popupMaterial(tester);
      expectInsideTestViewport(
        tester,
        _popupMaterialFinder('home-theme-menu-light-row'),
      );
      expectHitTestable(
        tester,
        find.byKey(const ValueKey('home-theme-menu-system-action')),
      );
      final shape = menuMaterial.shape! as RoundedRectangleBorder;
      expect(menuMaterial.color, tokens.panel);
      expect(menuMaterial.surfaceTintColor, Colors.transparent);
      expect(menuMaterial.shadowColor, Colors.black.withValues(alpha: 0.28));
      expect(menuMaterial.elevation, 8);
      expect(shape.side.color, tokens.border);
      expect(shape.side.width, Dim.borderW);

      final scrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView).last,
      );
      expect(scrollView.padding, const EdgeInsets.symmetric(vertical: 4));

      const rows = [
        'home-theme-menu-light',
        'home-theme-menu-dark',
        'home-theme-menu-system',
      ];
      final geometry = rows.map((key) => _rowRect(tester, key)).toList();
      expect(geometry.map((rect) => rect.height), everyElement(Dim.rowH));
      expect(geometry[1].top, geometry[0].bottom);
      expect(geometry[2].top, geometry[1].bottom);

      final selected = brightness == Brightness.dark ? rows[1] : rows[0];
      expect(_rowDecoration(tester, selected).color, tokens.selection);
      expect(
        tester
            .widget<Text>(
              find.byKey(ValueKey('$selected-label')),
            )
            .style!
            .color,
        tokens.accent,
      );
      expect(find.byKey(ValueKey('$selected-check')), findsOneWidget);

      for (final row in rows) {
        _expectLabelFits(tester, row);
      }
      expect(tester.getRect(slot), slotBefore);
      expect(tester.takeException(), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-theme-menu-light-row')),
          findsNothing);
      expect(tester.getRect(slot), slotBefore);
    }
  });

  testWidgets('theme rows keep geometry across hover and keyboard focus',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    const tokens = AppTokens.dark;
    await _pumpChrome(
      tester,
      brightness: Brightness.dark,
      state: _state(brightness: Brightness.dark),
    );
    await tester.tap(find.byKey(const ValueKey('home-theme-menu')));
    await tester.pumpAndSettle();

    const rows = [
      'home-theme-menu-light',
      'home-theme-menu-dark',
      'home-theme-menu-system',
    ];
    final before = rows.map((key) => _rowRect(tester, key)).toList();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(
      tester.getCenter(
        find.byKey(const ValueKey('home-theme-menu-system-action')),
      ),
    );
    await tester.pump();
    expect(rows.map((key) => _rowRect(tester, key)).toList(), before);
    expect(
      _rowDecoration(tester, rows[2]).color,
      Color.alphaBlend(tokens.hover, Colors.transparent),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(rows.map((key) => _rowRect(tester, key)).toList(), before);
    final focused = rows.where(
      (key) => _rowDecoration(tester, key).border!.top.color == tokens.focus,
    );
    expect(focused, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('theme menu keyboard selection preserves callback value',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final selected = <ThemeMode>[];
    await _pumpChrome(
      tester,
      brightness: Brightness.dark,
      state: _state(
        brightness: Brightness.dark,
        themeMode: ThemeMode.system,
      ),
      callbacks: _callbacks(onThemeMode: selected.add),
    );

    await tester.tap(find.byKey(const ValueKey('home-theme-menu')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(selected, hasLength(1));
    expect(ThemeMode.values, contains(selected.single));
    expect(
        find.byKey(const ValueKey('home-theme-menu-light-row')), findsNothing);
  });

  testWidgets('language popup keeps labels visible and callbacks exact',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final selected = <AppLang>[];
    for (final brightness in Brightness.values) {
      final tokens = AppTokens.forBrightness(brightness);
      await _pumpChrome(
        tester,
        brightness: brightness,
        state: _state(
          brightness: brightness,
          lang: AppLang.en,
        ),
        callbacks: _callbacks(onLang: selected.add),
      );

      final slot = find.byKey(const ValueKey('home-topbar-lang-slot'));
      final slotBefore = tester.getRect(slot);
      expect(slotBefore.size, const Size.square(Dim.ctlH));

      await tester.tap(find.byKey(const ValueKey('home-language-menu')));
      await tester.pumpAndSettle();

      const zh = 'home-language-menu-zh';
      const en = 'home-language-menu-en';
      expectInsideTestViewport(
        tester,
        _popupMaterialFinder('$zh-row'),
      );
      expectHitTestable(
        tester,
        find.byKey(const ValueKey('$zh-action')),
      );
      expect(_rowRect(tester, zh).height, Dim.rowH);
      expect(_rowRect(tester, en).height, Dim.rowH);
      expect(_rowDecoration(tester, en).color, tokens.selection);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('$en-label')))
            .style!
            .color,
        tokens.accent,
      );
      expect(find.byKey(const ValueKey('$en-check')), findsOneWidget);
      expect(find.byKey(const ValueKey('$zh-check')), findsNothing);
      _expectLabelFits(tester, zh);
      _expectLabelFits(tester, en);

      await tester.tap(find.byKey(const ValueKey('$zh-action')));
      await tester.pumpAndSettle();
      expect(selected.last, AppLang.zh);
      expect(tester.getRect(slot), slotBefore);
      expect(tester.takeException(), isNull);
    }
    expect(selected, [AppLang.zh, AppLang.zh]);
  });
}
