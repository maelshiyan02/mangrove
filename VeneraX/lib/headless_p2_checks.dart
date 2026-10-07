// S9 · 第 2 批 🟡 P2 的断言（P9.7）：吸附几何 · 韩文字族 · 离开路径 · 断点续跑 · 工装。
//
// 与 `headless_p1_checks.dart` 分开的理由相同（见该文件开头）：断言该是"能加"
// 的东西，而不是"想加要先动核心文件"的东西。
//
// 🔴 本文件里有两类断言，纪律不同，都必须满足"空结果判 FAIL"：
//
// 1. **纯函数断言**（吸附、断点、字体表）：直接调代码，输入是写死的人造数据，
//    输出可逐一核对。这类断言最容易写对，也最容易写成"只锁住我这次实现"——
//    所以每条都配了一个**反向**用例（容差外不吸、断点不在页集里返回空…）。
// 2. **源码/资产断言**（离开路径、工装、渲染器接线）：它们锁的是"某处必须
//    保持某种形状"，而扫不到东西时**必须 FAIL**。P9.3 的假绿就是扫了个空目录
//    还返回 true；这里每个扫描都先证明文件本身非空。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:venera/components/block_resize_geometry.dart';
import 'package:venera/foundation/bundled_fonts.dart';
import 'package:venera/foundation/translation_project/studio_pipeline.dart';

import 'headless_p1_checks.dart' show CheckSink;

/// 运行每一条 P2 断言。[packageRoot] 是含 `pubspec.yaml` 的目录。
///
/// [reverseVerified] 是调用方确认"注入故障后真的 FAIL"过的断言名（见
/// `docs/P9.7`）。它被当成一条断言来检查 —— "我手工跑过一次"要变成可复算的
/// 事实，而不是一个承诺。
void runP2Checks(
  CheckSink check, {
  required Directory packageRoot,
  required List<String> reverseVerified,
}) {
  _snapChecks(check);
  _koreanFontChecks(check, packageRoot);
  _leavePathChecks(check, packageRoot);
  _studioSourceChecks(check, packageRoot);
  _resumeChecks(check);
  _harnessChecks(check, packageRoot);
  _p2ReverseVerification(check, reverseVerified);
}

// ---------------------------------------------------------------------------
// 吸附（P9.3 登记的「缩放不吸附」）
// ---------------------------------------------------------------------------

void _snapChecks(CheckSink check) {
  // 1) 容差内必须吸。
  final hit = snapEdge(103, const [100, 300], resizeSnapTolerance);
  check(
    'snap.edge_within_tolerance',
    hit.snapped && hit.value == 100,
    '103 with targets [100,300] tol 4 -> ${hit.value} snapped=${hit.snapped}',
  );

  // 2) 🔴 反面：容差外必须**不**吸。只测"会吸"的断言在"参数被写成 ∞"时照样
  //    通过 —— 而那正是吸附最坏的样子（拖到哪都跳）。
  final miss = snapEdge(110, const [100], resizeSnapTolerance);
  check(
    'snap.edge_outside_tolerance',
    !miss.snapped && miss.value == 110,
    '110 with target [100] tol 4 -> ${miss.value} snapped=${miss.snapped}',
  );

  // 3) 只有被 handle 拖的那条边会动，另一条必须原地不动。
  final start = Rect.fromLTRB(100, 100, 200, 200);
  final resized = snapResize(
    start: start,
    handle: ResizeHandle.right,
    delta: const Offset(98, 0),
    targetsX: const [300],
  );
  check(
    'snap.resize_only_moves_dragged_edge',
    resized.rect.left == 100 &&
        resized.rect.right == 300 &&
        resized.rect.top == 100 &&
        resized.rect.bottom == 200 &&
        resized.guidesX.length == 1 &&
        resized.guidesX.first == 300 &&
        resized.guidesY.isEmpty,
    'rect=${_rectText(resized.rect)} guidesX=${resized.guidesX}',
  );

  // 4) 🔴 吸附发生在 `minSize` 夹取**之后**，所以它可能把尺寸压到最小之下。
  //    这里的目标坐标 114 会让宽度变成 14（< 16），必须被拒并退回吸附前的值，
  //    同时**不报 guide** —— 报了一条没生效的参考线比不报更误导。
  final tight = snapResize(
    start: Rect.fromLTRB(100, 100, 120, 120),
    handle: ResizeHandle.right,
    delta: const Offset(-16, 0),
    targetsX: const [114],
  );
  check(
    'snap.resize_never_violates_min_size',
    tight.rect.right == 116 && tight.rect.width >= 16 && tight.guidesX.isEmpty,
    'right=${tight.rect.right} width=${tight.rect.width} '
    'guides=${tight.guidesX} (114 would make it 14)',
  );

  // 5) 移动时两条边都是候选，取调整量更小的那条 —— 否则"把右边缘对到隔壁块的
  //    左边缘"永远对不上，而那是最常用的对齐方式（两块并排）。
  final moved = snapMove(
    start: Rect.fromLTRB(100, 100, 200, 200),
    offset: const Offset(57, 0),
    targetsX: const [160, 258],
  );
  check(
    'snap.move_prefers_smaller_adjustment',
    moved.offset.dx == 58 &&
        moved.guidesX.length == 1 &&
        moved.guidesX.first == 258,
    'moved box (157,257) targets [160,258] -> dx=${moved.offset.dx} '
    'guides=${moved.guidesX} (left would need +3, right only +1)',
  );

  // 6) 没有参考坐标时必须原样返回，且不报 guide。
  final noTargets = snapMove(
    start: start,
    offset: const Offset(7, -3),
  );
  check(
    'snap.no_targets_is_noop',
    noTargets.offset == const Offset(7, -3) &&
        noTargets.guidesX.isEmpty &&
        noTargets.guidesY.isEmpty,
    'offset=${_offsetText(noTargets.offset)} guides='
    '${noTargets.guidesX}/${noTargets.guidesY}',
  );

  // 7) 页面边界也是参考（0 与页宽/页高）。少了它，块永远无法精确贴边。
  final targets = snapTargets(
    const [Rect.fromLTRB(10, 20, 30, 40)],
    pageWidth: 900,
    pageHeight: 1778,
  );
  check(
    'snap.targets_include_page_bounds',
    targets.xs.contains(0) &&
        targets.xs.contains(900) &&
        targets.xs.contains(10) &&
        targets.ys.contains(40) &&
        targets.ys.contains(1778),
    'xs=${targets.xs} ys=${targets.ys}',
  );
}

// ---------------------------------------------------------------------------
// 韩文字族（P9.6 §六 #1 登记的最硬缺口）
// ---------------------------------------------------------------------------

void _koreanFontChecks(CheckSink check, Directory root) {
  const korean = 'Noto Sans KR';

  // 8) 注册了，且**没有**把回退终点搬走。
  final families = bundledFamilies;
  check(
    'font.korean_registered',
    families.contains(korean) && families.contains(primaryBundledFamily),
    'bundled families=$families primary=$primaryBundledFamily '
    '(moving the primary would change every existing project)',
  );

  // 9) 韩文系统的默认字族必须被认识 —— 这是 P9.6 那条雅黑别名的同一件事。
  final malgun = resolveFamily('Malgun Gothic');
  final hangulName = resolveFamily('맑은 고딕');
  check(
    'font.korean_alias_mapped',
    malgun.family == korean &&
        malgun.fallback &&
        hangulName.family == korean &&
        hangulName.fallback,
    '"Malgun Gothic" -> ${malgun.family} '
    '(fallback=${malgun.fallback}); "맑은 고딕" -> ${hangulName.family}',
  );

  // 10) 文件真的在盘上、够大、是 CFF、扩展名诚实。
  final koreanFonts = [
    for (final font in bundledFonts)
      if (font.family == korean) font,
  ];
  final problems = <String>[];
  for (final font in koreanFonts) {
    final file = File('${root.path}/assets/${font.file}');
    if (!file.existsSync()) {
      problems.add('${font.file} missing');
      continue;
    }
    final bytes = file.readAsBytesSync();
    if (bytes.length < 100000) {
      problems.add('${font.file} only ${bytes.length}B');
    }
    final tag = String.fromCharCodes(bytes.take(4));
    if (tag != 'OTTO') problems.add('${font.file} sfnt=$tag');
    if (!font.file.endsWith('.otf')) problems.add('${font.file} not .otf');
  }
  check(
    'font.korean_files_are_cff',
    koreanFonts.length == 2 && problems.isEmpty,
    koreanFonts.length != 2
        ? 'expected 2 Noto Sans KR entries, found ${koreanFonts.length}'
        : problems.isEmpty
        ? '${koreanFonts.length} CFF (.otf) files present'
        : problems.join('; '),
  );

  // 11) 🔴 直接读 cmap：KR 有韩文音节、SC 没有 —— 而 SC 没有正是不用它的原因。
  //
  //    非空判据：两张表的 format 12 都必须覆盖 > 10000 个码位。解析失败会得到
  //    0，于是这条断言 FAIL —— 而不是"两个 0 相等"式的假通过。
  final koreanCmap = _cmap12(File('${root.path}/assets/fonts/NotoSansKR-Regular.otf'));
  final chineseCmap =
      _cmap12(File('${root.path}/assets/fonts/NotoSansSC-Regular.otf'));
  final koreanHasHangul =
      koreanCmap.glyph(0xD55C) != null && koreanCmap.glyph(0xAE00) != null;
  check(
    'font.korean_cmap_has_hangul',
    koreanCmap.covered > 10000 &&
        chineseCmap.covered > 10000 &&
        koreanHasHangul &&
        chineseCmap.glyph(0xD55C) == null,
    'KR covered=${koreanCmap.covered} U+D55C=${koreanCmap.glyph(0xD55C)} '
    'U+AE00=${koreanCmap.glyph(0xAE00)}; SC covered=${chineseCmap.covered} '
    'U+D55C=${chineseCmap.glyph(0xD55C)}',
  );

  // 12) 回退链必须"补齐互补字面、但不重复自己"。
  final chainProblems = <String>[];
  for (final requested in <String?>[
    null,
    '',
    primaryBundledFamily,
    korean,
    'Microsoft YaHei UI',
    'No Such Face At All',
  ]) {
    final resolved = resolveFamily(requested).family;
    final chain = bundledFamilyFallbacks(requested);
    if (chain.contains(resolved)) {
      chainProblems.add('"$requested" -> $resolved appears in its own chain');
    }
    if (chain.toSet().length != chain.length) {
      chainProblems.add('"$requested" chain has duplicates: $chain');
    }
    if (chain.length != bundledFamilies.length - 1) {
      chainProblems.add(
        '"$requested" chain length ${chain.length}, expected '
        '${bundledFamilies.length - 1}',
      );
    }
  }
  check(
    'font.fallback_chain_excludes_own_family',
    chainProblems.isEmpty,
    chainProblems.isEmpty
        ? '${bundledFamilies.length} families, every chain excludes its own '
            'resolved family'
        : chainProblems.join('; '),
  );

  // 13) 两条渲染路径都必须真的**接线**到那条链。两条路径不共享代码（P9.4 §6），
  //     所以只接一条 = 预览与成品在韩文上不一致 —— 静默的。
  final wiring = <String, String>{
    'lib/foundation/image_translation/page_renderer.dart': 'product renderer',
    'lib/components/text_block_canvas.dart': 'studio canvas',
  };
  final unwired = <String>[];
  for (final entry in wiring.entries) {
    final source = _readFile(root, entry.key);
    if (source.isEmpty || !source.contains('bundledFamilyFallbacks')) {
      unwired.add('${entry.value} (${entry.key})');
    }
  }
  check(
    'font.renderer_uses_fallback_chain',
    unwired.isEmpty,
    unwired.isEmpty
        ? 'both render paths call bundledFamilyFallbacks'
        : 'NOT wired: ${unwired.join(", ")}',
  );
}

// ---------------------------------------------------------------------------
// 离开路径（P9.2 登记的 Alt+F4 / 托盘退出缺口）
// ---------------------------------------------------------------------------

void _leavePathChecks(CheckSink check, Directory root) {
  final tray = _codeOnly(_readFile(root, 'lib/foundation/tray.dart'));

  // 14) 关闭拦截**永远**开着。原实现把它和"是否最小化到托盘"绑在一起，
  //     于是没有托盘的机器上 Alt+F4 直接退出进程，守卫根本收不到通知。
  final opens = 'setPreventClose(true)'.allMatches(tray).length;
  final closes = 'setPreventClose(false)'.allMatches(tray).length;
  check(
    'leave.close_always_intercepted',
    tray.isNotEmpty && opens == 1 && closes == 0,
    tray.isEmpty
        ? 'tray.dart not found — the scan would pass vacuously'
        : 'setPreventClose(true) x$opens, setPreventClose(false) x$closes '
            '(放行关闭 = 交出拦截权 = 守卫收不到通知)',
  );

  // 15) 退出只有一个出口，且它先问守卫。两条出口（托盘"退出"与关闭）各写一次
  //     `exit(0)` 的话，改一处就会漏另一处。
  final exits = RegExp(r'\bexit\(0\)').allMatches(tray).length;
  check(
    'leave.single_exit_call_site',
    tray.isNotEmpty && exits == 1 && tray.contains('LeaveGuardRegistry'),
    tray.isEmpty
        ? 'tray.dart not found — the scan would pass vacuously'
        : 'exit(0) x$exits, asks LeaveGuardRegistry='
            '${tray.contains('LeaveGuardRegistry')}',
  );
}

// ---------------------------------------------------------------------------
// 工作室：框选模式必须随翻页复位（P9.3 登记）
// ---------------------------------------------------------------------------

void _studioSourceChecks(CheckSink check, Directory root) {
  final page = _readFile(root, 'lib/pages/translation_studio/studio_page.dart');

  // 16) 三次赋值 = 字段声明 1 次 + `_selectPage` 1 次 + 长画布 `onPageChanged`
  //     1 次。只做一处的话这里是 2，断言 FAIL。
  final resets = '_marqueeMode = false'.allMatches(page).length;
  check(
    'studio.marquee_reset_on_page_change',
    page.isNotEmpty && resets >= 3,
    page.isEmpty
        ? 'studio_page.dart not found — the scan would pass vacuously'
        : '_marqueeMode = false x$resets (needs decl + _selectPage + '
            'onPageChanged; two page-change paths must both clear it)',
  );
}

// ---------------------------------------------------------------------------
// 断点续跑（P9.6 §六 #7）
// ---------------------------------------------------------------------------

void _resumeChecks(CheckSink check) {
  final pages = <String>['0/1.webp', '0/2.webp', '0/3.webp'];

  // 17) 断点之后（含断点页本身）才是要跑的页。
  final tail = resumePages(pages, '0/2.webp');
  check(
    'pipeline.resume_returns_tail',
    tail.length == 2 &&
        tail.first == '0/2.webp' &&
        tail.last == '0/3.webp' &&
        pages.length == 3,
    'from 0/2.webp -> $tail (input must not be mutated; still ${pages.length})',
  );

  // 18) 🔴 反向：断点不在页集里、或压根没有断点，都必须返回**空**。
  //     写成"返回整份 pages"的话，"继续"会静默变成整章重跑 —— 而用户点的
  //     是"继续"。
  final unknown = resumePages(pages, '9/9.webp');
  final none = resumePages(pages, null);
  check(
    'pipeline.resume_unknown_page_is_empty',
    unknown.isEmpty && none.isEmpty,
    'unknown page -> $unknown, no breakpoint -> $none '
    '(must NOT fall back to the whole chapter)',
  );
}

// ---------------------------------------------------------------------------
// 验证工装：陈旧输出竞态（P9.7 的调查中被它误导过一次）
// ---------------------------------------------------------------------------

void _harnessChecks(CheckSink check, Directory root) {
  final source = _codeOnly(_readFile(root, 'tools/run_headless_task.py'));
  final truncates = source.contains('open(OUT, "w")');
  // 批量跑 35 次时 `os.remove` 会触发环境的批量删除保护，第 50 次之后全部被拒。
  final removes = source.contains('os.remove(OUT)');
  check(
    'harness.truncates_output_before_run',
    source.isNotEmpty && truncates && !removes,
    source.isEmpty
        ? 'tools/run_headless_task.py not found — the scan would pass vacuously'
        : 'truncates before run=$truncates, uses os.remove=$removes '
            '(without truncation the first poll reads the previous run)',
  );
}

// ---------------------------------------------------------------------------
// 反向验证记录
// ---------------------------------------------------------------------------

/// 断言名清单必须与"实测 FAIL 过"的清单**相等**。
///
/// 抄的是 P1 的机制，理由也一样：一个空清单会让上面每一条都变成装饰品，
/// 所以空清单本身判 FAIL。
void _p2ReverseVerification(CheckSink check, List<String> reverseVerified) {
  const known = <String>{
    'snap.edge_within_tolerance',
    'snap.edge_outside_tolerance',
    'snap.resize_only_moves_dragged_edge',
    'snap.resize_never_violates_min_size',
    'snap.move_prefers_smaller_adjustment',
    'snap.no_targets_is_noop',
    'snap.targets_include_page_bounds',
    'font.korean_registered',
    'font.korean_alias_mapped',
    'font.korean_files_are_cff',
    'font.korean_cmap_has_hangul',
    'font.fallback_chain_excludes_own_family',
    'font.renderer_uses_fallback_chain',
    'leave.close_always_intercepted',
    'leave.single_exit_call_site',
    'studio.marquee_reset_on_page_change',
    'pipeline.resume_returns_tail',
    'pipeline.resume_unknown_page_is_empty',
    'harness.truncates_output_before_run',
  };
  final notVerified = [
    for (final name in reverseVerified)
      if (!known.contains(name)) name,
  ];
  final notClaimed = [
    for (final name in known)
      if (!reverseVerified.contains(name)) name,
  ];
  check(
    'assertions.p2_reverse_verification_recorded',
    reverseVerified.isNotEmpty && notVerified.isEmpty && notClaimed.isEmpty,
    reverseVerified.isEmpty
        ? 'reverse-verification list is EMPTY — every P2 assertion above is '
            'unverified and may be decorative (this must FAIL)'
        : notVerified.isNotEmpty
        ? 'list names assertions that do not exist: ${notVerified.join(", ")}'
        : notClaimed.isNotEmpty
        ? 'no reverse verification recorded for: ${notClaimed.join(", ")}'
        : '${reverseVerified.length} P2 assertions confirmed FAIL under an '
            'injected fault',
  );
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

/// 读一个相对**仓库根**或包根的文件；读不到返回空串（调用方必须把空判 FAIL）。
String _readFile(Directory packageRoot, String relative) {
  for (final base in [packageRoot.parent.path, packageRoot.path]) {
    final file = File('$base${Platform.pathSeparator}'
        '${relative.replaceAll('/', Platform.pathSeparator)}');
    if (file.existsSync()) return file.readAsStringSync();
  }
  return '';
}

String _rectText(Rect rect) => '${rect.left},${rect.top},'
    '${rect.right},${rect.bottom}';

/// `Offset` has no `toString()` that prints its components (P9.3 §-registered:
/// a detail of `Instance of 'Offset'` makes a failure undiagnosable).
String _offsetText(Offset offset) => '(${offset.dx}, ${offset.dy})';

/// 去掉行注释后再扫。
///
/// 🔴 P9.6 §4.3 踩过这个坑：一条断言本想证明"工作室没有用旧引擎"，结果匹配到的
/// 是**解释"为什么不用"的那句注释**，于是报了一个假 FAIL。这次两处同型：
/// `tray.dart` 的文档注释里写了 `setPreventClose(false)`（说明它已删除），
/// `run_headless_task.py` 的注释里写了 `os.remove(OUT)`（说明为何删掉它）——
/// 两条扫描都把"解释缺席"的文字当成了"缺席"的反面。
///
/// 只按行首剥注释就够：这两个文件里的注释全是行注释（`//`、`///`、`#`）。
/// 块注释要真正的词法器，而这两条检查不值得为它写一个。
String _codeOnly(String source) {
  if (source.isEmpty) return source;
  final kept = <String>[];
  for (final line in source.split('\n')) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('//') ||
        trimmed.startsWith('*') ||
        trimmed.startsWith('#')) {
      continue;
    }
    kept.add(line);
  }
  return kept.join('\n');
}

/// 只读 `format 12` 的 cmap 视图。
///
/// 🔴 **只用 format 12，不用 format 4。** P9.3 那次误诊的根因是自制解析器漏了
/// format 4 的 `idRangeOffset` 指针数组；format 12 是顺序分段表，没有指针，
/// 写错的余地小得多。代价是：如果某个字体只有 format 4 而没有 format 12，
/// 这里会得到 covered == 0 —— 而调用方的 `covered > 10000` 会把那种情况判
/// FAIL，而不是"两个空表相等"式的假通过。
class _Cmap12 {
  _Cmap12(this._groups);

  final List<({int start, int end, int gid0})> _groups;

  /// 覆盖的码位数 —— 调用方用它做**非空判据**（解析失败会得 0）。
  late final int covered = _count();

  int _count() {
    var total = 0;
    for (final group in _groups) {
      total += group.end - group.start + 1;
    }
    return total;
  }

  int? glyph(int codepoint) {
    for (final group in _groups) {
      if (codepoint < group.start || codepoint > group.end) continue;
      final gid = group.gid0 + (codepoint - group.start);
      return gid == 0 ? null : gid;
    }
    return null;
  }
}

_Cmap12 _cmap12(File file) {
  if (!file.existsSync()) return _Cmap12(const []);
  final bytes = file.readAsBytesSync();
  if (bytes.length < 16) return _Cmap12(const []);
  final data = ByteData.sublistView(bytes);
  if (String.fromCharCodes(bytes.take(4)) != 'OTTO' &&
      data.getUint32(0) != 0x00010000) {
    return _Cmap12(const []);
  }
  final tableCount = data.getUint16(4);
  var cmapOffset = -1;
  for (var i = 0; i < tableCount; i++) {
    final record = 12 + i * 16;
    final tag = String.fromCharCodes(bytes.sublist(record, record + 4));
    if (tag == 'cmap') {
      cmapOffset = data.getUint32(record + 8);
      break;
    }
  }
  if (cmapOffset < 0) return _Cmap12(const []);
  final subtables = data.getUint16(cmapOffset + 2);
  for (var i = 0; i < subtables; i++) {
    // 表头是 version(2) + numTables(2) = 4 字节，编码记录从 +4 开始。
    final record = cmapOffset + 4 + i * 8;
    final subtable = cmapOffset + data.getUint32(record + 4);
    if (data.getUint16(subtable) != 12) continue;
    final groups = data.getUint32(subtable + 12);
    final result = <({int start, int end, int gid0})>[];
    for (var g = 0; g < groups; g++) {
      final entry = subtable + 16 + g * 12;
      result.add((
        start: data.getUint32(entry),
        end: data.getUint32(entry + 4),
        gid0: data.getUint32(entry + 8),
      ));
    }
    return _Cmap12(result);
  }
  return _Cmap12(const []);
}

/// 这个断言集自身的版本戳，随 `edit-check` 的 detail 一起报出。
const String p2CheckVersion = 'S9-P2-2026-10-07';
