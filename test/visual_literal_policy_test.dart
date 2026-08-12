import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('visual literal policy', () {
    test('business UI does not add color literal debt', () {
      // ui_tokens.dart is the canonical semantic palette owner. ui_theme.dart
      // temporarily owns compatibility accents until callers migrate to tokens.
      const paletteOwners = {
        'lib/src/ui_tokens.dart',
        'lib/src/ui_theme.dart',
      };

      // Business widgets must consume semantic tokens rather than owning raw
      // visual colours. Keep this map exact so new literal debt cannot appear.
      const expectedLegacyDebt = <String, Map<String, int>>{};

      final literalPattern = RegExp(r'Color\s*\(\s*(0x[0-9A-Fa-f]+)\s*\)');
      final actualLegacyDebt = <String, Map<String, int>>{};

      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path.replaceAll('\\', '/');
        if (paletteOwners.contains(path)) continue;

        final counts = <String, int>{};
        for (final match
            in literalPattern.allMatches(entity.readAsStringSync())) {
          final value = match.group(1)!.toUpperCase();
          counts[value] = (counts[value] ?? 0) + 1;
        }
        if (counts.isNotEmpty) actualLegacyDebt[path] = counts;
      }

      expect(
        actualLegacyDebt,
        equals(expectedLegacyDebt),
        reason: 'Move reusable visual colors to AppTokens. If a literal is '
            'genuinely data-semantic, document and explicitly whitelist it.',
      );
    });

    test('legacy Material blue and alternate theme factories stay absent', () {
      final sources = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .map((file) => MapEntry(
                file.path.replaceAll('\\', '/'),
                file.readAsStringSync(),
              ));

      final forbiddenNamedBlue = RegExp(r'Colors\s*\.\s*(blue|indigo|cyan)\b');
      final seededScheme = RegExp(r'\bcolorSchemeSeed\s*:');
      final completeTheme = RegExp(r'\bThemeData\s*\(');

      for (final source in sources) {
        expect(source.value, isNot(contains(forbiddenNamedBlue)),
            reason:
                '${source.key} must use a semantic token, not Material blue');
        expect(source.value, isNot(contains(seededScheme)),
            reason: '${source.key} must preserve the tuned semantic palette');
        if (source.key != 'lib/src/ui_theme.dart') {
          expect(source.value, isNot(contains(completeTheme)),
              reason: '${source.key} must delegate complete theme construction '
                  'to appTheme');
        }
      }
    });
  });
}
