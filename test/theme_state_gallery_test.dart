import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

void _noop() {}

Widget _stateGallery(
  Brightness brightness,
  Map<String, WidgetStatesController> controllers,
) =>
    MaterialApp(
      theme: appTheme(brightness),
      home: DefaultTabController(
        length: 2,
        child: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final state in controllers.keys)
                    SizedBox(
                      width: 112,
                      child: OutlinedButton(
                        key: ValueKey('button-$state'),
                        statesController: controllers[state],
                        onPressed: state == 'disabled' ? null : _noop,
                        child: Text(state),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const SizedBox(
                height: Dim.midBarH,
                child: TabBar(
                  tabs: [Tab(text: 'Data'), Tab(text: 'Details')],
                ),
              ),
              const SizedBox(height: 16),
              Builder(
                builder: (context) {
                  final tokens = Theme.of(context).extension<AppTokens>()!;
                  return Row(
                    children: [
                      for (final status in <(String, Color)>[
                        ('success', tokens.success),
                        ('warning', tokens.warning),
                        ('danger', tokens.danger),
                      ])
                        Container(
                          key: ValueKey('status-${status.$1}'),
                          width: 72,
                          height: 24,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: status.$2,
                            borderRadius: BorderRadius.circular(Dim.radiusS),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('renders every themed control state in $brightness',
        (tester) async {
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

      await tester.pumpWidget(_stateGallery(brightness, controllers));
      await tester.pumpAndSettle();

      final sizes = <Size>[
        for (final state in controllers.keys)
          tester.getSize(find.byKey(ValueKey('button-$state'))),
      ];
      expect(sizes.toSet(), hasLength(1));
      expect(sizes.first.height, Dim.ctlH);

      final tabContext = tester.element(find.byType(TabBar));
      expect(DefaultTabController.of(tabContext).index, 0);
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(DefaultTabController.of(tabContext).index, 1);

      final tokens = AppTokens.forBrightness(brightness);
      for (final status in <(String, Color)>[
        ('success', tokens.success),
        ('warning', tokens.warning),
        ('danger', tokens.danger),
      ]) {
        final container = tester.widget<Container>(
          find.byKey(ValueKey('status-${status.$1}')),
        );
        final decoration = container.decoration! as BoxDecoration;
        expect(decoration.color, status.$2);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
