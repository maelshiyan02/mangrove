import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:venera/foundation/bundled_fonts.dart';

import 'block_resize_geometry.dart';

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
  if (!file.existsSync()) return null;
  final Uint8List bytes;
  try {
    bytes = await file.readAsBytes();
  } catch (_) {
    return null;
  }
  if (bytes.isEmpty) return null;
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
  } catch (_) {
    // A truncated or unsupported file must not take the page down; the caller
    // falls back to the original image the same way it falls back when
    // `inpainted/` is missing.
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
  });

  final int index;

  /// Block box in the **original** page resolution.
  final Rect rect;

  final String translation;
  final String sourceText;
  final String fontFamily;

  /// Font size in pixels, FT's unit.
  final double fontSize;

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
  );
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
    this.marquee,
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

  /// Live marquee for "drag out a new box", in **canvas** pixels. Drawn as a
  /// translucent fill plus a dashed border so it reads as "pending" rather than
  /// as a committed block.
  final Rect? marquee;

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

    for (final block in blocks) {
      final rect = Rect.fromLTRB(
        block.rect.left * fit,
        block.rect.top * fit,
        block.rect.right * fit,
        block.rect.bottom * fit,
      );
      if (!rect.isFinite || rect.isEmpty) continue;
      final selected = block.index == selectedIndex;
      if (showBoxes || selected) {
        canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = selected ? 2 : 0.8
            ..color = selected ? selection : outline.withValues(alpha: 0.55),
        );
      }
      _paintText(canvas, block, rect, selected);
      // 🔴 Handles are drawn from `paint` rather than inside `_paintText`: that
      // method returns early for empty text, so a freshly created (still empty)
      // block would have shown no handles at all — precisely the block the user
      // most needs to resize.
      if (selected && showResizeHandles) _paintHandles(canvas, rect);
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

  void _paintText(Canvas canvas, CanvasTextBlock block, Rect rect, bool selected) {
    final text = block.displayText;
    if (text.isEmpty) return;
    // FT stores px; the canvas is a scaled view of the page.
    final fontSize = math.max(6.0, block.fontSize * fit);
    if (fontSize < 4) return;
    final lineHeight = block.lineSpacing ?? 1.15;
    final base = block.hasTranslation ? block.foreground : untranslated;
    final alpha = block.opacity.clamp(0.0, 1.0).toDouble();
    final fill = base.withValues(alpha: base.a * alpha);
    final textAlign = switch (block.alignment) {
      1 => TextAlign.center,
      2 => TextAlign.right,
      _ => TextAlign.left,
    };
    // FT's `letter_spacing` is a multiplier on the font's natural spacing, not
    // a pixel count, so it is converted to logical pixels at this font size.
    final letterSpacing = ((block.letterSpacing ?? 1.0) - 1.0) * fontSize;

    TextStyle style({Paint? foreground}) => TextStyle(
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
      fontSize: fontSize,
      fontWeight: _weight(block.fontWeight),
      color: foreground == null ? fill : null,
      foreground: foreground,
      height: lineHeight,
      letterSpacing: letterSpacing,
    );

    TextPainter build(TextStyle textStyle) => TextPainter(
      text: TextSpan(text: text, style: textStyle),
      textDirection: TextDirection.ltr,
      textAlign: textAlign,
      maxLines: math.max(1, (rect.height / (fontSize * lineHeight)).floor()),
      ellipsis: '…',
    )..layout(maxWidth: rect.width);

    final stroke = block.strokeColor;
    TextPainter? outline;
    if (stroke != null && block.strokeWidth > 0) {
      outline = build(
        style(
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = block.strokeWidth * fit
            ..strokeJoin = StrokeJoin.round
            ..color = stroke.withValues(alpha: stroke.a * alpha),
        ),
      );
    }
    final painter = build(style());

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
      canvas.translate(rect.right, rect.top);
      canvas.rotate(math.pi / 2);
      outline?.paint(canvas, Offset.zero);
      painter.paint(canvas, Offset.zero);
    } else {
      outline?.paint(canvas, rect.topLeft);
      painter.paint(canvas, rect.topLeft);
    }
    canvas.restore();
    // The old "four filled circles on the corners" marker used to live here.
    // It is replaced by [PageCanvasPainter._paintHandles], which draws eight
    // square handles and — unlike this marker — is not skipped when the block
    // has no text yet (this method returns early for empty text, which is
    // exactly the state of a block the user just created).
  }

  static FontWeight _weight(int value) => switch (value) {
    <= 150 => FontWeight.w100,
    <= 250 => FontWeight.w200,
    <= 350 => FontWeight.w300,
    <= 450 => FontWeight.w400,
    <= 550 => FontWeight.w500,
    <= 650 => FontWeight.w600,
    <= 750 => FontWeight.w700,
    <= 850 => FontWeight.w800,
    _ => FontWeight.w900,
  };

  @override
  bool shouldRepaint(PageCanvasPainter old) =>
      old.page != page ||
      old.fit != fit ||
      old.selectedIndex != selectedIndex ||
      old.showBoxes != showBoxes ||
      old.blocks != blocks ||
      old.marquee != marquee ||
      !_sameDoubles(old.snapGuidesX, snapGuidesX) ||
      !_sameDoubles(old.snapGuidesY, snapGuidesY);

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
}
