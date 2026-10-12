// B-2 步骤 b · 「识别这一块」的纯逻辑（跨页拼接计划 §4-B2 步骤 b）。
//
// 在缝窗口的**内存拼接图**上跑完现有检测后，检测器给出的是一批**窗口坐标**的
// 候选框（`(0,0)` 在拼接图左上角）。本文件负责把它们中**真正跨过缝线**的：
//
// 1. 映射回**虚拟坐标**（`windowRectToVirtual`）；
// 2. 按页边界切成 per-page 子矩形（`splitVirtual`）；
// 3. 用 `validateSpan` 剔除几何不合法（异宽/越界/同页重叠）的；
// 4. 单页候选（框只落在一页内）**直接丢弃** —— 那是普通块，不是跨页块，
//    交给普通检测链路即可，这里不能替它建块。
//
// 🔴 本文件**不含 Flutter 依赖**，所以过滤、映射、切分、校验都能 headless 跑完
// （`headless_p14_checks.dart`）；检测本身（ONNX）与人工确认对话框是 UI 层。
//
// ## 自动不做什么（与 B-4 同一条边界）
//
// 只产出**候选**，绝不自动落块：候选要经人工勾选确认后才允许写进工程。
library;

import '../image_translation/translation_types.dart' show IntRect;
import 'cross_page_block.dart';
import 'seam_window.dart';

/// 一个跨页候选：窗口框 → 虚拟框 → per-page 子矩形。
class SeamCandidatePlan {
  SeamCandidatePlan({
    required this.windowRect,
    required this.virtualRect,
    required this.span,
  });

  /// 检测器在缝窗口拼接图上给出的原始框（窗口坐标）。
  final IntRect windowRect;

  /// 映射回的虚拟整矩形（派生视图，不落盘）。
  final IntRect virtualRect;

  /// 按缝切好的 per-page 子矩形（落盘真相，>=2 段）。
  final BlockSpan span;
}

/// 候选框是否**跨过缝线**。
///
/// 缝线在窗口坐标的 `y = window.topHeight` 处：页 A 底条带在上、页 B 顶条带
/// 在下。框必须**两侧都吃到**才算跨页（`top < seamY` 且 `bottom > seamY`）。
///
/// [tolerance] 给检测框与缝线之间留一个小间隙容差（像素，窗口坐标）：检测器的
/// 气泡聚类框有时离真实缝线差几像素，严格压线会漏掉这种"明显被截断"的气泡。
/// 默认 0 = 必须严格跨过；调用方可按实际检测偏差放宽。
bool rectCrossesSeam(
  IntRect windowRect, {
  required int seamY,
  int tolerance = 0,
}) {
  if (windowRect.width <= 0 || windowRect.height <= 0) return false;
  final band = tolerance < 0 ? 0 : tolerance;
  return windowRect.top < seamY + band && windowRect.bottom > seamY - band;
}

/// 把一批窗口坐标的候选框规划成跨页候选。
///
/// * 只保留[rectCrossesSeam]为真的框；
/// * 切分后不足 2 段（实际只落在一页）的丢弃；
/// * `validateSpan` 判非法（异宽/越界/同页重叠）的丢弃；
/// * 完全相同的子矩形集合去重（检测器可能对同一气泡出两个几乎重合的框）。
///
/// 返回顺序与 [windowRects] 的输入顺序一致，便于 UI 把 OCR 文本按同位对齐。
List<SeamCandidatePlan> planSeamCandidates({
  required List<IntRect> windowRects,
  required int pageAHeight,
  required SeamWindow window,
  required List<PageBand> bands,
  required IntRect Function(String page) pageRect,
  int tolerance = 0,
}) {
  final plans = <SeamCandidatePlan>[];
  final seen = <String>{};
  final seamY = window.topHeight;
  for (final rect in windowRects) {
    if (!rectCrossesSeam(rect, seamY: seamY, tolerance: tolerance)) continue;
    final virtual = windowRectToVirtual(
      rect,
      pageAHeight: pageAHeight,
      window: window,
    );
    final parts = splitVirtual(virtual, bands: bands);
    if (parts.length < 2) continue;
    final span = BlockSpan(parts);
    if (validateSpan(span, pageRect: pageRect) != null) continue;
    // 去重键 = 各段 "page:x,y,w,h" 的串联；同页段排序后再拼，避免顺序差异漏判。
    final key = [
      for (final part in span.parts)
        '${part.page}:'
            '${part.rect.left},${part.rect.top},'
            '${part.rect.width},${part.rect.height}',
    ].join('|');
    if (!seen.add(key)) continue;
    plans.add(
      SeamCandidatePlan(windowRect: rect, virtualRect: virtual, span: span),
    );
  }
  return plans;
}
