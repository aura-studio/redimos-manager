import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

import 'golden_fonts.dart';

Widget _typographyFixture(ThemeData theme) => MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 420,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Redis database operations',
                  key: ValueKey('english-copy'),
                ),
                const Text(
                  '连接状态与数据库配置',
                  key: ValueKey('cjk-copy'),
                ),
                const SizedBox(height: 8),
                Text(
                  'GET customer:profile:00000000000000000000000000000042',
                  key: const ValueKey('command'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ts.style(monoFont: true),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '1,208.40',
                        key: const ValueKey('numeric-value'),
                        style: Ts.style(
                          monoFont: true,
                          tabularNums: true,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '98,765.00',
                        textAlign: TextAlign.end,
                        style: Ts.style(
                          monoFont: true,
                          tabularNums: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'tenant:production:redis:cluster:primary:'
                  'extremely-long-identifier-without-layout-reflow',
                  key: const ValueKey('long-identifier'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ts.style(monoFont: true),
                ),
              ],
            ),
          ),
        ),
      ),
    );

void main() {
  setUpAll(loadGoldenFonts);

  for (final brightness in Brightness.values) {
    testWidgets('renders production typography and fallback in $brightness',
        (tester) async {
      await tester.pumpWidget(_typographyFixture(appTheme(brightness)));
      await tester.pumpAndSettle();

      final context =
          tester.element(find.byKey(const ValueKey('english-copy')));
      final theme = Theme.of(context);
      expect(theme.textTheme.bodyMedium?.fontFamily, Ts.uiFamily);
      expect(
        theme.textTheme.bodyMedium?.fontFamilyFallback,
        containsAll(Ts.sansFallback),
      );
      expect(find.text('连接状态与数据库配置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders injected UI font and mono data in $brightness',
        (tester) async {
      await tester.pumpWidget(
        _typographyFixture(
          appTheme(brightness, fontFamily: kGoldenUiFont),
        ),
      );
      await tester.pumpAndSettle();

      final context =
          tester.element(find.byKey(const ValueKey('english-copy')));
      final theme = Theme.of(context);
      final command =
          tester.widget<Text>(find.byKey(const ValueKey('command')));
      final numeric =
          tester.widget<Text>(find.byKey(const ValueKey('numeric-value')));
      final identifier =
          tester.widget<Text>(find.byKey(const ValueKey('long-identifier')));

      expect(theme.textTheme.bodyMedium?.fontFamily, kGoldenUiFont);
      expect(theme.textTheme.bodyMedium?.fontFamilyFallback, Ts.sansFallback);
      for (final widget in [command, numeric, identifier]) {
        expect(widget.style?.fontFamily, Ts.monoFamily);
        expect(widget.style?.fontFamilyFallback, Ts.monoFallback);
      }
      expect(numeric.style?.fontFeatures, Ts.tabular);
      expect(tester.getSize(find.byKey(const ValueKey('command'))).width,
          lessThanOrEqualTo(388));
      expect(
          tester.getSize(find.byKey(const ValueKey('long-identifier'))).width,
          lessThanOrEqualTo(388));
      expect(tester.takeException(), isNull);
    });
  }
}
