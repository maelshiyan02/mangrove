import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:venera/foundation/bundled_fonts.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// Renders the translated page: draws [decoded] as the base, then lays each
/// region's translated text over it. Returns PNG bytes.
///
/// In [InpaintMode.patch] the base is the untouched original and each region is
/// covered with an opaque rounded plate in the sampled background colour (the
/// legacy look). In [InpaintMode.smart] the caller has already
/// erased the original lettering in [decoded.pixels], so the base is clean and
/// each region only gets a backing plate where the placed text would otherwise
/// be hard to read against the artwork.
Future<Uint8List> renderTranslatedPage(
  Uint8List originalBytes,
  RgbaImage decoded,
  List<TranslatedRegion> regions, {
  InpaintMode mode = InpaintMode.smart,
}) async {
  var base = await _baseImage(originalBytes, decoded, mode);
  try {
    var recorder = ui.PictureRecorder();
    var canvas = ui.Canvas(recorder);
    canvas.drawImage(base, ui.Offset.zero, ui.Paint());
    for (var region in regions) {
      if (mode == InpaintMode.patch) {
        _drawPatchRegion(canvas, region);
      } else {
        _drawErasedRegion(canvas, decoded, region);
      }
    }
    var picture = recorder.endRecording();
    var rendered = await picture.toImage(decoded.width, decoded.height);
    picture.dispose();
    try {
      var data = await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw Exception('Failed to encode translated page');
      }
      return data.buffer.asUint8List();
    } finally {
      rendered.dispose();
    }
  } finally {
    base.dispose();
  }
}

/// The base image to draw under the text. patch mode re-decodes the pristine
/// original at the working resolution; the erase modes draw [decoded] itself,
/// whose pixels were already cleaned by the inpainter.
Future<ui.Image> _baseImage(
  Uint8List originalBytes,
  RgbaImage decoded,
  InpaintMode mode,
) async {
  if (mode != InpaintMode.patch) {
    var buffer = await ui.ImmutableBuffer.fromUint8List(decoded.pixels);
    var descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: decoded.width,
      height: decoded.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    var codec = await descriptor.instantiateCodec();
    var frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  }
  var buffer = await ui.ImmutableBuffer.fromUint8List(originalBytes);
  var descriptor = await ui.ImageDescriptor.encoded(buffer);
  var codec = await descriptor.instantiateCodec(
    targetWidth: decoded.width,
    targetHeight: decoded.height,
  );
  var frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return frame.image;
}

ui.Rect _rectOf(TranslatedRegion region) => ui.Rect.fromLTRB(
  region.rect.left.toDouble(),
  region.rect.top.toDouble(),
  region.rect.right.toDouble(),
  region.rect.bottom.toDouble(),
);

/// Legacy patch mode: opaque rounded plate + feathered halo, then the text.
void _drawPatchRegion(ui.Canvas canvas, TranslatedRegion region) {
  var rect = _rectOf(region);
  var background = ui.Color(region.backgroundColor);

  // Coverage margin scales with the region so original text bleeding past the
  // detected box is still hidden instead of leaving edges poking out.
  var minSide = math.min(rect.width, rect.height);
  var margin = math.max(3.0, minSide * 0.14);
  var core = rect.inflate(margin);
  var radius = ui.Radius.circular(math.min(margin, 4.0));

  // Feathered halo blends the fill into textured/translucent bubbles; the
  // opaque core on top still guarantees the original text is covered.
  var sigma = math.max(1.5, margin * 0.6);
  canvas.drawRRect(
    ui.RRect.fromRectAndRadius(core.inflate(sigma * 0.5), radius),
    ui.Paint()
      ..color = background
      ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, sigma),
  );
  canvas.drawRRect(
    ui.RRect.fromRectAndRadius(core, radius),
    ui.Paint()..color = background,
  );

  _drawText(canvas, region, rect, ui.Color(region.textColor));
}

/// Erase mode: the base is already clean, so the text only needs a contrast
/// outline (never an opaque plate) to stay readable over minor screentone or
/// gradient the erase left behind.
void _drawErasedRegion(
  ui.Canvas canvas,
  RgbaImage decoded,
  TranslatedRegion region,
) {
  var rect = _rectOf(region);
  var backgroundIsDark = _regionIsDark(decoded, region.rect);
  var textColor = backgroundIsDark
      ? const ui.Color(0xFFF5F5F5)
      : const ui.Color(0xFF202020);
  // Outline in the opposite colour keeps the text legible without covering the
  // art — this is what replaces the old opaque backing plate.
  var outline = backgroundIsDark
      ? const ui.Color(0xE6000000)
      : const ui.Color(0xE6FFFFFF);
  _drawText(canvas, region, rect, textColor, outline: outline);
}

/// Mean-luminance test of the region on the (erased) base, choosing the text
/// colour. Sampled on a stride grid — a full read is needless for a summary.
bool _regionIsDark(RgbaImage image, IntRect rect) {
  var w = image.width;
  var left = rect.left.clamp(0, w - 1);
  var top = rect.top.clamp(0, image.height - 1);
  var right = rect.right.clamp(1, w);
  var bottom = rect.bottom.clamp(1, image.height);
  var pixels = image.pixels;

  var sum = 0.0;
  var count = 0;
  var stepX = math.max(1, (right - left) ~/ 24);
  var stepY = math.max(1, (bottom - top) ~/ 24);
  for (var y = top; y < bottom; y += stepY) {
    for (var x = left; x < right; x += stepX) {
      var i = (y * w + x) * 4;
      sum += 0.299 * pixels[i] + 0.587 * pixels[i + 1] + 0.114 * pixels[i + 2];
      count++;
    }
  }
  if (count == 0) return false;
  return sum / count < 128;
}

/// Draws the region's text (horizontal wrap or vertical columns). [outline],
/// when set, is painted as a stroke behind the fill so the text stays readable
/// on a cleaned background without an opaque plate.
void _drawText(
  ui.Canvas canvas,
  TranslatedRegion region,
  ui.Rect rect,
  ui.Color color, {
  ui.Color? outline,
}) {
  if (rect.width <= 4 || rect.height <= 4 || region.text.trim().isEmpty) {
    return;
  }
  final style = region.fontStyle;
  canvas.save();
  canvas.clipRect(rect);

  // 🔴 P0-1: rotation and glyph slant are applied around the region's centre
  // **before** anything is laid out, so the shrink-to-fit search below measures
  // the rotated footprint. Measuring first and rotating afterwards (the old
  // behaviour, which ignored both) let a rotated block overflow its box.
  final angle = style?.angle ?? 0.0;
  final slant = style?.glyphSlantAngle ?? 0.0;
  if (angle != 0 || slant != 0) {
    final center = rect.center;
    canvas.translate(center.dx, center.dy);
    if (angle != 0) canvas.rotate(angle * math.pi / 180.0);
    if (slant != 0) {
      // A shear is a scale on the y axis indexed by x. `ui.Canvas` has no
      // `concat`, only `transform(Float64List)`, so the 4x4 is written out
      // directly — column-major, which is what Skia expects.
      final k = math.tan(slant * math.pi / 180.0);
      canvas.transform(
        Float64List.fromList(<double>[
          1, k, 0, 0, //
          0, 1, 0, 0,
          0, 0, 1, 0,
          0, 0, 0, 1,
        ]),
      );
    }
    canvas.translate(-center.dx, -center.dy);
  }
  try {
    if (_prefersVertical(region.text, rect, style)) {
      _drawVerticalText(
        canvas,
        region.text,
        color,
        rect,
        outline: outline,
        lineHeight: region.lineHeight,
        style: style,
      );
      return;
    }
    var maxWidth = rect.width - 4;
    var maxHeight = rect.height - 4;
    var size = _fitFontSize(
      region.text,
      maxWidth,
      maxHeight,
      lineHeight: region.lineHeight,
      // 🔴 FT's requested `font_size` becomes an upper bound, never a
      // replacement: a user asking for 40px in a 20px-tall box must still get
      // readable 20px text, and forcing 40px would overflow the box.
      maxFontSize: style?.fontSize,
      style: style,
    );
    if (outline != null) {
      var strokePainter = _horizontalPainter(
        region.text,
        size,
        _strokeStyle(outline, size, style),
        maxWidth,
        style,
      );
      var strokeOffset = ui.Offset(
        rect.left + (rect.width - strokePainter.width) / 2,
        rect.top + (rect.height - strokePainter.height) / 2,
      );
      strokePainter.paint(canvas, strokeOffset);
      strokePainter.dispose();
    }
    var painter = _horizontalPainter(
      region.text,
      size,
      _fillStyle(color, size, style),
      maxWidth,
      style,
    );
    var offset = ui.Offset(
      rect.left + (rect.width - painter.width) / 2,
      rect.top + (rect.height - painter.height) / 2,
    );
    painter.paint(canvas, offset);
    painter.dispose();
  } finally {
    canvas.restore();
  }
}

/// Stroke width scales with the glyph so the outline reads at any size.
double _strokeWidth(double fontSize) => math.max(1.5, fontSize * 0.14);

/// Hard floor for the shrink-to-fit search. Nothing below this is legible, and
/// without it a box the text can never fit into makes the search unbounded.
const _minGlyphSize = 4.0;

/// Narrowest width [_horizontalPainter] will lay out at. The fit test must use
/// this, not the caller's box: `TextPainter.width` reports the layout
/// constraint, so comparing against a narrower value is never satisfiable.
const _minLayoutWidth = 8.0;

/// Builds the fill [TextStyle] for a region.
///
/// 🔴 P0-1: every field here used to be hard-coded. [style] is null for regions
/// that carry no FT formatting (the OCR pipeline, the reader's legacy parser,
/// cached results), and the defaults below reproduce the **old** output exactly
/// — that is what makes this change safe to land without re-rendering history.
TextStyle _fillStyle(ui.Color color, double fontSize, [RegionFontStyle? style]) {
  if (style == null) {
    // 🔴 P1-4: even the **no-FT-format** legacy path must letter in a bundled
    // face. Leaving `fontFamily` null here would let Flutter pick the platform
    // UI font, which on a machine without a CJK face renders tofu — and the
    // symptom ("boxes but no glyphs") looks like a detector bug, not a font
    // bug. Historically this path also resolved to the system face, so this is
    // the one place where output changes on purpose: everything the library
    // has already rendered stays as it is (only newly rendered pages change),
    // and it changes to "always has glyphs".
    return TextStyle(
      color: color,
      fontSize: fontSize,
      height: 1.2,
      fontWeight: FontWeight.w500,
      fontFamily: resolveFamily(null).family,
      // 🔴 P9.7: the chosen bundled face is a *subset* (SC has no Hangul, KR has
      // no simplified-only Han shapes). The chain keeps the substitution inside
      // `assets/fonts/` instead of letting Flutter reach for a platform face,
      // which is what acceptance criterion ③ is actually about.
      fontFamilyFallback: bundledFamilyFallbacks(null),
    );
  }
  return TextStyle(
    color: color.withValues(alpha: _alphaOf(style.opacity)),
    fontSize: fontSize,
    // FT's `line_spacing` is a multiplier, same unit as Flutter's `height`.
    height: style.lineSpacing,
    fontWeight: _fontWeightOf(style.fontWeight),
    // 🔴 P1-4: FT's `font_family` goes through [resolveFamily] rather than
    // straight into `TextStyle`. Passing it raw is what produced the "set a
    // font, nothing happens" symptom — `Microsoft YaHei UI` (FT's own default,
    // and the value in most existing project json) is not registered in this
    // app, so Flutter silently substituted the platform face. See
    // `lib/foundation/bundled_fonts.dart` for the fallback contract.
    fontFamily: resolveFamily(style.fontFamily).family,
    fontFamilyFallback: bundledFamilyFallbacks(style.fontFamily),
    fontStyle: style.italic ? ui.FontStyle.italic : ui.FontStyle.normal,
    // 🔴 FT's `letter_spacing` is a multiplier on the font's natural spacing,
    // so it becomes `(v - 1) em`. Passing the raw 1.15 as a pixel value would
    // squash every CJK glyph — the conversion has to be done here.
    letterSpacing: style.letterSpacing == null
        ? null
        : (style.letterSpacing! - 1.0),
    decoration: style.underline ? TextDecoration.underline : TextDecoration.none,
    shadows: _shadowsOf(style, fontSize),
  );
}

/// Outline [TextStyle]: drawn behind the fill so text stays readable without an
/// opaque plate. Mirrors [_fillStyle]'s metrics exactly — if the two disagreed
/// on size or family the outline would be visibly offset.
TextStyle _strokeStyle(ui.Color outline, double fontSize, [RegionFontStyle? style]) {
  if (style == null) {
    return TextStyle(
      fontSize: fontSize,
      height: 1.2,
      fontWeight: FontWeight.w500,
      // 🔴 P9.7: this branch used to leave `fontFamily` unset **while the fill
      // beside it had already moved to a bundled face** (P1-4). Two different
      // faces means two different glyph sets: the outline stops hugging the
      // fill and every outlined region gets a visible double edge. The comment
      // above has always claimed the two "mirror each other's metrics"; that
      // was only true while neither of them named a family.
      fontFamily: resolveFamily(null).family,
      fontFamilyFallback: bundledFamilyFallbacks(null),
      foreground: ui.Paint()
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = _strokeWidth(fontSize)
        ..strokeJoin = ui.StrokeJoin.round
        ..color = outline,
    );
  }
  return _fillStyle(outline, fontSize, style).copyWith(
    color: null,
    foreground: ui.Paint()
      ..style = ui.PaintingStyle.stroke
      // 🔴 FT's `stroke_width` is an absolute px value; the legacy path scaled it
      // with the glyph. Honouring it literally is what makes a 6px outline look
      // like 6px whether the text is 20px or 80px.
      ..strokeWidth = style.strokeWidth > 0 ? style.strokeWidth : _strokeWidth(fontSize)
      ..strokeJoin = ui.StrokeJoin.round
      ..color = outline,
  );
}

/// FT weights are 100..900 in steps of 100 (the same scale as CSS), so the
/// mapping is a lookup rather than the threshold ladder the canvas uses.
FontWeight _fontWeightOf(int value) => switch (value) {
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

/// `overall_opacity` applied to the fill's alpha, clamped because a corrupt
/// value would otherwise throw inside the paint.
double _alphaOf(double opacity) => opacity.clamp(0.0, 1.0);

/// FT's shadow as Flutter [ui.Shadow]s, or null when there is none.
///
/// `shadow_strength` scales the **alpha**, and `shadow_offset` is a pixel
/// displacement — both are how FT means them, so no extra factor is invented.
List<ui.Shadow>? _shadowsOf(RegionFontStyle style, double fontSize) {
  if (style.shadowColor == null || style.shadowRadius <= 0) return null;
  final strength = _alphaOf(style.shadowStrength);
  if (strength <= 0) return null;
  return [
    ui.Shadow(
      color: ui.Color(style.shadowColor!).withValues(
        alpha: ui.Color(style.shadowColor!).a * strength,
      ),
      // FT's radius is a blur sigma in px; Flutter wants a blur radius, which is
      // roughly 2x sigma. Converting keeps a 4px FT shadow looking like a 4px
      // one rather than a noticeably tighter 2px.
      blurRadius: style.shadowRadius * 2,
      offset: ui.Offset(style.shadowOffsetX, style.shadowOffsetY),
    ),
  ];
}

TextPainter _horizontalPainter(
  String text,
  double fontSize,
  TextStyle style,
  double maxWidth, [
  RegionFontStyle? font,
]) {
  var painter = TextPainter(
    text: TextSpan(text: text, style: style),
    // 🔴 FT's `alignment` replaces the historical hard-coded centre. Left/right
    // matter for translated lettering, where the source was right-aligned
    // and centring it looks plainly wrong.
    textAlign: switch (font?.alignment) {
      0 => TextAlign.left,
      2 => TextAlign.right,
      _ => TextAlign.center,
    },
    textDirection: _textDirectionFor(text),
  );
  painter.layout(maxWidth: math.max(_minLayoutWidth, maxWidth));
  return painter;
}

/// Whether [text] should be laid out right-to-left.
///
/// 🔴 Getting this wrong reverses a whole line's visual order. Silent for
/// Latin, catastrophic for Arabic/Hebrew — and a translation pipeline will
/// happily produce one. Detection is by Unicode range rather than by a
/// language tag, because nothing upstream carries one.
TextDirection _textDirectionFor(String text) {
  const rtlRanges = <(int, int)>[
    (0x0590, 0x05FF), // Hebrew
    (0x0600, 0x06FF), // Arabic
    (0x0700, 0x074F), // Syriac
    (0x0780, 0x07BF), // Thaana
    (0x07C0, 0x08FF), // N'Ko + Samaritan
    (0xFB1D, 0xFDFF), // Hebrew/Arabic presentation forms
    (0x10800, 0x10FFF), // Samaritan, Mandaic, Arabic Ext-A
  ];
  for (final rune in text.runes) {
    // Ignore anything below the first RTL block: digits and punctuation below
    // 0x0590 would otherwise drag an English sentence to RTL on the strength of
    // one stray character.
    if (rune < 0x0590) continue;
    for (final (lo, hi) in rtlRanges) {
      if (rune >= lo && rune <= hi) return TextDirection.rtl;
    }
  }
  return TextDirection.ltr;
}

/// Whether [text] should be laid out vertically inside [rect].
///
/// 🔴 P0-1: FT's explicit `vertical` flag now **wins over** the heuristic.
/// Previously a horizontal translation that happened to be tall and CJK was
/// silently rotated — the user asked for horizontal text and got columns.
bool _prefersVertical(String text, ui.Rect rect, [RegionFontStyle? style]) {
  if (style?.vertical ?? false) return true;
  if (style != null) {
    // The block carries real formatting and says "not vertical" — respect it
    // rather than second-guessing from the aspect ratio.
    return false;
  }
  if (rect.height < rect.width * 1.6) return false;
  var cjk = 0, total = 0;
  for (var r in text.runes) {
    if (r <= 0x20) continue;
    total++;
    if ((r >= 0x4E00 && r <= 0x9FFF) ||
        (r >= 0x3400 && r <= 0x4DBF) ||
        (r >= 0x3040 && r <= 0x30FF) ||
        (r >= 0xAC00 && r <= 0xD7AF)) {
      cjk++;
    }
  }
  if (total < 2) return false;
  return cjk / total >= 0.7;
}

/// Draws [text] as vertical right-to-left columns fitted to [rect], one
/// character per cell, wrapping to a new column on the left when full. When
/// [outline] is set each glyph is stroked behind its fill for legibility.
void _drawVerticalText(
  ui.Canvas canvas,
  String text,
  ui.Color color,
  ui.Rect rect, {
  ui.Color? outline,
  int lineHeight = 0,
  // 🔴 P0-1: the same FT styling the horizontal path gets.
  RegionFontStyle? style,
}) {
  var chars = text.runes
      .map((r) => String.fromCharCode(r))
      .where((c) => c.trim().isNotEmpty)
      .toList();
  if (chars.isEmpty) return;

  var maxWidth = rect.width - 4;
  var maxHeight = rect.height - 4;

  TextPainter glyph(String c, double fontSize, TextStyle style) {
    var painter = TextPainter(
      text: TextSpan(text: c, style: style),
      textDirection: TextDirection.ltr,
    );
    painter.layout();
    return painter;
  }

  // Cap by the original lettering size when known, so a small vertical caption
  // stays small instead of growing to fill the column width.
  var cap = 42.0;
  if (lineHeight > 0) {
    cap = math.min(cap, math.max(10.0, lineHeight * 0.9));
  }
  // 🔴 P0-1: the user's requested size caps vertical glyphs too, same as
  // horizontal. Without this, switching a block to vertical would silently
  // ignore the size the user picked.
  if (style?.fontSize != null && style!.fontSize! > 0) {
    cap = math.min(cap, style.fontSize!);
  }
  var upper = math.max(10.0, math.min(cap, maxWidth * 0.9));
  var size = upper;
  var chosen = _minGlyphSize;
  var perColumn = 1;
  var columns = chars.length;
  while (true) {
    var cell = size * 1.15;
    perColumn = math.max(1, (maxHeight / cell).floor());
    columns = (chars.length / perColumn).ceil();
    if (columns * cell <= maxWidth || size <= _minGlyphSize) {
      chosen = math.max(_minGlyphSize, size);
      break;
    }
    size *= 0.8;
  }

  var cellH = chosen * 1.15;
  var cellW = chosen * 1.15;
  perColumn = math.max(1, (maxHeight / cellH).floor());
  columns = (chars.length / perColumn).ceil();

  var blockW = columns * cellW;
  var blockH = math.min(maxHeight, perColumn * cellH);
  var startRight = rect.left + (rect.width + blockW) / 2;
  var top = rect.top + (rect.height - blockH) / 2;

  var fillStyle = _fillStyle(color, chosen, style).copyWith(height: 1.0);
  var strokeStyle = outline == null
      ? null
      : _strokeStyle(outline, chosen, style).copyWith(height: 1.0);

  for (var col = 0; col < columns; col++) {
    var colCenterX = startRight - (col + 0.5) * cellW;
    for (var row = 0; row < perColumn; row++) {
      var index = col * perColumn + row;
      if (index >= chars.length) break;
      var dyBase = top + row * cellH;
      if (strokeStyle != null) {
        var sp = glyph(chars[index], chosen, strokeStyle);
        sp.paint(
          canvas,
          ui.Offset(
            colCenterX - sp.width / 2,
            dyBase + (cellH - sp.height) / 2,
          ),
        );
        sp.dispose();
      }
      var painter = glyph(chars[index], chosen, fillStyle);
      var dx = colCenterX - painter.width / 2;
      var dy = dyBase + (cellH - painter.height) / 2;
      painter.paint(canvas, ui.Offset(dx, dy));
      painter.dispose();
    }
  }
}

/// Largest font size whose wrapped horizontal layout fits [maxWidth]x[maxHeight].
///
/// [lineHeight] is the original lettering's approximate size (px, 0 = unknown).
/// When known it caps the glyph size so the translation stays close to the
/// source scale — a small caption stays small instead of being blown up to fill
/// the detected box. The detector's line box already spans the full line with
/// leading and CJK glyphs fill the em, so the cap sits slightly *below* the box
/// height (0.9x) to keep the translation from reading larger than the source.
double _fitFontSize(
  String text,
  double maxWidth,
  double maxHeight, {
  int lineHeight = 0,
  // 🔴 P0-1: FT's requested `font_size`. It is a **cap**, never a floor: the
  // shrink-to-fit search must still be able to go smaller, or a user asking for
  // 40px inside a 20px box would get text overflowing the bubble.
  double? maxFontSize,
  RegionFontStyle? style,
}) {
  var cap = 42.0;
  if (lineHeight > 0) {
    cap = math.min(cap, math.max(10.0, lineHeight * 0.9));
  }
  // The tighter of "the source lettering" and "what the user asked for" wins.
  if (maxFontSize != null && maxFontSize > 0) {
    cap = math.min(cap, maxFontSize);
  }
  var upper = math.max(10.0, math.min(cap, maxHeight * 0.8));
  var layoutWidth = math.max(_minLayoutWidth, maxWidth);
  var size = upper;
  while (size > _minGlyphSize) {
    var painter = _horizontalPainter(
      text,
      size,
      _fillStyle(const ui.Color(0xFF000000), size, style),
      maxWidth,
      style,
    );
    var fits = painter.height <= maxHeight && painter.width <= layoutWidth;
    painter.dispose();
    if (fits) return size;
    size *= 0.8;
  }
  return _minGlyphSize;
}
