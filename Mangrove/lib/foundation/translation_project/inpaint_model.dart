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
/// 尺寸固定 512：把「选区 + 上下文」的裁剪框**等比缩放**塞进 512（短边两侧
/// 用边缘像素补齐，不拉黑边、不压扁），推理后缩回原尺寸，**只把选区内的
/// 像素贴回**。上下文只用于让模型理解结构，绝不写回 —— 这是用户明确要求的
/// 那条纪律。
library;

import 'dart:async';
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

  /// 实际送进模型的上下文裁剪框（源像素，**非正方形**）。
  final IntRect crop;
  final int elapsedMs;
}

/// LaMa 修复的统一入口。
abstract class InpaintModel {
  /// 常驻推理 worker（见 [_lamaWorkerMain] 与 [_WorkerClient]）。
  static final _WorkerClient _worker = _WorkerClient();

  /// 最近一次推理是否**复用了**已经加载好的 session。
  ///
  /// 🔴 暴露出来是为了让 `headless_p7_checks` 能真的量到"第二次比第一次快"
  /// 这件事，而不是去 grep 源码里有没有 `Isolate.run`。
  static bool lastRunReusedSession = false;

  /// worker 累计打开过几次模型 —— 用户感知的"模型加载了几次"。
  static int sessionOpenCount = 0;

  /// 模型是否已下载（设置 → 翻译模型 → 图像修复）。
  static bool get isInstalled => TranslationModels.inpaintLama.isInstalled;

  static String get modelPath =>
      TranslationModels.inpaintLama.filePath('inpaint.onnx');

  /// 模型在 UI 上显示的尺寸说明（MB）。
  static int get approxSizeMb =>
      TranslationModels.inpaintLama.approxSizeBytes ~/ 1000000;

  /// 在 [rgba] 的**副本**上修复 [regionMask] 覆盖的像素。
  ///
  /// [contextExpand] 是上下文比例，按选区的**长边**换算成每边外扩的像素数
  /// （0.75 ⇒ 长边 ×0.75）。上下文只读；写回严格限制在 [regionMask] 内。
  ///
  /// 🔴 早先按"正方形裁剪 + 总尺寸 ×1.3"取样，对细长水印是灾难：第 33 页
  /// 水印 231×65，裁成 300×300 后掩膜占了 77% 的宽度、上下只剩 117px，
  /// 模型几乎只能看见水印自身，于是把上方一大片黄色网格当不存在、整片填白
  /// （人工验收原话："AI 修复对于上下环境的参考很狭窄……上方有一大片，
  /// 居然直接无视了"）。改成按长边外扩后掩膜占比降到约 40%。
  ///
  /// 返回 null 表示模型不可用或选区为空 —— 调用方据此回退本地算法。
  static Future<ModelInpaintResult?> inpaintRegion({
    required Uint8List rgba,
    required int width,
    required int height,
    required Uint8List regionMask,
    double contextExpand = 0.75,
    int modelSize = 512,
  }) async {
    if (!isInstalled) return null;
    if (rgba.length != width * height * 4) return null;
    if (regionMask.length != width * height) return null;

    final bounds = _maskBounds(regionMask, width, height);
    if (bounds == null) return null;

    final crop = inpaintContextCrop(bounds, width, height, contextExpand);
    final started = DateTime.now();
    // 🔴 路径必须在**主 isolate 里**求值再捕获：`TranslationModels.*.filePath`
    // 依赖 `App.dataPath`，新 isolate 里 App 未必初始化过，闭包里再取会抛。
    final path = modelPath;
    final reply = await _worker.run(
      modelPath: path,
      rgba: rgba,
      width: width,
      height: height,
      regionMask: regionMask,
      crop: crop,
      modelSize: modelSize,
    );
    if (reply == null || reply.rgba == null) {
      // 模型损坏 / 运行时不匹配 / 内存不足：交给调用方回退，不把异常抛到 UI。
      return null;
    }
    lastRunReusedSession = reply.reused;
    sessionOpenCount = reply.opens;
    return ModelInpaintResult(
      rgba: reply.rgba!.materialize().asUint8List(),
      regionPixels: reply.regionPixels,
      crop: crop,
      elapsedMs: DateTime.now().difference(started).inMilliseconds,
    );
  }

  /// 预热：在用户点按钮**之前**把模型加载好。
  ///
  /// 🔴 加速的真正瓶颈不是推理，而是 `OrtFfiSession.open` —— 一个 200 MB 级
  /// 的 ONNX 图要把权重读进内存再初始化一遍计算图。把它挪到打开工作室之后
  /// 的静默时机，第一次点【AI 修复填充】就不必再等它。失败静默：没有模型、
  /// 运行时缺失都不该让工作室报错（用户可能根本不打算用 AI 填充）。
  static Future<void> warmUp() async {
    if (!isInstalled) return;
    try {
      final reply = await _worker.warm(modelPath);
      if (reply != null) sessionOpenCount = reply.opens;
    } catch (_) {
      // 预热是纯优化，失败等于没预热。
    }
  }

  /// 释放常驻 worker（退出工作室/切换工程时调用，回收 ~200 MB 常驻内存）。
  static void dispose() => _worker.shutdown();
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
/// 上下文裁剪框：以选区为中心，**每边**外扩 `expand × 长边`，再夹进页面。
///
/// 一侧贴边时把缺掉的视野补到对侧（总量守恒）：第 10 页的水印右边界几乎
/// 顶到页边，若不补，它就只有半圈上下文可用。
IntRect inpaintContextCrop(IntRect box, int w, int h, double expand) {
  final bw = box.width;
  final bh = box.height;
  if (bw <= 0 || bh <= 0) return box;
  // 按**长边**算外扩量，不按各方向自己的比例：水印几乎都是细长条，按短边
  // 算出来的 0.75×65≈49px 根本看不到上下的纹理。
  final pad = math.max(64, (math.max(bw, bh) * expand).round());

  var left = box.left - pad;
  var right = box.right + pad;
  var top = box.top - pad;
  var bottom = box.bottom + pad;

  if (left < 0) {
    right = math.min(w, right - left);
    left = 0;
  }
  if (right > w) {
    left = math.max(0, left - (right - w));
    right = w;
  }
  if (top < 0) {
    bottom = math.min(h, bottom - top);
    top = 0;
  }
  if (bottom > h) {
    top = math.max(0, top - (bottom - h));
    bottom = h;
  }
  if (right <= left || bottom <= top) return box;
  return IntRect(left, top, right, bottom);
}

/// 裁剪框 → `size×size` 模型输入的等比映射（letterbox）。
class _Fitted {
  const _Fitted(this.scale, this.offX, this.offY);

  /// 裁剪框像素 → 模型像素 的倍数。
  final double scale;

  /// 居中留白（模型像素）。
  final double offX;
  final double offY;
}

_Fitted _fitInto(int cw, int ch, int size) {
  final scale = size / math.max(cw, ch);
  return _Fitted(scale, (size - cw * scale) / 2, (size - ch * scale) / 2);
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
  // 🔴 letterbox：等比缩放 + 居中。落在留白区的模型像素**钳到裁剪框边缘**
  // = 边缘像素复制。这样模型看到的是"纹理一直延伸出去"，而不是一圈黑边
  //（黑边会被 LaMa 当成真实内容，补出一块暗色）。
  final f = _fitInto(cw, ch, size);

  for (var y = 0; y < size; y++) {
    // 双线性取样（图像）/ 最近邻（掩膜）。
    final sy = ((y + 0.5 - f.offY) / f.scale - 0.5).clamp(
      0.0,
      (ch - 1).toDouble(),
    );
    final y0 = sy.floor();
    final y1 = math.min(y0 + 1, ch - 1);
    final wy = sy - y0;
    for (var x = 0; x < size; x++) {
      final sx = ((x + 0.5 - f.offX) / f.scale - 0.5).clamp(
        0.0,
        (cw - 1).toDouble(),
      );
      final x0 = sx.floor();
      final x1 = math.min(x0 + 1, cw - 1);
      final wx = sx - x0;

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
      final mx = sx.round().clamp(0, cw - 1);
      final my = sy.round().clamp(0, ch - 1);
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
  // 与 [_prepareInputs] 完全同一份 letterbox 映射，否则补回来的位置会整体偏移。
  final f = _fitInto(cw, ch, modelSize);
  for (var y = 0; y < ch; y++) {
    final my = ((y + 0.5) * f.scale + f.offY - 0.5).clamp(
      0.0,
      (modelSize - 1).toDouble(),
    );
    final y0 = my.floor();
    final y1 = math.min(y0 + 1, modelSize - 1);
    final wy = my - y0;
    final py = crop.top + y;
    if (py < 0 || py >= pageHeight) continue;
    final pageRow = py * pageWidth;
    for (var x = 0; x < cw; x++) {
      final px = crop.left + x;
      if (px < 0 || px >= pageWidth) continue;
      // 🔴 只写选区内的像素：上下文只让模型"看懂"，不允许它改写邻居。
      if (regionMask[pageRow + px] == 0) continue;
      final mx = ((x + 0.5) * f.scale + f.offX - 0.5).clamp(
        0.0,
        (modelSize - 1).toDouble(),
      );
      final x0 = mx.floor();
      final x1 = math.min(x0 + 1, modelSize - 1);
      final wx = mx - x0;
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

/// 一次推理请求。整页 RGBA 与掩膜都用 [TransferableTypedData] 传 —— 它们是
/// MB 级缓冲，普通消息会把字节复制两次（发送 + 接收各一次）。
class _RunRequest {
  const _RunRequest({
    required this.id,
    required this.modelPath,
    required this.rgba,
    required this.width,
    required this.height,
    required this.mask,
    required this.crop,
    required this.modelSize,
  });

  final int id;
  final String modelPath;
  final TransferableTypedData rgba;
  final int width;
  final int height;
  final TransferableTypedData mask;
  final IntRect crop;
  final int modelSize;
}

/// 预热请求：只加载模型，不推理。
class _WarmRequest {
  const _WarmRequest(this.id, this.modelPath);

  final int id;
  final String modelPath;
}

/// worker 的回复。`rgba` 为 null 时 [error] 必定非空。
class _RunReply {
  const _RunReply({
    required this.id,
    required this.reused,
    required this.opens,
    this.rgba,
    this.regionPixels = 0,
    this.error,
  });

  final int id;

  /// 本次是否复用了已加载的 session（false = 这次才打开模型）。
  final bool reused;

  /// 累计打开模型的次数。
  final int opens;

  final TransferableTypedData? rgba;
  final int regionPixels;
  final String? error;
}

/// 常驻推理 worker 的主循环。
///
/// 🔴 为什么是长驻 isolate 而不是每次 `Isolate.run`：LaMa 是一个 200 MB 级的
/// ONNX 图，`OrtFfiSession.open` 要把权重读进内存并初始化计算图，实测占单轮
/// 耗时的一半以上。人工验收要求"看 ai 修图以及增强画质的响应速度能不能稍微
/// 加快"，而复用同一个 session 是唯一**不牺牲画质**的加速方式（降分辨率会掉
/// 细节，用户已明确"AI 水平不够"是可接受下限，不能再往下压）。
///
/// 预处理 / 后处理也搬进来了：整页扫描、双线性重采样、写回都是 CPU 活，放在
/// 这里跑，UI isolate 全程零占用。
void _lamaWorkerMain(SendPort toMain) {
  final inbox = ReceivePort();
  toMain.send(inbox.sendPort);

  OrtFfiSession? session;
  String? sessionPath;
  var opens = 0;

  OrtFfiSession open(String path) {
    final existing = session;
    if (existing != null && sessionPath == path) return existing;
    existing?.close();
    final opened = OrtFfiSession.open(path);
    session = opened;
    sessionPath = path;
    opens++;
    return opened;
  }

  inbox.listen((message) {
    if (message is _WarmRequest) {
      try {
        open(message.modelPath);
        toMain.send(
          _RunReply(id: message.id, reused: false, opens: opens),
        );
      } catch (e) {
        toMain.send(
          _RunReply(
            id: message.id,
            reused: false,
            opens: opens,
            error: '$e',
          ),
        );
      }
      return;
    }
    if (message is! _RunRequest) return;
    final reused = session != null && sessionPath == message.modelPath;
    try {
      final active = open(message.modelPath);
      final rgba = message.rgba.materialize().asUint8List();
      final mask = message.mask.materialize().asUint8List();
      final prepared = _prepareInputs(
        rgba: rgba,
        width: message.width,
        height: message.height,
        regionMask: mask,
        crop: message.crop,
        size: message.modelSize,
      );
      if (prepared == null) {
        toMain.send(
          _RunReply(
            id: message.id,
            reused: reused,
            opens: opens,
            error: 'prepare-failed',
          ),
        );
        return;
      }
      final output = _runWithSession(
        active,
        image: prepared.image,
        mask: prepared.mask,
        size: message.modelSize,
      );
      if (output == null) {
        toMain.send(
          _RunReply(
            id: message.id,
            reused: reused,
            opens: opens,
            error: 'inference-failed',
          ),
        );
        return;
      }
      final out = Uint8List.fromList(rgba);
      var regionPixels = 0;
      for (var i = 0; i < mask.length; i++) {
        if (mask[i] != 0) regionPixels++;
      }
      _compositeBack(
        out: out,
        pageWidth: message.width,
        pageHeight: message.height,
        regionMask: mask,
        crop: message.crop,
        model: output,
        modelSize: message.modelSize,
      );
      toMain.send(
        _RunReply(
          id: message.id,
          reused: reused,
          opens: opens,
          rgba: TransferableTypedData.fromList([out]),
          regionPixels: regionPixels,
        ),
      );
    } catch (e) {
      toMain.send(
        _RunReply(
          id: message.id,
          reused: reused,
          opens: opens,
          error: '$e',
        ),
      );
    }
  });
}

/// 主 isolate 侧的 worker 句柄：负责启动、握手、排队、超时与重建。
///
/// 🔴 请求**串行化**：同一时刻只有一个推理在跑。并行跑两个 LaMa 推理只会让
/// 两者都变慢（线程池被抢），而 UI 侧本来就靠 `_blockOpBusy` 或按钮禁用来
/// 防连点；这里再用一条 Future 链兜底，避免 headless/批量路径意外并发。
class _WorkerClient {
  SendPort? _send;
  ReceivePort? _receive;
  Isolate? _isolate;
  Future<void>? _starting;
  int _nextId = 1;
  final Map<int, Completer<_RunReply>> _pending = {};
  Future<void> _chain = Future<void>.value();

  /// 单次推理的兜底超时。模型正常时 512×512 一轮是几百毫秒级；给到 3 分钟
  /// 是因为第一次要加载 200 MB 权重，低配机 + 冷缓存可能到十几秒。
  static const Duration _runTimeout = Duration(minutes: 3);
  static const Duration _startTimeout = Duration(seconds: 30);

  Future<SendPort> _ensureStarted() async {
    final existing = _send;
    if (existing != null) return existing;
    final starting = _starting;
    if (starting != null) {
      await starting;
      final port = _send;
      if (port != null) return port;
      throw StateError('inpaint worker failed to start');
    }
    final future = _start();
    _starting = future;
    try {
      await future;
    } finally {
      _starting = null;
    }
    final port = _send;
    if (port == null) throw StateError('inpaint worker failed to start');
    return port;
  }

  Future<void> _start() async {
    final receive = ReceivePort();
    _receive = receive;
    final ready = Completer<SendPort>();
    receive.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is _RunReply) {
        _pending.remove(message.id)?.complete(message);
        return;
      }
      // onError / onExit 都会落到这里（List<dynamic> 或 null）：
      // worker 死了，把所有等待中的请求放掉，交给调用方回退本地算法。
      _failPending('inpaint worker exited');
    });
    _isolate = await Isolate.spawn(
      _lamaWorkerMain,
      receive.sendPort,
      debugName: 'mangrove-inpaint',
      onError: receive.sendPort,
      onExit: receive.sendPort,
    );
    _send = await ready.future.timeout(
      _startTimeout,
      onTimeout: () {
        _resetWorker();
        throw StateError('inpaint worker handshake timed out');
      },
    );
  }

  void _failPending(String reason) {
    final pending = Map<int, Completer<_RunReply>>.from(_pending);
    _pending.clear();
    for (final entry in pending.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(
          _RunReply(
            id: entry.key,
            reused: false,
            opens: 0,
            error: reason,
          ),
        );
      }
    }
  }

  void _resetWorker() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receive?.close();
    _receive = null;
    _send = null;
    _failPending('inpaint worker reset');
  }

  /// 串行执行 [action]，保证同一时刻只有一个推理在 worker 里跑。
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _chain.then((_) => action());
    // 链条本身不能因为某次失败而断掉，否则后续请求全部拿不到执行机会。
    _chain = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<_RunReply?> _dispatch(
    Object message,
    int id, {
    required String modelPath,
  }) async {
    try {
      final port = await _ensureStarted();
      final completer = Completer<_RunReply>();
      _pending[id] = completer;
      port.send(message);
      return await completer.future.timeout(
        _runTimeout,
        onTimeout: () {
          _pending.remove(id);
          // 超时的 worker 状态不可信（可能卡在 native 里），直接重建。
          _resetWorker();
          // 重建失败不影响「这一次」的结论：调用方回退本地算法。
          unawaited(
            Future<void>.microtask(() async {
              try {
                await _ensureStarted();
              } catch (_) {}
            }),
          );
          return _RunReply(
            id: id,
            reused: false,
            opens: 0,
            error: 'timeout',
          );
        },
      );
    } catch (e) {
      return _RunReply(id: id, reused: false, opens: 0, error: '$e');
    }
  }

  /// 跑一轮修复。任何失败都返回带 [error] 的 reply —— 调用方只看 `rgba`。
  Future<_RunReply?> run({
    required String modelPath,
    required Uint8List rgba,
    required int width,
    required int height,
    required Uint8List regionMask,
    required IntRect crop,
    required int modelSize,
  }) {
    return _serial(() {
      final id = _nextId++;
      return _dispatch(
        _RunRequest(
          id: id,
          modelPath: modelPath,
          rgba: TransferableTypedData.fromList([rgba]),
          width: width,
          height: height,
          mask: TransferableTypedData.fromList([regionMask]),
          crop: crop,
          modelSize: modelSize,
        ),
        id,
        modelPath: modelPath,
      );
    });
  }

  /// 只加载模型（预热）。
  Future<_RunReply?> warm(String modelPath) {
    return _serial(() {
      final id = _nextId++;
      return _dispatch(_WarmRequest(id, modelPath), id, modelPath: modelPath);
    });
  }

  /// 彻底释放（退出工作室时）。
  void shutdown() {
    _resetWorker();
    _chain = Future<void>.value();
  }
}

/// 在给定 session 上跑一次推理（worker 内、同步、阻塞）。
Float32List? _runWithSession(
  OrtFfiSession session, {
  required Float32List image,
  required Float32List mask,
  required int size,
}) {
  try {
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
  }
}
