import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/configure_page.dart';
import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/models.dart';
import 'package:redimos_manager/src/ui_fields.dart';
import 'package:redimos_manager/src/ui_primitives.dart';
import 'package:redimos_manager/src/ui_surfaces.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'viewport_assertions.dart';

RedimosConfig _config() => RedimosConfig(
      id: 'configure-test',
      name: 'source-instance',
      version: 'v2',
      port: 6379,
      table: 'source-table',
      endpoint: 'http://localhost:8000',
      partitionID: 'aws-cn',
      region: 'us-west-2',
      accessKeyId: 'source-access',
      secretKey: 'source-secret',
      sessionToken: 'source-session',
      source: 'fixture-source',
      multiDb: false,
      autoCreateTable: false,
      autoRestart: true,
      runMode: 'native',
      requirepass: 'source-password',
      extraFlags: [FlagKV(key: 'max-clients', value: '128')],
    );

Widget _app(Brightness brightness, Widget child) => MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(body: child),
    );

Future<void> _pumpConfigure(
  WidgetTester tester, {
  required ConfigEditor editor,
  Brightness brightness = Brightness.dark,
  Size size = const Size(1280, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(brightness, editor));
  await tester.pump();
}

Finder _fieldWithText(WidgetTester tester, String text) =>
    find.byWidgetPredicate(
      (widget) => widget is TextField && widget.controller?.text == text,
    );

CodexSelectField<String> _selectWithValue(
  WidgetTester tester,
  String value,
) =>
    tester
        .widgetList<CodexSelectField<String>>(
          find.byType(CodexSelectField<String>),
        )
        .firstWhere(
          (select) => select.value == value,
        );

void main() {
  setUp(() => appLang.value = AppLang.en);

  for (final brightness in Brightness.values) {
    testWidgets(
      'Configure uses shared controls and fixed geometry in ${brightness.name}',
      (tester) async {
        await _pumpConfigure(
          tester,
          brightness: brightness,
          editor: ConfigEditor(
            config: _config(),
            onSave: (_) async {},
            onDelete: (_) async {},
          ),
        );

        expect(find.byType(CodexSurface), findsNWidgets(5));
        expect(find.byType(CodexTextField), findsNWidgets(10));
        expect(find.byType(CodexSelectField<String>), findsNWidgets(3));
        expect(find.byType(CodexButton), findsNWidgets(4));
        expect(
          tester.getSize(find.byKey(const ValueKey('configure-action-bar'))),
          const Size(1280, 52),
        );
        expect(
          tester.getSize(find.byType(AnimatedContainer).first),
          const Size(34, 19),
        );
        expect(find.byKey(const ValueKey('configure-scroll')), findsOneWidget);
        for (var section = 1; section <= 5; section++) {
          expect(
            find.byKey(ValueKey('configure-section-$section')),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'Configure switches support keyboard, semantics, and fixed geometry in ${brightness.name}',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await _pumpConfigure(
          tester,
          brightness: brightness,
          editor: ConfigEditor(
            config: _config(),
            onSave: (_) async {},
            onDelete: (_) async {},
          ),
        );

        final firstField = _fieldWithText(tester, 'source-instance');
        final switchFinder =
            find.byKey(const ValueKey('configure-switch-autorestart'));
        final focusTarget = find.byKey(
          const ValueKey('configure-switch-autorestart-focus-target'),
        );
        final before = tester.getRect(focusTarget);
        expect(before.size, const Size(34, 19));
        expect(
          tester.getSemantics(switchFinder),
          matchesSemantics(
            label: 'AutoRestart',
            isButton: true,
            hasToggledState: true,
            isToggled: true,
            hasTapAction: true,
          ),
        );

        await tester.tap(firstField);
        await tester.pump();
        Focus.of(focusTarget.evaluate().single).requestFocus();
        await tester.pump();

        expect(Focus.of(focusTarget.evaluate().single).hasFocus, isTrue);
        final focused = tester.widget<AnimatedContainer>(focusTarget);
        final focusedDecoration = focused.decoration! as BoxDecoration;
        expect(
          focusedDecoration.border!.top.color,
          AppTokens.forBrightness(brightness).focus,
        );
        expect(tester.getRect(focusTarget), before);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(
          tester.getSemantics(switchFinder),
          matchesSemantics(
            label: 'AutoRestart',
            isButton: true,
            hasToggledState: true,
            isToggled: false,
            hasTapAction: true,
          ),
        );
        expect(Focus.of(focusTarget.evaluate().single).hasFocus, isTrue);
        expect(tester.getRect(focusTarget), before);

        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(
          tester.getSemantics(switchFinder),
          matchesSemantics(
            label: 'AutoRestart',
            isButton: true,
            hasToggledState: true,
            isToggled: true,
            hasTapAction: true,
          ),
        );
        expect(tester.getRect(focusTarget), before);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
    );
  }

  testWidgets('Configure saves the exact persisted model and edits flag rows',
      (tester) async {
    final original = _config();
    final saved = <RedimosConfig>[];
    await _pumpConfigure(
      tester,
      editor: ConfigEditor(
        config: original,
        onSave: (config) async => saved.add(config),
        onDelete: (_) async {},
      ),
    );

    await tester.enterText(
        _fieldWithText(tester, 'source-instance'), '  edited-instance  ');
    await tester.enterText(_fieldWithText(tester, '6379'), '6388');
    await tester.enterText(
        _fieldWithText(tester, 'source-table'), ' edited-table ');
    await tester.enterText(
      _fieldWithText(tester, 'http://localhost:8000'),
      ' http://localhost:9000 ',
    );
    await tester.enterText(_fieldWithText(tester, 'us-west-2'), ' eu-west-1 ');
    await tester.enterText(
        _fieldWithText(tester, 'source-access'), ' edited-access ');
    await tester.enterText(
        _fieldWithText(tester, 'source-secret'), 'edited-secret');
    await tester.enterText(
        _fieldWithText(tester, 'source-session'), 'edited-session');
    await tester.enterText(
        _fieldWithText(tester, 'source-password'), 'edited-password');
    // Flags are v1-style add/remove rows: edit the existing row's value, then
    // add a row and pick its key from the dropdown.
    await tester.enterText(_fieldWithText(tester, '128'), '256');
    await tester.ensureVisible(find.text(tr('home.addFlag')));
    await tester.pump();
    await tester.tap(find.widgetWithText(CodexButton, tr('home.addFlag')));
    await tester.pump();
    tester
        .widget<CodexSelectField<String>>(
            find.byKey(const ValueKey('configure-flag-key-1')))
        .onChanged!('databases');
    await tester.pump();
    await tester.enterText(_fieldWithText(tester, ''), '16');

    _selectWithValue(tester, 'native').onChanged!('docker');
    _selectWithValue(tester, 'v2').onChanged!('v1');
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, tr('home.save')));
    await tester.pump();

    expect(saved, hasLength(1));
    final result = saved.single;
    expect(result.id, original.id);
    expect(result.name, 'edited-instance');
    expect(result.version, 'v1');
    expect(result.port, 6388);
    expect(result.table, 'edited-table');
    expect(result.endpoint, 'http://localhost:9000');
    expect(result.partitionID, original.partitionID);
    expect(result.region, 'eu-west-1');
    expect(result.accessKeyId, 'edited-access');
    expect(result.secretKey, 'edited-secret');
    expect(result.sessionToken, 'edited-session');
    expect(result.source, original.source);
    expect(result.multiDb, original.multiDb);
    expect(result.autoCreateTable, original.autoCreateTable);
    expect(result.autoRestart, original.autoRestart);
    expect(result.runMode, 'docker');
    expect(result.requirepass, 'edited-password');
    expect(
      result.extraFlags.map((flag) => flag.toJson()).toList(),
      [
        {'key': 'max-clients', 'value': '256'},
        {'key': 'databases', 'value': '16'},
      ],
    );
    expect(original.name, 'source-instance',
        reason: 'saving must not mutate the input config object');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Configure public bridges preserve collection semantics',
      (tester) async {
    final key = GlobalKey<ConfigEditorState>();
    final saved = <RedimosConfig>[];
    await _pumpConfigure(
      tester,
      editor: ConfigEditor(
        key: key,
        config: _config(),
        onSave: (config) async => saved.add(config),
        onDelete: (_) async {},
      ),
    );

    await tester.enterText(_fieldWithText(tester, '6379'), 'not-a-port');
    key.currentState!.applyTableName('recommended-table');
    key.currentState!.applyRecommended('v1', true);
    await tester.pump();

    expect(key.currentState!.isDirty, isTrue);
    expect(_fieldWithText(tester, 'recommended-table'), findsOneWidget);
    await key.currentState!.saveNow();

    expect(saved, hasLength(1));
    expect(saved.single.port, 0,
        reason: 'invalid port keeps the existing _collect fallback contract');
    expect(saved.single.table, 'recommended-table');
    expect(saved.single.version, 'v1');
    expect(saved.single.multiDb, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Configure dirty state reverts without moving the action bar',
      (tester) async {
    final key = GlobalKey<ConfigEditorState>();
    await _pumpConfigure(
      tester,
      editor: ConfigEditor(
        key: key,
        config: _config(),
        onSave: (_) async {},
        onDelete: (_) async {},
      ),
    );

    final actionBar = find.byKey(const ValueKey('configure-action-bar'));
    final before = tester.getRect(actionBar);
    expect(find.text(tr('home.unsavedChanges')), findsNothing);

    await tester.enterText(
        _fieldWithText(tester, 'source-instance'), 'draft-name');
    await tester.pump();
    expect(key.currentState!.isDirty, isTrue);
    expect(find.text(tr('home.unsavedChanges')), findsOneWidget);
    expect(tester.getRect(actionBar), before);

    await tester.tap(find.widgetWithText(OutlinedButton, tr('home.revert')));
    await tester.pump();
    expect(key.currentState!.isDirty, isFalse);
    expect(_fieldWithText(tester, 'source-instance'), findsOneWidget);
    expect(find.text(tr('home.unsavedChanges')), findsNothing);
    expect(find.text(tr('home.revertedChanges')), findsOneWidget);
    expect(tester.getRect(actionBar), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Configure delete requires confirmation and forwards original config',
      (tester) async {
    final original = _config();
    final deleted = <RedimosConfig>[];
    await _pumpConfigure(
      tester,
      editor: ConfigEditor(
        config: original,
        onSave: (_) async {},
        onDelete: (config) async => deleted.add(config),
      ),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, tr('home.delete')));
    await tester.pumpAndSettle();
    expect(find.text(tr('home.deleteConfigTitle')), findsOneWidget);
    final firstDialog = find.byType(AlertDialog);
    final cancelAction = find.descendant(
      of: firstDialog,
      matching: find.widgetWithText(OutlinedButton, tr('home.cancel')),
    );
    expectInsideTestViewport(tester, firstDialog);
    expectHitTestable(tester, cancelAction);
    await tester.tap(cancelAction);
    await tester.pumpAndSettle();
    expect(deleted, isEmpty);

    await tester.tap(find.widgetWithText(OutlinedButton, tr('home.delete')));
    await tester.pumpAndSettle();
    final secondDialog = find.byType(AlertDialog);
    final deleteAction = find.descendant(
      of: secondDialog,
      matching: find.widgetWithText(OutlinedButton, tr('home.delete')),
    );
    expectInsideTestViewport(tester, secondDialog);
    expectHitTestable(tester, deleteAction);
    await tester.tap(deleteAction);
    await tester.pumpAndSettle();

    expect(deleted, [same(original)]);
    expect(tester.takeException(), isNull);
  });
}
