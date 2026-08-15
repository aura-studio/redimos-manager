import 'dart:io';
import 'dart:ui' as ui show ImageByteFormat;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/home_chrome.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'golden_fonts.dart';

const _diagnosticDirectoryVariable = 'REDIMOS_SIDEBAR_DIAGNOSTIC_DIR';
const _diagnosticRoot = '/Users/tony/Documents/Claude';

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


// Stage 12: Service fixtures for the entity sidebar's third branch.
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

final _service = _svc('service-1', 'local-ddb');

ChromeState _state({
  required Brightness brightness,
  EntityKind kind = EntityKind.instance,
  String? selectedConfigId,
  String? selectedEndpointId,
  List<ServiceInfo> services = const [],
  String? selectedServiceId,
  String? hoveredCardId,
  String entityQuery = '',
  Map<String, InstanceStatus> statuses = const {},
}) =>
    ChromeState(
      entityKind: kind,
      configs: [_config],
      endpoints: const [_endpoint],
      statuses: statuses,
      selectedConfigId: selectedConfigId,
      selectedEndpointId: selectedEndpointId,
      services: services,
      selectedServiceId: selectedServiceId,
      hoveredCardId: hoveredCardId,
      entityQuery: entityQuery,
      tabLabels: const ['Browse'],
      tabIndex: 0,
      stopAllSnapshot: const [],
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      lang: AppLang.en,
    );

ChromeCallbacks _callbacks({
  ValueChanged<RedimosConfig>? onSelectConfig,
  ValueChanged<String>? onSelectEndpoint,
  ValueChanged<String?>? onHoverCard,
  ValueChanged<String>? onQueryChanged,
  VoidCallback? onNewConfig,
  ValueChanged<RedimosConfig>? onStartStop,
}) =>
    ChromeCallbacks(
      onEntityKind: (_) {},
      onSelectConfig: onSelectConfig ?? (_) {},
      onSelectEndpoint: onSelectEndpoint ?? (_) {},
      onHoverCard: onHoverCard ?? (_) {},
      onQueryChanged: onQueryChanged ?? (_) {},
      onNewConfig: onNewConfig ?? () {},
      onMidTab: (_) {},
      onStartStop: onStartStop ?? (_) {},
      onStopAll: () {},
      onRestoreAll: () {},
      onThemeMode: (_) {},
      onLang: (_) {},
    );

Future<void> _pumpSidebar(
  WidgetTester tester, {
  required Brightness brightness,
  required ChromeState state,
  ChromeCallbacks? callbacks,
  GlobalKey? shotKey,
}) async {
  await loadGoldenFonts();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme(brightness, fontFamily: kGoldenUiFont),
      themeAnimationDuration: Duration.zero,
      home: RepaintBoundary(
        key: shotKey,
        child: Scaffold(
          body: HomeChrome(
            state: state,
            cb: callbacks ?? _callbacks(),
            child: const SizedBox.expand(),
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

Future<void> _writeDiagnosticPngIfRequested(
  WidgetTester tester,
  GlobalKey shotKey,
  Brightness brightness,
) async {
  final rawDirectory = Platform.environment[_diagnosticDirectoryVariable];
  if (rawDirectory == null || rawDirectory.trim().isEmpty) return;

  final directory = Directory(rawDirectory).absolute;
  final root = Directory(_diagnosticRoot).absolute.path;
  final path = directory.path;
  if (path != root && !path.startsWith('$root${Platform.pathSeparator}')) {
    fail(
      '$_diagnosticDirectoryVariable must be an absolute directory inside '
      '$_diagnosticRoot; received $rawDirectory',
    );
  }
  directory.createSync(recursive: true);
  final bytes = await _boundaryPng(tester, shotKey);
  File('${directory.path}/home-chrome-sidebar-${brightness.name}.png')
      .writeAsBytesSync(bytes);
}

Future<Uint8List> _boundaryPng(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

void main() {
  setUp(() {
    appLang.value = AppLang.en;
  });

  tearDown(() {
    appLang.value = AppLang.en;
  });

  testWidgets('sidebar geometry is fixed across themes and entity kinds',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    List<Rect>? expectedShellGeometry;
    for (final brightness in Brightness.values) {
      for (final kind in EntityKind.values) {
        final selectedEndpoint =
            kind == EntityKind.endpoint ? _endpoint.id : null;
        final id = switch (kind) {
          EntityKind.instance => _config.id,
          EntityKind.endpoint => _endpoint.id,
          EntityKind.service => _service.id,
        };
        await _pumpSidebar(
          tester,
          brightness: brightness,
          state: _state(
            brightness: brightness,
            kind: kind,
            selectedConfigId: kind == EntityKind.instance ? _config.id : null,
            selectedEndpointId: selectedEndpoint,
            services: kind == EntityKind.service ? [_service] : const [],
            selectedServiceId:
                kind == EntityKind.service ? _service.id : null,
          ),
        );

        final shellGeometry = [
          tester.getRect(find.byKey(const ValueKey('entity-sidebar'))),
          tester.getRect(find.byKey(const ValueKey('entity-sidebar-search'))),
          tester
              .getRect(find.byKey(const ValueKey('entity-sidebar-new-action'))),
          tester.getRect(
              find.byKey(const ValueKey('entity-sidebar-group-header'))),
          tester.getRect(find.byKey(const ValueKey('entity-sidebar-list'))),
        ];
        expectedShellGeometry ??= shellGeometry;
        expect(shellGeometry, expectedShellGeometry);
        expect(shellGeometry.first.width, Dim.sidebarW);
        expect(shellGeometry[1].height, Dim.ctlH);
        expect(shellGeometry[2].height, Dim.ctlH);

        final slot = tester.getSize(
          find.byKey(ValueKey('entity-card-$id-trailing-slot')),
        );
        expect(slot, const Size(Dim.trailingSlot, Dim.trailingSlot));
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('sidebar uses semantic neutral paint in both themes',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final shotKey = GlobalKey();
    for (final brightness in Brightness.values) {
      await _pumpSidebar(
        tester,
        brightness: brightness,
        state: _state(
          brightness: brightness,
          selectedConfigId: _config.id,
        ),
        shotKey: shotKey,
      );
      final tokens = AppTokens.forBrightness(brightness);

      final sidebar = tester.widget<Container>(
        find.byKey(const ValueKey('entity-sidebar')),
      );
      final sidebarDecoration = sidebar.decoration! as BoxDecoration;
      expect(sidebarDecoration.color, tokens.sidebar);
      expect(sidebarDecoration.gradient, isNull);
      expect(sidebarDecoration.boxShadow, isNull);

      final badge = tester.widget<Container>(
        find.byKey(ValueKey('entity-card-${_config.id}-badge')),
      );
      final badgeDecoration = badge.decoration! as BoxDecoration;
      expect(badgeDecoration.color, tokens.panel2);
      expect(badgeDecoration.border!.top.color, tokens.hairline);
      expect(
        badgeDecoration.color,
        isNot(anyOf(
          tokens.accent,
          tokens.success,
          tokens.warning,
          tokens.danger,
        )),
      );
      final badgeText = tester.widget<Text>(
        find.descendant(
          of: find.byKey(ValueKey('entity-card-${_config.id}-badge')),
          matching: find.text('INST'),
        ),
      );
      expect(badgeText.style!.color, tokens.text2);

      final selected = _decoration(tester, _config.id);
      expect(selected.color, tokens.selection);
      expect(selected.border!.top.color, tokens.accent);
      expect(selected.border!.top.width, Dim.borderW);
      expect(selected.boxShadow, hasLength(1));

      await _writeDiagnosticPngIfRequested(tester, shotKey, brightness);
    }
  });

  testWidgets(
      'normal hover running and selected states change paint without reflow',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    const brightness = Brightness.dark;
    final tokens = AppTokens.forBrightness(brightness);
    final runningStatus = InstanceStatus(
      id: _config.id,
      status: 'running',
      pid: 42,
      port: _config.port,
      uptimeSec: 1,
      exitMsg: '',
    );
    List<Rect>? geometry;

    await _pumpSidebar(
      tester,
      brightness: brightness,
      state: _state(brightness: brightness),
    );
    geometry = _cardGeometry(tester, _config.id);
    expect(_decoration(tester, _config.id).color, tokens.panel);
    expect(find.byKey(ValueKey('entity-card-${_config.id}-start-stop')),
        findsNothing);

    await _pumpSidebar(
      tester,
      brightness: brightness,
      state: _state(brightness: brightness, hoveredCardId: _config.id),
    );
    expect(_cardGeometry(tester, _config.id), geometry);
    expect(_decoration(tester, _config.id).color, tokens.hover);
    final hoverSlot = tester.getRect(
      find.byKey(ValueKey('entity-card-${_config.id}-trailing-slot')),
    );
    final hoverAction = tester.getRect(
      find.byKey(ValueKey('entity-card-${_config.id}-start-stop')),
    );
    expect(hoverSlot.size, const Size(Dim.trailingSlot, Dim.trailingSlot));
    expect(hoverAction, hoverSlot);

    await _pumpSidebar(
      tester,
      brightness: brightness,
      state: _state(
        brightness: brightness,
        statuses: {_config.id: runningStatus},
      ),
    );
    expect(_cardGeometry(tester, _config.id), geometry);
    expect(_decoration(tester, _config.id).color, tokens.panel);
    final runningSlot = tester.getRect(
      find.byKey(ValueKey('entity-card-${_config.id}-trailing-slot')),
    );
    final runningAction = tester.getRect(
      find.byKey(ValueKey('entity-card-${_config.id}-start-stop')),
    );
    expect(runningSlot, hoverSlot);
    expect(runningAction, runningSlot);

    await _pumpSidebar(
      tester,
      brightness: brightness,
      state: _state(brightness: brightness, selectedConfigId: _config.id),
    );
    expect(_cardGeometry(tester, _config.id), geometry);
    expect(_decoration(tester, _config.id).color, tokens.selection);

    await _pumpSidebar(
      tester,
      brightness: brightness,
      state: _state(
        brightness: brightness,
        selectedConfigId: _config.id,
        hoveredCardId: _config.id,
      ),
    );
    expect(_cardGeometry(tester, _config.id), geometry);
    expect(_decoration(tester, _config.id).color, tokens.selection);
    expect(
      tester.getSize(
        find.byKey(ValueKey('entity-card-${_config.id}-trailing-slot')),
      ),
      const Size(Dim.trailingSlot, Dim.trailingSlot),
    );
  });

  testWidgets(
      'keyboard focus reveals and activates start stop without card reflow',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    for (final brightness in Brightness.values) {
      final selectedConfigs = <RedimosConfig>[];
      final startStopConfigs = <RedimosConfig>[];
      await _pumpSidebar(
        tester,
        brightness: brightness,
        state: _state(brightness: brightness),
        callbacks: _callbacks(
          onSelectConfig: selectedConfigs.add,
          onStartStop: startStopConfigs.add,
        ),
      );

      final geometry = _cardGeometry(tester, _config.id);
      final cardSurface =
          find.byKey(ValueKey('entity-card-${_config.id}-surface'));
      final action =
          find.byKey(ValueKey('entity-card-${_config.id}-start-stop'));
      expect(action, findsNothing);

      Focus.of(cardSurface.evaluate().single).requestFocus();
      await tester.pump();

      expect(action, findsOneWidget);
      expect(_cardGeometry(tester, _config.id), geometry);
      expect(tester.getRect(action), geometry.last);
      final focusedDecoration = _decoration(tester, _config.id);
      expect(
        focusedDecoration.border!.top.color,
        AppTokens.forBrightness(brightness).focus,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(selectedConfigs, [same(_config)]);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(action, findsOneWidget);
      expect(_cardGeometry(tester, _config.id), geometry);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(startStopConfigs, [same(_config)]);
      expect(_cardGeometry(tester, _config.id), geometry);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(action, findsNothing);
      expect(_cardGeometry(tester, _config.id), geometry);
      expect(tester.takeException(), isNull);
    }
  });


  testWidgets('sidebar callbacks preserve values and call counts',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final selectedConfigs = <RedimosConfig>[];
    final selectedEndpoints = <String>[];
    final hoveredCards = <String?>[];
    final queries = <String>[];
    final startStopConfigs = <RedimosConfig>[];
    var newCount = 0;
    final callbacks = _callbacks(
      onSelectConfig: selectedConfigs.add,
      onSelectEndpoint: selectedEndpoints.add,
      onHoverCard: hoveredCards.add,
      onQueryChanged: queries.add,
      onNewConfig: () => newCount++,
      onStartStop: startStopConfigs.add,
    );

    await _pumpSidebar(
      tester,
      brightness: Brightness.dark,
      state: _state(
        brightness: Brightness.dark,
        hoveredCardId: _config.id,
      ),
      callbacks: callbacks,
    );
    await tester.enterText(
      find.byKey(const ValueKey('entity-sidebar-search')),
      'cache:6379',
    );
    await tester.tap(find.byKey(const ValueKey('entity-sidebar-new-action')));
    await tester.tap(find.byKey(ValueKey('entity-card-${_config.id}-action')));
    await tester.tap(
      find.byKey(ValueKey('entity-card-${_config.id}-start-stop')),
    );
    expect(queries, ['cache:6379']);
    expect(newCount, 1);
    expect(selectedConfigs, [same(_config)]);
    expect(startStopConfigs, [same(_config)]);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester
          .getCenter(find.byKey(ValueKey('entity-card-${_config.id}-action'))),
    );
    await tester.pump();
    expect(hoveredCards, contains(_config.id));
    await mouse.removePointer();

    await _pumpSidebar(
      tester,
      brightness: Brightness.dark,
      state: _state(
        brightness: Brightness.dark,
        kind: EntityKind.endpoint,
        selectedEndpointId: _endpoint.id,
      ),
      callbacks: callbacks,
    );
    await tester
        .tap(find.byKey(ValueKey('entity-card-${_endpoint.id}-action')));
    expect(selectedEndpoints, [_endpoint.id]);
  });
}
