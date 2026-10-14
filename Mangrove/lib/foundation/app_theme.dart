import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'appdata.dart';

/// Builds the app's [ThemeData] from a seed colour.
///
/// Extracted verbatim from `_MyAppState.getTheme` so the colour scheme settings
/// screen can render a live light/dark preview through the *same* derivation
/// the running app uses — a preview built any other way would drift from the
/// real theme the moment the tones or the font stack change.
ThemeData buildAppTheme({
  required Color primary,
  Color? secondary,
  Color? tertiary,
  required Brightness brightness,
}) {
  String? font;
  List<String>? fallback;
  if (App.isLinux || App.isWindows) {
    font = 'Noto Sans CJK';
    fallback = [
      'Segoe UI',
      'Noto Sans SC',
      'Noto Sans TC',
      'Noto Sans',
      'Microsoft YaHei',
      'PingFang SC',
      'Arial',
      'sans-serif',
    ];
  }
  return ThemeData(
    colorScheme: SeedColorScheme.fromSeeds(
      primaryKey: primary,
      secondaryKey: secondary,
      tertiaryKey: tertiary,
      brightness: brightness,
      tones: FlexTones.vividBackground(brightness),
    ),
    fontFamily: font,
    fontFamilyFallback: fallback,
    // ExpansionTile shows top/bottom divider lines when expanded by default.
    // Override globally with borderless shapes so no expandable tile (task
    // cards, reader settings groups, source dialogs, etc.) renders stray
    // lines at its top and bottom.
    expansionTileTheme: const ExpansionTileThemeData(
      shape: Border(),
      collapsedShape: Border(),
    ),
    // Covers the routes that aren't AppPageRoute (they read the same setting
    // themselves) so the back gesture behaves the same everywhere (#194).
    pageTransitionsTheme:
        App.isAndroid && appdata.settings['enablePredictiveBack'] == false
        ? const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
            },
          )
        : null,
  );
}
