import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/ui_fields.dart';
import 'package:redimos_manager/src/ui_primitives.dart';
import 'package:redimos_manager/src/ui_states.dart';
import 'package:redimos_manager/src/ui_status.dart';
import 'package:redimos_manager/src/ui_surfaces.dart';
import 'package:redimos_manager/src/ui_table.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

Widget _app(Brightness brightness, Widget child) => MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
        'keyboard traversal skips disabled controls without moving bounds in $brightness',
        (tester) async {
      final textFocus = FocusNode(debugLabel: 'contract-text');
      final disabledFocus = FocusNode(debugLabel: 'contract-disabled');
      final selectFocus = FocusNode(debugLabel: 'contract-select');
      final buttonFocus = FocusNode(debugLabel: 'contract-button');
      final iconFocus = FocusNode(debugLabel: 'contract-icon');
      addTearDown(() {
        textFocus.dispose();
        disabledFocus.dispose();
        selectFocus.dispose();
        buttonFocus.dispose();
        iconFocus.dispose();
      });
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(
        _app(
          brightness,
          FocusTraversalGroup(
            policy: WidgetOrderTraversalPolicy(),
            child: SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CodexTextField(
                    key: const ValueKey('focus-text'),
                    focusNode: textFocus,
                    decoration: const InputDecoration(hintText: 'Key pattern'),
                  ),
                  const SizedBox(height: 8),
                  CodexTextField(
                    key: const ValueKey('focus-disabled'),
                    focusNode: disabledFocus,
                    enabled: false,
                    decoration: const InputDecoration(hintText: 'Disabled'),
                  ),
                  const SizedBox(height: 8),
                  CodexSelectField<String>(
                    key: const ValueKey('focus-select'),
                    value: 'one',
                    focusNode: selectFocus,
                    items: const [
                      DropdownMenuItem(value: 'one', child: Text('One')),
                      DropdownMenuItem(value: 'two', child: Text('Two')),
                    ],
                    onChanged: (_) {},
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      CodexButton(
                        key: const ValueKey('focus-button'),
                        focusNode: buttonFocus,
                        semanticLabel: 'Execute command',
                        onPressed: () {},
                        label: const Text('Execute'),
                      ),
                      const SizedBox(width: 8),
                      CodexIconButton(
                        key: const ValueKey('focus-icon'),
                        focusNode: iconFocus,
                        semanticLabel: 'Refresh records',
                        onPressed: () {},
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final keys = <ValueKey<String>>[
        const ValueKey('focus-text'),
        const ValueKey('focus-disabled'),
        const ValueKey('focus-select'),
        const ValueKey('focus-button'),
        const ValueKey('focus-icon'),
      ];
      final initialBounds = <ValueKey<String>, Rect>{
        for (final key in keys) key: tester.getRect(find.byKey(key)),
      };

      textFocus.requestFocus();
      await tester.pump();
      expect(textFocus.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(disabledFocus.hasFocus, isFalse);
      expect(selectFocus.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(buttonFocus.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(iconFocus.hasFocus, isTrue);

      for (final key in keys) {
        expect(tester.getRect(find.byKey(key)), initialBounds[key]);
      }
      expect(find.bySemanticsLabel('Execute command'), findsOneWidget);
      expect(find.bySemanticsLabel('Refresh records'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });

    testWidgets('composed primitive geometry is theme-invariant in $brightness',
        (tester) async {
      await tester.pumpWidget(_geometryGallery(brightness));

      for (final key in _geometryKeys) {
        expect(find.byKey(key), findsOneWidget);
      }
      expect(
        tester.getSize(find.byKey(const ValueKey('gallery-button'))).height,
        Dim.ctlH,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('gallery-field'))).height,
        Dim.ctlH,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('gallery-row'))).height,
        Dim.rowH,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('light and dark galleries retain identical primitive bounds',
      (tester) async {
    await tester.pumpWidget(_geometryGallery(Brightness.dark));
    final darkBounds = <ValueKey<String>, Rect>{
      for (final key in _geometryKeys) key: tester.getRect(find.byKey(key)),
    };

    await tester.pumpWidget(_geometryGallery(Brightness.light));
    await tester.pump();

    for (final key in _geometryKeys) {
      expect(tester.getRect(find.byKey(key)), darkBounds[key], reason: '$key');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('forwards values and callbacks across composed primitives',
      (tester) async {
    final searchController = TextEditingController();
    addTearDown(searchController.dispose);
    final changes = <String>[];
    final submissions = <String>[];
    String? selection;
    var searches = 0;
    var actions = 0;
    var rowTaps = 0;
    var retries = 0;
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _app(
        Brightness.dark,
        SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CodexSearchField(
                key: const ValueKey('callback-search'),
                controller: searchController,
                searchLabel: 'Run exact search',
                onChanged: changes.add,
                onSubmitted: submissions.add,
                onSearch: () => searches++,
              ),
              const SizedBox(height: 8),
              CodexSelectField<String>(
                key: const ValueKey('callback-select'),
                value: 'alpha',
                items: const [
                  DropdownMenuItem(value: 'alpha', child: Text('Alpha')),
                  DropdownMenuItem(value: 'beta', child: Text('Beta')),
                ],
                onChanged: (value) => selection = value,
              ),
              const SizedBox(height: 8),
              CodexButton(
                semanticLabel: 'Apply exact action',
                onPressed: () => actions++,
                label: const Text('Apply'),
              ),
              const SizedBox(height: 8),
              CodexTableRow(
                key: const ValueKey('callback-row'),
                semanticLabel: 'Open user key',
                onTap: () => rowTaps++,
                children: const [
                  CodexTableCell(value: 'user:1001', flex: 1),
                  CodexTableCell(
                    value: '42',
                    kind: CodexTableCellKind.numeric,
                    width: 80,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 150,
                child: CodexStateShell(
                  state: CodexContentState.error,
                  content: const SizedBox(),
                  message: 'Cannot load keys',
                  detail: 'ERR request 23',
                  retryLabel: 'Retry exact request',
                  onRetry: () => retries++,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('callback-search')),
      'session:*',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Run exact search'));

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta').last);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Apply exact action'));
    await tester.tap(find.bySemanticsLabel('Open user key'));
    await tester.tap(find.bySemanticsLabel('Retry exact request'));
    await tester.pump();

    expect(searchController.text, 'session:*');
    expect(changes, ['session:*']);
    expect(submissions, ['session:*']);
    expect(searches, 1);
    expect(selection, 'beta');
    expect(actions, 1);
    expect(rowTaps, 1);
    expect(retries, 1);
    expect(find.text('ERR request 23'), findsOneWidget);
    expect(find.bySemanticsLabel('Cannot load keys'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}

const _geometryKeys = <ValueKey<String>>[
  ValueKey('gallery-surface'),
  ValueKey('gallery-button'),
  ValueKey('gallery-icon'),
  ValueKey('gallery-field'),
  ValueKey('gallery-select'),
  ValueKey('gallery-status'),
  ValueKey('gallery-header'),
  ValueKey('gallery-row'),
  ValueKey('gallery-state'),
];

Widget _geometryGallery(Brightness brightness) => _app(
      brightness,
      SizedBox(
        width: 640,
        height: 430,
        child: CodexSurface(
          key: const ValueKey('gallery-surface'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CodexButton(
                    key: const ValueKey('gallery-button'),
                    onPressed: () {},
                    label: const Text('Run'),
                  ),
                  const SizedBox(width: 8),
                  CodexIconButton(
                    key: const ValueKey('gallery-icon'),
                    semanticLabel: 'Refresh gallery',
                    onPressed: () {},
                    icon: const Icon(Icons.refresh),
                  ),
                  const Spacer(),
                  const CodexStatusBadge(
                    key: ValueKey('gallery-status'),
                    status: CodexStatus.running,
                    label: 'Running',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const CodexTextField(
                key: ValueKey('gallery-field'),
                decoration: InputDecoration(hintText: 'Filter'),
              ),
              const SizedBox(height: 8),
              CodexSelectField<String>(
                key: const ValueKey('gallery-select'),
                value: 'all',
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('All')),
                ],
                onChanged: (_) {},
              ),
              const SizedBox(height: 8),
              const CodexTableHeader(
                key: ValueKey('gallery-header'),
                children: [
                  CodexTableHeaderCell(label: 'Key', flex: 1),
                  CodexTableHeaderCell(label: 'Count', width: 90),
                ],
              ),
              const CodexTableRow(
                key: ValueKey('gallery-row'),
                selected: true,
                children: [
                  CodexTableCell(
                    value: 'orders:2026',
                    kind: CodexTableCellKind.identifier,
                    flex: 1,
                  ),
                  CodexTableCell(
                    value: '1,248',
                    kind: CodexTableCellKind.numeric,
                    width: 90,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Expanded(
                child: CodexStateShell(
                  key: ValueKey('gallery-state'),
                  state: CodexContentState.empty,
                  content: SizedBox(),
                  message: 'No matching records',
                ),
              ),
            ],
          ),
        ),
      ),
    );
