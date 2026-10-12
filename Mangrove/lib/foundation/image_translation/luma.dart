// 亮度统计的**唯一实现**（2026-10-11 · ⑦b）。
//
// 🔴 为什么单独一个文件：Otsu 阈值此前在仓库里有**两份**逐行相同的实现
// （`inpaint._otsu` 用 `Uint8List`、`translation_worker._otsuOf` 用
// `List<int>`），本轮取色又要第三份。三份同一算法 = 三处可以各自漂移，而
// 它们判的是同一件事（"哪些像素是笔画"）—— 一旦不一致，抹字抹掉的与取色
// 取到的就不是同一批像素，且不报错。
//
// 纯 Dart，零 Flutter 依赖 ⇒ headless 可断言。
library;

import 'dart:typed_data';

/// Otsu's method: the luminance threshold that maximises between-class
/// variance.
///
/// 256-bin histogram, one pass to accumulate, one pass over thresholds. Returns
/// 127 for an empty sample (callers must check their own sample count — a
/// threshold over nothing is meaningless, and this file will not guess).
int otsuThreshold(List<int> lum) {
  var hist = Int32List(256);
  for (var l in lum) {
    if (l < 0 || l > 255) continue;
    hist[l]++;
  }
  var total = 0;
  for (var t = 0; t < 256; t++) {
    total += hist[t];
  }
  if (total == 0) return 127;
  var sum = 0.0;
  for (var t = 0; t < 256; t++) {
    sum += t * hist[t];
  }
  var sumB = 0.0;
  var wB = 0;
  var maxVar = -1.0;
  var threshold = 127;
  for (var t = 0; t < 256; t++) {
    wB += hist[t];
    if (wB == 0) continue;
    var wF = total - wB;
    if (wF == 0) break;
    sumB += t * hist[t];
    var mB = sumB / wB;
    var mF = (sum - sumB) / wF;
    var between = wB * wF * (mB - mF) * (mB - mF);
    if (between > maxVar) {
      maxVar = between;
      threshold = t;
    }
  }
  return threshold;
}

/// Mean luminance of the pixels at or below [threshold] and above it.
///
/// Empty classes fall back to the threshold value rather than 0: an empty
/// class has no colour to report, and handing back 0 would read as "black ink"
/// to a caller that is deciding which class is the text.
(double, double) classMeans(List<int> lum, int threshold) {
  var loSum = 0, loN = 0, hiSum = 0, hiN = 0;
  for (var l in lum) {
    if (l <= threshold) {
      loSum += l;
      loN++;
    } else {
      hiSum += l;
      hiN++;
    }
  }
  var lo = loN == 0 ? threshold.toDouble() : loSum / loN;
  var hi = hiN == 0 ? threshold.toDouble() : hiSum / hiN;
  return (lo, hi);
}

/// Rec. 601 luma, clamped to 0..255.
int lumaOf(int r, int g, int b) =>
    (0.299 * r + 0.587 * g + 0.114 * b).round().clamp(0, 255);
