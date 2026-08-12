import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/ui_primitives.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('renders fixed action variants in $brightness', (tester) async {
      final controllers = <String, WidgetStatesController>{
        'idle': WidgetStatesController(),
        'hovered': WidgetStatesController({WidgetState.hovered}),
        'focused': WidgetStatesController({WidgetState.focused}),
        'pressed': WidgetStatesController({WidgetState.pressed}),
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
            body: Wrap(
              children: [
                for (final variant in CodexButtonVariant.values)
                  for (final entry in controllers.entries)
                    SizedBox(
                      width: 112,
                      child: CodexButton(
                        key: ValueKey('${variant.name}-${entry.key}'),
                        variant: variant,
                        statesController: entry.value,
                        onPressed: entry.key == 'disabled' ? null : () {},
                        label: const Text('Action'),
                      ),
                    ),
                for (final entry in controllers.entries)
                  CodexIconButton(
                    key: ValueKey('icon-${entry.key}'),
                    icon: const Icon(Icons.refresh, size: 16),
                    semanticLabel: 'Refresh ${entry.key}',
                    statesController: entry.value,
                    onPressed: entry.key == 'disabled' ? null : () {},
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final variant in CodexButtonVariant.values) {
        final sizes = <Size>[
          for (final state in controllers.keys)
            tester.getSize(
              find.byKey(ValueKey('${variant.name}-$state')),
            ),
        ];
        expect(sizes.toSet(), hasLength(1));
        expect(sizes.first, const Size(112, Dim.ctlH));
      }

      final iconSizes = <Size>[
        for (final state in controllers.keys)
          tester.getSize(find.byKey(ValueKey('icon-$state'))),
      ];
      expect(iconSizes.toSet(), hasLength(1));
      expect(iconSizes.first, const Size.square(Dim.ctlH));
      expect(tester.takeException(), isNull);
    });

    testWidgets('maps action variants to themed controls in $brightness',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(brightness),
          home: Scaffold(
            body: Column(
              children: [
                CodexButton(
                  key: const ValueKey('primary'),
                  variant: CodexButtonVariant.primary,
                  onPressed: () {},
                  label: const Text('Primary'),
                ),
                CodexButton(
                  key: const ValueKey('secondary'),
                  onPressed: () {},
                  label: const Text('Secondary'),
                ),
                CodexButton(
                  key: const ValueKey('ghost'),
                  variant: CodexButtonVariant.ghost,
                  onPressed: () {},
                  label: const Text('Ghost'),
                ),
                CodexButton(
                  key: const ValueKey('danger'),
                  variant: CodexButtonVariant.danger,
                  onPressed: () {},
                  label: const Text('Danger'),
                ),
              ],
            ),
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('primary')),
          matching: find.byType(FilledButton),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('secondary')),
          matching: find.byType(OutlinedButton),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('ghost')),
          matching: find.byType(TextButton),
        ),
        findsOneWidget,
      );

      final danger = tester.widget<OutlinedButton>(
        find.descendant(
          of: find.byKey(const ValueKey('danger')),
          matching: find.byType(OutlinedButton),
        ),
      );
      final tokens = AppTokens.forBrightness(brightness);
      expect(danger.style?.foregroundColor?.resolve({}), tokens.danger);
      expect(
        danger.style?.side?.resolve({WidgetState.focused})?.color,
        tokens.focus,
      );
    });
  }

  testWidgets('forwards callbacks and explicit semantics', (tester) async {
    var presses = 0;
    var longPresses = 0;
    final hovers = <bool>[];
    final focuses = <bool>[];
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: Scaffold(
          body: Row(
            children: [
              CodexButton(
                semanticLabel: 'Run database command',
                onPressed: () => presses++,
                onLongPress: () => longPresses++,
                onHover: hovers.add,
                onFocusChange: focuses.add,
                label: const Text('Run'),
              ),
              CodexIconButton(
                icon: const Icon(Icons.refresh),
                semanticLabel: 'Refresh database',
                onPressed: () => presses++,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Run database command'), findsOneWidget);
    expect(find.bySemanticsLabel('Refresh database'), findsOneWidget);

    await tester.tap(find.text('Run'));
    await tester.longPress(find.text('Run'));
    await tester.tap(find.byType(CodexIconButton));
    await tester.pump();

    expect(presses, 2);
    expect(longPresses, 1);
    expect(hovers, isEmpty);
    expect(focuses, isEmpty);
    semantics.dispose();
  });
}
