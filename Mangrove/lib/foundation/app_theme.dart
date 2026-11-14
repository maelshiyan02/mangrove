import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'appdata.dart';

/// 全站文字描边：给每个 [TextStyle] 叠一圈「背景同色」的极细光晕。
///
/// Flutter 没有全局 stroke 能力（真描边要给每段文字叠一个
/// `PaintStyle.stroke` 的副本，无法在主题层统一），所以用 8 方向的零模糊
/// `shadows` 近似一圈 1px 轮廓。夜间档文字是浅色、护眼档是深墨色，光晕统一
/// 取当前 surface 色 —— 三种档位下文字都能从图片、彩色底和渐变上「浮」出来。
List<Shadow> buildTextOutline(Color halo) {
  const r = 1.0;
  const dirs = <(double, double)>[
    (0, -1),
    (0, 1),
    (-1, 0),
    (1, 0),
    (-0.7, -0.7),
    (0.7, -0.7),
    (-0.7, 0.7),
    (0.7, 0.7),
  ];
  return [
    for (final d in dirs)
      Shadow(
        color: halo.withValues(alpha: 0.85),
        offset: Offset(d.$1 * r, d.$2 * r),
        blurRadius: 0.4,
      ),
  ];
}

/// 把描边光晕铺到整张 [TextTheme] 上。
///
/// 下级控件的 `ts.s14` 之类都只设字号/颜色，`shadows` 为空时会从
/// `DefaultTextStyle`（即这里的 bodyMedium）继承，因此这一处修改即可覆盖
/// 绝大多数文本，无需逐页改绘制方式。
TextTheme withTextOutline(TextTheme t, Color halo) {
  final shadows = buildTextOutline(halo);
  TextStyle? o(TextStyle? s) => s?.copyWith(shadows: shadows);
  return TextTheme(
    displayLarge: o(t.displayLarge),
    displayMedium: o(t.displayMedium),
    displaySmall: o(t.displaySmall),
    headlineLarge: o(t.headlineLarge),
    headlineMedium: o(t.headlineMedium),
    headlineSmall: o(t.headlineSmall),
    titleLarge: o(t.titleLarge),
    titleMedium: o(t.titleMedium),
    titleSmall: o(t.titleSmall),
    bodyLarge: o(t.bodyLarge),
    bodyMedium: o(t.bodyMedium),
    bodySmall: o(t.bodySmall),
    labelLarge: o(t.labelLarge),
    labelMedium: o(t.labelMedium),
    labelSmall: o(t.labelSmall),
  );
}

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
    return theme.copyWith(
      textTheme: withTextOutline(theme.textTheme, theme.colorScheme.surface),
    );
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
    // 护眼档的描边取纸面暖色，深墨色文字在纸面上仍有清晰的边。
    textTheme: withTextOutline(theme.textTheme, paper),
  );
}
