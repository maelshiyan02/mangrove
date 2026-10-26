import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:mangrove/foundation/bundled_fonts.dart';
import 'package:mangrove/foundation/image_translation/font_fit.dart';
import 'package:mangrove/foundation/log.dart';

import 'block_resize_geometry.dart';

// ── P10.15 序2: 与产出渲染器**同一组**字号常量 ──────────────────────────────
//
// `page_renderer` 的同名常量住在它自己的库里（那条路径刻意不依赖 Flutter
// 之外的东西），所以这里只能各有一份 —— 改动其一必须同步另一份。数值漂移
// 的后果不是报错，而是"预览和成品不一样"，正是
// `font.preview_matches_output` 那条断言在防的静默漂移。

/// Mirrors `page_renderer._minGlyphSize` — the smallest fitted glyph size.
const double _minGlyphSize = 4.0;

/// Mirrors `page_renderer._minLayoutWidth` — the narrowest layout width.
///
/// `TextPainter.width` reports the layout constraint, so the fit test must
/// compare against this rather than the caller's box.
const double _minLayoutWidth = 8.0;

/// **Preview-only** legibility floor, in canvas logical pixels.
///
/// The renderer has its own floor; this one exists so that a box only a few
/// screen pixels wide still shows something rather than a smudge. It is
/// deliberately not mirrored in the renderer.
const double _minCanvasFontSize = 6.0;

/// A decoded page plus the natural size its block coordinates refer to.
///
/// FT stores `xyxy` in the **source image's** resolution, while the canvas may
/// decode a downscaled copy to bound memory. Keeping both lets the painter map
/// coordinates correctly without the caller doing any maths.
class DecodedPage {
  const DecodedPage({
    required this.image,
    required this.originalSize,
    required this.fromInpainted,
  });

  final ui.Image image;

  /// Natural pixel size of the file on disk.
  final Size originalSize;

  /// Whether the bytes came from the text-free `inpainted/` artifact (as
  /// opposed to the original page image). The studio shows this in the status
  /// bar because it decides what the user is looking at.
  final bool fromInpainted;

  double get scaleX => image.width / originalSize.width;

  double get scaleY => image.height / originalSize.height;

  void dispose() => image.dispose();
}

/// Decodes [file] with a bounded working size.
///
/// Mirrors the reader's decode budget so opening a project costs the same per
/// page as reading it; comic pages are frequently 8000px tall and decoding
/// them at full size is what makes a 200-page project feel broken.
Future<DecodedPage?> decodePageFile(
  File file, {
  int maxDimension = 2400,
  bool fromInpainted = false,
}) async {
  // 🔴 文件不存在保持静默：inpainted 缺失→回退原图是正常探测路径
  // （studio_page / studio_preview 都会先试 inpainted），打日志会淹没有效证据。
  if (!file.existsSync()) return null;
  final Uint8List bytes;
  try {
    bytes = await file.readAsBytes();
  } catch (e) {
    // P31 取证：长画布深页缺页要区分「读盘失败」与「codec/资源失败」，
    // 吞成裸 null 会让两条路径在日志里无法区分。
    Log.warning('StripDecode', 'read failed: ${file.path}: $e');
    return null;
  }
  if (bytes.isEmpty) {
    Log.warning('StripDecode', 'decode skipped (empty file): ${file.path}');
    return null;
  }
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final original = Size(descriptor.width.toDouble(), descriptor.height.toDouble());
    var scale = 1.0;
    final longest = math.max(original.width, original.height);
    if (longest > maxDimension) scale = maxDimension / longest;
    final targetW = scale < 1.0 ? math.max(1, (original.width * scale).round()) : null;
    final targetH = scale < 1.0 ? math.max(1, (original.height * scale).round()) : null;
    final codec = await descriptor.instantiateCodec(
      targetWidth: targetW,
      targetHeight: targetH,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return DecodedPage(
      image: image,
      originalSize: original,
      fromInpainted: fromInpainted,
    );
  } catch (e) {
    // A truncated or unsupported file must not take the page down; the caller
    // falls back to the original image the same way it falls back when
    // `inpainted/` is missing.
    //
    // 🔴 P31 取证：**原始错误必须留痕**。长画布深页三连 null 到底是文件坏、
    // codec 不认还是内存/资源不足（错误文本会带 codec / allocation 字样），
    // 全靠 logs.txt 这行区分；吞成裸 null 会把"约 15 页后永久缺页"永久变成
    // 猜谜。
    Log.warning('StripDecode', 'codec failed: ${file.path}: $e');
    return null;
  }
}

/// One text block prepared for painting.
///
/// Everything is resolved from FT's json model by the caller so this file stays
/// a pure drawing surface — the studio must not have to re-parse the project
/// while painting.
class CanvasTextBlock {
  const CanvasTextBlock({
    required this.index,
    required this.rect,
    required this.translation,
    required this.sourceText,
    required this.fontFamily,
    required this.fontSize,
    required this.fontWeight,
    required this.alignment,
    required this.vertical,
    required this.foreground,
    required this.hasFormat,
    this.lineHeight = 0,
    this.strokeColor,
    this.strokeWidth = 0,
    this.letterSpacing,
    this.lineSpacing,
    this.opacity = 1.0,
    this.gradientEnabled = false,
    this.gradientStart,
    this.gradientEnd,
    this.gradientAngle = 0,
    this.angle = 0,
    this.ownerPageKey,
    this.groupId,
    this.groupOrdinal = -1,
    this.groupIsLink = false,
    this.picked = false,
    this.polygon,
    this.kind = 'dialogue',
    this.shape = 'rect',
  });

  final int index;

  /// Block box in the **original** page resolution.
  final Rect rect;

  /// P48 · 自由画笔圈出的轮廓（**源像素**顶点，≥3 个才有效）。
  ///
  /// 🔴 存在的意义：多边形块如果只画外接矩形，用户根本看不出自己画的是
  /// 多边形 —— 人工验收的原话就是"多边形画笔还是只能生成矩形框"。凡是
  /// 有轮廓的块，画布以轮廓为主体绘制，矩形退成淡辅助线（手柄仍按外接框
  /// 摆放，因为缩放本来就是轴对齐的）。
  final List<Offset>? polygon;

  /// 块的语义种类：`dialogue` / `onomatopoeia` / `objectText` / `watermark`。
  ///
  /// 🔴 只服务**描边配色**。人工验收的原话："无论是矩形还是多边形的文字块，
  /// 我希望针对文字块的类型使用不同的颜色进行区分，都是黑色容易混淆。"
  /// 水印和对话框长得一样、拟声词和物体文字也长得一样时，一页上十几个块
  /// 谁是谁只能靠点开面板看 —— 配色是唯一不占空间的区分手段。
  final String kind;

  /// 几何形状：`rect`（矩形）或 `ellipse`（圆/椭圆）。
  ///
  /// 🔴 与 [polygon] 的关系：多边形优先 —— 有轮廓就画轮廓（不可缩放），
  /// 没有轮廓时按本字段画椭圆或矩形。椭圆由 [rect] 外接框决定，宽≠高即椭圆，
  /// 因此 8 个缩放手柄天然可用（这正是用户要的"可以上下左右调整高度和宽度"）。
  final String shape;

  /// 是否为椭圆块。
  bool get isEllipse => shape == 'ellipse';

  final String translation;
  final String sourceText;
  final String fontFamily;

  /// Font size in pixels, FT's unit.
  final double fontSize;

  /// FT's `_detected_font_size`: the height the **original lettering** measured,
  /// in source pixels (0 = unknown).
  ///
  /// 🔴 P10.15 序2：it exists so the canvas can cap the fitted size the same way
  /// the product renderer does (`page_renderer._fitFontSize` reads the region's
  /// `lineHeight`, which is exactly this number). Without it the canvas had no
  /// source-scale anchor at all and simply drew `fontSize × fit`, which is how
  /// the preview ended up with lettering twice the size of the exported page.
  final double lineHeight;

  final int fontWeight;
  final int alignment;
  final bool vertical;

  /// Text fill. The bubble background is not painted: the `inpainted/` base
  /// already carries it, so drawing an opaque box would double it up.
  final Color foreground;

  /// False when the block carries no `fontformat` at all (a freshly detected
  /// block), which the property panel reports rather than silently defaulting.
  final bool hasFormat;

  // ── Below: the fields S7's projection dropped ──────────────────────────
  // The studio's first cut flattened a block to the 11 fields above and threw
  // the rest away, so the property panel could only *display* what it had and
  // nothing could be painted faithfully. S8 edits these, so the projection has
  // to carry them. Optional/nullable: a block with no `fontformat` reports
  // `hasFormat == false` and the painter falls back to plain text.

  /// Outline colour; null when the block has no stroke.
  final Color? strokeColor;

  /// Outline width in pixels; 0 means no outline.
  final double strokeWidth;

  /// Extra spacing between glyphs, FT's unit. Null = font default.
  final double? letterSpacing;

  /// Extra spacing between lines. Null = font default.
  final double? lineSpacing;

  /// Text alpha in 0..1.
  final double opacity;

  /// Whether FT's gradient fill is on. The painter uses a plain fill while this
  /// is false, and an approximation of the gradient while it is true — the
  /// exact 9-slice reconstruction belongs to S9's renderer.
  final bool gradientEnabled;
  final Color? gradientStart;
  final Color? gradientEnd;

  /// Gradient direction in degrees, FT's unit.
  final double gradientAngle;

  /// Block rotation in degrees (FT's `angle` key). 🔴 This key exists in every
  /// real FT block but had **no modelling at all**, so a rotated block was
  /// drawn axis-aligned. The property panel reports it; the painter applies it
  /// from S8's editing work.
  final double angle;

  /// 🔴 非 null 表示这是**跨页块的投影片段**：块的真身落在 [ownerPageKey] 那一页
  /// 的 `blocks[index]` 上，本对象只是它在**当前页**上的一段子矩形（`rect` 已是
  /// 页内坐标）。
  ///
  /// 它存在的原因是跨页块只存"顶页"，若 [blocksFor] 不把别的页上的子矩形投影
  /// 过来，下页就**什么都不画** —— 用户看到的正是"文字块只能存在上页"。
  ///
  /// 片段**只能被点选**（选到真身），不能被拖动/缩放：它的 `rect` 是派生视图，
  /// 拖动它改不了 `_span.parts`，只会让上下两页错位。
  final String? ownerPageKey;

  /// B-3：所属组 id；null = 不属于任何组。同组块（含跨页块投影到本页的片段）
  /// 由 painter 画 nest 大框 / link 连线与序号。
  final String? groupId;

  /// 在组内的阅读序下标（0 起）；-1 = 不在组内。
  final int groupOrdinal;

  /// 组形态是否为 link（false 时组为 nest）。只影响装饰画法。
  final bool groupIsLink;

  /// B-3 建组点选进行中：该块已被加入待确认名单（琥珀色高亮）。
  final bool picked;

  bool get hasTranslation => translation.trim().isNotEmpty;

  String get displayText => hasTranslation ? translation : sourceText;

  /// Copy with a replaced [rect] — used by the editable canvas to render a
  /// dragged block at its live position without touching the model.
  CanvasTextBlock copyWith({Rect? rect}) => CanvasTextBlock(
    index: index,
    rect: rect ?? this.rect,
    translation: translation,
    sourceText: sourceText,
    fontFamily: fontFamily,
    fontSize: fontSize,
    fontWeight: fontWeight,
    alignment: alignment,
    vertical: vertical,
    foreground: foreground,
    hasFormat: hasFormat,
    lineHeight: lineHeight,
    strokeColor: strokeColor,
    strokeWidth: strokeWidth,
    letterSpacing: letterSpacing,
    lineSpacing: lineSpacing,
    opacity: opacity,
    gradientEnabled: gradientEnabled,
    gradientStart: gradientStart,
    gradientEnd: gradientEnd,
    gradientAngle: gradientAngle,
    angle: angle,
    ownerPageKey: ownerPageKey,
    groupId: groupId,
    groupOrdinal: groupOrdinal,
    groupIsLink: groupIsLink,
    picked: picked,
    // 🔴 P48 七轮补齐：这三个字段以前**没被复制**，于是"拖块时的实时预览"
    // 会整块退化 —— 多边形块变回外接矩形、类型色掉回默认蓝、椭圆变矩形。
    // 松手后模型没变所以看不出来，但拖拽过程中的画面一直是错的。
    polygon: polygon,
    kind: kind,
    shape: shape,
  );

  /// 🔴 **Value equality, and it exists for one reason: repair cost.**
  ///
  /// The studio rebuilds a page's block list from json on every build
  /// ([`studio_page._blocksFor`]), so the list is a *fresh* object each time.
  /// [PageCanvasPainter.shouldRepaint] used to compare by identity, so every
  /// rebuild — including the ones a decode completion triggers while scrolling —
  /// looked like "the blocks changed" and repainted the whole page. Painting a
  /// page means running the shrink-to-fit loop in [_paintText] for every block:
  /// several `TextPainter.layout()` calls *per block*. With seven pages kept
  /// alive that is thousands of text layouts per scroll frame, which is exactly
  /// the sustained jank reported after roughly ten pages of continuous
  /// scrolling.
  ///
  /// Every field is compared, deliberately: a field left out here is a field
  /// whose change stops repainting the canvas, i.e. a silently stale preview.
  /// The list below is `paint`'s dependency list, not a convenience subset.
  ///
  /// Value equality is only safe because this class is **immutable** and
  /// callers always hand over a freshly projected list: nothing mutates a block
  /// in place, so an "equal" verdict really does mean "nothing to redraw". The
  /// live-drag preview replaces an element rather than editing one, which is
  /// exactly the pattern that keeps this true.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CanvasTextBlock &&
        other.index == index &&
        other.rect == rect &&
        other.translation == translation &&
        other.sourceText == sourceText &&
        other.fontFamily == fontFamily &&
        other.fontSize == fontSize &&
        other.lineHeight == lineHeight &&
        other.fontWeight == fontWeight &&
        other.alignment == alignment &&
        other.vertical == vertical &&
        other.foreground == foreground &&
        other.hasFormat == hasFormat &&
        other.strokeColor == strokeColor &&
        other.strokeWidth == strokeWidth &&
        other.letterSpacing == letterSpacing &&
        other.lineSpacing == lineSpacing &&
        other.opacity == opacity &&
        other.gradientEnabled == gradientEnabled &&
        other.gradientStart == gradientStart &&
        other.gradientEnd == gradientEnd &&
        other.gradientAngle == gradientAngle &&
        other.angle == angle &&
        other.ownerPageKey == ownerPageKey &&
        other.groupId == groupId &&
        other.groupOrdinal == groupOrdinal &&
        other.groupIsLink == groupIsLink &&
        other.picked == picked &&
        // 🔴 P48 七轮：`kind` / `shape` / `polygon` 都必须参与判等。
        // 在此之前它们被漏掉了，于是"把块改成椭圆""换成水印色"这类**纯外观**
        // 修改不会触发重绘 —— 面板值变了、画布还是旧的，只能靠翻页骗一次重绘。
        other.kind == kind &&
        other.shape == shape &&
        _samePolygon(other.polygon, polygon);
  }

  /// [Offset] 列表逐项比较（`polygon` 是可变引用，不能比身份）。
  static bool _samePolygon(List<Offset>? a, List<Offset>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll([
    index,
    rect,
    translation,
    sourceText,
    fontFamily,
    fontSize,
    lineHeight,
    fontWeight,
    alignment,
    vertical,
    foreground,
    hasFormat,
    strokeColor,
    strokeWidth,
    letterSpacing,
    lineSpacing,
    opacity,
    gradientEnabled,
    gradientStart,
    gradientEnd,
    gradientAngle,
    angle,
    ownerPageKey,
    groupId,
    groupOrdinal,
    groupIsLink,
    picked,
    kind,
    shape,
  ]);
}

/// P31：nest 组外框的画布投影（组框本身不落盘，是成员并集的派生视图）。
///
/// [bounds] 是成员矩形的**并集**，单位为页像素，**不含** painter 画大框时
/// 外扩的 8px 视觉边距（缩放数学只认并集；手柄画在外扩框上，命中与绘制共用
/// 同一个 `bounds*fit ± 8` 矩形）。[memberIndices] 是成员在投影块列表中的
/// 下标；只收**本页真身块**（跨页片段与跨页成员不收 —— 整体缩放只支持全部
/// 成员都在当前页的 nest 组，跨页组不出手柄）。
class CanvasGroupFrame {
  const CanvasGroupFrame({
    required this.groupId,
    required this.bounds,
    required this.memberIndices,
  });

  final String groupId;
  final Rect bounds;
  final List<int> memberIndices;
}

/// Index of the topmost block whose box contains [pagePoint], in **page
/// pixels**, or -1.
///
/// Searched back to front because FT stores blocks in detection order, so the
/// last entry is what the user perceives as "the box on top" — the same rule the
/// read-only canvas used inline before the editable canvas needed it too.
int hitTestCanvasBlocks(List<CanvasTextBlock> blocks, Offset pagePoint) {
  for (var i = blocks.length - 1; i >= 0; i--) {
    if (blocks[i].rect.inflate(2).contains(pagePoint)) return i;
  }
  return -1;
}

/// Same as [hitTestCanvasBlocks] but **skips projected cross-page fragments**
/// ([CanvasTextBlock.ownerPageKey] != null).
///
/// 🔴 拖动/缩放必须用这一条：片段的 `rect` 是"真身块在别页上的子矩形"的派生
/// 视图，拖动它既改不了 `_span.parts`（落盘真相），又会让拖动的增量被施加到
/// 真身的 `xyxy` 上 —— 两页随即错位。点选仍走 [hitTestCanvasBlocks]（片段可被
/// 选中，选中后由调用方回指真身）。
int hitTestMovableCanvasBlocks(List<CanvasTextBlock> blocks, Offset pagePoint) {
  for (var i = blocks.length - 1; i >= 0; i--) {
    final block = blocks[i];
    if (block.ownerPageKey != null) continue;
    if (block.rect.inflate(2).contains(pagePoint)) return i;
  }
  return -1;
}

/// Read-only page canvas: the text-free base image plus every block's box and
/// translation painted on top, with tap-to-select for the property panel.
///
/// This is deliberately **not** built on `ReaderImageProvider`. The reader
/// collapses a page into one opaque `Uint8List` and never exposes coordinates;
/// the studio needs `xyxy` to stay addressable, so the page is a layered widget
/// instead (P6 §2.11(b)). Editing gestures arrive in S8 — this widget only
/// selects.
class TextBlockCanvas extends StatelessWidget {
  const TextBlockCanvas({
    super.key,
    required this.blocks,
    required this.selectedIndex,
    required this.onSelect,
    this.base,
    this.originalSize,
    this.loading = false,
    this.showBoxes = true,
  });

  final List<CanvasTextBlock> blocks;

  /// Index into [blocks], or -1 for "no selection".
  final int selectedIndex;

  final ValueChanged<int> onSelect;

  /// Decoded base page; null while loading, on failure, or when the project has
  /// no image for this key.
  final DecodedPage? base;

  /// Natural size of the base file. Defaults to the decoded size.
  final Size? originalSize;

  final bool loading;

  /// Hides the outlines while keeping the text — used by the preview mode.
  final bool showBoxes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (loading) {
      return Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
        ),
      );
    }
    final page = base;
    if (page == null) {
      return Center(
        child: Text(
          'No image for this page',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    final natural = originalSize ?? page.originalSize;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = Size(
          constraints.maxWidth.isFinite ? constraints.maxWidth : natural.width,
          constraints.maxHeight.isFinite ? constraints.maxHeight : natural.height,
        );
        // "Contain" fit: the whole page is always visible, zoom lives in the
        // surrounding InteractiveViewer.
        final fit = math.min(
          available.width / natural.width,
          available.height / natural.height,
        );
        final canvasSize = Size(natural.width * fit, natural.height * fit);
        void select(Offset local) {
          final x = local.dx / fit;
          final y = local.dy / fit;
          // Topmost last: FT stores blocks in detection order, so searching
          // backwards matches what the user perceives as "the box on top".
          onSelect(hitTestCanvasBlocks(blocks, Offset(x, y)));
        }

        return Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => select(details.localPosition),
            child: CustomPaint(
              size: canvasSize,
              painter: PageCanvasPainter(
                page: page,
                natural: natural,
                fit: fit,
                blocks: blocks,
                selectedIndex: selectedIndex,
                showBoxes: showBoxes,
                outline: scheme.outlineVariant,
                selection: scheme.primary,
                untranslated: scheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Paints a page: the base bitmap plus every block's box and lettering.
///
/// Public so the editable canvas ([EditableTextBlockCanvas]) shares one
/// implementation instead of forking the drawing rules — the read-only and
/// editable canvases must not drift apart, which is what P8.0 §三 item 2 asked
/// for when it flagged the shared-canvas merge strategy.
class PageCanvasPainter extends CustomPainter {
  PageCanvasPainter({
    required this.page,
    required this.natural,
    required this.fit,
    required this.blocks,
    required this.selectedIndex,
    required this.showBoxes,
    required this.outline,
    required this.selection,
    required this.untranslated,
    this.showResizeHandles = false,
    this.showGroups = true,
    this.activeGroupFrame,
    this.marquee,
    this.polygon = const [],
    this.snapGuidesX = const [],
    this.snapGuidesY = const [],
  });

  final DecodedPage page;
  final Size natural;
  final double fit;
  final List<CanvasTextBlock> blocks;
  final int selectedIndex;
  final bool showBoxes;
  final Color outline;
  final Color selection;
  final Color untranslated;

  /// 🔴 Draws the eight resize handles on the selected block.
  ///
  /// Off by default so the **read-only** canvas (`StudioPreviewPage`) is
  /// unaffected — handles imply an interaction it cannot honour. Only
  /// [EditableTextBlockCanvas] turns it on.
  final bool showResizeHandles;

  /// B-3：画文字块小组的可视化（nest 并集大框 / link 成员连线 / 序号徽标）。
  /// 预览页（读者侧）默认不展示工作室结构 —— 目前两处工作室画布都让它开着。
  final bool showGroups;

  /// P31：当前可整体缩放的 nest 组外框（页像素并集）。非 null 时在视觉大框
  /// （并集 ±8px）上画 8 个手柄；null = 没有可拖的组外框。
  final CanvasGroupFrame? activeGroupFrame;

  /// Live marquee for "drag out a new box", in **canvas** pixels. Drawn as a
  /// translucent fill plus a dashed border so it reads as "pending" rather than
  /// as a committed block.
  final Rect? marquee;

  /// P48 · Live freehand polygon for "draw a new block", in **canvas** pixels.
  /// Drawn as a translucent fill plus a dashed stroke so it reads as "pending".
  final List<Offset> polygon;

  /// Full-height / full-width guide lines the current drag snapped to, in
  /// **canvas** pixels.
  ///
  /// 🔴 S9 · P9.7: these exist so that snapping is *visible*. Without a guide, a
  /// block that jumps a few pixels on release looks like a bug — and this
  /// project has an explicit rule against changes the user cannot attribute to
  /// their own action. Empty means "no snap", not "snap to 0".
  final List<double> snapGuidesX;
  final List<double> snapGuidesY;

  @override
  void paint(Canvas canvas, Size size) {
    final target = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(
      page.image,
      Rect.fromLTWH(
        0,
        0,
        page.image.width.toDouble(),
        page.image.height.toDouble(),
      ),
      target,
      Paint()..filterQuality = FilterQuality.medium,
    );

    // B-3：组装饰（nest 大框 / link 连线）必须画在**块框之下**：成员自己的
    // 选中框、白晕黑框是更精细的信息，不能被组色盖住。
    if (showGroups) _paintGroupOverlays(canvas);

    for (final block in blocks) {
      final rect = Rect.fromLTRB(
        block.rect.left * fit,
        block.rect.top * fit,
        block.rect.right * fit,
        block.rect.bottom * fit,
      );
      if (!rect.isFinite || rect.isEmpty) continue;
      final selected = block.index == selectedIndex;
      // B-3 建组点选的待确认高亮（琥珀色），优先于普通框样式。
      if (block.picked) {
        canvas.drawRect(
          rect,
          Paint()..color = const Color(0xFFFFB300).withValues(alpha: 0.18),
        );
        _paintDashedRect(
          canvas,
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0
            ..color = const Color(0xFFFFB300),
        );
      }
      // P48 · 自由画笔块：先画轮廓。轮廓在就是"这块的形状"，矩形只是外接框。
      final polyPath = _polygonPath(block);
      // P48 七轮 · 第三种形状：椭圆/圆。有多边形时多边形优先（轮廓就是形状，
      // 且不可缩放）；没有轮廓时按外接框画椭圆，宽≠高即椭圆。
      final ellipse = polyPath == null && block.isEllipse;
      if (polyPath != null) {
        _paintPolygon(canvas, polyPath, block, selected);
      } else if (ellipse) {
        if (showBoxes || selected || block.picked) {
          _paintEllipse(canvas, rect, block, selected);
        }
      }
      if ((showBoxes || selected) && polyPath == null && !ellipse) {
        if (selected) {
          // 选中 = 同色加粗 + 更宽白晕。颜色仍按**类型**走，只靠粗细表达
          // "选中"：换成统一的青色会让"这块是水印还是对话框"重新变得不可辨。
          final kindColor = _kindColor(block.kind);
          canvas.drawRect(
            rect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 4.4
              ..color = const Color(0xFFFFFFFF),
          );
          canvas.drawRect(
            rect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.4
              ..color = kindColor,
          );
        } else if (showGroups && block.groupId != null) {
          // P32：组成员块用**本组配色**描边（同组同色，与 nest 大框 / link
          // 连线 / 序号徽标同一颜色），与普通块的黑框一眼区分。仍保留一圈细
          // 白晕 —— 组色板多为中明度色，直接描在深墨块上会发糊；白晕保证任
          // 意底色可见（与普通块黑框白晕同一条可读性纪律）。
          final groupColor = _groupColor(block.groupId!);
          canvas.drawRect(
            rect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.6
              ..color = const Color(0xFFFFFFFF),
          );
          canvas.drawRect(
            rect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.6
              ..color = groupColor,
          );
        } else {
          // 🔴 非选中框 = **类型色 + 白晕**（用户反馈："白边很不明显，视觉上
          // 容易隐形"，以及"都是黑色容易混淆"）。先在框上描一条更粗的白线，
          // 再叠一条更细的类型色线：白线在框两侧各露出约 1px，于是描边在深色
          // 墨块和浅色气泡上都稳定可见，而颜色本身负责区分块类型。
          canvas.drawRect(
            rect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3.0
              ..color = const Color(0xFFFFFFFF),
          );
          canvas.drawRect(
            rect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2
              ..color = _kindColor(block.kind),
          );
        }
      }
      _paintText(canvas, block, ellipse ? _inscribedRect(rect) : rect, selected,
          boxScale: ellipse ? _ellipseInset : 1.0);
      // 🔴 Handles are drawn from `paint` rather than inside `_paintText`: that
      // method returns early for empty text, so a freshly created (still empty)
      // block would have shown no handles at all — precisely the block the user
      // most needs to resize.
      //
      // 🔴 多边形块**不画**缩放手柄：用户画的就是最终形状，8 个角/边手柄拖
      // 动只会让"轮廓"和"外接框"变成两套互相矛盾的尺寸（人工验收原话：
      // "多边形是不需要再多一层外面的矩形框的，因为无法改变大小和形状，
      // 我们创造的是不规则形状"）。整块拖动移动仍然有效。
      //
      // 🔴 椭圆块**要**手柄：用户明确要求"圆形文字块是需要外围再有一圈矩形框
      // 用于大小调节的"，所以它的外接框（虚线）既是提示也是缩放入口。
      if (selected && showResizeHandles && polyPath == null) {
        _paintHandles(canvas, rect);
      }
      // B-3：成员序号徽标（阅读序 1 起）。nest/link 共用 —— 断句分配/倒装重排
      // 时用户靠它把面板里的成员和画布上的块一一对上。
      if (showGroups && block.groupOrdinal >= 0) {
        _paintOrdinalBadge(canvas, block, rect);
      }
    }

    // P31：nest 组外框的 8 个手柄画在所有块**之上**（组框是当前最高层级的
    // 操作对象）。锚点 = 视觉大框（并集外扩 8px），与 [_paintGroupOverlays]
    // 的 nest rrect 严格同框 —— 整体缩放的 live preview 里成员块已被替换为
    // 新矩形，调用方传入的 [activeGroupFrame].bounds 也是同步算好的新并集，
    // 于是大框、成员、手柄三者不会各走各的。
    final groupFrame = activeGroupFrame;
    if (groupFrame != null && showResizeHandles) {
      final f = groupFrame.bounds;
      final frameRect = Rect.fromLTRB(
        f.left * fit - 8,
        f.top * fit - 8,
        f.right * fit + 8,
        f.bottom * fit + 8,
      );
      if (frameRect.isFinite) _paintHandles(canvas, frameRect);
    }

    final box = marquee;
    if (box != null && box.isFinite && !box.isEmpty) {
      canvas.drawRect(box, Paint()..color = selection.withValues(alpha: 0.12));
      _paintDashedRect(
        canvas,
        box,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = selection,
      );
    }

    // P48 · 自由多边形预览：封闭填充 + 虚线描边，顶点用圆点提示。
    if (polygon.length >= 2) {
      final path = Path()..moveTo(polygon.first.dx, polygon.first.dy);
      for (final p in polygon.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.fill
          ..color = selection.withValues(alpha: 0.12),
      );
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = selection;
      for (var i = 0; i < polygon.length; i++) {
        final a = polygon[i];
        final b = polygon[(i + 1) % polygon.length];
        _paintDashedLine(canvas, a, b, stroke);
      }
      for (final p in polygon) {
        canvas.drawCircle(p, 2.5, Paint()..color = selection);
      }
    }

    // Snap guides last so they sit on top of every block. Drawn edge-to-edge
    // (not just across the block) because the question they answer is "which
    // other block's edge am I on?", and that edge can be far away.
    final guide = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = selection.withValues(alpha: 0.9);
    for (final x in snapGuidesX) {
      if (!x.isFinite) continue;
      _paintDashedLine(canvas, Offset(x, 0), Offset(x, size.height), guide);
    }
    for (final y in snapGuidesY) {
      if (!y.isFinite) continue;
      _paintDashedLine(canvas, Offset(0, y), Offset(size.width, y), guide);
    }
  }

  /// B-3 组可视化。每页只画**本页可见成员**（跨页组在另一页由该页的投影片段
  /// 续画同色装饰）：nest = 成员并集大框；link = 按阅读序连接成员中心。
  void _paintGroupOverlays(Canvas canvas) {
    // groupId → 该组在本页上的成员（保持 blocks 出现顺序，序号另算）。
    final byGroup = <String, List<CanvasTextBlock>>{};
    for (final block in blocks) {
      final id = block.groupId;
      if (id == null) continue;
      byGroup.putIfAbsent(id, () => <CanvasTextBlock>[]).add(block);
    }
    byGroup.forEach((id, members) {
      final color = _groupColor(id);
      final rects = [
        for (final b in members)
          Rect.fromLTRB(
            b.rect.left * fit,
            b.rect.top * fit,
            b.rect.right * fit,
            b.rect.bottom * fit,
          ),
      ]..removeWhere((r) => !r.isFinite || r.isEmpty);
      if (rects.isEmpty) return;
      final isLink = members.first.groupIsLink;
      if (isLink) {
        // 连线：成员中心按序号排序后依次连接。
        final ordered = [...members]..sort(
            (a, b) => a.groupOrdinal.compareTo(b.groupOrdinal),
          );
        final centers = <Offset>[
          for (final b in ordered)
            Offset(
              (b.rect.left + b.rect.right) * 0.5 * fit,
              (b.rect.top + b.rect.bottom) * 0.5 * fit,
            ),
        ];
        final line = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: 0.85);
        for (var i = 0; i < centers.length - 1; i++) {
          canvas.drawLine(centers[i], centers[i + 1], line);
        }
        final dot = Paint()..color = color;
        for (final center in centers) {
          canvas.drawCircle(center, 4.5, dot);
        }
      } else {
        // nest：成员并集外扩的圆角大框。
        var left = rects.first.left;
        var top = rects.first.top;
        var right = rects.first.right;
        var bottom = rects.first.bottom;
        for (final r in rects.skip(1)) {
          if (r.left < left) left = r.left;
          if (r.top < top) top = r.top;
          if (r.right > right) right = r.right;
          if (r.bottom > bottom) bottom = r.bottom;
        }
        final rrect = RRect.fromRectAndRadius(
          Rect.fromLTRB(left - 8, top - 8, right + 8, bottom + 8),
          const Radius.circular(12),
        );
        canvas.drawRRect(
          rrect,
          Paint()..color = color.withValues(alpha: 0.07),
        );
        canvas.drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5
            ..color = color.withValues(alpha: 0.90),
        );
      }
    });
  }

  /// 组色板：由组 id 哈希取色。同一组在**每一页**上都得到同一个颜色（同 id
  /// 同哈希），跨页组的 nest/link 装饰因此能被肉眼接上。
  static Color _groupColor(String groupId) {
    const palette = <Color>[
      Color(0xFF7E57C2), // 紫
      Color(0xFF26A69A), // 青
      Color(0xFFEC407A), // 粉
      Color(0xFFEF6C00), // 橙
      Color(0xFF5C6BC0), // 靛蓝
      Color(0xFF66BB6A), // 绿
      Color(0xFFAB47BC), // 品红
      Color(0xFF42A5F5), // 蓝
    ];
    return palette[groupId.hashCode.abs() % palette.length];
  }

  /// 块类型 → 描边色。人工验收："针对文字块的类型使用不同的颜色进行区分，
  /// 都是黑色容易混淆。"
  ///
  /// 🔴 选色约束：必须同时压在**深墨块**和**浅气泡/白底**上都可辨（外面还有
  /// 一圈白晕兜底），所以一律取中深饱和色，不用浅粉/浅黄这类会隐形的色。
  /// 组配色（[_groupColor]）优先于类型色 —— 组是用户临时建立的更强分组。
  static Color _kindColor(String kind) => switch (kind) {
    'watermark' => const Color(0xFF6A1B9A), // 紫：水印
    'onomatopoeia' => const Color(0xFFE65100), // 橙：拟声词
    'objectText' => const Color(0xFF2E7D32), // 绿：物体上的文字
    _ => const Color(0xFF1565C0), // 蓝：对话气泡（默认）
  };

  /// 成员序号徽标：块框左上角的组色圆点 + 白色序号。
  void _paintOrdinalBadge(
    Canvas canvas,
    CanvasTextBlock block,
    Rect rect,
  ) {
    final color = _groupColor(block.groupId!);
    const radius = 9.0;
    final center = Offset(
      rect.left + radius + 2,
      rect.top + radius + 2,
    );
    final badge = Paint()..color = color;
    canvas.drawCircle(center, radius, badge);
    final painter = TextPainter(
      text: TextSpan(
        text: '${block.groupOrdinal + 1}',
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  /// P48 · 把块的自由画笔轮廓转成画布坐标路径（源像素 × fit）。
  ///
  /// 顶点少于 3 个、或坐标非法时返回 null —— 调用方退回矩形绘制，绝不
  /// 画一个空路径（那会让块"看起来消失了"）。
  Path? _polygonPath(CanvasTextBlock block) {
    final poly = block.polygon;
    if (poly == null || poly.length < 3) return null;
    final path = Path();
    var started = false;
    for (final p in poly) {
      if (!p.dx.isFinite || !p.dy.isFinite) return null;
      final x = p.dx * fit;
      final y = p.dy * fit;
      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
    }
    if (!started) return null;
    path.close();
    return path;
  }

  /// 画自由画笔块：半透明填充 + 白晕描边 + （选中且顶点不多时）顶点圆点。
  ///
  /// 🔴 **不画外接矩形，也不画缩放手柄**。人工验收原话："针对多边形是不需要
  /// 再多一层外面的矩形框的，因为这些多边形无法改变大小和形状，准确的说
  /// 我们创造的是不规则形状。" 之前那圈淡虚线 + 8 个手柄，既让用户以为
  /// 多边形还能拉成矩形，又在 40+ 顶点时和顶点圆点叠成一片噪点。
  void _paintPolygon(
    Canvas canvas,
    Path path,
    CanvasTextBlock block,
    bool selected,
  ) {
    final kindColor = _kindColor(block.kind);
    final tint = block.picked ? const Color(0xFFFFB300) : kindColor;
    if (selected || block.picked) {
      canvas.drawPath(
        path,
        Paint()..color = tint.withValues(alpha: 0.16),
      );
    }
    // 白晕 + 类型色双层（矩形框同一条可读性纪律）。选中只靠**更粗**表达，
    // 颜色始终属于类型 —— 手柄和虚线框取消后，粗细是唯一的选中信号。
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 4.4 : 3.2
        ..color = const Color(0xFFFFFFFF),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 2.4 : 1.6
        ..color = tint,
    );
    if (!selected) return;
    // 顶点圆点只对"手绘量级"（≤16 顶点）显示。画笔抽稀后常留 40+ 个顶点，
    // 全画出来是一圈密集小点，既看不清形状、也盖住轮廓线本身。
    final poly = block.polygon!;
    if (poly.length > 16) return;
    final dot = Paint()..color = tint;
    final halo = Paint()..color = const Color(0xFFFFFFFF);
    for (final p in poly) {
      final c = Offset(p.dx * fit, p.dy * fit);
      canvas.drawCircle(c, 3.4, halo);
      canvas.drawCircle(c, 2.0, dot);
    }
  }

  /// 椭圆块的内接矩形比例：`1/√2 ≈ 0.7071`。
  ///
  /// 🔴 椭圆里能放下的**最大面积矩形**就是宽高各乘 1/√2。文字若不收进这个
  /// 内接矩形，长句会顶到椭圆边缘之外 —— 视觉上像是"字跑到气泡外面去了"，
  /// 而它其实只是按外接框排的版。
  static const double _ellipseInset = 0.7071067811865476;

  static Rect _inscribedRect(Rect rect) => Rect.fromCenter(
    center: rect.center,
    width: rect.width * _ellipseInset,
    height: rect.height * _ellipseInset,
  );

  /// 画椭圆块（第三种形状）。
  ///
  /// 描边纪律与矩形/多边形完全一致：白晕 + 类型色双层，选中只靠**更粗**表达
  /// （颜色始终属于块类型，不能因为选中就变青，否则"这是水印还是对话框"又
  /// 重新变得不可辨）。
  ///
  /// 🔴 选中时额外画一圈**虚线外接矩形** —— 这是用户明确要求的区分手段：
  /// "相比于矩形文字块，圆形文字块外围的这圈矩形框应该用虚线表示，这些可以
  /// 更好的区分。" 它同时是"这块能拖大小"的可见承诺（8 个手柄就摆在这条
  /// 虚线上）。未选中时不画：一页十几个椭圆块都挂虚线框会变成噪声。
  void _paintEllipse(
    Canvas canvas,
    Rect rect,
    CanvasTextBlock block,
    bool selected,
  ) {
    if (!rect.isFinite || rect.isEmpty) return;
    final kindColor = _kindColor(block.kind);
    final tint = block.picked ? const Color(0xFFFFB300) : kindColor;
    if (selected || block.picked) {
      canvas.drawOval(rect, Paint()..color = tint.withValues(alpha: 0.16));
    }
    canvas.drawOval(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 4.4 : 3.2
        ..color = const Color(0xFFFFFFFF),
    );
    canvas.drawOval(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 2.4 : 1.6
        ..color = tint,
    );
    if (!selected) return;
    _paintDashedRect(
      canvas,
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0
        ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.85),
    );
    _paintDashedRect(
      canvas,
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = tint,
    );
  }

  /// Eight square handles: four corners plus four edge midpoints.
  void _paintHandles(Canvas canvas, Rect rect) {
    final fill = Paint()..color = selection;
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xFFFFFFFF);
    for (final handle in resizeHandles) {
      final center = resizeHandleBox(rect, handle).center;
      final square = Rect.fromCenter(
        center: center,
        width: resizeHandleDrawSize,
        height: resizeHandleDrawSize,
      );
      canvas.drawRect(square, fill);
      // The white keyline is what keeps a handle visible on a dark bubble or a
      // black border — without it a primary-coloured square on a dark image
      // disappears.
      canvas.drawRect(square, border);
    }
  }

  /// Dashed 1px border, marching-ants style: each dash is drawn separately so
  /// the stroke width and colour match the rest of the studio's lines.
  void _paintDashedRect(Canvas canvas, Rect rect, Paint paint) {
    _paintDashedLine(canvas, rect.topLeft, rect.topRight, paint);
    _paintDashedLine(canvas, rect.topRight, rect.bottomRight, paint);
    _paintDashedLine(canvas, rect.bottomRight, rect.bottomLeft, paint);
    _paintDashedLine(canvas, rect.bottomLeft, rect.topLeft, paint);
  }

  /// One dashed segment — the snap-guide primitive. Shares the dash geometry
  /// with [_paintDashedRect] so a guide and a marquee border read as the same
  /// kind of mark.
  void _paintDashedLine(Canvas canvas, Offset from, Offset to, Paint paint) {
    const dash = 6.0;
    const gap = 4.0;
    final total = (to - from).distance;
    if (total <= 0) return;
    final dir = (to - from) / total;
    var travelled = 0.0;
    while (travelled < total) {
      final end = math.min(travelled + dash, total);
      canvas.drawLine(from + dir * travelled, from + dir * end, paint);
      travelled = end + gap;
    }
  }

  void _paintText(
    Canvas canvas,
    CanvasTextBlock block,
    Rect rect,
    bool selected, {
    double boxScale = 1.0,
  }) {
    final text = block.displayText;
    if (text.isEmpty) return;
    // P33：默认值与 result 出图统一（原来是 1.15，成品侧是 1.2）。
    final lineHeight = lineSpacingOf(block.lineSpacing);
    final base = block.hasTranslation ? block.foreground : untranslated;
    final alpha = block.opacity.clamp(0.0, 1.0).toDouble();
    final fill = base.withValues(alpha: base.a * alpha);
    // 🔴 P32：对齐码与 result 出图（page_renderer._horizontalPainter）严格
    // 同一份映射 —— 0=left / 2=right / 其余（含 FT 默认 center=1）居中。
    // 旧映射把 1 当 center、把**默认**当 left，而 FontFormat 默认恰是 center，
    // 导致没动过对齐设置的块在预览里全部顶左，与出图不一致。
    final textAlign = switch (block.alignment) {
      0 => TextAlign.left,
      2 => TextAlign.right,
      _ => TextAlign.center,
    };

    TextStyle styleFor(double size, {Paint? foreground}) => TextStyle(
      // 🔴 P1-4: go through [resolveFamily] exactly like the product renderer
      // (`page_renderer._fillStyle`). Passing the raw value made the canvas
      // preview disagree with the exported page for every project whose
      // `font_family` is FT's own default ("Microsoft YaHei UI", not bundled):
      // the canvas asked for a face that does not exist and Flutter substituted
      // whatever the platform had, while the renderer used the bundled one.
      // P9.4 §6 already warned that the two render paths share no code, so a
      // fix on one side has to be made on the other deliberately.
      fontFamily: resolveFamily(block.fontFamily).family,
      // 🔴 P9.7: same chain as the product renderer (`page_renderer
      // ._fillStyle`). The two paths share no code, so a fix on one side has to
      // be made on the other deliberately — otherwise the preview and the
      // exported page disagree for Korean/Hanja text, which is precisely the
      // class of silent drift `font.preview_matches_output` guards.
      fontFamilyFallback: bundledFamilyFallbacks(block.fontFamily),
      fontSize: size,
      fontWeight: _weight(block.fontWeight),
      color: foreground == null ? fill : null,
      foreground: foreground,
      height: lineHeight,
      // FT's `letter_spacing` is a multiplier on the font's natural spacing, not
      // a pixel count, so it is converted to logical pixels at this font size.
      // P33：换算规则搬到 [letterSpacingPx]，与 result 出图共用（原来成品侧
      // 漏乘字号，字距在出图上形同虚设）。
      letterSpacing: letterSpacingPx(block.letterSpacing, size),
    );

    TextPainter build(
      double size,
      TextStyle textStyle, {
      required double maxWidth,
    }) =>
        TextPainter(
          text: TextSpan(text: text, style: textStyle),
          textDirection: TextDirection.ltr,
          textAlign: textAlign,
        )..layout(maxWidth: math.max(_minLayoutWidth, maxWidth));

    // 🔴 P10.15 序2: the size is fitted by **the same rule the product renderer
    // uses** (`page_renderer._fitFontSize`), and the fit runs in **source
    // pixels** (`block.rect`) so the absolute cap (42) and floor (4) mean the
    // same thing on both sides. It used to be `block.fontSize * fit` — an
    // unbounded size — which drew lettering larger than its box and then hid the
    // overflow behind a single-line `…` (the "…" in the S9.5-a screenshot was
    // the canvas's own ellipsis, not the translation).
    final fitted = _fitFontSize(
      text: text,
      // 🔴 椭圆块要按**内接矩形**量尺寸（[boxScale] < 1），否则字号是按外接框
      // 算的，字会超出椭圆边界。源像素与画布两侧同乘这个系数，字号判据与
      // 出图规则保持同一套。
      boxWidth: block.rect.width * boxScale,
      boxHeight: block.rect.height * boxScale,
      lineHeight: block.lineHeight,
      maxFontSize: block.hasFormat && block.fontSize > 0 ? block.fontSize : null,
      build: build,
      styleFor: styleFor,
    );
    // Back to canvas pixels for drawing. The floor is a preview-only
    // legibility affordance and is deliberately **not** mirrored in the
    // renderer, which has its own floor.
    final fontSize = math.max(_minCanvasFontSize, fitted * fit);

    final stroke = block.strokeColor;
    TextPainter? outline;
    if (stroke != null && block.strokeWidth > 0) {
      outline = build(
        fontSize,
        styleFor(
          fontSize,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = block.strokeWidth * fit
            ..strokeJoin = StrokeJoin.round
            ..color = stroke.withValues(alpha: stroke.a * alpha),
        ),
        maxWidth: rect.width,
      );
    }
    final painter = build(fontSize, styleFor(fontSize), maxWidth: rect.width);

    // P32：块内文字像单元格一样**上下左右居中**（旧实现从块左上角起排，框
    // 大于文字时像"首行缩进顶格"）。偏移规则与 result 出图共用
    // [placeTextInBox]：垂直恒居中，水平按对齐码（默认 center）。
    final placed = placeTextInBox(
      boxWidth: rect.width,
      boxHeight: rect.height,
      textWidth: painter.width,
      textHeight: painter.height,
      alignment: block.alignment,
    );
    final textOrigin = rect.topLeft + Offset(placed.dx, placed.dy);

    canvas.save();
    // `angle` is FT's per-block rotation. A rotated block used to be drawn
    // axis-aligned because the model had no accessor for the key at all.
    if (block.angle != 0) {
      final center = rect.center;
      canvas.translate(center.dx, center.dy);
      canvas.rotate(block.angle * math.pi / 180.0);
      canvas.translate(-center.dx, -center.dy);
    }
    if (block.vertical) {
      // Vertical Japanese text: drawn rotated as a viewing aid. Exact per-glyph
      // vertical layout (FT's `vertical` + `line_spacing_type`) is S9's job.
      //
      // P32：π/2 旋转后绘画空间的 x 轴对应画布 −y、y 轴对应画布 +x，故把
      // painter 盒子在旋转空间里平移到 ((块高−文宽)/2, (块宽−文高)/2)，整块
      // 文字的几何中心恰好落在块中心 —— 与出图竖排的双向居中同一语义。
      canvas.translate(rect.right, rect.top);
      canvas.rotate(math.pi / 2);
      final vOrigin = Offset(
        (rect.height - painter.width) / 2,
        (rect.width - painter.height) / 2,
      );
      outline?.paint(canvas, vOrigin);
      painter.paint(canvas, vOrigin);
    } else {
      outline?.paint(canvas, textOrigin);
      painter.paint(canvas, textOrigin);
    }
    canvas.restore();
    // The old "four filled circles on the corners" marker used to live here.
    // It is replaced by [PageCanvasPainter._paintHandles], which draws eight
    // square handles and — unlike this marker — is not skipped when the block
    // has no text yet (this method returns early for empty text, which is
    // exactly the state of a block the user just created).
  }

  /// Largest font size whose wrapped layout fits a `boxWidth × boxHeight` box.
  ///
  /// 🔴 **A deliberate mirror of `page_renderer._fitFontSize`** — the two render
  /// paths share no code (the renderer is `dart:ui`-only on purpose), so the rule
  /// has to be kept in step by hand. That is the same discipline
  /// `font.preview_matches_output` exists to guard: preview and product must
  /// agree, and nothing at runtime compares them.
  ///
  /// The cap is whatever `font_fit.dart` says: **once the user asks for a size
  /// it wins** (`maxFontSize`), and only an untouched block falls back to the
  /// measured lettering (`lineHeight`, FT's `_detected_font_size`) or the hard
  /// default. It is a **cap, never a floor**: the shrink-to-fit loop below must
  /// still be able to go smaller, or a 40px request inside a 20px box would
  /// overflow the bubble.
  ///
  /// 🔴 The rule is **shared code** (`fitFontSizeCap`), not a hand-copied mirror
  /// any more: the two render paths still lay text out separately (this one has
  /// Flutter, the renderer is `dart:ui`-only), but the cap number itself now has
  /// exactly one definition. Before, it was `min(42, lineHeight*0.9, maxFontSize)`
  /// in **both** files, and the user's slider did nothing on either side.
  static double _fitFontSize({
    required String text,
    required double boxWidth,
    required double boxHeight,
    required double lineHeight,
    required double? maxFontSize,
    required TextPainter Function(
      double size,
      TextStyle style, {
      required double maxWidth,
    })
    build,
    required TextStyle Function(double size, {Paint? foreground}) styleFor,
  }) {
    final cap = fitFontSizeCap(requested: maxFontSize, measured: lineHeight);
    final upper = math.max(10.0, math.min(cap, boxHeight * 0.8));
    final layoutWidth = math.max(_minLayoutWidth, boxWidth);
    var size = upper;
    while (size > _minGlyphSize) {
      final painter = build(size, styleFor(size), maxWidth: boxWidth);
      final fits = painter.height <= boxHeight && painter.width <= layoutWidth;
      painter.dispose();
      if (fits) return size;
      size *= 0.8;
    }
    return _minGlyphSize;
  }

  /// P33：字重表搬到 `font_fit.fontWeightIndex`，与 result 出图共用同一张
  /// （原来两份逐行相同的 switch 分躺两边，改一处要记得改另一处）。
  static FontWeight _weight(int value) => FontWeight(fontWeightIndex(value));

  @override
  bool shouldRepaint(PageCanvasPainter old) =>
      old.page != page ||
      old.fit != fit ||
      old.selectedIndex != selectedIndex ||
      old.showBoxes != showBoxes ||
      // 🔴 **By value, not by identity.** The caller projects blocks out of the
      // json model on every build, so a fresh list always arrives and an
      // identity test only ever says "changed" — see [CanvasTextBlock.==] for
      // what that cost while scrolling.
      !_sameBlocks(old.blocks, blocks) ||
      old.activeGroupFrame?.groupId != activeGroupFrame?.groupId ||
      old.activeGroupFrame?.bounds != activeGroupFrame?.bounds ||
      old.marquee != marquee ||
      !_sameOffsets(old.polygon, polygon) ||
      !_sameDoubles(old.snapGuidesX, snapGuidesX) ||
      !_sameDoubles(old.snapGuidesY, snapGuidesY);

  /// Element-wise compare. `identical` is checked first because the studio's
  /// own single-page path hands the *same* list back on a rebuild.
  static bool _sameBlocks(List<CanvasTextBlock> a, List<CanvasTextBlock> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Local rather than `listEquals`: this file deliberately imports only
  /// `material.dart`, and pulling in `foundation.dart` for one helper is how a
  /// canvas ends up with two names for the same predicate.
  static bool _sameDoubles(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// P48 · [Offset] 列表逐项比较（多边形顶点预览是否变化）。
  static bool _sameOffsets(List<Offset> a, List<Offset> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
