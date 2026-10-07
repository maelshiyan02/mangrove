import 'dart:math' as math;

import '../image_translation/translation_types.dart';

/// Fan Translation (FT / BallonsTranslator) text-block model.
///
/// ## Why this is a "DOM passthrough" model instead of a plain data class
///
/// A real FT project stores **23 keys per text block** and **32 keys per
/// `fontformat`**, and those numbers grow as FT evolves. A hand-written class
/// that only knows today's fields silently deletes anything it does not
/// understand the moment we write the file back — the user's styles would be
/// gone when they reopen the project in FT.
///
/// The S5 probe turned up a second, sharper reason: 97 of the 194 page keys in
/// the sample project are phantom `.jpg` entries that exist only in the JSON.
/// A "typed model + write only known fields" strategy would drop those too, and
/// the round-trip diff would stop being zero.
///
/// So the source of truth here is the **decoded JSON itself, kept in its
/// original key order**, and every typed accessor is a *view* over it. Two
/// rules keep that honest:
///
/// * **Reading never materialises a key.** A getter returns a default when the
///   key is absent instead of inserting it, so a pure read pass cannot change
///   the file. (Writing a default would turn a zero-byte diff into a real one.)
/// * **Writing goes through the map.** Setters update the existing entry in
///   place, preserving its position, or append when the key is genuinely new.
///
/// `TextBlock.toTranslatedRegion()` is the bridge to the existing renderer, and
/// it is written to be *exactly* equivalent to the legacy
/// `BtProject._parseBlock` so switching the reader over cannot change what is
/// drawn (verified on the real project by `tools/s6_project_roundtrip.dart`).

/// Font weight values, mirroring FT's `FontWeight` IntEnum.
class FtFontWeight {
  const FtFontWeight._();

  static const int thin = 100;
  static const int extraLight = 200;
  static const int light = 300;
  static const int normal = 400;
  static const int medium = 500;
  static const int demiBold = 600;
  static const int bold = 700;
  static const int extraBold = 800;
  static const int black = 900;
}

/// Text alignment values, mirroring FT's `TextAlignment` IntEnum.
class FtTextAlignment {
  const FtTextAlignment._();

  static const int left = 0;
  static const int center = 1;
  static const int right = 2;
}

/// Line spacing interpretation, mirroring FT's `LineSpacingType` IntEnum.
class FtLineSpacingType {
  const FtLineSpacingType._();

  /// `line_spacing` multiplies the font size.
  static const int proportional = 0;

  /// `line_spacing` is an absolute distance in pixels.
  static const int distance = 1;
}

/// Logical DPI FT measure font sizes against (`shared.LDPI`).
///
/// FT stores `font_size` in pixels but some legacy payloads stored points, so
/// the two are converted on load. Keep in step with `fontformat.py`.
const double _logicalDpi = 96.0;

/// Ports FT's `pt2px`.
double ftPtToPx(double pt) => pt * _logicalDpi / 72.0;

/// Ports FT's `px2pt`.
double ftPxToPt(double px) => px / _logicalDpi * 72.0;

/// Narrows an arbitrary decoded value to a string-keyed map, or null.
///
/// JSON objects always decode to `Map<String, dynamic>`, but a malformed or
/// hand-edited project can hold something else; callers must not crash on it.
Map<String, Object?>? asObjectMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    final result = <String, Object?>{};
    value.forEach((key, entry) => result[key.toString()] = entry);
    return result;
  }
  return null;
}

/// Narrows an arbitrary decoded value to a list, or null.
List<Object?>? asObjectList(Object? value) {
  if (value is List) return value;
  return null;
}

/// Reads a colour stored as `[r, g, b]` (0..255) into a packed ARGB int.
///
/// Mirrors `BtProject._rgb`: a malformed entry yields null so the caller can
/// keep its own default instead of painting something arbitrary.
int? ftRgbToArgb(Object? value, {int fallbackAlpha = 0xFF}) {
  final list = asObjectList(value);
  if (list == null || list.length < 3) return null;
  final r = (list[0] as num?)?.round().clamp(0, 255);
  final g = (list[1] as num?)?.round().clamp(0, 255);
  final b = (list[2] as num?)?.round().clamp(0, 255);
  if (r == null || g == null || b == null) return null;
  return (fallbackAlpha << 24) | (r << 16) | (g << 8) | b;
}

/// Packs `[r, g, b]` into an ARGB int, clamping out-of-range input.
int ftRgbToArgbBytes(int r, int g, int b) {
  return 0xFF000000 |
      (r.clamp(0, 255) << 16) |
      (g.clamp(0, 255) << 8) |
      b.clamp(0, 255);
}

/// Splits a packed ARGB int back into FT's `[r, g, b]`.
List<int> ftArgbToRgb(int argb) {
  return [(argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF];
}

/// One entry of a `TextEffectStack` — a stroke, a hollow fill, a shadow, …
class TextEffect {
  TextEffect(this.raw);

  /// The live JSON object; mutations land here.
  final Map<String, Object?> raw;

  /// Discriminator FT uses: `stroke`, `hollow`, `shadow`, `gradient`, …
  String? get effectType => raw['effect_type'] as String?;

  bool get enabled => raw['enabled'] == true;

  set enabled(bool value) => raw['enabled'] = value;

  double get opacity => (raw['opacity'] as num?)?.toDouble() ?? 1.0;

  set opacity(double value) => raw['opacity'] = value;

  /// Stroke width in pixels; only meaningful for the stroke effect.
  double get width => (raw['width'] as num?)?.toDouble() ?? 0.0;

  set width(double value) => raw['width'] = value;

  /// Placement relative to the glyph outline (`outside`, `center`, `inside`).
  String? get position => raw['position'] as String?;

  /// Paint payload, e.g. `{paint_type: solid, color: [r, g, b]}`.
  Map<String, Object?>? get paint => asObjectMap(raw['paint']);

  /// Stroke colour as `[r, g, b]`, or null when the paint is not solid.
  List<int>? get paintColor {
    final entry = paint;
    if (entry == null) return null;
    final color = asObjectList(entry['color']);
    if (color == null || color.length < 3) return null;
    return [
      for (final channel in color.take(3)) (channel as num?)?.round() ?? 0,
    ];
  }
}

/// FT's `text_effects` payload: an overall opacity plus an ordered effect list.
///
/// FT keeps three legacy flat fields (`opacity`, `stroke_width`, `srgb`) in the
/// same `fontformat` object and derives them from this stack. Both must be
/// updated together or FT and the studio would disagree about the same file;
/// see [FontFormat.setStrokeWidth] and friends.
class TextEffectStack {
  TextEffectStack(this.raw);

  /// The live JSON object; mutations land here.
  final Map<String, Object?> raw;

  double get overallOpacity =>
      (raw['overall_opacity'] as num?)?.toDouble() ?? 1.0;

  set overallOpacity(double value) => raw['overall_opacity'] = value;

  List<TextEffect> get effects {
    final list = asObjectList(raw['effects']);
    if (list == null) return const [];
    return [
      for (final entry in list)
        if (asObjectMap(entry) case final map?) TextEffect(map),
    ];
  }

  /// The effect that owns stroke width/colour, creating a neutral one when the
  /// stack predates the effect system.
  TextEffect ensureStrokeEffect() {
    for (final effect in effects) {
      if (effect.effectType == 'stroke') return effect;
    }
    final created = <String, Object?>{
      'effect_type': 'stroke',
      'enabled': true,
      'opacity': 1.0,
      'blend_mode': 'normal',
      'width': 0.0,
      'position': 'outside',
      'paint': <String, Object?>{
        'paint_type': 'solid',
        'color': [0, 0, 0],
      },
    };
    final list = asObjectList(raw['effects']);
    if (list == null) {
      raw['effects'] = <Object?>[created];
    } else {
      list.add(created);
    }
    return TextEffect(created);
  }

  /// FT's compatibility view: 0 when the primary stroke is neutral.
  double get strokeWidth {
    final stroke = _primaryStroke;
    if (stroke == null || !stroke.enabled || stroke.opacity == 0.0) return 0.0;
    return stroke.width;
  }

  /// FT's compatibility view: the stroke colour, or black when neutral.
  List<int> get strokeColor => _primaryStroke?.paintColor ?? const [0, 0, 0];

  TextEffect? get _primaryStroke {
    for (final effect in effects) {
      if (effect.effectType == 'stroke') return effect;
    }
    return null;
  }
}

/// FT's `fontformat` payload: everything about how one block is lettered.
///
/// See the file header for why the raw map is authoritative. As a rule, every
/// getter here is safe to call on a read-only pass: absent keys yield FT's own
/// default and are **not** written back.
class FontFormat {
  FontFormat(this.raw);

  /// A format carrying **all 32 keys** FT writes, in the sample project's
  /// order, with FT's own defaults.
  ///
  /// 🔴 A partial `fontformat` is worse than an absent one: FT reads it back
  /// field by field, so a block created with only `font_family` and `font_size`
  /// would open in FT with every other style silently reset. The studio's
  /// "new block" path and the upcoming OCR adapter both take their defaults
  /// from here so a created block is indistinguishable from a detected one.
  ///
  /// Values come from the `default*` constants below — never from literals
  /// spelled out at the call site.
  factory FontFormat.createDefault() {
    final raw = <String, Object?>{
      'font_family': defaultFontFamily,
      'font_size': defaultFontSize,
      'frgb': <int>[0, 0, 0],
      'underline': false,
      'italic': false,
      // 🔴 FT's own default is centred (`TextAlignment.center == 1`), **not**
      // left. `defaultAlignment` below is the studio's block-panel default and
      // disagrees; a created block follows FT so that opening the project in FT
      // shows what the studio showed.
      'alignment': FtTextAlignment.center,
      'vertical': false,
      'standard_vertical_roman_alignment': true,
      'font_weight': defaultFontWeight,
      'line_spacing': defaultLineSpacing,
      'letter_spacing': defaultLetterSpacing,
      'ligature_common': 'default',
      'ligature_discretionary': 'enabled',
      'ligature_contextual': 'default',
      'oldstyle_nums': 'default',
      'shadow_radius': 0.0,
      'shadow_strength': 1.0,
      'shadow_color': <int>[0, 0, 0],
      'shadow_offset': <double>[0.0, 0.0],
      'gradient_enabled': false,
      'gradient_start_color': <int>[0, 0, 0],
      'gradient_end_color': <int>[255, 255, 255],
      'gradient_angle': 0.0,
      'gradient_size': 1.0,
      '_style_name': '',
      'line_spacing_type': defaultLineSpacingType,
      'text_transform': <Object?>[],
      'text_effects': <String, Object?>{
        'overall_opacity': 1.0,
        'effects': <Object?>[
          <String, Object?>{
            'effect_type': 'stroke',
            // FT ships stroke *enabled* with width 0 — the effect exists but
            // draws nothing. Keeping it enabled means the panel's stroke slider
            // has something to grab, and a width change turns it on for real.
            'enabled': true,
            'opacity': 1.0,
            'blend_mode': 'normal',
            'width': 0.0,
            'position': 'outside',
            'paint': <String, Object?>{
              'paint_type': 'solid',
              'color': <int>[0, 0, 0],
            },
          },
          <String, Object?>{'effect_type': 'hollow', 'enabled': false},
        ],
      },
      'glyph_slant_angle': 0.0,
      'opacity': 1.0,
      'stroke_width': 0.0,
      'srgb': <int>[0, 0, 0],
    };
    return FontFormat(raw);
  }

  /// The live JSON object; mutations land here.
  final Map<String, Object?> raw;

  // --- Defaults, copied from FT's `FontFormat` dataclass -------------------

  static const String defaultFontFamily = 'Microsoft YaHei UI';
  static const double defaultFontSize = 24.0;
  static const int defaultAlignment = FtTextAlignment.left;
  static const int defaultFontWeight = FtFontWeight.normal;
  static const double defaultLineSpacing = 1.2;
  static const double defaultLetterSpacing = 1.15;
  static const int defaultLineSpacingType = FtLineSpacingType.proportional;

  String get fontFamily => raw['font_family'] as String? ?? defaultFontFamily;

  set fontFamily(String value) => raw['font_family'] = value;

  /// Font size in **pixels** (FT stores px, and exposes `size_pt` separately).
  double get fontSize =>
      (raw['font_size'] as num?)?.toDouble() ?? defaultFontSize;

  set fontSize(double value) => raw['font_size'] = value;

  /// Same value expressed in points, matching FT's `size_pt` property.
  double get sizePt => ftPxToPt(fontSize);

  int get fontWeight {
    final value = raw['font_weight'];
    if (value is num) return value.round();
    return _resolveLegacyWeight() ?? defaultFontWeight;
  }

  set fontWeight(int value) => raw['font_weight'] = value;

  int get alignment => (raw['alignment'] as num?)?.round() ?? defaultAlignment;

  set alignment(int value) => raw['alignment'] = value;

  bool get vertical => raw['vertical'] == true;

  set vertical(bool value) => raw['vertical'] = value;

  bool get srcIsVerticalRoman =>
      raw['standard_vertical_roman_alignment'] != false;

  bool get underline => raw['underline'] == true;

  bool get italic => raw['italic'] == true;

  double get lineSpacing =>
      (raw['line_spacing'] as num?)?.toDouble() ?? defaultLineSpacing;

  set lineSpacing(double value) => raw['line_spacing'] = value;

  int get lineSpacingType =>
      (raw['line_spacing_type'] as num?)?.round() ?? defaultLineSpacingType;

  double get letterSpacing =>
      (raw['letter_spacing'] as num?)?.toDouble() ?? defaultLetterSpacing;

  /// Foreground (text fill) colour as `[r, g, b]`.
  List<int> get foregroundColor => _colorList('frgb', const [0, 0, 0]);

  /// Foreground colour packed into ARGB.
  int get foregroundArgb => ftRgbToArgb(foregroundColor) ?? 0xFF000000;

  set foregroundColor(List<int> value) => raw['frgb'] = value;

  /// Stroke colour as `[r, g, b]`. Prefers the effect stack (FT's live owner)
  /// and falls back to the flat `srgb` field when no stroke effect exists.
  List<int> get strokeColor {
    final stack = textEffects;
    if (stack != null) return stack.strokeColor;
    return _colorList('srgb', const [0, 0, 0]);
  }

  /// Background/fill colour as `[r, g, b]` (FT's `srgb`).
  List<int> get backgroundColor => _colorList('srgb', const [0, 0, 0]);

  int get backgroundArgb => ftRgbToArgb(backgroundColor) ?? 0xFFFFFFFF;

  /// Whether the block is drawn with a visible glyph outline.
  bool get hasStroke => strokeWidth > 0.0;

  double get strokeWidth => (raw['stroke_width'] as num?)?.toDouble() ?? 0.0;

  double get opacity =>
      (raw['opacity'] as num?)?.toDouble() ??
      textEffects?.overallOpacity ??
      1.0;

  double get shadowRadius => (raw['shadow_radius'] as num?)?.toDouble() ?? 0.0;

  double get shadowStrength =>
      (raw['shadow_strength'] as num?)?.toDouble() ?? 1.0;

  List<int> get shadowColor => _colorList('shadow_color', const [0, 0, 0]);

  List<double> get shadowOffset {
    final list = asObjectList(raw['shadow_offset']);
    if (list == null) return const [0.0, 0.0];
    return [
      for (final entry in list.take(2)) (entry as num?)?.toDouble() ?? 0.0,
    ];
  }

  bool get gradientEnabled => raw['gradient_enabled'] == true;

  List<int> get gradientStartColor =>
      _colorList('gradient_start_color', const [0, 0, 0]);

  List<int> get gradientEndColor =>
      _colorList('gradient_end_color', const [255, 255, 255]);

  double get gradientAngle =>
      (raw['gradient_angle'] as num?)?.toDouble() ?? 0.0;

  double get gradientSize => (raw['gradient_size'] as num?)?.toDouble() ?? 1.0;

  /// Name of the style preset this format was captured from, if any.
  String get styleName => raw['_style_name'] as String? ?? '';

  String get ligatureCommon => raw['ligature_common'] as String? ?? 'default';

  String get ligatureDiscretionary =>
      raw['ligature_discretionary'] as String? ?? 'enabled';

  String get ligatureContextual =>
      raw['ligature_contextual'] as String? ?? 'default';

  String get oldstyleNumerals => raw['oldstyle_nums'] as String? ?? 'default';

  /// Glyph slant in degrees. FT keeps a flat copy for compatibility and stores
  /// the transform stack in `text_transform`; the flat copy wins on read.
  double get glyphSlantAngle {
    final flat = raw['glyph_slant_angle'];
    if (flat is num) return flat.toDouble();
    return 0.0;
  }

  /// The effect stack, or null when the payload predates it (read-only).
  TextEffectStack? get textEffects {
    final map = asObjectMap(raw['text_effects']);
    if (map == null) return null;
    return TextEffectStack(map);
  }

  /// The transform stack as raw entries, in order.
  List<Object?> get textTransform =>
      asObjectList(raw['text_transform']) ?? const [];

  /// The effect stack, created if the payload does not have one yet.
  ///
  /// Separate from [textEffects] on purpose: only an explicit edit should
  /// introduce the key.
  TextEffectStack ensureTextEffects() {
    final existing = asObjectMap(raw['text_effects']);
    if (existing != null) return TextEffectStack(existing);
    final created = <String, Object?>{
      'overall_opacity': raw['opacity'] ?? 1.0,
      'effects': <Object?>[
        <String, Object?>{
          'effect_type': 'stroke',
          'enabled': true,
          'opacity': 1.0,
          'blend_mode': 'normal',
          'width': raw['stroke_width'] ?? 0.0,
          'position': 'outside',
          'paint': <String, Object?>{
            'paint_type': 'solid',
            'color': _colorList('srgb', const [0, 0, 0]),
          },
        },
        <String, Object?>{'effect_type': 'hollow', 'enabled': false},
      ],
    };
    raw['text_effects'] = created;
    return TextEffectStack(created);
  }

  // --- Compound setters: keep the flat compatibility fields in step ---------
  //
  // FT treats `text_effects` as the live owner of opacity/stroke and mirrors the
  // values into `opacity` / `stroke_width` / `srgb` on save. Writing only one
  // side would leave FT and the studio disagreeing about the same file, so the
  // setters below always update both.

  void setOpacity(double value) {
    raw['opacity'] = value;
    ensureTextEffects().overallOpacity = value;
  }

  void setStrokeWidth(double value) {
    raw['stroke_width'] = value;
    final stroke = ensureTextEffects().ensureStrokeEffect();
    stroke.width = value;
    stroke.enabled = value > 0.0;
  }

  void setStrokeColor(List<int> rgb) {
    raw['srgb'] = rgb;
    final stroke = ensureTextEffects().ensureStrokeEffect();
    final paint = stroke.paint;
    if (paint == null) {
      stroke.raw['paint'] = <String, Object?>{
        'paint_type': 'solid',
        'color': rgb,
      };
    } else {
      paint['paint_type'] = 'solid';
      paint['color'] = rgb;
    }
  }

  // --- Legacy migration (read-only) ----------------------------------------
  //
  // FT routes an old `deprecated_attributes` object into the modern fields.
  // We reproduce the interpretation but never write the result back, so an
  // untouched legacy file still round-trips byte for byte.

  Map<String, Object?>? get _deprecated =>
      asObjectMap(raw['deprecated_attributes']);

  int? _resolveLegacyWeight() {
    final legacy = _deprecated;
    if (legacy == null) return null;
    final weight = legacy['weight'];
    if (weight is num) return weight.round();
    if (legacy['bold'] == true) return FtFontWeight.bold;
    return null;
  }

  /// Font size with the legacy `deprecated_attributes.size` (points) applied.
  ///
  /// Use this instead of [fontSize] when reading a project that may predate the
  /// pixel-based field. Reading does not modify the payload.
  double get effectiveFontSize {
    final legacy = _deprecated;
    final size = legacy?['size'];
    if (size is num) return ftPtToPx(size.toDouble());
    return fontSize;
  }

  /// Font family with the legacy `deprecated_attributes.family` applied.
  String get effectiveFontFamily {
    final legacy = _deprecated;
    final family = legacy?['family'];
    if (family is String && family.isNotEmpty) return family;
    return fontFamily;
  }

  List<int> _colorList(String key, List<int> fallback) {
    final list = asObjectList(raw[key]);
    if (list == null || list.length < 3) return fallback;
    return [
      for (final channel in list.take(3)) (channel as num?)?.round() ?? 0,
    ];
  }
}

/// One FT text block: the source text, its translation, and its lettering.
class TextBlock {
  TextBlock(this.raw);

  /// Builds a blank, fully-formed block for [rect] — the **single source of a
  /// default text block** (P9.3).
  ///
  /// 🔴 This is deliberately the *only* place a new block's shape is defined,
  /// because two callers now need it and must not disagree:
  ///
  /// * the studio's "new block" button (S8 leftover, P2-6-c), and
  /// * the OCR adapter that will lift detected regions into editable blocks
  ///   (S9 P0-2).
  ///
  /// If each built its own map, a hand-made block and an automatic one would
  /// differ in key set, and the project's zero-byte-diff guarantee would break
  /// the first time a page mixed the two.
  ///
  /// Every one of FT's 23 block keys and 32 `fontformat` keys is written out,
  /// in the same order the real project stores them, so a created block is
  /// indistinguishable in shape from a detected one. Values come from
  /// [FontFormat]'s own defaults rather than being repeated here.
  ///
  /// [translation] starts empty on purpose: a block with no text yet must not
  /// be lettered (see [toTranslatedRegion]), and the studio needs to be able to
  /// select and type into it before anything is drawn.
  factory TextBlock.createDefault({required IntRect rect}) {
    final raw = <String, Object?>{};
    // Keys FT writes first, in the sample project's order.
    raw['xyxy'] = <double>[
      rect.left.toDouble(),
      rect.top.toDouble(),
      rect.right.toDouble(),
      rect.bottom.toDouble(),
    ];
    // The four corners of the box, as FT's detector records them. A flat
    // quad; `lines` is what the reader would follow for a rotated block.
    raw['lines'] = [
      [
        [rect.left.toDouble(), rect.top.toDouble()],
        [rect.right.toDouble(), rect.top.toDouble()],
        [rect.right.toDouble(), rect.bottom.toDouble()],
        [rect.left.toDouble(), rect.bottom.toDouble()],
      ],
    ];
    raw['language'] = 'unknown';
    raw['distance'] = null;
    raw['angle'] = 0;
    final width = rect.width.toDouble();
    final height = rect.height.toDouble();
    raw['vec'] = <double>[width, 0.0];
    raw['norm'] = math.sqrt(width * width + height * height);
    raw['merged'] = false;
    raw['text'] = <String>[''];
    raw['translation'] = '';
    raw['rich_text'] = '';
    raw['_bounding_rect'] = <double>[
      rect.left.toDouble(),
      rect.top.toDouble(),
      width,
      height,
    ];
    raw['src_is_vertical'] = false;
    // 🔴 Set to the block's default size, not 0: `_detected_font_size` is what
    // the renderer turns into a line height, and 0 would letter at whatever the
    // renderer's fallback is instead of the size the panel shows.
    raw['_detected_font_size'] = FontFormat.defaultFontSize;
    raw['det_model'] = '';
    raw['label'] = null;
    raw['region_mask'] = null;
    raw['region_inpaint_dict'] = null;
    raw['fontformat'] = FontFormat.createDefault().raw;
    raw['text_alpha_mask'] = null;
    raw['_detected_font_name'] = '';
    raw['_detected_font_confidence'] = 0.0;
    raw['text_layout_version'] = 1;
    return TextBlock(raw);
  }

  /// Lifts one detected region into an **editable** block (S9 P0-2).
  ///
  /// This is the reverse bridge that P0-1's forward one (`toTranslatedRegion`)
  /// implied but did not provide: the OCR pipeline produces
  /// [OcrBlock]s — plain geometry plus text — while the studio and FT need a
  /// fully-formed 23-key [TextBlock].
  ///
  /// 🔴 **It builds on [createDefault] and mutates the result**, rather than
  /// assembling a map of its own. Two callers now need "a new block", and if
  /// they disagreed on the key set the project's zero-byte-diff guarantee would
  /// break the first time a page mixed a hand-made block with a detected one —
  /// which is exactly what happens as soon as the user adds one by hand to a
  /// detected page.
  ///
  /// ## What gets carried across
  ///
  /// | from [OcrBlock] | to |
  /// |---|---|
  /// | [OcrBlock.rect] | `xyxy`, `lines`, `_bounding_rect` |
  /// | [OcrBlock.text] | `text` (split on newlines, FT's list form) |
  /// | [OcrBlock.language] | `language` |
  /// | [OcrBlock.textColor] / [backgroundColor] | `fontformat.frgb` / `srgb` |
  /// | [OcrBlock.lineHeight] | `_detected_font_size` **and** `fontformat.font_size` |
  ///
  /// [translation] is deliberately left **empty**: an untranslated block must not
  /// be lettered (see [toTranslatedRegion]), and the pipeline fills it in a
  /// moment later. Writing the source text there would render untranslated
  /// Japanese over the erased Japanese.
  factory TextBlock.fromOcr(OcrBlock block) {
    final rect = block.rect;
    final result = TextBlock.createDefault(rect: rect);

    // ---- Geometry: `_bounding_rect` is [l, t, w, h], not [l, t, r, b] ----
    // `createDefault` already wrote it correctly for the rect it was given, so
    // only the fields the OCR block knows better are refreshed.
    result.raw['lines'] = [
      [
        [rect.left.toDouble(), rect.top.toDouble()],
        [rect.right.toDouble(), rect.top.toDouble()],
        [rect.right.toDouble(), rect.bottom.toDouble()],
        [rect.left.toDouble(), rect.bottom.toDouble()],
      ],
    ];

    // ---- Source text ----
    final text = block.text.trim();
    result.raw['text'] = text.isEmpty
        ? <String>['']
        : text.split('\n').map((line) => line.trim()).toList();
    if (block.language.trim().isNotEmpty) {
      result.raw['language'] = block.language.trim();
    }

    final format = result.fontFormat!;
    final foreground = _argbToFtRgb(block.textColor);
    if (foreground != null) format.raw['frgb'] = foreground;
    final background = _argbToFtRgb(block.backgroundColor);
    if (background != null) format.raw['srgb'] = background;

    // ---- Size ----
    // 🔴 `lineHeight` is the *measured* source glyph height, which is far more
    // trustworthy than FT's default 24. It feeds **both** keys: the renderer
    // reads `_detected_font_size` as a cap, and `font_size` is what the panel
    // shows and P0-1 now passes to the renderer. Leaving them at 24 made every
    // detected block letter at the wrong size until someone nudged the slider.
    if (block.lineHeight > 0) {
      result.raw['_detected_font_size'] = block.lineHeight.toDouble();
      format.raw['font_size'] = block.lineHeight.toDouble();
    }

    // ---- Orientation ----
    // A box that is clearly taller than wide held vertical Japanese, and FT
    // needs to know or it will re-letter the translation horizontally. The 1.3
    // threshold mirrors what the worker uses for its own language hint, so the
    // two agree instead of each applying a different cut-off.
    final vertical = rect.height > rect.width * 1.3;
    if (vertical) {
      result.raw['src_is_vertical'] = true;
      format.raw['vertical'] = true;
    }

    // 🔴 `det_model` stays the empty string [createDefault] wrote. Putting a
    // detector's name here would make a later re-detect pass treat this block as
    // its own output — which is how P1-3's clustering would end up rewriting
    // blocks the user had already reviewed.
    return result;
  }

  /// `#AARRGGBB` → FT's `[r, g, b]`, or null when the colour cannot be read.
  ///
  /// FT stores colours as a 3-channel list; the alpha channel has no counterpart
  /// there and is dropped deliberately (a bubble's translucency lives in
  /// `text_effects.overall_opacity`, not in the colour).
  static List<int>? _argbToFtRgb(int argb) => [
    (argb >> 16) & 0xFF,
    (argb >> 8) & 0xFF,
    argb & 0xFF,
  ];


  /// The live JSON object; mutations land here.
  final Map<String, Object?> raw;

  /// Source text lines as recognised by OCR. FT stores this as a list.
  List<String> get sourceLines {
    final list = asObjectList(raw['text']);
    if (list == null) {
      final single = raw['text'];
      return single is String ? [single] : const [];
    }
    return [for (final line in list) line?.toString() ?? ''];
  }

  /// Source text joined into one string, for display and term matching.
  String get sourceText => sourceLines.join('\n');

  /// The translated text. Empty when the block has not been translated.
  String get translation => raw['translation']?.toString() ?? '';

  set translation(String value) => raw['translation'] = value;

  /// Detected source language ('ja', 'zh', 'en', 'unknown', …).
  String get language => raw['language']?.toString() ?? 'unknown';

  bool get hasTranslation => translation.trim().isNotEmpty;

  /// Detected text layout box `[x1, y1, x2, y2]` in image pixels.
  List<double> get xyxy {
    final list = asObjectList(raw['xyxy']);
    if (list == null || list.length < 4) return const [0, 0, 0, 0];
    return [
      for (final value in list.take(4)) (value as num?)?.toDouble() ?? 0.0,
    ];
  }

  set xyxy(List<double> value) => raw['xyxy'] = value;

  /// Font size FT measured on the source glyphs, in pixels (0 when unknown).
  double get detectedFontSize =>
      (raw['_detected_font_size'] as num?)?.toDouble() ?? 0.0;

  bool get sourceIsVertical => raw['src_is_vertical'] == true;

  /// Block rotation in degrees (FT's `angle` key), 0 when absent.
  ///
  /// 🔴 Every real FT block carries `angle`, and the model had **no** accessor
  /// for it at all, so a rotated block was silently drawn axis-aligned and the
  /// property panel could not even report the value. Read-modify-write goes
  /// through [raw] like the other setters, so an untouched block never grows
  /// the key.
  double get angle => (raw['angle'] as num?)?.toDouble() ?? 0.0;

  set angle(double value) => raw['angle'] = value;

  /// Whether the block was merged from several detected lines.
  bool get merged => raw['merged'] == true;

  /// Detector that produced this block ('ctd', 'dbconvnext', …).
  String get detectionModel => raw['det_model']?.toString() ?? '';

  /// The lettering format. Null when the payload has no `fontformat` object —
  /// callers that intend to edit should use [ensureFontFormat] instead.
  FontFormat? get fontFormat {
    final map = asObjectMap(raw['fontformat']);
    if (map == null) return null;
    return FontFormat(map);
  }

  /// The lettering format, created with FT's defaults when absent.
  ///
  /// Separate from [fontFormat] so that a read-only pass never adds the key.
  FontFormat ensureFontFormat() {
    final existing = asObjectMap(raw['fontformat']);
    if (existing != null) return FontFormat(existing);
    final created = <String, Object?>{};
    raw['fontformat'] = created;
    return FontFormat(created);
  }

  /// Layout box with FT's rounding: floor the top-left, ceil the bottom-right.
  IntRect get rect {
    final box = xyxy;
    return IntRect(
      box[0].floor(),
      box[1].floor(),
      box[2].ceil(),
      box[3].ceil(),
    );
  }

  /// Converts this block into the renderer's region type.
  ///
  /// Deliberately identical to the legacy `BtProject._parseBlock`, including
  /// its rejection rules, so that routing the reader through this model cannot
  /// change what is drawn. Returns null for blocks with no translation or with
  /// a box too small to letter.
  TranslatedRegion? toTranslatedRegion() {
    final text = translation.trim();
    if (text.isEmpty) return null;
    final box = asObjectList(raw['xyxy']);
    if (box == null || box.length < 4) return null;

    final rect = IntRect(
      ((box[0] as num?)?.toDouble() ?? 0.0).floor(),
      ((box[1] as num?)?.toDouble() ?? 0.0).floor(),
      ((box[2] as num?)?.toDouble() ?? 0.0).ceil(),
      ((box[3] as num?)?.toDouble() ?? 0.0).ceil(),
    );
    if (rect.width < 4 || rect.height < 4) return null;

    final detected = raw['_detected_font_size'];
    final fontSize = detected is num && detected > 0 ? detected.round() : 0;

    var textColor = 0xFF000000;
    var backgroundColor = 0xFFFFFFFF;
    final format = fontFormat;
    if (format != null) {
      textColor = ftRgbToArgb(format.raw['frgb']) ?? textColor;
      backgroundColor = ftRgbToArgb(format.raw['srgb']) ?? backgroundColor;
    }

    return TranslatedRegion(
      rect: rect,
      text: text,
      backgroundColor: backgroundColor,
      textColor: textColor,
      lineHeight: fontSize,
      // 🔴 The whole point of P0-1: hand the renderer FT's real styling instead
      // of letting it fall back to its hard-coded `w500` / height 1.2. Before
      // this, a user's font family, weight, slant, outline, shadow, gradient,
      // alignment, letter spacing and rotation were all accepted by the studio
      // and then **silently dropped** on the way to the rendered page.
      fontStyle: format == null ? null : _regionFontStyle(format),
    );
  }

  /// Flattens FT's 32-key `fontformat` into the renderer's plain style object.
  ///
  /// Only the keys the renderer can actually honour are copied; FT's
  /// typographic ligature/`oldstyle_nums`/`text_transform` family is not
  /// expressible through Flutter's `TextStyle` and is deliberately dropped
  /// rather than faked. The mapping is intentionally **total** — every field
  /// has a value — so the renderer never has to guess.
  RegionFontStyle _regionFontStyle(FontFormat format) {
    return RegionFontStyle(
      fontFamily: format.fontFamily,
      // 🔴 `font_size` is FT's **requested** size; `_detected_font_size` (which
      // becomes `lineHeight`) is what the original lettering measured. Passing
      // the requested size as a *cap* rather than a replacement is what lets the
      // renderer still shrink-to-fit when the box is smaller than requested —
      // forcing the raw size would overflow the box.
      fontSize: format.fontSize > 0 ? format.fontSize : null,
      fontWeight: format.fontWeight,
      italic: format.italic,
      underline: format.underline,
      lineSpacing: format.lineSpacing,
      letterSpacing: format.letterSpacing,
      alignment: format.alignment,
      vertical: format.vertical,
      opacity: format.opacity,
      // FT writes a stroke effect with `width: 0` by default; treating that as
      // "no outline" is what keeps new blocks from growing a spurious border.
      strokeColor: format.hasStroke
          ? (ftRgbToArgb(format.strokeColor) ?? 0xFF000000)
          : null,
      strokeWidth: format.strokeWidth,
      shadowColor: format.shadowRadius > 0
          ? (ftRgbToArgb(format.shadowColor) ?? 0xFF000000)
          : null,
      shadowRadius: format.shadowRadius,
      shadowStrength: format.shadowStrength,
      shadowOffsetX: format.shadowOffset.isNotEmpty
          ? format.shadowOffset[0]
          : 0.0,
      shadowOffsetY: format.shadowOffset.length > 1
          ? format.shadowOffset[1]
          : 0.0,
      gradientEnabled: format.gradientEnabled,
      gradientStartColor: ftRgbToArgb(format.gradientStartColor),
      gradientEndColor: ftRgbToArgb(format.gradientEndColor),
      gradientAngle: format.gradientAngle,
      angle: angle,
      glyphSlantAngle: format.glyphSlantAngle,
    );
  }
}
