import 'dart:io';
import 'dart:ui' as ui show ImageByteFormat;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/home_chrome.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'golden_fonts.dart';

const _diagnosticDirectoryVariable = 'REDIMOS_RAIL_DIAGNOSTIC_DIR';
const _diagnosticRoot = '/Users/tony/Documents/Claude';

ChromeState _state(EntityKind kind, Brightness brightness) => ChromeState(
      entityKind: kind,
      configs: const [],
      endpoints: const [],
      statuses: const {},
      selectedConfigId: null,
      selectedEndpointId: null,
      hoveredCardId: null,
      entityQuery: '',
      tabLabels: const ['Browse'],
      tabIndex: 0,
      stopAllSnapshot: const [],
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      lang: AppLang.en,
    );

ChromeCallbacks _callbacks({ValueChanged<EntityKind>? onEntityKind}) =>
    ChromeCallbacks(
      onEntityKind: onEntityKind ?? (_) {},
      onSelectConfig: (_) {},
      onSelectEndpoint: (_) {},
      onHoverCard: (_) {},
      onQueryChanged: (_) {},
      onNewConfig: () {},
      onMidTab: (_) {},
      onStartStop: (_) {},
      onStopAll: () {},
      onRestoreAll: () {},
      onThemeMode: (_) {},
      onLang: (_) {},
    );

Future<void> _pumpRail(
  WidgetTester tester, {
  required Brightness brightness,
  required EntityKind kind,
  ValueChanged<EntityKind>? onEntityKind,
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
            state: _state(kind, brightness),
            cb: _callbacks(onEntityKind: onEntityKind),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    ),
  );
}

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
  File('${directory.path}/home-chrome-rail-${brightness.name}.png')
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

List<Rect> _geometry(WidgetTester tester) => [
      tester.getRect(find.byKey(const ValueKey('main-rail'))),
      tester.getRect(find.byKey(const ValueKey('main-rail-logo'))),
      tester.getRect(find.byKey(const ValueKey('main-rail-instance-item'))),
      tester.getRect(find.byKey(const ValueKey('main-rail-instance-tile'))),
      tester.getRect(find.byKey(const ValueKey('main-rail-endpoint-item'))),
      tester.getRect(find.byKey(const ValueKey('main-rail-endpoint-tile'))),
      tester.getRect(find.byKey(const ValueKey('main-rail-service-item'))),
      tester.getRect(find.byKey(const ValueKey('main-rail-service-tile'))),
    ];

void main() {
  setUp(() {
    appLang.value = AppLang.en;
  });

  tearDown(() {
    appLang.value = AppLang.en;
  });

  testWidgets('rail geometry is fixed across themes and active entity',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    List<Rect>? expected;
    for (final brightness in Brightness.values) {
      for (final kind in EntityKind.values) {
        await _pumpRail(tester, brightness: brightness, kind: kind);
        final geometry = _geometry(tester);
        expected ??= geometry;
        expect(geometry, expected);
        expect(geometry[0].width, Dim.railW);
        expect(geometry[1].size, const Size(36, 36));
        expect(geometry[2].size, const Size(Dim.railW, 42));
        expect(geometry[3].size, const Size(44, 42));
        expect(geometry[4].size, const Size(Dim.railW, 42));
        expect(geometry[5].size, const Size(44, 42));
        // Stage 12: the Service item sits under the Endpoint item with the
        // same tile grammar.
        expect(geometry[6].size, const Size(Dim.railW, 42));
        expect(geometry[7].size, const Size(44, 42));

        final activeName = switch (kind) {
          EntityKind.instance => 'instance',
          EntityKind.endpoint => 'endpoint',
          EntityKind.service => 'service',
        };
        final indicator =
            find.byKey(ValueKey('main-rail-$activeName-indicator'));
        expect(indicator, findsOneWidget);
        expect(tester.getSize(indicator), const Size(2, 24));
      }
    }
  });

  testWidgets('rail uses flat themed paint without gradients or glow',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final shotKey = GlobalKey();
    for (final brightness in Brightness.values) {
      await _pumpRail(
        tester,
        brightness: brightness,
        kind: EntityKind.instance,
        shotKey: shotKey,
      );
      final tokens = AppTokens.forBrightness(brightness);
      final rail = tester.widget<Container>(
        find.byKey(const ValueKey('main-rail')),
      );
      final railDecoration = rail.decoration! as BoxDecoration;
      expect(railDecoration.color, tokens.railBg);
      expect(railDecoration.gradient, isNull);
      expect(railDecoration.boxShadow, isNull);

      final activeTile = tester.widget<Material>(
        find.byKey(const ValueKey('main-rail-instance-tile')),
      );
      final inactiveTile = tester.widget<Material>(
        find.byKey(const ValueKey('main-rail-endpoint-tile')),
      );
      expect(activeTile.color, tokens.railActiveBg);
      expect(inactiveTile.color, Colors.transparent);

      final indicator = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('main-rail-instance-indicator')),
      );
      final indicatorDecoration = indicator.decoration as BoxDecoration;
      expect(indicatorDecoration.color, tokens.accent);
      expect(indicatorDecoration.gradient, isNull);
      expect(indicatorDecoration.boxShadow, isNull);

      final logoFinder = find.descendant(
        of: find.byKey(const ValueKey('main-rail-logo')),
        matching: find.byType(Container),
      );
      final logo = tester.widget<Container>(logoFinder.first);
      final logoDecoration = logo.decoration! as BoxDecoration;
      expect(logoDecoration.color, tokens.accent);
      expect(logoDecoration.gradient, isNull);
      expect(logoDecoration.boxShadow, hasLength(1));

      await _writeDiagnosticPngIfRequested(tester, shotKey, brightness);
    }
  });

  testWidgets(
      'rail hover is geometry-stable and callbacks preserve entity kind',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final selected = <EntityKind>[];
    await _pumpRail(
      tester,
      brightness: Brightness.dark,
      kind: EntityKind.instance,
      onEntityKind: selected.add,
    );

    final before = _geometry(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(
        find.byKey(const ValueKey('main-rail-endpoint-action')),
      ),
    );
    await tester.pump();
    expect(_geometry(tester), before);

    await tester.tap(find.byKey(const ValueKey('main-rail-instance-action')));
    await tester.tap(find.byKey(const ValueKey('main-rail-endpoint-action')));
    expect(selected, [EntityKind.instance, EntityKind.endpoint]);

    await mouse.removePointer();
  });

  testWidgets('rail keyboard focus is visible and geometry-stable',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    for (final brightness in Brightness.values) {
      final selected = <EntityKind>[];
      await _pumpRail(
        tester,
        brightness: brightness,
        kind: EntityKind.instance,
        onEntityKind: selected.add,
      );
      final tokens = AppTokens.forBrightness(brightness);
      final before = _geometry(tester);

      final instanceTarget = find.byKey(
        const ValueKey('main-rail-instance-focus-target'),
      );
      Focus.of(instanceTarget.evaluate().single).requestFocus();
      await tester.pump();

      final instanceTile = tester.widget<Material>(
        find.byKey(const ValueKey('main-rail-instance-tile')),
      );
      final instanceShape = instanceTile.shape! as RoundedRectangleBorder;
      expect(instanceShape.side.color, tokens.focus);
      expect(instanceShape.side.width, Dim.borderW);
      expect(_geometry(tester), before);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(selected, [EntityKind.instance]);

      final endpointTarget = find.byKey(
        const ValueKey('main-rail-endpoint-focus-target'),
      );
      Focus.of(endpointTarget.evaluate().single).requestFocus();
      await tester.pump();

      final endpointTile = tester.widget<Material>(
        find.byKey(const ValueKey('main-rail-endpoint-tile')),
      );
      final endpointShape = endpointTile.shape! as RoundedRectangleBorder;
      expect(endpointShape.side.color, tokens.focus);
      expect(endpointShape.side.width, Dim.borderW);
      expect(_geometry(tester), before);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(selected, [EntityKind.instance, EntityKind.endpoint]);
      expect(tester.takeException(), isNull);
    }
  });
}
