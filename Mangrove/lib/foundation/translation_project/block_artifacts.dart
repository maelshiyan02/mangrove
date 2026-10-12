/// 单块级修图 / 复原的**纯 Dart 像素核心**（无 `dart:ui`，可 headless 断言）。
///
/// 与整页修图（`result_renderer.renderInpaintedPage` / `renderMaskPage`）的
/// 分工：
///
/// * 整页路径从**原图**重算这一页所有块的 mask / inpainted；
/// * 单块路径必须**只动一个块覆盖的像素**，保住同页其他块已经抹好的底图与
///   已经填好的译文 —— 所以不能"从原图重擦整页"（那会把其他块的原字擦回来），
///   也不能"在现有 inpainted 上再擦一遍"（对已抹底图重复 inpaint 会逐次变糊，
///   见 `renderInpaintedPage` 的文档）。
///
/// 做法：用原图擦**这一个块**得到 `erasedBlock`（整页尺寸，块外逐字节等于
/// 原图），再把它在 [mergeRepairedInpainted] 里**只在本块掩膜像素上**替换进
/// 现有底图。掩膜是字形级的（`buildMaskPage`），而 `TextInpainter.erase`
/// 只改写掩膜像素（`_fillNearest` / `_relax` 都以 `mask[i] == 0` 跳过），
/// 所以"只替换掩膜像素"恰好覆盖全部被算法动过的像素，一个不多一个不少。
library;

import 'dart:typed_data';

import '../image_translation/translation_types.dart';

/// 把"只擦了这一块"的整页图 [erasedBlock] 合并进已有的去字底图
/// [existingInpainted]（可为 null —— 这是本页第一次修图）。
///
/// 语义：
/// * [existingInpainted] == null → 输出就是 [erasedBlock]（块外 = 原图，
///   块内 = 新抹的像素）；
/// * 否则输出以**现有底图**为底（保住其他块），仅在 [blockMask] 非零的
///   字形像素上换成 [erasedBlock] 的值。
///
/// 🔴 为什么不能整块矩形替换：FT 的块框经常交叠（"大框套小框"、气泡跨块）。
/// 整块外框替换会把窗口内属于**另一个块**、已抹好的像素用原图盖回去 ——
/// 字形级掩膜把替换严格限制在本块笔画上。
///
/// 尺寸不一致返回 null（调用方应报错而不是拉伸）；输入**不被修改**
/// （返回新缓冲，调用方可能要留着做前后对比）。
Uint8List? mergeRepairedInpainted({
  required RgbaImage erasedBlock,
  required Uint8List blockMask,
  RgbaImage? existingInpainted,
}) {
  final w = erasedBlock.width;
  final h = erasedBlock.height;
  if (blockMask.length != w * h) return null;
  if (existingInpainted != null &&
      (existingInpainted.width != w || existingInpainted.height != h)) {
    return null;
  }
  final base = existingInpainted?.pixels ?? erasedBlock.pixels;
  final out = Uint8List.fromList(base);
  if (identical(base, erasedBlock.pixels)) {
    // 第一次修图：erasedBlock 本身就是答案，复制一份保持"不改入参"的统一语义。
    return out;
  }
  final src = erasedBlock.pixels;
  for (var i = 0; i < w * h; i++) {
    if (blockMask[i] == 0) continue;
    final s = i * 4;
    out[s] = src[s];
    out[s + 1] = src[s + 1];
    out[s + 2] = src[s + 2];
    out[s + 3] = src[s + 3];
  }
  return out;
}

/// 两张同尺寸灰度掩膜的**或**：本块掩膜并进已有掩膜（255 = 被抹）。
///
/// [existing] 为 null 时直接复制 [added]。重复抹同一处像素无害，但不能
/// 覆盖式写（`buildMaskPage` 的同一条理由：重叠窗口里后写会静默丢笔画）。
Uint8List unionMasks({
  required Uint8List added,
  Uint8List? existing,
}) {
  if (existing == null) return Uint8List.fromList(added);
  if (existing.length != added.length) {
    throw ArgumentError('mask size mismatch: ${existing.length} vs ${added.length}');
  }
  final out = Uint8List(existing.length);
  for (var i = 0; i < out.length; i++) {
    out[i] = (existing[i] != 0 || added[i] != 0) ? 255 : 0;
  }
  return out;
}

/// 从 [from] 里扣除 [removed] 覆盖的像素（本块复原后，mask 上不再有它）。
Uint8List subtractMasks({
  required Uint8List from,
  required Uint8List removed,
}) {
  if (from.length != removed.length) {
    throw ArgumentError('mask size mismatch: ${from.length} vs ${removed.length}');
  }
  final out = Uint8List(from.length);
  for (var i = 0; i < out.length; i++) {
    out[i] = (from[i] != 0 && removed[i] == 0) ? 255 : 0;
  }
  return out;
}

/// 两张掩膜的**与**：复原时只盖回"原字检测到 **且** 之前确实被抹过"的像素。
///
/// 🔴 为什么复原掩膜要与现有 mask 取交：`buildRestorationMask` 在外扩窗口内
/// 检测到的字形可能属于**交叠的另一个块**。那个块若没被抹过（不在现有
/// mask 上），它在 inpainted 里本来就等于原图，盖回去是 no-op；但若它也
/// 被抹过，直接盖回会**把另一个块的修图也撤销**。取交把复原严格限定在
/// "这一页真的被抹过、且属于本块外扩范围"的像素上。
Uint8List intersectMasks(Uint8List a, Uint8List b) {
  if (a.length != b.length) {
    throw ArgumentError('mask size mismatch: ${a.length} vs ${b.length}');
  }
  final out = Uint8List(a.length);
  for (var i = 0; i < out.length; i++) {
    out[i] = (a[i] != 0 && b[i] != 0) ? 255 : 0;
  }
  return out;
}

/// 掩膜里是否还有前景（被抹）像素。
bool maskHasAny(Uint8List mask) {
  for (final p in mask) {
    if (p != 0) return true;
  }
  return false;
}
