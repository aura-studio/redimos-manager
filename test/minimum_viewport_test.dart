import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/browser_page.dart';
import 'package:redimos_manager/src/cmd_console.dart';
import 'package:redimos_manager/src/home_chrome.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'fake_resp_server.dart';
import 'golden_fonts.dart';
import 'screen_fixtures.dart' as fx;
import 'viewport_assertions.dart';

typedef _ScreenPump = Future<void> Function(
  WidgetTester tester, {
  required bool dark,
  Key? shotKey,
  Widget Function(Widget)? chrome,
});

final _secondConfig = RedimosConfig(
  id: 'c2',
  name: 'dev-redis-02',
  port: 6380,
  endpoint: '',
);

const _extraEndpoints = [
  DdbEndpoint(
    id: 'e2',
    name: 'staging-aws',
    kind: 'aws',
    region: 'us-east-1',
  ),
  DdbEndpoint(
    id: 'e3',
    name: 'analytics-cache',
    kind: 'url',
    endpoint: 'redis://10.0.4.21:6380',
  ),
  DdbEndpoint(
    id: 'e4',
    name: 'legacy-cluster',
    kind: 'url',
    endpoint: 'redis://10.0.1.7:6379',
  ),
];

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
  onLang: _ignoreLang,
);

void _ignore() {}
void _ignoreConfig(RedimosConfig _) {}
void _ignoreEntityKind(EntityKind _) {}
void _ignoreInt(int _) {}
void _ignoreLang(AppLang _) {}
void _ignoreNullableString(String? _) {}
void _ignoreString(String _) {}

class _ScreenCase {
  const _ScreenCase({
    required this.name,
    required this.pump,
    required this.kind,
    required this.tabLabels,
    required this.tabIndex,
    required this.anchors,
  });

  final String name;
  final _ScreenPump pump;
  final EntityKind kind;
  final List<String> tabLabels;
  final int tabIndex;
  final List<Finder> Function() anchors;
}

const _instanceTabs = [
  'Browse',
  'Console',
  'Monitor',
  'Logs',
  'Playground',
  'Configure',
];

const _endpointTabs = ['Configure', 'Endpoint', 'Table'];

List<String> _localizedTabs(EntityKind kind) => kind == EntityKind.instance
    ? [
        tr('tab.browser'),
        tr('tab.console'),
        tr('tab.monitor'),
        tr('tab.logs'),
        tr('tab.playground'),
        tr('tab.configure'),
      ]
    : [
        tr('tab.configure'),
        tr('tab.endpoint'),
        tr('tab.table'),
      ];

final _screens = <_ScreenCase>[
  _ScreenCase(
    name: 'instance browse',
    pump: fx.pumpInstBrowse,
    kind: EntityKind.instance,
    tabLabels: _instanceTabs,
    tabIndex: 0,
    anchors: () => [find.byKey(const ValueKey('browser-page-state'))],
  ),
  _ScreenCase(
    name: 'instance console',
    pump: fx.pumpInstConsole,
    kind: EntityKind.instance,
    tabLabels: _instanceTabs,
    tabIndex: 1,
    anchors: () => [
      find.byKey(const ValueKey('cmd-console-toolbar-anchor')),
      find.byKey(const ValueKey('cmd-console-input-anchor')),
    ],
  ),
  _ScreenCase(
    name: 'instance monitor',
    pump: fx.pumpInstMonitor,
    kind: EntityKind.instance,
    tabLabels: _instanceTabs,
    tabIndex: 2,
    anchors: () => [find.byKey(const ValueKey('monitor-scroll-c1'))],
  ),
  _ScreenCase(
    name: 'instance logs',
    pump: fx.pumpInstLogs,
    kind: EntityKind.instance,
    tabLabels: _instanceTabs,
    tabIndex: 3,
    anchors: () => [
      find.byKey(const ValueKey('logs-state-shell')),
      find.byKey(const ValueKey('logs-auto-scroll')),
      find.byKey(const ValueKey('logs-export')),
      find.byKey(const ValueKey('logs-clear')),
    ],
  ),
  _ScreenCase(
    name: 'instance playground',
    pump: fx.pumpInstPlayground,
    kind: EntityKind.instance,
    tabLabels: _instanceTabs,
    tabIndex: 4,
    anchors: () => [
      find.byKey(const ValueKey('playground-toolbar-anchor')),
      find.byKey(const ValueKey('playground-state')),
    ],
  ),
  _ScreenCase(
    name: 'instance configure',
    pump: fx.pumpInstConfig,
    kind: EntityKind.instance,
    tabLabels: _instanceTabs,
    tabIndex: 5,
    anchors: () => [
      find.byKey(const ValueKey('configure-scroll')),
      find.byKey(const ValueKey('configure-action-bar')),
    ],
  ),
  _ScreenCase(
    name: 'endpoint config',
    pump: fx.pumpEpConfig,
    kind: EntityKind.endpoint,
    tabLabels: _endpointTabs,
    tabIndex: 0,
    anchors: () => [find.byKey(const ValueKey('ep-config-scroll'))],
  ),
  _ScreenCase(
    name: 'endpoint tables',
    pump: fx.pumpEpBrowser,
    kind: EntityKind.endpoint,
    tabLabels: _endpointTabs,
    tabIndex: 1,
    anchors: () => [
      find.byKey(const ValueKey('endpoint-tables-header')),
      find.byKey(const ValueKey('endpoint-tables-footer')),
    ],
  ),
];

Widget Function(Widget) _chromeFor(
  _ScreenCase screen,
  Brightness brightness, {
  TextScaler textScaler = TextScaler.noScaling,
}) {
  final instance = screen.kind == EntityKind.instance;
  return (content) => Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: HomeChrome(
            state: ChromeState(
              entityKind: screen.kind,
              configs: [fx.fixtureConfig(), _secondConfig],
              endpoints: const [fx.fixtureEndpoint, ..._extraEndpoints],
              statuses: {'c1': fx.fixtureStatus()},
              selectedConfigId: instance ? 'c1' : null,
              selectedEndpointId: instance ? null : 'e1',
              hoveredCardId: null,
              entityQuery: '',
              tabLabels: appLang.value == AppLang.en
                  ? screen.tabLabels
                  : _localizedTabs(screen.kind),
              tabIndex: screen.tabIndex,
              stopAllSnapshot: const [],
              lang: appLang.value,
            ),
            cb: _callbacks,
            child: content,
          ),
        ),
      );
}

void _expectInside(Rect child, Rect parent, String description) {
  expect(child.left, greaterThanOrEqualTo(parent.left), reason: description);
  expect(child.top, greaterThanOrEqualTo(parent.top), reason: description);
  expect(child.right, lessThanOrEqualTo(parent.right), reason: description);
  expect(child.bottom, lessThanOrEqualTo(parent.bottom), reason: description);
}

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  int attempts = 60,
}) async {
  for (var i = 0; i < attempts; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for minimum viewport fixture');
}

Future<FakeRespServer?> _pumpScreen(
  WidgetTester tester,
  _ScreenCase screen,
  Brightness brightness, {
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  if (screen.name == 'instance browse') {
    final server = FakeRespServer();
    await tester.runAsync(server.start);
    await fx.pumpScreen(
      tester,
      dark: brightness == Brightness.dark,
      chrome: _chromeFor(
        screen,
        brightness,
        textScaler: textScaler,
      ),
      child: BrowserPageView(
        config: fx.fixtureConfigAt(server.port),
        running: true,
        core: fx.fakeCore,
      ),
    );
    await _waitFor(tester, find.text('cache'));
    return server;
  }
  if (screen.name == 'instance console') {
    final server = FakeRespServer();
    await tester.runAsync(server.start);
    await fx.pumpScreen(
      tester,
      dark: brightness == Brightness.dark,
      chrome: _chromeFor(
        screen,
        brightness,
        textScaler: textScaler,
      ),
      child: CmdConsole(
        host: '127.0.0.1',
        port: server.port,
        running: true,
        instanceName: 'prod-redis-01',
      ),
    );
    await _waitFor(tester, find.text('redimos-cli'));
    return server;
  }
  await screen.pump(
    tester,
    dark: brightness == Brightness.dark,
    chrome: _chromeFor(
      screen,
      brightness,
      textScaler: textScaler,
    ),
  );
  return null;
}

void _expectScaledShell(
  WidgetTester tester,
  _ScreenCase screen,
) {
  const detail = Rect.fromLTWH(344, 92, 936, 684);
  final activeTab =
      find.byKey(ValueKey('home-midbar-tab-${screen.tabIndex}-label'));
  final activeTabAction =
      find.byKey(ValueKey('home-midbar-tab-${screen.tabIndex}-action'));
  final context = tester.element(activeTab);
  final theme = Theme.of(context);

  expect(MediaQuery.textScalerOf(context).scale(10), 20);
  expect(theme.textTheme.bodyMedium?.fontFamily, kGoldenUiFont);
  expect(
    theme.textTheme.bodyMedium?.fontFamilyFallback,
    containsAll(Ts.sansFallback),
  );

  final monoStatus = tester.widget<Text>(
    screen.kind == EntityKind.instance
        ? find.byKey(const ValueKey('home-statusbar-host'))
        : find.byKey(const ValueKey('home-statusbar-endpoint-summary')),
  );
  expect(monoStatus.style?.fontFamily, Ts.monoFamily);
  expect(monoStatus.style?.fontFamilyFallback, Ts.monoFallback);

  for (final anchor in screen.anchors()) {
    expect(anchor, findsOneWidget);
    _expectInside(
      tester.getRect(anchor),
      detail,
      '${screen.name} scaled anchor',
    );
  }

  expectHitTestable(tester, activeTabAction);
  expectHitTestable(
    tester,
    find.byKey(const ValueKey('entity-sidebar-new-action')),
  );
  expectHitTestable(tester, find.byKey(const ValueKey('home-language-menu')));
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadGoldenFonts);
  setUp(() => appLang.value = AppLang.en);
  tearDown(() => appLang.value = AppLang.en);

  for (final brightness in Brightness.values) {
    testWidgets(
      'playground samples menu remains reachable in the complete shell in ${brightness.name}',
      (tester) async {
        final screen = _screens.firstWhere(
          (candidate) => candidate.name == 'instance playground',
        );
        await _pumpScreen(tester, screen, brightness);
        await tester.tap(find.byTooltip(tr('pg.samplesMenu')));
        await tester.pumpAndSettle();

        final items = find.byType(PopupMenuItem<int>);
        expect(items, findsWidgets);
        for (var i = 0; i < items.evaluate().length; i++) {
          expectInsideTestViewport(tester, items.at(i));
        }
        expectHitTestable(tester, items.last);
        await tester.tap(items.last);
        await tester.pumpAndSettle();
        expect(find.byType(PopupMenuItem<int>), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    for (final screen in _screens) {
      testWidgets(
        '${screen.name} fits the complete 1280x800 shell in ${brightness.name}',
        (tester) async {
          FakeRespServer? server;
          try {
            server = await _pumpScreen(tester, screen, brightness);
            const detail = Rect.fromLTWH(344, 92, 936, 684);

            for (final anchor in screen.anchors()) {
              expect(anchor, findsOneWidget);
              _expectInside(
                tester.getRect(anchor),
                detail,
                '${screen.name} anchor',
              );
            }
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            if (server != null) await tester.runAsync(server.close);
          }
        },
      );
    }
  }

  for (final brightness in Brightness.values) {
    for (final lang in AppLang.values) {
      for (final screen in _screens) {
        testWidgets(
          '${screen.name} supports 200% text in ${brightness.name}/${lang.name}',
          (tester) async {
            appLang.value = lang;
            FakeRespServer? server;
            try {
              server = await _pumpScreen(
                tester,
                screen,
                brightness,
                textScaler: const TextScaler.linear(2),
              );
              _expectScaledShell(tester, screen);
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              if (server != null) await tester.runAsync(server.close);
            }
          },
        );
      }
    }
  }
}
