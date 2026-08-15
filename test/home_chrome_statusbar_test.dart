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

InstanceStatus _status({
  required String status,
  bool ready = false,
}) =>
    InstanceStatus(
      id: _config.id,
      status: status,
      pid: status == 'running' ? 42 : 0,
      port: _config.port,
      uptimeSec: status == 'running' ? 120 : 0,
      exitMsg: '',
      ready: ready,
    );

ChromeState _state({
  required Brightness brightness,
  EntityKind kind = EntityKind.instance,
  InstanceStatus? status,
}) =>
    ChromeState(
      entityKind: kind,
      configs: [_config],
      endpoints: const [_endpoint],
      statuses: status == null ? const {} : {_config.id: status},
      selectedConfigId: kind == EntityKind.instance ? _config.id : null,
      selectedEndpointId: kind == EntityKind.endpoint ? _endpoint.id : null,
      hoveredCardId: null,
      entityQuery: '',
      tabLabels: const ['Overview'],
      tabIndex: 0,
      stopAllSnapshot: const [],
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      lang: AppLang.en,
    );

const _callbacks = ChromeCallbacks(
  onEntityKind: _ignoreEntityKind,
  onSelectConfig: _ignoreConfig,
  onSelectEndpoint: _ignoreString,
  onHoverCard: _ignoreNullableString,
  onQueryChanged: _ignoreString,
  onNewConfig: _ignore,
  onMidTab: _ignoreInt,
  onStartStop: _ignoreConfig,
  onStopAll: _ignore,
  onRestoreAll: _ignore,
  onThemeMode: _ignoreThemeMode,
  onLang: _ignoreLang,
);

void _ignore() {}
void _ignoreConfig(RedimosConfig _) {}
void _ignoreEntityKind(EntityKind _) {}
void _ignoreInt(int _) {}
void _ignoreLang(AppLang _) {}
void _ignoreNullableString(String? _) {}
void _ignoreString(String _) {}
void _ignoreThemeMode(ThemeMode _) {}

Future<void> _pumpStatusbar(
  WidgetTester tester, {
  required Brightness brightness,
  required ChromeState state,
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
          cb: _callbacks,
          child: const SizedBox.expand(
            key: ValueKey('statusbar-detail-pane'),
          ),
        ),
      ),
    ),
  );
}

Color _dotColor(WidgetTester tester) {
  final dot = find.byKey(const ValueKey('home-statusbar-dot'));
  final decorated = find.descendant(
    of: dot,
    matching: find.byType(DecoratedBox),
  );
  final decoration = tester.widget<DecoratedBox>(decorated).decoration;
  return (decoration as BoxDecoration).color!;
}

List<Rect> _fixedGeometry(WidgetTester tester) => [
      tester.getRect(find.byKey(const ValueKey('home-statusbar'))),
      tester.getRect(find.byKey(const ValueKey('statusbar-detail-pane'))),
      tester.getRect(find.byKey(const ValueKey('home-statusbar-trailing'))),
    ];

void main() {
  setUp(() {
    appLang.value = AppLang.en;
  });

  tearDown(() {
    appLang.value = AppLang.en;
  });

  testWidgets('statusbar keeps a fixed 24px shell in both themes and modes',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    List<Rect>? expectedGeometry;
    for (final brightness in Brightness.values) {
      for (final kind in EntityKind.values) {
        await _pumpStatusbar(
          tester,
          brightness: brightness,
          state: _state(brightness: brightness, kind: kind),
        );

        final geometry = _fixedGeometry(tester);
        expectedGeometry ??= geometry;
        expect(geometry, expectedGeometry);
        expect(
          geometry.first,
          const Rect.fromLTWH(344, 776, 936, Dim.statusBarH),
        );
        expect(geometry[1].topLeft, const Offset(344, 92));
        expect(geometry[1].bottom, geometry.first.top);
        expect(
          tester.getSize(find.byKey(const ValueKey('home-statusbar-dot'))),
          const Size.square(7),
        );
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('statusbar uses low-emphasis semantic paint in both themes',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    for (final brightness in Brightness.values) {
      await _pumpStatusbar(
        tester,
        brightness: brightness,
        state: _state(brightness: brightness),
      );
      final tokens = AppTokens.forBrightness(brightness);
      final shell = tester.widget<Container>(
        find.byKey(const ValueKey('home-statusbar')),
      );
      final decoration = shell.decoration! as BoxDecoration;
      final statusText = tester.widget<Text>(
        find.byKey(const ValueKey('home-statusbar-status')),
      );

      expect(decoration.color, tokens.panel2);
      expect(decoration.border!.top.color, tokens.hairline);
      expect(decoration.boxShadow, isNull);
      expect(_dotColor(tester), tokens.danger);
      expect(_dotColor(tester), isNot(tokens.accent));
      expect(statusText.data, 'stopped');
      expect(statusText.style!.color, tokens.danger);
      expect(find.text('db0 · redimos'), findsOneWidget);
    }
  });

  testWidgets('instance status changes semantics without moving fixed anchors',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    const brightness = Brightness.dark;
    const tokens = AppTokens.dark;

    await _pumpStatusbar(
      tester,
      brightness: brightness,
      state: _state(brightness: brightness),
    );
    final fixed = _fixedGeometry(tester);
    final host = tester.getRect(
      find.byKey(const ValueKey('home-statusbar-host')),
    );
    expect(_dotColor(tester), tokens.danger);
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('home-statusbar-status')),
          )
          .data,
      'stopped',
    );
    expect(find.byKey(const ValueKey('home-statusbar-backend')), findsNothing);

    await _pumpStatusbar(
      tester,
      brightness: brightness,
      state: _state(
        brightness: brightness,
        status: _status(status: 'running', ready: true),
      ),
    );
    expect(_fixedGeometry(tester), fixed);
    expect(
      tester.getRect(find.byKey(const ValueKey('home-statusbar-host'))),
      host,
    );
    expect(_dotColor(tester), tokens.success);
    expect(_dotColor(tester), isNot(tokens.accent));
    expect(find.text('ready'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-statusbar-backend')), findsNothing);

    await _pumpStatusbar(
      tester,
      brightness: brightness,
      state: _state(
        brightness: brightness,
        status: _status(status: 'running'),
      ),
    );
    expect(_fixedGeometry(tester), fixed);
    expect(
      tester.getRect(find.byKey(const ValueKey('home-statusbar-host'))),
      host,
    );
    expect(_dotColor(tester), tokens.warning);
    expect(_dotColor(tester), isNot(tokens.accent));
    expect(find.text('degraded'), findsOneWidget);
    expect(find.text('backend degraded'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('endpoint summary and availability indicator remain intact',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    for (final brightness in Brightness.values) {
      await _pumpStatusbar(
        tester,
        brightness: brightness,
        state: _state(
          brightness: brightness,
          kind: EntityKind.endpoint,
        ),
      );
      final tokens = AppTokens.forBrightness(brightness);
      final summary = tester.widget<Text>(
        find.byKey(const ValueKey('home-statusbar-endpoint-summary')),
      );

      expect(summary.data, 'local · localhost:8000');
      expect(summary.style!.color, tokens.text2);
      expect(_dotColor(tester), tokens.success);
      expect(_dotColor(tester), isNot(tokens.accent));
      expect(
        find.byKey(const ValueKey('home-statusbar-dot')),
        findsOneWidget,
      );
      expect(find.text('db0 · redimos'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
