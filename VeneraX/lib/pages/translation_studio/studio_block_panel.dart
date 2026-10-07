import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'package:venera/foundation/bundled_fonts.dart';
import 'package:venera/foundation/translation_project/text_block.dart';
import 'package:venera/foundation/widget_utils.dart';
import 'package:venera/utils/translations.dart';

/// Applies a change to [block]'s JSON, wrapped by the owner into an undo step.
///
/// [syncRichText] tells the owner to regenerate the block's `rich_text` after
/// the mutation — required whenever the text or a lettering attribute changes,
/// or FT would keep rendering the old payload (P8.0 §5.2 item 1).
typedef StudioBlockEdit =
    void Function(
      String label,
      void Function(TextBlock block) mutate, {
      bool syncRichText,
    });

/// Editable property panel for one FT text block (P6 S8).
///
/// Everything here writes through [StudioBlockEdit], so each committed
/// adjustment becomes exactly one undo step. Sliders commit on
/// `onChangeEnd` (not on every pixel of travel) for the same reason.
///
/// Fields FT stores but the studio does not yet write (shadow, ligatures,
/// oldstyle numerals, `text_transform`) are shown read-only with a note, rather
/// than hidden — the honest-panel decision from P8.0 §5.2 item 3.
class StudioBlockPanel extends StatefulWidget {
  const StudioBlockPanel({
    super.key,
    required this.block,
    required this.index,
    required this.revision,
    required this.onEdit,
    this.onDelete,
  });

  final TextBlock block;

  /// 0-based index within its page's block list.
  final int index;

  /// Bumped by the owner on every model change (edit **and** undo/redo). Used to
  /// refresh the translation field when the model changes underneath it.
  final int revision;

  final StudioBlockEdit onEdit;

  final VoidCallback? onDelete;

  @override
  State<StudioBlockPanel> createState() => _StudioBlockPanelState();
}

class _StudioBlockPanelState extends State<StudioBlockPanel> {
  late final TextEditingController _controller;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.block.translation);
    _focus.addListener(() {
      if (!_focus.hasFocus) _commitTranslation();
    });
  }

  @override
  void didUpdateWidget(covariant StudioBlockPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The model changed under us (undo/redo, or a different block selected):
    // mirror it into the field unless the user is mid-edit.
    if (widget.revision != oldWidget.revision && !_focus.hasFocus) {
      final text = widget.block.translation;
      if (_controller.text != text) _controller.text = text;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commitTranslation() {
    final value = _controller.text;
    if (value == widget.block.translation) return;
    widget.onEdit(
      'Translation',
      (block) => block.translation = value,
      syncRichText: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final block = widget.block;
    final format = block.fontFormat;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Text block #@n'.tlParams({'n': widget.index + 1}),
                style: ts.s16,
              ),
            ),
            if (widget.onDelete != null)
              IconButton(
                tooltip: 'Delete block'.tl,
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: widget.onDelete,
              ),
          ],
        ),
        const SizedBox(height: 8),
        _kv('Source', block.sourceText.isEmpty ? '(empty)'.tl : block.sourceText),
        _kv('Box', block.xyxy.map((v) => v.round().toString()).join(', ')),
        const SizedBox(height: 8),
        _section('Translation'),
        const SizedBox(height: 6),
        TextField(
          controller: _controller,
          focusNode: _focus,
          minLines: 3,
          maxLines: 8,
          style: ts.s14,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            hintText: 'Type the translation…'.tl,
          ),
          onSubmitted: (_) => _commitTranslation(),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: _commitTranslation,
              icon: const Icon(Icons.check, size: 16),
              label: Text('Apply'.tl),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'one undo step'.tl,
                style: ts.s12,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const Divider(height: 28),
        if (format == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'No fontformat stored — editing creates one with FT defaults.'.tl,
              style: ts.s12.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        _section('Alignment'),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<int>(
            segments: [
              ButtonSegment(
                value: 0,
                icon: const Icon(Icons.format_align_left, size: 18),
              ),
              ButtonSegment(
                value: 1,
                icon: const Icon(Icons.format_align_center, size: 18),
              ),
              ButtonSegment(
                value: 2,
                icon: const Icon(Icons.format_align_right, size: 18),
              ),
            ],
            selected: {format?.alignment ?? FtTextAlignment.left},
            showSelectedIcon: false,
            onSelectionChanged: (selection) => widget.onEdit(
              'Alignment',
              (b) => b.ensureFontFormat().alignment = selection.first,
              syncRichText: true,
            ),
          ),
        ),
        const SizedBox(height: 16),
        _FamilyField(
          // 🔴 P1-4: show the **effective** family, not the raw `font_family`.
          // Most FT projects say "Microsoft YaHei UI", which this app does not
          // bundle — showing that would look like a missing font rather than a
          // deliberate mapping, and the user would hunt for a font that was
          // never in the build.
          value: resolveFamily(format?.fontFamily).family,
          current: format?.fontFamily ?? '',
          onChanged: (family) => widget.onEdit(
            'Font family',
            (b) => b.ensureFontFormat().fontFamily = family,
            syncRichText: true,
          ),
        ),
        _SliderField(
          label: 'Font size (px)',
          value: format?.fontSize ?? FontFormat.defaultFontSize,
          min: 6,
          max: 120,
          divisions: 114,
          onCommitted: (v) => widget.onEdit(
            'Font size',
            (b) => b.ensureFontFormat().fontSize = v,
            syncRichText: true,
          ),
        ),
        _WeightField(
          value: format?.fontWeight ?? FontFormat.defaultFontWeight,
          onChanged: (v) => widget.onEdit(
            'Font weight',
            (b) => b.ensureFontFormat().fontWeight = v,
            syncRichText: true,
          ),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text('Vertical'.tl, style: ts.s14),
          value: format?.vertical ?? block.sourceIsVertical,
          onChanged: (v) => widget.onEdit(
            'Vertical',
            (b) => b.ensureFontFormat().vertical = v,
            syncRichText: true,
          ),
        ),
        _SliderField(
          label: 'Rotation (°)',
          value: block.angle,
          min: -90,
          max: 90,
          divisions: 180,
          onCommitted: (v) => widget.onEdit('Rotation', (b) => b.angle = v),
        ),
        const Divider(height: 28),
        _section('Colour'),
        const SizedBox(height: 6),
        _ColorField(
          label: 'Fill colour',
          rgb: format?.foregroundColor ?? const [0, 0, 0],
          onCommitted: (rgb) => widget.onEdit(
            'Fill colour',
            (b) => b.ensureFontFormat().foregroundColor = rgb,
            syncRichText: true,
          ),
        ),
        const SizedBox(height: 8),
        _SliderField(
          label: 'Stroke width (px)',
          value: format?.strokeWidth ?? 0,
          min: 0,
          max: 12,
          divisions: 24,
          onCommitted: (v) => widget.onEdit(
            'Stroke width',
            (b) => b.ensureFontFormat().setStrokeWidth(v),
            syncRichText: true,
          ),
        ),
        _ColorField(
          label: 'Stroke colour',
          rgb: format?.strokeColor ?? const [0, 0, 0],
          onCommitted: (rgb) => widget.onEdit(
            'Stroke colour',
            (b) => b.ensureFontFormat().setStrokeColor(rgb),
            syncRichText: true,
          ),
        ),
        const Divider(height: 28),
        _section('Spacing'),
        const SizedBox(height: 6),
        _SliderField(
          label: 'Line spacing',
          value: format?.lineSpacing ?? FontFormat.defaultLineSpacing,
          min: 0.6,
          max: 3,
          divisions: 24,
          onCommitted: (v) => widget.onEdit(
            'Line spacing',
            (b) => b.ensureFontFormat().lineSpacing = v,
            syncRichText: true,
          ),
        ),
        _SliderField(
          label: 'Letter spacing',
          value: format?.letterSpacing ?? FontFormat.defaultLetterSpacing,
          min: 0.8,
          max: 2,
          divisions: 24,
          onCommitted: (v) => widget.onEdit(
            'Letter spacing',
            (b) => b.ensureFontFormat().raw['letter_spacing'] = v,
            syncRichText: true,
          ),
        ),
        _SliderField(
          label: 'Opacity',
          value: format?.opacity ?? 1,
          min: 0,
          max: 1,
          divisions: 20,
          onCommitted: (v) => widget.onEdit(
            'Opacity',
            (b) => b.ensureFontFormat().setOpacity(v),
            syncRichText: true,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            // 🔴 One literal. This string was two adjacent literals in S8, and
            // Dart joins them at parse time — so the lookup key was the whole
            // sentence while the i18n scan matched only the trailing fragment.
            // That is why this panel was never checked (the scan only read
            // `studio_page.dart`) and why it rendered in English for a year.
            'Read-only in S8: shadow, ligatures, old-style numerals, glyph slant, text transform. They are preserved on save.'.tl,
            style: ts.s12.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  /// 分组小标题（译文 / 对齐 / 颜色 …）。面板字段多，没有分组标题时全靠
  /// 分隔线切开，扫读很吃力。
  Widget _section(String label) => Text(
    label.tl,
    style: ts.s14.copyWith(fontWeight: FontWeight.w600),
  );

  Widget _kv(String key, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            key.tl,
            style: ts.s12.copyWith(
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(value, style: ts.s12),
        ],
      ),
    );
  }
}

/// A slider that keeps the thumb responsive while dragging and reports the
/// final value once, so a drag is a single undo step.
class _SliderField extends StatefulWidget {
  const _SliderField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onCommitted,
    this.divisions,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onCommitted;

  @override
  State<_SliderField> createState() => _SliderFieldState();
}

class _SliderFieldState extends State<_SliderField> {
  late double _value = widget.value.clamp(widget.min, widget.max).toDouble();

  @override
  void didUpdateWidget(covariant _SliderField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Model changed elsewhere (undo/redo): follow it.
    if (widget.value != oldWidget.value) {
      _value = widget.value.clamp(widget.min, widget.max).toDouble();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(widget.label.tl, style: ts.s14)),
            Text(
              widget.divisions != null
                  ? _value.round().toString()
                  : _value.toStringAsFixed(2),
              style: ts.s12,
            ),
          ],
        ),
        Slider(
          value: _value,
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          onChanged: (v) => setState(() => _value = v),
          onChangeEnd: widget.onCommitted,
        ),
      ],
    );
  }
}

/// Font family picker (S9 · P1-4, S8 leftover ⑤).
///
/// Lists the **bundled** families from `bundled_fonts.dart` — a hand-typed list
/// here would drift from `pubspec.yaml`, and the drift is silent (the item shows
/// up in the dropdown, selecting it changes nothing).
///
/// [current] is the raw `font_family` and is only used to append a
/// "not bundled" entry when the project names a face this build lacks. That
/// entry is deliberately **not** pre-selected: the effective value is [value],
/// and pretending otherwise would mean saving the mapped family over the
/// project's own name on the first unrelated edit.
class _FamilyField extends StatelessWidget {
  const _FamilyField({
    required this.value,
    required this.current,
    required this.onChanged,
  });

  /// The family actually used for rendering (after [resolveFamily]).
  final String value;

  /// The raw `font_family` from the block, possibly unbundled.
  final String current;

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final choices = fontFamilyChoices(current);
    final mapped = resolveFamily(current);
    final subtitle = mapped.fallback && current.trim().isNotEmpty
        ? 'stored as "@a", renders as @b'.tlParams({'a': current, 'b': mapped.family})
        : 'bundled with the app'.tl;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Font family'.tl, style: ts.s14)),
              // Long CJK family names must not push the panel wider than its
              // column; the row above carries the label, this carries the
              // value, so a bounded box plus ellipsis beats a layout jump.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 190),
                child: DropdownButton<String>(
                  value: value,
                  isDense: true,
                  // 🔴 No `constraints:` on the button itself: it has no such
                  // parameter (it belongs to `DropdownButtonFormField`, a
                  // different widget). The width is bounded by the
                  // `ConstrainedBox` above, which does work.
                  onChanged: (v) {
                    if (v != null) onChanged(v);
                  },
                  items: [
                    for (final choice in choices)
                      DropdownMenuItem(
                        value: choice.family,
                        child: Text(
                          choice.label,
                          overflow: TextOverflow.ellipsis,
                          style: ts.s14.copyWith(
                            color: choice.bundled
                                ? null
                                : Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          Text(
            subtitle,
            style: ts.s12.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _WeightField extends StatelessWidget {
  const _WeightField({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  static const _weights = [100, 200, 300, 400, 500, 600, 700, 800, 900];

  @override
  Widget build(BuildContext context) {
    // Snap an unknown weight to the nearest standard step so the dropdown never
    // receives a value it has no item for.
    final selected = _weights.reduce(
      (a, b) => (a - value).abs() <= (b - value).abs() ? a : b,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text('Font weight'.tl, style: ts.s14)),
          DropdownButton<int>(
            value: selected,
            isDense: true,
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
            items: [
              for (final weight in _weights)
                DropdownMenuItem(value: weight, child: Text('$weight')),
            ],
          ),
        ],
      ),
    );
  }
}

/// An RGB (FT stores `[r, g, b]`) colour editor built from three sliders plus a
/// preview. Commits the whole triple at once so one adjustment is one step.
class _ColorField extends StatefulWidget {
  const _ColorField({
    required this.label,
    required this.rgb,
    required this.onCommitted,
  });

  final String label;
  final List<int> rgb;
  final ValueChanged<List<int>> onCommitted;

  @override
  State<_ColorField> createState() => _ColorFieldState();
}

class _ColorFieldState extends State<_ColorField> {
  static const _channelNames = ['R', 'G', 'B'];

  late List<int> _rgb = _normalise(widget.rgb);

  static List<int> _normalise(List<int> rgb) => [
    for (var i = 0; i < 3; i++)
      (i < rgb.length ? rgb[i] : 0).clamp(0, 255).toInt(),
  ];

  @override
  void didUpdateWidget(covariant _ColorField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(widget.rgb, oldWidget.rgb)) {
      setState(() => _rgb = _normalise(widget.rgb));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(widget.label.tl, style: ts.s14)),
            Container(
              width: 28,
              height: 16,
              decoration: BoxDecoration(
                color: Color.fromARGB(255, _rgb[0], _rgb[1], _rgb[2]),
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ],
        ),
        for (var i = 0; i < 3; i++)
          _SliderField(
            label: _channelNames[i],
            value: _rgb[i].toDouble(),
            min: 0,
            max: 255,
            divisions: 255,
            onCommitted: (v) {
              final next = List<int>.of(_rgb);
              next[i] = v.round();
              setState(() => _rgb = next);
              widget.onCommitted(next);
            },
          ),
      ],
    );
  }
}
