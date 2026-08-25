import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/browser_page.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/partiql_page.dart';
import 'package:redimos_manager/src/table_page.dart';
import 'package:redimos_manager/src/ui_theme.dart';

import 'fake_core.dart';
import 'fake_resp_server.dart';
import 'screen_fixtures.dart' as fx;
import 'viewport_assertions.dart';

class _IconActionCore extends FakeNativeCore {
  final tableRequests = <Map<String, dynamic>>[];
  final partiqlRequests = <Map<String, dynamic>>[];

  @override
  TableMeta tableMeta(RedimosConfig config) => TableMeta(
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

  @override
  TablePage tablePage(Map<String, dynamic> request) {
    tableRequests.add(request);
    final firstPage = request['startKey'] == null;
    return TablePage(
      ok: true,
      cols: const ['pk'],
      rows: [
        TableItem(
          cells: {
            'pk': AttrCell(type: 'S', repr: firstPage ? 'first' : 'second'),
          },
          ddbJson: '{}',
        ),
      ],
      returned: 1,
      scanned: 1,
      timeMs: 1,
      lastKey: firstPage
          ? {
              'pk': {'S': 'cursor'}
            }
          : null,
    );
  }

  @override
  PartiqlResult partiql(Map<String, dynamic> request) {
    partiqlRequests.add(request);
    final firstPage = request['nextToken'] == '';
    return PartiqlResult(
      ok: true,
      cols: const ['pk'],
      rows: [
        TableItem(
          cells: {
            'pk': AttrCell(
              type: 'S',
              repr: firstPage ? 'partiql-first' : 'partiql-second',
            ),
          },
          ddbJson: '{}',
        ),
      ],
      returned: 1,
      timeMs: 1,
      nextToken: firstPage ? 'next-token' : null,
    );
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required Brightness brightness,
  required Widget child,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(body: child),
    ),
  );
}

Future<void> _settleDeferredPage(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
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
  fail('Timed out waiting for icon action fixture');
}

void _expectEnabledButtonSemantics(WidgetTester tester, String label) {
  final finder = find.bySemanticsLabel(label);
  expect(finder, findsWidgets);
  final actionable = <SemanticsNode>[];
  for (var i = 0; i < finder.evaluate().length; i++) {
    final node = tester.getSemantics(finder.at(i));
    if (node.getSemanticsData().hasAction(SemanticsAction.tap)) {
      actionable.add(node);
    }
  }
  expect(
    actionable,
    isNotEmpty,
    reason: '$label must expose an actionable semantics node',
  );
  for (final node in actionable) {
    final data = node.getSemanticsData();
    expect(data.label, label);
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isEnabled, Tristate.isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
  }
}

void _expectEnabledSelectableButtonSemantics(
  WidgetTester tester,
  String label, {
  required bool selected,
}) {
  _expectEnabledButtonSemantics(tester, label);
  final finder = find.bySemanticsLabel(label);
  final node = List.generate(
    finder.evaluate().length,
    (i) => tester.getSemantics(finder.at(i)),
  ).singleWhere(
    (candidate) => candidate.getSemanticsData().hasAction(SemanticsAction.tap),
  );
  final data = node.getSemanticsData();
  expect(data.flagsCollection.isSelected, isNot(Tristate.none));
  expect(
    data.flagsCollection.isSelected,
    selected ? Tristate.isTrue : Tristate.isFalse,
  );
}

void main() {
  setUp(() => appLang.value = AppLang.en);

  for (final brightness in Brightness.values) {
    testWidgets(
      'Table pagination exposes localized icon actions in ${brightness.name}',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final core = _IconActionCore();
        await _pump(
          tester,
          brightness: brightness,
          child: TablePageView(core: core, config: fx.fixtureConfig()),
        );
        await _settleDeferredPage(tester);
        await tester.ensureVisible(find.text('Previous page'));
        await tester.pump();

        expect(find.text('Previous page'), findsOneWidget);
        expect(find.text('Next page'), findsOneWidget);
        _expectEnabledButtonSemantics(tester, 'Next page');
        expect(
          tester.getSemantics(find.bySemanticsLabel('Previous page')),
          matchesSemantics(
            label: 'Previous page',
            isButton: true,
            hasEnabledState: true,
            isEnabled: false,
          ),
        );

        await tester.tap(find.bySemanticsLabel('Next page'));
        await _settleDeferredPage(tester);
        expect(core.tableRequests, hasLength(2));
        expect(core.tableRequests.last['startKey'], {
          'pk': {'S': 'cursor'}
        });
        _expectEnabledButtonSemantics(tester, 'Previous page');
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
    );

    testWidgets(
      'PartiQL clear and pagination expose icon actions in ${brightness.name}',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final core = _IconActionCore();
        await _pump(
          tester,
          brightness: brightness,
          child: PartiqlPageView(core: core, config: fx.fixtureConfig()),
        );

        final editor = find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.hintText?.contains('SELECT * FROM') == true,
        );
        await tester.tap(find.byTooltip(tr('pq.statementTemplates')));
        await tester.pumpAndSettle();
        final templateItems = find.byType(PopupMenuItem<String>);
        expect(templateItems, findsWidgets);
        for (var i = 0; i < templateItems.evaluate().length; i++) {
          expectInsideTestViewport(tester, templateItems.at(i));
        }
        expectHitTestable(tester, templateItems.last);
        await tester.tap(templateItems.last);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(editor).controller!.text, isNotEmpty);

        await tester.enterText(editor, 'SELECT * FROM "redimos-prod"');
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, tr('pq.run')));
        await _settleDeferredPage(tester);

        expect(find.byTooltip('Previous page'), findsOneWidget);
        expect(find.byTooltip('Next page'), findsOneWidget);
        _expectEnabledButtonSemantics(tester, 'Next page');

        await tester.tap(find.byTooltip('Next page'));
        await tester.pump();
        Tooltip.dismissAllToolTips();
        await _settleDeferredPage(tester);
        expect(core.partiqlRequests, hasLength(2));
        expect(core.partiqlRequests.last['nextToken'], 'next-token');
        _expectEnabledButtonSemantics(tester, 'Previous page');

        final filter = find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.hintText == tr('pq.findItems'),
        );
        await tester.enterText(filter, 'partiql');
        await tester.pump();
        expect(find.byTooltip(tr('pq.clear')), findsOneWidget);
        _expectEnabledButtonSemantics(tester, tr('pq.clear'));
        await tester.tap(find.byTooltip(tr('pq.clear')));
        await tester.pump();
        expect(tester.widget<TextField>(filter).controller!.text, isEmpty);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
    );

    testWidgets(
      'Browser custom icon actions expose one actionable node in ${brightness.name}',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final server = FakeRespServer();
        await tester.runAsync(server.start);
        await _pump(
          tester,
          brightness: brightness,
          child: BrowserPageView(
            config: fx.fixtureConfigAt(server.port),
            running: true,
            core: FakeNativeCore(),
          ),
        );
        await _waitFor(tester, find.text('cache'));

        expect(find.byTooltip(tr('br.treeView')), findsOneWidget);
        expect(find.byTooltip(tr('br.flatView')), findsOneWidget);
        expect(
          tester.getSemantics(find.bySemanticsLabel(tr('br.treeView'))),
          matchesSemantics(
            label: tr('br.treeView'),
            isButton: true,
            hasSelectedState: true,
            isSelected: true,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
        expect(
          tester.getSemantics(find.bySemanticsLabel(tr('br.flatView'))),
          matchesSemantics(
            label: tr('br.flatView'),
            isButton: true,
            hasSelectedState: true,
            isSelected: false,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
        _expectEnabledSelectableButtonSemantics(
          tester,
          tr('br.selectMultiple'),
          selected: false,
        );
        _expectEnabledButtonSemantics(tester, tr('br.refresh'));

        final search = find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.hintText == 'Glob pattern, e.g. user:*',
        );
        await tester.enterText(search, 'user:*');
        await tester.runAsync(() async {
          await tester.testTextInput.receiveAction(TextInputAction.search);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pump();
        await _waitFor(tester, find.text('user:1001'));
        await tester.tap(find.text('user:1001'));
        await _waitFor(tester, find.text('Tony Chen'));
        final closeLabel = '${tr('br.close')} user:1001';
        expect(find.byTooltip(closeLabel), findsOneWidget);
        _expectEnabledButtonSemantics(tester, closeLabel);
        _expectEnabledButtonSemantics(tester, tr('br.pickKey'));
        _expectEnabledButtonSemantics(tester, tr('br.edit'));
        _expectEnabledButtonSemantics(tester, tr('br.copyValue'));
        _expectEnabledButtonSemantics(tester, tr('br.delete'));

        await tester.tap(find.byTooltip(closeLabel));
        await tester.pump();
        expect(find.byTooltip(closeLabel), findsNothing);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(server.close);
        semantics.dispose();
      },
    );
  }
}
