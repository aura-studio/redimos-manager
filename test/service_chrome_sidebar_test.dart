// Stage 12.4: Service navigation + sidebar widget and boundary tests.
//
// Covers the third entity branch of the shared chrome: empty state, multi-card
// listing with engine badges, query filtering across all three match fields
// (name / engine wire / :port), state paint changes without reflow, callback
// fidelity, keyboard semantics, 200% text scale, and the minimum viewport.
// Pure widget tests with a fake core: no dylib needed.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/home_chrome.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'golden_fonts.dart';
import 'viewport_assertions.dart';

ServiceInfo _svc(String id, String name,
        {String engine = 'java', int port = 8000, String state = 'stopped'}) =>
    ServiceInfo.fromJson({
      'config': {'id': id, 'name': name, 'engine': engine, 'port': port},
      'runtime': {
        'state': state,
        'ready': state == 'running',
        'healthy': state == 'running',
      },
    });

final _services = [
  _svc('svc-a', 'local-ddb', engine: 'java', port: 8000),
  _svc('svc-b', 'stage-ddb', engine: 'docker', port: 8001),
  _svc('svc-c', 'cloud-stack', engine: 'localstack', port: 4566),
];

ChromeState _state({
  required Brightness brightness,
  List<ServiceInfo> services = const [],
  String? selectedServiceId,
  String entityQuery = '',
  List<String> tabLabels = const ['Overview'],
  int tabIndex = 0,
}) =>
    ChromeState(
      entityKind: EntityKind.service,
      configs: const [],
      endpoints: const [],
      statuses: const {},
      selectedConfigId: null,
      selectedEndpointId: null,
      services: services,
      selectedServiceId: selectedServiceId,
      hoveredCardId: null,
      entityQuery: entityQuery,
      tabLabels: tabLabels,
      tabIndex: tabIndex,
      stopAllSnapshot: const [],
      lang: AppLang.en,
    );

ChromeCallbacks _callbacks({
  ValueChanged<String>? onSelectService,
  VoidCallback? onNewService,
  ValueChanged<ServiceInfo>? onServiceStartStop,
  ValueChanged<String>? onQueryChanged,
}) =>
    ChromeCallbacks(
      onEntityKind: (_) {},
      onSelectConfig: (_) {},
      onSelectEndpoint: (_) {},
      onSelectService: onSelectService ?? (_) {},
      onHoverCard: (_) {},
      onQueryChanged: onQueryChanged ?? (_) {},
      onNewConfig: () {},
      onNewService: onNewService ?? () {},
      onMidTab: (_) {},
      onStartStop: (_) {},
      onServiceStartStop: onServiceStartStop ?? (_) {},
      onStopAll: () {},
      onRestoreAll: () {},
      onLang: (_) {},
    );

Future<void> _pump(
  WidgetTester tester, {
  required Brightness brightness,
  required ChromeState state,
  ChromeCallbacks? callbacks,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await loadGoldenFonts();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme(brightness, fontFamily: kGoldenUiFont),
      themeAnimationDuration: Duration.zero,
      home: Scaffold(
        body: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: HomeChrome(
              state: state,
              cb: callbacks ?? _callbacks(),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    ),
  );
}

List<Rect> _cardGeometry(WidgetTester tester, String id) => [
      tester.getRect(find.byKey(ValueKey('entity-card-$id'))),
      tester.getRect(find.byKey(ValueKey('entity-card-$id-surface'))),
      tester.getRect(find.byKey(ValueKey('entity-card-$id-name'))),
      tester.getRect(find.byKey(ValueKey('entity-card-$id-badge'))),
      tester.getRect(find.byKey(ValueKey('entity-card-$id-trailing-slot'))),
    ];

BoxDecoration _decoration(WidgetTester tester, String id) => tester
    .widget<Container>(find.byKey(ValueKey('entity-card-$id-surface')))
    .decoration! as BoxDecoration;

void main() {
  setUp(() {
    appLang.value = AppLang.en;
  });

  tearDown(() {
    appLang.value = AppLang.en;
  });

  testWidgets('empty Service list shows the empty state and New action',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    var newCount = 0;
    await _pump(
      tester,
      brightness: Brightness.dark,
      state: _state(brightness: Brightness.dark),
      callbacks: _callbacks(onNewService: () => newCount++),
    );

    expect(find.byKey(const ValueKey('entity-sidebar-empty')), findsOneWidget);
    expect(find.text(tr('service.noneYet')), findsOneWidget);
    expect(find.byKey(const ValueKey('entity-sidebar-list')), findsNothing);
    // The New button takes the Service flavor in this branch.
    final newAction = find.byKey(const ValueKey('entity-sidebar-new-action'));
    expect(
      find.descendant(of: newAction, matching: find.text(tr('service.new'))),
      findsOneWidget,
    );
    await tester.tap(newAction);
    expect(newCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('multiple Services render one card each with badges and state',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      brightness: Brightness.dark,
      state: _state(
        brightness: Brightness.dark,
        services: _services,
        selectedServiceId: 'svc-b',
      ),
    );

    for (final s in _services) {
      expect(find.byKey(ValueKey('entity-card-${s.id}')), findsOneWidget);
      // The name key sits ON the Text widget itself; read it directly rather
      // than via find.text, which would also hit the top-bar crumb for the
      // selected Service.
      final name = tester.widget<Text>(
        find.byKey(ValueKey('entity-card-${s.id}-name')),
      );
      expect(name.data, s.config.name);
    }
    // Engine badges use the short grammar per engine family.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('entity-card-svc-a-badge')),
        matching: find.text('JAVA'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('entity-card-svc-b-badge')),
        matching: find.text('DOCKER'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('entity-card-svc-c-badge')),
        matching: find.text('STACK'),
      ),
      findsOneWidget,
    );
    // Selection paint follows selectedServiceId, not list position.
    final tokens = AppTokens.forBrightness(Brightness.dark);
    expect(_decoration(tester, 'svc-b').color, tokens.selection);
    expect(_decoration(tester, 'svc-a').color, tokens.panel);
    // The group header counts every Service (the key wraps the Text in a
    // Container, so read the descendant Text rather than casting the key).
    final countFinder = find.descendant(
      of: find.byKey(const ValueKey('entity-sidebar-count')),
      matching: find.byType(Text),
    );
    expect(tester.widget<Text>(countFinder).data, '${_services.length}');
    expect(tester.takeException(), isNull);
  });

  testWidgets('query filters by name, engine wire, and :port', (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    Future<void> pumpWith(String q) => _pump(
          tester,
          brightness: Brightness.dark,
          state: _state(
            brightness: Brightness.dark,
            services: _services,
            entityQuery: q,
          ),
        );

    await pumpWith(''); // no query: everything visible
    for (final s in _services) {
      expect(find.byKey(ValueKey('entity-card-${s.id}')), findsOneWidget);
    }

    await pumpWith('local'); // name match ('local-ddb')
    expect(find.byKey(const ValueKey('entity-card-svc-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('entity-card-svc-b')), findsNothing);

    await pumpWith('docker'); // engine wire match
    expect(find.byKey(const ValueKey('entity-card-svc-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('entity-card-svc-a')), findsNothing);

    await pumpWith(':4566'); // port match
    expect(find.byKey(const ValueKey('entity-card-svc-c')), findsOneWidget);
    expect(find.byKey(const ValueKey('entity-card-svc-a')), findsNothing);

    await pumpWith('zzz'); // nothing matches → empty state, not a crash
    expect(find.byKey(const ValueKey('entity-card-svc-a')), findsNothing);
    expect(find.byKey(const ValueKey('entity-sidebar-empty')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'running state reveals the trailing action without card reflow',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final tokens = AppTokens.forBrightness(Brightness.dark);

    await _pump(
      tester,
      brightness: Brightness.dark,
      state: _state(brightness: Brightness.dark, services: _services),
    );
    final geometry = _cardGeometry(tester, 'svc-a');
    expect(find.byKey(const ValueKey('entity-card-svc-a-start-stop')),
        findsNothing);

    await _pump(
      tester,
      brightness: Brightness.dark,
      state: _state(
        brightness: Brightness.dark,
        services: [
          _svc('svc-a', 'local-ddb', state: 'running'),
          _services[1],
          _services[2],
        ],
      ),
    );
    // Paint-only change: the card must not move or resize.
    expect(_cardGeometry(tester, 'svc-a'), geometry);
    final action = find.byKey(const ValueKey('entity-card-svc-a-start-stop'));
    expect(action, findsOneWidget);
    final slot = tester.getRect(
      find.byKey(const ValueKey('entity-card-svc-a-trailing-slot')),
    );
    expect(tester.getRect(action), slot);
    // Live state also paints the status line in a semantic color.
    expect(_decoration(tester, 'svc-a').color, tokens.panel);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sidebar callbacks preserve values and call counts',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final selected = <String>[];
    final toggled = <ServiceInfo>[];
    final queries = <String>[];
    await _pump(
      tester,
      brightness: Brightness.dark,
      state: _state(
        brightness: Brightness.dark,
        services: [_svc('svc-a', 'local-ddb', state: 'running')],
      ),
      callbacks: _callbacks(
        onSelectService: selected.add,
        onServiceStartStop: toggled.add,
        onQueryChanged: queries.add,
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('entity-sidebar-search')),
      'local',
    );
    await tester.tap(find.byKey(const ValueKey('entity-card-svc-a-action')));
    await tester.tap(
      find.byKey(const ValueKey('entity-card-svc-a-start-stop')),
    );
    expect(queries, ['local']);
    expect(selected, ['svc-a']);
    expect(toggled, hasLength(1));
    expect(toggled.single.id, 'svc-a');
    expect(toggled.single.runtime.isLive, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'keyboard focus reveals and activates start stop without card reflow',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final selected = <String>[];
    final toggled = <ServiceInfo>[];
    await _pump(
      tester,
      brightness: Brightness.dark,
      state: _state(brightness: Brightness.dark, services: _services),
      callbacks: _callbacks(
        onSelectService: selected.add,
        onServiceStartStop: toggled.add,
      ),
    );

    final geometry = _cardGeometry(tester, 'svc-a');
    final cardSurface =
        find.byKey(const ValueKey('entity-card-svc-a-surface'));
    final action = find.byKey(const ValueKey('entity-card-svc-a-start-stop'));
    expect(action, findsNothing);

    Focus.of(cardSurface.evaluate().single).requestFocus();
    await tester.pump();

    expect(action, findsOneWidget);
    expect(_cardGeometry(tester, 'svc-a'), geometry);
    expect(tester.getRect(action), geometry.last);
    expect(
      _decoration(tester, 'svc-a').border!.top.color,
      AppTokens.forBrightness(Brightness.dark).focus,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(selected, ['svc-a']);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(action, findsOneWidget);
    expect(_cardGeometry(tester, 'svc-a'), geometry);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(toggled.map((s) => s.id), ['svc-a']);
    expect(_cardGeometry(tester, 'svc-a'), geometry);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(action, findsNothing);
    expect(_cardGeometry(tester, 'svc-a'), geometry);
    expect(tester.takeException(), isNull);
  });

  testWidgets('200% text scale keeps the sidebar shell fixed and readable',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      brightness: Brightness.dark,
      state: _state(
        brightness: Brightness.dark,
        services: _services,
        selectedServiceId: 'svc-a',
      ),
    );
    final shellBefore = tester.getRect(
      find.byKey(const ValueKey('entity-sidebar')),
    );
    final searchBefore = tester.getRect(
      find.byKey(const ValueKey('entity-sidebar-search')),
    );

    await _pump(
      tester,
      brightness: Brightness.dark,
      state: _state(
        brightness: Brightness.dark,
        services: _services,
        selectedServiceId: 'svc-a',
      ),
      textScaler: const TextScaler.linear(2),
    );
    // The shell is token-sized, never text-sized: scaling must not move it.
    expect(
      tester.getRect(find.byKey(const ValueKey('entity-sidebar'))),
      shellBefore,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('entity-sidebar-search'))),
      searchBefore,
    );
    expect(tester.getRect(find.byKey(const ValueKey('entity-sidebar'))).width,
        Dim.sidebarW);
    // Cards remain present and hit-testable under the scale.
    expectHitTestable(
      tester,
      find.byKey(const ValueKey('entity-card-svc-a-action')),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('minimum viewport keeps every Service control in bounds',
      (tester) async {
    // The smallest window the app targets (1280x800 logical).
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      brightness: Brightness.light,
      state: _state(
        brightness: Brightness.light,
        services: _services,
        selectedServiceId: 'svc-a',
      ),
    );

    expectInsideTestViewport(
      tester,
      find.byKey(const ValueKey('entity-sidebar')),
    );
    expectHitTestable(
      tester,
      find.byKey(const ValueKey('entity-sidebar-search')),
    );
    expectHitTestable(
      tester,
      find.byKey(const ValueKey('entity-sidebar-new-action')),
    );
    for (final s in _services) {
      expectHitTestable(
        tester,
        find.byKey(ValueKey('entity-card-${s.id}-action')),
      );
    }
    // The rail item for Services is reachable too.
    expectHitTestable(
      tester,
      find.byKey(const ValueKey('main-rail-service-action')),
    );
    expect(tester.takeException(), isNull);
  });
}
