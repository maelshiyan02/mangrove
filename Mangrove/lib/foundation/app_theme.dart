import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'appdata.dart';

// P57 曾在此处给全站 TextTheme 叠 8 方向零模糊 `shadows`，模拟 1px 同底色
// 描边。用户实测反馈这层描边让字形发虚、像套了阴影框线，正常阅读反而不如
// 无描边的原始字体，故整体移除（buildTextOutline / withTextOutline 一并删除，
// 避免留下只在自检里用得到的死代码）。文字现在直接继承基础主题，不再有阴影。

/// Builds the app's [ThemeData] from a seed colour.
///
/// Extracted verbatim from `_MyAppState.getTheme` so the colour scheme settings
/// screen can render a live light/dark preview through the *same* derivation
/// the running app uses — a preview built any other way would drift from the
/// real theme the moment the tones or the font stack change.
///
/// [sepia] derives the "护眼" (eye-care) appearance: a warm paper surface
/// layered over the normal light brightness while keeping the chosen seed as
/// the accent. Mirrors Scrollforge's `ReaderPaper.parchment/sage` idea — the
/// whole app, not just the reader, gets the warm tint.
ThemeData buildAppTheme({
  required Color primary,
  Color? secondary,
  Color? tertiary,
  required Brightness brightness,
  bool sepia = false,
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
  final ThemeData theme = ThemeData(
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
  if (!sepia) {
    return theme;
  }
  // 护眼：暖色纸张表面替换所有 surface 层级，主色（seed）保留为强调色。
  const paper = Color(0xFFF7F0E1);
  const paperLow = Color(0xFFF2E9D6);
  const paperMid = Color(0xFFEDE2C8);
  const paperHigh = Color(0xFFE7DABC);
  const paperHighest = Color(0xFFE1D2B0);
  const ink = Color(0xFF3B3326);
  const inkVariant = Color(0xFF6B5E48);
  const warmOutline = Color(0xFFC9B893);
  const warmOutlineVariant = Color(0xFFD8C9A8);
  final sepiaScheme = theme.colorScheme.copyWith(
    surface: paper,
    surfaceBright: const Color(0xFFFBF5E9),
    surfaceDim: paperLow,
    surfaceContainerLowest: paper,
    surfaceContainerLow: paperLow,
    surfaceContainer: paperMid,
    surfaceContainerHigh: paperHigh,
    surfaceContainerHighest: paperHighest,
    onSurface: ink,
    onSurfaceVariant: inkVariant,
    outline: warmOutline,
    outlineVariant: warmOutlineVariant,
    inverseSurface: ink,
    onInverseSurface: paperLow,
    surfaceTint: Colors.transparent,
  );
  return theme.copyWith(
    colorScheme: sepiaScheme,
    scaffoldBackgroundColor: paper,
    dialogTheme: DialogThemeData(backgroundColor: paperMid),
  );
}
