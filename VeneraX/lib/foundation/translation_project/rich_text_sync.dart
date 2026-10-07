/// Rebuilds FT's `rich_text` payload from a block's translation + `fontformat`.
///
/// ## Why this exists (P8.0 §5.2 item 1 — the "decisive blocker")
///
/// Every real FT block stores a `rich_text` key holding a **complete Qt
/// `qrichtext` HTML document** rendered from the lettering. FT's canvas renders
/// *that*, not the plain `translation` string. So an editor that changes
/// `translation` and leaves `rich_text` alone produces a file that VeneraX
/// shows correctly and **FT still shows the old text in** — which a user reads
/// as "the save did not work".
///
/// The studio therefore regenerates `rich_text` whenever the translation or a
/// lettering attribute changes, reproducing FT's own document shape (captured
/// from `Error the Echo`'s real blocks):
///
/// ```html
/// <!DOCTYPE html><html><head><meta name="qrichtext" content="1" />…
/// <body style=" font-family:'Microsoft YaHei UI'; font-size:24.375pt;
///              font-weight:400; font-style:normal;">
///   <p style="… line-height: 1.2;">
///     <span style=" color:#000100;">
///       <span style="letter-spacing: 0.15em;
///                    font-variant-ligatures: discretionary-ligatures;"
///             data-btrans-letter-spacing="1.15">LINE</span>
///     </span>
///   </p>…
/// </body></html>
/// ```
///
/// One `<p>` per translation line, matching how FT turns `\n` into paragraphs.
/// Font size is written in **points** (`px * 72 / 96`) exactly as FT does.
library;

import 'text_block.dart';

/// Logical DPI used for the px→pt conversion, shared with [ftPxToPt].
const double _dpi = 96.0;

/// Builds FT's `rich_text` document for [text] lettered with the given format.
String buildFtRichText({
  required String text,
  required String fontFamily,
  required double fontSizePx,
  required int fontWeight,
  required bool italic,
  required bool underline,
  required double lineSpacing,
  required double letterSpacing,
  required List<int> color,
  bool gradient = false,
}) {
  final sizePt = fontSizePx / _dpi * 72.0;
  final rgb = _rgbHex(color);
  // FT writes the letter-spacing as an `em` delta from the default 1.0 and
  // mirrors the raw multiplier into `data-btrans-letter-spacing`.
  final spacingEm = letterSpacing - 1.0;
  final style = italic ? 'italic' : 'normal';
  final decoration = underline ? 'text-decoration: underline; ' : '';

  final buffer = StringBuffer()
    ..write('<!DOCTYPE html><html><head><meta name="qrichtext" content="1" />')
    ..write('<meta charset="utf-8" /><style type="text/css">\n')
    ..write('p, li { white-space: pre-wrap; }\n')
    ..write('hr { height: 1px; border-width: 0; }\n')
    ..write('li.unchecked::marker { content: "\\2610"; }\n')
    ..write('li.checked::marker { content: "\\2612"; }\n')
    ..write('</style></head><body style=" font-family:\'')
    ..write(_escapeText(fontFamily))
    ..write('\'; font-size:')
    ..write(_formatPt(sizePt))
    ..write('pt; font-weight:')
    ..write(fontWeight)
    ..write('; font-style:')
    ..write(style)
    ..write(';">');

  // `split` on '\n' keeps empty lines as empty paragraphs, which is what FT
  // writes for a blank translation line — dropping them would silently change
  // the block's line count on the next FT save.
  for (final line in text.split('\n')) {
    buffer
      ..write('<p style="margin-top:0px; margin-bottom:0px; margin-left:0px; ')
      ..write('margin-right:0px; -qt-block-indent:0; text-indent:0px; ')
      ..write('line-height: ')
      ..write(_formatNumber(lineSpacing))
      ..write(';"><span style=" ')
      ..write(decoration)
      ..write('color:#')
      ..write(rgb)
      ..write(';"><span style="letter-spacing: ')
      ..write(_formatNumber(spacingEm))
      ..write('em; font-variant-ligatures: discretionary-ligatures;" ')
      ..write('data-btrans-letter-spacing="')
      ..write(_formatNumber(letterSpacing))
      ..write('">')
      ..write(_escapeText(line))
      ..write('</span></span></p>');
  }
  buffer.write('</body></html>');
  return buffer.toString();
}

/// Regenerates [block]'s `rich_text` from its current translation and format.
///
/// Called by the studio after any edit that changes the text or its lettering.
/// It intentionally goes through [TextBlock.ensureFontFormat] so a block that
/// somehow has no `fontformat` still yields a document FT can open.
void syncFtRichText(TextBlock block) {
  final format = block.ensureFontFormat();
  block.raw['rich_text'] = buildFtRichText(
    text: block.translation,
    fontFamily: format.fontFamily,
    fontSizePx: format.fontSize,
    fontWeight: format.fontWeight,
    italic: format.italic,
    underline: format.underline,
    lineSpacing: format.lineSpacing,
    letterSpacing: format.letterSpacing,
    color: format.foregroundColor,
    gradient: format.gradientEnabled,
  );
}

String _rgbHex(List<int> rgb) {
  if (rgb.length < 3) return '000000';
  final r = rgb[0].clamp(0, 255);
  final g = rgb[1].clamp(0, 255);
  final b = rgb[2].clamp(0, 255);
  return '${_hex2(r)}${_hex2(g)}${_hex2(b)}';
}

String _hex2(int value) => value.toRadixString(16).padLeft(2, '0');

/// Formats a number the way FT's Python `str()` does for the values it writes:
/// no scientific notation, no trailing zeros beyond what is meaningful.
///
/// `1.15 - 1.0` is `0.1499999999999999` in IEEE-754, so a naive `toString()`
/// would emit that ugly float into the HTML and diverge from FT's `0.15em`.
String _formatNumber(double value, {int decimals = 4}) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  var text = value.toStringAsFixed(decimals);
  if (text.contains('.')) {
    text = text.replaceAll(RegExp(r'0+$'), '');
    text = text.replaceAll(RegExp(r'\.$'), '');
  }
  return text;
}

String _formatPt(double value) => _formatNumber(value, decimals: 6);

/// Minimal HTML escaping for text nodes and attribute values.
String _escapeText(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
