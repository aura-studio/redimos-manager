import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/home_chrome.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

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
      lang: lang,
    );

ChromeCallbacks _callbacks({
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
      onLang: onLang ?? (_) {},
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
