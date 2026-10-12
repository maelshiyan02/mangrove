// 原图文字取色（2026-10-11 · ⑦b）。
//
// 目标：识别阶段估计**原图文字的颜色**，让译文的观感与原文一致（白字配
// 白、红字配红），用户仍可在块面板手动覆盖。
//
// ## 口径来自 BT，不是自创
//
// `Ballonstranslator_win_minium/ballontranslator/utils/textblock_mask.py`:
//
//     def textrgb_calculator(img, text_mask, show_process=False):
//         text_mask = cv2.erode(text_mask, (3, 3), iterations=1)
//         usm_img = usm(img)
//         overall_meanrgb = np.mean(usm_img[np.where(text_mask==255)], axis=0)
//         return overall_meanrgb.astype(np.uint8)
//
// 三条：**腐蚀掩膜 → 锐化 → 掩膜内像素 RGB 均值**。我们照搬第 1 条与第 3 条，
// **不照搬第 2 条（USM 锐化）**：USM 是为强化扫描件上的糊字边缘服务的，而
// 我们的输入已经是检测框裁出来的原始像素；对清晰图做 USM 会把每个笔画的
// 内侧也提亮，反而把"文字色"往白推。取舍记在这里，不在代码里。
//
// ## 与既有 `_sampleColors` 的关系
//
// `translation_worker._sampleColors` 早就在做"分离两类取均值"，但它**没有
// 腐蚀** —— 掩膜里混着抗锯齿的过渡像素，取到的是"文字色与背景色的加权
// 平均"（黑字在白底上会取成深灰 60 而非 0）。BT 的腐蚀正是为去掉这批像素。
// 本模块是它的**更准版本**，并让前者转而调用它（见那里的注释），免得两条
// 口径并存漂移。
//
// 纯 Dart、零 Flutter 依赖：输入 [RgbaImage] + [IntRect]，输出 RGB。
// ⇒ 可以用**合成像素夹具**在 headless 做正反断言（A01 §3：本会话无渲染
// 表面，真实 webp 解码只能 GUI 验）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mangrove/foundation/image_translation/luma.dart';
import 'package:mangrove/foundation/image_translation/translation_types.dart';

/// 一次取色的结果。
class TextColorEstimate {
  const TextColorEstimate({
    required this.textRgb,
    required this.backgroundRgb,
    required this.textSamples,
    required this.backgroundSamples,
    required this.eroded,
    required this.contrast,
  });

  /// 文字（笔画）色 `[r, g, b]`。
  final List<int> textRgb;

  /// 背景（气泡填充）色 `[r, g, b]`。
  final List<int> backgroundRgb;

  /// 参与文字均值的像素数（腐蚀后的）。
  final int textSamples;

  /// 参与背景均值的像素数。
  final int backgroundSamples;

  /// 腐蚀是否成功。**false = 笔画太细**，腐蚀会把它们吃光，于是退回未腐蚀
  /// 的掩膜 —— 这时取到的色偏灰，但总比"取不到"强。
  final bool eroded;

  /// 文字与背景的亮度差（0..255）。用于决定要不要自动加描边。
  final double contrast;

  int get textArgb =>
      0xFF000000 | (textRgb[0] << 16) | (textRgb[1] << 8) | textRgb[2];

  int get backgroundArgb =>
      0xFF000000 |
      (backgroundRgb[0] << 16) |
      (backgroundRgb[1] << 8) |
      backgroundRgb[2];
}

/// 取样的像素上限（每边）。
///
/// 一个块可能有 800×600，全量逐像素做腐蚀 + 均值在整章跑时是几十万次
/// 循环/块。等距抽样到 ≤96×96 后，笔画在统计上仍有足够多的代表像素
/// （一个 40px 的字在 96×96 网格里约占 100 个采样点）。
const int _sampleEdge = 96;

/// 少数类的占比上限。
///
/// 文字在气泡里通常占 5%~30%。若"少数类"已经占了 40% 以上，那多半不是文字
/// 而是**两种背景**（网点/渐变被 Otsu 切成两半）—— 这时取任何一类当文字色
/// 都是错的，宁可返回 null。
const double _maxTextShare = 0.40;

/// 腐蚀后至少要剩这么多像素才接受腐蚀结果。
const int _minErodedSamples = 8;

/// 估计 [region] 内原图文字与背景的颜色。
///
/// 返回 null = "这块取不出可信的颜色"（太小、几乎纯色、文字占比不合理）。
/// **不抛异常**：它在识别管线里被逐块调用，一次抛异常会让整页的块都建不出来。
TextColorEstimate? estimateTextColor(RgbaImage image, IntRect region) {
  final w = image.width;
  final h = image.height;
  // 内缩 1px：块的 xyxy 有时正好压在气泡描边上，那一圈不是文字也不是背景。
  var left = (region.left + 1).clamp(0, w - 1);
  var top = (region.top + 1).clamp(0, h - 1);
  var right = (region.right - 1).clamp(1, w);
  var bottom = (region.bottom - 1).clamp(1, h);
  var rw = right - left;
  var rh = bottom - top;
  if (rw < 3 || rh < 3) return null;

  final stepX = math.max(1, (rw / _sampleEdge).ceil());
  final stepY = math.max(1, (rh / _sampleEdge).ceil());
  final cols = ((rw + stepX - 1) ~/ stepX);
  final rows = ((rh + stepY - 1) ~/ stepY);
  final n = cols * rows;
  if (n < 16) return null;

  final pixels = image.pixels;
  final lum = Uint8List(n);
  final red = Uint8List(n);
  final green = Uint8List(n);
  final blue = Uint8List(n);
  var idx = 0;
  for (var gy = 0; gy < rows; gy++) {
    final y = top + gy * stepY;
    if (y >= h) break;
    for (var gx = 0; gx < cols; gx++) {
      final x = left + gx * stepX;
      if (x >= w) break;
      final i = (y * w + x) * 4;
      final r = pixels[i];
      final g = pixels[i + 1];
      final b = pixels[i + 2];
      red[idx] = r;
      green[idx] = g;
      blue[idx] = b;
      lum[idx] = lumaOf(r, g, b);
      idx++;
    }
  }
  if (idx < 16) return null;

  final threshold = otsuThreshold(lum);
  // ---- 1) 建笔画掩膜：少数类即文字 ---------------------------------------
  //
  // 🔴 判据是"像素少的那一类"，不是"暗的那一类"。白底黑字与黑底白字都是
  // 常见排版（后者在夜间场景、反白 SFX 里到处都是），按亮度判会在其中一种
  // 上取反 —— 而取反后的颜色是**背景色**，画上去就是隐形的字。
  var loN = 0, hiN = 0;
  for (var i = 0; i < idx; i++) {
    if (lum[i] <= threshold) {
      loN++;
    } else {
      hiN++;
    }
  }
  if (loN == 0 || hiN == 0) return null; // 纯色区域：没有文字可谈
  final textIsLow = loN <= hiN;
  final textCount = textIsLow ? loN : hiN;
  final share = textCount / idx;
  if (share > _maxTextShare) return null;

  var mask = Uint8List(idx);
  for (var i = 0; i < idx; i++) {
    final isLow = lum[i] <= threshold;
    if (isLow == textIsLow) mask[i] = 1;
  }

  // ---- 2) 腐蚀一次：去掉抗锯齿边缘 ---------------------------------------
  //
  // 🔴 **这一步是 BT 口径的核心**，也是"取到的色像不像原字"的分水岭。一个
  // 黑笔画在白底上，笔画边缘有 1~2 圈过渡灰（(128,128,128) 之类）；不腐蚀
  // 就把它们算进均值，取出来是深灰而不是黑，画上去立刻"比原字淡"。
  var eroded = false;
  var used = mask;
  final erodedMask = _erode3x3(mask, cols, rows);
  var erodedCount = 0;
  for (var i = 0; i < idx; i++) {
    if (erodedMask[i] != 0) erodedCount++;
  }
  if (erodedCount >= _minErodedSamples) {
    used = erodedMask;
    eroded = true;
  }

  // ---- 3) 两类各自求均值 --------------------------------------------------
  var tr = 0, tg = 0, tb = 0, tn = 0;
  var br = 0, bg = 0, bb = 0, bn = 0;
  for (var i = 0; i < idx; i++) {
    if (used[i] != 0) {
      tr += red[i];
      tg += green[i];
      tb += blue[i];
      tn++;
    } else {
      br += red[i];
      bg += green[i];
      bb += blue[i];
      bn++;
    }
  }
  if (tn == 0 || bn == 0) return null;

  final textRgb = <int>[
    (tr / tn).round().clamp(0, 255),
    (tg / tn).round().clamp(0, 255),
    (tb / tn).round().clamp(0, 255),
  ];
  final bgRgb = <int>[
    (br / bn).round().clamp(0, 255),
    (bg / bn).round().clamp(0, 255),
    (bb / bn).round().clamp(0, 255),
  ];
  final contrast = (lumaOf(textRgb[0], textRgb[1], textRgb[2]) -
          lumaOf(bgRgb[0], bgRgb[1], bgRgb[2]))
      .abs()
      .toDouble();
  return TextColorEstimate(
    textRgb: textRgb,
    backgroundRgb: bgRgb,
    textSamples: tn,
    backgroundSamples: bn,
    eroded: eroded,
    contrast: contrast,
  );
}

/// 3×3 腐蚀（4 连通的弱化版：只要 8 邻域内有一个非笔画像素就吃掉）。
///
/// BT 用的是 OpenCV 的 3×3 矩形核，等价于"邻域全为 1 才保留"。这里同义。
Uint8List _erode3x3(Uint8List src, int cols, int rows) {
  final out = Uint8List(src.length);
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < cols; x++) {
      final i = y * cols + x;
      if (src[i] == 0) continue;
      var keep = true;
      for (var dy = -1; dy <= 1 && keep; dy++) {
        final ny = y + dy;
        if (ny < 0 || ny >= rows) {
          keep = false;
          break;
        }
        for (var dx = -1; dx <= 1; dx++) {
          final nx = x + dx;
          if (nx < 0 || nx >= cols) {
            keep = false;
            break;
          }
          if (src[ny * cols + nx] == 0) {
            keep = false;
            break;
          }
        }
      }
      out[i] = keep ? 1 : 0;
    }
  }
  return out;
}
