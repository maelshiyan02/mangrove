/// ONNX 版「AI 修复填充」—— LaMa（Resolution-robust Large Mask Inpainting）。
///
/// 纯 Dart + FFI，复用 [OrtFfiSession]（`ort_ffi.dart`），**不经过 platform
/// channel**：插件的 handler 会把多 MB 张量在 UI 线程上来回拷，卡死界面；而
/// 修复是单次点击的重活，跑在独立 isolate 里阻塞没关系。
///
/// ## 为什么需要模型（P48 五轮）
///
/// 本地经典算法（方向性插值 / patch 合成）在**结构**上是盲的：它不知道
/// "这是一条裙子""这是对话框"，只会把邻域颜色往洞里推。于是：
/// * 第 3 页黑底水印 → 补成黑到紫的渐变（用户："根本不需要，全部涂黑"）；
/// * 第 7 页裙子上的水印 → 纹理被抹平；
/// * 第 10 页气泡 → 拉上方的白边下来，还留半笔字。
///
/// 纯色底这三种里前两种能靠 [detectFlatBackground] 解决，但纹理底（裙子、
/// 网点、渐变网点）只能靠模型。
///
/// ## 模型契约（Carve/LaMa-ONNX, Apache-2.0）
///
/// * 输入 `image`：`[1,3,512,512]` float32，RGB，`0..1`；
/// * 输入 `mask`：`[1,1,512,512]` float32，`{0,1}`，**1 = 要修**；
/// * 输出：`[1,3,512,512]` float32，RGB，`0..255`（该仓库导出未归一化）。
///
/// 尺寸固定 512：把「选区 + 30% 上下文」的方块缩放到 512，推理后缩回原尺寸，
/// **只把选区内的像素贴回**。上下文只用于让模型理解结构，绝不写回 —— 这是
/// 用户明确要求的那条纪律。
library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mangrove/foundation/image_translation/ort_ffi.dart';
import 'package:mangrove/foundation/image_translation/translation_types.dart';
import 'package:mangrove/foundation/image_translation/translation_models.dart';

/// 一次模型推理的结果。
class ModelInpaintResult {
  const ModelInpaintResult({
    required this.rgba,
    required this.regionPixels,
    required this.crop,
    required this.elapsedMs,
  });

  /// 整页 RGBA（**新缓冲**，选区外与原像素逐字节相同）。
  final Uint8List rgba;
  final int regionPixels;

  /// 实际送进模型的方形裁剪框（源像素）。
  final IntRect crop;
  final int elapsedMs;
}

/// LaMa 修复的统一入口。
abstract class InpaintModel {
  /// 模型是否已下载（设置 → 翻译模型 → 图像修复）。
  static bool get isInstalled => TranslationModels.inpaintLama.isInstalled;

  static String get modelPath =>
      TranslationModels.inpaintLama.filePath('inpaint.onnx');

  /// 模型在 UI 上显示的尺寸说明（MB）。
  static int get approxSizeMb =>
      TranslationModels.inpaintLama.approxSizeBytes ~/ 1000000;

  /// 在 [rgba] 的**副本**上修复 [regionMask] 覆盖的像素。
  ///
  /// [contextExpand] 是送给模型的上下文比例（默认 0.30 = 每边外扩 15%，
  /// 总尺寸 ×1.3）。上下文只读；写回严格限制在 [regionMask] 内。
  ///
  /// 返回 null 表示模型不可用或选区为空 —— 调用方据此回退本地算法。
  static Future<ModelInpaintResult?> inpaintRegion({
    required Uint8List rgba,
    required int width,
    required int height,
    required Uint8List regionMask,
    double contextExpand = 0.30,
    int modelSize = 512,
  }) async {
    if (!isInstalled) return null;
    if (rgba.length != width * height * 4) return null;
    if (regionMask.length != width * height) return null;

    final bounds = _maskBounds(regionMask, width, height);
    if (bounds == null) return null;

    final crop = _squareCrop(bounds, width, height, contextExpand);
    final prepared = _prepareInputs(
      rgba: rgba,
      width: width,
      height: height,
      regionMask: regionMask,
      crop: crop,
      size: modelSize,
    );
    if (prepared == null) return null;

    final started = DateTime.now();
    // 🔴 路径必须在**主 isolate 里**求值再捕获：`TranslationModels.*.filePath`
    // 依赖 `App.dataPath`，新 isolate 里 App 未必初始化过，闭包里再取会抛。
    final path = modelPath;
    final Float32List? output;
    try {
      output = await Isolate.run(
        () => _runLama(
          modelPath: path,
          image: prepared.image,
          mask: prepared.mask,
          size: modelSize,
        ),
      );
    } catch (_) {
      // 模型损坏 / 运行时不匹配 / 内存不足：交给调用方回退，不把异常抛到 UI。
      return null;
    }
    if (output == null) return null;

    final out = Uint8List.fromList(rgba);
    var regionPixels = 0;
    _compositeBack(
      out: out,
      pageWidth: width,
      pageHeight: height,
      regionMask: regionMask,
      crop: crop,
      model: output,
      modelSize: modelSize,
    );
    for (var i = 0; i < regionMask.length; i++) {
      if (regionMask[i] != 0) regionPixels++;
    }
    return ModelInpaintResult(
      rgba: out,
      regionPixels: regionPixels,
      crop: crop,
      elapsedMs: DateTime.now().difference(started).inMilliseconds,
    );
  }
}

// ── 几何 ───────────────────────────────────────────────────────────────────

/// 图像张量的扁平下标：模型声明 `[1,3,H,W]`，ORT 严格按声明顺序消费这块
/// 扁平内存，所以必须是 **CHW**（通道平面优先）。按 HWC 填会让通道整体
/// 错位，实测症状是「水印原样保留 + 整片噪声块」。
///
/// 单独抽成函数是为了让 `headless_p7_checks` 能直接断言这条布局约定，
/// 而不是去 grep 源码字符串。
int inpaintImageIndex(int c, int y, int x, int size) => (c * size + y) * size + x;

IntRect? _maskBounds(Uint8List mask, int w, int h) {
  var minX = w;
  var minY = h;
  var maxX = -1;
  var maxY = -1;
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      if (mask[row + x] == 0) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  if (maxX < 0) return null;
  return IntRect(minX, minY, maxX + 1, maxY + 1);
}

/// 把选区外接框外扩 [expand]，再补成正方形并夹进页面。
///
/// 🔴 补成正方形是为了保住长宽比：LaMa 的训练/导出都是 512×512，把
/// 1000×40 的水印条直接拉伸到正方形会把字形结构压扁，模型认不出"这是字"。
IntRect _squareCrop(IntRect box, int w, int h, double expand) {
  final cx = (box.left + box.right) / 2;
  final cy = (box.top + box.bottom) / 2;
  var side = math.max(box.width, box.height) * (1 + expand);
  // 太小则上下文不足（模型看不出结构），至少给 48px。
  if (side < 48) side = 48;
  var half = side / 2;
  // 夹进页面：先平移再定尺寸，避免裁到页外去。
  final maxHalfX = math.min(half, math.max(cx, w - cx));
  final maxHalfY = math.min(half, math.max(cy, h - cy));
  half = math.min(maxHalfX, maxHalfY);
  if (half < 8) half = 8;
  var left = (cx - half).round();
  var top = (cy - half).round();
  var right = (cx + half).round();
  var bottom = (cy + half).round();
  if (left < 0) {
    right -= left;
    left = 0;
  }
  if (top < 0) {
    bottom -= top;
    top = 0;
  }
  if (right > w) {
    left -= right - w;
    right = w;
  }
  if (bottom > h) {
    top -= bottom - h;
    bottom = h;
  }
  if (left < 0) left = 0;
  if (top < 0) top = 0;
  if (right <= left || bottom <= top) return IntRect(0, 0, w, h);
  return IntRect(left, top, right, bottom);
}

// ── 预处理 / 后处理 ────────────────────────────────────────────────────────

class _Prepared {
  const _Prepared(this.image, this.mask);

  final Float32List image;
  final Float32List mask;
}

_Prepared? _prepareInputs({
  required Uint8List rgba,
  required int width,
  required int height,
  required Uint8List regionMask,
  required IntRect crop,
  required int size,
}) {
  final cw = crop.width;
  final ch = crop.height;
  if (cw <= 0 || ch <= 0) return null;
  final image = Float32List(size * size * 3);
  final mask = Float32List(size * size);

  for (var y = 0; y < size; y++) {
    // 双线性取样（图像）/ 最近邻（掩膜）。
    final sy = (y + 0.5) * ch / size - 0.5;
    final y0 = sy.floor().clamp(0, ch - 1).toInt();
    final y1 = (y0 + 1).clamp(0, ch - 1).toInt();
    final wy = (sy - y0).clamp(0.0, 1.0).toDouble();
    for (var x = 0; x < size; x++) {
      final sx = (x + 0.5) * cw / size - 0.5;
      final x0 = sx.floor().clamp(0, cw - 1).toInt();
      final x1 = (x0 + 1).clamp(0, cw - 1).toInt();
      final wx = (sx - x0).clamp(0.0, 1.0).toDouble();

      final i00 = ((crop.top + y0) * width + crop.left + x0) * 4;
      final i10 = ((crop.top + y0) * width + crop.left + x1) * 4;
      final i01 = ((crop.top + y1) * width + crop.left + x0) * 4;
      final i11 = ((crop.top + y1) * width + crop.left + x1) * 4;
      for (var c = 0; c < 3; c++) {
        final top = rgba[i00 + c] * (1 - wx) + rgba[i10 + c] * wx;
        final bottom = rgba[i01 + c] * (1 - wx) + rgba[i11 + c] * wx;
        // 🔴 CHW（NCHW）布局 —— 见 [inpaintImageIndex]。
        image[inpaintImageIndex(c, y, x, size)] =
            (top * (1 - wy) + bottom * wy) / 255.0;
      }

      // 掩膜用最近邻：0/1 被插值成 0.4 这种值会让模型把"半透明边"当成
      // 需要保留的内容。
      final mx = (x * cw / size).floor().clamp(0, cw - 1).toInt();
      final my = (y * ch / size).floor().clamp(0, ch - 1).toInt();
      mask[y * size + x] =
          regionMask[(crop.top + my) * width + crop.left + mx] != 0 ? 1.0 : 0.0;
    }
  }
  return _Prepared(image, mask);
}

void _compositeBack({
  required Uint8List out,
  required int pageWidth,
  required int pageHeight,
  required Uint8List regionMask,
  required IntRect crop,
  required Float32List model,
  required int modelSize,
}) {
  final cw = crop.width;
  final ch = crop.height;
  for (var y = 0; y < ch; y++) {
    final sy = (y + 0.5) * modelSize / ch - 0.5;
    final y0 = sy.floor().clamp(0, modelSize - 1).toInt();
    final y1 = (y0 + 1).clamp(0, modelSize - 1).toInt();
    final wy = (sy - y0).clamp(0.0, 1.0).toDouble();
    final py = crop.top + y;
    if (py < 0 || py >= pageHeight) continue;
    final pageRow = py * pageWidth;
    for (var x = 0; x < cw; x++) {
      final px = crop.left + x;
      if (px < 0 || px >= pageWidth) continue;
      // 🔴 只写选区内的像素：上下文只让模型"看懂"，不允许它改写邻居。
      if (regionMask[pageRow + px] == 0) continue;
      final sx = (x + 0.5) * modelSize / cw - 0.5;
      final x0 = sx.floor().clamp(0, modelSize - 1).toInt();
      final x1 = (x0 + 1).clamp(0, modelSize - 1).toInt();
      final wx = (sx - x0).clamp(0.0, 1.0).toDouble();
      final di = (pageRow + px) * 4;
      for (var c = 0; c < 3; c++) {
        // 🔴 输出同样是 [1,3,H,W]（CHW），必须按通道平面寻址。
        final v00 = model[inpaintImageIndex(c, y0, x0, modelSize)];
        final v10 = model[inpaintImageIndex(c, y0, x1, modelSize)];
        final v01 = model[inpaintImageIndex(c, y1, x0, modelSize)];
        final v11 = model[inpaintImageIndex(c, y1, x1, modelSize)];
        final top = v00 * (1 - wx) + v10 * wx;
        final bottom = v01 * (1 - wx) + v11 * wx;
        final v = top * (1 - wy) + bottom * wy;
        out[di + c] = v.round().clamp(0, 255);
      }
      // alpha 保持原样（漫画页通常全不透明）。
    }
  }
}

// ── isolate 内推理 ─────────────────────────────────────────────────────────

Float32List? _runLama({
  required String modelPath,
  required Float32List image,
  required Float32List mask,
  required int size,
}) {
  OrtFfiSession? session;
  try {
    session = OrtFfiSession.open(modelPath);
    // 输入名按仓库导出约定；若模型改过名字，退到"第一个/第二个输入"。
    final names = session.inputNames;
    final imageName = names.contains('image') ? 'image' : names.first;
    final maskName = names.contains('mask')
        ? 'mask'
        : (names.length > 1 ? names[1] : names.first);
    final result = session.run({
      imageName: OrtInput.float32(image, [1, 3, size, size]),
      maskName: OrtInput.float32(mask, [1, 1, size, size]),
    });
    final first = result.values.first;
    // 有些导出把输出归一化到 0..1，有些是 0..255；按最大值判定，兼容两种。
    var maxV = 0.0;
    for (final v in first.data) {
      if (v > maxV) maxV = v;
    }
    final scale = maxV <= 1.5 ? 255.0 : 1.0;
    if (scale != 1.0) {
      final scaled = Float32List(first.data.length);
      for (var i = 0; i < first.data.length; i++) {
        scaled[i] = first.data[i] * scale;
      }
      return scaled;
    }
    return first.data;
  } catch (_) {
    return null;
  } finally {
    session?.close();
  }
}
