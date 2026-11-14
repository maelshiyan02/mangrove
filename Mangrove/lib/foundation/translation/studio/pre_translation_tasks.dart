import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/foundation/background_keepalive.dart';
import 'package:mangrove/foundation/comic_type.dart';
import 'package:mangrove/foundation/translation/engine/translation_config.dart';
import 'package:mangrove/foundation/translation/engine/translation_types.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/translation/studio/studio_pipeline.dart';

enum PreTranslationTaskStatus { running, paused, completed, canceled, failed }

/// One chapter queued for background pre-translation.
class PreTranslationChapter {
  PreTranslationChapter({
    required this.eid,
    required this.title,
    this.total = 0,
    this.done = 0,
    this.failed = 0,
    this.canceled = false,
    Set<int>? failedPages,
  }) : failedPages = failedPages ?? <int>{};

  /// Source chapter id (the eid passed to loadComicPages / image keys). For a
  /// comic without chapters this is '0'.
  final String eid;
  final String title;

  /// Page count, resolved lazily when the chapter starts.
  int total;
  int done;
  int failed;

  /// Set when the user cancels just this chapter of a still-running job. The
  /// worker loop skips a canceled chapter (both the forward pass and the retry
  /// pass), so the rest of the job keeps going. Not persisted as "running": a
  /// canceled chapter is simply left where it stopped and never resumed.
  bool canceled;

  /// Indices (into the resolved page-key list) of the pages that failed this
  /// run, so a retry can re-run exactly those and leave the succeeded pages
  /// alone. Kept in lockstep with [failed]: a page enters here when it fails
  /// and leaves when a retry succeeds, so `failedPages.length == failed` for a
  /// chapter recorded by the current version. Persisted so a retry survives a
  /// restart. Older persisted tasks lack it (empty set) — a retry then falls
  /// back to re-scanning the whole chapter, which is cheap because rendered
  /// pages skip via hasRenderedPage.
  final Set<int> failedPages;

  Map<String, dynamic> toJson() => {
    'eid': eid,
    'title': title,
    'total': total,
    'done': done,
    'failed': failed,
    'canceled': canceled,
    'failedPages': failedPages.toList(),
  };

  factory PreTranslationChapter.fromJson(Map<String, dynamic> json) {
    return PreTranslationChapter(
      eid: json['eid']?.toString() ?? '0',
      title: json['title']?.toString() ?? '',
      total: json['total'] ?? 0,
      done: json['done'] ?? 0,
      failed: json['failed'] ?? 0,
      canceled: json['canceled'] == true,
      failedPages: (json['failedPages'] as List? ?? [])
          .map((e) => e is int ? e : int.tryParse('$e'))
          .whereType<int>()
          .toSet(),
    );
  }
}

/// 一个工作室整章跑的进度与结局。
///
/// 刻意只有三个数字：任务卡要的只有这三样。旧引擎那套"分组缓冲 + 断点游标"
/// 是**旧缓存**的续跑语义，工作室不需要（它按 `result/` 判哪些页还没跑
/// —— `studioPagesNeedingWork`），硬搬过来只会让两条路的语义互相污染。
typedef StudioTaskOutcome = ({int done, int failed, bool canceled});

/// 工作室整章跑的**执行体**，由 `studio_enqueue.dart` 在启动时注入。
///
/// 🔴 为什么是一个注入的闭包而不是直接调用：本文件属于**旧引擎的任务框架**，
/// 让它去 import `TranslationProject` / `StudioChapterRunner` 就等于把工作室的
/// 工程模型拖进旧引擎（`P6 §S9.5` 交付 4 明写"只接**展示**，不把旧缓存写入口
/// 拉进工作室"—— 反向同理：旧框架只该知道"有个东西在跑、跑完了"）。
/// 这样本文件对工作室的全部认知就是 [PreTranslationTask.studio] 与
/// [PreTranslationTask.studioJsonPath] 两个字段。
typedef StudioTaskRunner =
    Future<StudioTaskOutcome> Function(
      PreTranslationTask task,
      CancellationToken token,
      void Function(int done, int total) onProgress,
    );

/// A background job that translates selected chapters of one comic through the
/// **studio pipeline**, writing finished pages into the project's `result/`.
///
/// 阅读器不再有读时翻译缓存：任务跑完，产物就在工程里，阅读器按绑定读它
/// （`StudioReaderStore`）。旧引擎那条"预翻译 → 阅读器即时命中"的路已删除。
class PreTranslationTask {
  PreTranslationTask({
    required this.id,
    required this.cid,
    required this.sourceKey,
    required this.comicType,
    required this.title,
    required this.chapters,
    required this.createdAt,
    this.cover = '',
    this.status = PreTranslationTaskStatus.running,
    this.finishedAt,
    this.studio = false,
    this.studioJsonPath,
    this.studioChapter,
    this.studioGroup = '',
  });

  final String id;
  final String cid;
  final String sourceKey;
  final ComicType comicType;
  final String title;
  final String cover;
  final List<PreTranslationChapter> chapters;
  final DateTime createdAt;
  PreTranslationTaskStatus status;
  DateTime? finishedAt;

  /// 这条任务走的是**工作室管线**（旧引擎 runnner 已删除，此字段恒为 true，
  /// 保留它只为读回历史持久化记录）。
  ///
  /// 🔴 判据仍然只有这一个字段：`_run` 凭它决定跑法，读到 `false` 的历史任务
  /// 会**响亮地失败**并写日志（不是静默 no-op），因为已经没有执行体可跑。
  final bool studio;

  /// studio 模式的工程 `imgtrans_*.json` 绝对路径。
  ///
  /// 持久化的**唯一理由**是跨重启续跑：重启后 [PreTranslationTaskManager]
  /// 靠它重建整章跑的输入（工程 → 这一章的页 → 还缺 `result/` 的页）。
  final String? studioJsonPath;

  /// 章节目录前缀（`'1 [Asura Scans]'`；无章节的漫画是空串）。
  final String? studioChapter;

  /// 这一章所属的**翻译组**（术语表的 group 段）。
  ///
  /// 非版本化源恒为空串，行为与"没有这个字段"完全一致。
  ///
  /// 🔴 为什么存下来而不是跑的时候现算：算它要原漫画的 `ComicChapters`
  /// （`versionEntryOf(eid)`），而任务里存的是**章节目录名**、不是 `eid`；靠目录
  /// 名字反查 eid 又是一次猜测。入队那一刻手里正好有全部信息，存一个字符串
  /// 比在跑的时候再猜一次便宜得多 —— 而且跨重启后猜错是没有声音的。
  final String studioGroup;

  String get comicKey => '$cid@$sourceKey';

  /// 这本漫画自己的语言对与文字消除方式。每次现读配置，保证任务展示的语言
  /// 与实际跑管线时用的是同一份（配置按漫画存，不随任务快照冻结）。
  TranslationConfig get config => TranslationConfig.of(cid, sourceKey);

  bool get isRunning => status == PreTranslationTaskStatus.running;

  int get total => chapters.fold(0, (sum, c) => sum + c.total);
  int get done => chapters.fold(0, (sum, c) => sum + c.done);
  int get failed => chapters.fold(0, (sum, c) => sum + c.failed);

  /// Whether any chapter has failed pages that could be retried. A canceled
  /// chapter is excluded: both the forward loop and the retry sweep skip it, so
  /// its failures are unreachable and offering a retry for them would do
  /// nothing. Re-running such a chapter goes through the picker's re-translate.
  bool get hasFailures => chapters.any((c) => !c.canceled && c.failed > 0);

  /// Overall progress across the whole job, weighted by chapters rather than
  /// pages. Each chapter contributes an equal 1/N slice; a chapter whose page
  /// count is not resolved yet (total == 0) counts as 0% until it starts, and a
  /// fully processed chapter counts as 100%. This keeps the percentage
  /// representative of the entire comic (all selected chapters), and monotonic,
  /// instead of tracking only the page counts of chapters that have already
  /// begun — which made the earlier page-based ratio jump around as new
  /// chapters resolved their totals.
  double get progress {
    if (chapters.isEmpty) return 0;
    var sum = 0.0;
    for (var c in chapters) {
      if (c.total <= 0) continue;
      sum += ((c.done + c.failed) / c.total).clamp(0.0, 1.0);
    }
    return sum / chapters.length;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'cid': cid,
    'sourceKey': sourceKey,
    'comicType': comicType.value,
    'title': title,
    'cover': cover,
    'createdAt': createdAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'status': status.name,
    'chapters': chapters.map((c) => c.toJson()).toList(),
    if (studio) 'studio': true,
    if (studioJsonPath != null) 'studioJsonPath': studioJsonPath,
    if (studioChapter != null) 'studioChapter': studioChapter,
    if (studioGroup.isNotEmpty) 'studioGroup': studioGroup,
  };

  factory PreTranslationTask.fromJson(Map<String, dynamic> json) {
    return PreTranslationTask(
      id: json['id']?.toString() ?? '',
      cid: json['cid']?.toString() ?? '',
      sourceKey: json['sourceKey']?.toString() ?? '',
      comicType: ComicType(json['comicType'] ?? 0),
      title: json['title']?.toString() ?? '',
      cover: json['cover']?.toString() ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      finishedAt: DateTime.tryParse(json['finishedAt'] ?? ''),
      status: PreTranslationTaskStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => PreTranslationTaskStatus.completed,
      ),
      chapters: (json['chapters'] as List? ?? [])
          .whereType<Map>()
          .map(
            (e) => PreTranslationChapter.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(),
      // 旧记录没有这两个键 ⇒ 一律按 legacy 解析（`fromJson` 的容错规矩与
      // `failedPages` 一致：老数据不因为新字段而整条作废）。
      studio: json['studio'] == true,
      studioJsonPath: json['studioJsonPath']?.toString(),
      studioChapter: json['studioChapter']?.toString(),
      // 老记录没有这个键 ⇒ 空串（共用层），正是引入 group 之前的行为。
      studioGroup: json['studioGroup']?.toString() ?? '',
    );
  }
}

/// Live view of one in-flight page group.
///
/// Never persisted and never folded into [PreTranslationChapter.done] /
/// `failed`: the resume cursor is `done + failed` and requires those to stay a
/// contiguous *committed* prefix, so a per-page stage change must not touch
/// them. This is the parallel, display-only channel instead.
class PreTranslationGroupActivity {
  PreTranslationGroupActivity({required this.index, required this.pageCount});

  /// Group order within the chapter, which is also its commit order.
  final int index;
  final int pageCount;
  TranslationStage stage = TranslationStage.fetching;

  /// Pages of this group already accounted for, in page units and weighted by
  /// the phase each page has reached — so a group that is minutes from
  /// committing still reads as partial progress rather than as nothing.
  double completedPages = 0;
}

/// What a running job is doing right now, beyond its committed counters.
class PreTranslationActivity {
  /// 1-based index of the chapter being processed; 0 before the first starts.
  int chapterIndex = 0;
  String chapterTitle = '';

  /// eid of the chapter being processed, so a per-chapter display can tell
  /// whether [bufferedPages] belongs to it.
  String chapterEid = '';

  final Map<int, PreTranslationGroupActivity> groups = {};

  /// Pages of groups that finished and handed their counts to the committer,
  /// but which are still buffered behind an earlier, slower group.
  ///
  /// These pages are genuinely rendered and cached; only the resume cursor
  /// cannot move past them yet, because `done + failed` has to stay a
  /// contiguous prefix. Keeping them here lets the display credit real work
  /// without touching the chapter counters. Reset per chapter, since each
  /// chapter gets its own committer.
  int bufferedDone = 0;
  int bufferedFailed = 0;

  int get bufferedPages => bufferedDone + bufferedFailed;

  /// Pages settled for display: committed plus buffered. Never write this back
  /// into [PreTranslationChapter.done] — that would break the resume cursor.
  int liveDone(PreTranslationTask task) => task.done + bufferedDone;

  int liveFailed(PreTranslationTask task) => task.failed + bufferedFailed;

  /// Pages the job is finished with, successes and failures alike — the same
  /// set [PreTranslationTask.progress] counts. Page counters must report this
  /// rather than [liveDone], or a failed page freezes the number while the bar
  /// keeps advancing.
  int liveProcessed(PreTranslationTask task) =>
      liveDone(task) + liveFailed(task);

  /// Stage of the lowest-numbered live group. Counts commit in group order, so
  /// that group is the one holding the cursor — it answers "why hasn't the
  /// number moved" better than whichever group changed stage most recently.
  TranslationStage? get headStage {
    PreTranslationGroupActivity? head;
    for (var g in groups.values) {
      if (head == null || g.index < head.index) head = g;
    }
    return head?.stage;
  }

  /// How many live groups sit in each stage, for the expanded breakdown.
  Map<TranslationStage, int> get stageCounts {
    var counts = <TranslationStage, int>{};
    for (var g in groups.values) {
      counts[g.stage] = (counts[g.stage] ?? 0) + 1;
    }
    return counts;
  }

  /// Pages finished inside groups that have not committed yet, weighted by how
  /// far each in-flight page has got, plus whole groups already waiting on the
  /// committer.
  double get uncommittedPages =>
      bufferedPages +
      groups.values.fold(0.0, (sum, g) => sum + g.completedPages);

  /// [PreTranslationTask.progress] plus those uncommitted pages. A group of
  /// 4-8 pages commits its counts at once, so the committed value can sit
  /// still for minutes — long enough to read as a stalled job. Falls back to
  /// the committed value whenever the running chapter is unknown or its page
  /// count is not resolved yet.
  double liveProgress(PreTranslationTask task) {
    var base = task.progress;
    var index = chapterIndex - 1;
    if (index < 0 || index >= task.chapters.length) return base;
    var chapter = task.chapters[index];
    if (chapter.total <= 0) return base;
    var extra = (uncommittedPages / chapter.total).clamp(0.0, 1.0);
    return (base + extra / task.chapters.length).clamp(0.0, 1.0);
  }
}

/// Manages background pre-translation jobs. Mirrors the structure of the
/// other task managers (currentTasks / historyTasks / persistence) so the
/// tasks page can render it the same way.
class PreTranslationTaskManager with ChangeNotifier {
  PreTranslationTaskManager._() {
    _load();
  }

  static final PreTranslationTaskManager instance =
      PreTranslationTaskManager._();

  final currentTasks = <PreTranslationTask>[];
  final historyTasks = <PreTranslationTask>[];
  final _canceledIds = <String>{};
  final _runningIds = <String>{};
  final _activities = <String, PreTranslationActivity>{};

  /// studio 任务的取消令牌，键是 `task.id`。
  ///
  /// 🔴 这就是交付 4 说的"把 `CancellationToken` 接进任务列表"：用户在任务卡上
  /// 点取消 → [cancel] 顺手 `token.cancel()` → 工作室管线在**下一个页边界**
  /// 抛 `PipelineCanceled` 停下（`StudioChapterRunner` 里那个 `throwIfCanceled`）。
  /// 没有这一行，"可取消"就只是把卡片从列表里挪走，而管线还在后台跑完 94 页。
  final _studioTokens = <String, CancellationToken>{};

  /// studio 整章跑的执行体；由 `studio_enqueue.dart` 在启动时注入。
  ///
  /// 是 `static` 且**可为 null**：headless 的 `edit-check` 在 `init()` 之前就
  /// 跑完了，那时没有任何人注册它 —— 于是"studio 任务但没人能跑"必须是一个
  /// **响亮的失败**（见 [_runStudio]），而不是静默地什么都不做。
  static StudioTaskRunner? studioRunner;

  /// 注册 studio 执行体。重复注册覆盖（启动路径只有一条，但测试会重入）。
  static void registerStudioRunner(StudioTaskRunner runner) {
    studioRunner = runner;
  }

  /// Live stage detail for a running job; null once it stops. Not persisted —
  /// a restart resumes from the committed counters, not from mid-group state.
  PreTranslationActivity? activityOf(String taskId) => _activities[taskId];

  Timer? _activityNotifyTimer;
  DateTime _lastActivityNotify = DateTime.fromMillisecondsSinceEpoch(0);

  /// Stage changes land per page across up to four concurrent groups, and each
  /// one rebuilds the whole task list. Coalesce them to a few frames a second;
  /// the trailing timer makes sure the final change is not swallowed.
  void _notifyActivity() {
    var now = DateTime.now();
    const window = Duration(milliseconds: 400);
    if (now.difference(_lastActivityNotify) >= window) {
      _lastActivityNotify = now;
      _activityNotifyTimer?.cancel();
      _activityNotifyTimer = null;
      notifyListeners();
      return;
    }
    _activityNotifyTimer ??= Timer(window, () {
      _activityNotifyTimer = null;
      _lastActivityNotify = DateTime.now();
      notifyListeners();
    });
  }

  void Function(PreTranslationTask task)? onTaskFinished;

  /// S9.5-b · 把一个**工作室工程**的整章跑排进任务列表。
  ///
  /// ## 与已删除的旧 `start` 的三处不同
  ///
  /// 1. **不查就绪判据**。旧路锁的是旧引擎的缓存键与模型开关（那套已删除）；
  ///    工作室的输入是**磁盘上的工程**，能不能跑由 [StudioTaskRunner] 决定
  ///    （它自己会在缺模型/缺 LLM 时失败并回报）。在这里拦一道，只会让
  ///    "模型装了但判据因为别的原因为 false"变成静默不跑。
  /// 2. **一章一任务**（`P6 §4.10.1` #14 拍板 ①）。一个工程就是一"章"
  ///    （`ProjectBootstrap.plan` 按 `comicDirectory + chapterName` 建），所以
  ///    `chapters` 恒为一条。
  /// 3. **`total` 可以后知**：工程里还缺 `result/` 的页数要读盘才知道，所以
  ///    这里传 0，由执行体在开工前用 `onProgress` 报上来。
  PreTranslationTask? startStudio({
    required String cid,
    required String sourceKey,
    required ComicType comicType,
    required String title,
    required String jsonPath,
    required String chapterEid,
    required String chapterTitle,
    required String chapterPrefix,
    String group = '',
    String cover = '',
  }) {
    if (jsonPath.isEmpty) return null;
    var existing = currentTasks
        .where((t) => t.comicKey == '$cid@$sourceKey' && t.isRunning)
        .firstOrNull;
    if (existing != null) {
      return existing;
    }
    var task = PreTranslationTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      cid: cid,
      sourceKey: sourceKey,
      comicType: comicType,
      title: title,
      cover: cover,
      chapters: [PreTranslationChapter(eid: chapterEid, title: chapterTitle)],
      createdAt: DateTime.now(),
      studio: true,
      studioJsonPath: jsonPath,
      studioChapter: chapterPrefix,
      studioGroup: group,
    );
    currentTasks.insert(0, task);
    _saveActive();
    notifyListeners();
    unawaited(_run(task));
    return task;
  }

  /// Whether a running job exists for the comic (detail page badge).
  PreTranslationTask? runningTaskFor(String cid, String sourceKey) {
    return currentTasks
        .where((t) => t.comicKey == '$cid@$sourceKey' && t.isRunning)
        .firstOrNull;
  }

  /// Best-known progress of a chapter for a comic, looking first at a running
  /// job and then at the most recent finished job. Lets the chapter picker show
  /// a "translated" / progress marker even after the app restarts or the task
  /// moved to history, so already-done chapters are obvious and not re-queued
  /// blindly.
  PreTranslationChapter? chapterProgressFor(
    String cid,
    String sourceKey,
    String eid,
  ) {
    var comicKey = '$cid@$sourceKey';
    // A running/paused job owns the chapter: return it even before its page
    // count is known (total == 0) so the picker can show a "waiting" state for
    // queued-but-not-started chapters, not just active ones.
    for (var task in currentTasks) {
      if (task.comicKey != comicKey) continue;
      var chapter = task.chapters.where((c) => c.eid == eid).firstOrNull;
      // A per-chapter cancel leaves the chapter in the running job but no longer
      // being worked; fall through so the history/stored-text lookup can still
      // surface a "translated" marker if some pages were done before the cancel.
      if (chapter != null && !chapter.canceled) return chapter;
    }
    // Otherwise only report a finished chapter (all pages accounted for) so a
    // canceled/failed run does not masquerade as in-progress after restart.
    for (var task in historyTasks) {
      if (task.comicKey != comicKey) continue;
      var chapter = task.chapters.where((c) => c.eid == eid).firstOrNull;
      if (chapter != null &&
          chapter.total > 0 &&
          chapter.done + chapter.failed >= chapter.total) {
        return chapter;
      }
    }
    return null;
  }

  /// Live page counts for [chapter] of a comic: the committed counters plus a
  /// running job's finished-but-buffered groups.
  ({int done, int processed}) livePagesOf(
    String cid,
    String sourceKey,
    PreTranslationChapter chapter,
  ) {
    var task = runningTaskFor(cid, sourceKey);
    // Identity check, not eid: a per-chapter cancel makes chapterProgressFor
    // fall through to a history record for the same eid, and that record must
    // not be credited with the running job's buffered pages.
    if (task == null || !task.chapters.contains(chapter)) {
      return livePagesFor(chapter, null);
    }
    return livePagesFor(chapter, _activities[task.id]);
  }

  /// Credits [activity]'s buffered groups to [chapter] for display, when they
  /// belong to this chapter.
  ///
  /// Buffered pages cannot advance `done + failed` (that must stay a contiguous
  /// prefix for the resume cursor), but they are rendered and cached, so
  /// leaving them out makes the number sit still while work is plainly
  /// happening — which is what a slow head group looks like from the outside.
  /// Display only: never write these back into the chapter.
  @visibleForTesting
  static ({int done, int processed}) livePagesFor(
    PreTranslationChapter chapter,
    PreTranslationActivity? activity,
  ) {
    var committed = (
      done: chapter.done,
      processed: chapter.done + chapter.failed,
    );
    if (activity == null || activity.chapterEid != chapter.eid) {
      return committed;
    }
    return (
      done: committed.done + activity.bufferedDone,
      processed: committed.processed + activity.bufferedPages,
    );
  }

  /// Whether a chapter belongs to a currently running/paused job (so the picker
  /// can distinguish "queued/among this run" from a finished-in-history one).
  bool isChapterActive(String cid, String sourceKey, String eid) {
    var comicKey = '$cid@$sourceKey';
    for (var task in currentTasks) {
      if (task.comicKey != comicKey) continue;
      if (task.chapters.any((c) => c.eid == eid && !c.canceled)) return true;
    }
    return false;
  }

  void cancel(String id) {
    _canceledIds.add(id);
    // 🔴 studio 模式：把令牌也点掉。它是在**页边界**检查的，所以这次取消会
    // 停在当前页之后、不会跑完整章（`StudioChapterRunner` 的 `throwIfCanceled`）。
    _studioTokens[id]?.cancel();
    var task = currentTasks.where((t) => t.id == id).firstOrNull;
    if (task == null) {
      notifyListeners();
      return;
    }
    task.status = PreTranslationTaskStatus.canceled;
    _moveToHistory(task);
    if (!_runningIds.contains(id)) {
      _canceledIds.remove(id);
    }
    notifyListeners();
  }

  /// Cancels just one chapter of a still-running job, leaving the other
  /// chapters to keep translating. The chapter is flagged [PreTranslationChapter.canceled]
  /// so both the forward pass and the retry pass skip it; an in-flight chapter
  /// stops at the next group boundary. If every remaining chapter is now
  /// canceled (or already finished), the whole job is canceled so it doesn't
  /// linger as "running" with nothing left to do.
  void cancelChapter(String taskId, String eid) {
    var task = currentTasks.where((t) => t.id == taskId).firstOrNull;
    if (task == null) return;
    var chapter = task.chapters.where((c) => c.eid == eid).firstOrNull;
    if (chapter == null || chapter.canceled) return;
    chapter.canceled = true;
    // If nothing is left to do, cancel the whole job. "Left to do" = a chapter
    // that isn't canceled and isn't already fully processed.
    var hasPending = task.chapters.any((c) {
      if (c.canceled) return false;
      return c.total <= 0 || (c.done + c.failed) < c.total;
    });
    if (!hasPending) {
      cancel(taskId);
      return;
    }
    _saveActive();
    notifyListeners();
  }

  /// Pauses a running pre-translation job. The worker loop checks this state
  /// between pages and waits until [resume] is called or the job is canceled.
  ///
  /// 🔴 studio 任务**不支持暂停**，这里直接不动它：`StudioChapterRunner` 只认
  /// `CancellationToken`，没有"暂停"这个状态。如果照旧把 status 改成 paused，
  /// 卡片会显示"已暂停"而管线其实在继续跑 —— 那正是这个项目最忌讳的
  /// "UI 在说谎"。任务卡也因此不给 studio 任务画暂停按钮（`tasks_page.dart`）。
  void pause(String id) {
    var task = currentTasks.where((t) => t.id == id).firstOrNull;
    if (task == null || !task.isRunning || task.studio) return;
    task.status = PreTranslationTaskStatus.paused;
    _saveActive();
    notifyListeners();
  }

  /// Resumes a paused pre-translation job.
  void resume(String id) {
    var task = currentTasks.where((t) => t.id == id).firstOrNull;
    if (task == null || task.status != PreTranslationTaskStatus.paused) return;
    task.status = PreTranslationTaskStatus.running;
    _saveActive();
    notifyListeners();
    if (!_runningIds.contains(id)) {
      unawaited(_run(task));
    }
  }

  /// Manually re-runs the failed pages of a job. Works on a running job (the
  /// running loop's own auto-retry already covers it, so this is mainly for a
  /// finished one) or a finished/failed job in history: the job is moved back
  /// to the active list, set running, and re-driven — [_run]'s forward loop
  /// no-ops on already-processed chapters, then [_retryFailedPasses] re-runs
  /// just the failed pages. Succeeded pages are never re-requested (they skip
  /// via hasRenderedPage). Does nothing if the job has no failures.
  void retryFailed(String id) {
    var task =
        currentTasks.where((t) => t.id == id).firstOrNull ??
        historyTasks.where((t) => t.id == id).firstOrNull;
    if (task == null || !task.hasFailures) return;
    if (_runningIds.contains(task.id)) return;
    if (historyTasks.remove(task)) {
      currentTasks.insert(0, task);
    }
    task.status = PreTranslationTaskStatus.running;
    task.finishedAt = null;
    _canceledIds.remove(task.id);
    _saveActive();
    notifyListeners();
    unawaited(_run(task));
  }

  void _refreshKeepAlive(PreTranslationTask task) {
    var activity = _activities[task.id];
    // Processed, not succeeded: a chapter whose pages keep failing would
    // otherwise leave the notification frozen on the last successful page.
    var processed = activity?.liveProcessed(task) ?? (task.done + task.failed);
    BackgroundKeepAlive.instance.update(
      BackgroundKeepAlive.tagPreTranslate,
      formatTaskStatus(
        title: task.title,
        detail: task.total == 0 ? null : '$processed/${task.total}',
      ),
    );
  }

  Future<void> _run(PreTranslationTask task) async {
    if (_runningIds.contains(task.id)) return;
    if (_canceledIds.contains(task.id) || !currentTasks.contains(task)) {
      return;
    }
    _runningIds.add(task.id);
    _activities[task.id] = PreTranslationActivity();
    _refreshKeepAlive(task);
    try {
      // 🔴 只有工作室一条路：旧引擎（`ImageTranslationService`）已随旧链路删除。
      if (task.studio) {
        await _runStudio(task);
      } else {
        // 非 studio 任务没有任何执行体可跑。**响亮地失败**而不是静默 no-op：
        // 静默会让"我点了预翻译但什么都没发生"变成一件查不到的事。
        Log.error(
          'Pre-translation',
          'legacy task ${task.id} (${task.chapters.length} chapters) has no '
          'runner: the legacy pipeline was removed. Enqueue through '
          'StudioChapterQueue instead.',
        );
        task.status = PreTranslationTaskStatus.failed;
      }
    } catch (e, s) {
      Log.error('Pre-translation', '$e', s);
      task.status = PreTranslationTaskStatus.failed;
    } finally {
      _canceledIds.remove(task.id);
      _runningIds.remove(task.id);
      // studio 任务的令牌随任务一起丢掉：管线已经停了，留着它只会让下一次
      // 同 id 的任务（不会发生，id 是时间戳）拿到一个已取消的令牌。
      _studioTokens.remove(task.id);
      // The coalescing timer is shared by every running job, so it is not this
      // job's to cancel; the notifyListeners below already flushes this one.
      _activities.remove(task.id);
      _moveToHistory(task);
      if (currentTasks.every((t) => !t.isRunning)) {
        BackgroundKeepAlive.instance.remove(
          BackgroundKeepAlive.tagPreTranslate,
        );
      }
      onTaskFinished?.call(task);
      notifyListeners();
    }
  }

  /// studio 模式：把整章交给注入的执行体（[StudioTaskRunner]）。
  ///
  /// 本方法**不认识** `TranslationProject` / `StudioChapterRunner` —— 它只做四
  /// 件事：建令牌、报进度、定状态、写日志。工作室那半边的知识全部留在
  /// `studio_enqueue.dart` 里（见 [StudioTaskRunner] 的说明）。
  Future<void> _runStudio(PreTranslationTask task) async {
    final chapter = task.chapters.isEmpty ? null : task.chapters.first;
    final runner = studioRunner;
    if (chapter == null) {
      task.status = PreTranslationTaskStatus.failed;
      return;
    }
    if (runner == null) {
      // 没有执行体 = 这一次跑**什么都没做**。静默标成"完成"会把
      // "阅读器永远显示原图"变成一个没有任何线索的现象。
      Log.error(
        'Pre-translation',
        'studio task ${task.id}: no runner registered '
        '(studioRunner is null — see StudioTaskRunner)',
      );
      chapter.failed = 1;
      task.status = PreTranslationTaskStatus.failed;
      return;
    }
    final token = CancellationToken();
    _studioTokens[task.id] = token;
    // 开局就已被取消（上一次会话遗留的 running 任务被用户点掉）时不要白跑。
    if (_canceledIds.contains(task.id)) token.cancel();

    final StudioTaskOutcome outcome;
    try {
      outcome = await runner(task, token, (done, total) {
        chapter.total = total;
        chapter.done = done;
        _notifyActivity();
      });
    } catch (e, s) {
      Log.error('Pre-translation', 'studio task ${task.id} threw: $e', s);
      task.status = PreTranslationTaskStatus.failed;
      return;
    }
    chapter.done = outcome.done;
    chapter.failed = outcome.failed;
    // 已经被 [cancel] 收走的任务不必再定状态（它此刻已经在 history 里了）。
    if (task.status != PreTranslationTaskStatus.running) return;
    task.status = outcome.canceled
        ? PreTranslationTaskStatus.canceled
        : (outcome.failed > 0 && outcome.done == 0
              ? PreTranslationTaskStatus.failed
              : PreTranslationTaskStatus.completed);
  }

  void _moveToHistory(PreTranslationTask task) {
    if (!currentTasks.remove(task)) {
      return;
    }
    task.finishedAt ??= DateTime.now();
    historyTasks.insert(0, task);
    if (historyTasks.length > 50) {
      historyTasks.removeRange(50, historyTasks.length);
    }
    _saveActive();
    _saveHistory();
  }

  // -------------------------------------------------------------------------
  // Persistence
  // -------------------------------------------------------------------------

  static const _activeKey = 'pre_translation_active_tasks';
  static const _historyKey = 'pre_translation_task_history';

  void _saveActive() {
    appdata.implicitData[_activeKey] = currentTasks
        .where((t) => t.isRunning)
        .map((t) => t.toJson())
        .toList();
    appdata.writeImplicitData();
  }

  void _saveHistory() {
    appdata.implicitData[_historyKey] = historyTasks
        .map((t) => t.toJson())
        .toList();
    appdata.writeImplicitData();
  }

  void _load() {
    var active = appdata.implicitData[_activeKey];
    if (active is List) {
      currentTasks
        ..clear()
        ..addAll(
          active.whereType<Map>().map((e) {
            var task = PreTranslationTask.fromJson(
              Map<String, dynamic>.from(e),
            );
            // Anything persisted as active is coerced back to running so it can
            // be resumed after a restart.
            task.status = PreTranslationTaskStatus.running;
            task.finishedAt = null;
            return task;
          }),
        );
    }
    var history = appdata.implicitData[_historyKey];
    if (history is List) {
      historyTasks
        ..clear()
        ..addAll(
          history.whereType<Map>().map(
            (e) => PreTranslationTask.fromJson(Map<String, dynamic>.from(e)),
          ),
        );
    }
  }

  /// Resumes jobs interrupted by app termination. Called once at startup.
  void resumePendingTasks() {
    for (var task in currentTasks.toList()) {
      if (task.isRunning && !_runningIds.contains(task.id)) {
        unawaited(_run(task));
      }
    }
  }

  void clearHistory() {
    historyTasks.clear();
    _saveHistory();
    notifyListeners();
  }

  /// Resets the pre-translation status the chapter picker reads from, so that
  /// after the user clears all translation results the "translated" ticks and
  /// progress markers go away too. Finished/canceled/failed jobs (history) are
  /// dropped entirely; a still-running job keeps running but its counters are
  /// zeroed so its chapters re-count from scratch against the now-empty cache.
  void clearAllChapterStatus() {
    historyTasks.clear();
    for (var task in currentTasks) {
      for (var c in task.chapters) {
        c.done = 0;
        c.failed = 0;
        c.total = 0;
        c.canceled = false;
        c.failedPages.clear();
      }
    }
    _saveActive();
    _saveHistory();
    notifyListeners();
  }

  /// Resets the recorded pre-translation status of specific chapters of a comic
  /// (used by the picker's selection-based re-translate). Zeroes their counters
  /// in both history and any running job so the picker stops showing them as
  /// "translated" and a fresh run re-counts them from scratch against the now
  /// cleared cache.
  void resetChapterStatus(String cid, String sourceKey, Set<String> eids) {
    if (eids.isEmpty) return;
    var comicKey = '$cid@$sourceKey';
    for (var task in [...historyTasks, ...currentTasks]) {
      if (task.comicKey != comicKey) continue;
      for (var c in task.chapters) {
        if (eids.contains(c.eid)) {
          c.done = 0;
          c.failed = 0;
          c.total = 0;
          c.canceled = false;
          c.failedPages.clear();
        }
      }
    }
    _saveActive();
    _saveHistory();
    notifyListeners();
  }

  /// Resets the recorded pre-translation status of every chapter of one comic
  /// (used by the detail page's whole-comic re-translate). Drops that comic's
  /// finished history entries and zeroes any running job's counters so the
  /// picker's "translated" ticks for it clear, leaving other comics untouched.
  void resetComicStatus(String cid, String sourceKey) {
    var comicKey = '$cid@$sourceKey';
    historyTasks.removeWhere((t) => t.comicKey == comicKey);
    for (var task in currentTasks) {
      if (task.comicKey != comicKey) continue;
      for (var c in task.chapters) {
        c.done = 0;
        c.failed = 0;
        c.total = 0;
        c.canceled = false;
        c.failedPages.clear();
      }
    }
    _saveActive();
    _saveHistory();
    notifyListeners();
  }

  void removeTask(String id) {
    historyTasks.removeWhere((t) => t.id == id);
    _saveHistory();
    notifyListeners();
  }
}

/// Per-source image-fetch concurrency for pre-translation. The effective limit
/// is min(user setting, AIMD estimate); AIMD halves on a 429/503 from the image
/// host and grows back on success, so a rate-limiting host is backed off
/// automatically without the user tuning anything.