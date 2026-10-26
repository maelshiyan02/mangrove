/// 上下文感知的「水印整体掩膜 / 抹字补漏 / 结构与纹理修复」核心。
///
/// 纯 Dart，**不依赖 `dart:ui`**，因此可以 headless 断言（与
/// `mask_producer.dart` / `polygon_mask.dart` / `block_artifacts.dart` 同一层）。
///
/// ## 为什么必须再加这一层（P48 三轮的根因）
///
/// [buildMaskPage] 产出的是**字形级**掩膜：它用局部 Otsu 把"文字笔画"从背景
/// 里分出来。这对气泡里的对白是对的，但**对水印是错的** —— 翻译组水印是一个
/// **整体图形**（圆形 logo + 紫色圆角底盘 + 白色字），笔画只是它的一部分。
/// 按字形掩膜擦，结果就是"白字没了、紫色底盘原样留在黑底上"（第 3 页实测：
/// 擦完仍是一条紫杠；第 7 页实测：裙子蓝色填上了，但留下两个紫点）。
///
/// 所以水印必须走**物体级**掩膜：
///
/// 1. 把块框外扩 ~30% 作为**上下文窗口**。用户框得紧是为了不伤边缘，但程序
///    需要看到框外的底图，才知道"这块底下本来应该是什么"；
/// 2. 用窗口四周已知像素做**方向性插值**，预测"没有水印时这里应该长什么样"
///    （[_predictWindow]）；
/// 3. 实际像素与预测的**残差**就是"不属于底图的东西" —— 底盘与字都在其中，
///    作为种子（[buildWatermarkMask]）；
/// 4. 种子颜色聚类后**沿连通性生长**，把残差漏掉的渐变、半透明、抗锯齿边
///    一并收进来；
/// 5. 形态学闭运算 + 小连通域剔除 + 边缘膨胀，得到完整物体掩膜。
///
/// ## 填色分两级
///
/// * [RepairQuality.structural] —— 方向性插值 + 松弛。纯色/渐变底（黑底水印、
///   白气泡）几乎完美，O(n)；
/// * [RepairQuality.texture] —— 在结构填充之上叠加**块级纹理合成**：从上下文
///   环带里找最相似的 patch 覆盖回去，用于角色衣物、网点渐变这类有纹理的底
///   （第 7 页蓝裙子上的水印）。
///
/// 两者都不联网、不下载模型，是经典图像修复（Telea / Efros-Leung 一系）的
/// 工程化实现 —— **不是神经网络**。面板与日志按这个事实写，不吹成"AI 生成"。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mangrove/foundation/image_translation/translation_types.dart';

/// 填色质量档。
enum RepairQuality {
  /// 方向性插值 + 松弛：适合纯色/渐变底。
  structural,

  /// 结构填充 + 块级纹理合成：适合衣物、网点、渐变网点等有纹理的底。
  texture,
}

/// 单块修图时"这一片到底用哪种方式填"的路线。
enum RepairFillRoute {
  /// 擦除 + 底色填充：整片选区刷成一个单色。
  solid,

  /// AI 修复填充（ONNX LaMa）：按上下文重建。
  model,

  /// 没装模型时的本地纹理合成（如实降级，不假装是神经网络）。
  localTexture,

  /// 本地结构插值（擦除/渐变底）。
  localStructural,
}

/// 决定填色路线 —— **纯函数**，因此 headless 能直接断言它。
///
/// 🔴 为什么必须单独抽出来：`allowFlat` 这条闸门曾经不存在，于是"AI 修复
/// 填充"和"擦除"走同一条判定，第 33 页（白底 + 淡黄网格）的环带有 86% 是
/// 白，被判成平色后整片刷白 —— 用户要的"按上方那一大片网格延伸纹理"连一次
/// 机会都没有。人工验收的原话是："明明上面有一大片（网格），居然直接无视
/// 了，没有对纹理进行延伸。"
///
/// 结论（用户把三种方法分得很清楚）：**平色直填只属于"擦除"入口**；
/// "AI 修复填充"一律走模型/纹理，不受平色判定拦截。
RepairFillRoute chooseRepairFillRoute({
  required RepairQuality quality,
  required bool allowFlat,
  required bool flatFound,
  required bool modelInstalled,
}) {
  if (allowFlat && flatFound) return RepairFillRoute.solid;
  if (quality == RepairQuality.texture) {
    return modelInstalled
        ? RepairFillRoute.model
        : RepairFillRoute.localTexture;
  }
  return RepairFillRoute.localStructural;
}

/// 一块区域的检测结果（整页掩膜 + 诊断量）。
class RegionMaskResult {
  RegionMaskResult({
    required this.mask,
    required this.seedPixels,
    required this.totalPixels,
    required this.fallback,
  });

  /// 整页灰度掩膜，`255 = 需要处理`，长度 `width * height`。
  final Uint8List mask;

  /// 残差种子数（"看起来不属于底图"的像素）。
  final int seedPixels;

  /// 最终掩膜前景像素数（含生长与膨胀）。
  final int totalPixels;

  /// 残差检测没能给出可信种子，退回"整块区域"掩膜。
  ///
  /// 🔴 对水印这是**正确的退路**：水印必须消失，"没检出来"不代表可以留着。
  /// 对普通文字块不走这条退路（见 [buildResidualTextMask]）。
  final bool fallback;

  bool get isEmpty => totalPixels == 0;
}

/// 修复统计（日志与面板文案用）。
class RepairStats {
  const RepairStats({
    required this.filledPixels,
    required this.textured,
    required this.windowArea,
    this.solid = false,
    this.solidRgb = 0,
  });

  final int filledPixels;
  final bool textured;
  final int windowArea;

  /// 纯色底直填（见 [detectFlatBackground]）：整片选区被填成一个单色，
  /// 既没有插值也没有纹理合成。
  final bool solid;

  /// [solid] 为真时填入的颜色，`0xRRGGBB`。
  final int solidRgb;
}

/// 纯色底判定结果。
///
/// 🔴 为什么要有这一步（P48 五轮的人工验收）：黑底上的水印，用"从四邻插值"
/// 去补，会把上方的黑与下方的紫色头发混成一条**渐变**——用户原话"莫名其妙
/// 出现了自动补充的效果，但根本不需要，这张类型的正确做法是全部涂黑"。白气泡
/// 同理（补成白，不要拉上方的白边当参考后还留半笔字）。所以先判断"这块周围
/// 到底是不是一个平色"，是就整片刷成那个颜色。
class FlatBackground {
  const FlatBackground({
    required this.r,
    required this.g,
    required this.b,
    required this.share,
    required this.deviation,
    this.agreeingEdges = 0,
  });

  final int r;
  final int g;
  final int b;

  /// 主色在取样环带中的占比（0..1）。
  final double share;

  /// 环带相对主色的平均绝对偏差（单通道，0..255）。
  final double deviation;

  /// 四条边里有几条是"压倒性"主色（各自占比 ≥0.65），诊断用。
  final int agreeingEdges;

  int get rgb => (r << 16) | (g << 8) | b;

  String get hex =>
      '#${r.toRadixString(16).padLeft(2, '0')}'
      '${g.toRadixString(16).padLeft(2, '0')}'
      '${b.toRadixString(16).padLeft(2, '0')}';
}

/// 检测选区之外的一圈是否基本是**同一个平色**。
///
/// 取样环带 = 选区外接框外扩 [ringWidth]（0 = 按选区尺寸自适应 8..48px）的
/// 那一圈，**只取环带、不取选区内部**：选区里就是待修的东西，把它的颜色当
/// 背景会填出原色（上一轮 `k=2` 聚类留下的紫团就是这个错误）。
///
/// 判定两个条件同时成立才算平色：
/// 1. 量化到 16 级/通道后，主色桶占比 ≥ [minShare]；
/// 2. 环带相对主色的平均绝对偏差 ≤ [maxDeviation]（挡掉平滑渐变 —— 渐变会
///    落在同一个桶里但偏差明显偏大）。
FlatBackground? detectFlatBackground(
  RgbaImage image,
  IntRect rect, {
  double minShare = 0.62,
  double maxDeviation = 10.0,
  int ringWidth = 0,
}) {
  final w = image.width;
  final h = image.height;
  // 🔴 取样框只认**块矩形**，不认多边形外接框。画笔轮廓常常比块框松
  // （第 3 页的 lasso 外接框一直含到下方的紫色头发），拿它当取样框会把
  // 头发算进"背景"，于是黑底横条反而不判平色、又被插值成渐变。
  // 块矩形是用户明确划定的那个框，轮廓只用来限定**写入**范围。
  final box = _clampRect(rect, w, h);
  final bw = box.width;
  final bh = box.height;
  if (bw < 2 || bh < 2) return null;
  final ring = ringWidth > 0
      ? ringWidth
      : math.max(8, math.min(48, (math.min(bw, bh) * 0.45).round()));
  final outer = _clampRect(
    IntRect(box.left - ring, box.top - ring, box.right + ring, box.bottom + ring),
    w,
    h,
  );

  final px = image.pixels;
  final counts = <int, int>{};
  // 四条边的分布分开统计：水印常贴在一条色带上（黑底横条 / 白气泡），
  // 全局占比可能只有一半，但**三条边同色**已经足够说明"这块在一个平色里"。
  final edgeCounts = List.generate(4, (_) => <int, int>{});
  var total = 0;
  for (var y = outer.top; y < outer.bottom; y++) {
    for (var x = outer.left; x < outer.right; x++) {
      if (x >= box.left && x < box.right && y >= box.top && y < box.bottom) {
        continue;
      }
      final i = (y * w + x) * 4;
      final key = ((px[i] >> 4) << 8) | ((px[i + 1] >> 4) << 4) | (px[i + 2] >> 4);
      counts[key] = (counts[key] ?? 0) + 1;
      total++;
      // 0 = 上, 1 = 下, 2 = 左, 3 = 右。归类到离得最近的一条边。
      final dTop = y - outer.top;
      final dBottom = outer.bottom - 1 - y;
      final dLeft = x - outer.left;
      final dRight = outer.right - 1 - x;
      final m = math.min(math.min(dTop, dBottom), math.min(dLeft, dRight));
      final edge = (m == dTop)
          ? 0
          : (m == dBottom ? 1 : (m == dLeft ? 2 : 3));
      edgeCounts[edge][key] = (edgeCounts[edge][key] ?? 0) + 1;
    }
  }
  if (total < 48) return null;
  var bestKey = 0;
  var best = 0;
  counts.forEach((key, value) {
    if (value > best) {
      best = value;
      bestKey = key;
    }
  });
  final share = best / total;
  var agreeing = 0;
  for (final edge in edgeCounts) {
    var edgeKey = -1;
    var edgeBest = 0;
    var edgeTotal = 0;
    edge.forEach((key, value) {
      edgeTotal += value;
      if (value > edgeBest) {
        edgeBest = value;
        edgeKey = key;
      }
    });
    // 🔴 一条边要"表态"必须自己也是压倒性的（≥65%），不能只比别的颜色多
    // 一点点。第 10 页那块水印右侧贴着页边留白、左侧是渐变闪粉：三条边的
    // "多数色"都是白，但其中两条只有 30%~50% —— 按"计数 ≥3 就平色"会把
    // 整块刷成白色（用户截图里那块突兀的白方块就是这么来的）。
    if (edgeKey == bestKey && edgeTotal > 0 && edgeBest / edgeTotal >= 0.65) {
      agreeing++;
    }
  }
  // 要么整圈以主色为主，要么至少三条边都是主色 —— 后者才是"框贴在一条色带
  // 上"的真实情形（第 3 页黑底横条：上/左/右黑、下方是紫色头发）。
  if (share < minShare && agreeing < 3) return null;

  // 主色桶的均色 + 偏差。
  var sr = 0;
  var sg = 0;
  var sb = 0;
  var n = 0;
  for (var y = outer.top; y < outer.bottom; y++) {
    for (var x = outer.left; x < outer.right; x++) {
      if (x >= box.left && x < box.right && y >= box.top && y < box.bottom) {
        continue;
      }
      final i = (y * w + x) * 4;
      final key = ((px[i] >> 4) << 8) | ((px[i + 1] >> 4) << 4) | (px[i + 2] >> 4);
      if (key != bestKey) continue;
      sr += px[i];
      sg += px[i + 1];
      sb += px[i + 2];
      n++;
    }
  }
  if (n == 0) return null;
  final mr = sr / n;
  final mg = sg / n;
  final mb = sb / n;
  var dev = 0.0;
  for (var y = outer.top; y < outer.bottom; y++) {
    for (var x = outer.left; x < outer.right; x++) {
      if (x >= box.left && x < box.right && y >= box.top && y < box.bottom) {
        continue;
      }
      final i = (y * w + x) * 4;
      final key = ((px[i] >> 4) << 8) | ((px[i + 1] >> 4) << 4) | (px[i + 2] >> 4);
      if (key != bestKey) continue;
      dev += ((px[i] - mr).abs() + (px[i + 1] - mg).abs() + (px[i + 2] - mb).abs()) /
          3.0;
    }
  }
  dev /= n;
  if (dev > maxDeviation) return null;
  return FlatBackground(
    r: mr.round(),
    g: mg.round(),
    b: mb.round(),
    share: share,
    deviation: dev,
    agreeingEdges: agreeing,
  );
}

/// 把 [regionMask] 覆盖的像素整片刷成 [rgb]（纯色底专用）。
///
/// 与 [repairRegionInPlace] 的区别：**不读邻域、不做插值**。黑底水印就该
/// 一整条黑，白气泡就该一整块白 —— 任何"聪明"的混合都只会引入用户没要求的
/// 东西。
RepairStats fillRegionWithColor(
  RgbaImage image,
  Uint8List regionMask,
  int rgb,
) {
  final w = image.width;
  final h = image.height;
  if (regionMask.length != w * h) {
    throw ArgumentError(
      'mask size mismatch: ${regionMask.length} vs ${w * h}',
    );
  }
  final r = (rgb >> 16) & 0xFF;
  final g = (rgb >> 8) & 0xFF;
  final b = rgb & 0xFF;
  final px = image.pixels;
  var filled = 0;
  for (var i = 0; i < regionMask.length; i++) {
    if (regionMask[i] == 0) continue;
    final p = i * 4;
    px[p] = r;
    px[p + 1] = g;
    px[p + 2] = b;
    filled++;
  }
  return RepairStats(
    filledPixels: filled,
    textured: false,
    windowArea: filled,
    solid: true,
    solidRgb: rgb,
  );
}

// ── 窗口 / 几何 ────────────────────────────────────────────────────────────

class _Win {
  const _Win(this.left, this.top, this.w, this.h);

  final int left;
  final int top;
  final int w;
  final int h;
}

IntRect _clampRect(IntRect r, int w, int h) {
  var x0 = r.left;
  var y0 = r.top;
  var x1 = r.right;
  var y1 = r.bottom;
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > w) x1 = w;
  if (y1 > h) y1 = h;
  if (x1 <= x0) x1 = x0 + 1;
  if (y1 <= y0) y1 = y0 + 1;
  return IntRect(x0, y0, x1, y1);
}

/// 四边各外扩 `fraction / 2`，使总宽高 = 原 * (1 + fraction)。
///
/// 与 `buildRestorationMask` 的 `dilation` 口径一致（1.3 ⟺ fraction 0.3），
/// 免得"外扩 30%"在两处各算一套。
IntRect _inflate(IntRect r, double fraction) {
  final ex = (r.width * fraction / 2).round();
  final ey = (r.height * fraction / 2).round();
  return IntRect(r.left - ex, r.top - ey, r.right + ex, r.bottom + ey);
}

_Win _windowOf(IntRect rect, int w, int h, {int pad = 2}) {
  final r = _clampRect(
    IntRect(rect.left - pad, rect.top - pad, rect.right + pad, rect.bottom + pad),
    w,
    h,
  );
  return _Win(r.left, r.top, r.width, r.height);
}

/// 水印用的**上下文窗口**：比例外扩 + **最小绝对宽度**双保险。
///
/// ## 为什么光有 30% 不够（P48 四轮实测的坑）
///
/// 用户框水印时会贴着水印本体框。若水印底盘只比框大一点点（典型：585×40 的
/// 网站条，框 550×34），30% 的环带**落在水印自己身上** —— 于是"预测底图"
/// 预测出来的是紫色的底盘，残差≈0，物体检测直接失败，退化成整块矩形，
/// 紫边照样留一半。
///
/// 所以环带宽度取 `max(比例外扩, 24px)`：24px 足以越过常见的底盘厚度，
/// 让预测真正看到画面上水印**外面**的东西。这也正是用户提的"给水印擦除增加
/// 30% 左右的识别区域来辅助理解底图"的落地方式 —— 只是还要加个下限，
/// 否则小水印的环带永远太窄。
IntRect _contextWindow(IntRect box, double fraction, int w, int h) {
  const minPad = 24;
  final padX = math.max((box.width * fraction / 2).round(), minPad);
  final padY = math.max((box.height * fraction / 2).round(), minPad);
  return _clampRect(
    IntRect(box.left - padX, box.top - padY, box.right + padX, box.bottom + padY),
    w,
    h,
  );
}

// ── 方向性插值：预测"没有遮挡物时的底图" ──────────────────────────────────

/// 用窗口内**已知**像素做四方向射线插值，返回窗口 RGBA（洞内已填）。
///
/// 做法：对每个洞像素，沿左右上下四条轴找最近的已知像素，按 `1/(d²+1)` 加权
/// 融合（距离近的一侧占绝对优势，洞中央两侧各半 → 等价于线性过渡）。随后
/// 做 [relax] 轮 Jacobi 松弛消掉十字接缝。
///
/// ## 为什么不用 `_fillNearest` 的 chamfer 最近邻
///
/// 最近邻会把洞填成"离它最近的那条边界颜色的一块平面"，在大洞（水印长条、
/// 跨页气泡）里表现为一条条放射性条纹。方向性插值给出的是两侧边界之间的
/// **线性过渡**，黑底/白底/渐变底都直接对；有纹理的底再交给
/// [RepairQuality.texture] 补。
///
/// [hole] 在窗口坐标下，非零 = 要填。返回的缓冲长度是 `win.w * win.h * 4`。
Uint8List _predictWindow(
  RgbaImage image,
  _Win win,
  Uint8List hole, {
  int relax = 2,
}) {
  final n = win.w * win.h;
  final out = Uint8List(n * 4);
  final px = image.pixels;
  final imgW = image.width;
  // 先把窗口里的真实像素搬进来（洞内稍后被覆盖）。
  for (var y = 0; y < win.h; y++) {
    final srcRow = (win.top + y) * imgW + win.left;
    final dstRow = y * win.w;
    for (var x = 0; x < win.w; x++) {
      final s = (srcRow + x) * 4;
      final d = (dstRow + x) * 4;
      out[d] = px[s];
      out[d + 1] = px[s + 1];
      out[d + 2] = px[s + 2];
      out[d + 3] = px[s + 3];
    }
  }

  // 四方向累加：r/g/b + 权重。
  final acc = Float32List(n * 4);

  void contribute(int dstIdx, int srcIdx, int dist) {
    final wgt = 1.0 / (dist * dist + 1.0);
    final s = srcIdx * 4;
    final d = dstIdx * 4;
    acc[d] += out[s] * wgt;
    acc[d + 1] += out[s + 1] * wgt;
    acc[d + 2] += out[s + 2] * wgt;
    acc[d + 3] += wgt;
  }

  final ww = win.w;
  final hh = win.h;
  // 左 / 右
  for (var y = 0; y < hh; y++) {
    final row = y * ww;
    var last = -1;
    for (var x = 0; x < ww; x++) {
      final li = row + x;
      if (hole[li] == 0) {
        last = x;
        continue;
      }
      if (last >= 0) contribute(li, row + last, x - last);
    }
    last = -1;
    for (var x = ww - 1; x >= 0; x--) {
      final li = row + x;
      if (hole[li] == 0) {
        last = x;
        continue;
      }
      if (last >= 0) contribute(li, row + last, last - x);
    }
  }
  // 上 / 下
  for (var x = 0; x < ww; x++) {
    var last = -1;
    for (var y = 0; y < hh; y++) {
      final li = y * ww + x;
      if (hole[li] == 0) {
        last = y;
        continue;
      }
      if (last >= 0) contribute(li, last * ww + x, y - last);
    }
    last = -1;
    for (var y = hh - 1; y >= 0; y--) {
      final li = y * ww + x;
      if (hole[li] == 0) {
        last = y;
        continue;
      }
      if (last >= 0) contribute(li, last * ww + x, last - y);
    }
  }

  for (var i = 0; i < n; i++) {
    if (hole[i] == 0) continue;
    final wgt = acc[i * 4 + 3];
    if (wgt <= 0) continue;
    final d = i * 4;
    out[d] = (acc[d] / wgt).round().clamp(0, 255);
    out[d + 1] = (acc[d + 1] / wgt).round().clamp(0, 255);
    out[d + 2] = (acc[d + 2] / wgt).round().clamp(0, 255);
  }

  // Jacobi 松弛：只在洞内做，边界像素固定。
  for (var p = 0; p < relax; p++) {
    final snap = Uint8List.fromList(out);
    for (var y = 0; y < hh; y++) {
      for (var x = 0; x < ww; x++) {
        final i = y * ww + x;
        if (hole[i] == 0) continue;
        var r = 0;
        var g = 0;
        var b = 0;
        var a = 0;
        var c = 0;
        void acc4(int nx, int ny) {
          if (nx < 0 || ny < 0 || nx >= ww || ny >= hh) return;
          final s = (ny * ww + nx) * 4;
          r += snap[s];
          g += snap[s + 1];
          b += snap[s + 2];
          a += snap[s + 3];
          c++;
        }

        acc4(x - 1, y);
        acc4(x + 1, y);
        acc4(x, y - 1);
        acc4(x, y + 1);
        if (c == 0) continue;
        final d = i * 4;
        out[d] = (r / c).round();
        out[d + 1] = (g / c).round();
        out[d + 2] = (b / c).round();
        out[d + 3] = (a / c).round();
      }
    }
  }
  return out;
}

// ── 形态学 ─────────────────────────────────────────────────────────────────

/// 掩膜膨胀（方形结构元，半径 [radius] 像素）。
///
/// 🔴 用途只有一个：「多轮修复」的第 2 轮要把**上一轮补过的洞 + 它周围一圈
/// 过渡**一起重做。早先第 2 轮直接把**整片选区**当洞，结果选区画得比水印大
/// 时，周围本不需要动的地方（花瓣、裙子）也被整片重画 —— 用户的原话就是
/// "外围一圈也被识别涂抹了"。只膨胀几像素既盖掉第 1 轮的边缘痕迹，又不碰
/// 选区里其他内容。
Uint8List dilatePageMask(Uint8List mask, int w, int h, int radius) =>
    _morph(mask, w, h, radius, dilate: true);

/// 可分离形态学（边缘按复制处理，避免贴着页面边的水印被削掉）。
Uint8List _morph(Uint8List src, int w, int h, int r, {required bool dilate}) {
  if (r <= 0) return Uint8List.fromList(src);
  final tmp = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      var on = !dilate;
      for (var dx = -r; dx <= r; dx++) {
        var nx = x + dx;
        if (nx < 0) nx = 0;
        if (nx >= w) nx = w - 1;
        final v = src[row + nx] != 0;
        if (dilate && v) {
          on = true;
          break;
        }
        if (!dilate && !v) {
          on = false;
          break;
        }
      }
      tmp[row + x] = on ? 1 : 0;
    }
  }
  final out = Uint8List(w * h);
  for (var x = 0; x < w; x++) {
    for (var y = 0; y < h; y++) {
      var on = !dilate;
      for (var dy = -r; dy <= r; dy++) {
        var ny = y + dy;
        if (ny < 0) ny = 0;
        if (ny >= h) ny = h - 1;
        final v = tmp[ny * w + x] != 0;
        if (dilate && v) {
          on = true;
          break;
        }
        if (!dilate && !v) {
          on = false;
          break;
        }
      }
      out[y * w + x] = on ? 1 : 0;
    }
  }
  return out;
}

/// 剔除小于 [minPixels] 的连通域（4 连通），返回保留的前景像素数。
int _filterSmall(Uint8List mask, int w, int h, int minPixels) {
  final n = w * h;
  final seen = Uint8List(n);
  final stack = <int>[];
  var kept = 0;
  for (var start = 0; start < n; start++) {
    if (mask[start] == 0 || seen[start] != 0) continue;
    stack
      ..clear()
      ..add(start);
    seen[start] = 1;
    final members = <int>[];
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      members.add(i);
      final x = i % w;
      if (x > 0 && mask[i - 1] != 0 && seen[i - 1] == 0) {
        seen[i - 1] = 1;
        stack.add(i - 1);
      }
      if (x < w - 1 && mask[i + 1] != 0 && seen[i + 1] == 0) {
        seen[i + 1] = 1;
        stack.add(i + 1);
      }
      if (i - w >= 0 && mask[i - w] != 0 && seen[i - w] == 0) {
        seen[i - w] = 1;
        stack.add(i - w);
      }
      if (i + w < n && mask[i + w] != 0 && seen[i + w] == 0) {
        seen[i + w] = 1;
        stack.add(i + w);
      }
    }
    if (members.length < minPixels) {
      for (final i in members) {
        mask[i] = 0;
      }
    } else {
      kept += members.length;
    }
  }
  return kept;
}

// ── 残差检测 ───────────────────────────────────────────────────────────────

int _dist2(int a, int b) {
  final ar = (a >> 16) & 0xFF;
  final ag = (a >> 8) & 0xFF;
  final ab = a & 0xFF;
  final br = (b >> 16) & 0xFF;
  final bg = (b >> 8) & 0xFF;
  final bb = b & 0xFF;
  final dr = ar - br;
  final dg = ag - bg;
  final db = ab - bb;
  // 加权欧氏距离（人眼对绿更敏感），再开方取整数近似。
  final v = dr * dr * 3 + dg * dg * 4 + db * db * 3;
  return math.sqrt(v / 10).round();
}

int _pack(Uint8List px, int i) =>
    (px[i] << 16) | (px[i + 1] << 8) | px[i + 2];

/// k 簇 k-means（种子颜色通常是"底盘色 + 圆标色 + 字色"三种）。
///
/// ## 为什么是 3 而不是 2（headless 断言当场抓到的）
///
/// 翻译组水印的典型构成是三色：紫色底盘 + 浅紫圆标 + 白字。k=2 时圆标色
/// 落在两个中心之外，**框外那一半圆标就长不进去**（生长按"离某个中心足够
/// 近"判定），掩膜上留下一条 5px 的竖洞。洞里还是原来的紫色 —— 填色时它
/// 就成了"已知像素"，于是那块地方被填成一团紫，用户看到的就是"擦了还留
/// 紫点"。k=3 让三种颜色各有中心，生长不再漏。
List<int> _kmeans(List<int> colors, int k) {
  if (colors.isEmpty) return const [];
  if (colors.length < 8) {
    var sumR = 0, sumG = 0, sumB = 0;
    for (final c in colors) {
      sumR += (c >> 16) & 0xFF;
      sumG += (c >> 8) & 0xFF;
      sumB += c & 0xFF;
    }
    final m = colors.length;
    return [(sumR ~/ m) << 16 | (sumG ~/ m) << 8 | (sumB ~/ m)];
  }
  // 初值：第一个点 + 离它最远的点 + 离这两点都最远的点（确定性，不用随机）。
  final centers = <int>[colors.first];
  while (centers.length < k) {
    var best = colors[1];
    var bestD = -1;
    for (final c in colors) {
      var nearest = 1 << 30;
      for (final ctr in centers) {
        final d = _dist2(c, ctr);
        if (d < nearest) nearest = d;
      }
      if (nearest > bestD) {
        bestD = nearest;
        best = c;
      }
    }
    if (bestD <= 0) break;
    centers.add(best);
  }
  for (var iter = 0; iter < 8; iter++) {
    final sr = List<int>.filled(centers.length, 0);
    final sg = List<int>.filled(centers.length, 0);
    final sb = List<int>.filled(centers.length, 0);
    final sn = List<int>.filled(centers.length, 0);
    for (final c in colors) {
      var bestIdx = 0;
      var bestD = 1 << 30;
      for (var i = 0; i < centers.length; i++) {
        final d = _dist2(c, centers[i]);
        if (d < bestD) {
          bestD = d;
          bestIdx = i;
        }
      }
      sr[bestIdx] += (c >> 16) & 0xFF;
      sg[bestIdx] += (c >> 8) & 0xFF;
      sb[bestIdx] += c & 0xFF;
      sn[bestIdx]++;
    }
    var moved = false;
    for (var i = 0; i < centers.length; i++) {
      if (sn[i] == 0) continue;
      final next =
          ((sr[i] ~/ sn[i]) << 16) | ((sg[i] ~/ sn[i]) << 8) | (sb[i] ~/ sn[i]);
      if (next != centers[i]) {
        centers[i] = next;
        moved = true;
      }
    }
    if (!moved) break;
  }
  return centers;
}

/// 填掉掩膜内部的**空洞**（不接触窗口边界的非掩膜区域）。
///
/// 洞里的像素会保持原样，填色时它们就是"已知的邻居"，会把水印原来的颜色
/// 重新混回填充结果（实测表现为"擦完还剩一块紫"）。这里把闭合区域一律并进
/// 掩膜：水印内部没有"必须保留"的东西，而边缘精度由 ctx 边界保证。
void _fillHoles(Uint8List mask, int w, int h) {
  final rest = Uint8List(w * h);
  final stack = <int>[];
  void seed(int i) {
    if (i < 0 || i >= rest.length) return;
    if (mask[i] != 0 || rest[i] != 0) return;
    rest[i] = 1;
    stack.add(i);
  }

  for (var x = 0; x < w; x++) {
    seed(x);
    seed((h - 1) * w + x);
  }
  for (var y = 0; y < h; y++) {
    seed(y * w);
    seed(y * w + w - 1);
  }
  while (stack.isNotEmpty) {
    final i = stack.removeLast();
    final x = i % w;
    if (x > 0) seed(i - 1);
    if (x < w - 1) seed(i + 1);
    seed(i - w);
    seed(i + w);
  }
  for (var i = 0; i < rest.length; i++) {
    if (mask[i] == 0 && rest[i] == 0) mask[i] = 1;
  }
}

// ── 对外：水印物体掩膜 ─────────────────────────────────────────────────────

/// 水印块的**物体级**掩膜：把"水印这个整体"圈出来，而不是只圈字。
///
/// 参数与语义：
/// * [rect] —— 用户框选的范围（源像素）。用户会刻意框得紧一点以免伤到边缘，
///   所以这里把它当"物体核心"，真实边界靠残差与生长决定；
/// * [polygon] —— 有顶点时用于把种子限制在轮廓内（用户画得更准）；
/// * [contextExpand] —— 上下文环带比例，默认 0.30（外扩总尺寸 30%）；
/// * [tolerance] —— 种子残差阈值（0..441 的加权色距），默认 34；
/// * [growTolerance] —— 生长时允许的颜色偏移，默认 30。
///
/// 残差种子不足 [rect] 面积的 1% 时**退回整块区域**：水印必须消失，"没检出来"
/// 不能变成"留着"（[RegionMaskResult.fallback] 记录这件事）。
RegionMaskResult buildWatermarkMask(
  RgbaImage image,
  IntRect rect, {
  List<List<double>>? polygon,
  double contextExpand = 0.30,
  int tolerance = 34,
  int growTolerance = 30,
}) {
  final w = image.width;
  final h = image.height;
  final box = _clampRect(rect, w, h);
  if (box.width < 3 || box.height < 3) {
    return RegionMaskResult(
      mask: Uint8List(w * h),
      seedPixels: 0,
      totalPixels: 0,
      fallback: false,
    );
  }
  // ① 两层窗口：检测区 ctx + **背景取样区 outer**。
  //
  // 🔴 预测必须从 outer 取，不能从 ctx 边界取。用户框水印时贴着水印本体框，
  // ctx 的边界往往**还在水印自己身上**（底盘露出的那一圈），从那里"预测底图"
  // 预测出来的就是水印底色 —— 残差≈0，检测直接失败，退化成整块矩形，紫边
  // 照样留在画面上。这正是第一版实现踩的坑（headless 断言当场判红）。
  // outer 再外扩一圈，看到的才是画面真正的背景。
  final ctx = _contextWindow(box, contextExpand, w, h);
  final outer = _contextWindow(ctx, 0.12, w, h);
  final win = _Win(outer.left, outer.top, outer.width, outer.height);
  final n = win.w * win.h;

  void markRect(IntRect r, Uint8List target) {
    final l = r.left - win.left;
    final t = r.top - win.top;
    for (var y = t; y < t + r.height; y++) {
      if (y < 0 || y >= win.h) continue;
      final row = y * win.w;
      for (var x = l; x < l + r.width; x++) {
        if (x < 0 || x >= win.w) continue;
        target[row + x] = 1;
      }
    }
  }

  // 预测时把整个 ctx 当洞（水印 + 它脚下的一点画面一起预测）。
  final hole = Uint8List(n);
  markRect(ctx, hole);
  // 生长允许范围 = ctx。绝不长到 outer 里 —— 那是画面背景，长进去就是误伤。
  final allowed = Uint8List(n);
  markRect(ctx, allowed);
  // 种子判定范围 = 用户的块框。ctx 里属于画面的部分（水印旁边的头发、
  // 对话框描边）不该被当成水印。
  final seedArea = Uint8List(n);
  markRect(box, seedArea);

  if (polygon != null && polygon.length >= 3) {
    final pagePoly = _rasterizeLocal(
      width: w,
      height: h,
      polygon: polygon,
      win: win,
    );
    for (var i = 0; i < n; i++) {
      if (pagePoly[i] != 0) continue;
      seedArea[i] = 0;
      allowed[i] = 0;
    }
  }
  var holeCount = 0;
  var seedAreaCount = 0;
  for (var i = 0; i < n; i++) {
    if (hole[i] != 0) holeCount++;
    if (seedArea[i] != 0) seedAreaCount++;
  }
  if (holeCount == 0 || seedAreaCount == 0) {
    return RegionMaskResult(
      mask: Uint8List(w * h),
      seedPixels: 0,
      totalPixels: 0,
      fallback: false,
    );
  }

  final pred = _predictWindow(image, win, Uint8List.fromList(hole), relax: 3);
  final px = image.pixels;

  // ① 残差种子
  final seeds = Uint8List(n);
  final seedColors = <int>[];
  final diff = Uint8List(n);
  for (var y = 0; y < win.h; y++) {
    final row = y * win.w;
    for (var x = 0; x < win.w; x++) {
      final i = row + x;
      if (seedArea[i] == 0) continue;
      final pi = ((win.top + y) * w + (win.left + x)) * 4;
      final oi = i * 4;
      final a = _pack(px, pi);
      final b = _pack(pred, oi);
      final d = _dist2(a, b);
      diff[i] = d > 255 ? 255 : d;
      if (d >= tolerance) {
        seeds[i] = 1;
        seedColors.add(a);
      }
    }
  }

  final minSeeds = math.max(8, (seedAreaCount * 0.01).round());
  if (seedColors.length < minSeeds) {
    // 退路：整块块框（多边形时只到轮廓内）。
    final out = Uint8List(w * h);
    for (var y = 0; y < win.h; y++) {
      final row = y * win.w;
      for (var x = 0; x < win.w; x++) {
        if (seedArea[row + x] == 0) continue;
        out[(win.top + y) * w + win.left + x] = 255;
      }
    }
    return RegionMaskResult(
      mask: out,
      seedPixels: seedColors.length,
      totalPixels: seedAreaCount,
      fallback: true,
    );
  }

  // ② 颜色聚类 + 连通生长
  final centers = _kmeans(seedColors, 3);
  final grow = Uint8List(n);
  final queue = <int>[];
  for (var i = 0; i < n; i++) {
    if (seeds[i] == 0) continue;
    grow[i] = 1;
    queue.add(i);
  }
  // 生长上限：允许长到块框的 6 倍（底盘常常比框大得多），但绝不超出 ctx。
  final maxGrow = math.min(holeCount, (seedAreaCount * 6).round());
  var grown = seedColors.length;
  var head = 0;
  while (head < queue.length) {
    final i = queue[head++];
    if (grown >= maxGrow) break;
    final x = i % win.w;
    final y = i ~/ win.w;
    for (var k = 0; k < 4; k++) {
      final nx = x + (k == 0 ? -1 : (k == 1 ? 1 : 0));
      final ny = y + (k == 2 ? -1 : (k == 3 ? 1 : 0));
      if (nx < 0 || ny < 0 || nx >= win.w || ny >= win.h) continue;
      final ni = ny * win.w + nx;
      if (grow[ni] != 0) continue;
      // 只在水印所在的 ctx 内生长，绝不进 outer 的背景环带。
      if (allowed[ni] == 0) continue;
      final pi = ((win.top + ny) * w + (win.left + nx)) * 4;
      final c = _pack(px, pi);
      var best = 1 << 30;
      for (final ctr in centers) {
        final d = _dist2(c, ctr);
        if (d < best) best = d;
      }
      if (best > growTolerance) continue;
      // 必须仍然"不像底图"，否则会把与底盘同色的天空/黑底一路吃进去。
      if (diff[ni] != 0 && diff[ni] < growTolerance) continue;
      grow[ni] = 1;
      grown++;
      queue.add(ni);
      if (grown >= maxGrow) break;
    }
  }

  // ③ 闭运算（吃平底盘与字之间的镂空）+ 去小块 + 边缘膨胀
  final minSide = math.min(box.width, box.height);
  final closeR = math.max(1, (minSide * 0.03).round()).clamp(1, 4);
  var m = _morph(grow, win.w, win.h, closeR, dilate: true);
  m = _morph(m, win.w, win.h, closeR, dilate: false);
  final minPixels = math.max(12, (seedAreaCount * 0.004).round());
  _filterSmall(m, win.w, win.h, minPixels);
  // 🔴 填洞必须在膨胀之前：洞里的原色会成为填色源，把水印颜色混回结果。
  _fillHoles(m, win.w, win.h);
  m = _morph(m, win.w, win.h, 2, dilate: true);
  // 生长上限之外、闭运算/膨胀溢出的像素也不能越出 ctx（否则会啃到画面）。
  final out = Uint8List(w * h);
  var total = 0;
  for (var y = 0; y < win.h; y++) {
    final row = y * win.w;
    for (var x = 0; x < win.w; x++) {
      if (m[row + x] == 0) continue;
      if (allowed[row + x] == 0) continue;
      out[(win.top + y) * w + win.left + x] = 255;
      total++;
    }
  }
  return RegionMaskResult(
    mask: out,
    seedPixels: seedColors.length,
    totalPixels: total,
    fallback: false,
  );
}

/// 多边形在窗口坐标下的栅格化（复用整页栅格化的同一套扫描线，只是窗口化）。
Uint8List _rasterizeLocal({
  required int width,
  required int height,
  required List<List<double>> polygon,
  required _Win win,
}) {
  final n = win.w * win.h;
  final out = Uint8List(n);
  if (polygon.length < 3) return out;
  var minY = double.infinity;
  var maxY = double.negativeInfinity;
  for (final p in polygon) {
    if (p[1] < minY) minY = p[1];
    if (p[1] > maxY) maxY = p[1];
  }
  if (!minY.isFinite) return out;
  var yStart = minY.floor() - win.top - 1;
  if (yStart < 0) yStart = 0;
  var yEnd = maxY.ceil() - win.top + 1;
  if (yEnd > win.h) yEnd = win.h;
  final count = polygon.length;
  final xs = <double>[];
  for (var ly = yStart; ly < yEnd; ly++) {
    final yc = (win.top + ly) + 0.5;
    xs.clear();
    for (var i = 0; i < count; i++) {
      final a = polygon[i];
      final b = polygon[(i + 1) % count];
      final y1 = a[1];
      final y2 = b[1];
      if ((y1 <= yc && y2 > yc) || (y2 <= yc && y1 > yc)) {
        final t = (yc - y1) / (y2 - y1);
        xs.add(a[0] + t * (b[0] - a[0]));
      }
    }
    if (xs.length < 2) continue;
    xs.sort();
    for (var k = 0; k + 1 < xs.length; k += 2) {
      var x0 = xs[k].floor() - win.left;
      var x1 = xs[k + 1].ceil() - win.left;
      if (x1 <= x0) continue;
      if (x0 < 0) x0 = 0;
      if (x1 > win.w) x1 = win.w;
      final row = ly * win.w;
      for (var x = x0; x < x1; x++) {
        out[row + x] = 255;
      }
    }
  }
  return out;
}

// ── 对外：普通文字块的"补漏"掩膜 ───────────────────────────────────────────

/// 普通文字块（对话/拟声词）的**补漏**掩膜：抓住字形掩膜漏掉的笔画。
///
/// `computeMask` 用 Otsu 分离笔画，遇到低对比度、细描边、半透明字时会漏，
/// 表现为"擦完还留着半个字"（第 10 页实测）。这里用同一套残差思路补一遍：
/// 在 [rect] 内预测底图、取残差种子、去小块、膨胀 2px。
///
/// 🔴 与 [buildWatermarkMask] 的关键差别：**不做连通生长**、**不退整块**。
/// 普通块的框里可能有气泡描边、网点、角色线条，生长与整块退路都会误伤。
Uint8List buildResidualTextMask(
  RgbaImage image,
  List<IntRect> rects, {
  int tolerance = 28,
}) {
  final w = image.width;
  final h = image.height;
  final out = Uint8List(w * h);
  for (final raw in rects) {
    final box = _clampRect(raw, w, h);
    if (box.width < 4 || box.height < 4) continue;
    // 上下文 30%：预测需要看到框外的底图，否则贴边字会被误判成"内容"。
    final ctx = _clampRect(_inflate(box, 0.30), w, h);
    final win = _Win(ctx.left, ctx.top, ctx.width, ctx.height);
    final hole = Uint8List(win.w * win.h);
    final boxLeft = box.left - win.left;
    final boxTop = box.top - win.top;
    for (var y = boxTop; y < boxTop + box.height; y++) {
      if (y < 0 || y >= win.h) continue;
      final row = y * win.w;
      for (var x = boxLeft; x < boxLeft + box.width; x++) {
        if (x < 0 || x >= win.w) continue;
        hole[row + x] = 1;
      }
    }
    final pred = _predictWindow(image, win, Uint8List.fromList(hole), relax: 2);
    final px = image.pixels;
    final seeds = Uint8List(win.w * win.h);
    var seedCount = 0;
    for (var y = 0; y < win.h; y++) {
      final row = y * win.w;
      for (var x = 0; x < win.w; x++) {
        final i = row + x;
        if (hole[i] == 0) continue;
        final pi = ((win.top + y) * w + (win.left + x)) * 4;
        final a = _pack(px, pi);
        final b = _pack(pred, i * 4);
        if (_dist2(a, b) >= tolerance) {
          seeds[i] = 1;
          seedCount++;
        }
      }
    }
    if (seedCount == 0) continue;
    var boxArea = 0;
    for (var i = 0; i < hole.length; i++) {
      if (hole[i] != 0) boxArea++;
    }
    // 整块都被判成"内容" ⇒ 多半是网点/线稿，不是字，宁可不动。
    if (seedCount > boxArea * 0.7) continue;
    _filterSmall(seeds, win.w, win.h, math.max(6, (boxArea * 0.0015).round()));
    final grown = _morph(seeds, win.w, win.h, 2, dilate: true);
    for (var y = 0; y < win.h; y++) {
      final row = y * win.w;
      for (var x = 0; x < win.w; x++) {
        if (grown[row + x] == 0) continue;
        out[(win.top + y) * w + win.left + x] = 255;
      }
    }
  }
  return out;
}

// ── 对外：填色 ─────────────────────────────────────────────────────────────

/// 按 [regionMask] 修复 [image] **原地**。返回实际填充的像素数。
///
/// [quality] 见 [RepairQuality]。像素缓冲区必须在调用前就**只含原图**（洞内
/// 的旧内容会被整体覆盖，不需要预先擦一遍）。
RepairStats repairRegionInPlace(
  RgbaImage image,
  Uint8List regionMask, {
  RepairQuality quality = RepairQuality.structural,
}) {
  final w = image.width;
  final h = image.height;
  if (regionMask.length != w * h) {
    throw ArgumentError(
      'mask size mismatch: ${regionMask.length} vs ${w * h}',
    );
  }
  // 掩膜外接框：只在框内做，别把整页读进内存。
  var minX = w, minY = h, maxX = -1, maxY = -1;
  var count = 0;
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      if (regionMask[row + x] == 0) continue;
      count++;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  if (count == 0) {
    return const RepairStats(filledPixels: 0, textured: false, windowArea: 0);
  }
  // 🔴 窗口外扩量按档位分开：
  // * 结构档只需要"四周一圈真像素"给射线起点，pad=3 就够（也保证老行为不变）；
  // * 纹理档需要在窗口里找到**整块干净的 patch**当候选源。当写入区域=整片
  //   选区时，pad=3 的环带连一个 8×8 的干净块都放不下 ⇒ `sources` 为空 ⇒
  //   纹理档静默变成空操作（实测：纹理档与结构档的输出 PNG 字节完全相同）。
  //   所以纹理档按选区尺寸外扩 35%（至少 24px）。
  final bw = maxX - minX + 1;
  final bh = maxY - minY + 1;
  final pad = quality == RepairQuality.texture
      ? math.max(24, (math.min(bw, bh) * 0.35).round())
      : 3;
  final win = _windowOf(
    IntRect(minX, minY, maxX + 1, maxY + 1),
    w,
    h,
    pad: pad,
  );
  final n = win.w * win.h;
  final hole = Uint8List(n);
  for (var y = 0; y < win.h; y++) {
    final row = y * win.w;
    final srcRow = (win.top + y) * w + win.left;
    for (var x = 0; x < win.w; x++) {
      if (regionMask[srcRow + x] != 0) hole[row + x] = 1;
    }
  }

  final pred = _predictWindow(image, win, Uint8List.fromList(hole), relax: 2);
  final px = image.pixels;
  for (var y = 0; y < win.h; y++) {
    final row = y * win.w;
    for (var x = 0; x < win.w; x++) {
      final i = row + x;
      if (hole[i] == 0) continue;
      final di = ((win.top + y) * w + (win.left + x)) * 4;
      final si = i * 4;
      px[di] = pred[si];
      px[di + 1] = pred[si + 1];
      px[di + 2] = pred[si + 2];
      px[di + 3] = pred[si + 3];
    }
  }

  var textured = false;
  if (quality == RepairQuality.texture) {
    textured = _textureOverlay(image, win, hole, count);
  }
  return RepairStats(
    filledPixels: count,
    textured: textured,
    windowArea: n,
  );
}

/// 块级纹理合成：在上下文环带里找最相似的 patch 覆盖回洞里。
///
/// ## 算法（Criminisi 一系的简化版，非神经网络）
///
/// 1. 把洞按 [block] 网格切成块，按"离已知像素的距离"从小到大处理 ——
///    先补靠边界的块，后面的块才有可靠的邻居可比；
/// 2. 候选源 = 窗口内**完全已知**的同尺寸块，按 [stride] 抽样；
/// 3. 代价 = 块内逐像素色差的加权平方和，**已知邻居权重 1.0、已填像素 0.3**
///    （已填像素只是方向性插值的近似值，不该和真像素等权）；
/// 4. 最优块的对应像素以 70% 权重覆盖回去，与底下的结构填充混合 —— 全量
///    替换会在块边界留下硬缝。
///
/// 返回是否真的做了纹理合成（洞太大时主动放弃，避免卡住 UI）。
bool _textureOverlay(RgbaImage image, _Win win, Uint8List hole, int holeCount) {
  // 🔴 上限：超过 12 万像素的洞直接放弃纹理档（仍保留结构填充）。
  // 单块水印通常几千像素，整页级别才可能撞到这个量。
  if (holeCount > 120000) return false;
  final block = holeCount > 40000 ? 12 : 8;
  final stride = holeCount > 40000 ? 9 : 6;
  final w = image.width;
  final px = image.pixels;

  // 候选源位置：块完全落在已知区域。
  final sources = <int>[];
  for (var ly = 0; ly + block <= win.h; ly += stride) {
    for (var lx = 0; lx + block <= win.w; lx += stride) {
      var clean = true;
      for (var dy = 0; dy < block && clean; dy++) {
        final row = (ly + dy) * win.w;
        for (var dx = 0; dx < block; dx++) {
          if (hole[row + lx + dx] != 0) {
            clean = false;
            break;
          }
        }
      }
      if (clean) sources.add(ly * win.w + lx);
    }
  }
  if (sources.isEmpty) return false;

  // 洞块列表，按"离已知像素最近"排序（用 chamfer 距离场的粗近似）。
  final dist = Int32List(win.w * win.h);
  const inf = 1 << 28;
  for (var i = 0; i < dist.length; i++) {
    dist[i] = hole[i] == 0 ? 0 : inf;
  }
  for (var y = 0; y < win.h; y++) {
    for (var x = 0; x < win.w; x++) {
      final i = y * win.w + x;
      if (hole[i] == 0) continue;
      if (x > 0 && dist[i - 1] + 3 < dist[i]) dist[i] = dist[i - 1] + 3;
      if (y > 0 && dist[i - win.w] + 3 < dist[i]) {
        dist[i] = dist[i - win.w] + 3;
      }
    }
  }
  for (var y = win.h - 1; y >= 0; y--) {
    for (var x = win.w - 1; x >= 0; x--) {
      final i = y * win.w + x;
      if (hole[i] == 0) continue;
      if (x < win.w - 1 && dist[i + 1] + 3 < dist[i]) dist[i] = dist[i + 1] + 3;
      if (y < win.h - 1 && dist[i + win.w] + 3 < dist[i]) {
        dist[i] = dist[i + win.w] + 3;
      }
    }
  }

  final blocks = <int>[];
  for (var by = 0; by < win.h; by += block) {
    for (var bx = 0; bx < win.w; bx += block) {
      var any = false;
      for (var dy = 0; dy < block && by + dy < win.h && !any; dy++) {
        final row = (by + dy) * win.w;
        for (var dx = 0; dx < block && bx + dx < win.w; dx++) {
          if (hole[row + bx + dx] != 0) {
            any = true;
            break;
          }
        }
      }
      if (any) blocks.add(by * win.w + bx);
    }
  }
  blocks.sort((a, b) {
    var da = inf;
    var db = inf;
    final ay = a ~/ win.w, ax = a % win.w;
    final by = b ~/ win.w, bx = b % win.w;
    for (var dy = 0; dy < block && ay + dy < win.h; dy++) {
      for (var dx = 0; dx < block && ax + dx < win.w; dx++) {
        final d = dist[(ay + dy) * win.w + ax + dx];
        if (d < da) da = d;
      }
    }
    for (var dy = 0; dy < block && by + dy < win.h; dy++) {
      for (var dx = 0; dx < block && bx + dx < win.w; dx++) {
        final d = dist[(by + dy) * win.w + bx + dx];
        if (d < db) db = d;
      }
    }
    return da.compareTo(db);
  });

  final bw = win.w;
  for (final blk in blocks) {
    final by = blk ~/ bw;
    final bx = blk % bw;
    var bestIdx = -1;
    var bestScore = 1 << 62;
    for (final src in sources) {
      final sy = src ~/ bw;
      final sx = src % bw;
      var score = 0;
      for (var dy = 0; dy < block; dy++) {
        final ly = by + dy;
        if (ly >= win.h) break;
        final lrow = ly * bw;
        for (var dx = 0; dx < block; dx++) {
          final lx = bx + dx;
          if (lx >= win.w) break;
          final li = lrow + lx;
          final di = ((win.top + ly) * w + (win.left + lx)) * 4;
          final sdi = ((win.top + sy + dy) * w + (win.left + sx + dx)) * 4;
          final dr = px[di] - px[sdi];
          final dg = px[di + 1] - px[sdi + 1];
          final db2 = px[di + 2] - px[sdi + 2];
          final weight = hole[li] == 0 ? 10 : 3;
          score += (dr * dr + dg * dg + db2 * db2) * weight;
          if (score >= bestScore) break;
        }
        if (score >= bestScore) break;
      }
      if (score < bestScore) {
        bestScore = score;
        bestIdx = src;
      }
    }
    if (bestIdx < 0) continue;
    final sy = bestIdx ~/ bw;
    final sx = bestIdx % bw;
    for (var dy = 0; dy < block; dy++) {
      final ly = by + dy;
      if (ly >= win.h) break;
      for (var dx = 0; dx < block; dx++) {
        final lx = bx + dx;
        if (lx >= win.w) break;
        final li = ly * bw + lx;
        if (hole[li] == 0) continue;
        final di = ((win.top + ly) * w + (win.left + lx)) * 4;
        final sdi = ((win.top + sy + dy) * w + (win.left + sx + dx)) * 4;
        for (var c = 0; c < 3; c++) {
          px[di + c] = ((px[sdi + c] * 7 + px[di + c] * 3) ~/ 10).clamp(0, 255);
        }
      }
    }
  }
  return true;
}

// ── 对外：向底色融合的马赛克 ───────────────────────────────────────────────

/// 把 [regionMask] 内的像素**马赛克化并向底图颜色融合**。
///
/// ## 为什么不沿用「块内取均值」的经典马赛克
///
/// 经典马赛克保留原色，于是黑底上的紫色水印条被打成一块块**紫色方块** ——
/// 用户实测的原话是"马赛克也还留着紫色"（第 3 页）。对水印这种"整片异物"
/// 的诉求是"看不出有水印"，而不是"看得出有马赛克"，所以这里让每个块的
/// 颜色按 [backgroundBlend] 向**上下文预测出来的底色**靠：
///
/// * 0.0 = 经典马赛克（保留原色）；
/// * 1.0 = 等价于整块擦除；
/// * 默认 0.75 —— 黑底读作近黑、裙子读作裙子色，只留一点点纹理，既是
///   "暂时遮挡"又不突兀。
///
/// 返回被改写的像素数；0 表示掩膜为空。
int mosaicWithBackgroundInPlace(
  RgbaImage image,
  Uint8List regionMask, {
  int blockSize = 12,
  double backgroundBlend = 0.75,
}) {
  final w = image.width;
  final h = image.height;
  if (regionMask.length != w * h) {
    throw ArgumentError(
      'mask size mismatch: ${regionMask.length} vs ${w * h}',
    );
  }
  var minX = w, minY = h, maxX = -1, maxY = -1;
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
  final win = _windowOf(
    IntRect(minX, minY, maxX + 1, maxY + 1),
    w,
    h,
    pad: 4,
  );
  final n = win.w * win.h;
  final hole = Uint8List(n);
  for (var y = 0; y < win.h; y++) {
    final row = y * win.w;
    final srcRow = (win.top + y) * w + win.left;
    for (var x = 0; x < win.w; x++) {
      if (regionMask[srcRow + x] != 0) hole[row + x] = 1;
    }
  }
  final pred = _predictWindow(image, win, Uint8List.fromList(hole), relax: 1);
  final px = image.pixels;
  final bs = blockSize < 2 ? 2 : blockSize;
  final blend = backgroundBlend.clamp(0.0, 1.0);
  var changed = 0;
  for (var by = 0; by < win.h; by += bs) {
    final ye = math.min(by + bs - 1, win.h - 1);
    for (var bx = 0; bx < win.w; bx += bs) {
      final xe = math.min(bx + bs - 1, win.w - 1);
      var r = 0, g = 0, b = 0, a = 0, c = 0;
      var pr = 0, pg = 0, pb = 0;
      for (var y = by; y <= ye; y++) {
        final row = y * win.w;
        for (var x = bx; x <= xe; x++) {
          final i = row + x;
          if (hole[i] == 0) continue;
          final di = ((win.top + y) * w + (win.left + x)) * 4;
          final si = i * 4;
          r += px[di];
          g += px[di + 1];
          b += px[di + 2];
          a += px[di + 3];
          pr += pred[si];
          pg += pred[si + 1];
          pb += pred[si + 2];
          c++;
        }
      }
      if (c == 0) continue;
      final mr = r / c;
      final mg = g / c;
      final mb = b / c;
      final ma = a / c;
      final tr = mr * (1 - blend) + (pr / c) * blend;
      final tg = mg * (1 - blend) + (pg / c) * blend;
      final tb = mb * (1 - blend) + (pb / c) * blend;
      for (var y = by; y <= ye; y++) {
        final row = y * win.w;
        for (var x = bx; x <= xe; x++) {
          final i = row + x;
          if (hole[i] == 0) continue;
          final di = ((win.top + y) * w + (win.left + x)) * 4;
          px[di] = tr.round().clamp(0, 255);
          px[di + 1] = tg.round().clamp(0, 255);
          px[di + 2] = tb.round().clamp(0, 255);
          px[di + 3] = ma.round().clamp(0, 255);
          changed++;
        }
      }
    }
  }
  return changed;
}
