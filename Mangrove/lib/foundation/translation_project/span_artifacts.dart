// B-5 · 跨页文本块的**多页产物规划**（纯逻辑，无 Flutter 依赖，可 headless 断言）。
//
// 跨页块的抹字 / 复原 / 出图与单页块的区别只有一个：**它同时碰多页**，而产物
// 契约（`mask/ → inpainted/ → result/`）是**逐页**的。所以必须先把一个
// `BlockSpan` 摊成「每一页要做什么」的计划，再逐页复用既有的单页像素链路
// （`buildMaskPage` / `mergeRepairedInpainted` / `unionMasks` / …）。
//
// 本文件只做**摊平与规划**（哪些页、每页哪些矩形、哪一页是真身），不碰像素、
// 不碰文件系统：那两步在 `studio_page.dart` 里走与单块修图**完全相同**的入口。
library;

import '../image_translation/translation_types.dart' show IntRect;
import 'block_group.dart';
import 'cross_page_block.dart';

/// 把跨页块摊成「**页 → 该页内的抹除矩形**」表。
///
/// 同一页理论上至多一段（`validateSpan` 已禁止同页两段重叠），但这里仍返回
/// **列表**而不是单值：计划是给逐页 `buildMaskPage(image, rects)` 直接喂的，
/// 列表形态让调用方不需要在"一段/多段"之间分叉。
///
/// 🔴 页的出现顺序 = `parts` 顺序（虚拟坐标自上而下），与逐页出图的页序一致。
Map<String, List<IntRect>> spanEraseRectsByPage(BlockSpan span) {
  final byPage = <String, List<IntRect>>{};
  for (final part in span.parts) {
    byPage.putIfAbsent(part.page, () => <IntRect>[]).add(
          IntRect(
            part.rect.left,
            part.rect.top,
            part.rect.right,
            part.rect.bottom,
          ),
        );
  }
  return byPage;
}

/// 跨页块涉及的全部页键（按 `parts` 顺序去重）。
List<String> spanPages(BlockSpan span) {
  final pages = <String>[];
  for (final part in span.parts) {
    if (!pages.contains(part.page)) pages.add(part.page);
  }
  return pages;
}

/// 「解跨页」后真身块的保留方案。
class SpanDissolvePlan {
  SpanDissolvePlan({
    required this.headPage,
    required this.headRect,
    required this.restoredPages,
  });

  /// 真身继续留在的页（顶段所在页）。
  final String headPage;

  /// 真身块在顶页上应有的矩形（顶段子矩形，而不是虚拟整矩形）。
  final IntRect headRect;

  /// 除顶页外的页：这些页上本块抹掉的像素要**复原原图**（块在这些页上将不复
  /// 存在，留着抹痕就是无主的空白）。顺序与 `parts` 一致。
  final List<String> restoredPages;
}

/// 规划「解跨页」：块收缩回顶页、其余页复原。
///
/// 空段返回 null（调用方应忽略而不是猜）。顶段的判定与 `_onSpanMarquee` 一致：
/// `parts` 按虚拟顺序存储，第一段即在最上的页。
SpanDissolvePlan? dissolveSpanPlan(BlockSpan span) {
  if (span.parts.isEmpty) return null;
  final head = span.parts.first;
  final tail = <String>[];
  for (var i = 1; i < span.parts.length; i++) {
    final page = span.parts[i].page;
    if (page != head.page && !tail.contains(page)) tail.add(page);
  }
  return SpanDissolvePlan(
    headPage: head.page,
    headRect: IntRect(
      head.rect.left,
      head.rect.top,
      head.rect.right,
      head.rect.bottom,
    ),
    restoredPages: tail,
  );
}

// ── 解组时的 `_uid` 回收规划 ────────────────────────────────────────────

/// 全部组仍在引用的成员：`页 -> uid 集合`。
///
/// 解组 / 删成员后，块上的惰性 `_uid` 只有在**不再被任何组引用**时才允许回收
/// （`clearBlockUid`）—— 误删一个仍被别的组引用的 uid，会让那个组静默指错块。
Map<String, Set<String>> referencedMembersByPage(
  Iterable<BlockGroup> groups,
) {
  final result = <String, Set<String>>{};
  for (final group in groups) {
    for (final member in group.members) {
      result.putIfAbsent(member.page, () => <String>{}).add(member.uid);
    }
  }
  return result;
}

/// 某页上「可以安全回收 `_uid`」的块：它带 uid，但该 uid 不在任何组的引用表里。
///
/// 返回块在该页 blocks 列表中的**下标**（调用方据此 `clearBlockUid`）。
List<int> clearableUidIndexes({
  required List<({int index, String uid})> indexedUids,
  required Set<String> stillReferenced,
}) =>
    [
      for (final entry in indexedUids)
        if (!stillReferenced.contains(entry.uid)) entry.index,
    ];
