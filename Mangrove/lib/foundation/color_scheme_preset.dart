import 'dart:ui';

/// Seed-colour presets for the whole app theme.
///
/// The app has always derived its [ColorScheme] from a single seed colour
/// (`SeedColorScheme.fromSeeds`), so a "theme" here is nothing more than the
/// seed it starts from. This file holds the preset table plus the pure
/// helpers used by the theme builder, the settings screen and the tests.
///
/// Kept free of any Flutter widget / appdata import so it can be asserted on
/// directly (see `test/color_scheme_preset_test.dart`).

/// Follows the platform accent (Android dynamic colour, elsewhere the seed).
const String kPresetSystem = 'system';

/// Uses [Appdata]'s `customSeedColor` instead of a fixed seed.
const String kPresetCustom = 'custom';

/// Used whenever a preset id is missing or unknown. Same blue the pre-P47
/// `translateColorSetting()` fell back to, so an unreadable value can never
/// change what a user already sees.
const Color kDefaultSeedColor = Color(0xFF2196F3);

/// A named seed colour. [seed] is what feeds `SeedColorScheme.fromSeeds`.
class ColorSchemePreset {
  final String id;

  /// The seed colour. Always opaque; alpha is meaningless for a seed.
  final Color seed;

  const ColorSchemePreset(this.id, this.seed);
}

/// The seeded presets, in the order they are offered to the user.
///
/// Secondary/tertiary keys stay `null` everywhere (P0): they are auto-derived
/// from the seed, and `FlexTones.vividBackground` is unchanged, so switching
/// from the legacy `color` setting to a preset of the same hue is visually a
/// no-op.
const List<ColorSchemePreset> kColorSchemePresets = [
  ColorSchemePreset('blue', Color(0xFF2196F3)),
  // comix.to's purple, the reference the reader restyle was measured against.
  ColorSchemePreset('purple', Color(0xFF8765EB)),
  ColorSchemePreset('tokyo', Color(0xFF7AA2F7)),
  ColorSchemePreset('teal', Color(0xFF14B8A6)),
  ColorSchemePreset('pink', Color(0xFFEC4899)),
  ColorSchemePreset('amber', Color(0xFFF59E0B)),
  ColorSchemePreset('green', Color(0xFF22C55E)),
  ColorSchemePreset('red', Color(0xFFEF4444)),
  ColorSchemePreset('violet', Color(0xFF8B5CF6)),
  ColorSchemePreset('graphite', Color(0xFF6B7280)),
  ColorSchemePreset('sepia', Color(0xFFB08968)),
];

/// Every selectable id: system + the 11 seeds + custom.
List<String> get kColorSchemePresetIds => [
  kPresetSystem,
  ...kColorSchemePresets.map((e) => e.id),
  kPresetCustom,
];

bool isValidColorSchemePreset(String? id) =>
    id != null && kColorSchemePresetIds.contains(id);

/// The seed for [presetId].
///
/// Returns `null` **only** for [kPresetSystem], where the caller is expected to
/// use the platform's own colours instead. An unknown id falls back to
/// [kDefaultSeedColor] rather than null so a garbled setting still renders.
Color? seedColorForPreset(String? presetId, {Color? customSeed}) {
  if (presetId == kPresetCustom) {
    return customSeed ?? kDefaultSeedColor;
  }
  if (presetId == kPresetSystem) {
    return null;
  }
  for (final preset in kColorSchemePresets) {
    if (preset.id == presetId) {
      return preset.seed;
    }
  }
  return kDefaultSeedColor;
}

/// One-shot upgrade of the legacy `color` setting (P47).
///
/// The old key held one of `system/red/pink/purple/green/orange/blue` (plus
/// `yellow`/`cyan`, which existed in the switch but were never offered in the
/// UI). Presets cover all of them, so the mapping is lossless. `orange` has no
/// preset of that name — it lands on `amber`, the preset whose seed is the
/// amber/orange family. Anything unrecognised falls back to `blue`, exactly as
/// the old `translateColorSetting()` did.
///
/// The old `color` key is deliberately left alone: it is the rollback path if
/// a build with this migration has to be reverted.
String migrateLegacyColorPreset(Object? legacyColor) => switch (legacyColor) {
  'system' => kPresetSystem,
  'red' => 'red',
  'pink' => 'pink',
  'purple' => 'purple',
  'green' => 'green',
  'orange' => 'amber',
  'yellow' => 'amber',
  'cyan' => 'teal',
  'blue' => 'blue',
  _ => 'blue',
};

/// Parses `#RRGGBB` / `RRGGBB` / `#AARRGGBB` / `0xAARRGGBB`.
///
/// Returns `null` for anything else so the caller can keep the previous value
/// instead of silently applying a half-typed colour.
Color? parseHexColor(String? value) {
  if (value == null) return null;
  var hex = value.trim();
  if (hex.startsWith('#')) {
    hex = hex.substring(1);
  } else if (hex.startsWith('0x') || hex.startsWith('0X')) {
    hex = hex.substring(2);
  }
  if (hex.length == 6) {
    hex = 'FF$hex';
  }
  if (hex.length != 8) return null;
  final parsed = int.tryParse(hex, radix: 16);
  if (parsed == null) return null;
  return Color(parsed);
}

/// `#RRGGBB`, upper case, alpha dropped — the form [parseHexColor] accepts and
/// the form shown in the HEX field.
String formatHexColor(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
