/// 几何掩膜与「按掩膜」的像素操作 —— 多边形精确擦除 / 马赛克。
///
/// 纯 Dart，**不依赖 `dart:ui`**，因此可以 headless 断言（与
/// `mask_producer.dart` / `block_artifacts.dart` 同一层）。
///
/// ## 为什么需要这一层
///
/// [buildMaskPage] 产出的字形级掩膜仍以块的外接矩形为窗口：多边形块（自由
/// 画笔圈出的水印/logo）若直接按矩形擦除，会把轮廓**外面**但落在矩形内的
/// 线条、网点一并抹掉。本文件把多边形栅格化成整页掩膜，再与字形掩膜取交，
/// 从而做到"只擦轮廓内的笔画"。
///
/// 掩膜极性沿用全项目的约定：**255 = 需要处理，0 = 保留**。
library;

import 'dart:typed_data';

import 'package:mangrove/foundation/image_translation/inpaint.dart';
import 'package:mangrove/foundation/image_translation/translation_types.dart';

/// 把多边形（源像素顶点 `[[x, y], ...]`）栅格化成整页掩膜。
///
/// 采用 **scanline + 奇偶规则**：对每条扫描线取像素中心 `y + 0.5`，求与各边
/// 的交点、排序后两两填充。复杂度 `O(bbox_h * edges * log edges)`，只扫多边形
/// 外接行，不遍历整页。
///
/// 顶点少于 3 个、或退化成零面积时返回全 0（调用方据此判"不可用"）。
Uint8List rasterizePolygon({
  required int width,
  required int height,
  required List<List<double>> polygon,
}) {
  final out = Uint8List(width * height);
  if (width <= 0 || height <= 0 || polygon.length < 3) return out;

  var minY = double.infinity;
  var maxY = double.negativeInfinity;
  var minX = double.infinity;
  var maxX = double.negativeInfinity;
  for (final p in polygon) {
    final x = p[0];
    final y = p[1];
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
  }
  if (!minY.isFinite || !maxY.isFinite) return out;
  // 夹到图像范围；`int` 运算，避免 num 下标。
  var yStart = minY.floor() - 1;
  if (yStart < 0) yStart = 0;
  var yEnd = maxY.ceil() + 1;
  if (yEnd > height) yEnd = height;

  final n = polygon.length;
  final xs = <double>[];
  for (var y = yStart; y < yEnd; y++) {
    final yc = y + 0.5;
    xs.clear();
    for (var i = 0; i < n; i++) {
      final a = polygon[i];
      final b = polygon[(i + 1) % n];
      final y1 = a[1];
      final y2 = b[1];
      // 半开区间，避免顶点恰好落在扫描线上时被重复计数。
      if ((y1 <= yc && y2 > yc) || (y2 <= yc && y1 > yc)) {
        final t = (yc - y1) / (y2 - y1);
        xs.add(a[0] + t * (b[0] - a[0]));
      }
    }
    if (xs.length < 2) continue;
    xs.sort();
    final row = y * width;
    for (var k = 0; k + 1 < xs.length; k += 2) {
      var x0 = xs[k].floor();
      var x1 = xs[k + 1].ceil();
      if (x1 <= x0) continue;
      if (x0 < 0) x0 = 0;
      if (x1 > width) x1 = width;
      for (var x = x0; x < x1; x++) {
        out[row + x] = 255;
      }
    }
  }
  // minX/maxX 仅用于退化成零面积的快速判断。
  if (maxX <= minX) return Uint8List(width * height);
  return out;
}

/// 把矩形栅格化成整页掩膜（马赛克等不依赖字形、只依赖范围的操作用）。
Uint8List rasterizeRect({
  required int width,
  required int height,
  required IntRect rect,
}) {
  final out = Uint8List(width * height);
  if (width <= 0 || height <= 0) return out;
  var x0 = rect.left;
  var y0 = rect.top;
  var x1 = rect.right;
  var y1 = rect.bottom;
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > width) x1 = width;
  if (y1 > height) y1 = height;
  for (var y = y0; y < y1; y++) {
    final row = y * width;
    for (var x = x0; x < x1; x++) {
      out[row + x] = 255;
    }
  }
  return out;
}

/// 选区的**唯一真相**：写入的硬边界。
///
/// 🔴 P48 五轮：修图的写入范围必须**恰好等于用户画的那个范围**。此前的实现
/// 让水印的物体级掩膜自由长到外扩 30% 的上下文里，结果"外圈被一起改了"、
/// "上方白边被拉下来"（用户两张截图，第 7 / 10 页）。上下文只能**读**，
/// 不能**写** —— 本函数产出的掩膜就是写入的硬边界。
///
/// ## 为什么多边形还要再和矩形取交集
///
/// 用户的原始诉求是两条，缺一不可：
/// 1. "修图范围限制在画笔不规则框中" —— 所以**形状**听多边形的；
/// 2. "修改的范围明显多了一圈……只要修框选范围内的部分" —— 所以**不得超过块框**。
///
/// 真实数据里这两条会打架：`003.webp` 那条手绘 lasso 有 196 个顶点，包围盒
/// (372,415,224,108) 比水印块框 (389.5,437.1,585,487.4) 高出一圈，下缘压到
/// 蓝色头发上。纯按多边形涂黑会把头发一起刷黑 —— 用户看到的就是"又多了
/// 一圈"。取交集后既保留不规则形状，又钉死块框这条上界。
///
/// 唯一例外：交集为空（画笔整个画在块框外面）。这时说明用户是**有意**在框
/// 外作业，退回纯多边形，否则会"点了没反应"。
Uint8List selectionMaskOf({
  required int width,
  required int height,
  required IntRect rect,
  List<List<double>>? polygon,
}) {
  if (polygon != null && polygon.length >= 3) {
    final mask = rasterizePolygon(
      width: width,
      height: height,
      polygon: polygon,
    );
    var any = false;
    for (final v in mask) {
      if (v != 0) {
        any = true;
        break;
      }
    }
    // 退化多边形（顶点共线、面积≈0）时栅格化结果为空 —— 这时退回矩形，
    // 否则"点了没反应"。
    if (!any) return rasterizeRect(width: width, height: height, rect: rect);

    final box = rasterizeRect(width: width, height: height, rect: rect);
    final clipped = Uint8List(mask.length);
    var kept = 0;
    for (var i = 0; i < mask.length; i++) {
      if (mask[i] == 0 || box[i] == 0) continue;
      clipped[i] = 255;
      kept++;
    }
    // 交集为空 ⇒ 画笔整个画在块框外，说明用户是有意在框外作业。
    return kept == 0 ? mask : clipped;
  }
  return rasterizeRect(width: width, height: height, rect: rect);
}

/// 点是否落在多边形内（射线法）。用于把 OCR 检测框过滤到画笔轮廓内。
bool pointInPolygon(List<List<double>> polygon, double x, double y) {
  final n = polygon.length;
  if (n < 3) return false;
  var inside = false;
  for (var i = 0, j = n - 1; i < n; j = i++) {
    final xi = polygon[i][0];
    final yi = polygon[i][1];
    final xj = polygon[j][0];
    final yj = polygon[j][1];
    if ((yi > y) != (yj > y)) {
      final xInt = xi + (y - yi) / (yj - yi) * (xj - xi);
      if (x < xInt) inside = !inside;
    }
  }
  return inside;
}

/// 两张同尺寸整页掩膜取交（都为非零才保留）。
Uint8List intersectPageMasks(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    throw ArgumentError('mask size mismatch: ${a.length} vs ${b.length}');
  }
  final out = Uint8List(a.length);
  for (var i = 0; i < out.length; i++) {
    out[i] = (a[i] != 0 && b[i] != 0) ? 255 : 0;
  }
  return out;
}

/// 只抹 [pageMask] 非零的像素（**按掩膜精确抹字**）。
///
/// 与 [TextInpainter.erase] 的区别：后者按 rect 现算字形掩膜，本函数接受
/// 外部给定的精确掩膜（如多边形裁剪结果）。实现上把掩膜的外接窗口包成一个
/// [TextMask] 交给 [TextInpainter.eraseWithMask]，因此填充算法与整页路径
/// 完全一致（`_fillNearest` + `_relax`），只是作用域被掩膜收窄。
///
/// 返回实际被抹的像素数；0 表示掩膜为空（调用方据此跳过）。
int erasePageMaskInPlace(RgbaImage image, Uint8List pageMask) {
  final w = image.width;
  final h = image.height;
  if (pageMask.length != w * h) {
    throw ArgumentError('mask size mismatch: ${pageMask.length} vs ${w * h}');
  }
  var minX = w;
  var minY = h;
  var maxX = -1;
  var maxY = -1;
  var count = 0;
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      if (pageMask[row + x] == 0) continue;
      count++;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  if (count == 0) return 0;

  final rw = maxX - minX + 1;
  final rh = maxY - minY + 1;
  final local = Uint8List(rw * rh);
  for (var y = 0; y < rh; y++) {
    final src = (minY + y) * w + minX;
    final dst = y * rw;
    for (var x = 0; x < rw; x++) {
      if (pageMask[src + x] != 0) local[dst + x] = 1;
    }
  }
  TextInpainter.eraseWithMask(image, TextMask(minX, minY, rw, rh, local));
  return count;
}

/// 把 [regionMask] 内的像素按 [blockSize] 方块**马赛克化**（每块取掩膜内
/// 像素均值，再写回块内所有掩膜像素）。
///
/// 水印的一种"不擦除、只不可读"处理：保留原图的构图与色调，只破坏字迹的
/// 可读性。返回被改写的像素数；0 表示掩膜为空。
int mosaicPageMaskInPlace(
  RgbaImage image,
  Uint8List regionMask, {
  int blockSize = 10,
}) {
  final w = image.width;
  final h = image.height;
  if (regionMask.length != w * h) {
    throw ArgumentError('mask size mismatch: ${regionMask.length} vs ${w * h}');
  }
  final bs = blockSize < 2 ? 2 : blockSize;

  var minX = w;
  var minY = h;
  var maxX = -1;
  var maxY = -1;
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      if (regionMask[row + x] == 0) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  if (maxX < 0) return 0;

  final px = image.pixels;
  var changed = 0;
  for (var by = minY; by <= maxY; by += bs) {
    var ye = by + bs - 1;
    if (ye > maxY) ye = maxY;
    for (var bx = minX; bx <= maxX; bx += bs) {
      var xe = bx + bs - 1;
      if (xe > maxX) xe = maxX;
      var r = 0;
      var g = 0;
      var b = 0;
      var a = 0;
      var n = 0;
      for (var y = by; y <= ye; y++) {
        final row = y * w;
        for (var x = bx; x <= xe; x++) {
          if (regionMask[row + x] == 0) continue;
          final i = (row + x) * 4;
          r += px[i];
          g += px[i + 1];
          b += px[i + 2];
          a += px[i + 3];
          n++;
        }
      }
      if (n == 0) continue;
      final ar = r ~/ n;
      final ag = g ~/ n;
      final ab = b ~/ n;
      final aa = a ~/ n;
      for (var y = by; y <= ye; y++) {
        final row = y * w;
        for (var x = bx; x <= xe; x++) {
          if (regionMask[row + x] == 0) continue;
          final i = (row + x) * 4;
          px[i] = ar;
          px[i + 1] = ag;
          px[i + 2] = ab;
          px[i + 3] = aa;
          changed++;
        }
      }
    }
  }
  return changed;
}
