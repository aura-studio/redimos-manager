import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/home_chrome.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'golden_fonts.dart';

final _config = RedimosConfig(
  id: 'instance-1',
  name: 'local-cache',
  port: 6379,
  endpoint: 'http://localhost:8000',
);

const _endpoint = DdbEndpoint(
  id: 'endpoint-1',
  name: 'Local DynamoDB',
  kind: 'local',
  endpoint: 'http://localhost:8000',
);

const _fourTabs = ['Overview', 'Browser', 'PartiQL', 'Playground'];
const _sixTabs = [
  'Overview',
  'Browser',
  'PartiQL',
  'Playground',
  'Monitor',
  'Logs',
];

ChromeState _state({
  required Brightness brightness,
  required List<String> tabLabels,
  int tabIndex = 0,
  EntityKind kind = EntityKind.endpoint,
}) =>
    ChromeState(
      entityKind: kind,
      configs: [_config],
      endpoints: const [_endpoint],
      statuses: const {},
      selectedConfigId: kind == EntityKind.instance ? _config.id : null,
      selectedEndpointId: kind == EntityKind.endpoint ? _endpoint.id : null,
      hoveredCardId: null,
      entityQuery: '',
      tabLabels: tabLabels,
      tabIndex: tabIndex,
      stopAllSnapshot: const [],
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      lang: AppLang.en,
    );

ChromeCallbacks _callbacks({ValueChanged<int>? onMidTab}) => ChromeCallbacks(
      onEntityKind: (_) {},
      onSelectConfig: (_) {},
      onSelectEndpoint: (_) {},
      onHoverCard: (_) {},
      onQueryChanged: (_) {},
      onNewConfig: () {},
      onMidTab: onMidTab ?? (_) {},
      onStartStop: (_) {},
      onStopAll: () {},
      onRestoreAll: () {},
      onThemeMode: (_) {},
      onLang: (_) {},
    );

Future<void> _pumpMidbar(
  WidgetTester tester, {
  required Brightness brightness,
  required ChromeState state,
  ChromeCallbacks? callbacks,
  Widget? midBarCta,
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
          midBarCta: midBarCta,
          child: const SizedBox.expand(
            key: ValueKey('midbar-detail-pane'),
          ),
        ),
      ),
    ),
  );
}

List<Rect> _tabGeometry(WidgetTester tester, int count) => [
      for (var i = 0; i < count; i++)
        tester.getRect(find.byKey(ValueKey('home-midbar-tab-$i'))),
    ];

void main() {
  setUp(() {
    appLang.value = AppLang.en;
  });

  tearDown(() {
    appLang.value = AppLang.en;
  });

  testWidgets('four and six endpoint tabs keep shell and content origin fixed',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    Rect? expectedMidbar;
    Rect? expectedDetail;
    Rect? expectedCta;
    for (final brightness in Brightness.values) {
      for (final labels in [_fourTabs, _sixTabs]) {
        await _pumpMidbar(
          tester,
          brightness: brightness,
          state: _state(brightness: brightness, tabLabels: labels),
          midBarCta: const SizedBox(
            key: ValueKey('midbar-test-cta'),
            width: 72,
            height: Dim.ctlH,
          ),
        );

        final midbar = tester.getRect(
          find.byKey(const ValueKey('home-midbar')),
        );
        final detail = tester.getRect(
          find.byKey(const ValueKey('midbar-detail-pane')),
        );
        final tabRow = tester.getRect(
          find.byKey(const ValueKey('home-midbar-tab-row')),
        );
        final cta = tester.getRect(
          find.byKey(const ValueKey('midbar-test-cta')),
        );

        expectedMidbar ??= midbar;
        expectedDetail ??= detail;
        expectedCta ??= cta;
        expect(midbar, expectedMidbar);
        expect(detail, expectedDetail);
        expect(cta, expectedCta);
        expect(midbar, const Rect.fromLTWH(344, 48, 936, Dim.midBarH));
        expect(detail.topLeft, const Offset(344, 92));
        expect(tabRow.center.dx, closeTo(midbar.center.dx, 0.01));
        expect(cta.right, midbar.right - 16);
        expect(cta.center.dy, midbar.top + (Dim.midBarH - Dim.borderW) / 2);
        expect(
          find.byKey(ValueKey('home-midbar-tab-${labels.length - 1}')),
          findsOneWidget,
        );
        expect(
          find.byKey(ValueKey('home-midbar-tab-${labels.length}')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('active tab changes semantic paint without changing geometry',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    for (final brightness in Brightness.values) {
      await _pumpMidbar(
        tester,
        brightness: brightness,
        state: _state(
          brightness: brightness,
          tabLabels: _sixTabs,
          tabIndex: 0,
        ),
      );
      final before = _tabGeometry(tester, _sixTabs.length);
      final tokens = AppTokens.forBrightness(brightness);
      final shell = tester.widget<Container>(
        find.byKey(const ValueKey('home-midbar')),
      );
      final shellDecoration = shell.decoration! as BoxDecoration;
      final active = tester.widget<Container>(
        find.byKey(const ValueKey('home-midbar-tab-0')),
      );
      final inactive = tester.widget<Container>(
        find.byKey(const ValueKey('home-midbar-tab-1')),
      );
      final activeDecoration = active.decoration! as BoxDecoration;
      final inactiveDecoration = inactive.decoration! as BoxDecoration;
      final activeText = tester.widget<Text>(
        find.byKey(const ValueKey('home-midbar-tab-0-label')),
      );
      final inactiveText = tester.widget<Text>(
        find.byKey(const ValueKey('home-midbar-tab-1-label')),
      );

      expect(shellDecoration.color, tokens.panel);
      expect(shellDecoration.border!.bottom.color, tokens.border);
      expect(shellDecoration.boxShadow, hasLength(1));
      expect(activeDecoration.border!.bottom.color, tokens.accent);
      expect(activeDecoration.border!.bottom.width, 2);
      expect(inactiveDecoration.border!.bottom.color, Colors.transparent);
      expect(inactiveDecoration.border!.bottom.width, 2);
      expect(activeText.style!.color, tokens.text);
      expect(activeText.style!.fontWeight, FontWeight.w600);
      expect(activeText.style!.fontSize, Ts.sm);
      expect(inactiveText.style!.color, tokens.text3);
      expect(inactiveText.style!.fontWeight, FontWeight.w600);

      await _pumpMidbar(
        tester,
        brightness: brightness,
        state: _state(
          brightness: brightness,
          tabLabels: _sixTabs,
          tabIndex: 4,
        ),
      );
      expect(_tabGeometry(tester, _sixTabs.length), before);
      final newActive = tester.widget<Container>(
        find.byKey(const ValueKey('home-midbar-tab-4')),
      );
      final oldActive = tester.widget<Container>(
        find.byKey(const ValueKey('home-midbar-tab-0')),
      );
      expect(
        (newActive.decoration! as BoxDecoration).border!.bottom.color,
        tokens.accent,
      );
      expect(
        (oldActive.decoration! as BoxDecoration).border!.bottom.color,
        Colors.transparent,
      );
    }
  });

  testWidgets('tab actions suppress ripple and preserve callback index',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final selected = <int>[];
    await _pumpMidbar(
      tester,
      brightness: Brightness.dark,
      state: _state(
        brightness: Brightness.dark,
        tabLabels: _sixTabs,
      ),
      callbacks: _callbacks(onMidTab: selected.add),
    );

    const tokens = AppTokens.dark;
    final action = tester.widget<InkWell>(
      find.byKey(const ValueKey('home-midbar-tab-4-action')),
    );
    expect(action.splashFactory, NoSplash.splashFactory);
    expect(action.splashColor, Colors.transparent);
    expect(action.highlightColor, Colors.transparent);
    expect(action.hoverColor, tokens.hover);
    expect(action.focusColor, tokens.focus.withValues(alpha: 0.12));

    await tester.tap(
      find.byKey(const ValueKey('home-midbar-tab-4-action')),
    );
    await tester.pump();
    expect(selected, [4]);
    expect(find.byType(InkRipple), findsNothing);
  });
}
