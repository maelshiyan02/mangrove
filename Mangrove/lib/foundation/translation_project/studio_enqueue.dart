// S9.5-b · 「打开开关 = 该章入队工作室管线」的落地端（app 侧）。
//
// ## 它把一个开关变成一次运行，中间有五个必须做对的判断
//
// | 步 | 判断 | 出错的样子 |
// |---|---|---|
// | 1 | 这本漫画**在本地**吗 | 在线漫画没有原图可复制 ⇒ 静默不跑 |
// | 2 | 建/复用工程、写绑定 | 阅读器永远读不到产物（等价于开关关着） |
// | 3 | 哪一页属于**这一章** | 把别话的页跑进来（`第2话/1.webp` 撞 `第1话/1.webp`） |
// | 4 | 哪一页**还没有** `result/` | 重跑已有产物的页（白烧一次 LLM） |
// | 5 | 排进任务列表并**可取消** | 用户点了取消，管线照样跑完 94 页 |
//
// 前四步的判据全部在纯逻辑层（`studio_reader.dart`），所以它们能在 `init()`
// 之前被 headless 注入故障打红；本文件只负责"读盘、写绑定、起任务"。
//
// ## 与 `headless_pipeline_check` 的关系
//
// 整章跑的**循环**只有一份实现（`StudioChapterRunner`）—— 本文件传的是
// "这一章还缺产物的页"，工装传的是"全部页"。`P6 §S9.5` 交付 1 的落点，就是
// 让这两处走同一个函数：否则 `--headless pipeline-check` 验的就不是应用跑的
// 那条路（`P9.6 §四`）。
library;

import 'dart:async';
import 'dart:io';

import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/foundation/comic_type.dart';
import 'package:mangrove/foundation/image_translation/balloon_clustering.dart';
import 'package:mangrove/foundation/image_translation/pre_translation_tasks.dart';
import 'package:mangrove/foundation/image_translation/translation_config.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/translation_project/glossary_store_app.dart';
import 'package:mangrove/foundation/translation_project/project.dart';
import 'package:mangrove/foundation/translation_project/project_io.dart';
import 'package:mangrove/foundation/translation_project/run_plan.dart';
import 'package:mangrove/foundation/translation_project/studio_chapter_runner.dart';
import 'package:mangrove/foundation/translation_project/studio_pipeline.dart';
import 'package:mangrove/foundation/translation_project/studio_reader.dart';
import 'package:mangrove/foundation/translation_project/studio_reader_app.dart';

/// 一次入队尝试的结局。
///
/// 🔴 返回**码**而不是句子：句子要落进调用方的字面量里，`i18n` 的扫描器才扫
/// 得到（漏登记不报错、只显示英文）。纯逻辑层不该持有 UI 文案 —— 与
/// `RunBlockReason` 同一条规矩。
enum StudioEnqueueStatus {
  /// 已排进任务列表，正在跑（或即将开始）。
  queued,

  /// 这本漫画已经有一个在跑的任务，没有重复入队。
  alreadyRunning,

  /// 本地没有这本漫画的副本（没下载 / 目录不在）。工程要把原图**复制**进
  /// `source/`，在线的漫画没有原图可复制。
  noLocalCopy,

  /// 这一章一个可读页都没有。
  noPage,

  /// 每一页都已经有 `result/` —— 没活可干。**这不是失败**。
  upToDate,

  /// 工程建不出来 / 绑定写不上。
  failed,
}

/// 「素材漫画的某一章 → 工作室工程」的**入队端**。
abstract final class StudioChapterQueue {
  StudioChapterQueue._();

  /// 把 [cid] 的 [eid] 这一章排进工作室管线。
  ///
  /// 幂等：同一个漫画已在跑时不重复入队；已经全部有产物的章直接返回
  /// [StudioEnqueueStatus.upToDate]（**不**建任务，否则任务列表里会出现一条
  /// 0 页的幽灵任务）。
  static Future<StudioEnqueueStatus> enqueue({
    required String cid,
    required String? sourceKey,
    required String eid,
    required String title,
    required ComicType comicType,
    String cover = '',
  }) async {
    // 已经有一个在跑的任务：直接复用。判据与 `start()` 里那条一致
    // （`comicKey` 用 `sourceKey ?? ''` 拼，`PreTranslationTask.sourceKey`
    // 是非空的 `String`）。
    final key = sourceKey ?? '';
    if (PreTranslationTaskManager.instance.runningTaskFor(cid, key) != null) {
      return StudioEnqueueStatus.alreadyRunning;
    }

    final target = StudioReaderLink.locate(
      cid: cid,
      sourceKey: key,
      eid: eid,
    );
    if (target == null) return StudioEnqueueStatus.noLocalCopy;

    final (binding, reason) = await StudioReaderLink.ensureBinding(
      cid: cid,
      sourceKey: sourceKey,
      eid: eid,
      target: target,
    );
    if (binding == null) {
      Log.error(
        'Studio Reader',
        'enqueue $cid/$eid: no project (${reason ?? 'unknown'})',
      );
      return StudioEnqueueStatus.failed;
    }

    final TranslationProject project;
    try {
      project = await TranslationProjectIo.load(File(binding.jsonPath));
    } catch (e, s) {
      Log.error('Studio Reader', 'enqueue: load ${binding.jsonPath} failed: $e', s);
      return StudioEnqueueStatus.failed;
    }

    // 🔴 章节目录前缀取自**工程页键的同一来源**（`target.chapterName` 是
    // `chapterDirectoryName(chapters, eid)` 的输出，工程就是按它建的）。
    final chapterKeys = studioChapterPageKeys(
      projectPageKeys: project.pageOrder,
      chapterName: target.chapterName,
    );
    if (chapterKeys.isEmpty) return StudioEnqueueStatus.noPage;

    final pending = studioPagesNeedingWork(
      chapterPages: chapterKeys,
      pagesWithResult: {
        for (final pageKey in chapterKeys)
          if (project.resultPath(pageKey) != null) pageKey,
      },
    );
    if (pending.isEmpty) {
      // 产物已经齐了。**照样**把产物变更计数推一格：用户可能是在工作室里
      // 重生成完之后才回来打开阅读器，此时缓存里还是旧的 provider。
      StudioReaderStore.markArtifactsChanged();
      return StudioEnqueueStatus.upToDate;
    }

    final task = PreTranslationTaskManager.instance.startStudio(
      cid: cid,
      sourceKey: key,
      comicType: comicType,
      title: title,
      cover: cover,
      jsonPath: binding.jsonPath,
      chapterEid: eid,
      chapterTitle: target.chapterName.isEmpty ? title : target.chapterName,
      chapterPrefix: target.chapterName,
    );
    if (task == null) return StudioEnqueueStatus.failed;
    Log.info(
      'Studio Reader',
      'enqueued cid=$cid eid=$eid pages=${pending.length} '
          'json=${binding.jsonPath}',
    );
    return StudioEnqueueStatus.queued;
  }

  /// 关开关：把这一章在跑的任务取消掉（**不**删工程，也不删产物）。
  ///
  /// ## 为什么"关开关"要取消在跑的任务
  ///
  /// 开关的语义就是"这一章入队工作室管线"（`P6 §S9.5` 交付 1）。关掉它之后
  /// 后台还在烧 token 跑一整章，是用户完全看不见的浪费 —— 而 V2 的验收是
  /// "回到原图且不残留"，一个还在跑的任务会让下一轮开关再打开时对着一个
  /// **正在被写**的工程。
  ///
  /// 返回是否真的取消了一个任务（调用方据此决定要不要提示）。
  static bool cancelIfRunning({
    required String cid,
    required String? sourceKey,
  }) {
    final running = PreTranslationTaskManager.instance.runningTaskFor(
      cid,
      sourceKey ?? '',
    );
    if (running == null || !running.studio) return false;
    PreTranslationTaskManager.instance.cancel(running.id);
    return true;
  }

  /// 关开关：**解绑**这一章。
  ///
  /// 只删绑定，不删工程、不删产物：产物是用户在工作室里的劳动成果，开关
  /// 表达的是"现在不读它"，不是"把它删掉"。重新打开开关时
  /// [StudioReaderLink.ensureBinding] 会把同一条绑定写回来，`result/` 齐了的
  /// 页也不会重跑（[StudioEnqueueStatus.upToDate]）。
  static void unbind({
    required String cid,
    required String? sourceKey,
    required String eid,
  }) {
    StudioReaderStore.remove(cid: cid, sourceKey: sourceKey, eid: eid);
  }
}

/// 注册 studio 执行体（`P6 §S9.5` 交付 4）。
///
/// 🔴 在 `init.dart` 里、`resumePendingTasks()` **之前**调用。位置不能换：
/// 上一次会话遗留的 studio 任务要在启动时就有人能跑它们，否则
/// `_runStudio` 会以 `studioRunner is null` 把任务标成 failed。
void registerStudioTaskRunner() {
  PreTranslationTaskManager.registerStudioRunner(_runStudioTask);
}

/// 工作室整章跑的**执行体**：读工程 → 算还缺产物的页 → 跑。
///
/// 状态（工程路径 + 章节目录前缀）从 [PreTranslationTask] 上取，所以跨重启
/// 续跑不需要任何额外登记 —— 重启后 `resumePendingTasks` 拿到的还是同一条
/// 描述，重新算一遍"还缺哪些页"即可（这正是幂等的好处：算出来的集合就是
/// 断点）。
Future<StudioTaskOutcome> _runStudioTask(
  PreTranslationTask task,
  CancellationToken token,
  void Function(int done, int total) onProgress,
) async {
  final jsonPath = task.studioJsonPath;
  if (jsonPath == null || jsonPath.isEmpty) {
    Log.error('Studio Reader', 'studio task ${task.id}: no json path');
    return (done: 0, failed: 1, canceled: false);
  }
  final file = File(jsonPath);
  if (!file.existsSync()) {
    Log.error('Studio Reader', 'studio task ${task.id}: $jsonPath missing');
    return (done: 0, failed: 1, canceled: false);
  }

  final project = await TranslationProjectIo.load(file);
  final chapterPrefix = task.studioChapter ?? '';
  final chapterKeys = studioChapterPageKeys(
    projectPageKeys: project.pageOrder,
    chapterName: chapterPrefix,
  );
  final pending = studioPagesNeedingWork(
    chapterPages: chapterKeys,
    pagesWithResult: {
      for (final pageKey in chapterKeys)
        if (project.resultPath(pageKey) != null) pageKey,
    },
  );
  if (pending.isEmpty) {
    onProgress(0, 0);
    return (done: 0, failed: 0, canceled: false);
  }

  final options = _runOptionsFor(task);
  var completed = 0;
  onProgress(0, pending.length);
  final run = await StudioChapterRunner.run(
    project: project,
    pageKeys: pending,
    options: options,
    label: 'studio',
    cancel: token,
    onPage: (page, index, total) {
      if (!page.failed) completed++;
      onProgress(completed, total);
    },
  );

  // 🔴 产物变了 ⇒ 阅读器的图片缓存必须失效（V3：工作室改一个字，阅读器该页
  // 立刻变）。放在这里而不是"保存成功时"：这里才是产物真的落盘的那一刻。
  StudioReaderStore.markArtifactsChanged();
  Log.info(
    'Studio Reader',
    'studio run done: pages=${pending.length} landed=${run.totalLanded} '
        'result=${run.resultOnDisk} failed=${run.failedPages} '
        'canceled=${run.canceled}',
  );
  return (
    done: completed,
    failed: run.failedPages,
    canceled: run.canceled,
  );
}

/// 这一次跑用什么语向 / 方向。
///
/// 语向与方向取自 `appdata.settings['studioRunDefaults']` —— 与工作室弹窗
/// **同一个命名空间**（P2 选项②）。这样"在工作室把语向改成日→繁"之后再从
/// 阅读页入队，跑出来的产物与工作室里跑的是同一种；各读各的默认值会让同一
/// 章在两处产出不同的东西，而那是事后最难解释的一类差异。
///
/// 🔴 **三段不参与**：`studioRunDefaults.stages` 说的是"这一轮做哪几段"，而
/// 阅读页的"入队"只有一个含义 —— 把这一章翻出来（检测 + 识别 + 翻译）。
/// 把用户上次在弹窗里勾的"只检测"带进来，会让阅读页入队之后**永远没有译文**
/// 而任务显示"完成"。方向/语向影响产物的**内容**，阶段影响**做多少事**，
/// 两者的默认值语义不同。
StudioRunOptions _runOptionsFor(PreTranslationTask task) {
  final config = TranslationConfig.of(task.cid, task.sourceKey);
  var sourceLang = config.sourceLang;
  var targetLang = config.targetLang;
  var direction = ReadingDirection.rightToLeft;
  final raw = appdata.settings['studioRunDefaults'];
  if (raw is Map) {
    final source = raw['sourceLang'];
    if (source is String && source.isNotEmpty) sourceLang = source;
    final target = raw['targetLang'];
    if (target is String && target.isNotEmpty) targetLang = target;
    direction =
        readingDirectionFromName(raw['readingDirection']) ?? direction;
  }
  return StudioRunOptions(
    sourceLang: sourceLang,
    targetLang: targetLang,
    readingDirection: direction,
    translate: true,
    recognize: true,
    // 术语表：与工作室同一条注入端（`studio_page._runPipeline`）。
    glossary: appGlossary.of(task.cid),
  );
}
