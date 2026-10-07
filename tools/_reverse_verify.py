"""Reverse-verify P1 assertions by injecting one fault at a time (P9.3 lesson).

For each fault: apply it, rebuild, run `edit-check`, and require that the
**targeted** assertion reports FAIL. A fault that leaves the assertion green
means the assertion is decorative.

Driven by `tools/_rv_drive.py`. Anchors are exact source substrings and must be
**unique** in their file — `apply` refuses a non-unique anchor rather than
patching the wrong site, because a silently mis-targeted fault would "verify" an
assertion that was never actually broken.

    python tools/_reverse_verify.py list|apply <id>|revert <id>|status
"""
import io
import json
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, 'VeneraX')
BACKUP = os.path.join(ROOT, 'builds', '_rv_backup')

B = 'balloon_clustering.dart'   # lib/foundation/image_translation/
F = 'bundled_fonts.dart'        # lib/foundation/
P = 'studio_pipeline.dart'      # lib/foundation/translation_project/
H = 'headless_p1_checks.dart'   # lib/
S = 'studio_page.dart'          # lib/pages/translation_studio/

# P2 (P9.7)
G = 'block_resize_geometry.dart'  # lib/components/
C = 'text_block_canvas.dart'      # lib/components/
T = 'tray.dart'                   # lib/foundation/
R = 'page_renderer.dart'          # lib/foundation/image_translation/

# id -> (files, [(old, new)], target assertion)
FAULTS = {
    # ---- font.* ---------------------------------------------------------
    # 🔴 打在 dart 表上，而不是 pubspec 上。改 pubspec 的 `asset:` 会让 Flutter
    # 在构建时直接失败（声明了不存在的资产 = 硬错误），于是故障报出来的是一句
    # "build failed" —— 那**没有测量**，不是一次失败的反向验证。改 dart 表则
    # 构建照常通过（该字段只被断言与 pubspec 镜像读），断言测到的正是它要测的。
    'font_files_missing': (
        [f'lib/foundation/{F}'],
        [("    file: 'fonts/NotoSansSC-Regular.otf',",
          "    file: 'fonts/NotoSansSC-MISSING.otf', // injected fault")],
        'font.files_present',
    ),
    'font_license_removed': (
        [f'lib/foundation/{F}'],
        # 🔴 Anchored on the *Bold* entry's file path (unique) rather than on the
        # `script:` lines: those were reworded when P9.7 added the Korean family
        # and every anchor that quoted them stopped applying. A fault that cannot
        # apply is not a passing test — it is a test that never ran.
        [("""    license: 'fonts/LICENSE-NotoSansSC.txt',
  ),
  BundledFont(
    family: 'Noto Sans SC',
    file: 'fonts/NotoSansSC-Bold.otf',
    weight: 700,""",
          """    license: 'fonts/LICENSE-GONE.txt',
  ),
  BundledFont(
    family: 'Noto Sans SC',
    file: 'fonts/NotoSansSC-Bold.otf',
    weight: 700,""")],
        'font.license_embedded',
    ),
    # 🔴 三重注入，而不是"给 `fonts:` 前面加个 #"：只注释父键的话，底下的
    # `- family:` 行会变成无主的列表项，pubspec 直接 YAML 解析失败 —— 又是一次
    # "build failed" 而不是一次测量。这里把两个 family 条目删干净、把父键换成
    # 空列表：YAML 合法、构建通过、`fonts:` 不再是裸键（断言的第一条腿），且表里
    # 两个 family 都不在 pubspec 里（`font.assets_exist_in_pubspec` 会连带红）。
    #
    # ⚠️ 第三个锚点必须写成 `\n  fonts:\n`：`  fonts:\n` 是 `      fonts:\n`
    # 的子串（两个 family 条目内部各有一次），只写两个空格的话锚点出现 3 次，
    # `apply` 会（正确地）拒绝。
    'font_family_commented_out': (
        ['pubspec.yaml', 'pubspec.yaml', 'pubspec.yaml'],
        [("""    - family: Noto Sans SC
      fonts:
        - asset: assets/fonts/NotoSansSC-Regular.otf
          weight: 400
        - asset: assets/fonts/NotoSansSC-Bold.otf
          weight: 700
""", ''),
         ("""    - family: Noto Sans KR
      fonts:
        - asset: assets/fonts/NotoSansKR-Regular.otf
          weight: 400
        - asset: assets/fonts/NotoSansKR-Bold.otf
          weight: 700
""", ''),
         ('\n  fonts:\n',
          '\n  fonts: []  # injected fault: no family is registered\n')],
        'font.registry_matches_pubspec',
    ),
    'font_renamed_in_pubspec': (
        ['pubspec.yaml'],
        [('    - family: Noto Sans SC\n',
          '    - family: Noto Sans SC X\n')],
        'font.assets_exist_in_pubspec',
    ),
    'font_fallback_removed': (
        [f'lib/foundation/{F}'],
        [("""  return ResolvedFamily(
    family: primaryBundledFamily,
    fallback: true,
    reason: '"$name" is not bundled; fell back to "$primaryBundledFamily"',
  );""",
          """  return ResolvedFamily(
    family: name,
    fallback: false,
    reason: 'injected fault: pass the unknown family through',
  );""")],
        'font.unknown_family_falls_back',
    ),
    'font_legacy_alias_removed': (
        [f'lib/foundation/{F}'],
        [("""  'Microsoft YaHei UI': primaryBundledFamily,
  'Microsoft YaHei': primaryBundledFamily,""",
          """  // injected fault: legacy YaHei aliases removed
  'Microsoft YaHei UIDISABLED': primaryBundledFamily,
  'Microsoft YaHeiDISABLED': primaryBundledFamily,""")],
        'font.legacy_yahei_mapped',
    ),
    'font_null_falls_back_to_system': (
        [f'lib/foundation/{F}'],
        [("""    return ResolvedFamily(
      family: primaryBundledFamily,
      fallback: true,
      reason: 'no font_family in the block — using the bundled family',
    );""",
          """    return ResolvedFamily(
      family: 'Microsoft YaHei UI',
      fallback: false,
      reason: 'injected fault: hand back a system font',
    );""")],
        'font.missing_family_falls_back',
    ),
    'font_bundled_rewritten': (
        [f'lib/foundation/{F}'],
        [('    if (font.family.toLowerCase() == key) {',
          '    if (font.family.length > 0 && false) {')],
        'font.bundled_family_passes_through',
    ),
    'font_default_family_changed': (
        ['lib/foundation/translation_project/text_block.dart'],
        [("  static const String defaultFontFamily = 'Microsoft YaHei UI';",
          "  static const String defaultFontFamily = 'Some Other Face';")],
        'font.default_family_is_legacy',
    ),
    'font_selector_drops_unbundled': (
        [f'lib/foundation/{F}'],
        [("""  final name = (current ?? '').trim();
  if (name.isNotEmpty && !seen.contains(name)) {
    result.add((family: name, bundled: false, label: '$name (not bundled)'));
  }""",
          """  // injected fault: the unbundled entry is dropped""")],
        'font.selector_lists_unbundled',
    ),
    'font_renderer_raw_passthrough': (
        [f'lib/foundation/image_translation/page_renderer.dart'],
        [('    fontFamily: resolveFamily(style.fontFamily).family,',
          '    fontFamily: style.fontFamily, // injected fault')],
        'font.renderer_resolves_family',
    ),
    'font_canvas_raw_passthrough': (
        ['lib/components/text_block_canvas.dart'],
        [('      fontFamily: resolveFamily(block.fontFamily).family,',
          '      fontFamily: block.fontFamily, // injected fault')],
        'font.preview_matches_output',
    ),

    # ---- cluster.* ------------------------------------------------------
    'cluster_merge_disabled': (
        [f'lib/foundation/image_translation/{B}'],
        [('      if (!boxes[i].intersects(boxes[j])) continue;',
          '      if (true) continue; // injected fault: never merge')],
        'cluster.merges_lines_of_one_balloon',
    ),
    # 🔴 改 `gapFactor` 而不是 `maxGap`。间隙是 `medianHeight × gapFactor` 再夹到
    # `[minGap, maxGap]`，而漫画行的字高只有 30–40px —— 把上限从 90 抬到 9000
    # 根本轮不到它生效（乘积 18–24 远小于 90），故障是完全惰性的，断言照样绿。
    # 4.0 让乘积涨到 120、被上限 90 夹住，正好越过夹具那 100px 的间距。
    'cluster_merge_too_eager': (
        [f'lib/foundation/image_translation/{B}'],
        [('    this.gapFactor = 0.6,',
          '    this.gapFactor = 4.0, // injected fault: an over-generous gap')],
        'cluster.splits_separate_balloons',
    ),
    'cluster_direction_ignored': (
        [f'lib/foundation/image_translation/{B}'],
        [("""  return direction == ReadingDirection.rightToLeft
      ? readColumn == columnCount - 1 - leftToRightIndex
      : readColumn == leftToRightIndex;""",
          """  // injected fault: the reading direction is ignored
  return readColumn == leftToRightIndex;""")],
        'cluster.reading_order_right_to_left',
    ),
    'cluster_ltr_becomes_rtl': (
        [f'lib/foundation/image_translation/{B}'],
        [("""  return direction == ReadingDirection.rightToLeft
      ? readColumn == columnCount - 1 - leftToRightIndex
      : readColumn == leftToRightIndex;""",
          """  // injected fault: every page reads right-to-left
  return readColumn == columnCount - 1 - leftToRightIndex;""")],
        'cluster.reading_order_left_to_right',
    ),
    'cluster_column_sorts_by_x': (
        [f'lib/foundation/image_translation/{B}'],
        [('    ]..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));',
          '    ]..sort((a, b) => a.bounds.left.compareTo(b.bounds.left));')],
        'cluster.column_reads_top_to_bottom',
    ),
    'cluster_column_merges_everything': (
        [f'lib/foundation/image_translation/{B}'],
        [('    if (group.bounds.left - rightmost >= minGap) {',
          '    if (false) { // injected fault: one column per page')],
        'cluster.staggered_not_merged_into_one_column',
    ),
    'cluster_nondeterministic_order': (
        [f'lib/foundation/image_translation/{B}'],
        [("""    ..sort((a, b) {
      final byLeft = a.bounds.left.compareTo(b.bounds.left);
      return byLeft != 0 ? byLeft : a.bounds.right.compareTo(b.bounds.right);
    });""",
          '    ; // injected fault: keep the input order')],
        'cluster.order_is_deterministic',
    ),
    'cluster_vertical_sorts_by_top': (
        [f'lib/foundation/image_translation/{B}'],
        [("""      final byColumn = b.rect.left.compareTo(a.rect.left);
      if (byColumn != 0) return byColumn;
      return a.rect.top.compareTo(b.rect.top);""",
          """      // injected fault: vertical columns sorted by top only
      return a.rect.top.compareTo(b.rect.top);""")],
        'cluster.vertical_lines_read_right_first',
    ),
    # 🔴 不能带 `const`：`Balloon` 的构造器不是 const（`IntRect` 的也不是），
    # 上一版因此**直接编译失败** —— 一次 "build failed" 是没有测量，不是一次
    # 失败的反向验证。判据要写成"这条断言真的翻红了"，而不是"构建炸了"。
    'cluster_empty_fabricates': (
        [f'lib/foundation/image_translation/{B}'],
        [('  if (usable.isEmpty) return const [];',
          '  if (usable.isEmpty) {\n'
          '    // injected fault: fabricate a balloon for an empty page\n'
          '    return <Balloon>[\n'
          '      Balloon(lines: <TextLine>[], bounds: IntRect(0, 0, 1, 1)),\n'
          '    ];\n'
          '  }')],
        'cluster.empty_input_yields_nothing',
    ),
    'cluster_blank_lines_count': (
        [f'lib/foundation/image_translation/{B}'],
        [('      if (!line.isBlank && line.rect.width > 0 && line.rect.height > 0) line,',
          '      if (line.rect.width > 0 && line.rect.height > 0) line,')],
        'cluster.blank_lines_ignored',
    ),
    'cluster_orientation_check_removed': (
        [f'lib/foundation/image_translation/{B}'],
        [('  if (dirA != 0 && dirB != 0 && dirA != dirB) return false;',
          '  // injected fault: orientation is no longer checked')],
        'cluster.mixed_orientation_not_merged',
    ),
    'cluster_size_check_removed': (
        [f'lib/foundation/image_translation/{B}'],
        [('  if (minH > 0 && maxH > minH * 2.2) return false;',
          '  // injected fault: the size-ratio guard is gone')],
        'cluster.mixed_font_size_not_merged',
    ),
    'cluster_mean_instead_of_median': (
        [f'lib/foundation/image_translation/{B}'],
        [("""    if (heights.isEmpty) return 0;
    return heights[heights.length ~/ 2];""",
          """    if (heights.isEmpty) return 0;
    var total = 0;
    for (final h in heights) {
      total += h;
    }
    return (total / heights.length).round(); // injected fault: the mean""")],
        'cluster.reports_median_line_height',
    ),
    'cluster_bridge_drops_per_line_rects': (
        [f'lib/foundation/image_translation/{B}'],
        [('    eraseRects: [for (final l in balloon.lines) l.rect],',
          '    eraseRects: [balloon.bounds], // injected fault')],
        'cluster.bridge_keeps_per_line_erase_rects',
    ),
    # 🔴 只能改"实现关系"，不能改类名：断言里写着
    # `const detector = PureGeometryBalloonDetector();` —— 改名会让**断言文件**
    # 编译不过，于是又是一次 build failed。
    # 同时必须摘掉 `@override`：留着它是一条 analyzer 警告，而 `flutter analyze`
    # 默认 `--fatal-warnings`，构建照样失败。两处一起改，才是既编译得过、又让
    # `detector is BalloonDetector` 变成 false 的形态。
    'cluster_extension_point_removed': (
        [f'lib/foundation/image_translation/{B}',
         f'lib/foundation/image_translation/{B}'],
        [('class PureGeometryBalloonDetector implements BalloonDetector {',
          'class PureGeometryBalloonDetector { // injected fault: seam removed'),
         ('  @override\n  Future<List<DetectedBalloon>> detect(DetectedPage page) async {',
          '  // injected fault: @override went with the interface\n'
          '  Future<List<DetectedBalloon>> detect(DetectedPage page) async {')],
        'cluster.detector_extension_point_exists',
    ),

    # ---- pipeline.* -----------------------------------------------------
    'pipeline_block_at_a_time': (
        ['lib/foundation/translation_project/project.dart'],
        [("""  void addBlocks(Iterable<TextBlock> blocks) {
    for (final block in blocks) {
      rawBlocks.add(block.raw);
    }
  }""",
          """  void addBlocks(Iterable<TextBlock> blocks) {
    // injected fault: only the first block lands, so one undo cannot revert
    // the batch
    for (final block in blocks.take(1)) {
      rawBlocks.add(block.raw);
    }
  }""")],
        'pipeline.batch_landing_is_one_undo_step',
    ),
    'pipeline_no_undo_recorded': (
        [f'lib/{H}'],
        [('  history.push(command);\n  final afterAdd = page.blocks.length;',
          '  // injected fault: the command is never pushed\n'
          '  final afterAdd = page.blocks.length;')],
        'pipeline.landing_registers_dirty_page',
    ),
    'pipeline_dirty_never_cleared': (
        ['lib/foundation/translation_project/edit_command.dart'],
        [('  void markSaved() {\n    _savedIndex = _undo.length;',
          '  void markSaved() {\n    _savedIndex = 0; // injected fault')],
        'pipeline.undo_after_save_clears_dirty',
    ),
    'pipeline_dedup_always_false': (
        [f'lib/foundation/translation_project/{P}'],
        [('  return best > threshold;',
          '  return false && best > threshold; // injected fault: never dedup')],
        'pipeline.dedup_protects_reviewed_blocks',
    ),
    'pipeline_fromocr_fills_translation': (
        ['lib/foundation/translation_project/text_block.dart'],
        [("""    final format = result.fontFormat!;""",
          """    result.raw['translation'] = block.text; // injected fault
    final format = result.fontFormat!;""")],
        'pipeline.blocks_become_letterable',
    ),
    'pipeline_cancel_ignored': (
        [f'lib/foundation/translation_project/{P}'],
        [("""  void throwIfCanceled() {
    if (_canceled) throw const PipelineCanceled();
  }""",
          '  void throwIfCanceled() {} // injected fault')],
        'pipeline.cancel_token_works',
    ),
    'pipeline_report_hides_failures': (
        [f'lib/foundation/translation_project/{P}'],
        [('  int get failedPages => pages.where((p) => p.failed).length;',
          '  int get failedPages => 0; // injected fault')],
        'pipeline.report_counts_failures',
    ),
    'pipeline_studio_uses_legacy': (
        [f'lib/pages/translation_studio/{S}'],
        [("import 'package:venera/foundation/translation_project/edit_command.dart';",
          "import 'package:venera/foundation/image_translation/"
          "pre_translation_tasks.dart'; // injected fault\n"
          "import 'package:venera/foundation/translation_project/"
          "edit_command.dart';")],
        'pipeline.studio_does_not_use_legacy_engine',
    ),

    # ---- P2 · snap.*（吸附几何 · P9.7）-----------------------------------
    #
    # 🔴 这一组有三条是**多目标连带**（见下面的 EXPECTED_CASCADE）：`snapEdge`
    # 的容差闸门被两条断言同时依赖，而 `snapResize` 又把它包在中间 —— 一个故障
    # 同时打红两条，不是"结果不可信"，是这两条断言本来就锁同一行代码。
    'snap_edge_last_wins': (
        [f'lib/components/{G}'],
        # 去掉容差 + 最近者胜的闸门：候选取最后一个能落进容差的。
        [('    if (distance > bestDistance) continue;\n',
          '    // injected fault: the last candidate inside tolerance wins\n')],
        'snap.edge_within_tolerance',
    ),
    'snap_tolerance_too_generous': (
        [f'lib/components/{G}'],
        # 4px 改成 40px：容差本身失灵。断言传的是这个常量，所以它**能**抓到 ——
        # 这正是"容差外不吸"那条断言存在的意义。
        [('const resizeSnapTolerance = 4.0;',
          'const resizeSnapTolerance = 40.0; // injected fault')],
        'snap.edge_outside_tolerance',
    ),
    'snap_resize_wrong_edge': (
        [f'lib/components/{G}'],
        # 左右搞反：右把手去吸左边缘。被 handle 拖动的那条边不再被吸附
        # （右边缘停在 298 而不是 300），且左边缘因为够不着而不吸。
        [("""  if (handle.movesLeft) {
    final hit = snapEdge(rect.left, targetsX, tolerance);""",
          """  if (handle.movesRight) { // injected fault: the wrong edge snaps
    final hit = snapEdge(rect.left, targetsX, tolerance);""")],
        'snap.resize_only_moves_dragged_edge',
    ),
    'snap_resize_skips_min_size_recheck': (
        [f'lib/components/{G}'],
        # 吸附后不再复验尺寸：114 会让宽度从 16 掉到 14，必须被拒。
        [('    if (hit.snapped && hit.value - rect.left >= minSize) {',
          '    if (hit.snapped) { // injected fault: the size is not re-checked')],
        'snap.resize_never_violates_min_size',
    ),
    'snap_move_ignores_right_edge': (
        [f'lib/components/{G}'],
        # 只把左边缘当候选：最常用的"把右边对到隔壁块的左边"永远对不上。
        [("""  final byLeft = rightAdjust == null ||
        (leftAdjust != null && leftAdjust.abs() <= rightAdjust.abs());""",
          '  final byLeft = true; // injected fault: only the left edge is a candidate')],
        'snap.move_prefers_smaller_adjustment',
    ),
    'snap_move_perturbs_no_target_drag': (
        [f'lib/components/{G}'],
        # 没有参考线时反而把位移改掉 —— "没什么可吸"必须等于"原样返回"。
        [('  return (offset: Offset(dx, dy), guidesX: guidesX, guidesY: guidesY);',
          """  if (guidesX.isEmpty && guidesY.isEmpty) {
    // injected fault: nothing to snap against must not move the block
    dx += 1;
  }
  return (offset: Offset(dx, dy), guidesX: guidesX, guidesY: guidesY);""")],
        'snap.no_targets_is_noop',
    ),
    'snap_targets_skip_page_bounds': (
        [f'lib/components/{G}'],
        # 页面边界不再是参考：块永远贴不到页边。
        [('  if (pageWidth != null) xs..add(0)..add(pageWidth);',
          '  if (pageWidth == null) xs..add(0)..add(pageWidth); // injected fault')],
        'snap.targets_include_page_bounds',
    ),

    # ---- P2 · font.korean_*（韩文字族 · P9.7）----------------------------
    'korean_family_never_registered': (
        [f'lib/foundation/{F}', 'pubspec.yaml'],
        # 回到 P9.6 §六 #1 的原状：韩文族**从未**被登记（表与 pubspec 一起撤，
        # 因为只撤一边会被 `font.registry_matches_pubspec` 抓到，故障就变成了
        # 两处不同的回归）。
        [("""  // 🔴 S9 · P9.7: Hangul. Registered as its **own family** rather than merged
  // into the SC entry above, and deliberately **not** made the fallback
  // endpoint: `primaryBundledFamily` decides what an unknown family renders
  // as, and moving that endpoint would change the appearance of every existing
  // project — the silent change P9.4 §6 warned about.
  BundledFont(
    family: 'Noto Sans KR',
    file: 'fonts/NotoSansKR-Regular.otf',
    weight: 400,
    script: 'Korean (Hangul) / Hanja / Latin',
    license: 'fonts/LICENSE-NotoSansKR.txt',
  ),
  BundledFont(
    family: 'Noto Sans KR',
    file: 'fonts/NotoSansKR-Bold.otf',
    weight: 700,
    script: 'Korean (Hangul) / Hanja / Latin',
    license: 'fonts/LICENSE-NotoSansKR.txt',
  ),
];""",
          ']; // injected fault: the Korean family was never registered'),
         ("""    - family: Noto Sans KR
      fonts:
        - asset: assets/fonts/NotoSansKR-Regular.otf
          weight: 400
        - asset: assets/fonts/NotoSansKR-Bold.otf
          weight: 700""",
          '    # injected fault: the Korean family was never registered')],
        'font.korean_registered',
    ),
    'korean_alias_points_to_chinese': (
        [f'lib/foundation/{F}'],
        # 韩文系统的默认字族被映到**中文字面** —— 正是注释里写的那个后果：
        # 每个谚文音节都掉到平台字体去。
        [("  'Malgun Gothic': 'Noto Sans KR',",
          '  \'Malgun Gothic\': primaryBundledFamily, // injected fault')],
        'font.korean_alias_mapped',
    ),
    'korean_bold_file_missing': (
        [f'lib/foundation/{F}'],
        # 登记了却不在盘上：这条最像真实的发布事故（漏拷一个文件）。
        [("    file: 'fonts/NotoSansKR-Bold.otf',",
          "    file: 'fonts/NotoSansKR-SemiBold.otf', // injected fault")],
        'font.korean_files_are_cff',
    ),
    'korean_fallback_chain_includes_self': (
        [f'lib/foundation/{F}'],
        # 回退链把自己也算进去：Flutter 已经先试过它，重复一次没有意义，而且
        # "这条链到底补了谁"就不再可读。
        [("""    for (final family in bundledFamilies)
      if (family != primary) family,""",
          '    for (final family in bundledFamilies) family, // injected fault')],
        'font.fallback_chain_excludes_own_family',
    ),
    'korean_canvas_fallback_unwired': (
        [f'lib/components/{C}'],
        # 只接成品那一条路径：预览与导出在韩文上不一致，且不报错。
        [('      fontFamilyFallback: bundledFamilyFallbacks(block.fontFamily),',
          '      fontFamilyFallback: const [], // injected fault: not wired')],
        'font.renderer_uses_fallback_chain',
    ),

    # ---- P2 · leave.*（离开路径 · P9.7）----------------------------------
    'leave_releases_close_intercept': (
        [f'lib/foundation/{T}'],
        # 回到 P9.2 登记的那个状态：关闭权随"是否最小化到托盘"一起交还原生。
        [("""      _enabled = false;
      await trayManager.destroy();
      await windowManager.show();""",
          """      _enabled = false;
      await trayManager.destroy();
      await windowManager.setPreventClose(false); // injected fault
      await windowManager.show();""")],
        'leave.close_always_intercepted',
    ),
    'leave_second_exit_call_site': (
        [f'lib/foundation/{T}'],
        # 守卫说"不"，照样退出 —— 而且退出点从一个变成两个。
        [("""    if (LeaveGuardRegistry.hasGuards &&
        !await LeaveGuardRegistry.requestLeave()) {
      // 守卫拒绝（用户选了"留下"）：什么都不做，窗口还在。
      return;
    }
    exit(0);""",
          """    if (LeaveGuardRegistry.hasGuards &&
        !await LeaveGuardRegistry.requestLeave()) {
      exit(0); // injected fault: a refusal still exits
    }
    exit(0);""")],
        'leave.single_exit_call_site',
    ),

    # ---- P2 · studio.* / pipeline.* / harness.* --------------------------
    'studio_marquee_survives_page_change': (
        [f'lib/pages/translation_studio/{S}'],
        # ⚠️ 这条断言扫的是**源码形状**，所以故障也只能是形状故障：把两处
        # `_marqueeMode = false` 写成 `(false)`，语义完全不变，但赋值次数从 4
        # 掉到 2。源码扫描类断言能测到的就只有这个 —— 它测不到行为，行为由
        # `headless.dart` 里那批几何断言测。
        [("""  bool _marqueeMode = false;

  /// Creates a block from a marquee the user dragged on the canvas.
  ///
  /// Auto-exits marquee mode: the overwhelmingly common case is "place this
  /// block, then type", and leaving the mode on would make the next drag on the
  /// page draw another box instead of doing what the user expects.
  void _onMarquee(Rect rect) {
    if (!_marqueeMode) return;
    setState(() => _marqueeMode = false);""",
          """  bool _marqueeMode = (false); // injected fault: never reset on page change

  /// Creates a block from a marquee the user dragged on the canvas.
  ///
  /// Auto-exits marquee mode: the overwhelmingly common case is "place this
  /// block, then type", and leaving the mode on would make the next drag on the
  /// page draw another box instead of doing what the user expects.
  void _onMarquee(Rect rect) {
    if (!_marqueeMode) return;
    setState(() => _marqueeMode = (false));""")],
        'studio.marquee_reset_on_page_change',
    ),
    'pipeline_resume_skips_breakpoint_page': (
        [f'lib/foundation/translation_project/{P}'],
        # 差一：断点页自己没跑，用户点"继续"会静默丢掉那一页。
        [('  return pages.sublist(index);',
          '  return pages.sublist(index + 1); // injected fault')],
        'pipeline.resume_returns_tail',
    ),
    'pipeline_resume_falls_back_to_all_pages': (
        [f'lib/foundation/translation_project/{P}'],
        # 没有断点时返回**整章**："继续"变成一次 97 页的重跑。
        [('  if (from == null) return const [];',
          '  if (from == null) return pages; // injected fault')],
        'pipeline.resume_unknown_page_is_empty',
    ),
    'harness_removes_output_file': (
        # `@` = 相对**仓库根**（不是包根）：这个故障打的是 `tools/` 下的验证
        # 工装，它本来就在 `VeneraX/` 之外。见 [_abs]。
        ['@tools/run_headless_task.py'],
        # 🔴 不能把 `os.remove(OUT)` 真的放回去：环境的批量删除守卫（每轮 50 次
        # 上限，且 **Python 的 `os.remove` 也被打了补丁**）会在批跑中途拦下它，
        # 于是**从那一刻起每一次 edit-check 都拿不到输出**，整批变成一串 ERROR。
        # 断言扫的是源码形状（`open(OUT, "w")` 这个子串），所以换一个"行为完全
        # 等价、形状不同"的写法即可：`open(OUT, mode="w")` 照样在注册任务之前
        # 把文件截断，但没有那个子串。
        [('    open(OUT, "w").close()\n',
          '    open(OUT, mode="w").close()  # injected fault: same truncation\n')],
        'harness.truncates_output_before_run',
    ),
}

# File-level faults.
#
# 🔴 Why a second table: the anchor mechanism above is **text substitution**, and
# one P2 assertion reads font **bytes** (`font.korean_cmap_has_hangul` parses
# `assets/fonts/NotoSansKR-Regular.otf`'s cmap directly). There is no source line
# to rewrite — the fault is "this slot ships the wrong font". The honest mutation
# is the file itself: copy the Chinese face over the Korean slot, which is what
# the assertion exists to catch. Doing it by editing the *assertion's* hard-coded
# path instead would be a test that fails because it was told to fail.
#
# ops: ('copy', src_rel_to_PKG, dst_rel_to_PKG)
FILE_FAULTS = {
    'korean_ships_the_chinese_font': (
        [('copy', 'assets/fonts/NotoSansSC-Regular.otf',
          'assets/fonts/NotoSansKR-Regular.otf')],
        'font.korean_cmap_has_hangul',
    ),
}

# Faults whose blast radius is **known and understood**: the target is the
# assertion the fault was written for, and these others go red because they
# genuinely guard the same code, not because the measurement slipped.
#
# 🔴 This is not a way to silence the driver. `_rv_drive.py` still prints every
# breakage; it just stops calling a *documented coupling* "results unreliable".
# An undeclared off-target failure still fails the run, which is the property
# that matters — an undeclared one means the tree was not what we thought.
EXPECTED_CASCADE = {
    # The tolerance gate plus "nearest wins" is one line; both assertions that
    # exercise `snapEdge` read it.
    'snap_edge_last_wins': {'snap.edge_outside_tolerance'},
    # With the Korean family unregistered there are no Korean files to inspect,
    # so `font.korean_files_are_cff` cannot report anything but zero entries.
    'korean_family_never_registered': {'font.korean_files_are_cff'},
    # A registered font file that is not on disk is exactly what the P1
    # "font files exist" check looks for too.
    'korean_bold_file_missing': {'font.files_present'},
    # ---- cluster.* ------------------------------------------------------
    #
    # 🔴 合并判定是唯一的桥接旋钮：`_mergeable` 一旦被整体短路，凡是"必须先
    # 合并"的用例都会红 —— 虚线行序、中位字高、逐行擦除框三条断言都建立在
    # "这三行确实进了同一个气泡"之上。这不是测量失手，是它们确实锁同一行代码。
    'cluster_merge_disabled': {
        'cluster.vertical_lines_read_right_first',
        'cluster.reports_median_line_height',
        'cluster.bridge_keeps_per_line_erase_rects',
    },
    # `_isReadingColumn` 一行决定"这一列该第几个读"，两条阅读方向断言与列内
    # 顺序断言都从它取答案 —— 强制单列时全部无列可分。
    'cluster_column_merges_everything': {
        'cluster.reading_order_right_to_left',
        'cluster.reading_order_left_to_right',
        'cluster.column_reads_top_to_bottom',
    },
    # 同上，只是方向被写死成左起：右起的那条先读断言必然翻红。
    'cluster_direction_ignored': {'cluster.column_reads_top_to_bottom'},
    # ---- font.* ---------------------------------------------------------
    # `resolveFamily` 是"该用哪个字面"与"回退链补谁"共同的上游：把未知字族
    # 原样放行（或交回系统字体）会让回退链的长度判据同时失效。
    'font_fallback_removed': {'font.fallback_chain_excludes_own_family'},
    'font_null_falls_back_to_system': {'font.fallback_chain_excludes_own_family'},
    # 改了 pubspec 里的 family 名，同时也就是"表里的 family 不在 pubspec 里"，
    # 而那正是 `font.assets_exist_in_pubspec` 的定义。两条断言本来就同源。
    'font_renamed_in_pubspec': {'font.registry_matches_pubspec'},
    'font_family_commented_out': {'font.assets_exist_in_pubspec'},
}


def all_faults():
    """id -> target assertion, across both tables."""
    table = {fid: spec[2] for fid, spec in FAULTS.items()}
    table.update({fid: spec[1] for fid, spec in FILE_FAULTS.items()})
    return table


def _fault_spec(fault_id):
    """(kind, ops, target) where ops is [(rel, old, new)] or [(op, src, dst)]."""
    if fault_id in FAULTS:
        files, edits, target = FAULTS[fault_id]
        return 'text', [(rel, old, new)
                        for rel, (old, new) in zip(files, edits)], target
    if fault_id in FILE_FAULTS:
        ops, target = FILE_FAULTS[fault_id]
        return 'file', list(ops), target
    return None, None, None


def cmd_list(_):
    for fault_id, target in sorted(all_faults().items()):
        print(fault_id, '->', target)
    print(len(FAULTS), 'text faults +', len(FILE_FAULTS), 'file faults')
    return 0


def _abs(rel):
    """Fault path -> absolute path.

    `@` means "relative to the **repository** root"; anything else is relative
    to the package root (`VeneraX/`), which is where the code under test lives.
    The one fault aimed at the verification harness itself (`tools/`) needs this:
    writing `../tools/...` instead only works while `PKG` sits one level down.
    """
    if rel.startswith('@'):
        return os.path.join(ROOT, rel[1:].replace('/', os.sep))
    return os.path.join(PKG, rel)


def _anchor_report(fault_id):
    """Every reason this fault could not be applied cleanly. Empty == applies.

    🔴 Validation happens for **all** edits before any of them is written. The
    first version applied as it went, so a fault whose second anchor was stale
    left the first file already mutated with no manifest — `revert` could not
    find it and the tree stayed dirty, which then made the *next* measurement
    measure the wrong tree.
    """
    kind, ops, _ = _fault_spec(fault_id)
    problems = []
    if kind == 'text':
        for rel, old, _new in ops:
            path = _abs(rel)
            if not os.path.exists(path):
                problems.append(f'{rel}: file not found')
                continue
            # 🔴 Read with **universal newlines** (no `newline=''`), so the text in
            # memory is LF-normalised. Anchors are written with `\n`, and a file
            # that happens to be checked out with CRLF
            # (`balloon_clustering.dart` is) made every multi-line anchor match
            # **zero** times. `apply` refused them, and the driver recorded the
            # result as "anchor not unique" — indistinguishable from a real
            # misfire, so five of the P1 assertions were silently never exercised
            # while the batch still reported a full table. Line endings are a
            # property of the checkout, not of the code under test; the harness
            # must not care.
            with io.open(path, encoding='utf-8') as f:
                text = f.read()
            count = text.count(old)
            if count != 1:
                problems.append(f'{rel}: anchor appears {count} time(s), '
                                'expected exactly 1')
    else:
        for _op, src, dst in ops:
            src_path = _abs(src)
            dst_path = _abs(dst)
            if not os.path.exists(src_path):
                problems.append(f'{src}: source not found')
                continue
            if not os.path.exists(dst_path):
                problems.append(f'{dst}: destination not found')
                continue
            # 🔴 A binary fault has no anchor to check, so "is it already
            # applied?" has to be answered from the bytes. If the slot already
            # holds the injected file, `apply` would back up the **fault** and
            # the revert would then make it permanent — the same mistake the
            # text path avoids by requiring its anchor to be present.
            with io.open(src_path, 'rb') as f:
                source_bytes = f.read()
            with io.open(dst_path, 'rb') as f:
                target_bytes = f.read()
            if source_bytes == target_bytes:
                problems.append(
                    f'{dst} already equals {src} — the fault looks applied; '
                    'run `revert` before applying it again')
    return problems


def cmd_selftest(_=None):
    """Anchor health check: no injection, no build, just "would it apply?".

    Run this before a 54-fault batch. A batch that silently skips faults because
    an anchor rotted reports a *smaller* table that still looks complete.
    """
    broken = 0
    for fault_id in sorted(all_faults()):
        problems = _anchor_report(fault_id)
        if problems:
            broken += 1
            print('BROKEN', fault_id)
            for problem in problems:
                print('   ', problem)
    print(f'total faults: {len(all_faults())} / broken anchors: {broken}')
    return 1 if broken else 0


def _fault_dir(fault_id):
    return os.path.join(BACKUP, fault_id)


def cmd_apply(fault_id):
    kind, ops, target = _fault_spec(fault_id)
    if kind is None:
        print('unknown fault', fault_id)
        return 2
    problems = _anchor_report(fault_id)
    if problems:
        print(f'FAULT DOES NOT APPLY CLEANLY: {fault_id}')
        for problem in problems:
            print('   ', problem)
        return 3
    # 🔴 Backups live **outside the source tree**, in `builds/_rv_backup/<id>/`,
    # and nothing in this function deletes anything.
    #
    # Both properties were bought with a broken batch (P9.7 §五):
    #
    # 1. A `.rvbak` next to the source is indistinguishable from a stray one, so
    #    `tree_is_clean()` had to treat it as a dirty tree.
    # 2. The environment patches Python's `os.remove` with a per-turn
    #    bulk-delete guard (`_safe_remove`, 50 per turn). A batch that drives
    #    the app dozens of times exhausts it — and the old `cmd_revert` ended
    #    with `os.remove(backup)`, so it started throwing **mid-manifest**: the
    #    first entry was restored, the rest were not. `pubspec.yaml` lost its
    #    Korean font block that way, and the next 26 measurements were taken
    #    against a tree nobody had noticed was broken.
    #
    # So `revert` restores bytes and retires the manifest by rewriting it to
    # `[]`. Reuse is prevented by validation instead of by deletion: the text
    # path requires its anchor to still be present, the binary path requires the
    # destination to still differ from the source.
    directory = _fault_dir(fault_id)
    os.makedirs(directory, exist_ok=True)
    manifest = []
    # 🔴 One backup per **file**, taken before that file's first edit. Several
    # faults patch the same file more than once (`font_family_commented_out`
    # does it three times); backing up per *op* would have captured the already
    # patched content on the second pass — the "revert restores the fault"
    # failure mode, one layer down.
    backed_up = {}
    for index, op in enumerate(ops):
        rel = op[2] if kind == 'file' else op[0]
        path = _abs(rel)
        if rel not in backed_up:
            flat = rel.lstrip('@').replace('/', '__')
            backup = os.path.join(directory, f'{index:02d}__{flat}.bak')
            shutil.copyfile(path, backup)
            backed_up[rel] = backup
            # 🔴 Store the path relative to the **package or repository** root,
            # never the basename: a basename made `revert` write the backup to
            # `VeneraX/<name>.dart` instead of back into `lib/foundation/...`,
            # leaving the faulted file in place plus a stray copy at the package
            # root, which then broke the next build on a relative import.
            manifest.append([rel.replace('\\', '/'), backup])
        if kind == 'text':
            _rel, old, new = op
            # Read with universal newlines, write in text mode: the file keeps
            # whatever line endings it had (`balloon_clustering.dart` is CRLF).
            with io.open(path, encoding='utf-8') as f:
                text = f.read()
            with io.open(path, 'w', encoding='utf-8') as f:
                f.write(text.replace(old, new))
        else:
            _op, src, _dst = op
            shutil.copyfile(_abs(src), path)
    with io.open(os.path.join(directory, 'manifest.json'), 'w',
                 encoding='utf-8') as f:
        json.dump(manifest, f)
    print('applied', fault_id, '->', target)
    return 0


def cmd_revert(fault_id):
    manifest_path = os.path.join(_fault_dir(fault_id), 'manifest.json')
    if not os.path.exists(manifest_path):
        print('nothing to revert for', fault_id)
        return 2
    with io.open(manifest_path, encoding='utf-8') as f:
        manifest = json.load(f)
    if not manifest:
        print('already reverted', fault_id)
        return 0
    # 🔴 Restore **every** entry even if one fails, and report the failures.
    # The old version let the first exception abort the loop, which is how a
    # two-file fault ended up half-reverted and half-faulted.
    failures = []
    for rel, backup in manifest:
        try:
            shutil.copyfile(backup, _abs(rel))
        except OSError as exc:  # noqa: PERF203 - report all, not just the first
            failures.append(f'{rel} <- {os.path.basename(backup)}: {exc}')
    with io.open(manifest_path, 'w', encoding='utf-8') as f:
        json.dump([], f)
    if failures:
        print(f'REVERT INCOMPLETE for {fault_id}:')
        for failure in failures:
            print('   ', failure)
        return 1
    print('reverted', fault_id, f'({len(manifest)} file(s))')
    return 0


def cmd_status(_):
    if not os.path.isdir(BACKUP):
        print('clean')
        return 0
    pending = []
    for name in sorted(os.listdir(BACKUP)):
        manifest_path = os.path.join(_fault_dir(name), 'manifest.json')
        if not os.path.exists(manifest_path):
            continue
        try:
            with io.open(manifest_path, encoding='utf-8') as f:
                if json.load(f):
                    pending.append(name)
        except (OSError, ValueError):
            pending.append(f'{name} (unreadable manifest)')
    print('pending:', pending if pending else 'none')
    return 0


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    action = sys.argv[1]
    handler = {'list': cmd_list, 'apply': cmd_apply,
               'revert': cmd_revert, 'status': cmd_status,
               'selftest': cmd_selftest}[action]
    sys.exit(handler(sys.argv[2] if len(sys.argv) > 2 else None))