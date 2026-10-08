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

  StudioRunChoice makeChoice({String sourceLang = 'ja', String targetLang = 'zh'}) {
    return StudioRunChoice(
      pages: resolvePageRange(pages, 3, 5),
      sourceLang: sourceLang,
      targetLang: targetLang,
      translate: false,
      rightToLeft: true,
    );
  }

  bool carries({String sourceLang = 'ja'}) {
    final c = makeChoice(sourceLang: sourceLang);
    return c.sourceLang == 'ja' &&
        c.targetLang == 'zh' &&
        !c.translate &&
        c.rightToLeft &&
        c.pages.length == 3;
  }

  probe(
    'choice.carries_every_field',
    () async => carries(),
    // 故障路径 = 换个 sourceLang 建对象，判据必须变红。否则这条是装饰品：
    // "字段被带出来"这件事只有在一个**不同的**输入会把它打红时才被证明。
    () async => carries(sourceLang: 'en'),
    () => '绿=五个字段原样带出 / 故障=sourceLang 变了判据也变红',
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
