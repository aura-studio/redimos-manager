import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
  id: 'platform-smoke-instance',
  name: '生产缓存实例',
  port: 6379,
  endpoint: '',
);

const _endpoint = DdbEndpoint(
  id: 'platform-smoke-endpoint',
  name: '本地数据端点',
  kind: 'local',
  endpoint: 'http://localhost:8000',
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
  onDdbMutated: _ignore,
);

void _ignore() {}
void _ignoreConfig(RedimosConfig _) {}
void _ignoreEntityKind(EntityKind _) {}
void _ignoreInt(int _) {}
void _ignoreLang(AppLang _) {}
void _ignoreNullableString(String? _) {}
void _ignoreString(String _) {}
void _ignoreThemeMode(ThemeMode _) {}

ChromeState _state(Brightness brightness) => ChromeState(
      entityKind: EntityKind.instance,
      configs: [_config],
      endpoints: const [_endpoint],
      statuses: const {},
      selectedConfigId: _config.id,
      selectedEndpointId: null,
      hoveredCardId: null,
      entityQuery: '',
      tabLabels: [
        tr('tab.browser'),
        tr('tab.console'),
        tr('tab.monitor'),
        tr('tab.logs'),
        tr('tab.playground'),
        tr('tab.configure'),
      ],
      tabIndex: 0,
      stopAllSnapshot: const [],
      ddb: null,
      themeMode:
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      lang: AppLang.zh,
    );

Future<void> _pumpShell(
  WidgetTester tester, {
  required Brightness brightness,
  required ScrollController controller,
  required ValueChanged<EntityKind> onEntityKind,
}) async {
  tester.view.physicalSize = const Size(2560, 1600);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  final callbacks = ChromeCallbacks(
    onEntityKind: onEntityKind,
    onSelectConfig: _callbacks.onSelectConfig,
    onSelectEndpoint: _callbacks.onSelectEndpoint,
    onHoverCard: _callbacks.onHoverCard,
    onQueryChanged: _callbacks.onQueryChanged,
    onNewConfig: _callbacks.onNewConfig,
    onMidTab: _callbacks.onMidTab,
    onStartStop: _callbacks.onStartStop,
    onStopAll: _callbacks.onStopAll,
    onRestoreAll: _callbacks.onRestoreAll,
    onThemeMode: _callbacks.onThemeMode,
    onLang: _callbacks.onLang,
    onDdbMutated: _callbacks.onDdbMutated,
  );

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme(brightness, fontFamily: kGoldenUiFont),
      scrollBehavior: appScrollBehavior,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
          ),
          child: Scaffold(
            body: HomeChrome(
              state: _state(brightness),
              cb: callbacks,
              core: FakeNativeCore(),
              child: ListView.builder(
                key: const ValueKey('platform-smoke-scroll'),
                controller: controller,
                itemCount: 80,
                itemBuilder: (_, index) => SizedBox(
                  height: 32,
                  child: Text('缓存键 $index · customer:profile:$index'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

SemanticsNode _actionableNode(WidgetTester tester, String label) {
  final finder = find.bySemanticsLabel(label);
  expect(finder, findsWidgets);
  return List.generate(
    finder.evaluate().length,
    (index) => tester.getSemantics(finder.at(index)),
  ).firstWhere(
    (node) => node.getSemanticsData().hasAction(SemanticsAction.tap),
  );
}

Set<String> _runtimeDependencies(String pubspec) {
  final result = <String>{};
  var inDependencies = false;
  for (final line in pubspec.split('\n')) {
    if (line == 'dependencies:') {
      inDependencies = true;
      continue;
    }
    if (line == 'dev_dependencies:') break;
    if (!inDependencies) continue;
    final match = RegExp(r'^  ([A-Za-z0-9_]+):').firstMatch(line);
    if (match != null) result.add(match.group(1)!);
  }
  return result;
}

void main() {
  setUpAll(loadGoldenFonts);
  setUp(() => appLang.value = AppLang.zh);
  tearDown(() => appLang.value = AppLang.en);

  for (final brightness in Brightness.values) {
    testWidgets(
      'macOS shell supports CJK accessibility at 200% in ${brightness.name}',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final controller = ScrollController();
        final selections = <EntityKind>[];
        addTearDown(controller.dispose);

        await _pumpShell(
          tester,
          brightness: brightness,
          controller: controller,
          onEntityKind: selections.add,
        );

        final detailContext = tester.element(
          find.byKey(const ValueKey('platform-smoke-scroll')),
        );
        final theme = Theme.of(detailContext);
        expect(MediaQuery.textScalerOf(detailContext).scale(10), 20);
        expect(theme.textTheme.bodyMedium?.fontFamily, kGoldenUiFont);
        expect(
          theme.textTheme.bodyMedium?.fontFamilyFallback,
          containsAll(Ts.sansFallback),
        );
        expect(Ts.sansFallback, contains('PingFang SC'));
        expect(Ts.monoFallback, contains('PingFang SC'));

        expect(find.text('实例'), findsWidgets);
        expect(find.text('浏览器'), findsWidgets);
        expect(find.byTooltip('主题'), findsOneWidget);
        expect(find.byTooltip('语言'), findsOneWidget);
        expect(find.byTooltip('本地 DynamoDB'), findsOneWidget);

        final endpointSemantics =
            _actionableNode(tester, tr('nav.endpoints')).getSemanticsData();
        expect(endpointSemantics.label, tr('nav.endpoints'));
        expect(endpointSemantics.flagsCollection.isButton, isTrue);
        expect(endpointSemantics.flagsCollection.isEnabled, Tristate.isTrue);

        final endpointTarget = find.byKey(
          const ValueKey('main-rail-endpoint-focus-target'),
        );
        Focus.of(endpointTarget.evaluate().single).requestFocus();
        await tester.pump();
        final endpointTile = tester.widget<Material>(
          find.byKey(const ValueKey('main-rail-endpoint-tile')),
        );
        final endpointShape = endpointTile.shape! as RoundedRectangleBorder;
        expect(endpointShape.side.color, AppTokens.of(detailContext).focus);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(selections, [EntityKind.endpoint]);

        expect(controller.hasClients, isTrue);
        expect(controller.position.maxScrollExtent, greaterThan(0));
        final pointer = TestPointer(1, PointerDeviceKind.mouse);
        final scrollTarget = tester.getCenter(
          find.byKey(const ValueKey('platform-smoke-scroll')),
        );
        await tester.sendEventToBinding(pointer.hover(scrollTarget));
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
        await tester.pump();
        expect(controller.offset, greaterThan(0));

        expectInsideTestViewport(
          tester,
          find.byKey(const ValueKey('home-topbar')),
        );
        expectInsideTestViewport(
          tester,
          find.byKey(const ValueKey('home-statusbar')),
        );
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
      skip: !Platform.isMacOS,
    );
  }

  testWidgets('production fonts are bundled without a font runtime package',
      (tester) async {
    final inter = await rootBundle.load('assets/fonts/Inter-Variable.ttf');
    final mono =
        await rootBundle.load('assets/fonts/JetBrainsMono-Variable.ttf');
    expect(inter.lengthInBytes, greaterThan(800000));
    expect(mono.lengthInBytes, greaterThan(250000));

    final theme = appTheme(Brightness.light);
    expect(theme.textTheme.bodyMedium?.fontFamily, Ts.uiFamily);
    expect(theme.textTheme.bodyMedium?.fontFamilyFallback, Ts.sansFallback);
    expect(Ts.style(monoFont: true).fontFamily, Ts.monoFamily);
    expect(Ts.style(monoFont: true).fontFamilyFallback, Ts.monoFallback);

    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(_runtimeDependencies(pubspec), {'flutter', 'ffi'});
    expect(pubspec, contains('assets/fonts/Inter-Variable.ttf'));
    expect(pubspec, contains('assets/fonts/JetBrainsMono-Variable.ttf'));
  });
}
