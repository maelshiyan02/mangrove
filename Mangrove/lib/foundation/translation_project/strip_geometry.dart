// B-2 · 长画布的条带几何（纯逻辑，可 headless）。
//
// 把「长画布上的像素坐标」↔「页内像素坐标 / 虚拟坐标」互相换算，并**按缝**
// 把一个跨缝的条带矩形切成 per-page 子矩形 —— 跨页框选的落盘就靠它。
//
// 🔴 本文件**不含 Flutter 依赖**（只 import `IntRect` 与 `cross_page_block.dart`），
// 所以条带↔页/虚拟的换算能被 headless 跑完。手势与绘制在 `StudioScrollCanvas`。
//
// ## 条带几何必须与画布一致
//
// 长画布自己算页高用的是 `min(1, 视口宽 / 页宽) * 页高`（见
// `studio_scroll_canvas.dart` 的 `_pageHeight`）。本模块把这同一条公式重新表达
// 一遍，[StripGeometry.build] 的 `maxFit`/`fallbackAspect` 就是那两个自由量；
// 两边不一致会让"拖出来的框"与"落盘的块"错位。
//
// 页在同一行居中：`leftOffset = (视口宽 - 渲染宽) / 2`，其中
// `渲染宽 = min(页宽, 视口宽)`（`maxFit = 1` 时）。
library;

import 'dart:math' as math;

import '../image_translation/translation_types.dart' show IntRect;
import 'cross_page_block.dart' show PageBand, SpanPart;

/// 一页在长画布里的度量。
class StripPageMetrics {
  const StripPageMetrics({
    required this.key,
    required this.naturalWidth,
    required this.naturalHeight,
    required this.renderedWidth,
    required this.renderedHeight,
    required this.leftOffset,
    required this.stripTop,
  });

  final String key;

  /// 页的源像素尺寸。
  final double naturalWidth;
  final double naturalHeight;

  /// 页在长画布里渲染出来的尺寸。
  final double renderedWidth;
  final double renderedHeight;

  /// 页在条带宽度内的水平偏移（页窄于视口时居中留出的空白）。
  final double leftOffset;

  /// 页顶在**条带内容坐标**里的 y。
  final double stripTop;

  /// 条带像素 / 页像素。
  double get fit => naturalWidth <= 0 ? 1 : renderedWidth / naturalWidth;

  double get stripBottom => stripTop + renderedHeight;

  /// 该页的页内矩形（`0,0,w,h`）。
  IntRect get pageRect =>
      IntRect(0, 0, naturalWidth.round(), naturalHeight.round());
}

/// 条带内容的整体几何。
class StripGeometry {
  StripGeometry(this.pages);

  final List<StripPageMetrics> pages;

  /// 无法预知页尺寸时的兜底宽高比（h / w），与长画布的默认值一致。
  static const double defaultAspect = 1.4;

  /// 由页 key + 源尺寸构造。`sizes` 与 `keys` 等长，元素为 null 表示该页尚未
  /// 解码、按 [fallbackAspect] 估高（与长画布的行为一致）。
  factory StripGeometry.build({
    required List<String> keys,
    required List<({double width, double height})?> sizes,
    required double viewportWidth,
    double gap = 0,
    double topPadding = 0,
    double fallbackAspect = defaultAspect,
    double maxFit = 1.0,
  }) {
    final vw = viewportWidth > 0 ? viewportWidth : 800.0;
    final result = <StripPageMetrics>[];
    var y = topPadding;
    for (var i = 0; i < keys.length; i++) {
      final size = i < sizes.length ? sizes[i] : null;
      double nw;
      double nh;
      if (size == null || size.width <= 0 || size.height <= 0) {
        nw = vw;
        nh = vw * fallbackAspect;
      } else {
        nw = size.width;
        nh = size.height;
      }
      final fit = math.min(maxFit, vw / nw);
      final rw = nw * fit;
      final rh = nh * fit;
      result.add(
        StripPageMetrics(
          key: keys[i],
          naturalWidth: nw,
          naturalHeight: nh,
          renderedWidth: rw,
          renderedHeight: rh,
          leftOffset: (vw - rw) / 2,
          stripTop: y,
        ),
      );
      y += rh + gap;
    }
    return StripGeometry(result);
  }

  bool get isEmpty => pages.isEmpty;

  /// 条带内容总高。
  double get contentHeight => pages.isEmpty ? 0 : pages.last.stripBottom;

  /// 每一道缝（下一页页顶）在条带坐标里的 y。
  List<double> get seamStripYs =>
      [for (var i = 1; i < pages.length; i++) pages[i].stripTop];

  /// [stripY] 落在哪一页；超出上下端则夹到首/末页。
  int? pageIndexAt(double stripY) {
    if (pages.isEmpty) return null;
    for (var i = 0; i < pages.length; i++) {
      if (stripY >= pages[i].stripTop && stripY < pages[i].stripBottom) return i;
    }
    return stripY < pages.first.stripTop ? 0 : pages.length - 1;
  }

  /// 条带坐标 → (页下标, 页内坐标)。
  ({int index, double x, double y})? toPage(double stripX, double stripY) {
    final index = pageIndexAt(stripY);
    if (index == null) return null;
    final page = pages[index];
    return (
      index: index,
      x: (stripX - page.leftOffset) / page.fit,
      y: (stripY - page.stripTop) / page.fit,
    );
  }

  /// 离 [stripY] 最近、且在 [threshold] 内的缝（返回其在条带坐标里的 y），
  /// 没有则 null。用于"缝线吸附/高亮"。
  double? nearestSeam(double stripY, {double threshold = 28}) {
    double? best;
    var bestDistance = double.infinity;
    for (final seam in seamStripYs) {
      final distance = (seam - stripY).abs();
      if (distance <= threshold && distance < bestDistance) {
        best = seam;
        bestDistance = distance;
      }
    }
    return best;
  }

  /// 把一个**条带坐标**矩形按缝切成 per-page 子矩形（页内像素），越页边界处被夹住。
  ///
  /// 单页内的框 → 1 段；跨缝的框 → ≥2 段。完全落在页外 / 退化（宽高为零）的段被丢弃。
  List<SpanPart> splitStripRect({
    required double left,
    required double top,
    required double right,
    required double bottom,
  }) {
    final parts = <SpanPart>[];
    for (final page in pages) {
      final t = math.max(top, page.stripTop);
      final b = math.min(bottom, page.stripBottom);
      if (b <= t) continue; // 竖向无交集
      final l = math.max(left, page.leftOffset);
      final r = math.min(right, page.leftOffset + page.renderedWidth);
      if (r <= l) continue; // 横向无交集
      final fit = page.fit;
      final pl = ((l - page.leftOffset) / fit).round();
      final pt = ((t - page.stripTop) / fit).round();
      final pr = ((r - page.leftOffset) / fit).round();
      final pb = ((b - page.stripTop) / fit).round();
      if (pr <= pl || pb <= pt) continue; // 取整后退化
      parts.add(SpanPart(page.key, IntRect(pl, pt, pr, pb)));
    }
    return parts;
  }

  /// 各页的 [PageBand]（源像素尺寸），供 `spanToVirtual` / `virtualOffsets` 使用。
  List<PageBand> bands() => [
        for (final page in pages)
          PageBand(page.key, page.naturalWidth.round(), page.naturalHeight.round()),
      ];
}