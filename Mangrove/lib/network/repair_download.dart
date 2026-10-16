import 'dart:async';
import 'dart:io';

import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/foundation/chapter_directory.dart';
import 'package:mangrove/foundation/comic_source/comic_source.dart';
import 'package:mangrove/foundation/comic_type.dart';
import 'package:mangrove/foundation/download_manager_store.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/missing_pages.dart';
import 'package:mangrove/network/download.dart';
import 'package:mangrove/utils/translations.dart';
import 'package:mangrove/network/images.dart';
import 'package:mangrove/utils/file_type.dart';
import 'package:mangrove/utils/io.dart';

/// Re-downloads individual pages recorded in `missing_pages.json` (P5-S4).
///
/// Unlike [ImagesDownloadTask] it never downloads whole chapters: it only
/// touches the pages listed in `targets`, reusing the exact same image channel
/// (WebView Lane for comix.to). A page that arrives is removed from the table;
/// a page that fails again keeps its entry with an incremented attempt count,
/// so it can be retried later. Only the pages the user asked to repair are
/// fetched — not the rest of the chapter.
class RepairDownloadTask extends DownloadTask with _RepairSpeedMixin {
  final ComicSource source;

  final String comicId;

  /// 非空 = 本任务只修复这一章（按章节拆分后的单章任务）。
  ///
  /// 2026-10-16 用户实测反馈：多章合并成一个"浓缩任务"会同时踩两个坑 ——
  /// ① 任务 id 整本共用（见 [id]），队列与「下载中」弹窗按 id 索引时互相
  /// 覆盖，渲染出一片空白占位；② 单任务 target 跨章时页级统计/回写语义
  /// 混乱。现在每个缺页章节一个独立任务，本章范围即任务范围。
  ///
  /// null = 旧版整本任务（仅持久化兼容，新代码一律传章节 id）。
  final String? chapterId;

  final String? comicTitle;

  final String? comicCover;

  /// Pages to repair. Held as copies so the run can mutate attempts/error and
  /// write results back to the persisted table independently of the source
  /// list (which a concurrent download run might also be editing).
  ///
  /// Entries whose [MissingPageEntry.url] is empty are **disk-detected gaps**
  /// (see `MissingPages.reconcileChapter`): the bookkeeping never knew the
  /// page's url. [resume] resolves them from the chapter's page list before
  /// anything is fetched, and drops the ones it cannot resolve.
  final List<MissingPageEntry> targets;

  RepairDownloadTask({
    required this.source,
    required this.comicId,
    required List<MissingPageEntry> targets,
    this.chapterId,
    this.comicTitle,
    this.comicCover,
  }) : targets = List<MissingPageEntry>.of(targets) {
    _total = this.targets.length;
  }

  // ---- runtime state ----
  bool _isRunning = false;
  bool _isError = false;
  String _message = "Preparing repair...".tl;

  late int _total;
  int _done = 0;
  int _repaired = 0;
  int _failed = 0;

  /// Index of the next target we still need to start a wrapper for.
  int _started = 0;

  final Map<String, _RepairImageWrapper> _tasks = {};

  @override
  String get id => repairTaskId(comicId, chapterId);

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  String? get cover => comicCover;

  @override
  String get title {
    final base = comicTitle ?? "Repairing...".tl;
    if (chapterId == null) return base;
    // 单章任务：标题带上章节，队列/过往列表里能直接看出在修哪一章。
    // 章节标签优先用条目登记的章节标题，回落目录名（chapterId）。
    final label = targets.isEmpty
        ? chapterId!
        : (targets.first.chapterTitle.isNotEmpty
              ? targets.first.chapterTitle
              : chapterId!);
    return "$base · $label";
  }

  @override
  String get message => _message;

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  double get progress => _total == 0 ? 0 : _done / _total;

  @override
  int get speed => currentSpeed;

  @override
  void cancel() {
    _isRunning = false;
    for (final t in _tasks.values) {
      t.cancel();
    }
    _tasks.clear();
    LocalManager().removeTask(this);
  }

  @override
  void pause() {
    if (isPaused) return;
    _isRunning = false;
    _message = "Paused".tl;
    _currentSpeed = 0;
    for (final t in _tasks.values) {
      if (!t.isFinished) t.cancel();
    }
    // Keep `_started` as-is; resume() resets it to `_done` so the in-flight
    // (now cancelled) pages are re-created rather than skipped.
    _tasks.clear();
    stopRecorder();
    notifyListeners();
    unawaited(LocalManager().saveCurrentDownloadingTasks());
  }

  /// Cleanly stop the repair run at app shutdown, persisting `wasRunning = true`
  /// (via [suspendShutdown]) so it auto-resumes next launch and keeps filling
  /// the missing pages it was working on.
  ///
  /// [suspendShutdown] is left `true` and cleared in [resume].
  @override
  Future<void> suspendForShutdown() async {
    if (isPaused) return;
    _isRunning = false;
    _message = "Paused".tl;
    _currentSpeed = 0;
    for (final t in _tasks.values) {
      if (!t.isFinished) t.cancel();
    }
    _tasks.clear();
    stopRecorder();
    notifyListeners();
    suspendShutdown = true;
    await LocalManager().saveCurrentDownloadingTasks();
  }

  @override
  void resume() async {
    if (_isRunning) return;
    _isError = false;
    _isRunning = true;
    suspendShutdown = false;
    _started = _done;
    _message = "Repairing @a pages".tlParams({"a": _total});
    notifyListeners();
    runRecorder();
    LocalManager().saveCurrentDownloadingTasks();

    final dir = path;
    if (dir == null || dir.isEmpty) {
      _setError("Repair target directory is missing".tl);
      return;
    }

    // 先补齐"只知其位、不知其址"的空洞条目：磁盘探测出的缺页没有任何 url，
    // 直接去 fetch 只会得到空指针。这里按 chapterId（=章节目录名）反查
    // chapterKey，再向源要一次该章的页列表，用 index 取回真实地址。
    //
    // ⚠️ 只在**首次启动**（还没有任何一页完成）时做：解析失败会把条目从
    // targets 里删掉，而 `_started`/`_done` 是按列表下标推进的，在途删除会让
    // 断点错位、已完成的页被重下。
    if (_done == 0) {
      if (!await _resolveBlankUrls()) return;
      _started = 0;
      if (targets.isEmpty) {
        _finalize();
        return;
      }
      _total = targets.length;
    }
    _message = "Repairing @a pages".tlParams({"a": _total});
    notifyListeners();

    final maxConcurrent = ((appdata.settings["downloadThreads"] as num?) ?? 3)
        .toInt()
        .clamp(1, 8);

    while (_isRunning && _done < _total) {
      while (_isRunning && _tasks.length < maxConcurrent && _started < _total) {
        final entry = targets[_started];
        _started++;
        final saveTo = Directory(FilePath.join(dir, entry.chapterId));
        if (!saveTo.existsSync()) {
          try {
            saveTo.createSync(recursive: true);
          } catch (e) {
            Log.error("Repair", "Failed to create $saveTo: $e");
          }
        }
        final wrapper = _RepairImageWrapper(this, entry, saveTo);
        _tasks[entry.key] = wrapper;
        unawaited(
          wrapper.wait().then((w) {
            _tasks.remove(w.entry.key);
            // A cancelled wrapper means we paused: its stats must not change, or
            // resume() would skip a page that never finished.
            if (w.isCancelled) return;
            _done++;
            if (w.isComplete) {
              unawaited(
                MissingPages.removeEntry(dir, w.entry.chapterId, w.entry.index),
              );
              _repaired++;
            } else {
              final updated = MissingPageEntry(
                chapterId: w.entry.chapterId,
                chapterTitle: w.entry.chapterTitle,
                index: w.entry.index,
                url: w.entry.url,
                error: w.error ?? "unknown",
                attempts: w.entry.attempts + 1,
                firstFailedAt: w.entry.firstFailedAt,
                lastFailedAt: w.entry.lastFailedAt,
              );
              unawaited(MissingPages.putEntry(dir, updated));
              _failed++;
            }
            if (_isRunning) _pump();
          }),
        );
      }
      if (_tasks.isNotEmpty) {
        await Future.any(_tasks.values.map((w) => w.wait()));
      }
      if (isPaused) return;
      if (_done >= _total) break;
    }

    stopRecorder();
    if (!_isRunning) return; // paused/cancelled during the final wait
    _finalize();
  }

  /// 把 targets 里 url 为空的"磁盘空洞"条目补上真实地址。
  ///
  /// 这些条目来自 `MissingPages.reconcileChapter` 的磁盘对账：它只知道
  /// "第 N 页的文件不在"，不知道去哪儿取。这里按 chapterId（正是章节目录名，
  /// 规则见 `chapterDirectoryName`）反查 chapterKey，再向源要一次该章的页
  /// 列表，用 index 取回真实地址。解析不出来的条目会被丢弃并记日志 ——
  /// 拿空 url 去 fetch 只会得到一个不可读的空指针错误。
  ///
  /// 返回 false 表示解析途中任务被取消/暂停。
  Future<bool> _resolveBlankUrls() async {
    final blanks = <int>[
      for (var i = 0; i < targets.length; i++)
        if (targets[i].url.trim().isEmpty) i,
    ];
    if (blanks.isEmpty) return true;

    final loadPages = source.loadComicPages;
    if (loadPages == null) {
      Log.warning(
        "Repair",
        "Source '${source.key}' cannot list pages; dropping ${blanks.length} "
        "disk-detected gap(s) that have no stored url",
      );
      targets.removeWhere((e) => e.url.trim().isEmpty);
      return true;
    }

    final comic = LocalManager().isInitialized
        ? LocalManager().find(comicId, comicType)
        : null;
    final chapters = comic?.chapters;
    final keyByDir = <String, String>{};
    if (chapters != null) {
      for (final key in chapters.allVersionKeys) {
        final name = chapterDirectoryName(chapters, key);
        if (name.isNotEmpty) keyByDir.putIfAbsent(name, () => key);
      }
    }

    final cache = <String, List<String>>{};
    var unresolved = 0;
    for (final i in blanks) {
      if (!_isRunning) return false;
      final entry = targets[i];
      final chapterKey = keyByDir[entry.chapterId];
      if (chapterKey == null) {
        unresolved++;
        continue;
      }
      List<String>? urls = cache[chapterKey];
      if (urls == null) {
        _message = "Resolving page list...".tl;
        notifyListeners();
        final res = await loadPages(comicId, chapterKey);
        if (!_isRunning) return false;
        if (res.error) {
          Log.warning(
            "Repair",
            "Cannot list pages of $chapterKey: ${res.errorMessage}",
          );
          unresolved++;
          continue;
        }
        urls = res.dataOrNull ?? const <String>[];
        cache[chapterKey] = urls;
      }
      if (entry.index < 0 || entry.index >= urls.length) {
        unresolved++;
        continue;
      }
      targets[i] = MissingPageEntry(
        chapterId: entry.chapterId,
        chapterTitle: entry.chapterTitle,
        index: entry.index,
        url: urls[entry.index],
        error: entry.error,
        attempts: entry.attempts,
        firstFailedAt: entry.firstFailedAt,
        lastFailedAt: entry.lastFailedAt,
      );
    }
    if (unresolved > 0) {
      Log.warning(
        "Repair",
        "Dropped $unresolved gap(s) whose url could not be resolved",
      );
      targets.removeWhere((e) => e.url.trim().isEmpty);
    }
    return true;
  }

  void _pump() {
    _message = "Repaired @a/@b".tlParams({"a": _repaired, "b": _total});
    if (_failed > 0) {
      _message = "$_message · ${"@a failed".tlParams({"a": _failed})}";
    }
    LocalManager().scheduleSaveDownloadingTasks();
    notifyListeners();
  }

  void _finalize() {
    _isRunning = false;
    if (_total == 0) {
      // Every target was a disk-detected gap whose url could not be resolved
      // (chapter gone from the source, or the source cannot list pages).
      Log.warning("Repair", "Nothing to repair for '$title'");
      _message = "Nothing to repair".tl;
      notifyListeners();
      LocalManager().removeTask(this);
      return;
    }
    if (_failed == 0) {
      Log.info("Repair", "Repaired all $_repaired missing page(s) of '$title'");
    } else {
      Log.info(
        "Repair",
        "Repair finished for '$title': $_repaired repaired, $_failed still missing",
      );
    }
    _message = _failed == 0
        ? "Repaired @a pages".tlParams({"a": _repaired})
        : "Repaired @a, still missing @b".tlParams({
            "a": _repaired,
            "b": _failed,
          });
    notifyListeners();
    // 「过往任务」：修复收尾也记入历史（下载管理分区的过往队列展示）。
    DownloadHistoryStore.instance.record(
      DownloadHistoryEntry(
        comicId: comicId,
        comicTypeValue: comicType.value,
        title: title,
        cover: comicCover,
        sourceKey: source.key,
        time: DateTime.now(),
        kind: 'repair',
        repaired: _repaired,
        failed: _failed,
      ),
    );
    // Remove from the queue and let the next runnable task start. Unlike
    // completeTask() we do NOT re-add the comic to the library: it is already
    // there, we only filled in missing pages.
    LocalManager().removeTask(this);
    // 但**必须**把"这一话现在有本地副本"回写到 `downloadedChapters`：
    // 修复只写磁盘 + 缺页表，而 `downloadedChapters` 才是 UI 的唯一判据
    // （章节标签配色 / 下载页勾选框 / 阅读器章节列表）。不回写就会出现
    // "磁盘 177 页齐全、界面却说未下载"——用户报告的那个冲突。
    //
    // 走与其它路径同一个磁盘扫描入口（`reconcileDiskState`），所以本地导入的
    // 漫画、以及正在下载的漫画仍会被各自的守卫跳过。
    // ⚠️ 必须放在 `removeTask` **之后**：`isDownloading` 的守卫看的是队列，
    // 任务还在队里时对账会直接空转返回。
    final comic = LocalManager().isInitialized
        ? LocalManager().find(comicId, comicType)
        : null;
    if (comic != null) {
      unawaited(LocalManager().reconcileDiskState(comic));
    }
  }

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    final key = diskFullMessageKey(message);
    _message = key != null ? key.tl : message;
    stopRecorder();
    notifyListeners();
    Log.error("Repair", message);
    LocalManager().onTaskError(this);
  }

  @override
  Map<String, dynamic> toJson() => {
    "type": "RepairDownloadTask",
    "source": source.key,
    "comicId": comicId,
    if (chapterId != null) "chapterId": chapterId,
    "comicTitle": comicTitle,
    "comicCover": comicCover,
    "path": path,
    "targets": targets.map((e) => e.toJson()).toList(),
    "wasRunning": _isRunning || suspendShutdown,
    "userPaused": userPaused,
  };

  static RepairDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "RepairDownloadTask") return null;
    final source = ComicSource.find(json["source"]);
    if (source == null) return null;
    final targets = <MissingPageEntry>[];
    if (json["targets"] is List) {
      for (final item in json["targets"]) {
        final e = MissingPageEntry.fromJson(item);
        if (e != null) targets.add(e);
      }
    }
    if (targets.isEmpty) return null;
    final chapterId = json["chapterId"];
    return RepairDownloadTask(
        source: source,
        comicId: json["comicId"],
        // 旧持久化数据没有 chapterId → null → 走旧版整本 id，兼容恢复。
        chapterId: chapterId is String && chapterId.isNotEmpty
            ? chapterId
            : null,
        targets: targets,
        comicTitle: json["comicTitle"],
        comicCover: json["comicCover"],
      )
      ..path = json["path"]
      ..wasRunning = json["wasRunning"] ?? false
      ..userPaused = json["userPaused"] ?? false;
  }

  @override
  LocalComic toLocalComic() {
    // A repair task does not (re)create the comic record; it only fills in
    // missing pages. Returning a stub satisfies the abstract contract without
    // ever being used to insert a duplicate row.
    return LocalComic(
      id: comicId,
      title: title,
      subtitle: '',
      tags: const ['Repair'],
      directory: path == null ? '' : Directory(path!).name,
      chapters: null,
      cover: '',
      comicType: comicType,
      downloadedChapters: const [],
      createdAt: DateTime.now(),
    );
  }

  // ---- static entry points ----

  /// Queue repair run(s) for the given [entries] of [comic].
  ///
  /// 每个缺页章节建成**独立任务**（见 [groupRepairEntriesByChapter]）：
  /// 2026-10-16 用户实测，多章合并成一个"浓缩任务"会让任务 id 整本共用，
  /// 队列与「下载中」弹窗按 id 索引时互相覆盖，显示成一片空白占位；
  /// 且页级统计跨章混杂。拆开后一章一任务，队列、弹窗、过往记录都是
  /// 一章一条，暂停/继续/删除都能精确落到单章。
  ///
  /// [silent] = true 时不弹 toast（批量选择场景由调用方统一汇报结果）。
  ///
  /// 返回创建的任务数。
  static int enqueue(
    LocalComic comic,
    List<MissingPageEntry> entries, {
    bool silent = false,
  }) {
    if (entries.isEmpty) return 0;
    registerRepairDownloadTaskType();
    final source = comic.comicType.comicSource;
    if (source == null) {
      Log.error("Repair", "No source for ${comic.id}; cannot repair");
      return 0;
    }
    final tasks = <RepairDownloadTask>[];
    for (final group in groupRepairEntriesByChapter(entries).entries) {
      tasks.add(
        RepairDownloadTask(
          source: source,
          comicId: comic.id,
          chapterId: group.key,
          targets: group.value,
          comicTitle: comic.title,
          comicCover: comic.cover.isEmpty
              ? null
              : "file://${FilePath.join(comic.baseDir, comic.cover)}",
        )..path = comic.baseDir,
      );
    }
    LocalManager().addTasks(tasks);
    if (!silent) {
      App.rootContext.showMessage(
        message: "Created @a repair task(s)".tlParams({"a": tasks.length}),
      );
    }
    return tasks.length;
  }

  /// Repair every missing page of a comic (one task per chapter).
  static void repairComic(LocalComic comic) {
    final table = MissingPages.peek(comic.baseDir);
    if (table == null) return;
    enqueue(comic, table.entries.toList());
  }

  /// Repair every missing page of one chapter (by its directory name).
  static void repairChapter(LocalComic comic, String chapterDirId) {
    final table = MissingPages.peek(comic.baseDir);
    if (table == null) return;
    final entries = table.entries
        .where((e) => e.chapterId == chapterDirId)
        .toList();
    enqueue(comic, entries);
  }

  /// Repair a single missing page.
  static void repairEntry(LocalComic comic, MissingPageEntry entry) {
    enqueue(comic, [entry]);
  }
}

/// 把缺页条目按章节分组（保持首次出现顺序，不排序）。
///
/// 每个缺页章节必须建成独立的 [RepairDownloadTask]（用户 2026-10-16 反馈：
/// 多章合并成一个"浓缩任务"会让任务 id 冲突——旧 id 整本一个——队列与
/// "下载中"弹窗按 id 索引时互相覆盖，显示成一片空白占位）。
Map<String, List<MissingPageEntry>> groupRepairEntriesByChapter(
  List<MissingPageEntry> entries,
) {
  final byChapter = <String, List<MissingPageEntry>>{};
  for (final e in entries) {
    byChapter.putIfAbsent(e.chapterId, () => <MissingPageEntry>[]).add(e);
  }
  return byChapter;
}

/// 修复任务 id：旧版整本一个（`repair:<comicId>`），按章节拆分后为
/// `repair:<comicId>:<chapterId>`（一章一 id，队列/弹窗/持久化恢复都靠它
/// 区分任务）。[chapterId] 为空（旧数据）时回退旧格式。
String repairTaskId(String comicId, String? chapterId) {
  if (chapterId == null || chapterId.isEmpty) return "repair:$comicId";
  return "repair:$comicId:$chapterId";
}

/// Per-page downloader for a repair run. Mirrors [_ImageDownloadWrapper] from
/// download.dart but records results through [MissingPages] instead of the
/// task's own bookkeeping.
class _RepairImageWrapper {
  final RepairDownloadTask task;
  final MissingPageEntry entry;
  final Directory saveTo;

  _RepairImageWrapper(this.task, this.entry, this.saveTo) {
    start();
  }

  bool isComplete = false;
  String? error;
  bool isCancelled = false;

  bool get isFinished => isComplete || error != null || isCancelled;

  void cancel() => isCancelled = true;

  final List<Completer<_RepairImageWrapper>> _completers = [];

  void _notify() {
    for (final c in _completers) {
      if (!c.isCompleted) c.complete(this);
    }
    _completers.clear();
  }

  void start() async {
    var lastBytes = 0;
    try {
      await for (final p in ImageDownloader.loadComicImageUnwrapped(
        entry.url,
        task.source.key,
        task.comicId,
        entry.chapterId,
        forDownload: true,
      )) {
        if (isCancelled) {
          _notify();
          return;
        }
        task.onData(p.currentBytes - lastBytes);
        lastBytes = p.currentBytes;
        if (p.imageBytes != null) {
          final fileType = detectFileType(p.imageBytes!);
          if (!fileType.mime.startsWith('image/') ||
              p.imageBytes!.length < 100) {
            throw "Invalid image data (${p.imageBytes!.length} bytes, "
                "${fileType.mime})";
          }
          final finalFile = saveTo.joinFile("${entry.index}${fileType.ext}");
          // 原子写：先写 `.dl` 临时文件再 rename，避免修复途中退出留下半截文件
          // 被当成已修复页（见 ImagesDownloadTask 同款处理）。
          final tmpFile = saveTo.joinFile("${entry.index}${fileType.ext}.dl");
          await tmpFile.writeAsBytes(p.imageBytes!);
          try {
            await tmpFile.rename(finalFile.path);
          } catch (_) {
            if (finalFile.existsSync()) finalFile.deleteSync();
            await finalFile.writeAsBytes(p.imageBytes!);
          }
          isComplete = true;
          _notify();
          return;
        }
      }
      if (!isComplete && !isCancelled) {
        throw "No image data received".tl;
      }
    } catch (e, s) {
      if (isCancelled) {
        _notify();
        return;
      }
      Log.error(
        "Repair",
        "Page ${entry.chapterId}/${entry.index} failed: $e",
        s,
      );
      error = e.toString();
      _notify();
    }
  }

  Future<_RepairImageWrapper> wait() {
    if (isFinished) return Future.value(this);
    final c = Completer<_RepairImageWrapper>();
    _completers.add(c);
    return c.future;
  }
}

/// Minimal throughput recorder so the download list can show a live speed.
mixin _RepairSpeedMixin on DownloadTask {
  int _bytesSinceLastSecond = 0;
  int _currentSpeed = 0;

  int get currentSpeed => _currentSpeed;

  Timer? _recorderTimer;

  void onData(int length) {
    if (_recorderTimer == null) return;
    if (length < 0) return;
    _bytesSinceLastSecond += length;
  }

  void _onTick(Timer t) {
    _currentSpeed = _bytesSinceLastSecond;
    _bytesSinceLastSecond = 0;
  }

  void runRecorder() {
    _recorderTimer?.cancel();
    _bytesSinceLastSecond = 0;
    _recorderTimer = Timer.periodic(const Duration(seconds: 1), _onTick);
  }

  void stopRecorder() {
    _recorderTimer?.cancel();
    _recorderTimer = null;
    _currentSpeed = 0;
    _bytesSinceLastSecond = 0;
  }
}

/// Register this task type with [DownloadTask.fromJson] so a persisted repair
/// run survives a restart. A top-level `final` initializer would be *lazy* in
/// Dart (it only runs when the variable is first read), so registration is an
/// explicit call, invoked from `initDeferred()` before saved tasks are restored
/// and again from every [RepairDownloadTask] entry point.
void registerRepairDownloadTaskType() {
  DownloadTask.registerDownloadTaskType(
    "RepairDownloadTask",
    RepairDownloadTask.fromJson,
  );
}
