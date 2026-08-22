import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/endpoint_browser.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/ui_primitives.dart';
import 'package:redimos_manager/src/ui_states.dart';
import 'package:redimos_manager/src/ui_table.dart';
import 'package:redimos_manager/src/ui_theme.dart';

import 'fake_core.dart';
import 'viewport_assertions.dart';

const _localEndpoint = DdbEndpoint(
  id: 'local-test',
  name: 'Local test endpoint',
  kind: 'local',
  endpoint: 'http://127.0.0.1:8123',
  partitionID: 'aws',
  region: 'us-west-2',
  accessKeyId: 'test-access-key',
  secretKey: 'test-secret-key',
  sessionToken: 'test-session-token',
  source: 'test-fixture',
);

const _awsEndpoint = DdbEndpoint(
  id: 'aws-test',
  name: 'AWS test endpoint',
  kind: 'aws',
  endpoint: 'https://dynamodb.us-east-1.amazonaws.com',
  partitionID: 'aws',
  region: 'us-east-1',
  accessKeyId: 'test-access-key',
  secretKey: 'test-secret-key',
  sessionToken: 'test-session-token',
  source: 'test-fixture',
);

class _TablesCore extends FakeNativeCore {
  _TablesCore({required this.awsMode});

  final bool awsMode;
  final listConfigs = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> epListTables(RedimosConfig config) async {
    listConfigs.add(Map<String, dynamic>.from(config.toJson()));
    return {
      'ok': true,
      'awsMode': awsMode,
      'tables': const [
        {
          'name': 'orders',
          'missing': false,
          'status': 'ACTIVE',
          'kind': 'raw',
          'itemCount': 1,
          'sizeBytes': 128,
          'pkName': 'pk',
          'skName': '',
          'usedBy': <Map<String, dynamic>>[],
        },
      ],
    };
  }
}

class _QueuedListCore extends FakeNativeCore {
  final loads = <Completer<Map<String, dynamic>>>[];

  @override
  Future<Map<String, dynamic>> epListTables(RedimosConfig config) {
    final load = Completer<Map<String, dynamic>>();
    loads.add(load);
    return load.future;
  }
}

Future<void> _pumpTables(
  WidgetTester tester, {
  required Brightness brightness,
  required FakeNativeCore core,
  required DdbEndpoint endpoint,
  void Function(String table)? onOpenTable,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(
        body: EndpointTablesView(
          core: core,
          config: endpoint.toStorageConfig(),
          endpoint: endpoint,
          onOpenTable: onOpenTable,
        ),
      ),
    ),
  );
}

CodexContentState _state(WidgetTester tester) => tester
    .widget<CodexStateShell>(find.byKey(const ValueKey('endpoint-tables-state')))
    .state;

void main() {
  setUp(() => appLang.value = AppLang.en);

  for (final brightness in Brightness.values) {
    testWidgets(
        'lists tables and bridges row taps into the Table tab in ${brightness.name}',
        (tester) async {
      final core = _TablesCore(awsMode: false);
      final opened = <String>[];
      await _pumpTables(
        tester,
        brightness: brightness,
        core: core,
        endpoint: _localEndpoint,
        onOpenTable: opened.add,
      );
      await tester.pump();

      // The list call carries the endpoint's synthesized storage config.
      expect(core.listConfigs, [_localEndpoint.toStorageConfig().toJson()]);
      expect(_state(tester), CodexContentState.content);

      // Row tap bridges into the Table tab via onOpenTable.
      final ordersRow = find
          .ancestor(
            of: find.text('orders').first,
            matching: find.byType(CodexTableRow),
          )
          .first;
      await tester.tap(ordersRow);
      await tester.pump();
      expect(opened, ['orders']);

      // The right-click menu keeps the lifecycle ops; Browse bridges too.
      await tester.tap(ordersRow, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      final tableMenuItems = find.byType(MenuItemButton);
      expect(tableMenuItems, findsWidgets);
      for (var i = 0; i < tableMenuItems.evaluate().length; i++) {
        expectInsideTestViewport(tester, tableMenuItems.at(i));
      }
      final browseAction =
          find.widgetWithText(MenuItemButton, tr('ep.browse'));
      expectHitTestable(tester, browseAction);
      await tester.tap(browseAction);
      await tester.pump();
      expect(opened, ['orders', 'orders']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('exposes bounded loading, empty, and error table-list states',
      (tester) async {
    final core = _QueuedListCore();
    await _pumpTables(
      tester,
      brightness: Brightness.dark,
      core: core,
      endpoint: _localEndpoint,
    );

    expect(_state(tester), CodexContentState.loading);
    core.loads.single.complete({
      'ok': true,
      'awsMode': false,
      'tables': const <Map<String, dynamic>>[],
    });
    await tester.pump();
    expect(_state(tester), CodexContentState.empty);
    expect(find.text('No tables'), findsOneWidget);

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    expect(_state(tester), CodexContentState.loading);
    core.loads.last.complete({'ok': false, 'error': 'fixture list failure'});
    await tester.pump();
    expect(_state(tester), CodexContentState.error);
    expect(find.text('fixture list failure'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps AWS tables read-only', (tester) async {
    final core = _TablesCore(awsMode: true);
    final opened = <String>[];
    await _pumpTables(
      tester,
      brightness: Brightness.dark,
      core: core,
      endpoint: _awsEndpoint,
      onOpenTable: opened.add,
    );
    await tester.pump();

    expect(find.text('AWS · read-only'), findsOneWidget);
    final createTable = tester.widget<CodexButton>(
      find.ancestor(
        of: find.text('＋ Table'),
        matching: find.byType(CodexButton),
      ),
    );
    expect(createTable.onPressed, isNull);

    // Selection still bridges into the Table tab…
    await tester.tap(find.text('orders'));
    await tester.pump();
    expect(opened, ['orders']);

    // …but the right-click menu offers nothing destructive on AWS.
    await tester.tap(find.text('orders'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
