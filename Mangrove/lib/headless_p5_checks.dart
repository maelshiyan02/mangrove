// 「运行确认弹窗」（S-N2 · P10.6 §七 S-N2）的断言集。
//
// 覆盖两件事：
//
// * **`resolvePageRange` / `clampPageNumber`** —— 弹窗里选的页码区间到底换算成
//   哪几页。这是本项唯一一处"算错了也不报错"的地方：算大了就是把整章重跑一遍
//   （几分钟 + 一整章的翻译请求），算小了就是"点了开始什么都没发生"。
// * **接线与文案** —— 两个入口确实先弹窗、弹窗确实覆盖了语向、弹窗文件确实
//   在 i18n 扫描的目录里、且它自己的字面量确实都登记了中文。
//
// ## 反向验证
//
// 与 P3 / P4 同源（见 `kb/methodology/M08`）：故障在**运行时**注入 —— 同一个
// 判据跑两遍，正确输入必须 true、故意做错必须 false。一次构建验完全部断言。
// 静态扫描类断言的"做错"用**对照组**实现（拿一个确实含有该特征的**别的**文件
// 去跑同一条判据），因为「拿一个不存在的字符串去搜」证明不了判据不是恒真。
//
// ## 这里测不到的
//
// 🔴 弹窗的**布局**（RangeSlider 拖起来顺不顺、下拉在窄屏会不会挤）需要 GUI
// 看。本文件只能证明"选择被正确算出来并被带下去了"。
library;

import 'dart:convert';
import 'dart:io';

// `ReadingDirection` 住在 `balloon_clustering.dart`，而 `run_plan.dart` 只是
// **import** 它、没有 export ⇒ 这里必须显式 import，否则报的错读起来像
// "拼错了枚举名"。
import 'package:mangrove/foundation/image_translation/balloon_clustering.dart';
import 'package:mangrove/foundation/translation_project/run_plan.dart';
import 'package:mangrove/headless_p1_checks.dart' show CheckSink, tlLiteralKeys;

/// 一条断言：绿路径 + 故障路径 + 可诊断的 detail。
class _Probe {
  const _Probe(this.name, this.green, this.red, this.detail);

  final String name;
  final Future<bool> Function() green;
  final Future<bool> Function() red;
  final String Function() detail;
}

const _dialogPath = 'lib/pages/translation_studio/run_dialog.dart';
const _studioPath = 'lib/pages/translation_studio/studio_page.dart';

/// 跑完「运行确认弹窗」的全部断言。
Future<void> runP5Checks(
  CheckSink check, {
  required Directory packageRoot,
}) async {
  // 94 页，与主验证素材 `MDGH-ch1` 同规模；页 key 用 FT 的
  // `<章节目录>/<页>.png` 形状，好让越界/顺序类断言读起来就是这个工程。
  final pages = [for (var i = 1; i <= 94; i++) '0/$i.webp'];
  final probes = <_Probe>[];
  void probe(
    String name,
    Future<bool> Function() green,
    Future<bool> Function() red,
    String Function() detail,
  ) {
    probes.add(_Probe(name, green, red, detail));
  }

  bool sameKeys(List<String> a, List<String> b) =>
      a.length == b.length && a.join('|') == b.join('|');

  // ── 1 · 页码范围 ──────────────────────────────────────────────────────

  probe(
    'range.subset_is_exact_slice',
    () async => sameKeys(resolvePageRange(pages, 10, 12), pages.sublist(9, 12)),
    // 故障路径 = 按 **0 起** 算的期望值。差一是这里唯一真实的 bug 类型，
    // 所以拿它当反面：同一个判据必须变红。
    () async => sameKeys(resolvePageRange(pages, 10, 12), pages.sublist(8, 11)),
    () => '绿=区间 10..12 取第 10/11/12 页（1 起） / 故障=按 0 起算会差一页',
  );

  probe(
    'range.clamps_high_bound',
    () async => resolvePageRange(pages, 90, 9999).length == 5,
    () async => resolvePageRange(pages, 90, 9999).length == pages.length,
    () => '绿=上界越界夹到末页（90..94 = 5 页） / 故障=静默塌成整章',
  );

  probe(
    'range.clamps_low_bound',
    () async => resolvePageRange(pages, 0, 0).length == 1,
    () async => resolvePageRange(pages, -5, -1).length == pages.length,
    () => '绿=0 夹到第 1 页（1 页） / 故障=负数区间塌成整章',
  );

  probe(
    'range.reversed_input_is_swapped',
    () async => sameKeys(resolvePageRange(pages, 12, 10), pages.sublist(9, 12)),
    // 故障路径 = 倒序返回空。用户点了开始却什么都没跑，而且**没有任何提示**。
    () async => resolvePageRange(pages, 12, 10).isEmpty,
    () => '绿=倒序 12..10 交换成 10..12 / 故障=返回空区间（静默什么都不做）',
  );

  probe(
    'range.never_becomes_whole_chapter',
    () async => resolvePageRange(pages, 3, 5).length == 3,
    () async => resolvePageRange(pages, 3, 5).length == pages.length,
    () => '🔴 绿=3..5 只跑 3 页 / 故障=扩大成整章 —— '
        '`resumePages`（studio_pipeline.dart）踩过的同型坑：'
        '"没看懂就全跑"会让一次点击变成几分钟的重跑',
  );

  probe(
    'range.empty_page_set_is_empty',
    () async => resolvePageRange(const [], 1, 5).isEmpty,
    () async => resolvePageRange(pages, 1, 5).isEmpty,
    () => '绿=空页集→空区间（唯一合法的空） / 故障=有页时不该是空',
  );

  probe(
    'range.single_page_is_that_page',
    () async => sameKeys(resolvePageRange(pages, 7, 7), [pages[6]]),
    () async => sameKeys(resolvePageRange(pages, 7, 7), [pages[5]]),
    () => '绿="本页"入口只选中该页 / 故障=选了隔壁页',
  );

  probe(
    'range.full_chapter_keeps_project_order',
    () async => sameKeys(resolvePageRange(pages, 1, 94), pages),
    // 故障路径 = 交换边界时把**内容**也翻了。差一/翻序都会让产物张数对不上，
    // 而顺序错了在画布上更难发现（页还是那几页，只是顺序不对）。
    () async =>
        sameKeys(resolvePageRange(pages, 94, 1), pages.reversed.toList()),
    () => '绿=1..94 = 工程原序 / 故障=倒序入参把内容顺序也翻过来',
  );

  // ── 2 · 选择对象 ──────────────────────────────────────────────────────

  StudioRunChoice makeChoice({String sourceLang = 'ja'}) {
    return StudioRunChoice(
      pages: resolvePageRange(pages, 3, 5),
      sourceLang: sourceLang,
      targetLang: 'zh',
      // 三段刻意**不全开**：全开时 `detect`/`recognize`/`translate` 三个
      // getter 都是 true，`carries` 里任何一个写错了都测不出来。
      stages: const StudioRunStages(
        detect: false,
        recognize: true,
        translate: false,
      ),
      direction: ReadingDirection.leftToRight,
    );
  }

  bool carries({String sourceLang = 'ja'}) {
    final c = makeChoice(sourceLang: sourceLang);
    return c.sourceLang == 'ja' &&
        c.targetLang == 'zh' &&
        !c.detect &&
        c.recognize &&
        !c.translate &&
        c.direction == ReadingDirection.leftToRight &&
        c.pages.length == 3;
  }

  probe(
    'choice.carries_every_field',
    () async => carries(),
    // 故障路径 = 换个 sourceLang 建对象，判据必须变红。否则这条是装饰品：
    // "字段被带出来"这件事只有在一个**不同的**输入会把它打红时才被证明。
    () async => carries(sourceLang: 'en'),
    () => '绿=语向/三段/方向/页码原样带出 / 故障=sourceLang 变了判据也变红',
  );

  // ── 2b · 三段工作量与「开始」按钮（P10.15 §4.3 / P3 选项①） ─────────────
  //
  // 这一组测的是**唯一的**"该不该放行"判据（`planStudioRun`）。它存在的理由
  // 是项目硬规矩 3：绝不能"跑了但什么都没发生"却看起来像成功。每条的故障
  // 路径都拿**同一条判据**去跑一个相反的场景，证明它不是恒真。

  probe(
    'workload.no_stage_blocks_start',
    () async =>
        !planStudioRun(
          selectedPages: 5,
          detect: false,
          recognize: false,
          translate: false,
          blocks: 40,
          unrecognized: 0,
          untranslated: 0,
        ).canStart,
    // 反场景 = 三段全开。若判据恒真（什么都禁），这条会变 true。
    () async =>
        !planStudioRun(
          selectedPages: 5,
          detect: true,
          recognize: true,
          translate: true,
          blocks: 40,
          unrecognized: 0,
          untranslated: 0,
        ).canStart,
    () => '绿=三段全关 → 禁用开始 / 故障=连三段全开也禁用（判据恒真）',
  );

  probe(
    'workload.detect_runs_on_blank_pages',
    () async =>
        planStudioRun(
          selectedPages: 3,
          detect: true,
          recognize: true,
          translate: false,
          // 一片空白页：工程里一个块都没有。这正是首次检测的正常起点。
          blocks: 0,
          unrecognized: 0,
          untranslated: 0,
        ).canStart,
    // 反场景 = 不勾检测、只勾识别、且工程没有块 ⇒ 必须被拦。
    // 只证明"检测能开始"不够 —— 还得证明这条判据不会对**所有**输入放行。
    () async =>
        planStudioRun(
          selectedPages: 3,
          detect: false,
          recognize: true,
          translate: false,
          blocks: 0,
          unrecognized: 0,
          untranslated: 0,
        ).canStart,
    () => '🔴 绿=空白页也能开始检测 / 故障=拿"当前 0 块"去禁用 —— '
        '那会让"对新工程做首次检测"这个最正常的用法按不了（§4.3）',
  );

  probe(
    'workload.recognize_without_blocks_blocks',
    () async =>
        planStudioRun(
          selectedPages: 3,
          detect: false,
          recognize: true,
          translate: false,
          blocks: 0,
          unrecognized: 0,
          untranslated: 0,
        ).blockedReason ==
        nothingToRecognizeCode,
    // 反场景 = 页上确实有 4 个还没认字的块。同一个不等式必须为假。
    () async =>
        planStudioRun(
          selectedPages: 3,
          detect: false,
          recognize: true,
          translate: false,
          blocks: 4,
          unrecognized: 4,
          untranslated: 0,
        ).blockedReason ==
        nothingToRecognizeCode,
    () => '绿=只勾识别但工程没有块 → 理由码 nothing-to-recognize / '
        '故障=有 4 个待识别块也报同一个理由码',
  );

  probe(
    'workload.translate_without_source_blocks',
    () async =>
        planStudioRun(
          selectedPages: 3,
          detect: false,
          recognize: false,
          translate: true,
          blocks: 9,
          // 9 个块**全都**没有原文 ⇒ 翻译阶段无输入。
          unrecognized: 9,
          untranslated: 0,
        ).blockedReason ==
        nothingToTranslateCode,
    // 反场景 = 9 个块都有原文、都还没译文。同一个等式必须为假。
    () async =>
        planStudioRun(
          selectedPages: 3,
          detect: false,
          recognize: false,
          translate: true,
          blocks: 9,
          unrecognized: 0,
          untranslated: 9,
        ).blockedReason ==
        nothingToTranslateCode,
    () => '绿=只勾翻译但所有块都没有原文 → 理由码 nothing-to-translate / '
        '故障=有 9 条可翻却报同一个理由码',
  );

  probe(
    'workload.counts_are_clamped_never_thrown',
    () async {
      // 统计口径错（unrecognized / untranslated 超过 blocks）时**夹取**而不是
      // 抛异常：这是弹窗里的实时预览，抛异常等于"打开弹窗就崩"。
      final w = planStudioRun(
        selectedPages: 2,
        detect: false,
        recognize: true,
        translate: true,
        blocks: 3,
        unrecognized: 99,
        untranslated: 99,
      );
      // 识别 = 夹取后的 3；翻译 = 夹取后的 3 条未译 + 3 条将被识别的 = 6。
      return w.recognizeBlocks == 3 && w.translateBlocks == 6;
    },
    () async =>
        planStudioRun(
          selectedPages: 2,
          detect: false,
          recognize: true,
          translate: true,
          blocks: 3,
          unrecognized: 99,
          untranslated: 99,
        ).recognizeBlocks ==
        99,
    () => '绿=越界计数被夹到 blocks 之内 / 故障=原样透出'
        '（界面会报"识别 99 块"，而工程里一共只有 3 块）',
  );

  probe(
    'workload.detect_marks_the_counts_as_a_lower_bound',
    () async =>
        planStudioRun(
          selectedPages: 4,
          detect: true,
          recognize: true,
          translate: true,
          blocks: 7,
          unrecognized: 5,
          untranslated: 2,
        ).dependsOnDetection,
    // 反场景 = 不勾检测。此时块数是**精确值**，不该标"下界"。
    () async =>
        planStudioRun(
          selectedPages: 4,
          detect: false,
          recognize: true,
          translate: true,
          blocks: 7,
          unrecognized: 5,
          untranslated: 2,
        ).dependsOnDetection,
    () => '绿=检测+识别一起勾时标记"块数只是下界"（新块数取决于检测结果）/ '
        '故障=不勾检测也标下界（把精确值说成估计值）',
  );

  probe(
    'workload.translate_only_does_not_promise_recognition',
    () async {
      // 只勾翻译时**不能**把"待识别的块"算进翻译量：那些块没有原文，
      // 翻译阶段对它们无事可做（`_runBlockStages` 只翻有原文的块）。
      final w = planStudioRun(
        selectedPages: 1,
        detect: false,
        recognize: false,
        translate: true,
        blocks: 5,
        unrecognized: 5,
        untranslated: 0,
      );
      return w.translateBlocks == 0 && w.detectPages == 0;
    },
    () async {
      final w = planStudioRun(
        selectedPages: 1,
        detect: false,
        recognize: true,
        translate: true,
        blocks: 5,
        unrecognized: 5,
        untranslated: 0,
      );
      // 反场景 = 同时勾识别：此时那 5 块会被识别后再翻 ⇒ 翻译量是 5 而不是 0。
      return w.translateBlocks == 0;
    },
    () => '绿=只勾翻译时"翻译 0 条"（无原文可翻）/ '
        '故障=把待识别块也算成翻译量（界面报 5 条，实际一条都没翻）',
  );

  probe(
    'direction.roundtrips_through_its_name',
    () async {
      // §4.4：三个值（右起 / 左起 / 纵向）。少一个就说明三分没做完 ——
      // 条漫会退回"左起"，界面上看不出任何异常。
      if (ReadingDirection.values.length != 3) return false;
      for (final d in ReadingDirection.values) {
        if (readingDirectionFromName(readingDirectionName(d)) != d) {
          return false;
        }
      }
      return true;
    },
    // 故障路径 = 一个**不存在的**方向名。它必须回落到 null（"存储里没有
    // 可用的值"），而不是被当成某个方向 —— 后者会让一份手改坏的
    // `appdata.json` 静默改变聚类方向。
    () async => readingDirectionFromName('sideways') != null,
    () => '绿=三个方向各自 name 往返恒等 / '
        '故障=未知名字被当成某个方向（存储写坏会静默改方向）',
  );

  probe(
    'direction.top_to_bottom_is_offered',
    () async =>
        readingDirectionFromName('topToBottom') == ReadingDirection.topToBottom,
    // 反场景 = 拼写近似的另一个名字。`topToBottom` 必须**精确**匹配，模糊
    // 匹配（比如前缀匹配）会把别的值也吞进来。
    () async =>
        readingDirectionFromName('topToBottomX') != null,
    () => '绿=topToBottom 可往返（条漫不再被静默当成左起）/ '
        '故障=相似名字也能命中（匹配过宽）',
  );

  // ── 3 · 接线（静态扫描，防"改回去了"） ─────────────────────────────────

  bool codeHas(String relPath, String needle) {
    final file = File('${packageRoot.path}/$relPath');
    if (!file.existsSync()) return false;
    final source = file
        .readAsStringSync()
        .replaceAll(RegExp(r'//.*$', multiLine: true), '')
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    return source.contains(needle);
  }

  probe(
    'wiring.studio_opens_confirmation_dialog',
    () async => codeHas(_studioPath, 'showStudioRunDialog('),
    () async => codeHas(_studioPath, '__never_opened_a_dialog__('),
    () => '两个运行入口必须先弹确认窗（此前直进 `_runPipeline`）',
  );

  probe(
    'wiring.run_choice_overrides_languages',
    () async => codeHas(_studioPath, '_runSourceLang ?? '),
    () async => codeHas(_studioPath, '__never_override__ ?? '),
    () => '弹窗选的语向必须真的覆盖到 `StudioRunOptions`（缺这一行弹窗就是摆设）',
  );

  probe(
    'wiring.dialog_lives_in_scanned_dir',
    // 🔴 i18n 扫描按**目录**扫 `lib/pages/translation_studio/`。把弹窗放到别处，
    // 它就不会被核对 —— 而漏核对不报错，只显示英文，正是 P1-4 之前的假绿。
    () async =>
        File('${packageRoot.path}/$_dialogPath').existsSync(),
    () async => File('${packageRoot.path}/lib/pages/run_dialog.dart').existsSync(),
    () => '弹窗必须落在 i18n 扫描覆盖的目录里',
  );

  probe(
    'wiring.dialog_does_not_persist',
    // 弹窗的选择只作用于本次运行：文件里不该出现任何持久化设置。
    () async => !codeHas(_dialogPath, 'appdata'),
    // 🔴 故障路径用**对照组**：拿一个确实读写持久化设置的文件去跑同一条判据。
    // 「搜一个不存在的字符串」证明不了判据不是恒真，对照组才证明得了。
    () async => !codeHas('lib/pages/settings/reader.dart', 'appdata'),
    () => '绿=弹窗不碰持久化设置 / 故障=对照组（设置页）确实含 appdata ⇒ 判据非恒真',
  );

  // ── 3b · 第四段「修图」与"产物只能由显式选择触发"（2026-10-09） ─────────
  //
  // 钉的是用户的两条原话：
  // ①「拒绝在运行对整个章节进行自动化之后再莫名其妙的使用一次产物生成」
  // ②「不希望自动抹除原文后修图，希望自动化管线之后人工修正文字块范围再修图」
  //
  // ⇒ 契约是：`mask/` `inpainted/` `result/` 的产出**只能**由 [repair] 那一段
  // 或显式的「保存并修图」触发；Ctrl+S 只写 JSON。

  probe(
    'stages.repair_defaults_to_off',
    () async =>
        // 从持久化值还原（默认路径）时 repair 必须是 false。
        StudioRunStages.fromJson({'detect': true, 'recognize': true,
            'translate': true}).repair ==
            false &&
        // 显式不给参数构造时也必须是 false。
        const StudioRunStages(detect: true, recognize: true, translate: true)
            .repair ==
            false &&
        // 而且 `producesArtifacts` 跟着它走。
        !const StudioRunStages(detect: true, recognize: true, translate: true)
            .producesArtifacts,
    // 故障路径 = 「修图默认开」那一版。症状：用户跑完检测+识别+翻译，
    // 原图上的字**已经被抹掉了**，而他还没机会看一眼块的范围。
    () async =>
        StudioRunStages.fromJson({
          'detect': true,
          'recognize': true,
          'translate': true,
        }).repair ==
            true,
    () => '绿=修图默认关闭（旧记录读出来也是 false）/ '
        '故障=默认开着就把"人工核对块"这一步跳过了',
  );

  probe(
    'stages.old_record_does_not_silently_restore_auto_repair',
    () async =>
        // 🔴 旧记录**没有** repair 键。它必须读成 false，而不是"跟着 translate 开"。
        StudioRunStages.fromJson({'translate': true}).repair == false,
    // 故障路径 = 把缺失的 repair 解释成"跟着 translate"（迁移时最容易犯的
    // "向后兼容"）。那等于把用户刚取消的自动出图**又悄悄恢复**，且没人会知道。
    () async =>
        StudioRunStages.fromJson({'translate': true}).repair == true,
    () => '绿=旧记录读出 repair=false / 故障=缺失键被补成 true 会复活自动出图',
  );

  probe(
    'workload.repair_alone_needs_something_to_draw',
    () async =>
        // 只勾修图、且一页译文都没有 ⇒ 必须拦下（画出来是去字白页）。
        planStudioRun(
          selectedPages: 5,
          detect: false,
          recognize: false,
          translate: false,
          repair: true,
          blocks: 0,
          unrecognized: 0,
          untranslated: 0,
          pagesWithTranslation: 0,
        ).blockedReason ==
            nothingToRepairCode,
    // 反场景 = 同一段但工程里已有 3 页译文 ⇒ 必须放行。
    // 🔴 这一支不能省：只钉"会拦"的话，一个恒返回 `nothingToRepairCode` 的
    // 实现也能通过 —— 而那会让「修图」永远按不动。
    () async =>
        planStudioRun(
          selectedPages: 5,
          detect: false,
          recognize: false,
          translate: false,
          repair: true,
          blocks: 24,
          unrecognized: 0,
          untranslated: 0,
          pagesWithTranslation: 3,
        ).blockedReason ==
            nothingToRepairCode,
    () => '绿=没译文时拦下 / 故障=恒拦时「修图」永远按不动（判据恒真）',
  );

  probe(
    'workload.repair_counts_pages_not_blocks',
    () async =>
        // 8 个译文块分布在 3 页上 ⇒ 报 3 页，不是 8。
        planStudioRun(
          selectedPages: 5,
          detect: false,
          recognize: false,
          translate: false,
          repair: true,
          blocks: 24,
          unrecognized: 0,
          untranslated: 0,
          pagesWithTranslation: 3,
        ).repairPages ==
            3,
    // 故障路径 = 按块计数那一版。`inpainted/` 是**按页**落的文件，报 8 会让
    // 用户以为要等 8 倍的时间，或者干脆不敢点。
    () async =>
        planStudioRun(
          selectedPages: 5,
          detect: false,
          recognize: false,
          translate: false,
          repair: true,
          blocks: 24,
          unrecognized: 0,
          untranslated: 0,
          pagesWithTranslation: 3,
        ).repairPages ==
            24,
    () => '绿=修图按页报（3 页） / 故障=按块报（24）会把等待时间虚报 8 倍',
  );

  probe(
    'wiring.save_does_not_spawn_artifact_generation',
    // 🔴 钉用户原话①：保存**不得**顺带出图。
    // 判据 = `_save` 的方法体里不再有 `_regenerateResults`。
    //
    // 🔴 边界怎么切：`_ComicPageState` 的成员一律缩进 **2 空格**，所以方法体
    // 结束于下一个 `  Future<` / `  void ` / … 那一行。
    // ⚠️ 坑：`Future<void>` 里 `Future` 后面是 `<` **不是空格** —— 早先写成
    // `\n  (Future|void|...) ` 的正则匹配不到，边界退化成"整个文件末尾"，
    // 于是 `_saveAndRepair` 里的那一句被算进了 `_save`，绿路径直接判 FALSE。
    // 这条断言本身把"判据写错"和"行为没改"混成了同一个失败，值得单独记一笔。
    () async => _saveBodySpansRegenerateResults(packageRoot),
    // 故障路径 = 任何"保存即出图"的形态：`unawaited(_regenerateResults(`、
    // 直接调用、间接回调，只要它回到 `_save` 里就判红。
    () async => _saveBodyCallsRegenerateResults(packageRoot),
    () => '绿=Ctrl+S 只写 JSON / 故障=保存又顺带出图（用户明确拒绝的那件事）',
  );

  probe(
    'wiring.the_regenerate_all_entry_is_gone',
    // 「重新生成全部产物」这个**入口**必须不存在（用户原话：「暂时不需要这个功能」）。
    // 判据扫全文件：方法名、菜单项、弹窗标题三处都不许有。
    () async {
      final file = File('${packageRoot.path}/$_studioPath');
      if (!file.existsSync()) return false;
      final source = file.readAsStringSync();
      return !source.contains('_regenerateAllArtifacts') &&
          !source.contains('Regenerate all artifacts');
    },
    // 故障路径 = 入口还在（哪怕只是把按钮藏起来）。
    () async => codeHas(_studioPath, '_regenerateAllArtifacts'),
    () => '绿=全量重生成入口已删 / 故障=入口还在（哪怕只是隐藏）',
  );

  probe(
    'wiring.repair_is_the_only_producer_of_artifacts',
    // 🔴 2026-10-09 续：用户决定删「保存并修图」按钮，出图只剩**一条**入口 ——
    // 运行弹窗勾了「修图」这一段。判据 = 段内入口存在 + 工具栏入口已删干净。
    () async =>
        codeHas(_studioPath, 'stages.repair') &&
        !codeHas(_studioPath, '_saveAndRepair'),
    // 故障路径 = 段内入口丢了（不出图），或工具栏入口又回来了（多一条路）。
    () async =>
        !codeHas(_studioPath, 'stages.repair') ||
        codeHas(_studioPath, '_saveAndRepair'),
    () => '绿=段内入口存在 + 工具栏入口已删 / 故障=段内入口丢了 或 工具栏入口又回来了',
  );

  // ── 4 · 文案（P9.3 的教训：漏登记不报错，只显示英文） ──────────────────

  /// 扫出 [relPath] 里**未登记 zh_CN** 的 `.tl` / `.tlParams` 字面量。
  ///
  /// 正则来自 `headless_p1_checks.dart::tlLiteralKeys` —— 与 `headless.dart`
  /// 的目录扫描**同一份实现**（复制三份就是三次独立漂移的机会）。
  List<String> unregistered(String relPath, Map<String, dynamic> zhCn) {
    final file = File('${packageRoot.path}/$relPath');
    if (!file.existsSync()) return const ['<file missing>'];
    final found = <String>[];
    for (final key in tlLiteralKeys(file.readAsStringSync())) {
      if (key.isEmpty || key.length <= 2) continue;
      if (!zhCn.containsKey(key) && !found.contains(key)) found.add(key);
    }
    return found;
  }

  List<String> tlLiterals(String relPath) {
    final file = File('${packageRoot.path}/$relPath');
    if (!file.existsSync()) return const [];
    return [
      for (final key in tlLiteralKeys(file.readAsStringSync()))
        if (key.isNotEmpty) key,
    ];
  }

  final tableFile = File('${packageRoot.path}/assets/translation.json');
  final zhCn = tableFile.existsSync()
      ? (jsonDecode(tableFile.readAsStringSync())
          as Map<String, dynamic>)['zh_CN'] as Map<String, dynamic>
      : <String, dynamic>{};

  probe(
    'i18n.dialog_strings_registered',
    () async => unregistered(_dialogPath, zhCn).isEmpty,
    // 🔴 故障路径同样是**对照组**：`studio_page.dart` 是**已经**全部登记过的
    // 文件（`i18n.studio_tooltips_registered` 每次 edit-check 都在核对它），
    // 所以同一条判据在它身上必须为 false —— 否则说明判据恒真。
    () async => unregistered(_studioPath, zhCn).isNotEmpty,
    () => '绿=弹窗的字面量全部有 zh_CN 条目 / 故障=对照组（已登记页）也被判缺 '
        '| 缺: ${unregistered(_dialogPath, zhCn).join(", ")}',
  );

  probe(
    'i18n.scan_actually_sees_the_dialog',
    // 🔴 空结果判 FAIL：正则改坏 / 文件挪走都会让上面那条**静默通过**
    // （"一个都没扫到"不是"全都登记了"）。所以必须另外钉住"确实扫到了一堆"。
    () async => tlLiterals(_dialogPath).length >= 10,
    () async => tlLiterals(_dialogPath).isEmpty,
    () => '绿=扫描在弹窗里扫到 ${tlLiterals(_dialogPath).length} 条字面量 / '
        '故障=0 条（说明扫描根本没看到这个文件）',
  );

  // ── 跑 ────────────────────────────────────────────────────────────────

  for (final item in probes) {
    bool green;
    bool red;
    String err = '';
    try {
      green = await item.green();
    } catch (e) {
      green = false;
      err = 'green threw: $e';
    }
    try {
      red = await item.red();
    } catch (e) {
      // 故障路径抛异常 ≠ 断言变红。异常只说明夹具炸了，不能算"验证通过"。
      red = true;
      err = '${err.isEmpty ? '' : '$err | '}red threw: $e';
    }
    final verdict = green && !red;
    check(
      'run.${item.name}',
      verdict,
      '${item.detail()} | 绿路径=${green ? 'true' : 'FALSE'} '
      '故障路径=${red ? '仍绿(装饰品)' : '变红'}${err.isEmpty ? '' : ' | $err'}',
    );
  }
}

// ── 「保存不得顺带出图」的判据工具（2026-10-09） ───────────────────────────
//
// 🔴 为什么要单独抽成函数：这条断言的**难点不在语义**（`_save` 里不该出现
// `_regenerateResults`），而在**方法体边界怎么切**。第一版把边界正则写成
// `\n  (Future|void|Widget|String|bool) ` —— 而下一行是
// `  Future<void> _saveAndRepair()`，`Future` 后面紧跟 `<` 而**不是空格**，
// 于是正则匹配不到，边界退化成"整个文件末尾"，`_saveAndRepair` 里的那一句
// 被算进了 `_save`，绿路径直接判 FALSE。
//
// 教训值得单独记：那条断言把"判据写错了"和"行为没改"报成**同一个失败**，
// 于是我第一反应是去改代码而不是改判据 —— 而真因在判据。
//⇒ 这里的正则必须能匹配泛型返回类型。

/// `_ComicPageState` 下一个成员的行首（成员一律缩进 **2 空格**）。
///
/// 泛型返回类型要显式处理：`  Future<void> ` 里 `Future` 之后是 `<`。
final RegExp _memberStart = RegExp(
  r'\n  (Future<|Future |void |Widget |String |bool |int |Set<|List<|Map<)',
);

/// `studio_page.dart` 里 [`_save`](...) 的**方法体**原文（含签名行）。
///
/// 返回 null 表示文件里找不到 `_save` —— 断言据此判 FAIL（"空结果判 FAIL"，
/// `A02 §7.1`）：找不到方法不等于"保存很干净"。
String? _saveBodyText(Directory packageRoot) {
  final file = File('${packageRoot.path}/$_studioPath');
  if (!file.existsSync()) return null;
  final source = file.readAsStringSync();
  final start = source.indexOf('Future<bool> _save(');
  if (start < 0) return null;
  final rest = source.substring(start);
  final end = rest.indexOf(_memberStart, 1);
  return end < 0 ? rest : rest.substring(0, end);
}

/// 绿路径 = 真实现：`_save` 里**不该**出现 `_regenerateResults`。
///
/// ⚠️ 找不到 `_save` 返回 false（不是 true）—— 否则把方法整个删掉反而"通过"。
bool _saveBodySpansRegenerateResults(Directory packageRoot) {
  final body = _saveBodyText(packageRoot);
  if (body == null) return false;
  return !body.contains('_regenerateResults');
}

/// 故障路径 = 修复前那一版：`_save` 末尾挂着
/// `unawaited(_regenerateResults(dirtyPages: dirtyPages, run: run))`。
bool _saveBodyCallsRegenerateResults(Directory packageRoot) {
  final body = _saveBodyText(packageRoot);
  if (body == null) return false;
  return body.contains('_regenerateResults');
}
