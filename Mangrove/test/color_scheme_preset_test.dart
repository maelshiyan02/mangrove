import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangrove/foundation/app_theme.dart';
import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/foundation/color_scheme_preset.dart';
import 'package:mangrove/utils/sync_skip.dart';

/// The 11 seeded presets; `system` (platform accent) and `custom` (user seed)
/// have no seed of their own and are asserted separately.
List<ColorSchemePreset> get _seeded => kColorSchemePresets;

void main() {
  group('preset table', () {
    test('offers 13 choices: system + 11 seeds + custom', () {
      expect(kColorSchemePresetIds.length, 13);
      expect(kColorSchemePresetIds.first, kPresetSystem);
      expect(kColorSchemePresetIds.last, kPresetCustom);
      for (final id in kColorSchemePresetIds) {
        expect(isValidColorSchemePreset(id), isTrue, reason: id);
      }
      expect(isValidColorSchemePreset('orange'), isFalse);
    });

    test('every seed is distinct', () {
      final seeds = _seeded.map((e) => e.seed.toARGB32()).toSet();
      expect(seeds.length, _seeded.length);
    });

    test('resolves to the seed, except system which defers to the platform', () {
      for (final preset in _seeded) {
        expect(seedColorForPreset(preset.id), preset.seed, reason: preset.id);
      }
      expect(seedColorForPreset(kPresetSystem), isNull);
      expect(seedColorForPreset('nonsense'), kDefaultSeedColor);
    });

    test('custom falls back to blue until a seed is picked', () {
      expect(seedColorForPreset(kPresetCustom), kDefaultSeedColor);
      expect(
        seedColorForPreset(kPresetCustom, customSeed: const Color(0xFF7AA2F7)),
        const Color(0xFF7AA2F7),
      );
    });

    test('every seeded preset derives a theme in both brightnesses', () {
      final primaries = <int>{};
      for (final preset in _seeded) {
        for (final brightness in Brightness.values) {
          final scheme = buildAppTheme(
            primary: seedColorForPreset(preset.id)!,
            brightness: brightness,
          ).colorScheme;
          expect(scheme.primary, isNotNull, reason: preset.id);
          primaries.add(scheme.primary.toARGB32() ^ brightness.index);
        }
      }
      // A preset that produced the same palette as another would be a
      // duplicate entry in the gallery.
      expect(primaries.length, _seeded.length * 2);
    });

    test('a custom seed themes exactly like the preset of the same colour', () {
      const seed = Color(0xFF7AA2F7); // the `tokyo` seed
      final fromPreset = buildAppTheme(
        primary: seedColorForPreset('tokyo')!,
        brightness: Brightness.light,
      ).colorScheme;
      final fromCustom = buildAppTheme(
        primary: seedColorForPreset(kPresetCustom, customSeed: seed)!,
        brightness: Brightness.light,
      ).colorScheme;
      expect(fromCustom.primary, fromPreset.primary);
      expect(fromCustom.secondary, fromPreset.secondary);
    });
  });

  group('legacy migration', () {
    void resetMigration() {
      appdata.settings['colorSchemePresetMigrated'] = false;
    }

    test('maps every legacy colour onto a preset', () {
      const expected = {
        'system': 'system',
        'red': 'red',
        'pink': 'pink',
        'purple': 'purple',
        'green': 'green',
        'orange': 'amber',
        'yellow': 'amber',
        'cyan': 'teal',
        'blue': 'blue',
        'somethingElse': 'blue',
        null: 'blue',
      };
      for (final entry in expected.entries) {
        expect(
          migrateLegacyColorPreset(entry.key),
          entry.value,
          reason: '${entry.key}',
        );
      }
    });

    test('writes the preset, keeps the old key, and is idempotent', () {
      appdata.settings['color'] = 'orange';
      resetMigration();
      appdata.migrateColorSchemePresetIfNeeded();
      expect(appdata.settings['colorSchemePreset'], 'amber');
      // Rollback safety: the pre-P47 code path must still find a choice.
      expect(appdata.settings['color'], 'orange');
      expect(appdata.settings['colorSchemePresetMigrated'], true);

      // Second run: the flag short-circuits, so a later user choice is never
      // clobbered by the legacy value again.
      appdata.settings['colorSchemePreset'] = 'graphite';
      appdata.migrateColorSchemePresetIfNeeded();
      expect(appdata.settings['colorSchemePreset'], 'graphite');
    });

    test('a fresh install starts on system', () {
      appdata.settings['color'] = 'system';
      resetMigration();
      appdata.migrateColorSchemePresetIfNeeded();
      expect(appdata.settings['colorSchemePreset'], kPresetSystem);
    });
  });

  group('hex round trip', () {
    test('parses the forms users actually type', () {
      const color = Color(0xFF7AA2F7);
      expect(parseHexColor('#7AA2F7'), color);
      expect(parseHexColor('7aa2f7'), color);
      expect(parseHexColor('  #7AA2F7  '), color);
      expect(parseHexColor('#FF7AA2F7'), color);
      expect(parseHexColor('0xFF7AA2F7'), color);
    });

    test('rejects anything else', () {
      expect(parseHexColor(''), isNull);
      expect(parseHexColor('#7AA2'), isNull);
      expect(parseHexColor('#GGGGGG'), isNull);
      expect(parseHexColor(null), isNull);
    });

    test('formats without alpha and re-parses to the same colour', () {
      for (final preset in _seeded) {
        final text = formatHexColor(preset.seed);
        expect(text, startsWith('#'));
        expect(text.length, 7);
        expect(parseHexColor(text), preset.seed, reason: preset.id);
      }
    });
  });

  group('sync classification', () {
    test('the new keys sync, the migration flag stays device-local', () {
      final appearance = syncSkipCategories.firstWhere(
        (c) => c.id == 'appearance',
      );
      expect(appearance.keys, contains('colorSchemePreset'));
      expect(appearance.keys, contains('customSeedColor'));
      expect(
        Appdata.syncDisabledFields(const []),
        contains('colorSchemePresetMigrated'),
      );
    });
  });
}
