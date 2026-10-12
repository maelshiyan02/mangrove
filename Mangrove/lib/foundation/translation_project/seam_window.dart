// B-2 · 缝窗口（临时拼接，用完即弃）的纯逻辑（跨页拼接计划 §4-B2）。
//
// 铁律：「**不落盘任何合成图**」。物理拼接只存在于内存、只在识别那一瞬间、
// 用完即弃 —— 本文件只在 `RgbaImage` 层做像素拷贝，**不碰文件系统、不碰 `dart:ui`**。
//
// 缝窗口 = 页 A 的**底部条带** + 页 B 的**顶部条带**，零间隙拼成一张临时图；
// 在它上面跑现有检测/OCR 拿候选框，再把候选框映射回虚拟坐标（人工确认后落盘）。
//
// 🔴 本文件**不含 Flutter 依赖**，所以窗口构造、拼接、坐标映射都能 headless 跑完。
library;

import 'dart:typed_data';

import '../image_translation/translation_types.dart' show IntRect, RgbaImage;

/// 缝窗口：页 A 底部条带 + 页 B 顶部条带，零间隙拼成一张临时图。
class SeamWindow {
  const SeamWindow({required this.topHeight, required this.bottomHeight});

  /// 从页 A **底部**取多少行。
  final int topHeight;

  /// 从页 B **顶部**取多少行。
  final int bottomHeight;

  /// 临时图的总高。
  int get height => topHeight + bottomHeight;
}

/// 缝窗口的默认取条比例（页 A 底 35% + 页 B 顶 35%，§4-B2）。
const double seamWindowFraction = 0.35;

/// 缝窗口高度封顶（像素）。**超过即拒绝**，不静默缩到封顶 —— 否则"全幅拼接"
/// 会被悄悄放行，正是 §4-B2 要禁止的（断言②故障路径）。
///
/// 默认 = 一页高量级（2400）：正常 0.35 比例的两条 ≈ 0.7 页 < 封顶；
/// 全幅（fraction = 1.0）两条 = 2 页 > 封顶 ⇒ 拒绝。
const int seamWindowCap = 2400;

/// 构造缝窗口。**比例非法 / 页高非正 / 超过封顶 ⇒ 返回 null（拒绝）**。
SeamWindow? buildSeamWindow({
  required int pageAHeight,
  required int pageBHeight,
  double fraction = seamWindowFraction,
  int cap = seamWindowCap,
}) {
  if (fraction <= 0 || fraction > 1) return null;
  if (pageAHeight <= 0 || pageBHeight <= 0) return null;
  final top = (pageAHeight * fraction).round().clamp(1, pageAHeight);
  final bottom = (pageBHeight * fraction).round().clamp(1, pageBHeight);
  final window = SeamWindow(topHeight: top, bottomHeight: bottom);
  if (window.height > cap) return null; // 全幅拼接被拒
  return window;
}

/// 把两页的条带拼成一张临时图（**内存**）。两页**宽度不同 ⇒ 返回 null**（D12）；
/// 条带高超过对应页高 ⇒ 返回 null。
RgbaImage? stitchSeamWindow({
  required RgbaImage above,
  required RgbaImage below,
  required SeamWindow window,
}) {
  if (above.width != below.width) return null;
  if (window.topHeight > above.height || window.bottomHeight > below.height) {
    return null;
  }
  final w = above.width;
  final h = window.height;
  final rowBytes = w * 4;
  final out = Uint8List(w * h * 4);
  // 页 A 底部 topHeight 行 -> 输出顶部
  final aStart = (above.height - window.topHeight) * rowBytes;
  out.setRange(0, window.topHeight * rowBytes, above.pixels, aStart);
  // 页 B 顶部 bottomHeight 行 -> 输出底部
  final bStart = window.topHeight * rowBytes;
  out.setRange(bStart, bStart + window.bottomHeight * rowBytes, below.pixels, 0);
  return RgbaImage(w, h, out);
}

/// 缝窗口内的矩形（左上为 `(0,0)`）→ **虚拟坐标**（页 A 顶部为 `y=0`）。
///
/// 窗口的 `y=0` 对应页 A 的 `pageAHeight - topHeight` 行。
IntRect windowRectToVirtual(
  IntRect windowRect, {
  required int pageAHeight,
  required SeamWindow window,
}) {
  final base = pageAHeight - window.topHeight;
  return IntRect(
    windowRect.left,
    windowRect.top + base,
    windowRect.right,
    windowRect.bottom + base,
  );
}

/// 虚拟坐标矩形 → 缝窗口内矩形（[windowRectToVirtual] 的逆）。
IntRect virtualRectToWindow(
  IntRect virtualRect, {
  required int pageAHeight,
  required SeamWindow window,
}) {
  final base = pageAHeight - window.topHeight;
  return IntRect(
    virtualRect.left,
    virtualRect.top - base,
    virtualRect.right,
    virtualRect.bottom - base,
  );
}