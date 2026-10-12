import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'package:mangrove/foundation/bundled_fonts.dart';
import 'package:mangrove/foundation/system_fonts.dart';
import 'package:mangrove/foundation/translation_project/text_block.dart';
import 'package:mangrove/foundation/widget_utils.dart';
import 'package:mangrove/utils/translations.dart';

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
    this.onRecognise,
    this.onTranslate,
    this.onRepair,
    this.onRestoreOriginal,
    this.isCrossPage = false,
    this.onDissolveSpan,
    this.onSampleColor,
    this.busy = false,
  });

  final TextBlock block;

  /// 0-based index within its page's block list.
  final int index;

  /// Bumped by the owner on every model change (edit **and** undo/redo). Used to
  /// refresh the translation field when the model changes underneath it.
  final int revision;

  final StudioBlockEdit onEdit;

  final VoidCallback? onDelete;

  /// 【识别】—— re-run OCR on this block's own box (S-N1).
  ///
  /// 🔴 **可反复点击**，不是"建块后自动跑一次"也不是"二次识别"：用户会在
  /// 同一个块上按很多次（框歪了挪一次、换个引擎再试、看清了再确认），所以
  /// 判据在 [StudioBlockOps]，按钮本身只是把回调接上去。
  final Future<void> Function()? onRecognise;

  /// 【翻译】—— re-run translation for this block's source text (S-N1).
  final Future<void> Function()? onTranslate;

  /// 【修图】—— 只抹掉这个块覆盖区域的原字并在该框填译文。
  ///
  /// 🔴 不可逆：`inpainted/` 一写出，原图上的字已被算法抹掉。整页修图的
  /// 同一份能力，但范围收窄到当前选中的**一个块** —— 用户可以先核对块
  /// 再对这一个块跑修图，不用整页一起做。
  final Future<void> Function()? onRepair;

  /// 【复原原图】—— 把这个块已经被抹掉的像素放回原图。
  ///
  /// 🔴 这是 BT 没有的能力：用**外扩 ≥30%** 的掩膜（[buildRestorationMask]）
  /// 把 inpaint 算法改写过的周围像素一起恢复，不留糊边。调用方会确保
  /// 原图存在（重下载即可），底图和掩膜也都已落盘。
  final Future<void> Function()? onRestoreOriginal;

  /// B-5：本块带 `_span` 且跨 ≥2 页时为真 —— 显示跨页标记与【解跨页】按钮。
  final bool isCrossPage;

  /// B-5【解跨页】：块缩回顶页、尾页复原。null（非跨页块）时按钮不显示。
  final Future<void> Function()? onDissolveSpan;

  /// P33 ⑦b【从原图取色】：在该块的框内采样原图文字颜色并写进 `frgb`。
  ///
  /// 🔴 它是**异步且可能失败**（原图缺失、纯色区域取不出色）⇒ 面板只负责把
  /// 回调接上并禁用重复点击，成败由调用方用 toast 说出口，不静默。
  /// null 时按钮不显示（单页之外的上下文可能没有可用的原图）。
  final Future<void> Function()? onSampleColor;

  /// True while either action is in flight; disables both buttons so a
  /// double-click cannot launch two OCR passes on the same block.
  final bool busy;

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
        _section('Source'),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 🔴 【识别】在原文框**左侧**（用户 2026-10-08 指定的方位）。
            // 原文是只读展示，所以按钮必须自己解释"点了会发生什么" ——
            // tooltip 说清是"只重识别这一块"，而不是整页。
            if (widget.onRecognise != null)
              _ActionButton(
                icon: Icons.text_fields,
                tooltip: 'Recognise this block again'.tl,
                busy: widget.busy,
                onPressed: widget.onRecognise!,
              ),
            if (widget.onRecognise != null) const SizedBox(width: 8),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  block.sourceText.isEmpty ? '(empty)'.tl : block.sourceText,
                  style: ts.s14,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
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
            // 🔴 【翻译】在译文框**右侧**（用户 2026-10-08 指定的方位），
            // 做成 suffixIcon 而不是另起一行：它作用于**上面那个框**，
            // 挨着放才不会让人以为又是一个独立字段。
            suffixIcon: widget.onTranslate == null
                ? null
                : Padding(
                    padding: const EdgeInsets.all(4),
                    child: _ActionButton(
                      icon: Icons.translate,
                      tooltip: 'Translate this block again'.tl,
                      busy: widget.busy,
                      onPressed: widget.onTranslate!,
                    ),
                  ),
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
            const SizedBox(width: 8),
            if (widget.onRepair != null)
              _ActionButton(
                icon: Icons.auto_fix_high,
                tooltip: 'Repair this block'.tl,
                busy: widget.busy,
                onPressed: widget.onRepair!,
              ),
            if (widget.onRepair != null && widget.onRestoreOriginal != null)
              const SizedBox(width: 4),
            if (widget.onRestoreOriginal != null)
              _ActionButton(
                icon: Icons.restore,
                tooltip: 'Restore original for this block'.tl,
                busy: widget.busy,
                onPressed: widget.onRestoreOriginal!,
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'one undo step'.tl,
                style: ts.s12,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        // B-5：跨页块标记 + 解跨页。修图/复原已在 owner 侧自动按 `_span`
        // 分流（逐页做），这里额外给出"它跨页"的可见事实与拆回单页的出口。
        if (widget.isCrossPage) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.select_all,
                    size: 16, color: scheme.onTertiaryContainer),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Cross-page block'.tl,
                    style: ts.s12.copyWith(
                      color: scheme.onTertiaryContainer,
                    ),
                  ),
                ),
                if (widget.onDissolveSpan != null)
                  TextButton.icon(
                    onPressed:
                        widget.busy ? null : () => widget.onDissolveSpan!(),
                    icon: const Icon(Icons.call_split, size: 16),
                    label: Text('Split back to one page'.tl),
                  ),
              ],
            ),
          ),
        ],
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
            // P32：无 FontFormat 时面板高亮 **center** —— 与 FontFormat 的
            // 默认对齐及双端居中渲染一致（旧值 fallback left 与实际默认相反）。
            selected: {format?.alignment ?? FtTextAlignment.center},
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
          // P33 ⑦b：这个色是"从原图取的"还是"用户定的"。两种来源在界面上
          // 长得一模一样的话，用户无法判断重新识别会不会把自己的调色冲掉。
          auto: widget.block.colorIsAuto,
          onSampleFromArt: widget.onSampleColor,
          busy: widget.busy,
          // 🔴 手动改色的**同时**把自动标记摘掉：否则下一次识别会把它覆盖回
          // 取样值 —— 表现为"我调好的字色自己变回去了"。
          onCommitted: (rgb) => widget.onEdit(
            'Fill colour',
            (b) {
              b.ensureFontFormat().foregroundColor = rgb;
              b.colorIsAuto = false;
            },
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

/// 【识别】/【翻译】共用的按钮：一个内置图标 + 一个 tooltip。
///
/// 🔴 刻意**不**用 `FilledButton.icon`：那会在面板里塞一条带文字的长按钮，
/// 把原文/译文两个框挤到换行。图标是 Flutter 内置的 `Icons.*`，不新增依赖，
/// 也不需要在 `pubspec` 里登记字体资源。
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.busy,
  });

  final IconData icon;
  final String tooltip;
  final Future<void> Function() onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        // 🔴 busy 时显示转圈：这两个动作都要跑推理引擎（数秒到几十秒），
        // 而按钮变小/变灰在 Windows 上很难被注意到，用户于是连点三次。
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon, size: 20),
        onPressed: busy ? null : () => unawaited(onPressed()),
        visualDensity: VisualDensity.compact,
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

/// P33：[family] 是机器里装着的字体（而不是打包字体）。
///
/// 判据直接查系统字体表，不靠 `resolveFamily(...).fallback` —— 那个字段把
/// 「系统字体」与「打包字体」都记成 `fallback: false`，区分不了。
bool _isSystemFamily(String? family) => systemFonts.has(family);

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
    // P33：三档来源要有三行不同的说明，否则"系统里装的"与"被打回兜底字体的"
    // 在界面上长得一模一样，而这两件事对用户意味着完全不同的风险。
    final subtitle = mapped.fallback && current.trim().isNotEmpty
        ? 'stored as "@a", renders as @b'.tlParams({'a': current, 'b': mapped.family})
        : _isSystemFamily(current)
            ? 'installed on this machine'.tl
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
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                choice.label,
                                overflow: TextOverflow.ellipsis,
                                style: ts.s14,
                              ),
                            ),
                            // P33：打包字体与系统字体在下拉里要能一眼分开 ——
                            // 前者任何机器都有，后者换台机器可能就缺字。
                            const SizedBox(width: 6),
                            Text(
                              choice.bundled ? '· app' : '· system',
                              style: ts.s10.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
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
    this.auto = false,
    this.onSampleFromArt,
    this.busy = false,
  });

  final String label;
  final List<int> rgb;
  final ValueChanged<List<int>> onCommitted;

  /// P33 ⑦b：True = 这个色是上次从原图取出来的，重新识别可以覆盖它。
  final bool auto;

  /// P33 ⑦b【从原图取色】。null 时不显示该按钮。
  final Future<void> Function()? onSampleFromArt;

  final bool busy;

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
    final scheme = Theme.of(context).colorScheme;
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
        // P33 ⑦b：来源要写出来。"自动"意味着下次识别会更新它，"手动"意味着
        // 我们保证不动它 —— 这两件事对用户是**完全不同的承诺**，不能靠色块
        // 自己去猜。
        if (widget.auto || widget.onSampleFromArt != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.auto
                        ? 'auto — sampled from the original art'.tl
                        : 'manual — kept across re-recognition'.tl,
                    style: ts.s10.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                if (widget.onSampleFromArt != null)
                  SizedBox(
                    height: 26,
                    child: TextButton(
                      onPressed: widget.busy ? null : widget.onSampleFromArt,
                      child: Text('Re-sample'.tl, style: ts.s10),
                    ),
                  ),
              ],
            ),
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
