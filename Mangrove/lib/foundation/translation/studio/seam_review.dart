// B-1 · 「缝发现与标记」的纯逻辑（跨页拼接计划 §4-B1）。
//
// 一个"缝"= 阅读序里**上下相邻的两页**交界。人工在单页+缩略图栏模式下逐条看，
// 记录四态之一：`todo`（未看）/ `clean`（干净）/ `split`（有截断）/ `n/a`（不可检视）。
//
// 🔴 本文件**不含 Flutter 依赖**，因此整个判定与计数都能 headless 跑完（本会话
// 没有渲染表面 ⇒ 能测的必须测干净）。GUI 部分（缩略图栏里的缝标记与跳转）另行处理。
//
// ## 两条不变式（与工程级持久化层 L4 一致）
//
// 1. **未知顶层键原样保留**：这里只碰 `_seam_reviews` 一个键，其余键一个不动
//    —— 工程 `raw` 是权威，`TranslationProjectIo.encode` 直接序列化它，所以
//    "读→不改→写"仍是零字节 diff。
// 2. **不存在即 nil**：没有任何检视记录时该键**根本不出现**（不是写一个空对象），
//    否则每个工程一保存就多一段永不消失的 `"_seam_reviews": {}`。
//
// ## 为什么 `n/a` 要单独一态而不是 `todo`
//
// 横版页（`width >= height`，A-1.4/D11）在缩略图栏里被隐藏，其**两侧的缝**没人能
// 看到，也永远不会有"截断"可言。若把它们记成 `todo`，"还有 N 条待检视"会永远
// 还不完（R8 的缓解手段）。所以它们记 `n/a`，且**不参与**待检视/已检视计数。
library;

import 'text_block.dart' show asObjectMap;

/// 工程级 JSON 里存缝检视状态的那个键（下划线前缀，与 FT 其余可选键一致）。
const String seamReviewKey = '_seam_reviews';

/// 一条缝的四种状态。
///
/// `wire` 是落盘字符串；`n/a` 带斜杠，与其余三个形态不同，读取时按整串比对。
enum SeamState {
  todo('todo'),
  clean('clean'),
  split('split'),
  na('n/a');

  const SeamState(this.wire);

  /// 落盘/读回用的字符串。
  final String wire;

  /// 由落盘字符串还原；不认识的值返回 null（调用方据此**忽略**坏值，而不是
  /// 猜一个默认态把数据写坏）。
  static SeamState? fromWire(String? value) {
    if (value == null) return null;
    for (final state in SeamState.values) {
      if (state.wire == value) return state;
    }
    return null;
  }
}

/// 缝 id：**阅读序**下的 `"<上页>|<下页>"`。
///
/// 🔴 顺序是判据的一部分：`"A|B"` 与 `"B|A"` 是两条不同的缝（一条在上、一条在
/// 下），所以这里**绝不**做排序或去重。调用方必须按阅读序传参（见 [seamsOf]）。
String seamId(String upperPage, String lowerPage) => '$upperPage|$lowerPage';

/// 把缝 id 拆回两页；形态不对（不是恰好两段）返回 null。
List<String>? seamIdPages(String id) {
  final parts = id.split('|');
  if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
  return parts;
}

/// 一条缝（阅读序里的上下相邻两页）。
class SeamEntry {
  const SeamEntry(this.upper, this.lower);

  /// 阅读序里靠上的那一页。
  final String upper;

  /// 阅读序里靠下的那一页。
  final String lower;

  String get id => seamId(upper, lower);

  @override
  String toString() => id;
}

/// [pageOrder] 里每一对相邻页构成一条缝，**按阅读序**返回（上页在前）。
///
/// 页数 < 2 时没有缝，返回空表。
List<SeamEntry> seamsOf(List<String> pageOrder) {
  final seams = <SeamEntry>[];
  for (var i = 0; i + 1 < pageOrder.length; i++) {
    seams.add(SeamEntry(pageOrder[i], pageOrder[i + 1]));
  }
  return seams;
}

/// 读出工程 `raw` 里的缝检视记录（值不认识的条目被忽略）。
///
/// 返回的是一个**新的可变表**，调用方改它不会影响 `raw`；要写回请用
/// [writeSeamReviews]。
Map<String, String> readSeamReviews(Map<String, Object?> raw) {
  final result = <String, String>{};
  final stored = asObjectMap(raw[seamReviewKey]);
  if (stored == null) return result;
  for (final entry in stored.entries) {
    final value = entry.value;
    if (value is String && SeamState.fromWire(value) != null) {
      result[entry.key] = value;
    }
  }
  return result;
}

/// 把 [reviews] 写回工程 `raw`。
///
/// 空表 ⇒ **删除**该键（不变式 2：不存在即 nil，避免凭空多出一段空对象）。
void writeSeamReviews(
  Map<String, Object?> raw,
  Map<String, String> reviews,
) {
  if (reviews.isEmpty) {
    raw.remove(seamReviewKey);
    return;
  }
  raw[seamReviewKey] = <String, Object?>{
    for (final entry in reviews.entries) entry.key: entry.value,
  };
}

/// [seam] 的**有效状态**。
///
/// 优先级：① 任一侧是隐藏页（横版）⇒ 恒为 [SeamState.na]（不可检视，且人工记的
/// 值不作数）；② 否则取记录里的值，认不出或未记录 ⇒ [SeamState.todo]。
SeamState effectiveSeamState(
  SeamEntry seam, {
  required Map<String, String> reviews,
  required bool Function(String pageKey) isHiddenPage,
}) {
  if (isHiddenPage(seam.upper) || isHiddenPage(seam.lower)) {
    return SeamState.na;
  }
  return SeamState.fromWire(reviews[seam.id]) ?? SeamState.todo;
}

/// 缝检视的计数。
class SeamCounts {
  const SeamCounts({
    required this.toReview,
    required this.reviewed,
    required this.notApplicable,
  });

  /// 仍待检视（`todo`）。
  final int toReview;

  /// 已检视（`clean` 或 `split`）。
  final int reviewed;

  /// 不可检视（`n/a`）。
  final int notApplicable;

  int get total => toReview + reviewed + notApplicable;
}

/// 统计 [seams] 的三种计数。
///
/// 🔴 `n/a` **不计入** [SeamCounts.toReview]（否则"还有 N 条待检视"永远还不完，
/// 见文件头 R8）。
SeamCounts seamCounts(
  List<SeamEntry> seams, {
  required Map<String, String> reviews,
  required bool Function(String pageKey) isHiddenPage,
}) {
  var toReview = 0;
  var reviewed = 0;
  var notApplicable = 0;
  for (final seam in seams) {
    switch (effectiveSeamState(
      seam,
      reviews: reviews,
      isHiddenPage: isHiddenPage,
    )) {
      case SeamState.todo:
        toReview++;
      case SeamState.clean || SeamState.split:
        reviewed++;
      case SeamState.na:
        notApplicable++;
    }
  }
  return SeamCounts(
    toReview: toReview,
    reviewed: reviewed,
    notApplicable: notApplicable,
  );
}

/// D7：从 [fromIndex] 之后找**下一条**待检视的缝（`todo`），到表尾回绕。
///
/// 返回缝在 [seams] 里的下标；没有待检视的缝时返回 null。`fromIndex` 默认 -1，
/// 表示"从头开始找"。
int? nextUnreviewedIndex(
  List<SeamEntry> seams, {
  required Map<String, String> reviews,
  required bool Function(String pageKey) isHiddenPage,
  int fromIndex = -1,
}) {
  if (seams.isEmpty) return null;
  for (var step = 1; step <= seams.length; step++) {
    final i = (fromIndex + step + seams.length) % seams.length;
    if (effectiveSeamState(
          seams[i],
          reviews: reviews,
          isHiddenPage: isHiddenPage,
        ) ==
        SeamState.todo) {
      return i;
    }
  }
  return null;
}