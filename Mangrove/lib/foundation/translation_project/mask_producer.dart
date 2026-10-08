import 'dart:typed_data';

import '../image_translation/inpaint.dart';
import '../image_translation/translation_types.dart';
import 'gray_png.dart';

/// 一页的 mask 生产结果：整页灰度位图 + 写入统计。
///
/// 语义与 FT / BT 一致：**255 = 需要被修复（抹掉）的像素，0 = 保留**。
/// 极性不是随手定的 —— `patch_match.py` 的 `PM_inpaint` 把 mask 直接当
/// "要补的洞"，`drawing_commands.py` 的 `undo` 又用 `mask > 0` 判"这块被
/// 抹过"，两处都要求 **非零 = 已抹**。
class MaskPage {
  MaskPage(this.width, this.height, this.pixels, this.strokes, this.regions);

  final int width;
  final int height;

  /// Row-major greyscale, length `width * height`.
  final Uint8List pixels;

  /// 前景像素总数（诊断用；为 0 说明这一页什么都没抹到）。
  final int strokes;

  /// 真正产出掩膜的 region 数（`computeMask` 返回 null 的不算）。
  final int regions;

  bool get isEmpty => strokes == 0;

  Uint8List encode() => GrayPng.encode(width, height, pixels);
}

/// 把 [image] 上 [regions] 的**字形级**掩膜拼成一张整页灰度图。
///
/// ## 为什么是字形级而不是矩形（S-N3 的核心决定）
///
/// `mask/` 在 FT 里的角色是"哪些像素被抹了"。写成块外框会造出一个**同名但
/// 语义不同**的文件：下游（BT 打开这个工程、或未来接 AI inpaint）会拿它当
/// 字形级掩膜用，于是把气泡里的整块背景也当成待修复区域 —— 抹得越狠越糊。
/// 本项目最忌讳的就是这种"静默分歧"，所以宁可慢一点也不走矩形近似。
///
/// ## 逐 region 累积而不是逐 region 覆盖
///
/// 多个 region 的窗口可能重叠（FT 的块外框常常交叠）。用**或**累积而不是
/// 后写覆盖：覆盖会让"后一个 region 的窗口恰好不含前一个的笔画"变成一次
/// 静默丢失，而重复抹同一处像素是无害的。
MaskPage buildMaskPage(RgbaImage image, List<IntRect> regions) {
  final w = image.width;
  final h = image.height;
  final page = Uint8List(w * h);
  var strokes = 0;
  var used = 0;
  for (final rect in regions) {
    final m = TextInpainter.computeMask(image, rect);
    if (m == null) continue;
    used++;
    // 窗口可能只覆盖页面一部分（`computeMask` 会 clamp 到图像边界），逐行
    // 夹取而不是信任它 —— 越界写入会静默截断 Uint8List 或抛越界，两者都比
    // "少抹几个边缘像素"难排查。
    final x0 = m.left < 0 ? 0 : m.left;
    final y0 = m.top < 0 ? 0 : m.top;
    final x1 = m.left + m.rw > w ? w : m.left + m.rw;
    final y1 = m.top + m.rh > h ? h : m.top + m.rh;
    for (var y = y0; y < y1; y++) {
      final srcRow = (y - m.top) * m.rw;
      final dstRow = y * w;
      for (var x = x0; x < x1; x++) {
        if (m.mask[srcRow + (x - m.left)] == 0) continue;
        // 已是 1 就不必重复计数，否则重叠 region 会把 strokes 报虚高。
        if (page[dstRow + x] == 0) strokes++;
        page[dstRow + x] = 255;
      }
    }
  }
  return MaskPage(w, h, page, strokes, used);
}

/// 「抹字复原」：用已有的 mask 把**原文**放回已抹掉的那张底图上。
///
/// ## 这不是 BT 的功能，是本项目补的一个能力
///
/// BT 只有单向的"抹"（`InpaintCommand`）与它自己的撤销栈；它的 `erase` 分支
/// （`drawingpanel.py:915`）是把**原图按 mask 混合回 inpaint 结果**，而不是
/// 从 inpaint 结果重建一张新底图。也就是说 BT 复原的是"这一次误擦"，
/// 而这里复原的是"整张底图退回未抹状态"—— 两者用途不同。
///
/// ## 判据：必须是**同一张**原图与同一份 mask
///
/// [mask] 与 [inpainted] 尺寸不一致时返回 null 而不是拉伸：拉伸会把 mask
/// 套到错误的像素上，产出一张"看起来抹了但位置全错"的底图，而且不报错。
Uint8List? restoreErasedPage({
  required RgbaImage original,
  required RgbaImage inpainted,
  required Uint8List mask,
}) {
  final w = original.width;
  final h = original.height;
  if (inpainted.width != w || inpainted.height != h) return null;
  if (mask.length != w * h) return null;
  // 逐字节还原成一张新图，不改入参 —— 调用方可能还想留着 inpainted/
  // 去比对，函数悄悄改掉入参会让"复原前后对比"变成同一份数据。
  final out = Uint8List.fromList(inpainted.pixels);
  var restored = 0;
  for (var i = 0; i < w * h; i++) {
    if (mask[i] == 0) continue;
    final s = i * 4;
    out[s] = original.pixels[s];
    out[s + 1] = original.pixels[s + 1];
    out[s + 2] = original.pixels[s + 2];
    out[s + 3] = original.pixels[s + 3];
    restored++;
  }
  return restored == 0 ? null : out;
}

/// mask 灰度图里前景（=被抹）像素的占比，用于日志与诊断。
double maskCoverage(MaskPage page) {
  if (page.width <= 0 || page.height <= 0) return 0;
  return page.strokes / (page.width * page.height);
}