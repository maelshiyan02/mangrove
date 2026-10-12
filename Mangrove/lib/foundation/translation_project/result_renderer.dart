import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../image_translation/inpaint.dart';
import '../image_translation/page_renderer.dart';
import '../image_translation/translation_types.dart';
import 'mask_producer.dart';
import 'project.dart';

/// Renders one project page's finished bitmap: the text-free `inpainted/` base
/// with the page's translated blocks lettered over it. Returns null when there
/// is nothing to render (`inpainted/` missing, or the page has no translation).
///
/// This is the `result/` half of the unified save contract (P6 §2.8): a save
/// writes the JSON and the intermediates synchronously, then — because
/// re-rendering every page of a 97-page project is expensive — regenerates
/// `result/` in the background so the editor never blocks on it.
///
/// It is deliberately a free function over [TranslationProject] rather than a
/// method on `BtProjectManager`: the studio works with the
/// `translation_project` model, and routing the render through the older
/// `BtProject` model would make "save" depend on which model happened to be
/// registered.
Future<Uint8List?> renderProjectResultPage(
  TranslationProject project,
  String pageKey,
) async {
  final page = project.pages[pageKey];
  if (page == null) return null;
  final regions = page.regions;
  if (regions.isEmpty) return null;
  final inpainted = project.inpaintedPath(pageKey);
  if (inpainted == null) return null;
  final bytes = await File(inpainted).readAsBytes();
  if (bytes.isEmpty) return null;

  final decoded = await _decodeBounded(bytes);
  // BT boxes are in the source's full resolution; the working image may be
  // scaled down by the decode budget, so the regions must be scaled with it.
  final scale = decoded.image.width / decoded.originalWidth;
  final scaled = [
    for (final region in regions)
      TranslatedRegion(
        rect: IntRect(
          (region.rect.left * scale).round(),
          (region.rect.top * scale).round(),
          (region.rect.right * scale).round(),
          (region.rect.bottom * scale).round(),
        ),
        text: region.text,
        backgroundColor: region.backgroundColor,
        textColor: region.textColor,
        lineHeight:
            region.lineHeight > 0 ? (region.lineHeight * scale).round() : 0,
        // 🔴 P0-1: this line is the whole reason the studio's font settings
        // reach `result/`. The region is **rebuilt from scratch** here (to
        // rescale the boxes to the working image), and the rebuild used to copy
        // only rect/text/colours — silently dropping every font attribute. The
        // user would set a family and a weight in the studio, save, and the
        // exported page came out in the renderer's default face.
        //
        // Every length is multiplied by the same [scale] for the same reason
        // the boxes are: the styles are in source pixels and the canvas is not.
        // Angles, weights and ratios (opacity, letter spacing) are scale-free
        // and pass through untouched.
        fontStyle: _scaledFontStyle(region.fontStyle, scale),
      ),
  ];
  // The inpainted PNG is already text-free, so render in smart mode: the decoded
  // pixels are used as the base directly, with only a contrast outline added.
  return renderTranslatedPage(
    bytes,
    decoded.image,
    scaled,
    mode: InpaintMode.smart,
  );
}

/// `inpainted/` 的底图**只从原图取** —— 这是底图来源的唯一真相。
///
/// ## 为什么不能从现有的 `inpainted/` 取
///
/// 对一份**已经是去字结果**的位图再擦一遍，只会把背景越擦越糊，而且
/// **每保存一次就更糊一点**：误差是累积的，界面上却看不出任何异常 ——
/// 用户只会觉得"画质怎么越来越差"。
///
/// ## 为什么它值得是一个函数
///
/// 否则"底图到底取自哪里"只能靠读 `renderInpaintedPage` 的第三行，而这一行
/// 恰好是最容易被"顺手优化成复用已有产物"的一行。抽出来之后它有一条可注入
/// 故障的断言：`inpaint.base_source_is_original`。
String inpaintedBaseSourcePath(TranslationProject project, String pageKey) =>
    project.originalPath(pageKey);

/// 这一页能不能产出 `inpainted/`：判据只有一条 —— **解码不许降采样**。
///
/// ## 它不是一句算术，是一条坐标契约
///
/// `result/` 侧的坐标换算是 `decoded.image.width / decoded.originalWidth`。
/// 当输入位图是 `inpainted/` 时，这两个值是**同一个文件的宽** ⇒ `scale == 1.0`，
/// 页面 regions 被当作**源坐标**直接使用。一旦这里放行一个被 `_decodeBounded`
/// 缩过的底图，那个 `scale == 1.0` 就变成谎言：框按源坐标落在缩小的图上，
/// **位置全错而不报错**。
///
/// 所以超大页（> 12 MP 或 > 8000 px）宁可**不产出** `inpainted/`
/// （`result/` 会如实地把它记成 skipped），也不产出一个破坏坐标契约的文件。
///
/// 抽成函数是为了让这条契约能被注入故障验证（`inpaint.base_requires_no_downscale`）：
/// 内联的 `a != b` 换个写法就再也测不出它保护的是什么。
bool canProduceInpaintedBase({
  required int decodedWidth,
  required int originalWidth,
}) => decodedWidth == originalWidth;

/// Renders one project page's **text-free** base (`inpainted/`).
///
/// ## 为什么这个函数必须存在（S9.5-a 补的一场欠账）
///
/// 统一保存契约（P6 §2.8，用户原话："都在各自的漫画文件目录地址下生成
/// `inpainted`、`mask`、`result`、相关 json 文件"）把 `mask/` 与 `inpainted/`
/// 定为**保存时同步产出**。但 P8.1 §82 把"去字"推迟到 S9 之后，S9 的交付清单
/// 又没有把它捡回来 —— 于是**没有任何代码生产 `inpainted/`**，而
/// [renderProjectResultPage] 的第一个前提就是它。整条链路因此卡在最后一环：
///
/// ```
///   info Translation Studio 2026-10-07 20:45:06
///   result/ regenerated: artifacts written=0 skipped=1 failed=0 (dirty=1)
/// ```
///
/// `written=0` 不是"这页没译文"，而是 `renderProjectResultPage` 在
/// `inpaintedPath == null` 上**返回 null**，被 `writeArtifacts` 记成 skipped。
/// 出图腿从未工作过，而且不报错。
///
/// ## 与 [renderProjectResultPage] 的分工
///
/// 本函数只做"去字"：取**原图** → 按页面 regions 的 `eraseRects` 擦除原文 →
/// 编码 PNG。绘制译文是 [renderProjectResultPage] 的事。两者顺序不可颠倒，
/// 因为后者把前者的产物当作输入位图。
///
/// 之所以从**原图**而不是现有的 `inpainted/` 取底：对一份已经是去字结果的位图
/// 再擦一遍，只会把背景越擦越糊，且每保存一次就更糊一点。
///
/// 🔴 **只在不需要降采样时才产出**。`result/` 侧的坐标换算是
/// `decoded.image.width / decoded.originalWidth` —— 当输入是 `inpainted/` 时，
/// 这两个值是**同一个文件的宽**，于是 `scale == 1.0`，页面 regions 被当作源
/// 坐标直接使用。一旦这里写出一个被 `_decodeBounded` 缩过的底图，那个
/// `scale == 1.0` 就变成谎言：框按源坐标落在缩小的图上，**位置全错而不报错**。
/// 所以超大页（> 12 MP 或 > 8000 px）宁可**不产出** `inpainted/`（`result/`
/// 会如实地把它记成 skipped），也不产出一个破坏坐标契约的文件。
///
/// 返回 null 表示"这一页没有可产出的底图"（页不存在 / 原图不在 / 没有 regions /
/// 需要降采样），调用方应记成 skipped 而不是失败。
Future<Uint8List?> renderInpaintedPage(
  TranslationProject project,
  String pageKey,
) async {
  final page = project.pages[pageKey];
  if (page == null) return null;
  final regions = page.regions;
  if (regions.isEmpty) return null;
  final source = File(inpaintedBaseSourcePath(project, pageKey));
  if (!source.existsSync()) return null;
  final bytes = await source.readAsBytes();
  if (bytes.isEmpty) return null;

  final decoded = await _decodeBounded(bytes);
  // 见上文：降采样会让 `result/` 的坐标换算失去意义，宁可不产出。
  if (!canProduceInpaintedBase(
    decodedWidth: decoded.image.width,
    originalWidth: decoded.originalWidth,
  )) {
    return null;
  }
  final scale = decoded.image.width / decoded.originalWidth;

  final eraseRects = <IntRect>[
    for (final region in regions)
      for (final rect in region.eraseRects)
        IntRect(
          (rect.left * scale).round(),
          (rect.top * scale).round(),
          (rect.right * scale).round(),
          (rect.bottom * scale).round(),
        ),
  ];
  if (eraseRects.isEmpty) return null;

  // 纯 Dart 擦除：Otsu 分出前景笔画 + 膨胀吞掉抗锯齿边，然后从周围画面重建。
  // 传入的矩形只是**搜索窗口**，真正被抹掉的像素由它内部的笔画判定决定 ——
  // 所以这里用块的外框（`eraseRects` 在工程模型里就是 `xyxy`）是安全的。
  TextInpainter.erase(decoded.image, eraseRects);
  // regions 传空：只编码底图，一个字都不画。
  return renderTranslatedPage(
    bytes,
    decoded.image,
    const [],
    mode: InpaintMode.smart,
  );
}

/// Renders one project page's **mask** (`mask/`) — the glyph-level greyscale
/// record of which pixels the eraser removed (S-N3).
///
/// ## Why this is not `renderInpaintedPage`'s by-product
///
/// [renderInpaintedPage] *consumes* each region's mask (fills it and throws it
/// away). That is why `mask/` stayed an empty directory for the whole of S9:
/// nothing in the codebase ever wrote a file there, while
/// `displayPath` lists it as a legitimate page source. The erase path had the
/// data and dropped it on the floor.
///
/// ## Polarity: 255 = erased
///
/// Not a free choice. `patch_match.py` feeds the mask straight to `PM_inpaint`
/// as "holes to fill", and `drawing_commands.py` tests `mask > 0` to mean "this
/// area was erased". A mask with the opposite polarity would be accepted by
/// every reader and repair exactly the wrong pixels.
///
/// ## 🔴 Written as a **greyscale** PNG, deliberately not via `dart:ui`
///
/// `ui.Image.toByteData` needs an image, and images come from
/// `Picture.toImage`, which throws without a rendering surface (A01 §3). That
/// would leave this function permanently unverifiable in this environment.
/// `GrayPng` is pure Dart (`dart:io` zlib + a hand-rolled CRC32), so the
/// output is checkable headless — and checkable output is what makes this count
/// as done rather than written.
///
/// Same size contract as [renderInpaintedPage]: a page that needs downscaling
/// produces nothing, because a mask at the wrong resolution silently misaligns
/// against the full-resolution boxes every other stage assumes.
Future<Uint8List?> renderMaskPage(
  TranslationProject project,
  String pageKey,
) async {
  final page = project.pages[pageKey];
  if (page == null) return null;
  final regions = page.regions;
  if (regions.isEmpty) return null;
  final source = File(inpaintedBaseSourcePath(project, pageKey));
  if (!source.existsSync()) return null;
  final bytes = await source.readAsBytes();
  if (bytes.isEmpty) return null;

  final decoded = await _decodeBounded(bytes);
  // Same reason as `renderInpaintedPage`: a downscaled mask would no longer
  // line up with the source-resolution boxes.
  if (!canProduceInpaintedBase(
    decodedWidth: decoded.image.width,
    originalWidth: decoded.originalWidth,
  )) {
    return null;
  }
  final scale = decoded.image.width / decoded.originalWidth;

  final eraseRects = <IntRect>[
    for (final region in regions)
      for (final rect in region.eraseRects)
        IntRect(
          (rect.left * scale).round(),
          (rect.top * scale).round(),
          (rect.right * scale).round(),
          (rect.bottom * scale).round(),
        ),
  ];
  if (eraseRects.isEmpty) return null;

  final mask = buildMaskPage(decoded.image, eraseRects);
  // All-zero would be a *valid* greyscale image and a useless artifact: FT
  // treats an existing mask as authoritative, so writing an empty one would
  // replace "nothing produced yet" with "nothing to erase" — two states that
  // look identical downstream but mean opposite things. Report skipped instead.
  if (mask.isEmpty) return null;
  return mask.encode();
}

/// Rescales a [RegionFontStyle]'s **pixel** fields, leaving dimensionless ones.
///
/// Font size and the stroke/shadow radii are in source pixels; opacity, weight,
/// alignment and the angles are not. Copying the style verbatim would make
/// lettering 1/scale times too large or too small relative to the box it was
/// scaled into — visible as text overflowing a shrunken box.
RegionFontStyle? _scaledFontStyle(RegionFontStyle? style, double scale) {
  if (style == null || scale == 1.0) return style;
  return RegionFontStyle(
    fontFamily: style.fontFamily,
    fontSize: style.fontSize == null ? null : style.fontSize! * scale,
    fontWeight: style.fontWeight,
    italic: style.italic,
    underline: style.underline,
    lineSpacing: style.lineSpacing,
    letterSpacing: style.letterSpacing,
    alignment: style.alignment,
    vertical: style.vertical,
    opacity: style.opacity,
    strokeColor: style.strokeColor,
    strokeWidth: style.strokeWidth * scale,
    shadowColor: style.shadowColor,
    shadowRadius: style.shadowRadius * scale,
    shadowStrength: style.shadowStrength,
    shadowOffsetX: style.shadowOffsetX * scale,
    shadowOffsetY: style.shadowOffsetY * scale,
    gradientEnabled: style.gradientEnabled,
    gradientStartColor: style.gradientStartColor,
    gradientEndColor: style.gradientEndColor,
    gradientAngle: style.gradientAngle,
    angle: style.angle,
    glyphSlantAngle: style.glyphSlantAngle,
  );
}

class _Decoded {
  _Decoded(this.image, this.originalWidth);

  final RgbaImage image;

  /// Width of the undecoded source, needed to scale the project's
  /// original-resolution boxes down to the working image.
  final int originalWidth;
}

/// Decodes [file] to raw RGBA pixels, refusing pages the decode budget would
/// have downscaled.
///
/// This is the block-level (single-block repair / restore) entry to the same
/// decode + coordinate contract the page-level renderers enforce privately
/// (`canProduceInpaintedBase`): block `xyxy` boxes are source pixels, so a
/// scaled-down working image would silently misalign every mask. Returns null
/// for a missing/empty file or an oversized page the callers must skip the
/// same way [renderInpaintedPage] does.
Future<RgbaImage?> decodeFullResolutionRgba(File file) async {
  if (!file.existsSync()) return null;
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) return null;
  final decoded = await _decodeBounded(bytes);
  if (!canProduceInpaintedBase(
    decodedWidth: decoded.image.width,
    originalWidth: decoded.originalWidth,
  )) {
    return null;
  }
  return decoded.image;
}

/// Decodes a greyscale `mask/` PNG into `(width, height, grey)` where `grey`
/// is one byte per pixel (255 = erased). RGB(A) channels are identical for a
/// greyscale PNG, so the red channel is enough.
///
/// Returns null when the file is missing/empty/undecodable. This deliberately
/// uses `dart:ui` (not [GrayPng], which is encode-only by design): the app
/// side already depends on `dart:ui`, and the pure-Dart pixel *logic* stays in
/// `mask_producer.dart` / `block_artifacts.dart`, where headless checks can
/// reach it without a surface.
Future<({int width, int height, Uint8List grey})?> decodeGreyscaleMask(
  File file,
) async {
  if (!file.existsSync()) return null;
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) return null;
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final rgba = data.buffer.asUint8List();
    final n = image.width * image.height;
    final grey = Uint8List(n);
    for (var i = 0; i < n; i++) {
      grey[i] = rgba[i * 4];
    }
    return (width: image.width, height: image.height, grey: grey);
  } finally {
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

/// Decodes [bytes] with a bounded working size, mirroring
/// `BtProjectManager._decodeBounded` so a studio save costs the same memory as
/// the reader's own render (≤12 MP, ≤8000 px on a side).
Future<_Decoded> _decodeBounded(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  const maxPixels = 12 * 1024 * 1024;
  const maxDimension = 8000;
  final w = descriptor.width;
  final h = descriptor.height;
  var scale = 1.0;
  if (w * h > maxPixels) {
    scale = math.sqrt(maxPixels / (w * h));
  }
  if (math.max(w, h) * scale > maxDimension) {
    scale = maxDimension / math.max(w, h);
  }
  int? targetW;
  int? targetH;
  if (scale < 1.0) {
    targetW = math.max(1, (w * scale).round());
    targetH = math.max(1, (h * scale).round());
  }
  final codec = await descriptor.instantiateCodec(
    targetWidth: targetW,
    targetHeight: targetH,
  );
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw Exception('Failed to read image pixels');
    }
    return _Decoded(
      RgbaImage(image.width, image.height, data.buffer.asUint8List()),
      w,
    );
  } finally {
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}
