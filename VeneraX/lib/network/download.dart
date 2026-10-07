import 'dart:async';
import 'dart:isolate';

import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/chapter_directory.dart';
import 'package:venera/foundation/comic_collection_chapter_id.dart';
import 'package:venera/foundation/comic_collection_store.dart';
import 'package:venera/foundation/comic_source/collection_source.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/missing_pages.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/archive.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/io.dart';

import 'file_downloader.dart';

abstract class DownloadTask with ChangeNotifier {
  /// 0-1
  double get progress;

  bool get isError;

  bool get isPaused;

  /// bytes per second
  int get speed;

  /// Estimated time remaining, or null when it can't be estimated yet (no
  /// throughput sample, unknown total). Shown in the download list (#12).
  Duration? get eta => null;

  void cancel();

  void pause();

  void resume();

  String get title;

  String? get cover;

  String get message;

  /// 第二行说明：来源网站 · 翻译组 · 章节名。国内源没有翻译组，只有
  /// "网站 · 章节名"。null 表示该任务类型不展示（基类默认）。
  String? get subtitle => null;

  /// root path for the comic. If null, the task is not scheduled.
  String? path;

  /// Whether the task was actively running when its state was last persisted.
  /// Lets the queue auto-resume genuinely-interrupted downloads on restart
  /// without reviving tasks the user had manually paused.
  bool wasRunning = false;

  /// How many times the queue has auto-retried this task after it errored.
  /// Bounded by [LocalManager] so a permanently-failing task eventually stops
  /// retrying and waits for the user. Reset when the user retries manually.
  int autoRetryCount = 0;

  /// True when the user explicitly paused this task (vs. it merely waiting its
  /// turn in the queue). The queue won't auto-resume a user-paused task, and it
  /// stays paused across restarts. Set by [pause]/[resume] paths via the queue.
  bool userPaused = false;

  /// convert current state to json, which can be used to restore the task
  Map<String, dynamic> toJson();

  LocalComic toLocalComic();

  String get id;

  ComicType get comicType;

  /// Lets additional [DownloadTask] subclasses (e.g. RepairDownloadTask) plug
  /// into [fromJson] without download.dart importing them — which would create
  /// a circular import (the subclass `extends DownloadTask`, defined here, and
  /// would fail to resolve during the cycle). Each subclass registers itself
  /// once at library load time.
  static final Map<String, DownloadTask? Function(Map<String, dynamic>)>
  _typeRegistry = {};

  static void registerDownloadTaskType(
    String type,
    DownloadTask? Function(Map<String, dynamic>) fromJson,
  ) {
    _typeRegistry[type] = fromJson;
  }

  static DownloadTask? fromJson(Map<String, dynamic> json) {
    final factory = _typeRegistry[json["type"]];
    if (factory != null) return factory(json);
    switch (json["type"]) {
      case "ImagesDownloadTask":
        return ImagesDownloadTask.fromJson(json);
      case "ArchiveDownloadTask":
        return ArchiveDownloadTask.fromJson(json);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is DownloadTask &&
        other.id == id &&
        other.comicType == comicType;
  }

  @override
  int get hashCode => Object.hash(id, comicType);
}

class ImagesDownloadTask extends DownloadTask with _TransferSpeedMixin {
  final ComicSource source;

  final String comicId;

  /// comic details. If null, the comic details will be fetched from the source.
  ComicDetails? comic;

  /// chapters to download. If null, all chapters will be downloaded.
  List<String>? chapters;

  @override
  String get id => comicId;

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  String? comicTitle;

  /// Cover url already known by whoever created the task. A queued task only
  /// fetches comic details (and the real cover) once it starts running, so
  /// without this the whole queue would render blank covers while waiting.
  final String? comicCover;

  ImagesDownloadTask({
    required this.source,
    required this.comicId,
    this.comic,
    this.chapters,
    this.comicTitle,
    this.comicCover,
  });

  @override
  void cancel() {
    _isRunning = false;
    LocalManager().removeTask(this);
    var local = LocalManager().find(id, comicType);
    if (path != null) {
      if (local == null) {
        Future.sync(() async {
          var tasks = this.tasks.values.toList();
          for (var i = 0; i < tasks.length; i++) {
            if (!tasks[i].isComplete) {
              tasks[i].cancel();
              await tasks[i].wait();
            }
          }
          try {
            await Directory(path!).delete(recursive: true);
          } catch (e) {
            Log.error("Download", "Failed to delete directory: $e");
          }
        });
      } else if (chapters != null) {
        for (var c in chapters!) {
          // [chapters] 存的是 chapterKey，目录名要现算（带组形态）。
          final name = comic == null
              ? LocalManager.getChapterDirectoryName(c)
              : _chapterDirectoryName(c);
          var dir = Directory(FilePath.join(path!, name));
          if (dir.existsSync()) {
            dir.deleteSync(recursive: true);
          }
        }
      }
    }
  }

  @override
  String? get cover => _cover ?? comic?.cover ?? comicCover;

  @override
  String get message => _message;

  @override
  void pause() {
    if (isPaused) {
      return;
    }
    _isRunning = false;
    _message = "Paused".tl;
    _currentSpeed = 0;
    var shouldMove = <int>[];
    for (var entry in tasks.entries) {
      if (!entry.value.isComplete) {
        entry.value.cancel();
        shouldMove.add(entry.key);
      }
    }
    for (var i in shouldMove) {
      tasks.remove(i);
    }
    stopRecorder();
    notifyListeners();
    // Persist the paused state (wasRunning=false) so a manual pause is not
    // auto-resumed on next launch.
    LocalManager().saveCurrentDownloadingTasks();
  }

  @override
  double get progress {
    if (_totalChapters > 0) {
      // Blend whole-chapter progress with the current chapter's in-flight image
      // fraction so the bar advances smoothly instead of jumping a full chapter
      // at a time (#11).
      var base = _chapter / _totalChapters;
      var images = _images;
      var key = (images != null && _chapter < images.keys.length)
          ? images.keys.elementAt(_chapter)
          : null;
      var chapterImages = key == null ? null : images![key];
      if (chapterImages != null && chapterImages.isNotEmpty) {
        base += (_index / chapterImages.length) / _totalChapters;
      }
      return base.clamp(0.0, 1.0);
    }
    return _totalCount == 0 ? 0 : _downloadedCount / _totalCount;
  }

  @override
  Duration? get eta {
    // speed==0（字节级停滞，如被 CDN 挂起重试中）时一并隐藏：EMA 衰减很慢，
    // 只看 _imagesPerSecond 会让"约 Xh X m"在卡住时无限膨胀（用户反馈）。
    if (isPaused || isError || _imagesPerSecond <= 0 || speed == 0) return null;
    final remaining = (_totalCount - _downloadedCount).clamp(0, _totalCount);
    if (remaining <= 0) return null;
    return Duration(seconds: (remaining / _imagesPerSecond).ceil());
  }

  bool _isRunning = false;

  bool _isError = false;

  String _message = "Fetching comic info...".tl;

  String? _cover;

  /// All images to download, key is chapter name
  Map<String, List<String>>? _images;

  /// Downloaded image count
  int _downloadedCount = 0;

  /// Total image count
  int _totalCount = 0;

  /// Total chapters to download
  int _totalChapters = 0;

  /// Current downloading image index
  int _index = 0;

  /// Current downloading chapter, index of [_images]
  int _chapter = 0;

  /// Smoothed images-per-second throughput (EMA), driven once per second from
  /// [onNextSecond]. Used to estimate [eta]. Zero until the first full second.
  double _imagesPerSecond = 0;

  /// Downloaded-count snapshot at the previous tick, to derive per-second rate.
  int _lastDownloadedCount = 0;

  /// Pages that failed after exhausting their retries. They no longer fail the
  /// whole task: the chapter keeps whatever downloaded and the page is written
  /// to `missing_pages.json` so it can be repaired later (P5-S2).
  final List<MissingPageEntry> _missing = [];

  /// 主机封锁命中计数（S12 整体强化）：失败页的错误含 403 / 导航落地 null /
  /// about:blank / 取图超时，即 comix 轮换域被反爬拦截的典型症状。累计到阈值
  /// 后 [_hostBlockSuspected] 为真，任务副标题/状态提示"host blocked"，让用户
  /// 明白缺失是源侧封锁而非软件 bug。
  int _hostBlockHits = 0;

  bool get _hostBlockSuspected => _hostBlockHits >= 2;

  /// Pages that were missing before (or failed earlier in this run) and have
  /// since been downloaded successfully. Flushed as deletions so a resumed
  /// download auto-clears its own entries.
  final Set<String> _recovered = {};

  /// Number of pages that could not be downloaded in this task.
  int get missingCount => _missing.length;

  /// True when the task finished downloading but some pages are absent.
  bool get isPartial => missingCount > 0;

  /// 只读诊断快照，供 `--headless download-check` 观察多轮渐进超时的真实行为
  /// （第几轮、成功/缺页数、是否疑似主机封锁）。GUI 不使用，纯为 headless
  /// 验证而暴露——下载腿此前没有 headless 入口，多轮超时只能靠肉眼看状态栏。
  Map<String, dynamic> debugSnapshot() {
    return {
      'title': title,
      'source': source.key,
      'comicId': comicId,
      'message': _message,
      'running': _isRunning,
      'error': _isError,
      // 当前轮次（1-based；0 = 不在章节下载池内/已结束）
      'round': _downloadRound,
      'roundTimeoutSeconds': _downloadRound == 0
          ? null
          : _roundTimeouts[(_downloadRound - 1).clamp(0, _roundTimeouts.length - 1)],
      'downloaded': _downloadedCount,
      'total': _totalCount,
      'chapterIndex': _chapter,
      'totalChapters': _totalChapters,
      'missing': _missing.length,
      'hostBlockHits': _hostBlockHits,
      'hostBlocked': _hostBlockSuspected,
      'missingPages': [
        for (final e in _missing)
          {
            'chapter': e.chapterId,
            'index': e.index,
            'attempts': e.attempts,
            'error': e.error,
          },
      ],
    };
  }

  /// Directory name a chapter's pages are stored in. Empty for comics without
  /// chapters, where pages live directly in the comic root.
  ///
  /// 规则本体在 [chapterDirectoryName]（版本化且带组名时为 `<话号> [组名]`），
  /// 读取侧 `LocalManager.getImagesForComic` 调的是同一个函数 —— 两侧绝不
  /// 能各写一份，否则"下载完读不到"。
  String _chapterDirectoryName(String chapterKey) {
    final chapters = comic?.chapters;
    if (chapters == null) return '';
    return chapterDirectoryName(chapters, chapterKey);
  }

  /// 本次任务要下载的章节 key 序列。
  ///
  /// [chapters] 为空（"下载全部"）时只取每话的**首选版本**，保持旧语义 ——
  /// 否则 comix.to 这类"一话十几组"的源会把 7 话炸成 70 话。用户显式勾选时
  /// [chapters] 里可能放着任意版本（非首选）的 key，必须拿全量版本 key 去
  /// 匹配，否则选了 B 组结果一个都匹配不上、什么都不会下载。
  List<String> _chapterKeysToDownload() {
    final chapters = comic!.chapters!;
    final all = this.chapters == null
        ? chapters.allChapters.keys.toList()
        : chapters.allVersionKeys.toList();
    return all.where((i) => this.chapters?.contains(i) ?? true).toList();
  }

  /// 仅统计"主机封锁"命中（403 / 导航落地 null / about:blank / 取图超时），
  /// 用于状态提示"host blocked"。**每一轮**都统计——即便中间轮不落盘，也能
  /// 尽早让用户看到"是源侧封锁而非软件 bug"。真正的 missing 落盘由
  /// [_onImageFailed]（仅末轮调用）负责。
  void _noteHostBlock(String err) {
    if (err.contains('403') ||
        err.contains('navigate landed on null') ||
        err.contains('about:blank') ||
        err.contains('image timeout')) {
      _hostBlockHits++;
    }
  }

  /// Record a page that failed all retries (final round only).
  void _onImageFailed(_ImageDownloadWrapper wrapper) {
    final entry = MissingPageEntry(
      chapterId: wrapper.chapterId,
      chapterTitle: wrapper.chapterTitle,
      index: wrapper.index,
      url: wrapper.image,
      error: wrapper.error ?? 'unknown',
      attempts: _roundTimeouts.length,
    );
    _missing.removeWhere((e) => e.key == entry.key);
    _missing.add(entry);
    _recovered.remove(entry.key);
    Log.error(
      "Download",
      "Missing page ${entry.chapterId}/${entry.index}: ${entry.error}",
    );
  }

  /// A page arrived: it is no longer missing (covers both normal downloads and
  /// pages recovered by a resume/repair of the same task).
  void _onImageSucceeded(_ImageDownloadWrapper wrapper) {
    final key = "${wrapper.chapterId}#${wrapper.index}";
    final had = _missing.any((e) => e.key == key);
    if (had) {
      _missing.removeWhere((e) => e.key == key);
    }
    _recovered.add(key);
  }

  /// Merge this task's missing/recovered pages into the comic's table file.
  /// Called per chapter and once when the task ends so nothing is lost even if
  /// the app is killed mid-download.
  Future<void> _flushMissing() async {
    final dir = path;
    if (dir == null) return;
    final table = await MissingPages.load(dir);
    if (table.sourceKey.isEmpty) {
      // Fresh table: fill in the identity fields.
      table.sourceKey = source.key;
      table.comicId = comicId;
    }
    for (final key in _recovered) {
      final parts = key.split('#');
      if (parts.length != 2) continue;
      table.remove(parts[0], int.tryParse(parts[1]) ?? -1);
    }
    _recovered.clear();
    for (final entry in _missing) {
      table.upsert(entry);
    }
    await MissingPages.save(dir, table);
  }

  var tasks = <int, _ImageDownloadWrapper>{};

  /// 滚动窗口并发（取代早先"5 张一批、等满一批才继续"）：维护最多
  /// [_maxInFlight] 张图在途，任意一张到达终态（成功 / 记 missing / 取消）
  /// 立刻从前沿补下一张——**绝不因某张慢图（如被 CDN 403 挂起）而阻塞整批
  /// 头阻塞**（S12 附录4：旧批逻辑在 Diva 第 0 页卡死的直接原因）。
  /// 真实并发上限对齐 [_ComixImageWorker.laneCount]（comix_client.dart，全局
  /// WebView 通道数 = 3）：所有任务共享这有限的 lane，无需再叠全局槽位；窗口
  /// 上限与之对齐即可。硬编码以保持无循环依赖（该类为库内私有）。
  static const int _maxInFlight = 3; // == _ComixImageWorker.laneCount

  /// 多轮"渐进超时"的每轮超时预算（秒）。第 1 轮用最短超时把能快速下载的图
  /// 全部下载完——**绝不陪跑慢图**：一张图超时就记失败、让出窗口，让其它快图
  /// 继续（用户反馈根因：单张失败图原要等满 30s 才跳，极反效率）。第 1 轮
  /// 结束后只对仍缺失的页启动下一轮，逐步放宽超时（10→15→30s）攻坚"硬骨头"。
  /// 末轮（30s）的失败页才写进 missing_pages.json。正常宿主（static.comix.to）
  /// 靠多轮恢复偶发慢/超时页；主机封锁（DivaScans 轮换域）由 comix_client 的
  /// 单 token 快失败（6s）独立处理，不在此预算内叠加。
  static const List<int> _roundTimeouts = [5, 10, 15, 30];

  /// 当前正处于第几轮（1-based），仅用于状态提示；0 表示不在章节下载池内。
  int _downloadRound = 0;

  /// 进入本章下载池前已累计下载的图数（跨章节累计），用于把本章进度并入
  /// 整任务的 [_downloadedCount]（ETA 用）。
  int _downloadedBase = 0;

  /// Resolves a chapter's page list for downloading.
  ///
  /// A collection serves already-downloaded chapters as `file://` paths so the
  /// reader can use them offline, but this path feeds the URLs straight to the
  /// HTTP client. Asking the collection for the download variant makes it skip
  /// that shortcut and return real network URLs.
  Future<Res<List<String>>> _loadPagesForDownload(String? ep) {
    final loadPages = source.loadComicPages;
    if (loadPages == null) {
      return Future.value(
        Res.error("The source does not support loading pages".tl),
      );
    }
    if (ComicCollectionStore.isCollectionSourceKey(source.key)) {
      return loadCollectionPages(comicId, ep, forDownload: true);
    }
    return loadPages(comicId, ep);
  }

  Future<void> _resolveCollectionDownloadChapters() async {
    if (!_isRunning) return;
    final current = comic!.chapters;
    if (current == null) return;
    final pending = current.allChapters.keys
        .where((key) => chapters == null || chapters!.contains(key))
        .skip(_chapter);
    final replacements = <String, Map<String, String>>{};
    for (final key in pending) {
      final ref = decodeCollectionChapterId(key);
      if (ref == null ||
          ref.chapterId.isNotEmpty ||
          _images?[key] != null ||
          ComicType.fromKey(ref.sourceKey) == ComicType.local) {
        continue;
      }
      // Failed member details use the same empty id as single-chapter comics.
      // Resolve it before sending a null chapter argument to the member source.
      final memberSource = ComicSource.find(ref.sourceKey);
      if (memberSource?.loadComicInfo == null) {
        throw 'The source of this comic is not installed'.tl;
      }
      final result = await memberSource!.loadComicInfo!(ref.comicId);
      if (!_isRunning) return;
      if (result.error) throw result.errorMessage!;
      final memberChapters = result.data.chapters?.allChapters;
      if (memberChapters == null) continue;
      if (memberChapters.isEmpty) throw 'Unknown chapter'.tl;
      replacements[key] = {
        for (final entry in memberChapters.entries)
          encodeCollectionChapterId(
            sourceKey: ref.sourceKey,
            comicId: ref.comicId,
            chapterId: entry.key,
          ): entry.value,
      };
    }
    if (replacements.isEmpty) return;

    Map<String, String> expand(Map<String, String> entries) => {
      for (final entry in entries.entries)
        ...replacements[entry.key] ?? {entry.key: entry.value},
    };
    comic = ComicDetails.fromJson({
      ...comic!.toJson(),
      'subtitle': comic!.subTitle,
      'chapters': current.isGrouped
          ? {
              for (final group in current.groups)
                group: expand(current.getGroup(group)),
            }
          : expand(current.allChapters),
    });
    // Only pending entries expand, so completed chapters keep their positions.
    chapters = chapters
        ?.expand((key) => replacements[key]?.keys ?? [key])
        .toList();
  }

  /// 本章目录里**已存在的页下标集合**（续传用），每章扫一次即可。
  ///
  /// ⚠️ 此前每张图的 wrapper 启动都自己 `saveTo.listSync()` 扫一遍目录——百页
  /// 的章节就是百次同步目录扫描，Windows 上把"整章秒完成"的续传拖成分钟级，
  /// headless 回归直接卡死在这里。改为进入章节池时扫一次，之后复用。
  Set<int> _existingPageIndexes(Directory dir) {
    final cached = _existingPagesCache;
    if (cached != null && cached.$1 == dir.path) return cached.$2;
    final found = <int>{};
    if (dir.existsSync()) {
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        final dot = name.indexOf('.');
        if (dot <= 0) continue;
        final idx = int.tryParse(name.substring(0, dot));
        if (idx != null) found.add(idx);
      }
    }
    _existingPagesCache = (dir.path, found);
    return found;
  }

  (String, Set<int>)? _existingPagesCache;

  /// Create the wrapper for image [i] of the current chapter (directory
  /// resolution + terminal-state bookkeeping shared by the batch loop).
  /// [timeoutSeconds] is this round's per-image budget; [recordMissing] is true
  /// only on the final round (so transient mid-round failures aren't written to
  /// disk as permanent missing pages).
  _ImageDownloadWrapper _createWrapper(
    List<String> images,
    int i,
    int timeoutSeconds,
    bool recordMissing,
  ) {
    Directory saveTo;
    String chapterId = '';
    if (comic!.chapters != null) {
      final chapterKey = _images!.keys.elementAt(_chapter);
      chapterId = _chapterDirectoryName(chapterKey);
      saveTo = Directory(FilePath.join(path!, chapterId));
      if (!saveTo.existsSync()) {
        saveTo.createSync(recursive: true);
      }
    } else {
      saveTo = Directory(path!);
    }
    final task = _ImageDownloadWrapper(
      this,
      _images!.keys.elementAt(_chapter),
      images[i],
      saveTo,
      i,
      chapterId: chapterId,
      timeoutSeconds: timeoutSeconds,
      recordMissing: recordMissing,
    );
    tasks[i] = task;
    return task;
  }

  /// 多轮"渐进超时"下载池（取代旧的单轮 30s 死等）：
  ///
  /// - 第 1 轮用最短超时（5s）把能快速下载的图**一次性**全部下载完——绝不陪跑
  ///   慢图，一张图超时即记失败、让出窗口，其它快图继续（用户反馈根因：单张
  ///   失败图原要等满 30s 才跳，极反效率）。
  /// - 第 1 轮结束后，**只对仍缺失的页**启动下一轮，逐步放宽超时
  ///   （10s → 15s → 30s 上限）攻坚"硬骨头"——先最大化效率把能下的全下了，
  ///   再回头补失败页（用户定案流程）。
  /// - 主机封锁（DivaScans `*.site` 轮换域）由 comix_client 的单 token 快失败
  ///   （6s）独立处理，不在此超时预算内叠加；正常宿主（static.comix.to）靠多轮
  ///   恢复偶发慢/超时页。
  /// - 只有**最后一轮**才把失败页写进 missing_pages.json（并记录 host-block），
  ///   中间轮只跳过、不落盘，避免瞬时段落被误记为永久缺失。
  /// - 图片级并发仍对齐 [_ComixImageWorker.laneCount]（全局 3 条 WebView 通道），
  ///   窗口上限 [_maxInFlight]=3；与阅读/下载共享有限 lane，不再叠全局槽位。
  /// 返回 false 表示被暂停/取消。
  Future<bool> _downloadChapterPool(
    List<String> images,
    String Function() buildMessage,
  ) async {
    // 续传：已完成偏移从 [_index] 续起；本轮窗口只覆盖"仍未完成"的下标。
    _downloadedBase = _downloadedCount;
    // 换章必须重扫目录清单（每章扫一次，见 [_existingPageIndexes]）。
    _existingPagesCache = null;
    // 续传短路：整章的页都已在磁盘上（重跑/修复/headless 回归常见）时直接收尾，
    // 不再为每页分配 wrapper 空跑一轮。既省掉百次目录扫描，也让 `download-check`
    // 能在秒级完成而不是分钟级。
    final existing = _existingPageIndexes(
      Directory(
        FilePath.join(
          path!,
          _chapterDirectoryName(_images!.keys.elementAt(_chapter)),
        ),
      ),
    );
    if (existing.length >= images.length) {
      _index = images.length;
      _downloadedCount = _downloadedBase + images.length;
      _message = buildMessage();
      LocalManager().scheduleSaveDownloadingTasks();
      return _isRunning;
    }
    var pending = <int>[
      for (var i = 0; i < images.length; i++)
        if (tasks[i]?.isComplete != true && !existing.contains(i)) i,
    ];
    if (pending.isEmpty) return _isRunning;

    for (var r = 0; r < _roundTimeouts.length; r++) {
      if (!_isRunning) return false;
      final timeout = _roundTimeouts[r];
      final isFinal = r == _roundTimeouts.length - 1;
      _downloadRound = r + 1;
      if (pending.isEmpty) break;

      final active = <_ImageDownloadWrapper>[];
      var cursor = 0;
      while (_isRunning && pending.isNotEmpty) {
        // 1) 填充滚动窗口：从 pending 续起，最多 [_maxInFlight] 张在途。
        while (active.length < _maxInFlight && cursor < pending.length) {
          final i = pending[cursor++];
          final existing = tasks[i];
          if (existing != null && existing.isComplete) {
            // 已完成页：复用，wait() 立刻返回，会被下面 isFinished 过滤掉、
            // 并被 pending 收尾移出——不重复拉取（续传/修复安全网）。
            active.add(existing);
          } else {
            // 未完成（含上一轮失败/超时的页）：**每轮都重建新 wrapper** 用本轮
            // 更宽松的超时重新攻坚。绝不能复用"已终态但未完成"的旧 wrapper——
            // 那张图不会再次 _run()，失败页就永远跳过了（多轮渐进超时的前提）。
            active.add(_createWrapper(images, i, timeout, isFinal));
          }
        }
        if (active.isEmpty) break;
        // 2) 等任意一张到达终态即补位——快失败（超时/403）的图立刻腾出窗口，
        //    下一页继续，不再整批卡死。
        await Future.any(
          active.where((w) => !w.isFinished).map((w) => w.wait()),
        );
        active.removeWhere((w) => w.isFinished);
        // 3) 收尾：已完成页移出 pending，更新进度（截断式：已完成数即前沿）。
        pending.removeWhere((i) => tasks[i]?.isComplete == true);
        final done = tasks.values.where((w) => w.isComplete).length;
        _index = done;
        _downloadedCount = _downloadedBase + done;
        _message = buildMessage();
        if (!isFinal && pending.isNotEmpty) {
          // 非末轮：提示正在用更宽松的超时攻坚剩余失败页。
          _message = "$_message · ${"retry round @a/@b".tlParams({
            "a": r + 2,
            "b": _roundTimeouts.length,
          })}";
        }
        if (_missing.isNotEmpty) {
          _message =
              "$_message · ${"@a pages missing".tlParams({"a": _missing.length})}";
        }
        LocalManager().scheduleSaveDownloadingTasks();
      }
      // 一轮结束：重新统计仍缺失的页（中间轮只跳过不落盘，末轮才记 missing）。
      pending = <int>[
        for (var i = 0; i < images.length; i++)
          if (tasks[i]?.isComplete != true) i,
      ];
    }
    _downloadRound = 0;
    return _isRunning;
  }

  @override
  void resume() async {
    if (_isRunning) return;
    _isError = false;
    _message = "Resuming...".tl;
    _isRunning = true;
    notifyListeners();
    runRecorder();
    // Persist wasRunning=true promptly so an interrupted download auto-resumes
    // on next launch even if it crashes before the first progress checkpoint.
    LocalManager().saveCurrentDownloadingTasks();

    if (comic == null) {
      _message = "Fetching comic info...".tl;
      notifyListeners();
      var loadInfo = source.loadComicInfo;
      if (loadInfo == null) {
        _setError("Error: The source does not support loading comic info".tl);
        return;
      }
      var res = await _runWithRetry(() async {
        var r = await loadInfo(comicId);
        if (r.error) {
          throw r.errorMessage!;
        } else {
          return r.data;
        }
      });
      if (!_isRunning) {
        return;
      }
      if (res.error) {
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        comic = res.data;
      }
    }

    if (path == null) {
      try {
        var dir = await LocalManager().findValidDirectory(
          comicId,
          comicType,
          comic!.title,
        );
        if (!(await dir.exists())) {
          await dir.create();
        }
        path = dir.path;
      } catch (e, s) {
        Log.error("Download", e.toString(), s);
        _setError("Error: $e");
        return;
      }
    }

    await LocalManager().saveCurrentDownloadingTasks();

    if (_cover == null) {
      // 已有本地封面（对已下载漫画的补下/重下场景）直接复用，不再联网取
      // （用户定案：文件夹里已有 cover 就不需要重复下载）。封面文件可能是
      // 任意扩展名，按目录扫描而不是猜名字。
      String? existingCover;
      final comicDir = Directory(path!);
      if (comicDir.existsSync()) {
        for (final entity in comicDir.listSync()) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last.toLowerCase();
          if (name.startsWith('cover.')) {
            existingCover = entity.path;
            break;
          }
        }
      }
      if (existingCover != null) {
        _cover = "file://$existingCover";
        notifyListeners();
      }
    }

    if (_cover == null) {
      _message = "Downloading cover...".tl;
      notifyListeners();
      var res = await _runWithRetry(() async {
        Uint8List? data;
        // 第三个参数 cid 必传：详情页对"已有本地副本"的漫画会把 cover 换成
        // 本地文件名（"cover.jpg"），loadThumbnail 需要拿 cid 反查网络详情
        // 才能还原真实封面 URL；不传就死在相对封面分支里。
        await for (var progress in ImageDownloader.loadThumbnail(
          comic!.cover,
          source.key,
          comicId,
        )) {
          if (progress.imageBytes != null) {
            data = progress.imageBytes;
          }
        }
        if (data == null) {
          throw "Failed to download cover";
        }
        var fileType = detectFileType(data);
        var file = File(FilePath.join(path!, "cover${fileType.ext}"));
        file.writeAsBytesSync(data);
        return "file://${file.path}";
      });
      if (res.error) {
        Log.error("Download", res.errorMessage ?? "unknown error");
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        _cover = res.data;
        notifyListeners();
      }
      await LocalManager().saveCurrentDownloadingTasks();
    }

    if (_images == null) {
      if (comic!.chapters == null && source.loadComicInfo != null) {
        // Chapter info may be missing because the task was created from a
        // local-first placeholder (network details not yet resolved) or lost
        // during restore. Fetch authoritative details before deciding whether
        // this is a single- or multi-chapter comic, otherwise a multi-chapter
        // comic would download `chapter/null`. A genuinely single-chapter
        // comic keeps `chapters == null` and falls through to the path below.
        _message = "Fetching comic info...".tl;
        notifyListeners();
        var loadInfo = source.loadComicInfo;
        if (loadInfo == null) {
          _setError("Error: The source does not support loading comic info".tl);
          return;
        }
        var res = await _runWithRetry(() async {
          var r = await loadInfo(comicId);
          if (r.error) {
            throw r.errorMessage!;
          } else {
            return r.data;
          }
        });
        if (!_isRunning) return;
        if (res.error) {
          _setError("Error: ${res.errorMessage}");
          return;
        }
        comic = res.data;
        await LocalManager().saveCurrentDownloadingTasks();
      }
      if (comic!.chapters == null) {
        _message = "Fetching image list...".tl;
        notifyListeners();
        var res = await _runWithRetry(() async {
          var r = await _loadPagesForDownload(null);
          if (r.error) {
            throw r.errorMessage!;
          } else {
            return r.data;
          }
        });
        if (!_isRunning) {
          return;
        }
        if (res.error) {
          Log.error("Download", res.errorMessage ?? "unknown error");
          _setError("Error: ${res.errorMessage}");
          return;
        } else {
          _images = {'': res.data};
          _totalCount = _images!['']!.length;
        }
      } else {
        _images = {};
        _totalCount = 0;
      }
      _message = "$_downloadedCount/$_totalCount";
      notifyListeners();
      await LocalManager().saveCurrentDownloadingTasks();
    }

    if (ComicCollectionStore.isCollectionSourceKey(source.key)) {
      final result = await _runWithRetry(_resolveCollectionDownloadChapters);
      if (!_isRunning) return;
      if (result.error) {
        _setError("Error: ${result.errorMessage}");
        return;
      }
      await LocalManager().saveCurrentDownloadingTasks();
    }

    if (comic!.chapters != null) {
      var chapterKeys = _chapterKeysToDownload();
      _totalChapters = chapterKeys.length;
      var prefetchCount = 3;
      var chapterDelay = Duration.zero;
      var consecutiveFast = 0;
      const throttleThreshold = Duration(seconds: 20);
      var prefetchFutures = <String, Future<Res<List<String>>>>{};
      var prefetchStartTimes = <String, DateTime>{};

      void startPrefetch(int fromIndex) {
        for (
          var p = fromIndex;
          p < (fromIndex + prefetchCount).clamp(0, chapterKeys.length);
          p++
        ) {
          var key = chapterKeys[p];
          if (_images![key] != null || prefetchFutures.containsKey(key)) {
            continue;
          }
          prefetchStartTimes[key] = DateTime.now();
          prefetchFutures[key] = _runWithRetry(() async {
            var r = await _loadPagesForDownload(key);
            if (r.error) {
              throw r.errorMessage!;
            } else {
              return r.data;
            }
          });
        }
      }

      for (var ci = _chapter; ci < chapterKeys.length; ci++) {
        if (!_isRunning) return;
        var key = chapterKeys[ci];

        startPrefetch(ci);

        if (_images![key] == null) {
          _message = "Fetching image list (@a/@b)".tlParams({
            "a": ci + 1,
            "b": chapterKeys.length,
          });
          notifyListeners();

          if (chapterDelay > Duration.zero && ci > _chapter) {
            await Future.delayed(chapterDelay);
            if (!_isRunning) return;
          }

          var startTime = prefetchStartTimes.remove(key) ?? DateTime.now();
          var future =
              prefetchFutures.remove(key) ??
              _runWithRetry(() async {
                var r = await _loadPagesForDownload(key);
                if (r.error) {
                  throw r.errorMessage!;
                } else {
                  return r.data;
                }
              });
          var res = await future;
          var elapsed = DateTime.now().difference(startTime);
          if (!_isRunning) return;
          if (res.error) {
            Log.error("Download", res.errorMessage ?? "unknown error");
            _setError("Error: ${res.errorMessage}");
            return;
          }

          if (elapsed > throttleThreshold) {
            prefetchCount = 0;
            chapterDelay = const Duration(seconds: 5);
            consecutiveFast = 0;
            prefetchFutures.clear();
            prefetchStartTimes.clear();
          } else {
            consecutiveFast++;
            if (consecutiveFast >= 3 && prefetchCount < 3) {
              prefetchCount = 3;
              chapterDelay = Duration.zero;
            }
          }

          _images![key] = res.data;
          _totalCount += res.data.length;
          await LocalManager().saveCurrentDownloadingTasks();
        }

        var images = _images![key]!;
        tasks.clear();
        final ok = await _downloadChapterPool(
          images,
          () {
            var msg = "Ep.@a @b/@c".tlParams({
              "a": ci + 1,
              "b": _index,
              "c": images.length,
            });
            if (_missing.isNotEmpty) {
              msg = "$msg · ${"@a missing".tlParams({"a": _missing.length})}";
            }
            if (_hostBlockSuspected) {
              msg = "$msg · host blocked";
            }
            return msg;
          },
        );
        if (!ok) {
          // Paused/cancelled/errored: still persist what was recorded so far.
          unawaited(_flushMissing());
          return;
        }
        final chapterId = _chapterDirectoryName(key);
        final failed = _missing.where((e) => e.chapterId == chapterId).length;
        if (images.isNotEmpty && failed >= images.length) {
          // Not a couple of flaky images: nothing at all came through for this
          // chapter, which means the source/network is broken. Keep the error
          // semantics so the chapter is retried as a whole instead of being
          // stored as a fully-missing chapter.
          await _flushMissing();
          _setError("Failed to download images".tl);
          return;
        }
        await _flushMissing();
        _index = 0;
        _chapter++;
      }
    } else {
      while (_chapter < _images!.length) {
        var key = _images!.keys.elementAt(_chapter);
        var images = _images![key]!;
        tasks.clear();
        final ok = await _downloadChapterPool(
          images,
          () => "$_downloadedCount/$_totalCount",
        );
        if (!ok) {
          unawaited(_flushMissing());
          return;
        }
        final chapterId = _chapterDirectoryName(key);
        final failed = _missing.where((e) => e.chapterId == chapterId).length;
        if (images.isNotEmpty && failed >= images.length) {
          await _flushMissing();
          _setError("Failed to download images".tl);
          return;
        }
        await _flushMissing();
        _index = 0;
        _chapter++;
      }
    }

    await _flushMissing();
    if (_missing.isNotEmpty) {
      Log.info(
        "Download",
        "Completed '$title' with ${_missing.length} missing page(s)",
      );
      _message = "Completed, @a pages missing".tlParams({"a": _missing.length});
      notifyListeners();
    }

    LocalManager().completeTask(this);
    stopRecorder();
  }

  @override
  void onNextSecond(Timer t) {
    // Per-second image throughput as an EMA, smoothing out the bursty nature of
    // image completions so the ETA doesn't swing wildly (#12).
    final delta = _downloadedCount - _lastDownloadedCount;
    _lastDownloadedCount = _downloadedCount;
    if (delta >= 0) {
      _imagesPerSecond = _imagesPerSecond == 0
          ? delta.toDouble()
          : _imagesPerSecond * 0.6 + delta * 0.4;
    }
    notifyListeners();
    super.onNextSecond(t);
  }

  void _setError(String message) {
    // Never lose pages that were already recorded as missing before the error.
    unawaited(_flushMissing());
    _isRunning = false;
    _isError = true;
    // Surface a clear "out of storage" message instead of a raw errno (#18).
    var key = diskFullMessageKey(message);
    _message = key != null ? key.tl : message;
    notifyListeners();
    stopRecorder();
    LocalManager().onTaskError(this);
  }

  @override
  int get speed => currentSpeed;

  @override
  String get title => comic?.title ?? comicTitle ?? "Loading...";

  /// 下载卡片第二行：`来源网站 · 翻译组 · 章节名`。翻译组取当前正在下载
  /// 章节的版本信息——版本化章节（comix.to）每组每话的 key 都不同，能精确
  /// 归组；国内源的章节是扁平的，没有组，自然只显示 `网站 · 章节名`。
  @override
  String? get subtitle {
    final sourceName = source.name;
    final chs = comic?.chapters;
    String? key;
    if (_images != null && _images!.isNotEmpty) {
      key = _images!.keys.elementAt(_chapter.clamp(0, _images!.length - 1));
    } else if (chapters != null && chapters!.isNotEmpty) {
      key = chapters!.first;
    }
    if (key == null) return sourceName;
    final entry = chs?.versionEntryOf(key);
    final group = entry?.version.scanlationGroup?.trim();
    final chapterTitle = entry == null ? null : entry.version.title.trim();
    return [
      sourceName,
      if (group != null && group.isNotEmpty) group,
      if (chapterTitle != null && chapterTitle.isNotEmpty)
        chapterTitle
      else if (entry != null)
        "Chapter ${entry.chapterNumber}",
    ].join(" · ");
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ImagesDownloadTask",
      "source": source.key,
      "comicId": comicId,
      "comic": comic?.toJson(),
      "chapters": chapters,
      "path": path,
      "cover": _cover,
      "comicCover": comicCover,
      "comicTitle": comicTitle,
      "images": _images,
      "downloadedCount": _downloadedCount,
      "totalCount": _totalCount,
      "totalChapters": _totalChapters,
      "index": _index,
      "chapter": _chapter,
      "wasRunning": _isRunning,
      "userPaused": userPaused,
      // Missing pages live in `missing_pages.json`; this copy keeps the count
      // visible in the download list right after a restart.
      "missing": _missing.map((e) => e.toJson()).toList(),
    };
  }

  static ImagesDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ImagesDownloadTask") {
      return null;
    }

    Map<String, List<String>>? images;
    if (json["images"] != null) {
      images = {};
      for (var entry in json["images"].entries) {
        images[entry.key] = List<String>.from(entry.value);
      }
    }

    var missing = <MissingPageEntry>[];
    if (json["missing"] is List) {
      for (var item in json["missing"]) {
        var entry = MissingPageEntry.fromJson(item);
        if (entry != null) {
          missing.add(entry);
        }
      }
    }

    return ImagesDownloadTask(
        source: ComicSource.find(json["source"])!,
        comicId: json["comicId"],
        comic: json["comic"] == null
            ? null
            : ComicDetails.fromJson(json["comic"]),
        chapters: ListOrNull.from(json["chapters"]),
        comicCover: json["comicCover"],
        comicTitle: json["comicTitle"],
      )
      ..path = json["path"]
      ..wasRunning = json["wasRunning"] ?? false
      ..userPaused = json["userPaused"] ?? false
      .._cover = json["cover"]
      .._images = images
      .._downloadedCount = json["downloadedCount"] ?? 0
      .._totalCount = json["totalCount"] ?? 0
      .._totalChapters = json["totalChapters"] ?? 0
      .._index = json["index"] ?? 0
      .._chapter = json["chapter"] ?? 0
      .._missing.addAll(missing);
  }

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  LocalComic toLocalComic() {
    String coverName;
    if (path == null) {
      // Not scheduled yet, so there is no directory and no cover file to name.
      // Carry the remote cover url instead; `findImageProvider` recognises such
      // a placeholder by its empty directory and loads it over the network. A
      // record written to the database always has a path, so it never holds a
      // url here.
      coverName = comic?.cover ?? comicCover ?? '';
    } else {
      coverName = _cover == null
          ? ''
          : File(_cover!.split("file://").last).name;
    }
    return LocalComic(
      id: id,
      title: title,
      subtitle: comic?.subTitle ?? '',
      tags:
          comic?.tags.entries.expand((e) {
            return e.value.map((v) => "${e.key}:$v");
          }).toList() ??
          [],
      directory: path == null ? '' : Directory(path!).name,
      chapters: comic?.chapters,
      cover: coverName,
      comicType: comicType,
      downloadedChapters: chapters ?? comic?.chapters?.ids.toList() ?? [],
      createdAt: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is ImagesDownloadTask) {
      // ⚠️ 必须纳入 chapters：每章一个任务时，同漫画同来源的不同章节
      // 任务仅靠 comicId+source 判断会"相等"，被下载页的 toSet()/ValueKey
      // 当成同一项合并 → 表现为"两个任务堆在一张卡里、无法并行"（见 S12 附录4）。
      final a = chapters ?? const [];
      final b = other.chapters ?? const [];
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return other.comicId == comicId && other.source.key == source.key;
    }
    return false;
  }

  @override
  int get hashCode =>
      Object.hash(comicId, source.key, Object.hashAll(chapters ?? const []));
}

Future<Res<T>> _runWithRetry<T>(
  Future<T> Function() task, {
  int retry = 3,
}) async {
  for (var i = 0; i < retry; i++) {
    try {
      return Res(await task());
    } catch (e, s) {
      if (i == retry - 1) {
        // 堆栈必须落日志：任务卡片上只显示 message，"Null check operator
        // used on a null value" 这类错误没有堆栈根本无法定位（#S7U）。
        Log.error("Download", "step failed after $retry attempt(s): $e", s);
        return Res.error(e.toString());
      }
      await Future.delayed(Duration(seconds: i + 1));
    }
  }
  throw UnimplementedError();
}

class _ImageDownloadWrapper {
  final ImagesDownloadTask task;

  final String chapter;

  /// Directory name the page belongs to ('' for comics without chapters).
  final String chapterId;

  final int index;

  final String image;

  final Directory saveTo;

  /// 本轮的"单图超时预算"（秒）。由 [_downloadChapterPool] 的多轮渐进超时
  /// 传入（5 → 10 → 15 → 30），而非写死 30s——单张失败图一旦超时就记失败、
  /// 让出窗口让快图继续，绝不陪跑整段超时（用户反馈根因）。
  final int timeoutSeconds;

  /// 仅末轮为 true：命中即把页写进 missing_pages.json（[_onImageFailed]）。
  /// 中间轮为 false，失败只记 host-block 提示、不落盘，避免瞬时段落被误记为
  /// 永久缺失。重试预算统一交给多轮渐进超时，wrapper 内部不再递归重试。
  final bool recordMissing;

  _ImageDownloadWrapper(
    this.task,
    this.chapter,
    this.image,
    this.saveTo,
    this.index, {
    required this.chapterId,
    required this.timeoutSeconds,
    required this.recordMissing,
  }) {
    start();
  }

  /// 启动取图。并发上限由 [_ComixImageWorker.laneCount]（全局 3 条 WebView
  /// 通道）自然约束——所有任务共享这 3 条 lane，无需再叠一层全局槽位（此前
  /// 的 [_imageSlots] 与 3-lane 池打架，还制造了死锁风险，已移除）。
  void start() async {
    _run();
  }

  Future<void> _run() async {
    // 续传 / 修复前先确认：目标页若已存在（上次跑过、或同任务恢复），直接判
    // 完成，不重复拉取——避免重下整章把已好的页再拉一遍（S12 整体强化）。
    // 目录清单由任务层每章扫一次并缓存（见 [_existingPageIndexes]），这里
    // 不再自己 listSync()——百页章节那样扫会把续传拖成分钟级。
    if (task._existingPageIndexes(saveTo).contains(index)) {
      isComplete = true;
      task._onImageSucceeded(this);
      _notifyWaiters();
      return;
    }
    int lastBytes = 0;
    try {
      await for (var p in ImageDownloader.loadComicImageUnwrapped(
        image,
        task.source.key,
        task.comicId,
        chapter,
        forDownload: true,
        downloadTimeoutSeconds: timeoutSeconds,
      )) {
        if (isCancelled) {
          _notifyWaiters();
          return;
        }
        task.onData(p.currentBytes - lastBytes);
        lastBytes = p.currentBytes;
        if (p.imageBytes != null) {
          var fileType = detectFileType(p.imageBytes!);
          // Reject obvious garbage before saving it as a "page": a source can
          // answer 200 with an HTML error page, a truncated body, or an empty
          // response. detectFileType reports image/* only for real image magic
          // bytes, so a non-image mime (or a suspiciously tiny body) is treated
          // as a failure and retried instead of silently storing a broken page
          // that would surface as a corrupt image offline (#14).
          if (!fileType.mime.startsWith('image/') ||
              p.imageBytes!.length < 100) {
            throw "Invalid image data (${p.imageBytes!.length} bytes, "
                "${fileType.mime})";
          }
          var file = saveTo.joinFile("$index${fileType.ext}");
          await file.writeAsBytes(p.imageBytes!);
          isComplete = true;
          task._onImageSucceeded(this);
          _notifyWaiters();
        }
      }
    } catch (e, s) {
      if (isCancelled) {
        _notifyWaiters();
        return;
      }
      // 统计主机封锁命中（403/导航null/about:blank/超时）——每轮都统计，即便
      // 中间轮不落盘也尽早提示"是源侧封锁而非软件 bug"。真正的 missing 落盘
      // 只在末轮由 _onImageFailed 负责（重试预算统一交给多轮渐进超时，wrapper
      // 内不再递归重试，避免单图 30s+ 陪跑卡死）。
      task._noteHostBlock(e.toString());
      Log.error("Download", e.toString(), s);
      error = e.toString();
      if (recordMissing) {
        // 末轮：把页写进 missing_pages.json，任务以"部分完成"收尾，可后续修复。
        task._onImageFailed(this);
      }
      // 非末轮：只记下失败、让出窗口，下一轮（更宽松超时）会重新攻坚该页。
      _notifyWaiters();
    }
  }

  bool isComplete = false;

  String? error;

  bool isCancelled = false;

  /// Terminal state: succeeded, gave up after all retries, or cancelled. The
  /// chapter pool advances over these instead of stalling on a failed page.
  bool get isFinished => isComplete || error != null || isCancelled;

  /// Human readable chapter name, stored alongside the entry for display.
  String get chapterTitle => chapter;

  void cancel() {
    isCancelled = true;
  }

  var completers = <Completer<_ImageDownloadWrapper>>[];

  /// Complete every pending waiter. Critically also called on the cancelled
  /// path: otherwise `await wait()` in the download loop and in cancel()'s
  /// cleanup would hang forever on a cancelled image (B1).
  void _notifyWaiters() {
    for (var c in completers) {
      if (!c.isCompleted) {
        c.complete(this);
      }
    }
    completers.clear();
  }

  Future<_ImageDownloadWrapper> wait() {
    if (isFinished) {
      return Future.value(this);
    }
    var c = Completer<_ImageDownloadWrapper>();
    completers.add(c);
    return c.future;
  }
}

abstract mixin class _TransferSpeedMixin {
  int _bytesSinceLastSecond = 0;

  int _currentSpeed = 0;

  int get currentSpeed => _currentSpeed;

  Timer? timer;

  void onData(int length) {
    if (timer == null) return;
    if (length < 0) {
      return;
    }
    _bytesSinceLastSecond += length;
  }

  void onNextSecond(Timer t) {
    _currentSpeed = _bytesSinceLastSecond;
    _bytesSinceLastSecond = 0;
  }

  void runRecorder() {
    if (timer != null) {
      timer!.cancel();
    }
    _bytesSinceLastSecond = 0;
    timer = Timer.periodic(const Duration(seconds: 1), onNextSecond);
  }

  void stopRecorder() {
    timer?.cancel();
    timer = null;
    _currentSpeed = 0;
    _bytesSinceLastSecond = 0;
  }
}

class ArchiveDownloadTask extends DownloadTask {
  final String archiveUrl;

  final ComicDetails comic;

  late ComicSource source;

  /// Download comic by archive url
  ///
  /// Currently only support zip file and comics without chapters
  ArchiveDownloadTask(this.archiveUrl, this.comic) {
    source = ComicSource.find(comic.sourceKey)!;
  }

  FileDownloader? _downloader;

  /// Per-task temp path for the archive being downloaded. Keyed by source +
  /// comic so a different archive download can't reuse a leftover partial file
  /// (which would corrupt it). The matching `$path.download` status file lets
  /// [FileDownloader] resume after an interrupted run.
  String get _archiveTempPath => FilePath.join(
    App.dataPath,
    "archive_${source.key.hashCode}_${comic.id.hashCode}.zip",
  );

  String _message = "Fetching comic info...".tl;

  bool _isRunning = false;

  bool _isError = false;

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    // Surface a clear "out of storage" message instead of a raw errno (#18).
    var key = diskFullMessageKey(message);
    _message = key != null ? key.tl : message;
    notifyListeners();
    Log.error("Download", message);
    LocalManager().onTaskError(this);
  }

  @override
  void cancel() async {
    _isRunning = false;
    await _downloader?.stop();
    if (path != null) {
      Directory(path!).deleteIgnoreError(recursive: true);
    }
    path = null;
    // Drop the partial archive + its resume status so a cancelled task leaves
    // nothing behind. (Pause/app-kill keep them so the download can resume.)
    File(_archiveTempPath).deleteIgnoreError();
    File("$_archiveTempPath.download").deleteIgnoreError();
    LocalManager().removeTask(this);
  }

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  String? get cover => comic.cover;

  @override
  String get id => comic.id;

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  String get message => _message;

  int _currentBytes = 0;

  int _expectedBytes = 0;

  int _speed = 0;

  @override
  void pause() {
    _isRunning = false;
    _message = "Paused".tl;
    _downloader?.stop();
    notifyListeners();
    LocalManager().saveCurrentDownloadingTasks();
  }

  @override
  double get progress =>
      _expectedBytes == 0 ? 0 : _currentBytes / _expectedBytes;

  @override
  Duration? get eta {
    if (isPaused || isError || _speed <= 0 || _expectedBytes <= 0) return null;
    final remaining = _expectedBytes - _currentBytes;
    if (remaining <= 0) return null;
    return Duration(seconds: (remaining / _speed).ceil());
  }

  @override
  void resume() async {
    if (_isRunning) {
      return;
    }
    _isError = false;
    _isRunning = true;
    notifyListeners();
    _message = "Downloading...".tl;
    LocalManager().saveCurrentDownloadingTasks();

    if (path == null) {
      var dir = await LocalManager().findValidDirectory(
        comic.id,
        comicType,
        comic.title,
      );
      if (!(await dir.exists())) {
        try {
          await dir.create();
        } catch (e) {
          _setError("Error: $e");
          return;
        }
      }
      path = dir.path;
    }

    var archiveFile = File(_archiveTempPath);

    Log.info("Download", "Downloading $archiveUrl");

    _downloader = FileDownloader(archiveUrl, archiveFile.path);

    bool isDownloaded = false;

    try {
      await for (var status in _downloader!.start()) {
        _currentBytes = status.downloadedBytes;
        _expectedBytes = status.totalBytes;
        _message =
            "${bytesToReadableString(_currentBytes)}/${bytesToReadableString(_expectedBytes)}";
        _speed = status.bytesPerSecond;
        isDownloaded = status.isFinished;
        notifyListeners();
      }
    } catch (e) {
      _setError("Error: $e");
      return;
    }

    if (!_isRunning) {
      return;
    }

    if (!isDownloaded) {
      _setError("Error: Download failed");
      return;
    }

    try {
      await _extractArchive(archiveFile.path, path!);
    } catch (e) {
      _setError("Failed to extract archive: $e");
      return;
    }

    await archiveFile.deleteIgnoreError();

    LocalManager().completeTask(this);
  }

  static Future<void> _extractArchive(String archive, String outDir) async {
    var out = Directory(outDir);
    if (out is AndroidDirectory) {
      // Saf directory can't be accessed by native code.
      var cacheDir = FilePath.join(App.cachePath, "archive_downloading");
      Directory(cacheDir).forceCreateSync();
      await Isolate.run(() {
        extractZip(archive, cacheDir);
      });
      await copyDirectoryIsolate(Directory(cacheDir), Directory(outDir));
      await Directory(cacheDir).deleteIgnoreError(recursive: true);
    } else {
      await Isolate.run(() {
        extractZip(archive, outDir);
      });
    }
  }

  @override
  int get speed => _speed;

  @override
  String get title => comic.title;

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ArchiveDownloadTask",
      "archiveUrl": archiveUrl,
      "comic": comic.toJson(),
      "path": path,
      "wasRunning": _isRunning,
      "userPaused": userPaused,
    };
  }

  static ArchiveDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ArchiveDownloadTask") {
      return null;
    }
    return ArchiveDownloadTask(
        json["archiveUrl"],
        ComicDetails.fromJson(json["comic"]),
      )
      ..path = json["path"]
      ..wasRunning = json["wasRunning"] ?? false
      ..userPaused = json["userPaused"] ?? false;
  }

  String _findCover() {
    var files = Directory(path!).listSync();
    for (var f in files) {
      if (f.name.startsWith('cover')) {
        return f.name;
      }
    }
    // An empty archive (or one that extracted nothing) would crash on
    // `files.first`; return no cover instead (B14).
    if (files.isEmpty) {
      return '';
    }
    files.sort((a, b) {
      return a.name.compareTo(b.name);
    });
    return files.first.name;
  }

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic.id,
      title: title,
      subtitle: comic.subTitle ?? '',
      tags: comic.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: null,
      cover: _findCover(),
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: [],
      createdAt: DateTime.now(),
    );
  }
}
