import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

const _localEndpoint = DdbEndpoint(
  id: 'endpoint-local',
  name: 'Local DynamoDB',
  kind: 'local',
  endpoint: 'http://localhost:8000',
);

const _awsEndpoint = DdbEndpoint(
  id: 'endpoint-aws',
  name: 'Production DynamoDB',
  kind: 'aws',
  region: 'us-east-1',
);

const _instanceTabs = [
  'Browser',
  'Console',
  'Playground',
  'Monitor',
  'Logs',
  'Configure',
];

const _localEndpointTabs = ['Overview', 'Browser', 'PartiQL', 'Playground'];

const _awsEndpointTabs = [
  'Overview',
  'Browser',
  'PartiQL',
  'Playground',
  'Monitor',
  'Logs',
];

class _InteractionHarness extends StatefulWidget {
  const _InteractionHarness({super.key});

  @override
  State<_InteractionHarness> createState() => _InteractionHarnessState();
}

class _InteractionHarnessState extends State<_InteractionHarness> {
  EntityKind entityKind = EntityKind.instance;
  String? selectedConfigId = _config.id;
  String? selectedEndpointId;
  String? hoveredCardId;
  List<String> tabLabels = _instanceTabs;
  int tabIndex = 0;
  ThemeMode themeMode = ThemeMode.dark;
  AppLang lang = AppLang.en;

  final entityKindSelections = <EntityKind>[];
  final endpointSelections = <String>[];
  final tabSelections = <int>[];
  final themeSelections = <ThemeMode>[];
  final languageSelections = <AppLang>[];

  List<String> _tabsForEndpoint(String id) =>
      id == _localEndpoint.id ? _localEndpointTabs : _awsEndpointTabs;

  void _selectEntityKind(EntityKind value) {
    entityKindSelections.add(value);
    setState(() {
      entityKind = value;
      hoveredCardId = null;
      tabIndex = 0;
      if (value == EntityKind.instance) {
        selectedConfigId = _config.id;
        selectedEndpointId = null;
        tabLabels = _instanceTabs;
      } else {
        selectedConfigId = null;
        selectedEndpointId = _localEndpoint.id;
        tabLabels = _localEndpointTabs;
      }
    });
  }

  void _selectConfig(RedimosConfig config) {
    setState(() {
      entityKind = EntityKind.instance;
      selectedConfigId = config.id;
      selectedEndpointId = null;
      tabLabels = _instanceTabs;
      tabIndex = 0;
    });
  }

  void _selectEndpoint(String id) {
    endpointSelections.add(id);
    setState(() {
      entityKind = EntityKind.endpoint;
      selectedConfigId = null;
      selectedEndpointId = id;
      tabLabels = _tabsForEndpoint(id);
      tabIndex = 0;
    });
  }

  void _selectTab(int value) {
    tabSelections.add(value);
    setState(() => tabIndex = value);
  }

  void _selectTheme(ThemeMode value) {
    themeSelections.add(value);
    setState(() => themeMode = value);
  }

  void _selectLanguage(AppLang value) {
    languageSelections.add(value);
    setState(() {
      lang = value;
      appLang.value = value;
    });
  }

  ChromeState get chromeState => ChromeState(
        entityKind: entityKind,
        configs: [_config],
        endpoints: const [_localEndpoint, _awsEndpoint],
        statuses: const {},
        selectedConfigId: selectedConfigId,
        selectedEndpointId: selectedEndpointId,
        hoveredCardId: hoveredCardId,
        entityQuery: '',
        tabLabels: tabLabels,
        tabIndex: tabIndex,
        stopAllSnapshot: const [],
        themeMode: themeMode,
        lang: lang,
      );

  ChromeCallbacks get callbacks => ChromeCallbacks(
        onEntityKind: _selectEntityKind,
        onSelectConfig: _selectConfig,
        onSelectEndpoint: _selectEndpoint,
        onHoverCard: (value) => setState(() => hoveredCardId = value),
        onQueryChanged: (_) {},
        onNewConfig: () {},
        onMidTab: _selectTab,
        onStartStop: (_) {},
        onStopAll: () {},
        onRestoreAll: () {},
        onThemeMode: _selectTheme,
        onLang: _selectLanguage,
      );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light, fontFamily: kGoldenUiFont),
      darkTheme: appTheme(Brightness.dark, fontFamily: kGoldenUiFont),
      themeMode: themeMode,
      themeAnimationDuration: Duration.zero,
      home: Scaffold(
        body: HomeChrome(
          state: chromeState,
          cb: callbacks,
          child: const SizedBox.expand(
            key: ValueKey('interaction-detail-pane'),
          ),
        ),
      ),
    );
  }
}

Future<GlobalKey<_InteractionHarnessState>> _pumpHarness(
  WidgetTester tester,
) async {
  await loadGoldenFonts();
  final key = GlobalKey<_InteractionHarnessState>();
  await tester.pumpWidget(_InteractionHarness(key: key));
  return key;
}

List<Rect> _shellGeometry(WidgetTester tester) => [
      tester.getRect(find.byKey(const ValueKey('main-rail'))),
      tester.getRect(find.byKey(const ValueKey('entity-sidebar'))),
      tester.getRect(find.byKey(const ValueKey('home-topbar'))),
      tester.getRect(find.byKey(const ValueKey('home-midbar'))),
      tester.getRect(find.byKey(const ValueKey('interaction-detail-pane'))),
      tester.getRect(find.byKey(const ValueKey('home-statusbar'))),
    ];

List<Offset> _topbarAnchors(WidgetTester tester) => [
      tester.getRect(find.byKey(const ValueKey('home-topbar-crumb'))).topLeft,
      tester.getRect(find.byKey(const ValueKey('home-topbar-entity'))).topLeft,
      tester
          .getRect(find.byKey(const ValueKey('home-topbar-sub-entity')))
          .topLeft,
      tester
          .getRect(find.byKey(const ValueKey('home-topbar-screen-name')))
          .topLeft,
      tester.getRect(find.byKey(const ValueKey('home-topbar-actions'))).topLeft,
    ];

List<Rect> _cardGeometry(WidgetTester tester, String id) => [
      tester.getRect(find.byKey(ValueKey('entity-card-$id-name'))),
      tester.getRect(find.byKey(ValueKey('entity-card-$id-badge'))),
      tester.getRect(find.byKey(ValueKey('entity-card-$id-trailing-slot'))),
    ];

void _expectOffsetsStable(
  Iterable<Offset> actual,
  Iterable<Offset> expected,
) {
  final actualList = actual.toList();
  final expectedList = expected.toList();
  expect(actualList, hasLength(expectedList.length));
  for (var i = 0; i < actualList.length; i++) {
    expect(actualList[i].dx, closeTo(expectedList[i].dx, 1));
    expect(actualList[i].dy, closeTo(expectedList[i].dy, 1));
  }
}

void _expectRectsStable(
  Iterable<Rect> actual,
  Iterable<Rect> expected,
) {
  final actualList = actual.toList();
  final expectedList = expected.toList();
  expect(actualList, hasLength(expectedList.length));
  for (var i = 0; i < actualList.length; i++) {
    expect(actualList[i].left, closeTo(expectedList[i].left, 1));
    expect(actualList[i].top, closeTo(expectedList[i].top, 1));
    expect(actualList[i].right, closeTo(expectedList[i].right, 1));
    expect(actualList[i].bottom, closeTo(expectedList[i].bottom, 1));
  }
}

void main() {
  setUp(() {
    appLang.value = AppLang.en;
  });

  tearDown(() {
    appLang.value = AppLang.en;
  });

  testWidgets(
      'entity and four/six tab interactions preserve shell and topbar anchors',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final harnessKey = await _pumpHarness(tester);
    final shell = _shellGeometry(tester);

    Focus.of(
      find
          .byKey(const ValueKey('main-rail-endpoint-focus-target'))
          .evaluate()
          .single,
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    final state = harnessKey.currentState!;
    expect(state.entityKindSelections, [EntityKind.endpoint]);
    expect(state.entityKind, EntityKind.endpoint);
    expect(state.selectedEndpointId, _localEndpoint.id);
    expect(state.tabLabels, _localEndpointTabs);
    expect(_shellGeometry(tester), shell);
    expect(find.byKey(const ValueKey('home-midbar-tab-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-midbar-tab-4')), findsNothing);
    expect(
      tester
          .getRect(find.byKey(const ValueKey('interaction-detail-pane')))
          .topLeft,
      const Offset(344, 92),
    );

    await tester.tap(
      find.byKey(
        const ValueKey('entity-card-endpoint-aws-action'),
      ),
    );
    await tester.pump();

    expect(state.endpointSelections, [_awsEndpoint.id]);
    expect(state.selectedEndpointId, _awsEndpoint.id);
    expect(state.tabLabels, _awsEndpointTabs);
    expect(state.tabIndex, 0);
    expect(_shellGeometry(tester), shell);
    expect(find.byKey(const ValueKey('home-midbar-tab-5')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-midbar-tab-6')), findsNothing);

    final topbarBeforeTab = _topbarAnchors(tester);
    final trailingSlotBeforeTab = tester.getRect(
      find.byKey(const ValueKey('entity-card-endpoint-aws-trailing-slot')),
    );
    await tester.tap(
      find.byKey(const ValueKey('home-midbar-tab-5-action')),
    );
    await tester.pump();

    expect(state.tabSelections, [5]);
    expect(state.tabIndex, 5);
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('home-topbar-screen-name')),
          )
          .data,
      'Logs',
    );
    _expectOffsetsStable(_topbarAnchors(tester), topbarBeforeTab);
    expect(
      tester.getRect(
        find.byKey(const ValueKey('entity-card-endpoint-aws-trailing-slot')),
      ),
      trailingSlotBeforeTab,
    );
    expect(_shellGeometry(tester), shell);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'hover and keyboard menus update state without moving fixed bounds',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final harnessKey = await _pumpHarness(tester);
    final state = harnessKey.currentState!;
    final shell = _shellGeometry(tester);
    final cardBefore = _cardGeometry(tester, _config.id);
    final topbarBefore = _topbarAnchors(tester);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(
      tester.getCenter(
        find.byKey(ValueKey('entity-card-${_config.id}-action')),
      ),
    );
    await tester.pump();

    expect(state.hoveredCardId, _config.id);
    _expectRectsStable(_cardGeometry(tester, _config.id), cardBefore);
    _expectOffsetsStable(_topbarAnchors(tester), topbarBefore);
    final trailingSlot = tester.getRect(
      find.byKey(ValueKey('entity-card-${_config.id}-trailing-slot')),
    );
    expect(trailingSlot.size, const Size.square(Dim.trailingSlot));
    expect(
      tester.getRect(
        find.byKey(ValueKey('entity-card-${_config.id}-start-stop')),
      ),
      trailingSlot,
    );

    await tester.tap(find.byKey(const ValueKey('home-theme-menu')));
    await tester.pumpAndSettle();
    final themeSlotBefore = tester.getRect(
      find.byKey(const ValueKey('home-topbar-theme-slot')),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(state.themeSelections, hasLength(1));
    expect(state.themeMode, state.themeSelections.single);
    expect(ThemeMode.values, contains(state.themeMode));
    expect(
      find.byKey(const ValueKey('home-theme-menu-light-row')),
      findsNothing,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('home-topbar-theme-slot'))),
      themeSlotBefore,
    );
    expect(_shellGeometry(tester), shell);
    _expectOffsetsStable(_topbarAnchors(tester), topbarBefore);

    await tester.tap(find.byKey(const ValueKey('home-language-menu')));
    await tester.pumpAndSettle();
    final langSlotBefore = tester.getRect(
      find.byKey(const ValueKey('home-topbar-lang-slot')),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(state.languageSelections, hasLength(1));
    expect(state.lang, state.languageSelections.single);
    expect(AppLang.values, contains(state.lang));
    expect(appLang.value, state.lang);
    expect(
      find.byKey(const ValueKey('home-language-menu-en-row')),
      findsNothing,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('home-topbar-lang-slot'))),
      langSlotBefore,
    );
    expect(_shellGeometry(tester), shell);
    _expectRectsStable(_cardGeometry(tester, _config.id), cardBefore);
    _expectOffsetsStable(_topbarAnchors(tester), topbarBefore);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'complete chrome smoke is stable across light and dark interactions',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final harnessKey = await _pumpHarness(tester);
    final state = harnessKey.currentState!;
    final shell = _shellGeometry(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      await tester.tap(find.byKey(const ValueKey('home-theme-menu')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('home-theme-menu-${mode.name}-row')),
      );
      await tester.pumpAndSettle();

      expect(state.themeMode, mode);
      expect(_shellGeometry(tester), shell);
      final theme = Theme.of(
        tester.element(
          find.byKey(const ValueKey('interaction-detail-pane')),
        ),
      );
      final tokens = AppTokens.forBrightness(theme.brightness);
      expect(theme.colorScheme.primary, tokens.accent);
      expect(theme.colorScheme.primary, isNot(Colors.blue));
      expect(theme.colorScheme.secondary, isNot(Colors.blue));

      await tester.tap(
        find.byKey(const ValueKey('main-rail-instance-action')),
      );
      await tester.pump();
      expect(state.entityKind, EntityKind.instance);
      expect(state.selectedConfigId, _config.id);
      final cardBefore = _cardGeometry(tester, _config.id);
      await mouse.moveTo(
        tester.getCenter(
          find.byKey(ValueKey('entity-card-${_config.id}-action')),
        ),
      );
      await tester.pump();
      expect(state.hoveredCardId, _config.id);
      _expectRectsStable(_cardGeometry(tester, _config.id), cardBefore);
      expect(_shellGeometry(tester), shell);

      await tester.tap(
        find.byKey(const ValueKey('main-rail-endpoint-action')),
      );
      await tester.pump();
      expect(state.selectedEndpointId, _localEndpoint.id);
      expect(state.tabLabels, _localEndpointTabs);
      expect(find.byKey(const ValueKey('home-midbar-tab-4')), findsNothing);
      expect(_shellGeometry(tester), shell);

      await tester.tap(
        find.byKey(const ValueKey('entity-card-endpoint-aws-action')),
      );
      await tester.pump();
      expect(state.selectedEndpointId, _awsEndpoint.id);
      expect(state.tabLabels, _awsEndpointTabs);
      expect(find.byKey(const ValueKey('home-midbar-tab-5')), findsOneWidget);

      final topbarBeforeTab = _topbarAnchors(tester);
      await tester.tap(
        find.byKey(const ValueKey('home-midbar-tab-5-action')),
      );
      await tester.pump();
      expect(state.tabIndex, 5);
      _expectOffsetsStable(_topbarAnchors(tester), topbarBeforeTab);
      expect(_shellGeometry(tester), shell);

      await tester.tap(find.byKey(const ValueKey('home-language-menu')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('home-language-menu-en-row')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('home-language-menu-en-row')),
        findsNothing,
      );
      expect(_shellGeometry(tester), shell);
      expect(tester.takeException(), isNull);
    }
  });
}
