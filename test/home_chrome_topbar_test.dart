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

// Stage 12: the Service entity fixture for the crumb / status bar branches.
final _svc = ServiceInfo.fromJson({
  'config': {
    'id': 'service-1',
    'name': 'local-ddb',
    'engine': 'java',
    'port': 8000,
  },
  'runtime': {'state': 'stopped', 'ready': false, 'healthy': false},
});

ChromeState _state({
  required Brightness brightness,
  EntityKind kind = EntityKind.instance,
  int tabIndex = 0,
  List<String> tabLabels = const ['Browse', 'A much longer screen name'],
  Map<String, InstanceStatus> statuses = const {},
  List<String> stopAllSnapshot = const [],
}) =>
    ChromeState(
      entityKind: kind,
      configs: [_config],
      endpoints: const [_endpoint],
      statuses: statuses,
      selectedConfigId: kind == EntityKind.instance ? _config.id : null,
      selectedEndpointId: kind == EntityKind.endpoint ? _endpoint.id : null,
      services: kind == EntityKind.service ? [_svc] : const [],
      selectedServiceId: kind == EntityKind.service ? _svc.id : null,
      hoveredCardId: null,
      entityQuery: '',
      tabLabels: tabLabels,
      tabIndex: tabIndex,
      stopAllSnapshot: stopAllSnapshot,
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      lang: AppLang.en,
    );

ChromeCallbacks _callbacks({
  VoidCallback? onStopAll,
  VoidCallback? onRestoreAll,
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
      onStopAll: onStopAll ?? () {},
      onRestoreAll: onRestoreAll ?? () {},
      onThemeMode: (_) {},
      onLang: (_) {},
    );

Future<void> _pumpTopbar(
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

List<Rect> _invariantGeometry(WidgetTester tester) => [
      tester.getRect(find.byKey(const ValueKey('home-topbar'))),
      tester.getRect(find.byKey(const ValueKey('home-topbar-entity'))),
      tester.getRect(find.byKey(const ValueKey('home-topbar-sub-entity'))),
      tester.getRect(find.byKey(const ValueKey('home-topbar-actions'))),
      tester.getRect(find.byKey(const ValueKey('home-topbar-stop-slot'))),
      tester.getRect(find.byKey(const ValueKey('home-topbar-theme-slot'))),
      tester.getRect(find.byKey(const ValueKey('home-topbar-lang-slot'))),
    ];

void main() {
  setUp(() {
    appLang.value = AppLang.en;
  });

  tearDown(() {
    appLang.value = AppLang.en;
  });

  testWidgets('topbar geometry is fixed across themes and entity kinds',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    for (final brightness in Brightness.values) {
      for (final kind in EntityKind.values) {
        await _pumpTopbar(
          tester,
          brightness: brightness,
          state: _state(brightness: brightness, kind: kind),
        );

        final topbar = tester.getRect(
          find.byKey(const ValueKey('home-topbar')),
        );
        expect(topbar, const Rect.fromLTWH(344, 0, 936, Dim.topBarH));

        final slots = [
          tester.getSize(
            find.byKey(const ValueKey('home-topbar-stop-slot')),
          ),
          tester.getSize(
            find.byKey(const ValueKey('home-topbar-theme-slot')),
          ),
          tester.getSize(
            find.byKey(const ValueKey('home-topbar-lang-slot')),
          ),
        ];
        expect(
          slots,
          everyElement(const Size(Dim.ctlH, Dim.ctlH)),
        );
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('entity context anchors do not move across tab labels',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    for (final brightness in Brightness.values) {
      for (final kind in EntityKind.values) {
        await _pumpTopbar(
          tester,
          brightness: brightness,
          state: _state(
            brightness: brightness,
            kind: kind,
            tabIndex: 0,
          ),
        );
        final before = _invariantGeometry(tester);
        final screenBefore = tester.getRect(
          find.byKey(const ValueKey('home-topbar-screen-name')),
        );

        await _pumpTopbar(
          tester,
          brightness: brightness,
          state: _state(
            brightness: brightness,
            kind: kind,
            tabIndex: 1,
          ),
        );
        final after = _invariantGeometry(tester);
        final screenAfter = tester.getRect(
          find.byKey(const ValueKey('home-topbar-screen-name')),
        );

        expect(after, before);
        expect(screenAfter.left, screenBefore.left);
        expect(screenAfter.top, screenBefore.top);
        expect(screenAfter.width, greaterThan(screenBefore.width));
      }
    }
  });

  testWidgets('topbar uses semantic surface paint in both themes',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    for (final brightness in Brightness.values) {
      await _pumpTopbar(
        tester,
        brightness: brightness,
        state: _state(brightness: brightness),
      );
      final tokens = AppTokens.forBrightness(brightness);
      final topbar = tester.widget<Container>(
        find.byKey(const ValueKey('home-topbar')),
      );
      final decoration = topbar.decoration! as BoxDecoration;

      expect(decoration.color, tokens.panel);
      expect(decoration.border!.bottom.color, tokens.hairline);
      expect(decoration.border!.top, BorderSide.none);
      expect(decoration.gradient, isNull);
      expect(decoration.boxShadow, hasLength(1));

      final entity = tester.widget<Text>(
        find.byKey(const ValueKey('home-topbar-entity')),
      );
      final sub = tester.widget<Text>(
        find.byKey(const ValueKey('home-topbar-sub-entity')),
      );
      final screen = tester.widget<Text>(
        find.byKey(const ValueKey('home-topbar-screen-name')),
      );
      expect(entity.style!.color, tokens.text);
      expect(sub.style!.color, tokens.text3);
      expect(screen.style!.color, tokens.text);
    }
  });

  testWidgets('stop and restore actions preserve callback behavior',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    var stopCount = 0;
    var restoreCount = 0;
    final callbacks = _callbacks(
      onStopAll: () => stopCount++,
      onRestoreAll: () => restoreCount++,
    );
    final running = InstanceStatus(
      id: _config.id,
      status: 'running',
      pid: 42,
      port: _config.port,
      uptimeSec: 1,
      exitMsg: '',
    );

    await _pumpTopbar(
      tester,
      brightness: Brightness.dark,
      state: _state(
        brightness: Brightness.dark,
        statuses: {_config.id: running},
      ),
      callbacks: callbacks,
    );
    await tester.tap(
      find.byKey(const ValueKey('home-topbar-stop-slot')),
    );
    expect(stopCount, 1);
    expect(restoreCount, 0);

    await _pumpTopbar(
      tester,
      brightness: Brightness.dark,
      state: _state(
        brightness: Brightness.dark,
        stopAllSnapshot: [_config.id],
      ),
      callbacks: callbacks,
    );
    await tester.tap(
      find.byKey(const ValueKey('home-topbar-stop-slot')),
    );
    expect(stopCount, 1);
    expect(restoreCount, 1);
  });
}
