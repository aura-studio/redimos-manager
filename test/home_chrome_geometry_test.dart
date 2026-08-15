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

ChromeState _state({
  required Brightness brightness,
  required EntityKind kind,
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
      tabLabels: const [
        'Overview',
        'Browser',
        'PartiQL',
        'Playground',
        'Monitor',
        'Logs',
      ],
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

Future<void> _pumpChrome(
  WidgetTester tester, {
  required Brightness brightness,
  required EntityKind kind,
}) async {
  await loadGoldenFonts();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme(brightness, fontFamily: kGoldenUiFont),
      themeAnimationDuration: Duration.zero,
      home: Scaffold(
        body: HomeChrome(
          state: _state(brightness: brightness, kind: kind),
          cb: _callbacks,
          child: const SizedBox.expand(
            key: ValueKey('home-detail-pane'),
          ),
        ),
      ),
    ),
  );
}

List<Rect> _shellGeometry(WidgetTester tester) => [
      tester.getRect(find.byKey(const ValueKey('main-rail'))),
      tester.getRect(find.byKey(const ValueKey('entity-sidebar'))),
      tester.getRect(find.byKey(const ValueKey('home-topbar'))),
      tester.getRect(find.byKey(const ValueKey('home-midbar'))),
      tester.getRect(find.byKey(const ValueKey('home-detail-pane'))),
      tester.getRect(find.byKey(const ValueKey('home-statusbar'))),
    ];

void main() {
  setUp(() {
    appLang.value = AppLang.en;
  });

  tearDown(() {
    appLang.value = AppLang.en;
  });

  testWidgets('complete shell geometry is fixed at 1280x800 in both themes',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    const expected = [
      Rect.fromLTWH(0, 0, Dim.railW, 800),
      Rect.fromLTWH(Dim.railW, 0, Dim.sidebarW, 800),
      Rect.fromLTWH(344, 0, 936, Dim.topBarH),
      Rect.fromLTWH(344, Dim.topBarH, 936, Dim.midBarH),
      Rect.fromLTWH(344, 92, 936, 684),
      Rect.fromLTWH(344, 776, 936, Dim.statusBarH),
    ];

    List<Rect>? baseline;
    for (final brightness in Brightness.values) {
      for (final kind in EntityKind.values) {
        await _pumpChrome(tester, brightness: brightness, kind: kind);
        final geometry = _shellGeometry(tester);
        baseline ??= geometry;

        expect(geometry, expected);
        expect(geometry, baseline);
        expect(geometry[0].right, geometry[1].left);
        expect(geometry[1].right, geometry[2].left);
        expect(geometry[2].bottom, geometry[3].top);
        expect(geometry[3].bottom, geometry[4].top);
        expect(geometry[4].bottom, geometry[5].top);
        expect(geometry[5].bottom, 800);
        expect(tester.takeException(), isNull);
      }
    }
  });
}
