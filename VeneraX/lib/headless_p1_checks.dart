// S9 · 第 2 批 🟠 P1 的断言（P1-3 聚块/阅读顺序 · P1-4 字体资产 · P1-5 落地）。
//
// 🔴 **为什么单独一个文件**：P1 的断言比 P0 那一批多得多，而 `headless.dart`
// 已经 2400 行。把它们放在一起的后果是"再加断言"这件事越来越像要动核心
// 文件，于是被跳过 —— 而这一批的断言恰恰最该被看到（P9.3 的元教训：静默
// 失败必须用断言锁）。
//
// 每一条断言都必须满足两条纪律：
//
// 1. **空结果判 FAIL。** 扫源码/扫配置的检查，"一个都没扫到"不是通过，是
//    规则失效。（P9.3 的假绿。）
// 2. **反向验证。** 每条断言写完后，故意注入一个错误确认它真的 FAIL。
//    `assertions_were_reverse_verified` 把这件事本身变成一条可执行的记录。
library;

import 'dart:convert';
import 'dart:io';

import 'package:venera/foundation/bundled_fonts.dart';
import 'package:venera/foundation/image_translation/balloon_clustering.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/translation_project/edit_command.dart';
import 'package:venera/foundation/translation_project/project.dart';
import 'package:venera/foundation/translation_project/rich_text_sync.dart';
import 'package:venera/foundation/translation_project/studio_pipeline.dart';
import 'package:venera/foundation/translation_project/text_block.dart';

/// Collects one entry per assertion, in the same shape `edit-check` reports.
typedef CheckSink = void Function(String name, bool passed, String detail);

/// Runs every P1 assertion. [packageRoot] is the directory holding `pubspec.yaml`.
///
/// [reverseVerified] is the list of assertion names the caller confirmed FAIL
/// under an injected fault (see `docs/P9.6` §五). It is asserted against, so
/// "I ran them once by hand" becomes a checkable claim rather than a promise.
void runP1Checks(
  CheckSink check, {
  required Directory packageRoot,
  required List<String> reverseVerified,
}) {
  _fontChecks(check, packageRoot);
  _clusterChecks(check);
  _pipelineChecks(check, reverseVerified, packageRoot);
}

// ---------------------------------------------------------------------------
// P1-4 · 字体资产
// ---------------------------------------------------------------------------

void _fontChecks(CheckSink check, Directory root) {
  // 1) 打包字体文件真的在磁盘上。
  //
  // 🔴 空结果判 FAIL：只断言"表里有两条记录"而不断言文件存在的话，把表清空
  // 也能过 —— 而"表是空的"恰好是这套机制完全失效的样子。
  final missingFiles = <String>[];
  for (final font in bundledFonts) {
    final path = '${root.path}/assets/${font.file}';
    if (!File(path).existsSync()) {
      missingFiles.add(font.file);
      continue;
    }
    final size = File(path).lengthSync();
    // An empty or stub file would let the build "succeed" and letter nothing.
    if (size < 100000) missingFiles.add('${font.file} (${size}B, too small)');
  }
  check(
    'font.files_present',
    missingFiles.isEmpty,
    missingFiles.isEmpty
        ? '${bundledFonts.length} bundled font file(s) on disk'
        // 🔴 Empty detail would read like a pass; name the offender.
        : 'MISSING: ${missingFiles.join(", ")}',
  );

  // 2) LICENSE 必须随字体分发（OFL 的硬性要求）。
  final missingLicenses = <String>{
    for (final font in bundledFonts)
      if (!File('${root.path}/assets/${font.license}').existsSync())
        font.license,
  }.toList();
  check(
    'font.license_embedded',
    missingLicenses.isEmpty,
    missingLicenses.isEmpty
        ? 'OFL text present for ${bundledFonts.length} font file(s)'
        : 'MISSING: ${missingLicenses.join(", ")}',
  );

  // 3) 打包表与 pubspec 的 fonts: 段必须一致。
  //
  // 这一条锁的是"两处漂移"：面板按 bundled_fonts.dart 列选项，Flutter 按
  // pubspec 注册字体。两者不一致时症状是"下拉里有这个字体，选了没反应"。
  final pubspec = File('${root.path}/pubspec.yaml');
  if (!pubspec.existsSync()) {
    check(
      'font.registry_matches_pubspec',
      false,
      'pubspec.yaml not found at ${root.path} — the check cannot pass',
    );
  } else {
    final yaml = pubspec.readAsStringSync();
    final uncommented = RegExp(r'^\s*fonts:\s*$', multiLine: true).hasMatch(yaml);
    final registered = <String>{};
    // 🔴 Capture to end-of-line, not `\S+`. A family name may contain spaces
    // ("Noto Sans SC") and a non-greedy token match reads it as "Noto" — which
    // made the very first run of this assertion report a mismatch that did not
    // exist. The rule from P9.3 applies: when a check disagrees with the code,
    // suspect the check first.
    for (final m in RegExp(
      r'^\s*-\s*family:\s*(.+?)\s*$',
      multiLine: true,
    ).allMatches(yaml)) {
      registered.add(m.group(1)!.trim());
    }
    final declared = bundledFamilies.toSet();
    final notInYaml = declared.difference(registered);
    final notInTable = registered.difference(declared);
    check(
      'font.registry_matches_pubspec',
      uncommented && notInYaml.isEmpty && notInTable.isEmpty,
      uncommented
          ? 'fonts: active; families yaml=${registered.toList()} '
              'table=${declared.toList()}'
          : 'the fonts: block is still commented out in pubspec.yaml',
    );
    check(
      'font.assets_exist_in_pubspec',
      notInYaml.isEmpty,
      notInYaml.isEmpty
          ? 'every bundled family is registered'
          : 'declared in bundled_fonts.dart but absent from pubspec: '
              '${notInYaml.join(", ")}',
    );
  }

  // 4) 未打包的字族必须落到打包字体，**而不是**交给系统字体。
  //
  // 🔴 这是 P1-4 的核心契约，也是 P0-1 验收的解锁条件。断言直接比对
  // `resolveFamily` 的输出，而不是"页面上看起来有字"——后者对 Linux
  // 发行版以外的所有机器都成立，也就是说它在真正会出问题的环境里
  // 什么也测不到。
  final unknown = resolveFamily('Some Font That Does Not Exist');
  check(
    'font.unknown_family_falls_back',
    unknown.family == primaryBundledFamily && unknown.fallback,
    'resolveFamily("Some Font That Does Not Exist") -> '
    '"${unknown.family}" fallback=${unknown.fallback}; '
    'reason: ${unknown.reason}',
  );

  // 5) FT 工程里的历史字族名（雅黑）必须被认识，否则打开旧工程全是英文/回退。
  // 🔴 只比 (family, fallback) 是**不够的**：雅黑映射到的恰好就是
  // `primaryBundledFamily`，而"完全未知的名字 → 落到 primary"给出的是同一个
  // 二元组。于是把别名表整条删掉，这条断言照样通过 —— 反向验证（P9.7 §五）
  // 就是这么发现的。别名到底有没有被**认识**，只能从 `reason` 读出来；而
  // `reason` 的文档注释写明"面板与断言都靠它说话"，所以这里必须多断言那一段。
  final yahei = resolveFamily('Microsoft YaHei UI');
  final knownAlias = yahei.reason.contains('mapped to');
  check(
    'font.legacy_yahei_mapped',
    yahei.family == primaryBundledFamily && yahei.fallback && knownAlias,
    '"Microsoft YaHei UI" -> "${yahei.family}" fallback=${yahei.fallback} '
    'recognised=$knownAlias; reason: ${yahei.reason} '
    '(this is FontFormat.defaultFontFamily, i.e. most existing projects)',
  );

  // 6) 空字族必须落回打包字体（"缺失"不等于"用系统默认"）。
  final empty = resolveFamily(null);
  check(
    'font.missing_family_falls_back',
    empty.family == primaryBundledFamily && empty.fallback,
    'resolveFamily(null) -> "${empty.family}" fallback=${empty.fallback}',
  );

  // 7) 已打包的字族必须原样通过（不许被"清洗"成别的名字）。
  final packaged = resolveFamily(primaryBundledFamily);
  check(
    'font.bundled_family_passes_through',
    packaged.family == primaryBundledFamily && !packaged.fallback,
    '"$primaryBundledFamily" -> "${packaged.family}" '
    'fallback=${packaged.fallback} (a bundled family must never be rewritten)',
  );

  // 8) `FontFormat.defaultFontFamily` 是雅黑 —— 这条记录的是**为什么**
  //    第 5 条断言必须存在。哪天默认值改了，第 5 条就该被重新评估。
  check(
    'font.default_family_is_legacy',
    FontFormat.defaultFontFamily == 'Microsoft YaHei UI',
    'FontFormat.defaultFontFamily = "${FontFormat.defaultFontFamily}"',
  );

  // 9) 字族选择器必须把"未打包"也列出来。
  //
  // 反过来也成立：不列的话用户打开一个 FT 工程会看到面板显示打包字体，而
  // json 里写的是另一个名字，"我明明有那个字体"就成了一个像 bug 的现象。
  final choices = fontFamilyChoices('Some Unbundled Face');
  final labels = [for (final c in choices) c.label];
  check(
    'font.selector_lists_unbundled',
    choices.any((c) => c.family == 'Some Unbundled Face' && !c.bundled) &&
        choices.any((c) => c.family == primaryBundledFamily),
    'choices: $labels',
  );

  // 10) 渲染器必须真的走 resolveFamily。
  //
  // 这条扫的是**源码**而不是调用结果 —— 因为 `page_renderer._fillStyle` 是私有的，
  // headless 拿不到它。🔴 空结果必须判 FAIL：扫不到 `page_renderer.dart` 说明
  // 文件被改名/移动了，此时"没有裸传 fontFamily"这个结论毫无意义。
  final renderer = File('${root.path}/lib/foundation/image_translation/page_renderer.dart');
  if (!renderer.existsSync()) {
    check(
      'font.renderer_resolves_family',
      false,
      'page_renderer.dart not found — cannot verify the renderer path',
    );
  } else {
    final source = renderer.readAsStringSync();
    final resolves = source.contains('resolveFamily(');
    // A raw `fontFamily: style.fontFamily` is the exact bug P1-4 fixes.
    final rawPassThrough = RegExp(r'fontFamily:\s*style\.fontFamily').hasMatch(source);
    check(
      'font.renderer_resolves_family',
      resolves && !rawPassThrough,
      resolves
          ? (rawPassThrough
                ? 'resolveFamily is used BUT style.fontFamily is still passed '
                    'raw somewhere — the fallback is bypassed on that path'
                : 'every fontFamily assignment goes through resolveFamily()')
          : 'page_renderer never calls resolveFamily — an unregistered family '
              'would silently fall back to a system font',
    );
  }

  // 11) 两条渲染路径（读模型 / 成品）必须用同一个解析结果。
  //
  // P9.4 §六 已经指出：工作室画布用 `PageCanvasPainter`（读模型），成品用
  // `page_renderer`，两条路径不共享代码。若画布按原始字族显示而成品按打包
  // 字体显示，用户看到的预览与导出结果会不一致 —— 而这类不一致正是
  // "所见即所得"最贵的失败，而且不报错。
  final canvas = File('${root.path}/lib/components/text_block_canvas.dart');
  final studioPage = File('${root.path}/lib/pages/translation_studio/studio_page.dart');
  final canvasResolves =
      canvas.existsSync() && canvas.readAsStringSync().contains('resolveFamily(');
  final canvasRaw = canvas.existsSync() &&
      RegExp(r'fontFamily:\s*block\.fontFamily').hasMatch(canvas.readAsStringSync());
  // The studio page must hand the **raw** family to the canvas and let the
  // canvas resolve it. Hardcoding a family here would double-resolve and make
  // the panel's stored value meaningless.
  final studioHandsOff = studioPage.existsSync() &&
      studioPage
          .readAsStringSync()
          .contains('fontFamily: format?.fontFamily ?? FontFormat.defaultFontFamily');
  check(
    'font.preview_matches_output',
    canvasResolves && !canvasRaw && studioHandsOff,
    'canvas resolves=${canvasResolves} rawPassThrough=${canvasRaw} '
    'studioHandsOffRaw=${studioHandsOff} '
    '(the canvas must resolve, or the preview lies about the exported page)',
  );
}

// ---------------------------------------------------------------------------
// P1-3 · 气泡聚块 + 阅读顺序
// ---------------------------------------------------------------------------

/// 900×1778 是 S9Fixture 的页面尺寸（见 P9.0 §四）。
const int _fixtureWidth = 900;

void _clusterChecks(CheckSink check) {
  // --- 1) 同一气泡内的多行必须合成一个 ------------------------------------
  //
  // 三行、每行 30px 高、行间距 8px：8 / 30 = 0.27 < gapFactor 0.6，所以
  // 间隙阈值 ≈ 18px，三行都桥接得上。
  final oneBubble = clusterBalloons(
    [
      TextLine(rect: IntRect(100, 100, 400, 130), text: '第一行', lineHeight: 30),
      TextLine(rect: IntRect(100, 138, 400, 168), text: '第二行', lineHeight: 30),
      TextLine(rect: IntRect(100, 176, 400, 206), text: '第三行', lineHeight: 30),
    ],
    pageWidth: _fixtureWidth,
  );
  check(
    'cluster.merges_lines_of_one_balloon',
    oneBubble.length == 1 && oneBubble.first.lines.length == 3,
    // 🔴 One interpolated literal, not several joined ones: the report is read
    // by a human comparing two runs, and a line break in the middle of a
    // coordinate list makes that comparison harder than it needs to be.
    '3 lines 8px apart -> ${oneBubble.length} balloon(s), '
        '${oneBubble.isEmpty ? 0 : oneBubble.first.lines.length} line(s); '
        'bounds=${oneBubble.isEmpty ? '-' : _rectText(oneBubble.first.bounds)}',
  );

  // --- 2) 相邻气泡（间距远大于行距）必须分开 ------------------------------
  //
  // 同一列、纵向相隔 100px（≈3.3 倍字高）：远超正确间隙阈值
  // （0.6 × 30 = 18px），所以必须是两个气泡。
  //
  // 🔴 100px 是**故意贴着**阈值取的。反向验证把 `gapFactor` 调到 4.0 时阈值
  // 涨到上限 90px，两框立刻桥接成一个；而 200px 的旧夹具在同一个故障下依然
  // 分开（间距 / 字高 = 6.7，任何被 `maxGap` 夹住的阈值都够不着它）—— 于是
  // 那条断言"通过"了，却什么也没测到。**夹具必须落在正确值与故障值之间，
  // 否则断言是装饰品**（P9.7 §五）。
  final twoBalloons = clusterBalloons(
    [
      TextLine(rect: IntRect(100, 100, 400, 130), text: '上の台詞', lineHeight: 30),
      TextLine(rect: IntRect(100, 230, 400, 260), text: '下の台詞', lineHeight: 30),
    ],
    pageWidth: _fixtureWidth,
  );
  check(
    'cluster.splits_separate_balloons',
    twoBalloons.length == 2,
    '2 lines 100px apart -> ${twoBalloons.length} balloon(s) (must be 2)',
  );

  // --- 3) 右起：右列先读 --------------------------------------------------
  //
  // 两个气泡横向相隔 300px（> columnGapFactor 0.04 × 900 = 36px），因此切成
  // 两列；右起模式下右列的 order 必须是 0。
  //
  // 🔴 300 而不是"够用就好"的 180：桥接判定是"两框各外扩 gap 后是否相交"，
  // 也就是要 2 × gap > 间距才算够到。gap 的正确值是 0.6 × 40 = 24（2×24 = 48
  // 够不着 300 ✓），反向验证把它调到上限 90 时是 2 × 90 = 180 —— 180 恰好
  // 等于旧夹具的间距，`intersects` 在相等时返回 false，于是那次反向验证**靠
  // 一个像素的运气**才没有误报。夹具要留出真正的余量，不要靠边界值。
  final rtl = clusterBalloons(
    [
      TextLine(rect: IntRect(40, 100, 320, 140), text: '左', lineHeight: 40),
      TextLine(rect: IntRect(620, 100, 900, 140), text: '右', lineHeight: 40),
    ],
    pageWidth: _fixtureWidth,
    direction: ReadingDirection.rightToLeft,
  );
  check(
    'cluster.reading_order_right_to_left',
    rtl.length == 2 &&
        rtl[0].text == '右' &&
        rtl[0].column == 0 &&
        rtl[1].column == 1,
    'RTL order: ${_orderText(rtl)}',
  );

  // --- 4) 左起：同一份输入必须给出相反的顺序 ------------------------------
  //
  // 🔴 这一条与第 3 条共用输入数据。反向验证就是把它单独跑：若实现里方向
  // 参数被忽略，3 和 4 会给出同样的顺序，而它们各自都"看起来合理"。
  final ltr = clusterBalloons(
    [
      TextLine(rect: IntRect(40, 100, 320, 140), text: '左', lineHeight: 40),
      TextLine(rect: IntRect(620, 100, 900, 140), text: '右', lineHeight: 40),
    ],
    pageWidth: _fixtureWidth,
    direction: ReadingDirection.leftToRight,
  );
  check(
    'cluster.reading_order_left_to_right',
    ltr.length == 2 &&
        ltr[0].text == '左' &&
        ltr[0].column == 0 &&
        ltr[1].column == 1,
    'LTR order: ${_orderText(ltr)}',
  );

  // --- 5) 列内自上而下 ---------------------------------------------------
  //
  // 右列两个气泡、右列先读；列内必须按 top 排，不能按 left（否则同列两个
  // 宽度不同的气泡会被排错）。
  final columnOrder = clusterBalloons(
    [
      TextLine(rect: IntRect(600, 600, 860, 640), text: '下', lineHeight: 40),
      TextLine(rect: IntRect(600, 120, 820, 160), text: '上', lineHeight: 40),
      TextLine(rect: IntRect(80, 200, 380, 240), text: '左列', lineHeight: 40),
    ],
    pageWidth: _fixtureWidth,
    direction: ReadingDirection.rightToLeft,
  );
  check(
    'cluster.column_reads_top_to_bottom',
    columnOrder.length == 3 &&
        columnOrder[0].text == '上' &&
        columnOrder[1].text == '下' &&
        columnOrder[2].text == '左列',
    'order: ${_orderText(columnOrder)}',
  );

  // --- 6) 阶梯排列**不得**被并成一列 -------------------------------------
  //
  // 这是"横向重叠即同列"那个写法的反例：A 与 B 搭上、B 与 C 搭上，传递闭包
  // 会把三块并成一列，于是右起漫画被当成单列从上往下读 —— 恰好是本项要修的
  // 那个错。三块的 x 区间两两不重叠，且相邻间隔 > 36px，所以必须是三列。
  //
  // 🔴 相邻间隔取 **210px**，不是为了好看：桥接要求 `2 × gap > 间距`，而
  // `gap` 被 `maxGap` 夹在 90，也就是 2 × 90 = 180。60px 的旧间距在"间隙阈值
  // 被放大"的故障下会被合并，于是这条断言（以及另外三条"不许合并"的断言）
  // 全部连带打红 —— 连带不是说谎，但它把一次故障变成一锅粥，掩盖了真正
  // 被瞄准的那一条。**留出 180 的余量，让"合并类"故障只打它该打的那一条。**
  final staggered = clusterBalloons(
    [
      TextLine(rect: IntRect(20, 100, 160, 140), text: 'A', lineHeight: 40),
      TextLine(rect: IntRect(370, 300, 510, 340), text: 'B', lineHeight: 40),
      TextLine(rect: IntRect(720, 500, 860, 540), text: 'C', lineHeight: 40),
    ],
    pageWidth: _fixtureWidth,
  );
  check(
    'cluster.staggered_not_merged_into_one_column',
    staggered.length == 3 && staggered.map((b) => b.column).toSet().length == 3,
    'staircase -> ${staggered.length} balloons in '
    '${staggered.map((b) => b.column).toSet().length} column(s) '
    '(must be 3/3, not 3/1)',
  );

  // --- 7) 结果与输入顺序无关（确定性） -------------------------------------
  //
  // 检测器不保证输出顺序。若聚类依赖输入顺序，同一页两次跑会给出不同的
  // 气泡数，而用户无法分辨那是模型抖动还是代码不确定。
  // 🔴 夹具的两个细节都是为了让"输入顺序"真的**能被测出来**（P9.7 §五）：
  //
  //   * 第一项必须是**左列**的块。列切分的游标 `rightmost` 从"第一个组"起算，
  //     所以首项是谁直接决定后面每一组落在第几列。首项换成右列块时，正序与
  //     逆序恰好给出同一个答案（旧夹具就是这样），断言于是测不到"顺序无关"。
  //   * B 与 D 的 `left` 必须**不同**（600 / 620）。同 left 时按 left 排序是
  //     平局，平局顺序退化成输入顺序 —— 那样"把列内排序改成按 left"的故障
  //     也会打红这条断言，那是连带噪声，不是这条断言要测的东西。
  final lines = [
    TextLine(rect: IntRect(100, 100, 380, 140), text: 'A', lineHeight: 40),
    TextLine(rect: IntRect(600, 120, 820, 160), text: 'B', lineHeight: 40),
    TextLine(rect: IntRect(80, 700, 380, 740), text: 'C', lineHeight: 40),
    TextLine(rect: IntRect(620, 600, 860, 640), text: 'D', lineHeight: 40),
  ];
  final forward = clusterBalloons(lines, pageWidth: _fixtureWidth);
  final reversed = clusterBalloons(
    lines.reversed.toList(),
    pageWidth: _fixtureWidth,
  );
  final forwardKeys = [for (final b in forward) '${b.text}@${b.order}'];
  final reversedKeys = [for (final b in reversed) '${b.text}@${b.order}'];
  check(
    'cluster.order_is_deterministic',
    forwardKeys.join('|') == reversedKeys.join('|'),
    'forward=$forwardKeys reversed=$reversedKeys',
  );

  // --- 8) 竖排气泡内的列必须右起 ------------------------------------------
  //
  // 两列竖排文字，右列先读。用 top 排会把整段译文左右颠倒（P9.5 §三 的
  // 同类错误：静默地把内容排反）。
  final verticalLines = clusterBalloons(
    [
      TextLine(rect: IntRect(120, 100, 150, 400), text: '左列', lineHeight: 300),
      TextLine(rect: IntRect(180, 100, 210, 400), text: '右列', lineHeight: 300),
    ],
    pageWidth: _fixtureWidth,
  );
  check(
    'cluster.vertical_lines_read_right_first',
    verticalLines.length == 1 &&
        verticalLines[0].text == '右列\n左列',
    verticalLines.isEmpty
        ? 'no balloon for two adjacent vertical lines (must not throw)'
        : 'joined text = ${verticalLines[0].text.replaceAll("\n", " | ")}',
  );

  // --- 9) 空输入不得抛异常，也不得凭空造块 --------------------------------
  check(
    'cluster.empty_input_yields_nothing',
    clusterBalloons(const [], pageWidth: _fixtureWidth).isEmpty,
    'no lines -> no balloons (must not fabricate)',
  );

  // --- 10) 空文本行不参与聚类 --------------------------------------------
  //
  // 检测器偶尔会吐出空白行（无文字的框）。让它们参与聚类会把两个气泡桥接
  // 起来 —— 一个空框横在中间，间隙判定就失效了。
  //
  // 🔴 两个真实行相隔 570px（> 2 × maxGap = 180）：这条断言要测的是"空白行被
  // 过滤"，不该被"间隙阈值被放大"的故障连带打红。旧夹具只隔 200px，间距小于
  // 放大后的桥接半径，于是那次反向验证里它跟着一起红了。
  final withBlank = clusterBalloons(
    [
      TextLine(rect: IntRect(100, 100, 400, 130), text: '上', lineHeight: 30),
      TextLine(rect: IntRect(100, 400, 400, 430), text: '   ', lineHeight: 30),
      TextLine(rect: IntRect(100, 700, 400, 730), text: '下', lineHeight: 30),
    ],
    pageWidth: _fixtureWidth,
  );
  check(
    'cluster.blank_lines_ignored',
    withBlank.length == 2,
    'blank line between two lines -> ${withBlank.length} balloons (must be 2, '
    'a blank must not bridge them)',
  );

  // --- 11) 方向相反的两行不得合并 ----------------------------------------
  //
  // 🔴 两个几何细节是这条断言**能被反向验证**的前提（P9.7 §五）：
  //   * 竖排那一行的外扩框必须与横排那行**相交**，否则 `_mergeable` 根本不会
  //     被调用，方向闸门一次也没执行过；
  //   * 两者的字高必须在 2.2 倍以内，否则先被尺寸闸门拦掉 —— 旧夹具是
  //     30px vs 260px，注入"删掉方向检查"后断言照样通过，因为它压根没走到那里。
  final mixed = clusterBalloons(
    [
      TextLine(rect: IntRect(100, 100, 400, 140), text: '横排', lineHeight: 40),
      TextLine(rect: IntRect(110, 150, 150, 230), text: '縦', lineHeight: 80),
    ],
    pageWidth: _fixtureWidth,
  );
  check(
    'cluster.mixed_orientation_not_merged',
    mixed.length == 2,
    'one horizontal + one vertical -> ${mixed.length} balloons (must be 2; '
    'merging them would feed OCR two unrelated strings)',
  );

  // --- 12) 字高差过大的两行不得合并 --------------------------------------
  final sizeGap = clusterBalloons(
    [
      TextLine(rect: IntRect(100, 100, 400, 120), text: '小', lineHeight: 20),
      TextLine(rect: IntRect(100, 126, 400, 206), text: '大', lineHeight: 80),
    ],
    pageWidth: _fixtureWidth,
  );
  check(
    'cluster.mixed_font_size_not_merged',
    sizeGap.length == 2,
    '20px + 80px lines -> ${sizeGap.length} balloons (must be 2; the median '
    'line height would otherwise land between the two)',
  );

  // --- 13) 聚类必须确定 lineHeight（写进 fromOcr 的字号） ------------------
  final heights = clusterBalloons(
    [
      TextLine(rect: IntRect(100, 100, 400, 130), text: 'a', lineHeight: 30),
      TextLine(rect: IntRect(100, 138, 400, 168), text: 'b', lineHeight: 30),
      TextLine(rect: IntRect(100, 176, 400, 206), text: 'c', lineHeight: 44),
    ],
    pageWidth: _fixtureWidth,
  );
  check(
    'cluster.reports_median_line_height',
    heights.length == 1 && heights[0].medianLineHeight == 30,
    heights.isEmpty
        ? 'no balloon for 3 nearby lines (must not throw)'
        : 'line heights 30/30/44 -> median ${heights[0].medianLineHeight}'
            ' (must be 30: the median is what caps the translated glyph size)',
  );

  // --- 14) 落回 OcrBlock 必须带上逐行擦除框 ------------------------------
  //
  // 🔴 若这里退化成"整块一个框"，气泡内的美术会被一起擦掉；而且旧引擎
  // (`worker.ocrPage`) 用的是逐行框，两条路不一致时同一页在阅读器与工作室
  // 里的擦除结果会不同。
  //
  // 🔴 这条断言**不得抛异常**。`oneBubble.first` 在聚类意外返回空时会抛
  // `Bad state: No element`，而 `edit-check` 的 catch 会把它当成"整批抛异常"
  // —— 于是第 15 条与后面 9 条 pipeline 断言**根本没跑**，报告里却没有它们。
  // 那正是"失败被吞掉"的一种：不是假绿，是根本没执行。
  final bridgeOk = oneBubble.length == 1;
  final bridge = bridgeOk
      ? balloonToOcrBlock(
          oneBubble.first,
          backgroundColor: 0xFFFFFFFF,
          textColor: 0xFF112233,
        )
      : null;
  check(
    'cluster.bridge_keeps_per_line_erase_rects',
    bridge != null &&
        bridge.eraseRects.length == 3 &&
        bridge.lineHeight == 30 &&
        bridge.text == '第一行\n第二行\n第三行',
    bridge == null
        ? 'clustering produced ${oneBubble.length} balloons for 3 lines — '
            'nothing to convert (must not throw; this check must report FAIL)'
        : 'eraseRects=${bridge.eraseRects.length} '
            'lineHeight=${bridge.lineHeight} '
            'text=${bridge.text.replaceAll("\n", "|")}',
  );

  // --- 15) 扩展点必须是可实现的接口，而不是一个 TODO ----------------------
  //
  // 方案 B（气球检测模型）本批不做，但接缝必须先固定。若 `BalloonDetector`
  // 消失了，将来换实现就要改落地路径 —— 而那正是本批最贵的部分。
  const detector = PureGeometryBalloonDetector();
  check(
    'cluster.detector_extension_point_exists',
    detector is BalloonDetector,
    'PureGeometryBalloonDetector implements BalloonDetector '
    '(scheme B plugs in here)',
  );
}

// ---------------------------------------------------------------------------
// P1-5 · 工作室落地
// ---------------------------------------------------------------------------

void _pipelineChecks(
  CheckSink check,
  List<String> reverseVerified,
  Directory root,
) {
  // --- 1) 批量落地必须走 `pages[key]` 且能被一次撤销 ----------------------
  //
  // 复刻工作室的做法：一次 `captureBlockListEdit` 包住整页的新增块，push 进
  // EditHistory，然后验证 (a) 块真的进了页、(b) 一次 undo 全部回退。
  // 🔴 (b) 是"跑错了能一键回退"这个前提；逐块 push 会让用户按几十次。
  final project = TranslationProject.create(
    jsonFile: File('${Directory.systemTemp.path}/_p1_pipeline_probe.json'),
    directory: Directory.systemTemp.path,
  );
  final page = project.putPage('0/1.webp');
  final history = EditHistory();
  final made = [
    TextBlock.fromOcr(
      OcrBlock(
        rect: IntRect(100, 100, 400, 200),
        text: '台詞1',
        language: 'ja',
        backgroundColor: 0xFFFFFFFF,
        textColor: 0xFF000000,
        lineHeight: 28,
      ),
    ),
    TextBlock.fromOcr(
      OcrBlock(
        rect: IntRect(100, 300, 400, 400),
        text: '台詞2',
        language: 'ja',
        backgroundColor: 0xFFFFFFFF,
        textColor: 0xFF000000,
        lineHeight: 28,
      ),
    ),
  ];
  final command = captureBlockListEdit(
    page.rawBlocks,
    () => page.addBlocks(made),
    pageKey: '0/1.webp',
    label: 'Detect blocks',
  );
  history.push(command);
  final afterAdd = page.blocks.length;
  history.undo();
  final afterUndo = page.blocks.length;
  history.redo();
  final afterRedo = page.blocks.length;
  check(
    'pipeline.batch_landing_is_one_undo_step',
    afterAdd == 2 && afterUndo == 0 && afterRedo == 2,
    'add -> $afterAdd blocks; undo -> $afterUndo; redo -> $afterRedo '
    '(a chapter run produces dozens of blocks; per-block undo is not usable)',
  );

  // --- 2) 落地必须登记脏页（硬规矩 3） -----------------------------------
  //
  // 🔴 这是最容易被绕过、后果最静默的一条：不登记脏页，`result/` 增量重渲
  // 会漏掉这一页，用户看到的是"跑完了，导出还是旧的"。
  check(
    'pipeline.landing_registers_dirty_page',
    history.dirtyPages.contains('0/1.webp'),
    'dirtyPages=${history.dirtyPages.toList()} '
    '(must contain the page that just gained blocks)',
  );

  // --- 3) 撤销到保存点后脏页必须为空 -------------------------------------
  final fresh = TranslationProject.create(
    jsonFile: File('${Directory.systemTemp.path}/_p1_pipeline_probe2.json'),
    directory: Directory.systemTemp.path,
  );
  final freshPage = fresh.putPage('0/1.webp');
  final freshHistory = EditHistory();
  freshHistory.push(
    captureBlockListEdit(
      freshPage.rawBlocks,
      () => freshPage.addBlock(
        TextBlock.fromOcr(
          OcrBlock(
            rect: IntRect(0, 0, 10, 10),
            text: 'x',
            language: 'ja',
            backgroundColor: 0xFFFFFFFF,
            textColor: 0xFF000000,
          ),
        ),
      ),
      pageKey: '0/1.webp',
    ),
  );
  freshHistory.markSaved();
  final clean = freshHistory.dirtyPages;
  freshHistory.undo();
  final afterUndoSave = freshHistory.dirtyPages;
  check(
    'pipeline.undo_after_save_clears_dirty',
    clean.isEmpty && afterUndoSave.isEmpty,
    'after save dirty=${clean.toList()}; after undo dirty=${afterUndoSave.toList()} '
    '(a page whose net change is nil must not be re-rendered)',
  );

  // --- 4) 去重必须只读、不得覆盖人工校对过的块 ---------------------------
  //
  // The previous check undid its block, so seed the "already reviewed" one
  // here. Written as plain statements: `addBlock` returns `void`, so a
  // conditional expression wrapping it cannot yield the block.
  final seed = TextBlock.fromOcr(
    OcrBlock(
      rect: IntRect(0, 0, 200, 120),
      text: '台詞',
      language: 'ja',
      backgroundColor: 0xFFFFFFFF,
      textColor: 0xFF000000,
      lineHeight: 24,
    ),
  );
  freshPage.addBlock(seed);
  final reviewed = seed;
  reviewed.translation = '人工校对过的译文';
  syncRichTranslation(reviewed);
  final dup = overlapsExistingBlock(freshPage, reviewed.rect);
  final far = overlapsExistingBlock(
    freshPage,
    IntRect(5000, 5000, 5400, 5400),
  );
  check(
    'pipeline.dedup_protects_reviewed_blocks',
    dup && !far && reviewed.translation == '人工校对过的译文',
    'same box overlaps=$dup; distant box overlaps=$far; '
    'existing translation intact=${reviewed.translation}',
  );

  // --- 5) 落地的块必须能变成可渲染 region（即 fromOcr 契约被用上） -------
  //
  // 空译文的块不得被 letter（P9.5 的契约）；有译文的必须能。
  final lifted = TextBlock.fromOcr(
    OcrBlock(
      rect: IntRect(10, 20, 300, 120),
      text: 'こんにちは',
      language: 'ja',
      backgroundColor: 0xFFFFFFFF,
      textColor: 0xFF000000,
      lineHeight: 26,
    ),
  );
  final before = lifted.toTranslatedRegion();
  lifted.translation = '你好';
  syncRichTranslation(lifted);
  final after = lifted.toTranslatedRegion();
  check(
    'pipeline.blocks_become_letterable',
    before == null && after != null && after.text == '你好',
    'before translation region=$before; after="${after?.text}" '
    '(an untranslated block must not be lettered)',
  );

  // --- 6) 取消令牌必须在页边界生效 ---------------------------------------
  final token = CancellationToken()..cancel();
  var threw = false;
  try {
    token.throwIfCanceled();
  } on PipelineCanceled {
    threw = true;
  }
  check(
    'pipeline.cancel_token_works',
    threw && token.isCanceled,
    'a cancelled token throws PipelineCanceled (threw=$threw)',
  );

  // --- 7) 部分成功的汇总必须把失败页数报出来 -----------------------------
  final report = StudioRunReport([
    StudioPageRun(pageKey: '0/1.webp', blocks: [], skipped: 0),
    StudioPageRun(
      pageKey: '0/2.webp',
      blocks: [],
      skipped: 0,
      error: Exception('boom'),
    ),
    StudioPageRun(pageKey: '0/3.webp', blocks: [], skipped: 2),
  ]);
  check(
    'pipeline.report_counts_failures',
    report.failedPages == 1 && report.skippedLines == 2 && !report.canceled,
    'failed=${report.failedPages} skipped=${report.skippedLines} '
    'canceled=${report.canceled} '
    '(a partial run must not report as a complete one)',
  );

  // --- 8) 工作室 UI 不得耦合旧引擎的任务框架 ----------------------------
  //
  // 🔴 这是本项与旧 AI 翻译引擎的**分叉点**。若 studio_page 以后 import
  // `pre_translation_tasks.dart`，产物就会有机会被写进旧缓存，而那条路的
  // 失败模式是"跑完了，作品里一个字没变"—— 完全静默。
  final studioPage = File(
    '${root.path}/lib/pages/translation_studio/studio_page.dart',
  );
  if (!studioPage.existsSync()) {
    check(
      'pipeline.studio_does_not_use_legacy_engine',
      false,
      'studio_page.dart not found under ${root.path}',
    );
  } else {
    final source = studioPage.readAsStringSync();
    // 🔴 Strip comments before scanning. The page documents *why* it does not
    // use the legacy manager, and that rationale mentions the class by name —
    // so a naive substring scan flags the file for its own explanation. The
    // first version of this check did exactly that and reported a false FAIL.
    // What matters is whether the code **uses** it, so comments come out first.
    final code = source
        .replaceAll(RegExp(r'//.*$', multiLine: true), '')
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    final usesLegacy = code.contains('PreTranslationTaskManager') ||
        code.contains('pre_translation_tasks');
    final mentionsInComment = source.contains('PreTranslationTaskManager') &&
        !code.contains('PreTranslationTaskManager');
    check(
      'pipeline.studio_does_not_use_legacy_engine',
      !usesLegacy,
      usesLegacy
          ? 'studio_page USES PreTranslationTaskManager in code — results would '
              'go to the reader OCR cache instead of the project'
          : mentionsInComment
              ? 'only referenced in a comment (documenting the deliberate '
                  'non-use); no code path reaches it'
              : 'studio_page builds its own runner; progress/cancel are local',
    );
  }

  // --- 9) 反向验证本身必须被记录 -----------------------------------------
  //
  // 断言不报错不代表它在检查正确的东西。这条把"每条断言都被注入故障验证过
  // 失败"变成可核对的记录，而不是一句"应该测过了"。清单在 docs/P9.6 §五。
  final known = {
    'font.files_present',
    'font.license_embedded',
    'font.registry_matches_pubspec',
    'font.assets_exist_in_pubspec',
    'font.unknown_family_falls_back',
    'font.legacy_yahei_mapped',
    'font.missing_family_falls_back',
    'font.bundled_family_passes_through',
    'font.default_family_is_legacy',
    'font.selector_lists_unbundled',
    'font.renderer_resolves_family',
    'font.preview_matches_output',
    'cluster.merges_lines_of_one_balloon',
    'cluster.splits_separate_balloons',
    'cluster.reading_order_right_to_left',
    'cluster.reading_order_left_to_right',
    'cluster.column_reads_top_to_bottom',
    'cluster.staggered_not_merged_into_one_column',
    'cluster.order_is_deterministic',
    'cluster.vertical_lines_read_right_first',
    'cluster.empty_input_yields_nothing',
    'cluster.blank_lines_ignored',
    'cluster.mixed_orientation_not_merged',
    'cluster.mixed_font_size_not_merged',
    'cluster.reports_median_line_height',
    'cluster.bridge_keeps_per_line_erase_rects',
    'cluster.detector_extension_point_exists',
    'pipeline.batch_landing_is_one_undo_step',
    'pipeline.landing_registers_dirty_page',
    'pipeline.undo_after_save_clears_dirty',
    'pipeline.dedup_protects_reviewed_blocks',
    'pipeline.blocks_become_letterable',
    'pipeline.cancel_token_works',
    'pipeline.report_counts_failures',
    'pipeline.studio_does_not_use_legacy_engine',
  };
  // 🔴 空清单判 FAIL。一个没做过反向验证的清单等于没做。
  final notVerified = [
    for (final name in reverseVerified)
      if (!known.contains(name)) name,
  ];
  final notClaimed = [
    for (final name in known)
      if (!reverseVerified.contains(name)) name,
  ];
  check(
    'assertions.reverse_verification_recorded',
    reverseVerified.isNotEmpty && notVerified.isEmpty && notClaimed.isEmpty,
    reverseVerified.isEmpty
        ? 'reverse-verification list is EMPTY — every assertion above is '
            'unverified and may be decorative (this must FAIL)'
        : notVerified.isNotEmpty
        ? 'list names assertions that do not exist: ${notVerified.join(", ")}'
        : notClaimed.isNotEmpty
        ? 'no reverse verification recorded for: ${notClaimed.join(", ")}'
        : '${reverseVerified.length} assertions confirmed FAIL under an '
            'injected fault',
  );
}

/// `syncFtRichText` is the real name (it mirrors FT's field); the alias keeps
/// the pipeline checks readable without hiding which function is called.
void syncRichTranslation(TextBlock block) => syncFtRichText(block);

/// `text@colN/#M` per balloon — the form both reading-order details use, so
/// the two are directly comparable by eye.
String _orderText(List<Balloon> balloons) =>
    balloons.isEmpty ? '(none)' : '[${[for (final b in balloons) "${b.text}@col${b.column}/#${b.order}"].join(', ')}]';

/// `l,t,r,b` for assertion details — one place so no detail string has to
/// interpolate four numbers inline (and get its quoting wrong).
String _rectText(IntRect rect) => '${rect.left},${rect.top},'
    '${rect.right},${rect.bottom}';

/// Version stamp of this assertion set, reported in the check detail.
const String p1CheckVersion = 'S9-P1-2026-10-07';

/// JSON-safe dump of a raw block, used in assertion details.
String dumpBlock(TextBlock block) => jsonEncode(block.raw);