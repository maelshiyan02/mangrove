// B-2 · 跨页文本块的纯逻辑（跨页拼接计划 §4-B2 / §8.3）。
//
// 铁律：「**真相在源像素坐标**」。跨页块的落盘形态是**每页各自的子矩形**
// （`_span.parts`，D8 结案）；"跨两页的虚拟整矩形"是**派生视图**、随用随算。
//
// 🔴 本文件**不含 Flutter 依赖**（只 import `IntRect` 与 `TextBlock`），所以
// 虚拟 ↔ 子矩形互转、按缝切分、`parts` 校验都能 headless 跑完；画布上的跨缝拖框
// 是 UI，另行处理。
//
// ## 虚拟坐标（§4.0.2）
//
// 两页**纵向零间隙**拼接：`虚拟 y = 该页之前所有页高之和 + 页内 y`，x 沿用页内 x。
// 不存虚拟整矩形（它依赖"当前是哪两页、什么顺序"）；`parts.length > 1` 本身就
// 等于"这是跨页块"（§8.3 结论 2，不设冗余 `_isCrossPage` 标志位）。
//
// ## 两条不变式（与 L4 持久化层一致）
//
// 1. **未知键原样保留**：只碰块级 `_span` 一个键，其余不动。
// 2. **不存在即 nil**：单页块**根本没有** `_span` 键（不是写空对象）。
library;

import 'dart:math' as math;

import '../image_translation/translation_types.dart' show IntRect;
import 'text_block.dart' show TextBlock, asObjectList, asObjectMap;

/// 块级的跨页标记键（下划线前缀；单页块不出现此键）。
const String spanKey = '_span';

/// `validateSpan` 的缘由码（返回 null = 合法）。
const String spanReasonEmpty = 'empty_parts';
const String spanReasonWidthMismatch = 'width_mismatch';
const String spanReasonOutOfBounds = 'part_out_of_page_bounds';
const String spanReasonOverlap = 'parts_overlap_on_same_page';

/// 跨页块在**某一页**上的子矩形（页内像素坐标）。
class SpanPart {
  SpanPart(this.page, this.rect);

  /// 页键（如 `p004`）。
  final String page;

  /// 该页内的子矩形（页内坐标，非虚拟坐标）。
  IntRect rect;

  /// 落盘形态：`{"page": k, "rect": [x, y, w, h]}`（§4.0.3）。
  Map<String, Object?> toRaw() => <String, Object?>{
        'page': page,
        'rect': <Object?>[rect.left, rect.top, rect.width, rect.height],
      };

  /// 由落盘数据还原；形态不对（无页 / rect 不是 4 个整数 / 宽高非正）返回 null。
  static SpanPart? fromRaw(Object? value) {
    final map = asObjectMap(value);
    if (map == null) return null;
    final page = map['page']?.toString() ?? '';
    if (page.isEmpty) return null;
    final list = asObjectList(map['rect']);
    if (list == null || list.length != 4) return null;
    final nums = <int>[];
    for (final entry in list) {
      if (entry is int) {
        nums.add(entry);
      } else if (entry is num) {
        nums.add(entry.round());
      } else {
        return null;
      }
    }
    final w = nums[2];
    final h = nums[3];
    if (w <= 0 || h <= 0) return null;
    return SpanPart(page, IntRect(nums[0], nums[1], nums[0] + w, nums[1] + h));
  }

  SpanPart copy() =>
      SpanPart(page, IntRect(rect.left, rect.top, rect.right, rect.bottom));
}

/// 跨页块的分页子矩形集合（`_span` 的载荷）。
class BlockSpan {
  BlockSpan(List<SpanPart> parts) : parts = [...parts];

  /// **有序**子矩形（顺序 = 虚拟坐标里从上到下）。
  final List<SpanPart> parts;

  /// `parts.length > 1` 即跨页块（§8.3 结论 2）。
  bool get isCrossPage => parts.length > 1;

  /// 涉及的页键（保留重复，用于校验同页重叠）。
  List<String> get pageKeys => [for (final part in parts) part.page];

  Map<String, Object?> toRaw() =>
      <String, Object?>{'parts': <Object?>[for (final part in parts) part.toRaw()]};

  /// 由落盘数据还原；无有效段返回 null（调用方据此忽略坏记录）。
  static BlockSpan? fromRaw(Object? value) {
    final map = asObjectMap(value);
    if (map == null) return null;
    final parts = <SpanPart>[];
    for (final entry in asObjectList(map['parts']) ?? const []) {
      final part = SpanPart.fromRaw(entry);
      if (part != null) parts.add(part);
    }
    if (parts.isEmpty) return null;
    return BlockSpan(parts);
  }

  BlockSpan copy() => BlockSpan([for (final part in parts) part.copy()]);
}

// ── 块级读写（惰性：单页块不出现 `_span`） ──────────────────────────────

/// 读块的 `_span`，没有 / 坏数据则 null。
BlockSpan? readSpan(TextBlock block) => BlockSpan.fromRaw(block.raw[spanKey]);

/// 写块的 `_span`；空段 ⇒ **删除该键**（不变式 2）。返回是否已写入。
bool writeSpan(TextBlock block, BlockSpan span) {
  if (span.parts.isEmpty) return clearSpan(block);
  block.raw[spanKey] = span.toRaw();
  return true;
}

/// 删掉块的 `_span`（解跨页时回收）。返回是否确实删掉了。
bool clearSpan(TextBlock block) => block.raw.remove(spanKey) != null;

// ── 虚拟坐标 ↔ per-page 子矩形（L1 几何层，纯函数） ─────────────────────

/// 一页在虚拟（纵向零间隙拼接）里的尺寸。
class PageBand {
  const PageBand(this.page, this.width, this.height);

  final String page;
  final int width;
  final int height;
}

/// 逐页虚拟起点（页首在虚拟坐标里的 y）。按 [bands] 顺序累加高度。
Map<String, int> virtualOffsets(List<PageBand> bands) {
  final offsets = <String, int>{};
  var y = 0;
  for (final band in bands) {
    offsets[band.page] = y;
    y += band.height;
  }
  return offsets;
}

/// 把 per-page 子矩形映射回**虚拟整矩形**（派生的包围盒）。
///
/// 每段：`(x, 页内 y) -> (x, offset + y)`；返回所有段的并集。无段 ⇒ null。
IntRect? spanToVirtual(
  BlockSpan span, {
  required int Function(String page) offsetOf,
}) {
  IntRect? bounds;
  for (final part in span.parts) {
    final dy = offsetOf(part.page);
    final rect = IntRect(
      part.rect.left,
      part.rect.top + dy,
      part.rect.right,
      part.rect.bottom + dy,
    );
    bounds = bounds == null
        ? rect
        : IntRect(
            math.min(bounds.left, rect.left),
            math.min(bounds.top, rect.top),
            math.max(bounds.right, rect.right),
            math.max(bounds.bottom, rect.bottom),
          );
  }
  return bounds;
}

/// 把**虚拟整矩形**按页边界切成 per-page 子矩形；与该页无交集的段被丢弃。
///
/// 往返无损的前提：虚拟矩形落在 [bands] 覆盖的竖向区间内（§4-B2 断言①）。
/// 返回的每段都**已被夹在各自页内**（§4-B2 断言⑤）。
List<SpanPart> splitVirtual(
  IntRect virtualRect, {
  required List<PageBand> bands,
}) {
  final parts = <SpanPart>[];
  var offset = 0;
  for (final band in bands) {
    final pageTop = offset;
    final pageBottom = offset + band.height;
    offset = pageBottom;
    final top = math.max(virtualRect.top, pageTop);
    final bottom = math.min(virtualRect.bottom, pageBottom);
    if (bottom <= top) continue; // 该页没有交集
    parts.add(
      SpanPart(
        band.page,
        IntRect(
          virtualRect.left,
          top - pageTop,
          virtualRect.right,
          bottom - pageTop,
        ),
      ),
    );
  }
  return parts;
}

/// 校验 `parts`：合法返回 null，否则返回缘由码。
///
/// 规则（§4-B2 落点）：① 非空；② **所有页同宽**（D12：虚拟坐标要求同宽）；
/// ③ 每段**不越自己那页**；④ **同页两段不重叠**。
String? validateSpan(
  BlockSpan span, {
  required IntRect Function(String page) pageRect,
}) {
  if (span.parts.isEmpty) return spanReasonEmpty;
  int? width;
  final byPage = <String, List<IntRect>>{};
  for (final part in span.parts) {
    final page = pageRect(part.page);
    if (width == null) {
      width = page.width;
    } else if (width != page.width) {
      return spanReasonWidthMismatch;
    }
    final rect = part.rect;
    if (rect.left < 0 ||
        rect.top < 0 ||
        rect.right > page.width ||
        rect.bottom > page.height) {
      return spanReasonOutOfBounds;
    }
    final seen = byPage.putIfAbsent(part.page, () => <IntRect>[]);
    for (final other in seen) {
      if (rect.intersects(other)) return spanReasonOverlap;
    }
    seen.add(rect);
  }
  return null;
}