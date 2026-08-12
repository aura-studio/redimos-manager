import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/item_editor.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/ui_fields.dart';
import 'package:redimos_manager/src/ui_primitives.dart';
import 'package:redimos_manager/src/ui_surfaces.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'viewport_assertions.dart';

final _target = TableTarget(
  name: 'orders',
  kind: 'table',
  pk: TableKeyRef(name: 'accountId', type: 'S'),
  sk: TableKeyRef(name: 'orderId', type: 'S'),
);

Map<String, dynamic> _initialItem() => {
      'accountId': {'S': 'acct-1'},
      'orderId': {'S': 'order-7'},
      'age': {'N': '42'},
      'active': {'BOOL': true},
      'metadata': {
        'M': {
          'source': {'S': 'desktop'},
        },
      },
    };

Widget _host({
  required Brightness brightness,
  required bool isNew,
  required Map<String, dynamic> initial,
  required Future<String?> Function(Map<String, dynamic>) onSave,
  required List<bool?> results,
}) =>
    MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const ValueKey('open-editor'),
              onPressed: () async {
                final result = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    fullscreenDialog: true,
                    builder: (_) => ItemEditorPage(
                      table: 'orders',
                      target: _target,
                      isNew: isNew,
                      initial: initial,
                      onSave: onSave,
                    ),
                  ),
                );
                results.add(result);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

Future<void> _openEditor(
  WidgetTester tester, {
  required Brightness brightness,
  required bool isNew,
  required Map<String, dynamic> initial,
  required Future<String?> Function(Map<String, dynamic>) onSave,
  required List<bool?> results,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_host(
    brightness: brightness,
    isNew: isNew,
    initial: initial,
    onSave: onSave,
    results: results,
  ));
  await tester.tap(find.byKey(const ValueKey('open-editor')));
  await tester.pumpAndSettle();
}

Finder _textFieldInside(Key key) => find.descendant(
      of: find.byKey(key),
      matching: find.byType(TextField),
    );

CodexButton _saveButton(WidgetTester tester) => tester.widget<CodexButton>(
      find.byKey(const ValueKey('item-editor-save')),
    );

void main() {
  setUp(() => appLang.value = AppLang.en);

  for (final brightness in Brightness.values) {
    testWidgets(
      'uses shared fixed geometry and locks edit keys in ${brightness.name}',
      (tester) async {
        final results = <bool?>[];
        await _openEditor(
          tester,
          brightness: brightness,
          isNew: false,
          initial: _initialItem(),
          onSave: (_) async => null,
          results: results,
        );

        expect(
          tester
              .getSize(find.byKey(const ValueKey('item-editor-header')))
              .height,
          60,
        );
        expect(
          tester
              .getSize(find.byKey(const ValueKey('item-editor-footer')))
              .height,
          52,
        );
        final header = find.byKey(const ValueKey('item-editor-header'));
        final body = find.byKey(const ValueKey('item-editor-body'));
        final footer = find.byKey(const ValueKey('item-editor-footer'));
        expectInsideTestViewport(tester, header);
        expectInsideTestViewport(tester, body);
        expectInsideTestViewport(tester, footer);
        expectHitTestable(
          tester,
          find.byKey(const ValueKey('item-editor-save')),
          reason: 'the primary editor action must remain reachable',
        );
        expect(find.byType(CodexSectionHeader), findsOneWidget);
        expect(find.byType(CodexTextField), findsNWidgets(9));
        expect(find.byType(CodexSelectField<String>), findsNWidgets(5));
        expect(_saveButton(tester).variant, CodexButtonVariant.primary);

        final pkName = tester.widget<CodexTextField>(
          find.byKey(const ValueKey('item-editor-attr-name-0')),
        );
        final pkValue = tester.widget<CodexTextField>(
          find.byKey(const ValueKey('item-editor-attr-value-0')),
        );
        expect(pkName.enabled, isFalse,
            reason: 'schema key names never change');
        expect(pkValue.enabled, isFalse, reason: 'edit mode locks key values');

        final ageField = tester.widget<CodexTextField>(
          find.byKey(const ValueKey('item-editor-attr-value-2')),
        );
        expect(ageField.style?.fontFamily, Ts.monoFamily);
        expect(ageField.style?.fontFeatures, Ts.tabular);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
      'form save forwards exact DynamoDB JSON and disables while pending',
      (tester) async {
    final results = <bool?>[];
    final saved = <Map<String, dynamic>>[];
    final completion = Completer<String?>();
    await _openEditor(
      tester,
      brightness: Brightness.dark,
      isNew: true,
      initial: _initialItem(),
      onSave: (item) {
        saved.add(item);
        return completion.future;
      },
      results: results,
    );

    await tester.enterText(
      _textFieldInside(const ValueKey('item-editor-attr-value-2')),
      '43.50',
    );
    await tester.tap(find.byKey(const ValueKey('item-editor-save')));
    await tester.pump();

    expect(saved, [
      {
        'accountId': {'S': 'acct-1'},
        'orderId': {'S': 'order-7'},
        'age': {'N': '43.50'},
        'active': {'BOOL': true},
        'metadata': {
          'M': {
            'source': {'S': 'desktop'},
          },
        },
      },
    ]);
    expect(_saveButton(tester).onPressed, isNull);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('item-editor-save')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    completion.complete(null);
    await tester.pumpAndSettle();

    expect(results, [true]);
    expect(find.byKey(const ValueKey('item-editor-header')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('simple JSON view converts nested values to exact attribute maps',
      (tester) async {
    final results = <bool?>[];
    final saved = <Map<String, dynamic>>[];
    await _openEditor(
      tester,
      brightness: Brightness.light,
      isNew: true,
      initial: _initialItem(),
      onSave: (item) async {
        saved.add(item);
        return null;
      },
      results: results,
    );

    await tester.tap(find.text('JSON'));
    await tester.pump();
    final jsonField = tester.widget<CodexTextField>(
      find.byKey(const ValueKey('item-editor-json-field')),
    );
    expect(jsonField.style?.fontFamily, Ts.monoFamily);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.enterText(
      _textFieldInside(const ValueKey('item-editor-json-field')),
      '''{
  "accountId": "acct-2",
  "orderId": "order-8",
  "age": 44,
  "active": false,
  "tags": ["new", "paid"],
  "address": {"city": "Paris"}
}''',
    );
    await tester.tap(find.byKey(const ValueKey('item-editor-save')));
    await tester.pumpAndSettle();

    expect(saved, [
      {
        'accountId': {'S': 'acct-2'},
        'orderId': {'S': 'order-8'},
        'age': {'N': '44'},
        'active': {'BOOL': false},
        'tags': {
          'L': [
            {'S': 'new'},
            {'S': 'paid'},
          ],
        },
        'address': {
          'M': {
            'city': {'S': 'Paris'},
          },
        },
      },
    ]);
    expect(results, [true]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid form values stay in editor and never call save',
      (tester) async {
    final results = <bool?>[];
    var calls = 0;
    await _openEditor(
      tester,
      brightness: Brightness.dark,
      isNew: true,
      initial: _initialItem(),
      onSave: (_) async {
        calls++;
        return null;
      },
      results: results,
    );

    await tester.enterText(
      _textFieldInside(const ValueKey('item-editor-attr-value-2')),
      'not-a-number',
    );
    await tester.tap(find.byKey(const ValueKey('item-editor-save')));
    await tester.pump();

    expect(calls, 0);
    expect(results, isEmpty);
    expect(find.textContaining('not a number'), findsOneWidget);
    expect(find.byKey(const ValueKey('item-editor-header')), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('save callback error is shown and re-enables the action',
      (tester) async {
    final results = <bool?>[];
    final completion = Completer<String?>();
    await _openEditor(
      tester,
      brightness: Brightness.light,
      isNew: true,
      initial: _initialItem(),
      onSave: (_) => completion.future,
      results: results,
    );

    await tester.tap(find.byKey(const ValueKey('item-editor-save')));
    await tester.pump();
    expect(_saveButton(tester).onPressed, isNull);

    completion.complete('conditional write failed');
    await tester.pump();
    await tester.pump();

    expect(results, isEmpty);
    expect(find.text('conditional write failed'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNotNull);
    expect(find.byKey(const ValueKey('item-editor-header')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
