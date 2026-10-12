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
import 'dart:typed_data';

import 'package:mangrove/foundation/bundled_fonts.dart';
import 'package:mangrove/foundation/image_translation/balloon_clustering.dart';
import 'package:mangrove/foundation/image_translation/font_fit.dart';
import 'package:mangrove/foundation/image_translation/text_color.dart';
import 'package:mangrove/foundation/image_translation/translation_types.dart';
import 'package:mangrove/foundation/system_fonts.dart';
import 'package:mangrove/foundation/translation_project/edit_command.dart';
import 'package:mangrove/foundation/translation_project/project.dart';
import 'package:mangrove/foundation/translation_project/project_writer.dart';
import 'package:mangrove/foundation/translation_project/result_renderer.dart';
import 'package:mangrove/foundation/translation_project/rich_text_sync.dart';
import 'package:mangrove/foundation/translation_project/studio_pipeline.dart';
import 'package:mangrove/foundation/translation_project/text_block.dart';

/// Collects one entry per assertion, in the same shape `edit-check` reports.
typedef CheckSink = void Function(String name, bool passed, String detail);

/// 扫出源码里所有 `.tl` / `.tlParams` 调用前置的**字面量键**。
///
/// 🔴 这是三个扫描器（`headless.dart` 的目录扫描、`headless_p5_checks.dart`、
/// `headless_p6_checks.dart`）**唯一**的实现。此前同一正则被复制了三份，而
/// 复制出来的每一条都能独立漂移；P9.3 的"新按钮显示英文"就是这条正则漏掉
/// `tlParams` 造成的（`\btl\b` 匹配不到 `tlParams`，两者之间没有词边界）。
///
/// 这里还补上了**双引号字面量**（`"Add term".tl`）。原先只认单引号，而
/// `pages/comic_details_page/glossary_editor.dart` 通篇是双引号 —— 它的 15
/// 条文案因此从来没被任何扫描看过。当时登记表里是全的，所以"没报错"，但那
/// 纯属运气：少登记一条就会静默显示英文，而**引号风格不该决定一个字符串会
/// 不会被检查**。
///
/// 锚在**翻译调用**上，而不是 `tooltip:` 参数上：后者只匹配字面量直接当参数
/// 的写法，条件选择（`cond ? 'A'.tl : 'B'.tl`）一个都扫不到。`.tlEN` 依旧被
/// 排除（`l` 与 `E` 之间没有词边界）。
List<String> tlLiteralKeys(String source) {
  final found = <String>[];
  for (final m in _tlLiteral.allMatches(source)) {
    found.add(m.group(2)!);
  }
  return found;
}

/// 引号由反向引用保证前后一致：`'A'.tl` 与 `"A".tl` 都算，`'A".tl` 不算。
///
/// 🔴 内容里**两种引号都要排除**（`[^'"\\]`），不能只排除起始引号那一种。
/// 只排除单引号时，双引号分支会从 `"Term rejected: …"` 一路吞到下一个文件
/// 里出现的 `"`（中间隔着换行、参数名、别的字符串），把 `child: Text("Save`
/// 这种片段当成一个 key —— 第一版就是这么炸的：它把半页源码 report 成一个
/// 未登记字面量。排除两种引号以后，匹配范围被钉在一个字符串字面量之内。
///
/// 🔴 `\1` 与 `.tl` 之间允许空白（`\s*`），因为**长文案换行是常态**：
///
///     "These terms belong to this studio project. …"
///         .tl,
///
/// `dart format` 会把超过 80 列的字符串和它的 `.tl` 拆到两行。不允许跨行，
/// 这些字符串就永远扫不到 —— 而"扫不到"不报错，只显示英文，正是本函数要
/// 防的那种静默失败。`\s*` 只吃空白，`"A"` 与 `"B".tl` 之间隔着一个非空白的
/// `,` 或 `"`，所以不会把相邻字面量错认成同一个 key。
final RegExp _tlLiteral = RegExp(
  r"""(['"])((?:[^'"\\]|\\.)*?)\1\s*\.tl(?:Params)?\b""",
);

/// Runs every P1 assertion. [packageRoot] is the directory holding `pubspec.yaml`.
///
/// [reverseVerified] is the list of assertion names the caller confirmed FAIL
/// under an injected fault (see `docs/P9.6` §五). It is asserted against, so
/// "I ran them once by hand" becomes a checkable claim rather than a promise.
///
/// [pendingVerification] names the assertions in the same batch that are **not**
/// fault-verified yet. They must be listed rather than quietly dropped: a
/// missing name fails the coverage check, so the honest options are "verified"
/// or "pending". Reporting a pending item does **not** fail the check — failing
/// it would make the cheapest fix "delete the name", which buys a green run by
/// throwing away the coverage guarantee. The lie to prevent is a name claimed
/// as verified when no fault ever turned it red.
void runP1Checks(
  CheckSink check, {
  required Directory packageRoot,
  required List<String> reverseVerified,
  List<String> pendingVerification = const [],
}) {
  _fontChecks(check, packageRoot);
  _clusterChecks(check);
  _pipelineChecks(check, reverseVerified, pendingVerification, packageRoot);
}

// ---------------------------------------------------------------------------
// P1-4 · 字体资产
// ---------------------------------------------------------------------------

void _fontChecks(CheckSink check, Directory root) {
  // 🔴 P33：下面第 4/5/6/7/9 条是在「**没有**系统字体表」的前提下写的。
  // 系统字体探测上线以后，一台装了雅黑的机器上
  // `resolveFamily('Microsoft YaHei UI')` 会走系统字体分支 —— 那是**正确的**
  // 新行为，却会让第 5 条变红。为了让两批断言各自在确定的状态下测量，这里
  // 先把表清空，末尾再注入合成表单独测新分支（测完恢复现场）。
  final savedIndex = systemFonts;
  systemFonts = SystemFontIndex(const <SystemFontInfo>[]);

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

  // ── P33 · 系统字体探测 + 双端参数统一（⑦a）────────────────────────────
  _fontSystemChecks(check, root);

  systemFonts = savedIndex;

  // ── P33 · 原图文字取色（⑦b）───────────────────────────────────────────
  _textColorChecks(check);
}

/// 合成一块「背景 + 抗锯齿边 + 实心笔画」的两色调夹具。
///
/// 🔴 抗锯齿边是**必须的**：它是"腐蚀到底有没有用"这件事唯一的证据来源。
/// 只有纯两色的夹具，腐蚀前后取到同一个颜色，断言就变成装饰品 —— 而这类
/// 装饰品正是本项目反复踩的那种（P29/P31 都重写过）。
RgbaImage _twoToneFixture({
  required List<int> bg,
  required List<int> ink,
  required List<int> aa,
  int w = 64,
  int h = 64,
  int inkSize = 24,
}) {
  final pixels = Uint8List(w * h * 4);
  void put(int x, int y, List<int> c) {
    final i = (y * w + x) * 4;
    pixels[i] = c[0];
    pixels[i + 1] = c[1];
    pixels[i + 2] = c[2];
    pixels[i + 3] = 255;
  }

  final left = (w - inkSize) ~/ 2;
  final top = (h - inkSize) ~/ 2;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      put(x, y, bg);
    }
  }
  // 1px 的抗锯齿圈（真实扫描件里是 1~2px）。
  for (var y = top - 1; y <= top + inkSize; y++) {
    for (var x = left - 1; x <= left + inkSize; x++) {
      if (x < 0 || y < 0 || x >= w || y >= h) continue;
      put(x, y, aa);
    }
  }
  for (var y = top; y < top + inkSize; y++) {
    for (var x = left; x < left + inkSize; x++) {
      put(x, y, ink);
    }
  }
  return RgbaImage(w, h, pixels);
}

void _textColorChecks(CheckSink check) {
  final rect = IntRect(4, 4, 60, 60);

  // --- 21) 白底黑字 → 取到黑（不是"黑与白的加权平均"）-------------------
  final darkOnLight = estimateTextColor(
    _twoToneFixture(
      bg: const [255, 255, 255],
      ink: const [0, 0, 0],
      aa: const [100, 100, 100],
    ),
    rect,
  );
  final darkOk = darkOnLight != null;
  check(
    'color.black_text_on_white',
    darkOk &&
        darkOnLight.textRgb.every((c) => c <= 32) &&
        darkOnLight.backgroundRgb.every((c) => c >= 223),
    darkOk
        ? 'text=${darkOnLight.textRgb} bg=${darkOnLight.backgroundRgb} '
            'samples=${darkOnLight.textSamples} eroded=${darkOnLight.eroded} '
            'contrast=${darkOnLight.contrast.toStringAsFixed(0)}'
        : 'estimateTextColor returned null on a synthetic black-on-white box',
  );

  // --- 22) 黑底白字 → 取到白 --------------------------------------------
  //
  // 🔴 这条是对"按亮度判文字"那类实现的证伪：白底黑字与黑底白字是两种都常见
  // 的排版（后者在夜间场景、反白 SFX 里到处都是），按亮度判必在其中一种上
  // 取反 —— 取反后拿到的是**背景色**，画上去就是隐形的字。
  final lightOnDark = estimateTextColor(
    _twoToneFixture(
      bg: const [0, 0, 0],
      ink: const [255, 255, 255],
      aa: const [155, 155, 155],
    ),
    rect,
  );
  final lightOk = lightOnDark != null;
  check(
    'color.white_text_on_black',
    lightOk &&
        lightOnDark.textRgb.every((c) => c >= 223) &&
        lightOnDark.backgroundRgb.every((c) => c <= 32),
    lightOk
        ? 'text=${lightOnDark.textRgb} bg=${lightOnDark.backgroundRgb} '
            'samples=${lightOnDark.textSamples}'
        : 'estimateTextColor returned null on a synthetic white-on-black box',
  );

  // --- 23) 故障实现「恒返回黑」必须被打红 ---------------------------------
  //
  // 🔴 对拍而不是许诺：把"恒黑"这个坏实现与正确实现放在同一块夹具上比，判据
  // 必须能分开两者。否则"取色功能已完成"这句话没有证据 —— 它在一个恒返回
  // 黑色的实现上也照样是绿的。
  final faultyBlack = <int>[0, 0, 0];
  final spread = lightOk
      ? (lightOnDark.textRgb[0] - faultyBlack[0]).abs() +
          (lightOnDark.textRgb[1] - faultyBlack[1]).abs() +
          (lightOnDark.textRgb[2] - faultyBlack[2]).abs()
      : 0;
  check(
    'color.constant_black_fault_is_caught',
    lightOk && spread > 300,
    lightOk
        ? 'white-on-black text=${lightOnDark.textRgb} vs a "always black" '
            'implementation $faultyBlack — channel spread $spread must stay huge'
        : 'no estimate to compare against the faulty implementation',
  );

  // --- 24) 腐蚀真的起作用（BT 口径的核心）--------------------------------
  //
  // 未腐蚀的均值把 1px 抗锯齿圈（本夹具里 100 灰）算进文字色，取到 26 灰而
  // 不是 0 —— 画上去就是"比原字淡一截"。腐蚀后只剩实心笔画。
  final noErosion = darkOk
      ? (darkOnLight.textRgb[0] + darkOnLight.textRgb[1] + darkOnLight.textRgb[2]) /
          3.0
      : 0.0;
  // 手算「不腐蚀」的期望值：784 个文字像素 = 576 个 0 + 208 个 100。
  const expectedWithoutErosion = (208 * 100) / 784;
  check(
    'color.erosion_removes_antialiased_edge',
    darkOk &&
        darkOnLight.eroded &&
        (noErosion - expectedWithoutErosion).abs() > 15,
    darkOk
        ? 'eroded mean=${noErosion.toStringAsFixed(1)}; '
            'skipping erosion would give '
            '${expectedWithoutErosion.toStringAsFixed(1)} '
            '(a visible "lighter than the original ink" shift)'
        : 'no estimate — cannot compare erosion modes',
  );

  // --- 25) 纯色区域返回 null，不编一个颜色出来 ---------------------------
  final flat = _twoToneFixture(
    bg: const [200, 200, 200],
    ink: const [200, 200, 200],
    aa: const [200, 200, 200],
  );
  check(
    'color.flat_region_returns_null',
    estimateTextColor(flat, rect) == null,
    'a uniform crop must yield null (there is no text to sample), got '
    '${estimateTextColor(flat, rect)}',
  );

  // --- 26) 彩字：色相要保住 ---------------------------------------------
  final red = estimateTextColor(
    _twoToneFixture(
      bg: const [200, 200, 200],
      ink: const [220, 20, 20],
      aa: const [210, 110, 110],
    ),
    rect,
  );
  final redOk = red != null;
  check(
    'color.coloured_text_keeps_hue',
    redOk &&
        red.textRgb[0] > 200 &&
        red.textRgb[1] < 60 &&
        red.textRgb[2] < 60,
    redOk
        ? 'text=${red.textRgb} (a red SFX must not come back grey)'
        : 'estimateTextColor returned null on coloured text',
  );

  // ⚠️ 刻意**不写**"同一输入两次结果一致"那条断言：它无法反向验证 —— 任何纯
  // 函数在相同输入上都给出相同输出，注入不了"让它变不确定"的故障，于是那条
  // 断言永远绿（装饰品）。无状态这件事由本文件头部的约定（纯 Dart、无全局
  // 可变状态）与"零 Flutter 依赖"保证，不靠一条打不红的断言装作验证过。

  // --- 27) `_color_auto` 的写/删语义（旧工程零字节 diff）------------------
  //
  // 🔴 这是"自动/手动"两条路径的开关：键存在 = 自动路径可以覆盖 `frgb`；
  // 键不存在 = 用户定的，谁都不许动。手动时**必须删键**，否则每个旧块落盘
  // 时都会多一个键，FT 零字节 diff 就破了。
  final block = TextBlock.createDefault(rect: IntRect(0, 0, 40, 20));
  final hadKeyAtBirth = block.raw.containsKey('_color_auto');
  block.colorIsAuto = true;
  final afterSet = block.raw['_color_auto'];
  block.colorIsAuto = false;
  final afterClear = block.raw.containsKey('_color_auto');
  check(
    'color.auto_flag_round_trip',
    !hadKeyAtBirth && afterSet == true && !afterClear,
    'new block carries the key=$hadKeyAtBirth (must be false); '
    'after set=$afterSet; after clearing it still exists=$afterClear',
  );
}

/// P33 新增的字体断言。全部自带「故障实现对拍」：每条都拿正确实现与一个
/// 写坏的变体同时跑，断言两者结果**不同** —— 这样"判据有没有区分力"在每次
/// 构建里都被检验，而不靠"写的时候手工试过一次"。
void _fontSystemChecks(CheckSink check, Directory root) {
  // --- 12) 装着的 CJK 字族要原样使用 -------------------------------------
  //
  // 合成表而不是真扫 `C:\Windows\Fonts`：扫描结果随机器而变，而断言必须是
  // 确定性的（"在这台机器上雅黑存在"证明不了代码对）。
  SystemFontInfo face(
    String family,
    Map<FontScript, double> coverage,
  ) => SystemFontInfo(
    family: family,
    subfamily: 'Regular',
    weight: 400,
    italic: false,
    path: '/fake/$family.ttf',
    codepoints: 20000,
    coverage: coverage,
  );
  final cjkOnly = <FontScript, double>{
    FontScript.cjk: 1.0,
    FontScript.latin: 1.0,
  };
  final latinOnly = <FontScript, double>{FontScript.latin: 1.0};
  systemFonts = SystemFontIndex(<SystemFontInfo>[
    face('Fake CJK Face', cjkOnly),
    face('Fake Latin Face', latinOnly),
    face('Microsoft YaHei UI', cjkOnly),
  ]);

  final installed = resolveFamily('Fake CJK Face');
  check(
    'font.system_family_used_when_installed',
    installed.family == 'Fake CJK Face' &&
        !installed.fallback &&
        installed.reason.contains('system font'),
    'resolveFamily("Fake CJK Face") -> "${installed.family}" '
    'fallback=${installed.fallback}; reason: ${installed.reason}',
  );

  // --- 13) 装着但**不能显示中文**的字族不许用 -----------------------------
  //
  // 🔴 这条守的是 A05 §3 的底线："中文一定出字"。FT 工程里写 `Arial` 完全
  // 可能，而 Arial 在每台 Windows 上都装着 —— 若"装了"就等于"能用"，译文
  // 会变成一片豆腐块且**不报错**。
  final latin = resolveFamily('Fake Latin Face');
  check(
    'font.non_cjk_system_family_not_used',
    latin.family == primaryBundledFamily && latin.fallback,
    'a Latin-only installed face must NOT be used: '
    '-> "${latin.family}" fallback=${latin.fallback}; reason: ${latin.reason}',
  );

  // --- 14) 系统字体压过历史别名 ------------------------------------------
  //
  // 别名表（雅黑→思源黑）的存在前提是"雅黑没被打进包里"。探测上线后这个
  // 前提不成立了：机器上真有雅黑还换成思源黑，等于静默替换用户意图。
  final yaheiLive = resolveFamily('Microsoft YaHei UI');
  check(
    'font.system_family_beats_legacy_alias',
    yaheiLive.family == 'Microsoft YaHei UI' && !yaheiLive.fallback,
    'with the face installed it must be used as-is: -> '
    '"${yaheiLive.family}" fallback=${yaheiLive.fallback}; '
    'reason: ${yaheiLive.reason}',
  );

  // --- 15) 选择器只列能出中文的系统字体 -----------------------------------
  final liveChoices = fontFamilyChoices(null);
  check(
    'font.selector_lists_installed_cjk_only',
    liveChoices.any((c) => c.family == 'Fake CJK Face') &&
        !liveChoices.any((c) => c.family == 'Fake Latin Face'),
    'listed: ${[for (final c in liveChoices) c.family].join(", ")} '
    '(a Latin-only face in this list would be a tofu trap)',
  );

  // --- 16) sfnt 解析：真实打包字体必须读出正确的名字与覆盖 ----------------
  //
  // 拿 `assets/fonts/` 里的真字体做 known-answer 测试：Noto Sans SC 有汉字
  // 与假名、**没有**谚文 —— 这一条同时验了 name 表解析与 cmap 覆盖判定。
  final scFile = File('${root.path}/assets/fonts/NotoSansSC-Regular.otf');
  if (!scFile.existsSync()) {
    check(
      'font.sfnt_parses_bundled_face',
      false,
      'NotoSansSC-Regular.otf missing — cannot verify the sfnt parser',
    );
    check(
      'font.sfnt_coverage_distinguishes_scripts',
      false,
      'NotoSansSC-Regular.otf missing — cannot verify cmap coverage',
    );
  } else {
    final bytes = scFile.readAsBytesSync();
    final info = parseFontBytes(bytes, scFile.path);
    final ok = info != null;
    check(
      'font.sfnt_parses_bundled_face',
      ok &&
          info.family == 'Noto Sans SC' &&
          info.weight == 400 &&
          !info.italic &&
          info.codepoints > 10000,
      ok
          ? 'family="${info.family}" weight=${info.weight} '
              'italic=${info.italic} codepoints=${info.codepoints} '
              'coverage=${info.coverage}'
          : 'parseFontBytes returned null on a real bundled OTF',
    );
    // 🔴 对拍：把 cmap 覆盖判成"全都支持"，这条断言立刻失去意义。下面这个
    // 坏变体用来证明判据本身有区分力（不是靠抛异常变红的装饰品）。
    final bad = ok
        ? SystemFontInfo(
            family: info.family,
            subfamily: info.subfamily,
            weight: info.weight,
            italic: info.italic,
            path: info.path,
            codepoints: info.codepoints,
            coverage: const <FontScript, double>{
              FontScript.cjk: 1.0,
              FontScript.hangul: 1.0,
              FontScript.kana: 1.0,
            },
          )
        : null;
    check(
      'font.sfnt_coverage_distinguishes_scripts',
      ok &&
          info.covers(FontScript.cjk) &&
          info.covers(FontScript.kana) &&
          !info.covers(FontScript.hangul) &&
          bad != null &&
          bad.covers(FontScript.hangul) != info.covers(FontScript.hangul),
      ok
          ? 'SC covers cjk=${info.coverage[FontScript.cjk]?.toStringAsFixed(2)} '
              'kana=${info.coverage[FontScript.kana]?.toStringAsFixed(2)} '
              'hangul=${info.coverage[FontScript.hangul]?.toStringAsFixed(2)} '
              '(hangul must be < $scriptCoverageThreshold); '
              'a coverage table hard-coded to 1.0 is distinguishable: '
              'hangul bad=${bad?.covers(FontScript.hangul)}'
          : 'no parse result to compare',
    );
  }

  // --- 17) sfnt 解析：垃圾字节返回 null，不抛 -----------------------------
  //
  // 🔴 系统字体目录里什么都可能躺着（`.fon`、零字节、快捷方式）。扫描一次要
  // 遍历几百个文件，任何一次抛异常都会让整次扫描半途而废 —— 而"字体列表
  // 少了一半"是不报错的。
  //
  // 🔴 这条断言要打中 line 116 的守卫（`tables == null` 时本应 return null）。
  // 纯随机字节会在 line 113 的**魔数校验**处就 return null，根本到不了 116，
  // 注入那里的故障时它不会红（装饰品）。所以这里喂一条「长得像 sfnt、但表
  // 目录为空」的坏字节：前 4 字节是合法魔数 0x00010000（通过魔数校验），接着
  // numTables=0 让 `_readTableDirectory` 返回 null —— 正好落进 116 的守卫。
  final junk = Uint8List(64);
  junk[0] = 0x00; junk[1] = 0x00; junk[2] = 0x01; junk[3] = 0x00; // sfnt magic
  junk[4] = 0x00; junk[5] = 0x00; // numTables = 0 → table dir null
  for (var i = 6; i < junk.length; i++) junk[i] = (i * 37 + 11) & 0xFF;
  SystemFontInfo? junkResult;
  var threw = false;
  try {
    junkResult = parseFontBytes(junk, '/fake/junk.bin');
  } catch (_) {
    threw = true;
  }
  check(
    'font.sfnt_rejects_garbage',
    !threw && junkResult == null,
    threw
        ? 'parseFontBytes THREW on a bogus sfnt (magic ok, empty table dir) — '
            'one bad file would abort the whole system font scan'
        : 'bogus sfnt (magic ok, 0 tables) -> '
            '${junkResult == null ? "null (rejected)" : "ACCEPTED"}',
  );

  // --- 18) 字距必须随字号缩放（⑦a-1 修的真 bug）--------------------------
  //
  // 🔴 成品路径 `page_renderer._fillStyle` 原来是 `(v - 1.0)` —— 0.15 个
  // **逻辑像素**，在 40px 的字上完全看不出来，于是"调字距滑块没反应"在出图
  // 上是个真 bug，而画布上是正常的。判据取 40px 下的具体数值，故障实现
  // （不乘字号）给出 0.15 —— 相差 40 倍，不可能靠边界相等蒙过去。
  final goodSpacing = letterSpacingPx(1.15, 40.0);
  final badSpacing = 1.15 - 1.0; // 漏乘字号的旧实现
  check(
    'font.letter_spacing_scales_with_size',
    goodSpacing != null &&
        (goodSpacing - 6.0).abs() < 1e-9 &&
        (goodSpacing - badSpacing).abs() > 1.0,
    'letterSpacingPx(1.15, 40) = $goodSpacing px; '
    'the old size-independent expression gives $badSpacing px '
    '(0.15 px is invisible — that was the bug)',
  );

  // --- 19) 行距默认值两端统一 ---------------------------------------------
  //
  // 画布侧写 `?? 1.15`、成品侧 `RegionFontStyle` 默认 1.2：同一个"没设过行距"
  // 的块在两端行高差 0.05em。
  check(
    'font.line_spacing_default_is_shared',
    lineSpacingOf(null) == defaultLineSpacingValue &&
        lineSpacingOf(2.0) == 2.0 &&
        defaultLineSpacingValue == 1.2,
    'lineSpacingOf(null)=${lineSpacingOf(null)} (was 1.15 on the canvas, '
    '1.2 in RegionFontStyle); explicit values pass through: '
    '${lineSpacingOf(2.0)}',
  );

  // --- 20) 字重表两端共用 -------------------------------------------------
  //
  // 两张逐行相同的 switch 原本分别躺在 `page_renderer._fontWeightOf` 与
  // `text_block_canvas._weight`，注释里还互相称对方为"查表/阶梯"。
  check(
    'font.weight_table_is_shared',
    fontWeightIndex(100) == 100 &&
        fontWeightIndex(350) == 300 &&
        fontWeightIndex(700) == 700 &&
        fontWeightIndex(999) == 900,
    '100->${fontWeightIndex(100)} 350->${fontWeightIndex(350)} '
    '700->${fontWeightIndex(700)} 999->${fontWeightIndex(999)}',
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
  List<String> pendingVerification,
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

  // --- 9) 两阶段产出的三个契约（S9.5-a 的新代码，此前零反向验证） ---------
  //
  // 三条都是"违反不报错、只是静默地少一半产物"那一类，所以它们必须有一个
  // 能被注入故障的地方（`A08 §6.2` 记的就是这三处抽口）。

  // 9a) 顺序契约：底图必须先于成品。
  //
  // 🔴 判据必须**同步**读，而且**只能**同步读：两个回调都不含 await，所以
  // `inLayeredOrder(...)` 一旦被调用，第一阶段已经开始、第二阶段还没有。
  // 若改成 `await` 完再读，两种顺序都会得到 `bases,results` —— 断言就永远绿了
  // （那正是这处抽口最容易写错的地方）。本函数是同步的，正好逼出这个判据。
  //
  // 三种写错的方式都会被打红：
  //   * 两阶段对调        → 同步读到 `results`；
  //   * 两个阶段并发起跑  → 同步读到 `bases,results`；
  //   * 一次都不跑        → 同步读到空串。
  final orderLog = <String>[];
  // ignore: unawaited_futures
  ProjectWriter.inLayeredOrder<void, void>(
    () async {
      orderLog.add('bases');
    },
    () async {
      orderLog.add('results');
    },
  );
  final synchronousOrder = orderLog.join(',');
  check(
    'inpaint.layered_order_bases_first',
    synchronousOrder == 'bases',
    'sync=[$synchronousOrder]（必须是 bases）—— '
    'result/ 以 inpainted/ 为输入位图；反过来跑只会把成品记成 skipped，'
    '"一张都没出"看起来像"这页没译文"',
  );

  // 9b) 降采样不许出底图。
  final sameWidth = canProduceInpaintedBase(
    decodedWidth: 8000,
    originalWidth: 8000,
  );
  final downscaled = canProduceInpaintedBase(
    decodedWidth: 4000,
    originalWidth: 8000,
  );
  check(
    'inpaint.base_requires_no_downscale',
    sameWidth && !downscaled,
    '同宽=$sameWidth；降采样=$downscaled（必须 false）—— '
    '否则 result/ 侧的 scale==1.0 变成谎言，框按源坐标落在缩小的图上',
  );

  // 9c) 底图只从原图取。
  final inpaintProbe = TranslationProject.create(
    jsonFile: File('${Directory.systemTemp.path}/_p1_inpaint_probe.json'),
    directory: Directory.systemTemp.path,
  );
  final baseSource = inpaintedBaseSourcePath(inpaintProbe, '0/1.webp');
  final forbiddenSource = inpaintProbe.artifactPath('inpainted', '0/1.webp');
  check(
    'inpaint.base_source_is_original',
    baseSource == inpaintProbe.originalPath('0/1.webp') &&
        baseSource != forbiddenSource,
    'source=$baseSource；禁止=$forbiddenSource '
    '(对已去字的位图再擦一遍会越擦越糊，且每保存一次更糊一点)',
  );

  // --- 10) 反向验证本身必须被记录 ----------------------------------------
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
    'inpaint.layered_order_bases_first',
    'inpaint.base_requires_no_downscale',
    'inpaint.base_source_is_original',
  };
  // 🔴 两个清单**合起来**必须覆盖 `known`，互不相交，且 `reverseVerified` 非空。
  //
  // 这里刻意**不**因"存在 pending"判 FAIL。要防的是**假的 ✅**：一个清单声称
  // 某条断言验证过、而它其实没被任何故障打红过。把 pending 显式列出来就已经消除
  // 了那个谎言。反过来若 pending 也判 FAIL，最省事的修法会变成"把未验证的名字从
  // 清单里删掉" —— 那会连带丢掉覆盖检查，让"漏了一条断言"重新变得看不出来。
  // **失效的清单比不完整的清单危险得多**，所以判据是"覆盖完整 + 分类无歧义"。
  final stated = [...reverseVerified, ...pendingVerification];
  final notVerified = [
    for (final name in stated)
      if (!known.contains(name)) name,
  ];
  final notClaimed = [
    for (final name in known)
      if (!stated.contains(name)) name,
  ];
  final overlap = [
    for (final name in reverseVerified)
      if (pendingVerification.contains(name)) name,
  ];
  final unverified = pendingVerification.isEmpty
      ? ''
      : ' — ${pendingVerification.length} NOT fault-verified yet '
          '(${pendingVerification.join(", ")})';
  check(
    'assertions.reverse_verification_recorded',
    reverseVerified.isNotEmpty &&
        notVerified.isEmpty &&
        notClaimed.isEmpty &&
        overlap.isEmpty,
    reverseVerified.isEmpty
        ? 'verified list is EMPTY — every assertion above is unverified and '
            'may be decorative (this must FAIL)'
        : notVerified.isNotEmpty
        ? 'lists name assertions that do not exist: ${notVerified.join(", ")}'
        : notClaimed.isNotEmpty
        ? 'no verification status recorded for: ${notClaimed.join(", ")}'
        : overlap.isNotEmpty
        ? 'listed as both verified and pending: ${overlap.join(", ")}'
        : '${reverseVerified.length} assertions confirmed FAIL under an '
            'injected fault$unverified',
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