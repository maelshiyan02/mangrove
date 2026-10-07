/// S9.5-a · 端到端实机验证工装。
///
/// `venera.exe --headless pipeline-check <comicId|project.json> [options]`
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
/// | 去重 | `overlapsExistingBlock(page, rect)` |
/// | 落地 | `captureBlockListEdit` + `EditHistory.push`（**硬规矩 3** 的唯一入口） |
/// | 保存 | `ProjectWriter.save(root: project.workspace, keepBackup: true)` |
/// | 出图 | `ProjectWriter.writeArtifacts(kinds: {result})` + `renderProjectResultPage` |
///
/// 只要有一环"另写一套"，它验的就不是工作室，而是工装自己。
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
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:venera/foundation/bt_project/bt_project_manager.dart';
import 'package:venera/foundation/image_translation/balloon_clustering.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/translation_project/edit_command.dart';
import 'package:venera/foundation/translation_project/project.dart';
import 'package:venera/foundation/translation_project/project_io.dart';
import 'package:venera/foundation/translation_project/project_writer.dart';
import 'package:venera/foundation/translation_project/result_renderer.dart';
import 'package:venera/foundation/translation_project/studio_pipeline.dart';

void _cli(Map<String, dynamic> data) =>
    print('[CLI PRINT] ${jsonEncode(data)}');

/// 一页的全程记录。字段名与 `StudioPageRun` 对齐但**不复用**它 —— 工装要多记
/// "落盘前后"的观测量，那是管线不知道的事。
class _PageRecord {
  _PageRecord(this.pageKey);

  final String pageKey;
  int blocksBefore = 0;
  int blocksAfter = 0;
  int detected = 0;
  int landed = 0;
  int deduped = 0;
  int skipped = 0;
  String? baseSource;
  String? error;
  bool imageInfoMissing = false;
  int resultBytes = 0;
  String? resultHash;

  Map<String, Object?> toJson() => {
    'page': pageKey,
    'blocksBefore': blocksBefore,
    'detected': detected,
    'deduped': deduped,
    'landed': landed,
    'blocksAfter': blocksAfter,
    'skippedLines': skipped,
    'base': baseSource,
    'imageInfoMissing': imageInfoMissing,
    if (error != null) 'error': error,
    'resultBytes': resultBytes,
    if (resultHash != null) 'resultHash': resultHash,
  };
}

class _Round {
  _Round(this.label);

  final String label;
  final pages = <_PageRecord>[];
  int resultWritten = 0;
  int resultSkipped = 0;
  int resultFailed = 0;
  int resultOnDisk = 0;
  int inpaintedWritten = 0;
  int inpaintedSkipped = 0;
  int totalLanded = 0;
  int failedPages = 0;
  final skippedReasons = <String, int>{};
  Map<String, Object?> stage = const <String, Object?>{};

  Map<String, Object?> toJson() => {
    'label': label,
    'stages': stage,
    'totalLanded': totalLanded,
    'failedPages': failedPages,
    'inpaintedWritten': inpaintedWritten,
    'inpaintedSkipped': inpaintedSkipped,
    'resultWritten': resultWritten,
    'resultSkipped': resultSkipped,
    'resultFailed': resultFailed,
    'resultOnDisk': resultOnDisk,
    'resultAbsentReasons': skippedReasons,
    'pages': [for (final p in pages) p.toJson()],
  };
}

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
    if (_resolveBase(project, key) != null) allKeys.add(key);
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
  final rounds = <_Round>[];
  var live = project;
  for (var r = 0; r < repeat; r++) {
    // 第 2 轮起从盘上重读：否则比的是内存里的同一份对象，"幂等"无从谈起。
    if (r > 0) live = await TranslationProjectIo.load(live.jsonFile);
    final round = _Round('run${r + 1}');
    await _runOnce(live, keys, options, round);
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

Future<void> _runOnce(
  TranslationProject project,
  List<String> keys,
  StudioRunOptions options,
  _Round round,
) async {
  final pipeline = StudioPagePipeline();
  final history = EditHistory();
  final cancel = CancellationToken();

  var detectPages = 0;
  var detectBlocks = 0;
  var detectSkipped = 0;
  var landed = 0;
  var deduped = 0;

  for (final pageKey in keys) {
    final record = _PageRecord(pageKey);
    round.pages.add(record);
    final page = project.pages[pageKey];
    record.blocksBefore = page?.blocks.length ?? 0;
    // 失败页也要报出真实的落盘前块数，否则 `blocksAfter: 0` 会被读成"原来就没有块"。
    record.blocksAfter = record.blocksBefore;

    final base = _resolveBase(project, pageKey);
    if (base == null) {
      record.error = 'no page image on disk';
      continue;
    }
    record.baseSource = base.$2;
    final size = _pageSizeInPixels(project, pageKey);
    record.imageInfoMissing = size.$2;

    final Uint8List bytes;
    try {
      bytes = await base.$1.readAsBytes();
    } catch (e) {
      record.error = 'read failed: $e';
      continue;
    }

    final run = await pipeline.runPage(
      pageKey,
      bytes,
      options: options,
      pageWidth: size.$1.round(),
      cancel: cancel,
    );
    if (run.error != null) {
      record.error = '${run.error}';
      continue;
    }
    record.detected = run.blocks.length;
    record.skipped = run.skipped;
    detectPages++;
    detectBlocks += run.blocks.length;
    detectSkipped += run.skipped;

    if (page == null) {
      record.error = 'page key not in project';
      continue;
    }
    // 去重：**只读**既有块（`overlapsExistingBlock` 明写绝不改动它们）。
    final fresh = [
      for (final block in run.blocks)
        if (!overlapsExistingBlock(page, block.rect)) block,
    ];
    record.deduped = run.blocks.length - fresh.length;
    record.landed = fresh.length;
    landed += fresh.length;
    deduped += record.deduped;

    if (fresh.isNotEmpty) {
      // 🔴 硬规矩 3：任何写 `pages[key]` 的路径都必须走登记入口，否则
      // `result/` 增量重渲会漏页 —— 这里与 Create/Delete 块共用同一条。
      final command = captureBlockListEdit(
        page.rawBlocks,
        () => page.addBlocks(fresh),
        pageKey: pageKey,
        label: 'Pipeline detect',
      );
      if (!command.isEmpty) history.push(command);
    }
    record.blocksAfter = page.blocks.length;
    round.totalLanded += record.landed;
  }

  round.failedPages = round.pages.where((p) => p.error != null).length;
  final dirty = history.dirtyPages;

  // ---- 保存（统一契约，与工作室 Ctrl+S 同一条） ----
  final saveReport = await ProjectWriter.save(
    root: project.workspace,
    project: project,
    keepBackup: true,
  );
  history.markSaved();

  // ---- 出图（两阶段，与 `studio_page._regenerateResults` 同一条） ----
  //
  // 🔴 顺序不可交换：`result/` 以 `inpainted/` 为**输入位图**，而
  // `writeArtifacts` 内部是并发 worker —— 放进同一次调用会读到还没写出来的
  // 底图。全量（不走脏页 filter），理由见文件头。
  final baseReport = await ProjectWriter.writeArtifacts(
    root: project.workspace,
    project: project,
    kinds: const {ProjectArtifactKind.inpainted},
    concurrency: 2,
    source: (kind, pageKey) => renderInpaintedPage(project, pageKey),
  );
  final artifactReport = await ProjectWriter.writeArtifacts(
    root: project.workspace,
    project: project,
    kinds: const {ProjectArtifactKind.result},
    concurrency: 2,
    source: (kind, pageKey) => renderProjectResultPage(project, pageKey),
  );
  round.inpaintedWritten = baseReport.written.length;
  round.inpaintedSkipped = baseReport.skipped.length;
  round.resultWritten = artifactReport.written.length;
  round.resultSkipped = artifactReport.skipped.length;
  round.resultFailed = artifactReport.failed.length;

  // 逐页取**盘上**哈希：这是"内容哈希与重跑一致"的唯一来源。
  for (final record in round.pages) {
    final file = File(
      ProjectWriter.artifactPath(
        project.workspace,
        ProjectArtifactKind.result,
        record.pageKey,
      ),
    );
    if (!file.existsSync()) continue;
    final data = await file.readAsBytes();
    round.resultOnDisk++;
    record.resultBytes = data.length;
    record.resultHash = sha256.convert(data).toString().substring(0, 16);
  }
  // 没出图的页，说清是哪一类原因 —— 只看"0 张"分不清。
  //
  // 🔴 顺序即语义：**检测失败的页必须先报检测失败**。第一版按
  // "页键缺失 → 无译文 → 无底图 → 渲染器返回 null" 的顺序取第一个成立的，
  // 于是 94 页全部报成 `no translated region` —— 字面没错（确实没有 region），
  // 但它把真正的根因（`No Impeller context is available`，解码在第一行就挂了）
  // 藏在了第二层。这正是本项目最忌讳的那类"静默分歧"：一个数字看起来正常，
  // 成因却是另一回事。
  for (final record in round.pages) {
    if (record.resultBytes > 0) continue;
    final reason = _absentReason(
      project,
      record.pageKey,
      project.pages[record.pageKey],
      record.error,
    );
    round.skippedReasons[reason] = (round.skippedReasons[reason] ?? 0) + 1;
  }

  round.stage = {
    'detect': {
      'pages': detectPages,
      'blocks': detectBlocks,
      'skippedLines': detectSkipped,
    },
    'land': {
      'landed': landed,
      'deduped': deduped,
      'dirtyPages': dirty.length,
    },
    'save': {
      'json': saveReport.jsonFile.path,
      'jsonBytes': saveReport.bytes,
      'artifactDirs': saveReport.artifactDirectories
          .map((d) => d.split(RegExp(r'[\\/]')).last)
          .toList(),
    },
    'result': {
      'inpaintedWritten': round.inpaintedWritten,
      'inpaintedSkipped': round.inpaintedSkipped,
      'written': round.resultWritten,
      'skipped': round.resultSkipped,
      'failed': round.resultFailed,
      'onDisk': round.resultOnDisk,
    },
  };

  for (final (artifact, error) in artifactReport.failed) {
    Log.error('pipeline-check', 'result ${artifact.path}: $error');
  }
}

/// 为什么这一页没有 `result/` 文件 —— 成因分开报，**根因优先**。
String _absentReason(
  TranslationProject project,
  String pageKey,
  ProjectPage? page,
  String? pageError,
) {
  // 上游就挂了的页，先说上游。没有这一支，解码/OCR 的失败会被降级成
  // "这一页没有译文"，读起来像"这页本来就没文字"。
  if (pageError != null) return 'upstream failed: $pageError';
  if (page == null) return 'page key missing';
  if (page.regions.isEmpty) return 'no translated region';
  final inpainted = project.inpaintedPath(pageKey);
  if (inpainted == null || !File(inpainted).existsSync()) {
    return 'no inpainted base';
  }
  return 'renderer returned null';
}

/// 与 `studio_page._resolvePageFile` 同一条回退链，附带来源标签。
(File, String)? _resolveBase(TranslationProject project, String pageKey) {
  final original = File(project.originalPath(pageKey));
  if (original.existsSync()) return (original, 'original');
  for (final kind in const ['inpainted', 'mask']) {
    final file = File(project.artifactPath(kind, pageKey));
    if (file.existsSync()) return (file, kind);
  }
  return null;
}

/// 与 `studio_page._pageSizeInPixels` 同一条：FT 的 `image_info`，缺则回落
/// 1200×1800。第二项报告"是否回落了" —— 回落会让 `clusterBalloons` 的列切分
/// 用一个**不是这页真实宽度**的值，是聚类质量的隐形变量。
(double, bool) _pageSizeInPixels(TranslationProject project, String pageKey) {
  final info = project.imageInfo[pageKey];
  final width = info is Map ? (info['width'] as num?)?.toDouble() : null;
  final height = info is Map ? (info['height'] as num?)?.toDouble() : null;
  if (width == null || height == null || width <= 0 || height <= 0) {
    return (1200.0, true);
  }
  return (width, false);
}
