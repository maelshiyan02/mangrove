import 'dart:async';
import 'dart:io';

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/chapter_directory.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/missing_pages.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';

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
  String get id => "repair:$comicId";

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  String? get cover => comicCover;

  @override
  String get title => comicTitle ?? "Repairing...".tl;

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

  @override
  void resume() async {
    if (_isRunning) return;
    _isError = false;
    _isRunning = true;
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
    "comicTitle": comicTitle,
    "comicCover": comicCover,
    "path": path,
    "targets": targets.map((e) => e.toJson()).toList(),
    "wasRunning": _isRunning,
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
    return RepairDownloadTask(
        source: source,
        comicId: json["comicId"],
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

  /// Queue a repair run for the given [entries] of [comic]. Shows a toast and
  /// lets the download queue start it within the parallelism limit.
  static void enqueue(LocalComic comic, List<MissingPageEntry> entries) {
    if (entries.isEmpty) return;
    registerRepairDownloadTaskType();
    final source = comic.comicType.comicSource;
    if (source == null) {
      Log.error("Repair", "No source for ${comic.id}; cannot repair");
      return;
    }
    final task = RepairDownloadTask(
      source: source,
      comicId: comic.id,
      targets: entries,
      comicTitle: comic.title,
      comicCover: comic.cover.isEmpty
          ? null
          : "file://${FilePath.join(comic.baseDir, comic.cover)}",
    );
    task.path = comic.baseDir;
    LocalManager().addTask(task);
    App.rootContext.showMessage(message: "Repair started".tl);
  }

  /// Repair every missing page of a comic.
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
          final file = saveTo.joinFile("${entry.index}${fileType.ext}");
          await file.writeAsBytes(p.imageBytes!);
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
