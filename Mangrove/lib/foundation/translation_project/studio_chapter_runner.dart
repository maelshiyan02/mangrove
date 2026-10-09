// S9.5-b · 整章跑管线 —— **唯一实现**。
//
// 这一段代码原先长在 `headless_pipeline_check.dart` 的 `_runOnce` 里。S9.5-b 把它
// 搬到库里，理由只有一条（P6 §S9.5 交付 1）：
//
// 阅读页的开关语义变成"打开 = **该章入队工作室管线**"之后，**应用**也需要一个
// "把一整章跑完"的入口。如果那个入口在 app 侧另写一套（自己 for 循环、自己
// 调 `ProjectWriter`），那么 `--headless pipeline-check` 验的就不再是应用跑的
// 那条路 —— 而"工装验的不是产品"正是这个项目反复栽的坑（`P9.6 §四`）。
//
// 于是两侧共用本文件：工装传全部页、不做进度回调；阅读侧传缺产物的页、带进度
// 回调。**顺序、去重、落地入口、保存契约、两阶段出图顺序**只在这里写一次。
//
// 🔴 三处不可动的契约（每一处都有故障注入断言瞄着，动之前先看 `A08 §6.2`）：
//
// 1. **落地必须走 `captureBlockListEdit` + `EditHistory.push`**（硬规矩 3）：
//    绕过它就等于绕过脏页登记，`result/` 增量重渲会漏页。
// 2. **出图两阶段顺序不可交换**（`ProjectWriter.inLayeredOrder`）：
//    `result/` 以 `inpainted/` 为输入位图，同一次并发调用里会读到还没写出来的底图。
// 3. **去重只能读既有块**（`overlapsExistingBlock`）：覆盖用户校对过的块 = 丢掉
//    人工工作。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../log.dart';
import 'edit_command.dart';
import 'project.dart';
import 'project_writer.dart';
import 'result_renderer.dart';
import 'studio_pipeline.dart';

/// 一页的全程记录。
///
/// 字段名与 `StudioPageRun` 对齐但**不复用**它 —— 本类要多记"落盘前后"的观测
/// 量，那是管线不知道的事。`toJson()` 的键名是 `--headless pipeline-check`
/// 报告的一部分，属于对外契约。
class StudioChapterPageRun {
  StudioChapterPageRun(this.pageKey);

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

  bool get failed => error != null;

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

/// 一次整章运行的汇总。
class StudioChapterRun {
  StudioChapterRun(this.label);

  final String label;
  final pages = <StudioChapterPageRun>[];

  int detectedPages = 0;
  int detectedBlocks = 0;
  int detectedSkipped = 0;
  int totalLanded = 0;
  int deduped = 0;
  int failedPages = 0;
  int dirtyPages = 0;
  bool canceled = false;

  int inpaintedWritten = 0;
  int inpaintedSkipped = 0;
  int resultWritten = 0;
  int resultSkipped = 0;
  int resultFailed = 0;
  int resultOnDisk = 0;

  /// 没出 `result/` 的页**按成因分类**。只看"0 张"分不清是哪一种。
  final skippedReasons = <String, int>{};

  String? jsonPath;
  int jsonBytes = 0;
  List<String> artifactDirs = const [];

  /// 与 `--headless pipeline-check` 报告的 `rounds[i]` 逐键同形。
  Map<String, Object?> toJson() => {
    'label': label,
    'stages': {
      'detect': {
        'pages': detectedPages,
        'blocks': detectedBlocks,
        'skippedLines': detectedSkipped,
      },
      'land': {
        'landed': totalLanded,
        'deduped': deduped,
        'dirtyPages': dirtyPages,
      },
      'save': {
        'json': jsonPath,
        'jsonBytes': jsonBytes,
        'artifactDirs': artifactDirs,
      },
      'result': {
        'inpaintedWritten': inpaintedWritten,
        'inpaintedSkipped': inpaintedSkipped,
        'written': resultWritten,
        'skipped': resultSkipped,
        'failed': resultFailed,
        'onDisk': resultOnDisk,
      },
    },
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

/// 「跑一整章」的唯一实现。见文件头。
abstract final class StudioChapterRunner {
  StudioChapterRunner._();

  /// 跑 [pageKeys]。**每页一次 undo 记录**（`EditHistory.limit` 是 200，整章
  /// 97 页 × 平均 8 块 = 776 步，按块 push 会把最早的编辑挤出栈）。
  ///
  /// [onPage] 在**每一页结束后**调用（含失败页），用来驱动进度显示。
  /// [onBeforeArtifacts] 在保存之后、出图之前调用 —— 两阶段出图前把 JSON 与
  /// 底图落到盘上，调用方据此登记产物变更（阅读器的缓存失效）。
  static Future<StudioChapterRun> run({
    required TranslationProject project,
    required List<String> pageKeys,
    required StudioRunOptions options,
    String label = 'run1',
    CancellationToken? cancel,
    bool keepBackup = true,
    bool fullArtifacts = true,
    void Function(StudioChapterPageRun page, int index, int total)? onPage,
  }) async {
    final run = StudioChapterRun(label);
    final pipeline = StudioPagePipeline();
    final history = EditHistory();
    final token = cancel ?? CancellationToken();

    for (var i = 0; i < pageKeys.length; i++) {
      final pageKey = pageKeys[i];
      final record = StudioChapterPageRun(pageKey);
      run.pages.add(record);

      if (token.isCanceled) {
        record.error = 'canceled';
        run.canceled = true;
        onPage?.call(record, i, pageKeys.length);
        break;
      }

      final page = project.pages[pageKey];
      record.blocksBefore = page?.blocks.length ?? 0;
      // 失败页也要报出真实的落盘前块数，否则 `blocksAfter: 0` 会被读成
      // "原来就没有块"。
      record.blocksAfter = record.blocksBefore;

      await _runPage(
        project: project,
        pageKey: pageKey,
        page: page,
        record: record,
        options: options,
        pipeline: pipeline,
        history: history,
        token: token,
        run: run,
      );
      onPage?.call(record, i, pageKeys.length);
    }

    run.failedPages = run.pages.where((p) => p.failed && p.error != 'canceled').length;
    run.dirtyPages = history.dirtyPages.length;
    run.totalLanded = run.pages.fold(0, (sum, p) => sum + p.landed);

    // ---- 保存（统一契约，与工作室 Ctrl+S 同一条） ----
    final saveReport = await ProjectWriter.save(
      root: project.workspace,
      project: project,
      keepBackup: keepBackup,
    );
    history.markSaved();
    run.jsonPath = saveReport.jsonFile.path;
    run.jsonBytes = saveReport.bytes;
    run.artifactDirs = [
      for (final d in saveReport.artifactDirectories)
        d.split(RegExp(r'[\\/]')).last,
    ];

    // ---- 出图（两阶段，与 `studio_page._regenerateResults` 同一条） ----
    //
    // 🔴 顺序不可交换：`result/` 以 `inpainted/` 为**输入位图**，而
    // `writeArtifacts` 内部是并发 worker —— 放进同一次调用会读到还没写出来的
    // 底图。全量（不走脏页 filter），因为这正是"同样的输入是否给出同样的字节"
    // 要跑的那条路。
    final (baseReport, artifactReport) = await ProjectWriter.inLayeredOrder(
      () => ProjectWriter.writeArtifacts(
        root: project.workspace,
        project: project,
        kinds: const {ProjectArtifactKind.inpainted},
        concurrency: 2,
        source: (kind, pageKey) => renderInpaintedPage(project, pageKey),
      ),
      () => ProjectWriter.writeArtifacts(
        root: project.workspace,
        project: project,
        kinds: const {ProjectArtifactKind.result},
        concurrency: 2,
        source: (kind, pageKey) => renderProjectResultPage(project, pageKey),
      ),
    );
    run.inpaintedWritten = baseReport.written.length;
    run.inpaintedSkipped = baseReport.skipped.length;
    run.resultWritten = artifactReport.written.length;
    run.resultSkipped = artifactReport.skipped.length;
    run.resultFailed = artifactReport.failed.length;

    // 逐页取**盘上**哈希：这是"内容哈希与重跑一致"的唯一来源。
    for (final record in run.pages) {
      final file = File(
        ProjectWriter.artifactPath(
          project.workspace,
          ProjectArtifactKind.result,
          record.pageKey,
        ),
      );
      if (!file.existsSync()) continue;
      final data = await file.readAsBytes();
      run.resultOnDisk++;
      record.resultBytes = data.length;
      record.resultHash = sha256.convert(data).toString().substring(0, 16);
    }
    for (final record in run.pages) {
      if (record.resultBytes > 0) continue;
      final reason = absentReason(
        project,
        record.pageKey,
        project.pages[record.pageKey],
        record.error,
      );
      run.skippedReasons[reason] = (run.skippedReasons[reason] ?? 0) + 1;
    }

    for (final (artifact, error) in artifactReport.failed) {
      Log.error('Studio Chapter', 'result ${artifact.path}: $error');
    }
    return run;
  }

  static Future<void> _runPage({
    required TranslationProject project,
    required String pageKey,
    required ProjectPage? page,
    required StudioChapterPageRun record,
    required StudioRunOptions options,
    required StudioPagePipeline pipeline,
    required EditHistory history,
    required CancellationToken token,
    required StudioChapterRun run,
  }) async {
    final base = resolveBase(project, pageKey);
    if (base == null) {
      record.error = 'no page image on disk';
      return;
    }
    record.baseSource = base.$2;
    final size = pageSizeInPixels(project, pageKey);
    record.imageInfoMissing = size.$2;

    final Uint8List bytes;
    try {
      bytes = await base.$1.readAsBytes();
    } catch (e) {
      record.error = 'read failed: $e';
      return;
    }

    final pageRun = await pipeline.runPage(
      pageKey,
      bytes,
      options: options,
      pageWidth: size.$1.round(),
      cancel: token,
    );
    if (pageRun.error != null) {
      record.error = '${pageRun.error}';
      return;
    }
    record.detected = pageRun.blocks.length;
    record.skipped = pageRun.skipped;
    run.detectedPages++;
    run.detectedBlocks += pageRun.blocks.length;
    run.detectedSkipped += pageRun.skipped;

    if (page == null) {
      record.error = 'page key not in project';
      return;
    }
    // 去重：**只读**既有块（`overlapsExistingBlock` 明写绝不改动它们）。
    final fresh = [
      for (final block in pageRun.blocks)
        if (!overlapsExistingBlock(page, block.rect)) block,
    ];
    record.deduped = pageRun.blocks.length - fresh.length;
    record.landed = fresh.length;
    run.deduped += record.deduped;

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
  }

  /// 与 `studio_page._resolvePageFile` 同一条回退链，附带来源标签。
  static (File, String)? resolveBase(
    TranslationProject project,
    String pageKey,
  ) {
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
  static (double, bool) pageSizeInPixels(
    TranslationProject project,
    String pageKey,
  ) {
    final info = project.imageInfo[pageKey];
    final width = info is Map ? (info['width'] as num?)?.toDouble() : null;
    final height = info is Map ? (info['height'] as num?)?.toDouble() : null;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return (1200.0, true);
    }
    return (width, false);
  }
}

/// 为什么这一页没有 `result/` 文件 —— 成因分开报，**根因优先**。
///
/// 🔴 顺序即语义：**检测失败的页必须先报检测失败**。第一版按
/// "页键缺失 → 无译文 → 无底图 → 渲染器返回 null" 的顺序取第一个成立的，
/// 于是 94 页全部报成 `no translated region` —— 字面没错（确实没有 region），
/// 但它把真正的根因（`No Impeller context is available`，解码在第一行就挂了）
/// 藏在了第二层。这正是本项目最忌讳的那类"静默分歧"：一个数字看起来正常，
/// 成因却是另一回事。
String absentReason(
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
