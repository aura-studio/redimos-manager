import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/endpoint_browser.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/item_editor.dart';
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

class _EndpointBrowserCore extends FakeNativeCore {
  _EndpointBrowserCore({
    required this.awsMode,
    this.pageError,
    this.emptyPage = false,
  });

  final bool awsMode;
  final String? pageError;
  final bool emptyPage;
  final listConfigs = <Map<String, dynamic>>[];
  final metaConfigs = <Map<String, dynamic>>[];
  final pageRequests = <Map<String, dynamic>>[];
  int getItemCalls = 0;
  int putItemCalls = 0;
  int deleteItemCalls = 0;

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

  @override
  TableMeta tableMeta(RedimosConfig config) {
    metaConfigs.add(Map<String, dynamic>.from(config.toJson()));
    return TableMeta(
      ok: true,
      table: config.table,
      targets: [
        TableTarget(
          name: config.table,
          kind: 'table',
          pk: TableKeyRef(name: 'pk', type: 'S'),
        ),
      ],
    );
  }

  @override
  TablePage tablePage(Map<String, dynamic> request) {
    pageRequests.add({
      ...request,
      'config': Map<String, dynamic>.from(
        request['config'] as Map<String, dynamic>,
      ),
    });
    if (pageError case final error?) {
      return TablePage(ok: false, error: error);
    }
    if (emptyPage) {
      return TablePage(ok: true, cols: const ['pk']);
    }
    return TablePage(
      ok: true,
      cols: const ['pk', 'status'],
      rows: [
        TableItem(
          cells: {
            'pk': AttrCell(type: 'S', repr: 'order#1'),
            'status': AttrCell(type: 'S', repr: 'ready'),
          },
          ddbJson: '{"pk":{"S":"order#1"},"status":{"S":"ready"}}',
        ),
      ],
      returned: 1,
      scanned: 1,
      timeMs: 3,
    );
  }

  @override
  Map<String, dynamic> tableGetItem(
    RedimosConfig config,
    Map<String, dynamic> key,
  ) {
    getItemCalls++;
    throw StateError('AWS read-only flow must not fetch an editable item');
  }

  @override
  Map<String, dynamic> tablePutItem(
    RedimosConfig config,
    Map<String, dynamic> item,
  ) {
    putItemCalls++;
    throw StateError('Endpoint Browser test forbids item writes');
  }

  @override
  Map<String, dynamic> tableDeleteItem(
    RedimosConfig config,
    Map<String, dynamic> key,
  ) {
    deleteItemCalls++;
    throw StateError('Endpoint Browser test forbids item deletes');
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

Future<void> _pumpBrowser(
  WidgetTester tester, {
  required Brightness brightness,
  required FakeNativeCore core,
  required DdbEndpoint endpoint,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(
        body: EndpointBrowserView(
          core: core,
          config: endpoint.toStorageConfig(),
          endpoint: endpoint,
        ),
      ),
    ),
  );
}

CodexContentState _state(WidgetTester tester, String key) =>
    tester.widget<CodexStateShell>(find.byKey(ValueKey(key))).state;

Future<void> _selectOrdersAndLoad(WidgetTester tester) async {
  await tester.pump();
  await tester.tap(find.text('orders').first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  setUp(() => appLang.value = AppLang.en);

  for (final brightness in Brightness.values) {
    testWidgets(
      'selects a local table with exact read parameters in ${brightness.name}',
      (tester) async {
        final core = _EndpointBrowserCore(awsMode: false);
        await _pumpBrowser(
          tester,
          brightness: brightness,
          core: core,
          endpoint: _localEndpoint,
        );
        await tester.pump();
        final ordersRow = find
            .ancestor(
              of: find.text('orders').first,
              matching: find.byType(CodexTableRow),
            )
            .first;
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
        for (var i = 0; i < 10 && core.pageRequests.isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }

        final storageConfig = _localEndpoint.toStorageConfig();
        final selectedConfig = storageConfig.copy()..table = 'orders';
        expect(core.listConfigs, [storageConfig.toJson()]);
        expect(core.metaConfigs, [selectedConfig.toJson()]);
        expect(core.pageRequests, hasLength(1));
        expect(core.pageRequests.single, {
          'config': selectedConfig.toJson(),
          'op': 'scan',
          'index': '',
          'projection': 'all',
          'projectAttrs': const <String>[],
          'pkValue': '',
          'skCond': null,
          'scanForward': true,
          'filters': const <Map<String, dynamic>>[],
          'limit': 50,
          'startKey': null,
        });
        expect(_state(tester, 'endpoint-browser-table-state'),
            CodexContentState.content);
        expect(_state(tester, 'table-page-state'), CodexContentState.content);
        expect(find.text('order#1'), findsOneWidget);
        expect(find.text('ready'), findsOneWidget);
        expect(find.text('Actions'), findsOneWidget);
        expect(find.text('Create item'), findsOneWidget);

        await tester
            .tap(find.widgetWithText(OutlinedButton, tr('tbl.actions')));
        await tester.pumpAndSettle();
        final actionMenuItems = find.byType(MenuItemButton);
        expect(actionMenuItems, findsNWidgets(4));
        for (var i = 0; i < actionMenuItems.evaluate().length; i++) {
          expectInsideTestViewport(tester, actionMenuItems.at(i));
        }
        expectHitTestable(
          tester,
          find.widgetWithText(MenuItemButton, tr('tbl.exportToCsv')),
        );
        await tester
            .tap(find.widgetWithText(OutlinedButton, tr('tbl.actions')));
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(MenuItemButton, tr('tbl.exportToCsv')),
          findsNothing,
        );

        final state = tester.state<EndpointBrowserViewState>(
          find.byType(EndpointBrowserView),
        );
        expect(state.createItem(), isTrue);
        await tester.pumpAndSettle();
        expect(find.byType(ItemEditorPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('exposes bounded loading, empty, and error table-list states',
      (tester) async {
    final core = _QueuedListCore();
    await _pumpBrowser(
      tester,
      brightness: Brightness.dark,
      core: core,
      endpoint: _localEndpoint,
    );

    expect(_state(tester, 'endpoint-browser-table-state'),
        CodexContentState.loading);
    core.loads.single.complete({
      'ok': true,
      'awsMode': false,
      'tables': const <Map<String, dynamic>>[],
    });
    await tester.pump();
    expect(_state(tester, 'endpoint-browser-table-state'),
        CodexContentState.empty);
    expect(find.text('No tables'), findsOneWidget);

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    expect(_state(tester, 'endpoint-browser-table-state'),
        CodexContentState.loading);
    core.loads.last.complete({'ok': false, 'error': 'fixture list failure'});
    await tester.pump();
    expect(_state(tester, 'endpoint-browser-table-state'),
        CodexContentState.error);
    expect(find.text('fixture list failure'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'renders empty and failed item scans inside the selected explorer',
      (tester) async {
    final emptyCore = _EndpointBrowserCore(awsMode: false, emptyPage: true);
    await _pumpBrowser(
      tester,
      brightness: Brightness.light,
      core: emptyCore,
      endpoint: _localEndpoint,
    );
    await _selectOrdersAndLoad(tester);
    expect(find.text('No items'), findsOneWidget);
    expect(emptyCore.pageRequests, hasLength(1));

    await tester.pumpWidget(const SizedBox.shrink());
    final errorCore = _EndpointBrowserCore(
      awsMode: false,
      pageError: 'fixture scan failure',
    );
    await _pumpBrowser(
      tester,
      brightness: Brightness.light,
      core: errorCore,
      endpoint: _localEndpoint,
    );
    await _selectOrdersAndLoad(tester);
    expect(find.text('fixture scan failure'), findsOneWidget);
    expect(errorCore.pageRequests, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps AWS tables read-only through selection and item viewing',
      (tester) async {
    final core = _EndpointBrowserCore(awsMode: true);
    await _pumpBrowser(
      tester,
      brightness: Brightness.dark,
      core: core,
      endpoint: _awsEndpoint,
    );
    await _selectOrdersAndLoad(tester);

    expect(find.text('AWS · read-only'), findsWidgets);
    expect(find.text('Actions'), findsNothing);
    expect(find.text('Create item'), findsNothing);
    final createTable = tester.widget<CodexButton>(
      find.ancestor(
        of: find.text('＋ Table'),
        matching: find.byType(CodexButton),
      ),
    );
    expect(createTable.onPressed, isNull);

    await tester.tap(find.text('order#1'));
    await tester.pumpAndSettle();
    expect(find.text('Item (DynamoDB JSON)'), findsOneWidget);
    expect(find.byType(ItemEditorPage), findsNothing);
    expect(core.getItemCalls, 0);
    expect(core.putItemCalls, 0);
    expect(core.deleteItemCalls, 0);
    expect(tester.takeException(), isNull);
  });
}
