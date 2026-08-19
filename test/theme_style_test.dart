import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:redimos_manager/src/i18n.dart';
import 'package:redimos_manager/src/theme_prefs.dart';
import 'package:redimos_manager/src/ui_theme.dart';
import 'package:redimos_manager/src/ui_tokens.dart';

Map<String, Color> _scalarFields(AppTokens t) => {
      'bg': t.bg,
      'panel': t.panel,
      'panel2': t.panel2,
      'sidebar': t.sidebar,
      'border': t.border,
      'hairline': t.hairline,
      'text': t.text,
      'text2': t.text2,
      'text3': t.text3,
      'accent': t.accent,
      'onAccent': t.onAccent,
      'hover': t.hover,
      'selection': t.selection,
      'focus': t.focus,
      'danger': t.danger,
      'success': t.success,
      'warning': t.warning,
      'highlight': t.highlight,
      'highlightSoft': t.highlightSoft,
      'railBg': t.railBg,
      'railBgTop': t.railBgTop,
      'railBgBottom': t.railBgBottom,
      'railFg': t.railFg,
      'railFgActive': t.railFgActive,
      'railActiveBg': t.railActiveBg,
      'railGlow': t.railGlow,
      'railIndicatorTop': t.railIndicatorTop,
      'railIndicatorBottom': t.railIndicatorBottom,
    };

// The design-doc palette tables (.kiro/specs/theme-style-selector/design.md).
// These are the single source of truth the implementation must match.
const _expected = <AppStyle, Map<String, int>>{
  AppStyle.midnight: {
    'bg': 0xFF10151D, 'panel': 0xFF161C26, 'panel2': 0xFF1C242F,
    'sidebar': 0xFF131923, 'border': 0xFF2E3A4B, 'hairline': 0xFF242F3E,
    'text': 0xFFE8ECF3, 'text2': 0xFFA9B4C4, 'text3': 0xFF8B97A8,
    'accent': 0xFF4F8FE8, 'onAccent': 0xFFFFFFFF, 'hover': 0xFF1C242F,
    'selection': 0xFF1E3A5C, 'focus': 0xFF3A72C4, 'danger': 0xFFFF6B6B,
    'success': 0xFF4CC27A, 'warning': 0xFFE8C35A,
    'highlight': 0x17FFFFFF, 'highlightSoft': 0x0DFFFFFF,
    'railBg': 0xFF0C1118, 'railBgTop': 0xFF0F141C, 'railBgBottom': 0xFF090D13,
    'railFg': 0xFF8B97A8, 'railFgActive': 0xFF7FB2F0,
    'railActiveBg': 0xFF1C3250, 'railGlow': 0x404F8FE8,
    'railIndicatorTop': 0xFF4F8FE8, 'railIndicatorBottom': 0xFF4F8FE8,
  },
  AppStyle.charcoal: {
    'bg': 0xFF191919, 'panel': 0xFF212121, 'panel2': 0xFF2A2A2A,
    'sidebar': 0xFF1E1E1E, 'border': 0xFF3D3D3D, 'hairline': 0xFF313131,
    'text': 0xFFF2F0EB, 'text2': 0xFFBDBAB2, 'text3': 0xFF9C9890,
    'accent': 0xFFFFB020, 'onAccent': 0xFF241B07, 'hover': 0xFF2A2A2A,
    'selection': 0xFF453517, 'focus': 0xFFD9950F, 'danger': 0xFFFF6B6B,
    'success': 0xFF4CC27A, 'warning': 0xFFE8C35A,
    'highlight': 0x17FFFFFF, 'highlightSoft': 0x0DFFFFFF,
    'railBg': 0xFF141414, 'railBgTop': 0xFF171717, 'railBgBottom': 0xFF101010,
    'railFg': 0xFF9C9890, 'railFgActive': 0xFFFFC655,
    'railActiveBg': 0xFF3A2E16, 'railGlow': 0x40FFB020,
    'railIndicatorTop': 0xFFFFB020, 'railIndicatorBottom': 0xFFFFB020,
  },
  AppStyle.brick: {
    'bg': 0xFFF6EFE3, 'panel': 0xFFFFFAF0, 'panel2': 0xFFF0E6D2,
    'sidebar': 0xFFF3EBDC, 'border': 0xFFC4AE93, 'hairline': 0xFFE3D5BC,
    'text': 0xFF2E2118, 'text2': 0xFF6B5138, 'text3': 0xFF7A6248,
    'accent': 0xFFC0392B, 'onAccent': 0xFFFFF6E8, 'hover': 0xFFF0E6D2,
    'selection': 0xFFF5D7B8, 'focus': 0xFFA32B1F, 'danger': 0xFFAD0017,
    'success': 0xFF137A42, 'warning': 0xFF8A5A00,
    'highlight': 0xD9FFFFFF, 'highlightSoft': 0x8CFFFFFF,
    'railBg': 0xFFEFE5D2, 'railBgTop': 0xFFF4EBD9, 'railBgBottom': 0xFFEADFC8,
    'railFg': 0xFF6B5138, 'railFgActive': 0xFFA32B1F,
    'railActiveBg': 0xFFF2CBAE, 'railGlow': 0x40C0392B,
    'railIndicatorTop': 0xFFC0392B, 'railIndicatorBottom': 0xFFC0392B,
  },
  AppStyle.aubergine: {
    'bg': 0xFF1E1626, 'panel': 0xFF261D30, 'panel2': 0xFF2E2439,
    'sidebar': 0xFF231A2C, 'border': 0xFF443652, 'hairline': 0xFF372B44,
    'text': 0xFFF0EAF5, 'text2': 0xFFB6A9C2, 'text3': 0xFF9A8CA8,
    'accent': 0xFFBB86E0, 'onAccent': 0xFF24132E, 'hover': 0xFF2E2439,
    'selection': 0xFF3E2A52, 'focus': 0xFFA06BD0, 'danger': 0xFFFF7A85,
    'success': 0xFF6FD3A0, 'warning': 0xFFE8C98A,
    'highlight': 0x17FFFFFF, 'highlightSoft': 0x0DFFFFFF,
    'railBg': 0xFF1A1220, 'railBgTop': 0xFF1E1628, 'railBgBottom': 0xFF150E1B,
    'railFg': 0xFF9A8CA8, 'railFgActive': 0xFFD3AEF0,
    'railActiveBg': 0xFF3A2A4C, 'railGlow': 0x40BB86E0,
    'railIndicatorTop': 0xFFBB86E0, 'railIndicatorBottom': 0xFFBB86E0,
  },
  AppStyle.mono: {
    'bg': 0xFFFFFFFF, 'panel': 0xFFFFFFFF, 'panel2': 0xFFF2F2F0,
    'sidebar': 0xFFF7F7F5, 'border': 0xFF3A3A38, 'hairline': 0xFFD8D8D4,
    'text': 0xFF0A0A0A, 'text2': 0xFF3D3D3B, 'text3': 0xFF5A5A57,
    'accent': 0xFF0A0A0A, 'onAccent': 0xFFFFFFFF, 'hover': 0xFFF2F2F0,
    'selection': 0xFFDEDEDA, 'focus': 0xFF0A0A0A, 'danger': 0xFFC0001A,
    'success': 0xFF0A0A0A, 'warning': 0xFF5A5A57,
    'highlight': 0xD9FFFFFF, 'highlightSoft': 0x8CFFFFFF,
    'railBg': 0xFFF0F0EE, 'railBgTop': 0xFFF5F5F3, 'railBgBottom': 0xFFE9E9E6,
    'railFg': 0xFF5A5A57, 'railFgActive': 0xFF0A0A0A,
    'railActiveBg': 0xFFE4E4E0, 'railGlow': 0x400A0A0A,
    'railIndicatorTop': 0xFF0A0A0A, 'railIndicatorBottom': 0xFF0A0A0A,
  },
  AppStyle.sky: {
    'bg': 0xFFF2F6FA, 'panel': 0xFFFFFFFF, 'panel2': 0xFFE8F0F7,
    'sidebar': 0xFFEDF3F9, 'border': 0xFFB9CCDD, 'hairline': 0xFFD7E3EE,
    'text': 0xFF1B2A3A, 'text2': 0xFF46586B, 'text3': 0xFF6A7D92,
    'accent': 0xFF2F7DE1, 'onAccent': 0xFFFFFFFF, 'hover': 0xFFE8F0F7,
    'selection': 0xFFD3E4F6, 'focus': 0xFF1F63B8, 'danger': 0xFFC0283B,
    'success': 0xFF177A46, 'warning': 0xFF96620A,
    'highlight': 0xD9FFFFFF, 'highlightSoft': 0x8CFFFFFF,
    'railBg': 0xFFE7EFF6, 'railBgTop': 0xFFECF3F9, 'railBgBottom': 0xFFE1EAF3,
    'railFg': 0xFF6A7D92, 'railFgActive': 0xFF1F63B8,
    'railActiveBg': 0xFFCBE0F4, 'railGlow': 0x402F7DE1,
    'railIndicatorTop': 0xFF2F7DE1, 'railIndicatorBottom': 0xFF2F7DE1,
  },
  AppStyle.sakura: {
    'bg': 0xFFFBF3F4, 'panel': 0xFFFFFBFB, 'panel2': 0xFFF6E7E9,
    'sidebar': 0xFFF8EDEE, 'border': 0xFFDDBEC3, 'hairline': 0xFFEEDADD,
    'text': 0xFF3A2028, 'text2': 0xFF6E4750, 'text3': 0xFF8F6B74,
    'accent': 0xFFD14D6B, 'onAccent': 0xFFFFF7F8, 'hover': 0xFFF6E7E9,
    'selection': 0xFFF5D3DA, 'focus': 0xFFAE3551, 'danger': 0xFFAD0017,
    'success': 0xFF1A7A4A, 'warning': 0xFF8A5A00,
    'highlight': 0xD9FFFFFF, 'highlightSoft': 0x8CFFFFFF,
    'railBg': 0xFFF4E5E7, 'railBgTop': 0xFFF8EBED, 'railBgBottom': 0xFFF0DEE1,
    'railFg': 0xFF8F6B74, 'railFgActive': 0xFFAE3551,
    'railActiveBg': 0xFFF3CBD4, 'railGlow': 0x40D14D6B,
    'railIndicatorTop': 0xFFD14D6B, 'railIndicatorBottom': 0xFFD14D6B,
  },
  AppStyle.mint: {
    'bg': 0xFFF1F8F4, 'panel': 0xFFFDFFFE, 'panel2': 0xFFE4F1E9,
    'sidebar': 0xFFEBF5EF, 'border': 0xFFB6D4C2, 'hairline': 0xFFD4E7DC,
    'text': 0xFF183128, 'text2': 0xFF3F5A50, 'text3': 0xFF64796F,
    'accent': 0xFF1E9E6A, 'onAccent': 0xFFF2FFF9, 'hover': 0xFFE4F1E9,
    'selection': 0xFFCBE9D9, 'focus': 0xFF137A50, 'danger': 0xFFBF1F38,
    'success': 0xFF137A42, 'warning': 0xFF8A5A00,
    'highlight': 0xD9FFFFFF, 'highlightSoft': 0x8CFFFFFF,
    'railBg': 0xFFE2EFE7, 'railBgTop': 0xFFE9F4ED, 'railBgBottom': 0xFFDBEAE1,
    'railFg': 0xFF64796F, 'railFgActive': 0xFF137A50,
    'railActiveBg': 0xFFC2E4D1, 'railGlow': 0x401E9E6A,
    'railIndicatorTop': 0xFF1E9E6A, 'railIndicatorBottom': 0xFF1E9E6A,
  },
  AppStyle.lilac: {
    'bg': 0xFFF7F4FB, 'panel': 0xFFFDFBFF, 'panel2': 0xFFEDE6F6,
    'sidebar': 0xFFF2EDF9, 'border': 0xFFCDBFDF, 'hairline': 0xFFE2D9EF,
    'text': 0xFF2A2140, 'text2': 0xFF56496E, 'text3': 0xFF7A6E92,
    'accent': 0xFF7A4FD0, 'onAccent': 0xFFFBF8FF, 'hover': 0xFFEDE6F6,
    'selection': 0xFFE0D2F2, 'focus': 0xFF5E34AE, 'danger': 0xFFBC2140,
    'success': 0xFF177A46, 'warning': 0xFF8A5A00,
    'highlight': 0xD9FFFFFF, 'highlightSoft': 0x8CFFFFFF,
    'railBg': 0xFFEBE3F5, 'railBgTop': 0xFFF0E9F8, 'railBgBottom': 0xFFE6DCEF,
    'railFg': 0xFF7A6E92, 'railFgActive': 0xFF5E34AE,
    'railActiveBg': 0xFFDAC7EE, 'railGlow': 0x407A4FD0,
    'railIndicatorTop': 0xFF7A4FD0, 'railIndicatorBottom': 0xFF7A4FD0,
  },
  AppStyle.lagoon: {
    'bg': 0xFF0E1A1C, 'panel': 0xFF142224, 'panel2': 0xFF1A2B2D,
    'sidebar': 0xFF111F21, 'border': 0xFF2E4548, 'hairline': 0xFF23373A,
    'text': 0xFFE4F0EE, 'text2': 0xFFA6BCB7, 'text3': 0xFF869B96,
    'accent': 0xFF2ED3C6, 'onAccent': 0xFF08201E, 'hover': 0xFF1A2B2D,
    'selection': 0xFF1E4442, 'focus': 0xFF1FA89D, 'danger': 0xFFFF6B6B,
    'success': 0xFF4CC27A, 'warning': 0xFFE8C35A,
    'highlight': 0x17FFFFFF, 'highlightSoft': 0x0DFFFFFF,
    'railBg': 0xFF0B1516, 'railBgTop': 0xFF0E1A1B, 'railBgBottom': 0xFF081112,
    'railFg': 0xFF869B96, 'railFgActive': 0xFF7FE8DF,
    'railActiveBg': 0xFF143A3B, 'railGlow': 0x402ED3C6,
    'railIndicatorTop': 0xFF2ED3C6, 'railIndicatorBottom': 0xFF2ED3C6,
  },
  AppStyle.neon: {
    'bg': 0xFF0D0F14, 'panel': 0xFF131720, 'panel2': 0xFF1A1F2B,
    'sidebar': 0xFF10131A, 'border': 0xFF2C3444, 'hairline': 0xFF212838,
    'text': 0xFFE6EDF7, 'text2': 0xFFA8B5C9, 'text3': 0xFF8794A8,
    'accent': 0xFF2BD9E8, 'onAccent': 0xFF062228, 'hover': 0xFF1A1F2B,
    'selection': 0xFF1C3446, 'focus': 0xFF17AAB8, 'danger': 0xFFFF5470,
    'success': 0xFF3FD68F, 'warning': 0xFFF0C04A,
    'highlight': 0x17FFFFFF, 'highlightSoft': 0x0DFFFFFF,
    'railBg': 0xFF0A0C10, 'railBgTop': 0xFF0D1015, 'railBgBottom': 0xFF07090C,
    'railFg': 0xFF8794A8, 'railFgActive': 0xFF7FECF5,
    'railActiveBg': 0xFF142E3A, 'railGlow': 0x402BD9E8,
    'railIndicatorTop': 0xFF2BD9E8, 'railIndicatorBottom': 0xFF2BD9E8,
  },
};

void main() {
  group('AppStyle catalogue', () {
    test('exactly twelve styles; parchment leads the enum, midnight the startup',
        () {
      expect(AppStyle.values.length, 12);
      expect(AppStyle.values.first, AppStyle.parchment);
      expect(appStyle.value, AppStyle.midnight);
    });

    test('ids are unique and fromId round-trips every style', () {
      final ids = AppStyle.values.map((s) => s.id).toList();
      expect(ids.toSet().length, 12);
      for (final s in AppStyle.values) {
        expect(AppStyleX.fromId(s.id), s);
      }
    });

    test('fromId returns null for unknown and empty ids', () {
      expect(AppStyleX.fromId('no-such-style'), isNull);
      expect(AppStyleX.fromId(''), isNull);
      expect(AppStyleX.fromId('null'), isNull);
    });

    test('labels are non-empty and unique', () {
      final labels = AppStyle.values.map((s) => s.label).toList();
      expect(labels.every((l) => l.isNotEmpty), isTrue);
      expect(labels.toSet().length, 12);
    });

    test('brightness mapping: seven light styles, five dark styles', () {
      const lightStyles = {
        AppStyle.parchment,
        AppStyle.brick,
        AppStyle.mono,
        AppStyle.sky,
        AppStyle.sakura,
        AppStyle.mint,
        AppStyle.lilac,
      };
      for (final s in AppStyle.values) {
        expect(s.brightness,
            lightStyles.contains(s) ? Brightness.light : Brightness.dark,
            reason: s.id);
      }
    });
  });

  group('style palettes', () {
    test('parchment aliases the historical light tokens', () {
      expect(identical(AppStyle.parchment.tokens, AppTokens.light), isTrue);
    });

    for (final entry in _expected.entries) {
      test('${entry.key.id}: all 28 scalar fields match the design table', () {
        final actual = _scalarFields(entry.key.tokens);
        expect(actual.length, 28);
        for (final f in entry.value.entries) {
          expect(actual[f.key], Color(f.value),
              reason: '${entry.key.id}.${f.key}');
        }
      });
    }

    test('dark styles reuse the saturated dark type-colour set', () {
      for (final s in const [
        AppStyle.midnight,
        AppStyle.charcoal,
        AppStyle.aubergine,
        AppStyle.lagoon,
        AppStyle.neon,
      ]) {
        expect(s.tokens.typeString.fill, const Color(0xFF6A1DC3),
            reason: '${s.id}.typeString');
        expect(s.tokens.typeJson.fill, const Color(0xFF3F4B5F),
            reason: '${s.id}.typeJson');
        expect(s.tokens.typeHash.fg, const Color(0xFFFFFFFF),
            reason: '${s.id}.typeHash.fg');
      }
    });

    test('light styles reuse the pastel light type-colour set', () {
      for (final s in const [
        AppStyle.brick,
        AppStyle.sky,
        AppStyle.sakura,
        AppStyle.mint,
        AppStyle.lilac,
      ]) {
        expect(s.tokens.typeString.fill, const Color(0xFFC7B0EA),
            reason: '${s.id}.typeString');
        expect(s.tokens.typeList.fg, const Color(0xFF0C4A33),
            reason: '${s.id}.typeList.fg');
      }
    });

    test('mono uses the newspaper grayscale type-badge set', () {
      final t = AppStyle.mono.tokens;
      final fills = [
        t.typeString.fill,
        t.typeHash.fill,
        t.typeList.fill,
        t.typeSet.fill,
        t.typeZset.fill,
        t.typeStream.fill,
        t.typeJson.fill,
      ];
      const expectedFills = [
        0xFFF0F0EE, 0xFFE4E4E2, 0xFFD8D8D6, 0xFFCCCCCA,
        0xFFBFBFBD, 0xFFB3B3B1, 0xFFA6A6A4,
      ];
      for (var i = 0; i < fills.length; i++) {
        expect(fills[i], Color(expectedFills[i]));
      }
      expect(t.typeString.fg, const Color(0xFF0A0A0A));
      expect(t.typeJson.border, const Color(0x660A0A0A));
    });
  });

  group('appThemeForStyle', () {
    test('theme extension is identical to the style tokens (all 12)', () {
      for (final s in AppStyle.values) {
        final theme = appThemeForStyle(s);
        expect(identical(theme.extension<AppTokens>(), s.tokens),
            isTrue,
            reason: s.id);
      }
    });

    test('colorScheme brightness matches the style brightness', () {
      for (final s in AppStyle.values) {
        expect(appThemeForStyle(s).colorScheme.brightness, s.brightness,
            reason: s.id);
      }
    });

    test('legacy appTheme(Brightness) is unchanged', () {
      expect(identical(appTheme(Brightness.light).extension<AppTokens>(),
          AppTokens.light), isTrue);
      expect(identical(appTheme(Brightness.dark).extension<AppTokens>(),
          AppTokens.dark), isTrue);
    });

    test('smoke: all twelve themes build with scaffold == tokens.bg', () {
      for (final s in AppStyle.values) {
        final theme = appThemeForStyle(s);
        expect(theme.scaffoldBackgroundColor, s.tokens.bg, reason: s.id);
      }
    });
  });

  group('app wiring', () {
    test('appStyle change fires the merged appLang+appStyle listenable', () {
      var fired = 0;
      final merged = Listenable.merge([appLang, appStyle]);
      void listener() => fired++;
      merged.addListener(listener);
      appStyle.value = AppStyle.mono;
      expect(fired, 1);
      merged.removeListener(listener);
      appStyle.value = AppStyle.parchment;
    });

    test('smoke: parchment keeps its light token baseline', () {
      expect(AppStyle.parchment.tokens.bg, const Color(0xFFF7F5F0));
    });
  });

  group('theme prefs persistence', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('theme-prefs-test');
      appStyle.value = AppStyle.parchment;
    });

    tearDown(() {
      appStyle.value = AppStyle.parchment;
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('roundtrip: save then load restores the style', () {
      appStyle.value = AppStyle.lagoon;
      saveAppStyle(dir: tmp);
      appStyle.value = AppStyle.parchment;
      loadAppStyle(dir: tmp);
      expect(appStyle.value, AppStyle.lagoon);
    });

    test('missing file keeps the current style', () {
      appStyle.value = AppStyle.mono;
      loadAppStyle(dir: tmp);
      expect(appStyle.value, AppStyle.mono);
    });

    test('corrupt JSON falls back without throwing', () {
      File('${tmp.path}/theme.json').writeAsStringSync('{not json');
      loadAppStyle(dir: tmp);
      expect(appStyle.value, AppStyle.parchment);
    });

    test('unknown style id falls back without throwing', () {
      File('${tmp.path}/theme.json').writeAsStringSync('{"style":"no-such-style"}');
      loadAppStyle(dir: tmp);
      expect(appStyle.value, AppStyle.parchment);
    });

    test('non-map JSON falls back without throwing', () {
      File('${tmp.path}/theme.json').writeAsStringSync('["lagoon"]');
      loadAppStyle(dir: tmp);
      expect(appStyle.value, AppStyle.parchment);
    });

    test('atomic write leaves no .tmp residue', () {
      appStyle.value = AppStyle.midnight;
      saveAppStyle(dir: tmp);
      final names = tmp.listSync().map((e) => e.path.split('/').last).toList();
      expect(names, ['theme.json']);
      expect(File('${tmp.path}/theme.json').readAsStringSync(),
          '{"style":"midnight"}');
    });

    test('smoke: saving all twelve styles then load returns the last', () {
      for (final s in AppStyle.values) {
        appStyle.value = s;
        saveAppStyle(dir: tmp);
      }
      appStyle.value = AppStyle.parchment;
      loadAppStyle(dir: tmp);
      expect(appStyle.value, AppStyle.values.last);
    });
  });
}
