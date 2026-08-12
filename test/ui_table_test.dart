import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/ui_table.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('keeps header and row geometry stable in $brightness',
        (tester) async {
      final controllers = <String, WidgetStatesController>{
        'idle': WidgetStatesController(),
        'hovered': WidgetStatesController({WidgetState.hovered}),
        'selected': WidgetStatesController({WidgetState.selected}),
        'disabled': WidgetStatesController({WidgetState.disabled}),
      };
      addTearDown(() {
        for (final controller in controllers.values) {
          controller.dispose();
        }
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(brightness),
          home: Scaffold(
            body: Column(
              children: [
                const SizedBox(
                  width: 360,
                  child: CodexTableHeader(
                    key: ValueKey('header'),
                    children: [
                      CodexTableHeaderCell(label: 'name', flex: 1),
                      CodexTableHeaderCell(
                        label: 'count',
                        width: 100,
                        alignment: Alignment.centerRight,
                      ),
                    ],
                  ),
                ),
                for (final entry in controllers.entries)
                  SizedBox(
                    width: 360,
                    child: CodexTableRow(
                      key: ValueKey('row-${entry.key}'),
                      statesController: entry.value,
                      enabled: entry.key != 'disabled',
                      selected: entry.key == 'selected',
                      children: const [
                        CodexTableCell(
                          value: 'orders:2026',
                          kind: CodexTableCellKind.identifier,
                          flex: 1,
                        ),
                        CodexTableCell(
                          value: '12,480',
                          kind: CodexTableCellKind.numeric,
                          width: 100,
                          alignment: Alignment.centerRight,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(const ValueKey('header'))).height,
          Dim.rowH);
      final rowSizes = [
        for (final state in controllers.keys)
          tester.getSize(find.byKey(ValueKey('row-$state'))),
      ];
      expect(rowSizes.toSet(), hasLength(1));
      expect(rowSizes.first, const Size(360, Dim.rowH));

      final tokens = AppTokens.forBrightness(brightness);
      expect(_rowColor(tester, 'idle'), tokens.panel);
      expect(_rowColor(tester, 'hovered'), tokens.hover);
      expect(_rowColor(tester, 'selected'), tokens.selection);
      expect(_rowColor(tester, 'disabled'), tokens.panel);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'keyboard traversal activates rows and skips disabled descendants in $brightness',
        (tester) async {
      final beforeFocus = FocusNode(debugLabel: 'table-before');
      final enabledFocus = FocusNode(debugLabel: 'table-enabled');
      final disabledFocus = FocusNode(debugLabel: 'table-disabled');
      final disabledChildFocus = FocusNode(debugLabel: 'table-disabled-child');
      final afterFocus = FocusNode(debugLabel: 'table-after');
      final enabledStates = WidgetStatesController();
      addTearDown(() {
        beforeFocus.dispose();
        enabledFocus.dispose();
        disabledFocus.dispose();
        disabledChildFocus.dispose();
        afterFocus.dispose();
        enabledStates.dispose();
      });
      var activations = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(brightness),
          home: Scaffold(
            body: FocusTraversalGroup(
              policy: WidgetOrderTraversalPolicy(),
              child: Column(
                children: [
                  TextButton(
                    focusNode: beforeFocus,
                    onPressed: () {},
                    child: const Text('Before'),
                  ),
                  SizedBox(
                    width: 360,
                    child: CodexTableRow(
                      key: const ValueKey('keyboard-row'),
                      focusNode: enabledFocus,
                      statesController: enabledStates,
                      semanticLabel: 'Open keyboard row',
                      onTap: () => activations++,
                      children: const [
                        CodexTableCell(value: 'orders', flex: 1),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 360,
                    child: CodexTableRow(
                      key: const ValueKey('disabled-keyboard-row'),
                      focusNode: disabledFocus,
                      enabled: false,
                      onTap: () {},
                      children: [
                        Expanded(
                          child: TextButton(
                            focusNode: disabledChildFocus,
                            onPressed: () {},
                            child: const Text('Disabled descendant'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    focusNode: afterFocus,
                    onPressed: () {},
                    child: const Text('After'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final row = find.byKey(const ValueKey('keyboard-row'));
      final beforeBounds = tester.getRect(row);
      beforeFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(enabledFocus.hasFocus, isTrue);
      expect(enabledStates.value, contains(WidgetState.focused));
      expect(tester.getRect(row), beforeBounds);
      final focusedDecoration = tester
          .widgetList<DecoratedBox>(
            find.descendant(of: row, matching: find.byType(DecoratedBox)),
          )
          .map((box) => box.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((decoration) => decoration.border != null);
      final focusedBorder = focusedDecoration.border! as Border;
      final tokens = AppTokens.forBrightness(brightness);
      expect(focusedBorder.top.color, tokens.focus);
      expect(focusedBorder.right.color, tokens.focus);
      expect(focusedBorder.bottom.color, tokens.focus);
      expect(focusedBorder.left.color, tokens.focus);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(activations, 2);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(disabledFocus.hasFocus, isFalse);
      expect(disabledChildFocus.hasFocus, isFalse);
      expect(afterFocus.hasFocus, isTrue);
      expect(tester.getRect(row), beforeBounds);
      expect(tester.takeException(), isNull);
    });

    testWidgets('uses semantic cell typography in $brightness', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(brightness),
          home: const Scaffold(
            body: CodexTableRow(
              children: [
                CodexTableCell(
                  value: 'Friendly name',
                  kind: CodexTableCellKind.text,
                  width: 130,
                ),
                CodexTableCell(
                  value: 'user:1001',
                  kind: CodexTableCellKind.identifier,
                  width: 130,
                ),
                CodexTableCell(
                  value: '42.50',
                  kind: CodexTableCellKind.numeric,
                  width: 100,
                ),
              ],
            ),
          ),
        ),
      );

      final text = tester.widget<Text>(find.text('Friendly name'));
      final identifier = tester.widget<Text>(find.text('user:1001'));
      final numeric = tester.widget<Text>(find.text('42.50'));
      expect(text.style?.fontFamily, isNull);
      expect(identifier.style?.fontFamily, Ts.monoFamily);
      expect(identifier.style?.fontFeatures, isNull);
      expect(numeric.style?.fontFamily, Ts.monoFamily);
      expect(numeric.style?.fontFeatures, Ts.tabular);
    });
  }

  testWidgets('real pointer hover changes paint without moving the row',
      (tester) async {
    var taps = 0;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: CodexTableRow(
                key: const ValueKey('hover-row'),
                onTap: () => taps++,
                semanticLabel: 'Open orders row',
                children: const [
                  CodexTableCell(value: 'orders', flex: 1),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final before = tester.getSize(find.byKey(const ValueKey('hover-row')));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(700, 500));
    await mouse
        .moveTo(tester.getCenter(find.byKey(const ValueKey('hover-row'))));
    await tester.pump();

    expect(_rowColor(tester, 'hover-row', rawKey: true), AppTokens.dark.hover);
    expect(tester.getSize(find.byKey(const ValueKey('hover-row'))), before);
    await tester.tap(find.byKey(const ValueKey('hover-row')));
    expect(taps, 1);
    expect(find.bySemanticsLabel('Open orders row'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('selected paint wins over hover and keeps accent indicator',
      (tester) async {
    final states = WidgetStatesController({
      WidgetState.hovered,
      WidgetState.selected,
    });
    addTearDown(states.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: CodexTableRow(
            key: const ValueKey('selected-row'),
            selected: true,
            statesController: states,
            children: const [CodexTableCell(value: 'selected', flex: 1)],
          ),
        ),
      ),
    );

    expect(_rowColor(tester, 'selected-row', rawKey: true),
        AppTokens.light.selection);
    final decorated = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byKey(const ValueKey('selected-row')),
            matching: find.byType(DecoratedBox),
          )
          .last,
    );
    final border = (decorated.decoration as BoxDecoration).border! as Border;
    expect(border.left.width, 2);
    expect(border.left.color, AppTokens.light.accent);
  });

  testWidgets('secondary tap is forwarded without changing row geometry',
      (tester) async {
    var secondaryTaps = 0;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: CodexTableRow(
                key: const ValueKey('secondary-row'),
                semanticLabel: 'Table lifecycle actions',
                onSecondaryTapUp: (_) => secondaryTaps++,
                children: const [
                  CodexTableCell(value: 'orders', flex: 1),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final row = find.byKey(const ValueKey('secondary-row'));
    final before = tester.getSize(row);
    final inkWell = tester.widget<InkWell>(
      find.descendant(of: row, matching: find.byType(InkWell)).first,
    );
    inkWell.onSecondaryTapUp!(TapUpDetails(
      kind: PointerDeviceKind.mouse,
      globalPosition: const Offset(10, 10),
    ));
    await tester.pump();

    expect(secondaryTaps, 1);
    expect(tester.getSize(row), before);
    expect(find.bySemanticsLabel('Table lifecycle actions'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('empty and loading placeholders keep identical bounds',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: const Scaffold(
          body: Row(
            children: [
              Expanded(
                child: CodexTablePlaceholder.empty(
                  key: ValueKey('empty'),
                  message: 'No rows',
                ),
              ),
              Expanded(
                child: CodexTablePlaceholder.loading(
                  key: ValueKey('loading'),
                  message: 'Loading rows',
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(const ValueKey('empty'))),
        tester.getSize(find.byKey(const ValueKey('loading'))));
    expect(tester.getSize(find.byKey(const ValueKey('empty'))).height, 120);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.bySemanticsLabel('No rows'), findsOneWidget);
    expect(find.bySemanticsLabel('Loading rows'), findsOneWidget);
    semantics.dispose();
  });

  for (final brightness in Brightness.values) {
    testWidgets(
        'viewport routes desktop pointer and keyboard scrolling in ${brightness.name}',
        (tester) async {
      final horizontal = ScrollController();
      final vertical = ScrollController();
      final tableFocus = FocusNode(debugLabel: 'table-scroll-focus');
      addTearDown(horizontal.dispose);
      addTearDown(vertical.dispose);
      addTearDown(tableFocus.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(brightness).copyWith(platform: TargetPlatform.macOS),
          scrollBehavior: appScrollBehavior,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                key: const ValueKey('table-viewport-bounds'),
                width: 320,
                height: 90,
                child: CodexTableViewport(
                  horizontalController: horizontal,
                  verticalController: vertical,
                  child: Column(
                    children: [
                      const CodexTableHeader(
                        children: [
                          CodexTableHeaderCell(label: 'key', width: 300),
                          CodexTableHeaderCell(label: 'value', width: 300),
                        ],
                      ),
                      for (var i = 0; i < 6; i++)
                        Focus(
                          focusNode: i == 0 ? tableFocus : null,
                          child: CodexTableRow(
                            children: [
                              CodexTableCell(value: 'key-$i', width: 300),
                              CodexTableCell(value: 'value-$i', width: 300),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(horizontal.hasClients, isTrue);
      expect(vertical.hasClients, isTrue);
      expect(horizontal.position.maxScrollExtent, greaterThan(0));
      expect(vertical.position.maxScrollExtent, greaterThan(0));
      final scrollbars = tester.widgetList<Scrollbar>(find.byType(Scrollbar));
      expect(scrollbars, hasLength(2));
      expect(
        scrollbars.map((bar) => bar.controller).toSet(),
        {horizontal, vertical},
      );

      final position =
          tester.getCenter(find.byKey(const ValueKey('table-viewport-bounds')));
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(position));
      await tester.sendEventToBinding(
        mouse.scroll(const Offset(0, 30)),
      );
      await tester.pump();
      expect(vertical.offset, 30);
      expect(horizontal.offset, 0);

      vertical.jumpTo(0);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendEventToBinding(
        mouse.scroll(const Offset(0, 40)),
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(horizontal.offset, 40);
      expect(vertical.offset, 0);

      horizontal.jumpTo(0);
      final trackpad = TestPointer(2, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(trackpad.hover(position));
      await tester.sendEventToBinding(
        trackpad.scroll(const Offset(45, 0)),
      );
      await tester.pump();
      expect(horizontal.offset, 45);
      expect(vertical.offset, 0);

      horizontal.jumpTo(0);
      await tester.sendEventToBinding(
        trackpad.scroll(const Offset(0, 35)),
      );
      await tester.pump();
      expect(horizontal.offset, 0);
      expect(vertical.offset, 35);

      vertical.jumpTo(0);
      tableFocus.requestFocus();
      await tester.pump();
      expect(tableFocus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(vertical.offset, greaterThan(0));
      expect(horizontal.offset, 0);
      expect(tester.takeException(), isNull);
    });
  }
}

Color _rowColor(
  WidgetTester tester,
  String key, {
  bool rawKey = false,
}) {
  final finder = find.descendant(
    of: find.byKey(ValueKey(rawKey ? key : 'row-$key')),
    matching: find.byType(ColoredBox),
  );
  return tester.widget<ColoredBox>(finder.first).color;
}
