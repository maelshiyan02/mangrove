// B-2 步骤 b（缝窗口候选识别）+ B-5（跨页块多页产物规划 / 解组 uid 回收）的
// headless 断言集（跨页拼接计划 §4-B2 步骤 b / §4-B5 验收）。
//
// 与 P12/P13 同一纪律：每条断言跑两遍 —— 绿路径喂**真实现**，故障路径喂一个
// **故意写错的实现**，两条路径检验同一个命题；`故障路径=变红` 才说明判据不是
// 装饰品（M08）。
//
// 检测本身（ONNX 在拼接图上出框）、像素解码/出图、人工确认对话框都需要 GUI
// 会话（本会话无渲染表面），不在本文件覆盖范围。
library;

import 'package:mangrove/foundation/image_translation/translation_types.dart'
    show IntRect;
import 'package:mangrove/foundation/translation_project/block_group.dart';
import 'package:mangrove/foundation/translation_project/cross_page_block.dart';
import 'package:mangrove/foundation/translation_project/seam_detect.dart';
import 'package:mangrove/foundation/translation_project/seam_window.dart';
import 'package:mangrove/foundation/translation_project/span_artifacts.dart';
import 'package:mangrove/foundation/translation_project/strip_hidden_pages.dart';
import 'package:mangrove/headless_p1_checks.dart' show CheckSink;

// ── 夹具：§8.3 的两页（p003 / p004，均 1600×2400）──────────────────────

const _bands = <PageBand>[
  PageBand('p003', 1600, 2400),
  PageBand('p004', 1600, 2400),
];

/// 异宽夹具（p003=1600 / pWide=1200）。
const _badWidthBands = <PageBand>[
  PageBand('p003', 1600, 2400),
  PageBand('pWide', 1200, 2400),
];

/// 🔴 IntRect 没有值相等（translation_types.dart），断言只能逐字段比。
bool _sameRect(IntRect a, IntRect b) =>
    a.left == b.left &&
    a.top == b.top &&
    a.right == b.right &&
    a.bottom == b.bottom;

IntRect _pageRectOf(String page) {
  if (page == 'pWide') return IntRect(0, 0, 1200, 2400);
  return IntRect(0, 0, 1600, 2400);
}

SeamWindow get _window => buildSeamWindow(
      pageAHeight: 2400,
      pageBHeight: 2400,
    )!; // 0.35 → top=bottom=840，总高 1680 ≤ 2400 封顶

// ── 1 · 跨缝候选 → 两页子矩形（映射回虚拟坐标无损） ───────────────────

typedef _PlanFn = List<SeamCandidatePlan> Function(List<IntRect> rects);

bool _crossingCandidateMapsToTwoPages(_PlanFn plan) {
  // 跨缝框：窗口内 y ∈ [640, 1140]（缝线 y=840），即页 A 底 200px + 页 B 顶 300px。
  final plans = plan([IntRect(600, 640, 1000, 1140)]);
  if (plans.length != 1) return false;
  final p = plans.single;
  if (p.span.parts.length != 2) return false;
  final a = p.span.parts[0];
  final b = p.span.parts[1];
  if (a.page != 'p003' || b.page != 'p004') return false;
  // base = pageAHeight - topHeight = 1560；窗口 [640,1140] → 虚拟 [2200,2700]
  if (!_sameRect(p.virtualRect, IntRect(600, 2200, 1000, 2700))) return false;
  if (!_sameRect(a.rect, IntRect(600, 2200, 1000, 2400))) return false;
  if (!_sameRect(b.rect, IntRect(600, 0, 1000, 300))) return false;
  // 派生视图往返无损。
  final back = spanToVirtual(p.span, offsetOf: (page) => page == 'p003' ? 0 : 2400);
  return back != null && _sameRect(back, p.virtualRect);
}

/// 故障实现：映射时不减窗口 base（把窗口 y 直接当虚拟 y），顶段整段错位。
List<SeamCandidatePlan> _faultyNoBase(List<IntRect> rects) {
  final window = _window;
  return [
    for (final rect in rects)
      SeamCandidatePlan(
        windowRect: rect,
        virtualRect: IntRect(rect.left, rect.top, rect.right, rect.bottom),
        span: BlockSpan([
          SpanPart('p003', IntRect(rect.left, rect.top, rect.right, 2400)),
          SpanPart(
            'p004',
            IntRect(rect.left, 0, rect.right, rect.bottom - window.topHeight),
          ),
        ]),
      ),
  ];
}

// ── 2 · 只落在一页的候选被丢弃 ─────────────────────────────────────────

bool _singleSideCandidateDropped(_PlanFn plan) {
  // 完全在页 A 条带内（y 100..300，缝线 840）→ 不是跨页候选。
  final topOnly = plan([IntRect(600, 100, 1000, 300)]);
  // 完全在页 B 条带内（y 900..1200）。
  final bottomOnly = plan([IntRect(600, 900, 1000, 1200)]);
  return topOnly.isEmpty && bottomOnly.isEmpty;
}

/// 故障实现：不过滤、不切分，任何框都当跨页候选。
List<SeamCandidatePlan> _faultyKeepsSinglePage(List<IntRect> rects) => [
      for (final rect in rects)
        SeamCandidatePlan(
          windowRect: rect,
          virtualRect: rect,
          span: BlockSpan([
            SpanPart('p003', IntRect(rect.left, rect.top, rect.right, rect.bottom)),
            SpanPart('p004', IntRect(rect.left, 0, rect.right, 10)),
          ]),
        ),
    ];

// ── 3 · 异宽候选被校验剔除 ─────────────────────────────────────────────

bool _invalidWidthRejected(_PlanFn plan) {
  // 🔴 命题必须走**注入的** plan 函数（真规划器 vs 跳过校验的故障版）；
  // 早先版本在这里直接调真 planSeamCandidates，于是故障路径永远"空"，
  // 断言沦为装饰品。
  final plans = plan([IntRect(600, 640, 1000, 1140)]);
  return plans.isEmpty && plan([]).isEmpty;
}

/// 真规划器 + 异宽夹具（绿路径用）。
List<SeamCandidatePlan> _realPlanBadWidth(List<IntRect> rects) =>
    planSeamCandidates(
      windowRects: rects,
      pageAHeight: 2400,
      window: _window,
      bands: _badWidthBands,
      pageRect: _pageRectOf,
    );

/// 故障实现：跳过 validateSpan（异宽也照收）。
List<SeamCandidatePlan> _faultyNoValidate(List<IntRect> rects) {
  final window = _window;
  final plans = <SeamCandidatePlan>[];
  for (final rect in rects) {
    final virtual = windowRectToVirtual(
      rect,
      pageAHeight: 2400,
      window: window,
    );
    plans.add(
      SeamCandidatePlan(
        windowRect: rect,
        virtualRect: virtual,
        span: BlockSpan(splitVirtual(virtual, bands: _badWidthBands)),
      ),
    );
  }
  return plans;
}

// ── 4 · 抹除计划按页摊平 ───────────────────────────────────────────────

typedef _EraseFn = Map<String, List<IntRect>> Function(BlockSpan span);

bool _erasePlanGroupedByPage(_EraseFn fn) {
  final span = BlockSpan([
    SpanPart('p003', IntRect(600, 2200, 1000, 2400)),
    SpanPart('p004', IntRect(600, 0, 1000, 300)),
  ]);
  final plan = fn(span);
  if (plan.length != 2) return false;
  final a = plan['p003'];
  final b = plan['p004'];
  if (a == null || b == null || a.length != 1 || b.length != 1) return false;
  return _sameRect(a.single, IntRect(600, 2200, 1000, 2400)) &&
      _sameRect(b.single, IntRect(600, 0, 1000, 300));
}

/// 故障实现：不按页摊平，所有矩形都挂在顶页下。
Map<String, List<IntRect>> _faultyEraseLumpsOnHead(BlockSpan span) => {
      span.parts.first.page: [for (final p in span.parts) p.rect],
    };

// ── 5 · 解跨页：真身留顶页、尾页复原 ───────────────────────────────────

typedef _DissolveFn = SpanDissolvePlan? Function(BlockSpan span);

bool _dissolveKeepsHeadRestoresTail(_DissolveFn fn) {
  final span = BlockSpan([
    SpanPart('p003', IntRect(600, 2200, 1000, 2400)),
    SpanPart('p004', IntRect(600, 0, 1000, 300)),
  ]);
  final plan = fn(span);
  if (plan == null) return false;
  return plan.headPage == 'p003' &&
      _sameRect(plan.headRect, IntRect(600, 2200, 1000, 2400)) &&
      plan.restoredPages.length == 1 &&
      plan.restoredPages.single == 'p004';
}

/// 故障实现：误把**末页**当顶页（真身块会落到下页，顶页反而被复原）。
SpanDissolvePlan? _faultyDissolveTailAsHead(BlockSpan span) {
  if (span.parts.isEmpty) return null;
  final last = span.parts.last;
  final others = <String>[
    for (final p in span.parts)
      if (p.page != last.page) p.page,
  ];
  return SpanDissolvePlan(
    headPage: last.page,
    headRect: last.rect,
    restoredPages: others,
  );
}

// ── 6 · 解组回收 uid：只清不再被任何组引用的 ───────────────────────────

bool _unreferencedUidsClearable() {
  // 场景：g1 = {a#u1, a#u2}（即将被解散）；g2 = {a#u2, a#u3} 仍在（u2 共享）。
  // g1 只出现在文字描述里 —— "解散 g1"这个动作由 studio_page 接线，本断言
  // 只验证"剩下 g2 时哪些 uid 可清"。
  final g2 = BlockGroup(
    id: 'g2',
    members: const [
      GroupMemberRef('a', 'u2'),
      GroupMemberRef('a', 'u3'),
    ],
  );
  // 解散 g1 后，仍被引用的只有 g2 的 {u2,u3}。
  final referenced = referencedMembersByPage([g2]);
  final clearable = clearableUidIndexes(
    indexedUids: const [
      (index: 0, uid: 'u1'),
      (index: 1, uid: 'u2'),
      (index: 2, uid: 'u3'),
    ],
    stillReferenced: referenced['a'] ?? const <String>{},
  );
  // 绿判据：只有 u1（下标 0）可清；共享的 u2 必须保留。
  final greenOk = clearable.length == 1 && clearable.single == 0;

  // 故障路径：解散时无脑清掉本组所有成员的 uid —— 会误清共享的 u2，
  // g2 随即静默指错块。该集合与"仍被引用"表有交集 ⇒ 判红。
  final faultyCleared = ['u1', 'u2'];
  final still = referenced['a'] ?? const <String>{};
  final faultyTouchesReferenced = faultyCleared.any(still.contains);
  return greenOk && faultyTouchesReferenced;
}

// ── P30 · 长画布按页隐藏（strip_hidden_pages）─────────────────────────

typedef _ReadHiddenFn = Set<String> Function(Map<String, Object?> raw);
typedef _WriteHiddenFn = void Function(
    Map<String, Object?> raw, Set<String> hidden);

/// 读写往返：写进去的能原样读回；空集**删键**；未知键原样保留。
bool _hiddenReadWriteRoundtrip(_ReadHiddenFn read, _WriteHiddenFn write) {
  final raw = <String, Object?>{
    'unrelated': <String, Object?>{'x': 1},
  };
  write(raw, {'a.webp', 'b.webp'});
  final got = read(raw);
  if (got.length != 2 || !got.contains('a.webp') || !got.contains('b.webp')) {
    return false;
  }
  final unrelated = raw['unrelated'];
  if (unrelated is! Map || unrelated['x'] != 1) return false;
  // 空集必须删键（FT 零字节 diff 的纪律）。
  write(raw, <String>{});
  if (raw.containsKey(stripHiddenKey)) return false;
  return read(raw).isEmpty;
}

/// 故障实现：空集写成空 map 而不是删键 —— JSON 里平白多一个 `"_strip_hidden": {}`。
void _faultyWriteKeepsEmptyKey(Map<String, Object?> raw, Set<String> hidden) {
  if (hidden.isEmpty) {
    raw[stripHiddenKey] = <String, Object?>{};
    return;
  }
  writeHiddenPages(raw, hidden);
}

/// 坏数据（非 map / 值非 true）一律当作"没藏"，绝不抛、绝不误藏。
bool _hiddenMalformedIgnored(_ReadHiddenFn read) {
  if (read(<String, Object?>{stripHiddenKey: 'garbage'}).isNotEmpty) {
    return false;
  }
  if (read(<String, Object?>{
        stripHiddenKey: <String, Object?>{'a.webp': false, 'b.webp': 'yes'},
      })
      .isNotEmpty) {
    return false;
  }
  final ok = read(<String, Object?>{
    stripHiddenKey: <String, Object?>{'a.webp': true},
  });
  return ok.length == 1 && ok.single == 'a.webp';
}

/// 故障实现：信任 map 里的每个键（不看值）—— false / 垃圾值也被当成隐藏页。
Set<String> _faultyReadTrustsKeys(Map<String, Object?> raw) {
  final stored = raw[stripHiddenKey];
  if (stored is! Map) return <String>{};
  return stored.keys.cast<String>().toSet();
}

typedef _ToggleFn = Set<String> Function(Set<String> hidden, String pageKey);

/// 切换：无则加、有则删；**不改入参**。
bool _hiddenToggleFlips(_ToggleFn toggle) {
  final input = <String>{'a.webp'};
  final added = toggle(input, 'b.webp');
  if (!added.contains('a.webp') || !added.contains('b.webp')) return false;
  if (input.length != 1 || !input.contains('a.webp')) return false; // 入参被改
  final removed = toggle(added, 'a.webp');
  return removed.length == 1 && removed.single == 'b.webp';
}

/// 故障实现：只加不删（再点一次勾选框无法取消隐藏）。
Set<String> _faultyToggleOnlyAdds(Set<String> hidden, String pageKey) =>
    <String>{...hidden, pageKey};

typedef _VisibleFn = List<int> Function({
  required List<String> pageKeys,
  required Set<String> hidden,
});

/// 可见序列返回的是**原始下标**（隐藏首页后整体不错位）。
bool _visibleIndicesOriginal(_VisibleFn visible) {
  final keys = ['0.webp', '1.webp', '2.webp', '3.webp'];
  final got = visible(pageKeys: keys, hidden: {'0.webp', '2.webp'});
  if (got.length != 2 || got[0] != 1 || got[1] != 3) return false;
  final all = visible(pageKeys: keys, hidden: <String>{});
  if (all.length != 4) return false;
  return visible(pageKeys: keys, hidden: <String>{...keys}).isEmpty;
}

/// 故障实现：返回压缩后的连续位置 —— 隐藏首页后所有下标整体前移，
/// 调用方拿它回查工程页就会全页错位。
List<int> _faultyVisibleCompressed({
  required List<String> pageKeys,
  required Set<String> hidden,
}) {
  final n = pageKeys.length - hidden.length;
  return [for (var i = 0; i < n; i++) i];
}

typedef _NextVisibleFn = int? Function({required int current, required List<int> visible});

/// 隐藏当前页后的落点：后可见优先 → 否则前可见 → 全隐 null。
bool _nextVisibleBranches(_NextVisibleFn next) {
  // 藏第 2 页（下标 1），后面还有可见页 ⇒ 2。
  if (next(current: 1, visible: const [0, 2, 3]) != 2) return false;
  // 藏最后一页 ⇒ 前一张可见页 1。
  if (next(current: 2, visible: const [0, 1]) != 1) return false;
  // 全部被隐藏 ⇒ null（调用方保持现状，不瞎跳）。
  if (next(current: 1, visible: const <int>[]) != null) return false;
  return true;
}

/// 故障实现：直接 current+1 —— 藏末页时跳到一个不存在/被隐藏的下标。
int? _faultyNextIsCurrentPlusOne({
  required int current,
  required List<int> visible,
}) =>
    current + 1;

// ── 工具（与 P13 同一个 _probe；故障路径抛异常不算变红） ───────────────

Future<void> _probe(
  CheckSink check,
  String name,
  Future<bool> Function() green,
  Future<bool> Function() red,
  String Function() detail,
) async {
  bool g;
  bool r;
  var err = '';
  try {
    g = await green();
  } catch (e) {
    g = false;
    err = 'green threw: $e';
  }
  try {
    r = await red();
  } catch (e) {
    r = true;
    err = '${err.isEmpty ? '' : '$err | '}red threw: $e';
  }
  check(
    name,
    g && !r,
    '${detail()} | 绿路径=${g ? 'true' : 'FALSE'} '
    '故障路径=${r ? '仍绿(装饰品)' : '变红'}${err.isEmpty ? '' : ' | $err'}',
  );
}

List<SeamCandidatePlan> _realPlan(List<IntRect> rects) => planSeamCandidates(
      windowRects: rects,
      pageAHeight: 2400,
      window: _window,
      bands: _bands,
      pageRect: _pageRectOf,
    );

/// B-2 步骤 b + B-5 的 6 条断言 + P30 长画布按页隐藏的 5 条断言
/// （由 `block-ops-check` 汇总）。
Future<void> runP14Checks(CheckSink check) async {
  await _probe(
    check,
    'seam_detect.crossing_candidate_maps_to_two_pages',
    () async => _crossingCandidateMapsToTwoPages(_realPlan),
    () async => _crossingCandidateMapsToTwoPages(_faultyNoBase),
    () => '绿=跨缝框映射成两页子矩形且虚拟往返无损 / 故障=不减窗口 base ⇒ 顶段错位 ⇒ 变红',
  );

  await _probe(
    check,
    'seam_detect.single_side_candidate_is_dropped',
    () async => _singleSideCandidateDropped(_realPlan),
    () async => _singleSideCandidateDropped(_faultyKeepsSinglePage),
    () => '绿=只落在一页的框不产生跨页候选 / 故障=照单全收 ⇒ 变红',
  );

  await _probe(
    check,
    'seam_detect.mismatched_width_candidate_rejected',
    () async => _invalidWidthRejected(_realPlanBadWidth),
    () async => _invalidWidthRejected(_faultyNoValidate),
    () => '绿=异宽候选被 validateSpan 剔除 / 故障=不校验照收 ⇒ 变红',
  );

  await _probe(
    check,
    'span_artifacts.erase_plan_grouped_by_page',
    () async => _erasePlanGroupedByPage(spanEraseRectsByPage),
    () async => _erasePlanGroupedByPage(_faultyEraseLumpsOnHead),
    () => '绿=抹除矩形按页摊平、逐页出图 / 故障=全挂顶页 ⇒ 下页没抹到 ⇒ 变红',
  );

  await _probe(
    check,
    'span_artifacts.dissolve_keeps_head_restores_tail',
    () async => _dissolveKeepsHeadRestoresTail(dissolveSpanPlan),
    () async => _dissolveKeepsHeadRestoresTail(_faultyDissolveTailAsHead),
    () => '绿=解跨页真身留顶页·尾页复原 / 故障=误取末页 ⇒ 变红',
  );

  await _probe(
    check,
    'group.uid_recycle_skips_still_referenced',
    () async => _unreferencedUidsClearable(),
    // 本条的"故障实现"已内联（无脑清组内全部 uid），红路径恒为"故障会误清"。
    () async => false,
    () => '绿=解组只回收无引用 uid，共享 uid 保留 / 故障=全清本组成员 ⇒ 误伤共享组 ⇒ 变红',
  );

  // ── P30 · 长画布按页隐藏 ─────────────────────────────────────────────
  await _probe(
    check,
    'strip_hidden.read_write_roundtrip',
    () async =>
        _hiddenReadWriteRoundtrip(readHiddenPages, writeHiddenPages),
    () async =>
        _hiddenReadWriteRoundtrip(readHiddenPages, _faultyWriteKeepsEmptyKey),
    () => '绿=读写往返一致·空集删键·未知键保留 / 故障=空集留空 map ⇒ FT 脏 diff ⇒ 变红',
  );

  await _probe(
    check,
    'strip_hidden.malformed_storage_ignored',
    () async => _hiddenMalformedIgnored(readHiddenPages),
    () async => _hiddenMalformedIgnored(_faultyReadTrustsKeys),
    () => '绿=非 map/值非 true 一律忽略 / 故障=只看键不看值 ⇒ false 也被误藏 ⇒ 变红',
  );

  await _probe(
    check,
    'strip_hidden.toggle_flips_without_mutation',
    () async => _hiddenToggleFlips(toggleHiddenPage),
    () async => _hiddenToggleFlips(_faultyToggleOnlyAdds),
    () => '绿=无则加有则删·不改入参 / 故障=只加不删 ⇒ 无法取消隐藏 ⇒ 变红',
  );

  await _probe(
    check,
    'strip_hidden.visible_indices_are_original_indexes',
    () async => _visibleIndicesOriginal(visiblePageIndices),
    () async => _visibleIndicesOriginal(_faultyVisibleCompressed),
    () => '绿=可见序列保留原始下标 / 故障=压缩成连续位置 ⇒ 隐藏首页后全页错位 ⇒ 变红',
  );

  await _probe(
    check,
    'strip_hidden.next_visible_after_hide_branches',
    () async => _nextVisibleBranches(nextVisibleAfterHide),
    () async => _nextVisibleBranches(_faultyNextIsCurrentPlusOne),
    () => '绿=后可见优先·末页取前·全隐 null / 故障=恒取 current+1 ⇒ 藏末页越界 ⇒ 变红',
  );
}
