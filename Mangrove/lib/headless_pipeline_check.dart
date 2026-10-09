/// S9.5-a · 端到端实机验证工装。
///
/// `mangrove.exe --headless pipeline-check <comicId|project.json> [options]`
///
/// ## 它存在的理由
///
/// S9 之前所有验证都只覆盖了**算法与接缝**：`cluster.*` 断言喂的是人造
/// `TextLine`，`pipeline.*` 断言喂的是人造 `OcrBlock`。整条
/// 「检测 → OCR → 翻译 → 落块 → 保存 → 出图」**一次都没被真正执行过**
/// （`P9.6 §六 #8` · `P6 §4.0.1`）。
///
/// 缺口不在"没人写代码"，而在**没人把它跑起来**：真实检测要 ONNX 模型 +
/// 原图，而 `edit-check` 是纯 Dart 的、在 `init()` 之前就跑完了。
///
/// 本命令在 `init()` **之后**运行（模型路径、`LocalManager`、`appdata` 都就绪），
/// 并且**刻意复用工作室的每一条真实路径**而不是另写一套：
///
/// | 环节 | 复用的东西 |
/// |---|---|
/// | 语向配置 | `TranslationConfig.of(comicId, null)` |
/// | 页面解析 | `original → inpainted → mask`（`studio_page._resolvePageFile`） |
/// | 页宽 | `project.imageInfo[key]`（`studio_page._pageSizeInPixels`） |
/// | 单页管线 | `StudioPagePipeline().runPage(...)` |
/// | 整章循环 | **`StudioChapterRunner.run(...)`** —— 与阅读侧入队**同一个函数** |
/// | 去重 | `overlapsExistingBlock(page, rect)` |
/// | 落地 | `captureBlockListEdit` + `EditHistory.push`（**硬规矩 3** 的唯一入口） |
/// | 保存 | `ProjectWriter.save(root: project.workspace, keepBackup: true)` |
/// | 出图 | `ProjectWriter.writeArtifacts(kinds: {result})` + `renderProjectResultPage` |
///
/// 只要有一环"另写一套"，它验的就不是工作室，而是工装自己。
///
/// 🔴 第 3 行是 S9.5-b 加的：整章循环本来长在本文件的 `_runOnce` 里，现在搬进了
/// `studio_chapter_runner.dart` —— 因为**应用**（阅读页开关 = 该章入队）也需要
/// 同一个循环。留在两处的话，工装验的就不再是产品跑的那条路（`P6 §S9.5` 交付 1）。
///
/// ## 输出
///
/// 与 `edit-check` 同形的 `[CLI PRINT]` 行 + 一份 `--json` 报告。报告里
/// **每条结论都必须带一个数字或一句原话**（`P9.6 §四`：没有观测量的断言是
/// 装饰品）。特别地：
///
/// - `result/` 一张都没出时，报告**逐条给出原因分类** ——
///   `renderProjectResultPage` 返回 null 有四种完全不同的成因
///   （页键不存在／无译文／无 `inpainted/` 底图／渲染器返回空），
///   只看"0 张"分不清是哪一种。
/// - `--repeat N` 跑 N 轮并逐页比对 `result/` 的**盘上**内容哈希：这是验收里
///   「内容哈希与重跑一致（幂等）」那一条的可执行形式。刻意不使用
///   `artifactReport` 的内存结果 —— 那就没验证到落盘的那一字节。
/// - 每轮都走**全量** `planArtifacts`（不走脏页 filter）：脏页增量已由
///   `edit-check` 的 `dirty.filter_selects_one` 断言锁住，这里要的是
///   "同样的输入是否给出同样的字节"。
library;

import 'dart:convert';
import 'dart:io';

import 'package:mangrove/foundation/bt_project/bt_project_manager.dart';
import 'package:mangrove/foundation/image_translation/balloon_clustering.dart';
import 'package:mangrove/foundation/image_translation/translation_config.dart';
import 'package:mangrove/foundation/translation_project/project.dart';
import 'package:mangrove/foundation/translation_project/project_io.dart';
import 'package:mangrove/foundation/translation_project/studio_chapter_runner.dart';
import 'package:mangrove/foundation/translation_project/studio_pipeline.dart';

void _cli(Map<String, dynamic> data) =>
    print('[CLI PRINT] ${jsonEncode(data)}');

Future<void> runPipelineCheck(List<String> args, int commandIndex) async {
  final jsonIndex = args.indexOf('--json');
  final outPath = jsonIndex != -1 && jsonIndex + 1 < args.length
      ? args[jsonIndex + 1]
      : '${Directory.current.path}/pipeline_check.json';

  String? option(String name) {
    final i = args.indexOf(name);
    if (i == -1 || i + 1 >= args.length) return null;
    return args[i + 1];
  }

  final target = commandIndex + 1 < args.length &&
          !args[commandIndex + 1].startsWith('--')
      ? args[commandIndex + 1]
      : null;
  final limit = int.tryParse(option('--limit') ?? '') ?? 0;
  final repeat = ((int.tryParse(option('--repeat') ?? '') ?? 1).clamp(1, 5))
      .toInt();
  final translate = !args.contains('--no-translate');
  final chapterFilter = option('--chapter');

  Future<void> finish(
    bool passed,
    String message,
    Map<String, Object?> report,
  ) async {
    final output = File(outPath);
    if (!output.parent.existsSync()) {
      await output.parent.create(recursive: true);
    }
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'command': 'pipeline-check',
        'passed': passed,
        ...report,
      }),
      encoding: utf8,
    );
    _cli({
      'status': passed ? 'success' : 'error',
      'message': message,
      'data': {'report': output.path},
    });
  }

  if (target == null) {
    await finish(
      false,
      'Usage: --headless pipeline-check <comicId|project.json> '
          '[--chapter d] [--limit n] [--no-translate] [--repeat n] [--json out]',
      const <String, Object?>{},
    );
    exit(1);
  }

  // ---- 工程载入：`bt_` id 走登记表（与工作室同一条），否则直接读 json ----
  final TranslationProject project;
  var comicId = target;
  if (target.startsWith(BtProjectManager.idPrefix)) {
    final loaded = await BtProjectManager().ensureTranslationProject(target);
    if (loaded == null) {
      await finish(false, 'Project not resolved: $target', const <String, Object?>{});
      exit(1);
    }
    project = loaded;
  } else {
    final file = File(target);
    if (!file.existsSync()) {
      await finish(false, 'Project not found: $target', const <String, Object?>{});
      exit(1);
    }
    project = await TranslationProjectIo.load(file);
    comicId = project.jsonFileName;
  }

  // ---- 页集：与 `studio_page._pageExists` 同一条判据 ----
  final allKeys = <String>[];
  for (final key in project.pageOrder) {
    if (chapterFilter != null && !key.startsWith('$chapterFilter/')) continue;
    if (StudioChapterRunner.resolveBase(project, key) != null) allKeys.add(key);
  }
  final keys = limit > 0 && limit < allKeys.length
      ? allKeys.sublist(0, limit)
      : allKeys;

  if (keys.isEmpty) {
    await finish(
      false,
      'No readable page image in ${project.jsonFileName}'
          '${chapterFilter == null ? '' : ' (chapter $chapterFilter)'}',
      {
        'project': {
          'json': project.jsonFileName,
          'workspace': project.workspace,
          'directory': project.directory,
          'pageOrder': project.pageOrder.length,
          'readable': 0,
        },
      },
    );
    exit(1);
  }

  final config = TranslationConfig.of(comicId, null);
  final options = StudioRunOptions(
    sourceLang: config.sourceLang,
    targetLang: config.targetLang,
    readingDirection: ReadingDirection.rightToLeft,
    translate: translate,
  );
  final startedAt = DateTime.now();
  final blocksBeforeTotal = keys.fold<int>(
    0,
    (sum, key) => sum + (project.pages[key]?.blocks.length ?? 0),
  );

  // ---- 逐轮 ----
  final rounds = <StudioChapterRun>[];
  var live = project;
  for (var r = 0; r < repeat; r++) {
    // 第 2 轮起从盘上重读：否则比的是内存里的同一份对象，"幂等"无从谈起。
    if (r > 0) live = await TranslationProjectIo.load(live.jsonFile);
    final round = await StudioChapterRunner.run(
      project: live,
      pageKeys: keys,
      options: options,
      label: 'run${r + 1}',
    );
    rounds.add(round);
    _cli({
      'status': 'running',
      'message': 'Round ${r + 1}',
      'data': {
        'landed': round.totalLanded,
        'failedPages': round.failedPages,
        'inpaintedWritten': round.inpaintedWritten,
        'resultWritten': round.resultWritten,
        'resultOnDisk': round.resultOnDisk,
      },
    });
  }

  // ---- 跨轮比对：幂等的可执行形式 ----
  final idempotency = <String, Object?>{};
  if (rounds.length >= 2) {
    final first = {for (final p in rounds[0].pages) p.pageKey: p};
    final second = {for (final p in rounds[1].pages) p.pageKey: p};
    final mismatched = <String>[];
    final missing = <String>[];
    for (final entry in first.entries) {
      final b = second[entry.key];
      if (b == null) {
        missing.add(entry.key);
      } else if (entry.value.resultHash != b.resultHash) {
        mismatched.add(
          '${entry.key} (${entry.value.resultHash ?? '-'} -> '
          '${b.resultHash ?? '-'})',
        );
      }
    }
    idempotency
      ..['comparable'] = true
      ..['hashMismatches'] = mismatched
      ..['missingInSecondRun'] = missing
      ..['stable'] = mismatched.isEmpty && missing.isEmpty;
  } else {
    idempotency
      ..['comparable'] = false
      ..['note'] = 'pass --repeat 2 to compare result/ hashes across runs';
  }

  // ---- 失败清单与分布 ----
  final failedPages = [
    for (final p in rounds.first.pages)
      if (p.error != null) {'page': p.pageKey, 'error': p.error},
  ];
  final histogram = <String, int>{};
  for (final p in rounds.first.pages) {
    final bucket = p.landed == 0
        ? '0'
        : p.landed <= 3
        ? '1-3'
        : p.landed <= 8
        ? '4-8'
        : p.landed <= 15
        ? '9-15'
        : '16+';
    histogram[bucket] = (histogram[bucket] ?? 0) + 1;
  }

  final head = rounds.first;
  // 🔴 **顺序即诊断**：把"上游挂了"排在"下游没产出"之前。反过来的话，
  // 阅读者第一眼看到的是 `result/ is EMPTY`，会去找渲染器的问题，
  // 而真正的断点在更上游。
  final findings = <String>[];
  if (head.failedPages > 0) {
    findings.add(
      '${head.failedPages}/${head.pages.length} page(s) failed detect/OCR — '
      'first error: ${head.pages.firstWhere((p) => p.error != null).error}',
    );
  }
  final noImageInfo = head.pages.where((p) => p.imageInfoMissing).length;
  if (noImageInfo > 0) {
    findings.add(
      '$noImageInfo page(s) had no image_info entry, so clustering used the '
      '1200×1800 fallback page width instead of the real one',
    );
  }
  if (!translate) {
    findings.add(
      '--no-translate: the LLM leg was skipped, so blocks carry no translation '
      'and result/ cannot render',
    );
  }
  if (head.resultOnDisk == 0) {
    findings.add(
      'result/ is EMPTY — the 出图 leg produced nothing. '
      'inpainted written=${head.inpaintedWritten} '
      'skipped=${head.inpaintedSkipped}; per-page reasons: '
      '${jsonEncode(head.skippedReasons)}',
    );
  }

  final elapsed = DateTime.now().difference(startedAt);
  // 「通过」只看**能自动判定**的三条，与 §4.10 序 0 的验收对齐；
  // 块数与 FT 的对比需要人眼，报告给的是直方图与逐页清单。
  final passed =
      failedPages.isEmpty && (!translate || head.resultOnDisk > 0);

  await finish(
    passed,
    passed
        ? 'pipeline-check OK: ${keys.length} pages, '
            '${head.totalLanded} block(s) landed, '
            '${head.resultWritten} result(s) written in ${elapsed.inSeconds}s'
        : 'pipeline-check problems: ${failedPages.length} failed page(s), '
            '${head.resultOnDisk} result file(s) on disk',
    {
      'project': {
        'json': project.jsonFileName,
        'workspace': project.workspace,
        'directory': project.directory,
        'pageOrder': project.pageOrder.length,
        'readable': allKeys.length,
        'planned': keys.length,
        'limit': limit,
        'chapter': chapterFilter,
      },
      'options': {
        'sourceLang': options.sourceLang,
        'targetLang': options.targetLang,
        'translate': translate,
        'readingDirection': 'rightToLeft',
        'repeat': repeat,
      },
      'rounds': [for (final r in rounds) r.toJson()],
      'idempotency': idempotency,
      'failedPages': failedPages,
      'landedHistogram': histogram,
      'blocksBeforeFirstRun': blocksBeforeTotal,
      'findings': findings,
      'elapsedSeconds': elapsed.inMilliseconds / 1000.0,
    },
  );
  exit(passed ? 0 : 1);
}
