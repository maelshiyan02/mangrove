// 工作室「运行自动管线」的确认弹窗（S-N2 · P10.6 §七 · P10.15 序4）。
//
// 🔴 **为什么要有这个弹窗**：`Run this page` / `Run chapter` 两个按钮此前
// 直接进 `_runPipeline` —— 整章重跑是"点一下就好几分钟 + 一整个章节的翻译
// 请求"，而这恰恰是最容易点错的按钮。更要紧的是**它此前无处可改语向**：
// 语言只能来自全局 `TranslationConfig`，为一个日文工程临时改成日语得先去
// 设置页改全局，再记得改回来。
//
// 因此本弹窗做三件事：
//
// 1. **让人在按下开始之前看清这一轮会做什么**；
// 2. **让语向 / 阶段 / 阅读方向在这个运行级别上可覆盖**；
// 3. 🔴 **算出来并明确告知**：三段（检测 / 识别 / 翻译）各自的工作量实时
//    统计，组合起来**没有输入**时直接**禁用「开始」**并给出一行原因。
//    "跑了但什么都没发生"看起来和成功一模一样，那是本项目最忌讳的一类静默。
//
// ## 🔴 本文件不碰持久化
//
// 弹窗的一切都只作用于本次运行：[StudioRunChoice] 是一份纯数据，调用方
// 拿它去构造 `StudioRunOptions`。**"记住上次选择"由 `studio_page.dart`
// 负责**（写 `appdata.settings.studioRunDefaults`，与 `TranslationConfig`
// 隔离 —— #178 就是"把为这一本临时改的语言变成全局默认"踩出来的）。
// `edit-check` 的 `wiring.dialog_does_not_persist` 每次都在核对这条边界，
// 所以这里连 `appdata` 这个词都不该出现。
//
// ## 🔴 文案纪律（P9.3 的教训）
//
// 本目录的**每一个** `'…'.tl` / `'…'.tlParams` 字面量都会被
// `edit-check` 的 `i18n.studio_tooltips_registered` 扫到并核对
// `assets/translation.json` 的 `zh_CN` 表；漏登记不会报错，只会**显示英文**
// —— 之前加按钮就反复栽在这上面。所以：
//
// * 绝不写成两个相邻字面量再对第二个调 `.tl`（Dart 在**解析期**就拼接了，
//   查表用的键是拼完的长句，而扫描匹配到的是后半截 ⇒ 扫描要求登记的键
//   与真正查表的键不是同一个，绿灯亮在英文标签上）；
// * 绝不把标签藏进扫描看不见的 `Map` 常量里 —— 那是同一种错的变体。
//   ⇒ 选项表在 `build()` 里现搭，每个标签都是**字面量挨着 `.tl`**。
//
// ## 🔴 图标
//
// 按钮/标题用的都是 Flutter **内置**图标（`Icons.play_arrow` 等），
// 不引外部图标字体：本应用的图标字体是**裁剪过的子集**，随手挑一个没进
// 子集的 codepoint 会渲染成方框（`studio_page.dart` 里 `Icons.crop` /
// `Icons.crop_outlined` 那条注释记着这件事）。
library;

import 'package:flutter/material.dart';

import 'package:mangrove/components/components.dart';
// `context.pop(value)`（`Navigation` 扩展）住在 `foundation/context.dart`；
// `components.dart` 只是自己 import 了它，**没有**把它 export 出去
// ⇒ 这里必须显式 import，否则报的错读起来像"拼错了方法名"。
import 'package:mangrove/foundation/context.dart';
import 'package:mangrove/foundation/image_translation/balloon_clustering.dart';
import 'package:mangrove/foundation/translation_project/run_plan.dart';
import 'package:mangrove/foundation/widget_utils.dart';
import 'package:mangrove/utils/translations.dart';

/// 打开确认弹窗。返回 `null` 表示用户取消（含点遮罩/返回键）——
/// 调用方必须把 `null` 当作"不要跑"，而不是"用户没说不要"。
Future<StudioRunChoice?> showStudioRunDialog({
  required BuildContext context,
  required List<String> pageKeys,
  required int initialStart,
  required int initialEnd,
  required String sourceLang,
  required String targetLang,
  required StudioRunStages stages,
  required ReadingDirection direction,
  required StudioRunCounts Function(List<String> pages) countsOf,
}) {
  if (pageKeys.isEmpty) return Future.value(null);
  return showDialog<StudioRunChoice>(
    context: context,
    builder: (_) => _StudioRunDialog(
      pageKeys: pageKeys,
      initialStart: initialStart,
      initialEnd: initialEnd,
      sourceLang: sourceLang,
      targetLang: targetLang,
      stages: stages,
      direction: direction,
      countsOf: countsOf,
    ),
  );
}

class _StudioRunDialog extends StatefulWidget {
  const _StudioRunDialog({
    required this.pageKeys,
    required this.initialStart,
    required this.initialEnd,
    required this.sourceLang,
    required this.targetLang,
    required this.stages,
    required this.direction,
    required this.countsOf,
  });

  final List<String> pageKeys;

  /// 1 起的闭区间。
  final int initialStart;
  final int initialEnd;

  final String sourceLang;
  final String targetLang;
  final StudioRunStages stages;
  final ReadingDirection direction;

  /// 统计**选中页范围内**的块数，供工作量预估使用。
  final StudioRunCounts Function(List<String> pages) countsOf;

  @override
  State<_StudioRunDialog> createState() => _StudioRunDialogState();
}

class _StudioRunDialogState extends State<_StudioRunDialog> {
  late int _start;
  late int _end;
  late final TextEditingController _startCtl;
  late final TextEditingController _endCtl;
  late String _sourceLang;
  late String _targetLang;
  late StudioRunStages _stages;
  late ReadingDirection _direction;

  int get _total => widget.pageKeys.length;

  @override
  void initState() {
    super.initState();
    _start = clampPageNumber(widget.initialStart, _total);
    _end = clampPageNumber(widget.initialEnd, _total);
    if (_start > _end) {
      final swap = _start;
      _start = _end;
      _end = swap;
    }
    _startCtl = TextEditingController(text: '$_start');
    _endCtl = TextEditingController(text: '$_end');
    _sourceLang = widget.sourceLang;
    _targetLang = widget.targetLang;
    _stages = widget.stages;
    _direction = widget.direction;
  }

  @override
  void dispose() {
    _startCtl.dispose();
    _endCtl.dispose();
    super.dispose();
  }

  /// 把两个数字框里的内容夹取回合法区间，并**写回框里**。
  ///
  /// 写回是刻意的：用户打了一个越界的页码而框里还留着那个数字，他会以为
  /// 那个数字生效了；让它立刻变成夹取后的值，"我打的 999 被改成了 94"这件事
  /// 就是看得见的。
  void _applyFields() {
    final start = clampPageNumber(_read(_startCtl, _start), _total);
    final end = clampPageNumber(_read(_endCtl, _end), _total);
    setState(() {
      if (start <= end) {
        _start = start;
        _end = end;
      } else {
        // 起止写反了：交换而不是留一个空区间（`resolvePageRange` 同一条契约）。
        _start = end;
        _end = start;
      }
      _startCtl.text = '$_start';
      _endCtl.text = '$_end';
    });
  }

  int _read(TextEditingController controller, int fallback) {
    return int.tryParse(controller.text.trim()) ?? fallback;
  }

  void _setRange(int start, int end) {
    setState(() {
      _start = start;
      _end = end;
      _startCtl.text = '$_start';
      _endCtl.text = '$_end';
    });
  }

  /// 按下「开始」时把选择打包出去。
  ///
  /// 🔴 页码**从输入框现读**，而不是用 `_start` / `_end`：用户完全可能打完
  /// 数字直接点开始（不按回车、不点别处），此时 `_start` 还是旧值 —— 拿它去
  /// 跑就是"框里写着 12、实际跑的是 3"。夹取与排序一律交给
  /// `resolvePageRange`，本方法只管读。
  void _confirm() {
    final choice = StudioRunChoice(
      pages: resolvePageRange(
        widget.pageKeys,
        _read(_startCtl, _start),
        _read(_endCtl, _end),
      ),
      sourceLang: _sourceLang,
      targetLang: _targetLang,
      stages: _stages,
      direction: _direction,
    );
    context.pop(choice);
  }

  /// 把"不能开始"的原因码翻成一句人话。
  ///
  /// 🔴 每个分支都是**字面量挨着 `.tl`** —— 这正是 i18n 扫描看得见的写法。
  String _blockedText(StudioRunBlockReason reason) {
    if (reason == noStageCode) return 'Select at least one stage.'.tl;
    if (reason == noPagesCode) return 'There are no pages in the selected range.'.tl;
    if (reason == nothingToRecognizeCode) {
      return 'Nothing to recognize: the selected pages have no blocks waiting for text.'.tl;
    }
    if (reason == nothingToTranslateCode) {
      return 'Nothing to translate: the selected pages have no blocks with source text.'.tl;
    }
    // 🔴 与上面两条**刻意不同**：这一条的正确动作是"回弹窗勾上「修图」"或
    // "去工作室核对块"，不是"去跑翻译" —— 复用翻译那条文案会把用户引到
    // 一个已经做过的事上。
    if (reason == nothingToRepairCode) {
      return 'Nothing to repair: no page in the range has a translated box yet. Translate first, or turn on repair artwork after checking the boxes.'.tl;
    }
    return 'Nothing to do: the selected pages have no matching blocks.'.tl;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 🔴 选项表在 build 里现搭：把标签写在这里，每个字面量都紧挨着 `.tl`，
    // `i18n.studio_tooltips_registered` 才扫得到它们。
    final sourceLabels = <String, String>{
      'auto': 'Auto detect'.tl,
      'ja': 'Japanese'.tl,
      'en': 'English'.tl,
      'ko': 'Korean'.tl,
      'zh': 'Chinese'.tl,
      'es': 'Spanish'.tl,
      'la': 'Latin'.tl,
    };
    final targetLabels = <String, String>{
      'zh': 'Simplified Chinese'.tl,
      'zh-TW': 'Traditional Chinese'.tl,
      'en': 'English'.tl,
      'ja': 'Japanese'.tl,
      'ko': 'Korean'.tl,
      'fr': 'French'.tl,
      'de': 'German'.tl,
      'es': 'Spanish'.tl,
      'ru': 'Russian'.tl,
      'la': 'Latin'.tl,
    };
    // 🔴 选中值必须在选项里，否则 `DropdownButton` 会断言失败（工程里存着
    // 一个没有对应项的语言码时就会这样）。刻意**在 build 里算一个局部值**
    // 而不是回写 `_sourceLang`：在 `build` 里改 state 是另一类 bug，而这里
    // 需要的只是"显示成什么"。
    final sourceValue =
        sourceLabels.containsKey(_sourceLang) ? _sourceLang : 'auto';
    final targetValue =
        targetLabels.containsKey(_targetLang) ? _targetLang : 'zh';

    final selected = resolvePageRange(widget.pageKeys, _start, _end);
    final counts = widget.countsOf(selected);
    final workload = planStudioRun(
      selectedPages: selected.length,
      detect: _stages.detect,
      recognize: _stages.recognize,
      translate: _stages.translate,
      repair: _stages.repair,
      blocks: counts.blocks,
      unrecognized: counts.unrecognized,
      untranslated: counts.untranslated,
      pagesWithTranslation: counts.translatedPages,
    );

    return ContentDialog(
      title: 'Run the pipeline'.tl,
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _section('Page range'),
              const SizedBox(height: 4),
              if (_total > 1)
                RangeSlider(
                  min: 1,
                  max: _total.toDouble(),
                  divisions: _total - 1,
                  values: RangeValues(_start.toDouble(), _end.toDouble()),
                  labels: RangeLabels('$_start', '$_end'),
                  onChanged: (values) => _setRange(
                    values.start.round(),
                    values.end.round(),
                  ),
                ),
              Row(
                children: [
                  Expanded(child: _pageField('First page', _startCtl)),
                  const SizedBox(width: 12),
                  Expanded(child: _pageField('Last page', _endCtl)),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '@a of @b pages selected'.tlParams({
                  'a': '${selected.length}',
                  'b': '$_total',
                }),
                style: ts.s12.copyWith(color: scheme.onSurfaceVariant),
              ),
              const Divider(height: 24),
              _section('Stages'),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  FilterChip(
                    label: Text('Detect'.tl),
                    selected: _stages.detect,
                    onSelected: (on) =>
                        setState(() => _stages = _stages.copyWith(detect: on)),
                  ),
                  FilterChip(
                    label: Text('Recognize'.tl),
                    selected: _stages.recognize,
                    onSelected: (on) => setState(
                      () => _stages = _stages.copyWith(recognize: on),
                    ),
                  ),
                  FilterChip(
                    label: Text('Translate'.tl),
                    selected: _stages.translate,
                    onSelected: (on) => setState(
                      () => _stages = _stages.copyWith(translate: on),
                    ),
                  ),
                  // 🔴 第四段（2026-10-09 用户修订）：抹除原文 + 填字修图。
                  //
                  // 单独一格而不是"翻译完自动做"，因为抹字**不可逆** —— 用户必须
                  // 先在前三段之后**亲眼核对文字块范围**，再决定出不出图。
                  // 所以它默认不勾，且文案要说清"这一步会抹掉原图上的字"。
                  FilterChip(
                    label: Text('Repair artwork'.tl),
                    selected: _stages.repair,
                    avatar: _stages.repair
                        ? null
                        : Icon(
                            Icons.warning_amber_rounded,
                            size: 16,
                            color: scheme.onSurfaceVariant,
                          ),
                    onSelected: (on) => setState(
                      () => _stages = _stages.copyWith(repair: on),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Stages run in order: detect, then recognize, then translate. Repair artwork erases the original lettering and draws the translation into the same boxes; it only touches the image files, so check the boxes in the studio first.'.tl,
                style: ts.s12.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              Text(
                'Detect @a pages, recognize @b blocks, translate @c items, repair @d pages'.tlParams({
                  'a': '${workload.detectPages}',
                  'b': '${workload.recognizeBlocks}',
                  'c': '${workload.translateBlocks}',
                  'd': '${workload.repairPages}',
                }),
                style: ts.s14,
              ),
              if (workload.dependsOnDetection)
                Text(
                  'The block counts are a lower bound: new blocks depend on the detection result.'.tl,
                  style: ts.s12.copyWith(color: scheme.onSurfaceVariant),
                ),
              if (!workload.canStart)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _blockedText(workload.blockedReason!),
                    style: ts.s12.copyWith(color: scheme.error),
                  ),
                ),
              const Divider(height: 24),
              _section('Languages'),
              const SizedBox(height: 4),
              _dropdownRow('Source language', sourceValue, sourceLabels,
                  (v) => setState(() => _sourceLang = v)),
              _dropdownRow('Target language', targetValue, targetLabels,
                  (v) => setState(() => _targetLang = v)),
              const Divider(height: 24),
              _section('Reading direction'),
              Wrap(
                spacing: 8,
                children: [
                  // 🔴 用 ChoiceChip 而不是 RadioListTile：一是与上面的三段
                  // 选择同一套交互（点一下就是选中，不需要额外说明），二是
                  // `RadioListTile.groupValue/onChanged` 在新 Flutter 上已废弃，
                  // 留着会在 analyze 里持续报 deprecation。
                  ChoiceChip(
                    label: Text('Right to left'.tl),
                    selected: _direction == ReadingDirection.rightToLeft,
                    onSelected: (_) => setState(
                      () => _direction = ReadingDirection.rightToLeft,
                    ),
                  ),
                  ChoiceChip(
                    label: Text('Left to right'.tl),
                    selected: _direction == ReadingDirection.leftToRight,
                    onSelected: (_) => setState(
                      () => _direction = ReadingDirection.leftToRight,
                    ),
                  ),
                  ChoiceChip(
                    label: Text('Top to bottom'.tl),
                    selected: _direction == ReadingDirection.topToBottom,
                    onSelected: (_) => setState(
                      () => _direction = ReadingDirection.topToBottom,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Right to left for Japanese manga, left to right for western page manga, top to bottom for webtoons.'.tl,
                style: ts.s12.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Text(
                'Stages, languages and reading direction are remembered for the next run. The page range is not.'.tl,
                style: ts.s12.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => context.pop(),
          child: Text('Cancel'.tl),
        ),
        FilledButton.icon(
          onPressed: workload.canStart ? _confirm : null,
          icon: const Icon(Icons.play_arrow, size: 18),
          label: Text('Start'.tl),
        ),
      ],
    );
  }

  Widget _section(String label) => Text(
    label.tl,
    style: ts.s14.copyWith(fontWeight: FontWeight.w600),
  );

  Widget _pageField(String label, TextEditingController controller) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      style: ts.s14,
      decoration: InputDecoration(
        isDense: true,
        border: const OutlineInputBorder(),
        labelText: label.tl,
      ),
      onSubmitted: (_) => _applyFields(),
      onEditingComplete: _applyFields,
      onTapOutside: (_) => _applyFields(),
    );
  }

  Widget _dropdownRow(
    String label,
    String value,
    Map<String, String> options,
    ValueChanged<String> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label.tl, style: ts.s14)),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: DropdownButton<String>(
              value: value,
              isDense: true,
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
              items: [
                for (final entry in options.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(
                      entry.value,
                      overflow: TextOverflow.ellipsis,
                      style: ts.s14,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
