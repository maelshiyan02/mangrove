// B-1（缝发现与标记）的 headless 断言集（跨页拼接计划 §4-B1 验收）。
//
// 「缝」的判定与计数全在 `seam_review.dart`（纯 Dart，无 Flutter、无 `dart:ui`），
// 所以这一批第一次能被 headless 跑完。GUI 部分（缩略图栏里画出缝标记、跳转）本
// 会话没有渲染表面，只能由用户在 GUI 会话验收。
//
// ## 反向验证（M08）
//
// 每条断言跑两遍：绿路径喂**真实现**，故障路径喂一个**故意写错的实现**，两条
// 路径检验的是**同一个命题**。`故障路径=变红` 才说明判据不是装饰品。
library;

import 'dart:io';

import 'package:mangrove/foundation/translation_project/project.dart';
import 'package:mangrove/foundation/translation_project/project_io.dart';
import 'package:mangrove/foundation/translation_project/seam_review.dart';
import 'package:mangrove/foundation/translation_project/text_block.dart'
    show asObjectMap;
import 'package:mangrove/headless_p1_checks.dart' show CheckSink;

typedef _StoreFn = void Function(
  Map<String, Object?> raw,
  Map<String, String> reviews,
);

typedef _CountFn = SeamCounts Function(
  List<SeamEntry> seams, {
  required Map<String, String> reviews,
  required bool Function(String pageKey) isHiddenPage,
});

typedef _StateFn = SeamState Function(
  SeamEntry seam, {
  required Map<String, String> reviews,
  required bool Function(String pageKey) isHiddenPage,
});

/// 一篇例子的页序：p2 是横版页（被隐藏）。
const _order = ['p1.webp', 'p2.webp', 'p3.webp', 'p4.webp'];

bool _hidden(String pageKey) => pageKey == 'p2.webp';

// ── 1 · 缝 id 只认阅读序 ────────────────────────────────────────────────

/// 命题：id 编码**阅读序**，`"A|B"` 与 `"B|A"` 是两条不同的缝。
///
/// 分辨点：一个"把两页排序后拼 id"的实现会让两者相等 —— 那样"上页/下页"就丢了，
/// 而缝的方向正是它的全部意义。
bool _idOrderStable(String Function(String, String) idFn) {
  if (idFn('a', 'b') != 'a|b') return false;
  if (idFn('b', 'a') != 'b|a') return false;
  if (idFn('a', 'b') == idFn('b', 'a')) return false;
  // 枚举也必须按阅读序（不是字典序）。
  final seams = seamsOf(_order);
  final ids = [for (final s in seams) s.id];
  return _listEq(ids, const [
    'p1.webp|p2.webp',
    'p2.webp|p3.webp',
    'p3.webp|p4.webp',
  ]);
}

/// 故障实现：把两页排序后拼 id（丢方向）。
String _faultyId(String a, String b) {
  final pair = [a, b]..sort();
  return '${pair[0]}|${pair[1]}';
}

// ── 2 · 写→读→还原（含未知顶层键保留） ─────────────────────────────────

/// 命题：经**真实编解码**往返后，缝记录逐条还原，且工程里**未知的顶层键**仍在。
///
/// 分辨点：一个"只保留 `_seam_reviews`、重建整个工程"的实现会把未知键抹掉 ——
/// 那正是"读→不改→写 = 零字节 diff"这条契约的反面。
bool _roundTripOk(_StoreFn store) {
  final raw = <String, Object?>{
    'directory': 'C:/some/where',
    'pages': <String, Object?>{'p1.webp': <Object?>[]},
    'page_order': <Object?>['p1.webp', 'p2.webp'],
    'a_future_key': <String, Object?>{'nested': 7},
  };
  const reviews = <String, String>{
    'p1.webp|p2.webp': 'split',
    'p2.webp|p3.webp': 'clean',
  };
  store(raw, reviews);

  final project = TranslationProject.buildFrom(raw, File('x.json'));
  final text = TranslationProjectIo.encode(project);
  final back = TranslationProjectIo.parse(text, File('x.json')).raw;

  final read = readSeamReviews(back);
  if (read.length != reviews.length) return false;
  for (final entry in reviews.entries) {
    if (read[entry.key] != entry.value) return false;
  }
  if (back['a_future_key'] == null) return false;
  final nested = asObjectMap(back['a_future_key']);
  return nested != null && nested['nested'] == 7;
}

/// 故障实现：重建整个工程，只留 `_seam_reviews`。
void _faultyStore(Map<String, Object?> raw, Map<String, String> reviews) {
  raw
    ..clear()
    ..[seamReviewKey] = <String, Object?>{
      for (final entry in reviews.entries) entry.key: entry.value,
    };
}

// ── 3 · 计数排除 n/a ────────────────────────────────────────────────────

/// 命题：`n/a` 的缝**不**计入"待检视"。
bool _countsMatch(_CountFn fn) {
  final seams = seamsOf(_order); // p1|p2, p2|p3, p3|p4
  final counts = fn(
    seams,
    reviews: const {'p3.webp|p4.webp': 'clean'},
    isHiddenPage: _hidden,
  );
  // p1|p2 与 p2|p3 触及横版页 ⇒ n/a；p3|p4 已标 clean。
  return counts.notApplicable == 2 &&
      counts.reviewed == 1 &&
      counts.toReview == 0 &&
      counts.total == 3;
}

/// 故障实现：不特判隐藏页，把 `n/a` 也当成"待检视"。
SeamCounts _faultyCounts(
  List<SeamEntry> seams, {
  required Map<String, String> reviews,
  required bool Function(String pageKey) isHiddenPage,
}) {
  var toReview = 0;
  var reviewed = 0;
  for (final seam in seams) {
    final wire = reviews[seam.id];
    if (wire == 'clean' || wire == 'split') {
      reviewed++;
    } else {
      toReview++;
    }
  }
  return SeamCounts(toReview: toReview, reviewed: reviewed, notApplicable: 0);
}

// ── 4 · 横版页两侧的缝是 n/a ────────────────────────────────────────────

/// 命题：任一侧是隐藏页的缝 ⇒ `n/a`；两侧都可见的缝才可能是 `todo`。
bool _landscapeNa(_StateFn fn) {
  final seams = seamsOf(_order);
  const reviews = <String, String>{};
  final a = fn(seams[0], reviews: reviews, isHiddenPage: _hidden);
  final b = fn(seams[1], reviews: reviews, isHiddenPage: _hidden);
  final c = fn(seams[2], reviews: reviews, isHiddenPage: _hidden);
  return a == SeamState.na && b == SeamState.na && c == SeamState.todo;
}

/// 故障实现：无视隐藏页，一律按记录/默认返回（两颗都判错）。
SeamState _faultyState(
  SeamEntry seam, {
  required Map<String, String> reviews,
  required bool Function(String pageKey) isHiddenPage,
}) {
  return SeamState.fromWire(reviews[seam.id]) ?? SeamState.todo;
}

// ── 工具 ───────────────────────────────────────────────────────────────

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

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
    // 故障路径抛异常 ≠ 断言变红。
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

/// B-1 的 4 条断言（由 `block-ops-check` 汇总）。
///
/// 与 A-1 那批不同，这里**不扫源码**（缝的判定全在纯函数里），所以不需要包根。
Future<void> runP11Checks(CheckSink check) async {
  // 1 · 缝 id 只认阅读序。
  await _probe(
    check,
    'seam.id_is_order_stable',
    () async => _idOrderStable(seamId),
    () async => _idOrderStable(_faultyId),
    () => '绿=A|B ≠ B|A 且按阅读序枚举 / 故障=排序两页 ⇒ 方向丢失 ⇒ 变红',
  );

  // 2 · 写→读→还原（含未知顶层键保留）。
  await _probe(
    check,
    'seam.reviews_round_trip',
    () async => _roundTripOk(writeSeamReviews),
    () async => _roundTripOk(_faultyStore),
    () => '绿=记录逐条还原 + 未知键 a_future_key 仍在 / '
        '故障=重建工程只留 _seam_reviews ⇒ 未知键被抹 ⇒ 变红',
  );

  // 3 · 计数排除 n/a。
  await _probe(
    check,
    'seam.counts_exclude_na',
    () async => _countsMatch(seamCounts),
    () async => _countsMatch(_faultyCounts),
    () => '绿=n/a 不入待检视（toReview=0） / 故障=n/a 也算 todo（=2）⇒ 变红',
  );

  // 4 · 横版页两侧的缝是 n/a。
  await _probe(
    check,
    'seam.landscape_neighbours_are_na',
    () async => _landscapeNa(effectiveSeamState),
    () async => _landscapeNa(_faultyState),
    () => '绿=触及横版页的缝 n/a·其余 todo / 故障=无视隐藏页 ⇒ 变红',
  );
}