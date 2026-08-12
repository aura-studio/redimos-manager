import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/ui_surfaces.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

Widget _app(Brightness brightness, Widget child) => MaterialApp(
      theme: appTheme(brightness),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('keeps surface geometry fixed in $brightness', (tester) async {
      await tester.pumpWidget(
        _app(
          brightness,
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final variant in CodexSurfaceVariant.values) ...[
                CodexSurface(
                  key: ValueKey(variant.name),
                  variant: variant,
                  child: const SizedBox(width: 100, height: 40),
                ),
                if (variant != CodexSurfaceVariant.values.last)
                  const SizedBox(width: 8),
              ],
            ],
          ),
        ),
      );

      final sizes = [
        for (final variant in CodexSurfaceVariant.values)
          tester.getSize(find.byKey(ValueKey(variant.name))),
      ];
      expect(sizes.toSet(), hasLength(1));
      expect(sizes.first, const Size(124, 64));
      expect(tester.takeException(), isNull);
    });

    testWidgets('maps surface variants to semantic paint in $brightness',
        (tester) async {
      await tester.pumpWidget(
        _app(
          brightness,
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final variant in CodexSurfaceVariant.values)
                CodexSurface(
                  key: ValueKey('paint-${variant.name}'),
                  variant: variant,
                  padding: EdgeInsets.zero,
                  child: const SizedBox(width: 40, height: 40),
                ),
            ],
          ),
        ),
      );

      final tokens = AppTokens.forBrightness(brightness);
      BoxDecoration decoration(CodexSurfaceVariant variant) {
        final surface = tester.widget<DecoratedBox>(
          find
              .descendant(
                of: find.byKey(ValueKey('paint-${variant.name}')),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        return surface.decoration as BoxDecoration;
      }

      final standard = decoration(CodexSurfaceVariant.standard);
      final elevated = decoration(CodexSurfaceVariant.elevated);
      final sunken = decoration(CodexSurfaceVariant.sunken);

      expect(standard.color, tokens.panel);
      expect(standard.boxShadow, isNull);
      expect(elevated.color, tokens.panel);
      expect(elevated.boxShadow, Depth.elev2(brightness));
      expect(sunken.color, tokens.panel2);
      expect(sunken.boxShadow, isNull);

      for (final surface in [standard, elevated, sunken]) {
        expect(surface.borderRadius, BorderRadius.circular(Dim.radiusM));
        final border = surface.border! as Border;
        expect(border.top.color, tokens.border);
        expect(border.top.width, Dim.borderW);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders section header and exact dividers in $brightness',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          brightness,
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                key: ValueKey('header-box'),
                width: 280,
                child: CodexSectionHeader(
                  label: 'CONNECTION',
                  trailing: Text('3 items'),
                ),
              ),
              SizedBox(height: 8),
              SizedBox(
                key: ValueKey('horizontal-box'),
                width: 180,
                child: CodexDivider(),
              ),
              SizedBox(height: 8),
              SizedBox(
                key: ValueKey('vertical-box'),
                height: 60,
                child: CodexDivider(axis: Axis.vertical),
              ),
            ],
          ),
        ),
      );

      expect(tester.getSize(find.byKey(const ValueKey('header-box'))),
          const Size(280, 20));
      expect(find.text('CONNECTION'), findsOneWidget);
      expect(find.text('3 items'), findsOneWidget);
      expect(
        tester
            .getSemantics(find.byType(CodexSectionHeader))
            .flagsCollection
            .isHeader,
        isTrue,
      );
      expect(tester.getSize(find.byKey(const ValueKey('horizontal-box'))),
          const Size(180, Dim.borderW));
      expect(tester.getSize(find.byKey(const ValueKey('vertical-box'))),
          const Size(Dim.borderW, 60));
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }
}
