// Stage 12.5: three-entity round-trip smoke test.
//
// Drives the shared chrome through Instance → Endpoint → Service and back
// with a harness that mirrors HomePage's selection model (each entity kind
// keeps its own selected ID + detail tab — switching kinds never loses
// either, 12.6), and asserts the shell geometry never shifts between kinds.

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

ServiceInfo _svc(String id, String name, {int port = 8000}) =>
    ServiceInfo.fromJson({
      'config': {'id': id, 'name': name, 'engine': 'java', 'port': port},
      'runtime': {'state': 'stopped', 'ready': false, 'healthy': false},
    });

const _instanceTabs = ['Browse', 'Console', 'Monitor', 'Logs', 'Play', 'Conf'];
const _endpointTabs = ['Overview', 'Browser', 'PartiQL', 'Playground'];
const _serviceTabs = ['Configure', 'Monitor', 'Logs'];
const _connectTabs = ['Configure', 'Browse', 'Console', 'Playground'];

/// Mirrors HomePage's per-kind selection model: three independent
/// (selectedId, tabIndex) slots + the active kind. Nothing here ever clears
/// another kind's slot when the kind switches.
class _ThreeEntityHarness extends StatefulWidget {
  const _ThreeEntityHarness();

  @override
  State<_ThreeEntityHarness> createState() => _ThreeEntityHarnessState();
}

class _ThreeEntityHarnessState extends State<_ThreeEntityHarness> {
  EntityKind kind = EntityKind.instance;
  String? instanceId;
  String? endpointId;
  String? serviceId;
  String? connectId;
  int instanceTab = 0;
  int endpointTab = 0;
  int serviceTab = 0;
  int connectTab = 0;

  List<String> get _labels => switch (kind) {
        EntityKind.instance => _instanceTabs,
        EntityKind.endpoint => _endpointTabs,
        EntityKind.service => _serviceTabs,
        EntityKind.connect => _connectTabs,
      };

  @override
  Widget build(BuildContext context) {
    return HomeChrome(
      state: ChromeState(
        entityKind: kind,
        configs: [_config],
        endpoints: const [_endpoint],
        statuses: const {},
        selectedConfigId: instanceId,
        selectedEndpointId: endpointId,
        services: [_svc('svc-a', 'local-ddb'), _svc('svc-b', 'stage-ddb')],
        selectedServiceId: serviceId,
        hoveredCardId: null,
        entityQuery: '',
        tabLabels: _labels,
        tabIndex: switch (kind) {
          EntityKind.instance => instanceTab,
          EntityKind.endpoint => endpointTab,
          EntityKind.service => serviceTab,
          EntityKind.connect => connectTab,
        },
        stopAllSnapshot: const [],
        lang: AppLang.en,
      ),
      cb: ChromeCallbacks(
        onEntityKind: (k) => setState(() => kind = k),
        onSelectConfig: (c) => setState(() {
          instanceId = c.id;
          kind = EntityKind.instance;
        }),
        onSelectEndpoint: (id) => setState(() {
          endpointId = id;
          kind = EntityKind.endpoint;
        }),
        onSelectService: (id) => setState(() {
          serviceId = id;
          kind = EntityKind.service;
        }),
        onHoverCard: (_) {},
        onQueryChanged: (_) {},
        onNewConfig: () {},
        onNewService: () {},
        onMidTab: (i) => setState(() {
          switch (kind) {
            case EntityKind.instance:
              instanceTab = i;
            case EntityKind.endpoint:
              endpointTab = i;
            case EntityKind.service:
              serviceTab = i;
            case EntityKind.connect:
              connectTab = i;
          }
        }),
        onStartStop: (_) {},
        onServiceStartStop: (_) {},
        onStopAll: () {},
        onRestoreAll: () {},
        onLang: (_) {},
      ),
      child: const SizedBox.expand(),
    );
  }
}

Future<void> _pumpHarness(WidgetTester tester) async {
  await loadGoldenFonts();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.dark, fontFamily: kGoldenUiFont),
      themeAnimationDuration: Duration.zero,
      home: const Scaffold(body: _ThreeEntityHarness()),
    ),
  );
}

List<Rect> _shellGeometry(WidgetTester tester) => [
      tester.getRect(find.byKey(const ValueKey('entity-sidebar'))),
      tester.getRect(find.byKey(const ValueKey('home-topbar'))),
      tester.getRect(find.byKey(const ValueKey('home-midbar'))),
      tester.getRect(find.byKey(const ValueKey('main-rail'))),
    ];

Finder _activeTabLabel(String label) => find.descendant(
      of: find.byKey(const ValueKey('home-midbar-tab-row')),
      matching: find.text(label),
    );

void main() {
  setUp(() {
    appLang.value = AppLang.en;
  });

  tearDown(() {
    appLang.value = AppLang.en;
  });

  testWidgets('each entity kind keeps its own selection and tab on round-trip',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await _pumpHarness(tester);
    final harness =
        tester.state<_ThreeEntityHarnessState>(find.byType(_ThreeEntityHarness));
    List<Rect>? shell;

    // --- Instance: select the config, move to tab 2 ---
    await tester.tap(
      find.byKey(const ValueKey('entity-card-instance-1-action')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('home-midbar-tab-2-action')));
    await tester.pump();
    shell ??= _shellGeometry(tester);
    expect(_shellGeometry(tester), shell);

    // --- Endpoint: select, tab 1 ---
    await tester.tap(find.byKey(const ValueKey('main-rail-endpoint-action')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('entity-card-endpoint-1-action')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('home-midbar-tab-1-action')));
    await tester.pump();
    expect(_shellGeometry(tester), shell);

    // --- Service: select the second card, tab 2 ---
    await tester.tap(find.byKey(const ValueKey('main-rail-service-action')));
    await tester.pump();
    expect(find.text('local-ddb'), findsOneWidget);
    expect(find.text('stage-ddb'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('entity-card-svc-b-action')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('home-midbar-tab-2-action')));
    await tester.pump();
    expect(harness.serviceId, 'svc-b');
    expect(harness.serviceTab, 2);
    expect(
      _decorationColor(tester, 'svc-b'),
      AppTokens.forBrightness(Brightness.dark).selection,
    );
    expect(_shellGeometry(tester), shell);

    // --- Round-trip back through endpoint to instance ---
    await tester.tap(find.byKey(const ValueKey('main-rail-instance-action')));
    await tester.pump();
    expect(harness.instanceId, 'instance-1'); // never lost
    expect(harness.instanceTab, 2); // never reset
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('entity-card-instance-1-surface')),
        matching: find.text('local-cache'),
      ),
      findsOneWidget,
    );
    expect(_activeTabLabel(_instanceTabs[2]), findsOneWidget);
    expect(_shellGeometry(tester), shell);

    await tester.tap(find.byKey(const ValueKey('main-rail-endpoint-action')));
    await tester.pump();
    expect(harness.endpointId, 'endpoint-1');
    expect(harness.endpointTab, 1);
    expect(_activeTabLabel(_endpointTabs[1]), findsOneWidget);
    expect(_shellGeometry(tester), shell);

    await tester.tap(find.byKey(const ValueKey('main-rail-service-action')));
    await tester.pump();
    expect(harness.serviceId, 'svc-b'); // selection survived the round-trip
    expect(harness.serviceTab, 2);
    expect(_activeTabLabel(_serviceTabs[2]), findsOneWidget);
    expect(_shellGeometry(tester), shell);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching kinds repaints cards without moving the shell',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await _pumpHarness(tester);
    final shell = _shellGeometry(tester);

    for (final kind in EntityKind.values) {
      await tester.tap(
        find.byKey(ValueKey('main-rail-${kind.name}-action')),
      );
      await tester.pump();
      expect(_shellGeometry(tester), shell, reason: 'kind ${kind.name}');
      // Exactly the active kind's indicator is painted.
      expect(
        find.byKey(ValueKey('main-rail-${kind.name}-indicator')),
        findsOneWidget,
      );
    }
    expect(tester.takeException(), isNull);
  });
}

Color _decorationColor(WidgetTester tester, String id) {
  final decoration = tester
      .widget<Container>(find.byKey(ValueKey('entity-card-$id-surface')))
      .decoration!;
  return (decoration as BoxDecoration).color!;
}
