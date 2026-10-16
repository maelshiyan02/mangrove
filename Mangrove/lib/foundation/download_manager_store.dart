// 下载管理（主页「下载管理」分区）的数据层：三个互不依赖的部件。
//
// 1. [classifyDownloadTask] —— 把队列里的一只任务归入四个队列之一
//    （当前 / 过往 / 问题 / 待命）。纯函数，可 headless 测。
// 2. [DownloadHistoryStore] —— 「过往任务」的数据源。下载队列完成任务后
//    `LocalManager.completeTask` 会往这里记一条；修复任务收尾时也记。
//    持久化在 `App.dataPath/download_history.json`。
// 3. [DownloadProblemScanner] —— 「问题任务」的自动检测（用户需求 #8）：
//    扫全库素材漫画的 `missing_pages.json`；深扫模式逐本跑
//    `LocalManager.reconcileDiskState`，把"半截章节 + 磁盘空洞"补记进表，
//    让没打开过详情页的漫画也能被归类进问题队列。
//
// 边界：本文件不做任何 UI 字符串（`.tl` 字面量留在 dart UI 文件里），
// 也不直接改队列（暂停/继续仍走 LocalManager）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ChangeNotifier, kDebugMode;

import 'app.dart';
import 'appdata.dart';
import 'comic_card_kind.dart';
import 'comic_type.dart';
import 'local.dart';
import 'log.dart';
import 'missing_pages.dart';
import 'package:mangrove/network/download.dart' show DownloadTask;
import 'package:mangrove/utils/io.dart' show FilePath;

/// 一只队列里的任务属于四个队列中的哪一个。
enum DownloadTaskBucket {
  /// 正在下载（运行中，或下到一半被暂停的活任务）。
  current,

  /// 下载完成的历史记录（数据来自 [DownloadHistoryStore]，不在任务队列里）。
  past,

  /// 出了问题的：下载报错的任务 + 检测出缺页的漫画。
  problem,

  /// 排队待命：从未开始下载的任务（含用户手动暂停的未启动任务）。
  standby,
}

/// 四队列归类（纯函数）。
///
/// 判据顺序有意为之：
/// * 报错 → 问题（无论下到多少）；
/// * 在跑 → 当前；
/// * 暂停但已有进度 → 当前（下到一半被暂停的活任务，继续/暂停语义与在跑一致）；
/// * 其余（从未启动）→ 待命。
///
/// 🔴 不要用 `userPaused` 区分当前/待命：用户把一只下到一半的任务手动暂停，
/// 它仍然是"当前任务"里的一只（有进度、可继续），不是待命。
DownloadTaskBucket classifyDownloadTask(DownloadTask task) {
  if (task.isError) return DownloadTaskBucket.problem;
  if (!task.isPaused) return DownloadTaskBucket.current;
  if (task.progress > 0) return DownloadTaskBucket.current;
  return DownloadTaskBucket.standby;
}

/// 一条「过往任务」记录。
class DownloadHistoryEntry {
  /// 漫画 id（可用于点开详情页）。
  final String comicId;

  /// 漫画来源类型（`ComicType.value`）。
  final int comicTypeValue;

  final String title;

  /// 封面（url 或相对路径，原样转存自任务）。
  final String? cover;

  /// 来源 key（UI 端用 `ComicSource.find` 取显示名）。
  final String sourceKey;

  /// 记录时间。
  final DateTime time;

  /// `'download'` = 整本/整批下载完成；`'repair'` = 缺页修复收尾。
  final String kind;

  /// 下载完成时：本地登记的章节数；修复时为 null。
  final int? chapters;

  /// 修复收尾时：补回的页数 / 仍缺的页数；下载记录为 null。
  final int? repaired;
  final int? failed;

  const DownloadHistoryEntry({
    required this.comicId,
    required this.comicTypeValue,
    required this.title,
    required this.time,
    required this.kind,
    this.cover,
    this.sourceKey = '',
    this.chapters,
    this.repaired,
    this.failed,
  });

  Map<String, dynamic> toJson() => {
    'id': comicId,
    'comicType': comicTypeValue,
    'title': title,
    if (cover != null) 'cover': cover,
    if (sourceKey.isNotEmpty) 'sourceKey': sourceKey,
    'time': time.toIso8601String(),
    'kind': kind,
    if (chapters != null) 'chapters': chapters,
    if (repaired != null) 'repaired': repaired,
    if (failed != null) 'failed': failed,
  };

  static DownloadHistoryEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final id = json['id'];
    final title = json['title'];
    final time = json['time'] is String ? DateTime.tryParse(json['time']) : null;
    if (id is! String || title is! String || time == null) return null;
    final kind = json['kind'];
    int? intOf(Object? v) => v is int ? v : null;
    return DownloadHistoryEntry(
      comicId: id,
      comicTypeValue: intOf(json['comicType']) ?? ComicType.local.value,
      title: title,
      cover: json['cover'] is String ? json['cover'] as String : null,
      sourceKey: json['sourceKey'] is String ? json['sourceKey'] as String : '',
      time: time,
      kind: kind == 'repair' ? 'repair' : 'download',
      chapters: intOf(json['chapters']),
      repaired: intOf(json['repaired']),
      failed: intOf(json['failed']),
    );
  }
}

/// 「过往任务」持久化存储。
///
/// 写入是 fire-and-forget：记录路径跑在下载完成的关键路径上，绝不能因
/// 磁盘慢把它阻塞。读取惰性（第一次访问时加载）。
class DownloadHistoryStore extends ChangeNotifier {
  DownloadHistoryStore._();

  static final DownloadHistoryStore instance = DownloadHistoryStore._();

  static const _maxEntries = 300;

  String get _filePath => FilePath.join(App.dataPath, 'download_history.json');

  List<DownloadHistoryEntry>? _cache;

  bool _saving = false;
  bool _saveAgain = false;

  /// 最新在前；只读副本。
  List<DownloadHistoryEntry> get entries {
    _cache ??= _load();
    return List.unmodifiable(_cache!);
  }

  int get count => entries.length;

  List<DownloadHistoryEntry> _load() {
    try {
      final file = File(_filePath);
      if (!file.existsSync()) return <DownloadHistoryEntry>[];
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) return <DownloadHistoryEntry>[];
      return [
        for (final item in decoded)
          if (DownloadHistoryEntry.fromJson(item) != null)
            DownloadHistoryEntry.fromJson(item)!,
      ];
    } catch (e, s) {
      Log.error('DownloadHistory', 'Failed to load history: $e', s);
      return <DownloadHistoryEntry>[];
    }
  }

  /// 记一条完成事件（最新在前，超出上限裁掉最旧的）。
  void record(DownloadHistoryEntry entry) {
    _cache ??= _load();
    _cache!.insert(0, entry);
    if (_cache!.length > _maxEntries) {
      _cache!.removeRange(_maxEntries, _cache!.length);
    }
    notifyListeners();
    _scheduleSave();
  }

  /// 清空历史（UI 的"清空过往记录"入口）。
  void clear() {
    _cache ??= _load();
    if (_cache!.isEmpty) return;
    _cache!.clear();
    notifyListeners();
    _scheduleSave();
  }

  void _scheduleSave() {
    if (_saving) {
      _saveAgain = true;
      return;
    }
    _saving = true;
    () async {
      do {
        _saveAgain = false;
        try {
          final file = File(_filePath);
          final tmp = File('$_filePath.tmp');
          await tmp.writeAsString(
            jsonEncode(_cache!.map((e) => e.toJson()).toList()),
            flush: true,
          );
          try {
            final dest = File(_filePath);
            if (dest.existsSync()) dest.deleteSync();
            await tmp.rename(_filePath);
          } catch (_) {
            await file.writeAsString(
              jsonEncode(_cache!.map((e) => e.toJson()).toList()),
              flush: true,
            );
            try {
              tmp.deleteSync();
            } catch (_) {}
          }
        } catch (e, s) {
          Log.error('DownloadHistory', 'Failed to save history: $e', s);
        }
      } while (_saveAgain);
      _saving = false;
    }();
  }
}

/// 一本检测出缺页的漫画及其缺页表快照。
class ComicMissingReport {
  final LocalComic comic;
  final MissingPagesTable table;

  const ComicMissingReport({required this.comic, required this.table});

  String get comicId => comic.id;

  /// 有缺页的章节数。
  int get chapterCount => table.chapterIds.length;

  /// 缺页总数。
  int get pageCount => table.count;
}

/// 「问题任务」的自动检测器。
///
/// * [quickScan]：只读每本素材漫画的 `missing_pages.json`（毫秒级/本），
///   打开问题队列时自动跑，保证表里已登记的缺页立刻可见。
/// * [deepScan]：逐本跑 `LocalManager.reconcileDiskState`（磁盘对账），
///   把"半截章节目录 + 磁盘空洞"补记进表 —— 这是用户"关软件导致大量章节
///   缺页却查不出来"那个场景的正解。带进度通知，供统计弹窗显示。
///
/// 两者都会跳过：工程/成品派生卡、本地导入（页命名不保证 0-based，
/// 误判率不可接受）、正在下载中的漫画。
class DownloadProblemScanner extends ChangeNotifier {
  DownloadProblemScanner._();

  static final DownloadProblemScanner instance = DownloadProblemScanner._();

  /// 快扫结果（最新一次扫描的快照，按缺页数降序）。
  List<ComicMissingReport> reports = const [];

  bool _scanning = false;
  bool get scanning => _scanning;

  bool _cancelRequested = false;

  /// 深扫进度：已完成本数 / 总本数（快扫时二者都为 0）。
  int scannedCount = 0;
  int totalCount = 0;

  /// 扫到的候选素材（含"没有缺页"的），测试与进度条用。
  int candidateCount = 0;

  List<LocalComic> _candidates() {
    final manager = LocalManager();
    if (!manager.isInitialized) return const [];
    return manager
        .getComics(LocalSortType.defaultSort)
        .where((c) => !isDerivedComicCard(c.id))
        .where((c) => c.comicType != ComicType.local)
        .where((c) => !manager.isDownloading(c.id, c.comicType))
        .toList();
  }

  /// 只读已登记的缺页表。返回本轮发现的问题漫画数。
  Future<int> quickScan() async {
    if (_scanning) return reports.length;
    _scanning = true;
    scannedCount = 0;
    totalCount = 0;
    notifyListeners();
    try {
      final found = <ComicMissingReport>[];
      for (final comic in _candidates()) {
        candidateCount++;
        final table = MissingPages.peek(comic.baseDir);
        if (table != null && !table.isEmpty) {
          found.add(ComicMissingReport(comic: comic, table: table));
        }
      }
      found.sort((a, b) => b.pageCount.compareTo(a.pageCount));
      reports = found;
      return found.length;
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }

  /// 磁盘深扫：逐本对账后重读缺页表。可被 [_cancelRequested] 中断。
  Future<int> deepScan() async {
    if (_scanning) return reports.length;
    _scanning = true;
    _cancelRequested = false;
    notifyListeners();
    try {
      final candidates = _candidates();
      candidateCount = candidates.length;
      totalCount = candidates.length;
      scannedCount = 0;
      final manager = LocalManager();
      final found = <ComicMissingReport>[];
      for (final comic in candidates) {
        if (_cancelRequested) break;
        try {
          // 对账内部自带守卫（本地导入 / 下载中跳过）；这里再防御一次
          // 单本失败不影响整轮。
          await manager.reconcileDiskState(comic);
        } catch (e, s) {
          Log.error(
            'DownloadProblemScanner',
            'Reconcile failed for "${comic.title}": $e',
            s,
          );
        }
        scannedCount++;
        final table = MissingPages.peek(comic.baseDir);
        if (table != null && !table.isEmpty) {
          found.add(ComicMissingReport(comic: comic, table: table));
        }
        notifyListeners();
      }
      found.sort((a, b) => b.pageCount.compareTo(a.pageCount));
      reports = found;
      return found.length;
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }

  /// 用户手动请求中断深扫。
  void cancelScan() {
    if (_scanning) _cancelRequested = true;
  }

  /// 单本漫画的缺页表发生变化（修复完成等）后刷新快照：
  /// 有缺页 → 替换/插入该本；没缺页 → 从快照里移除。
  void refreshComic(LocalComic comic) {
    final table = MissingPages.peek(comic.baseDir);
    final next = <ComicMissingReport>[
      for (final r in reports)
        if (!(r.comicId == comic.id && r.comic.comicType == comic.comicType)) r,
    ];
    if (table != null && !table.isEmpty) {
      next.add(ComicMissingReport(comic: comic, table: table));
    }
    next.sort((a, b) => b.pageCount.compareTo(a.pageCount));
    reports = next;
    notifyListeners();
  }

  /// 丢弃缓存（测试隔离用）。
  void resetForTest() {
    if (kDebugMode) {
      reports = const [];
      scannedCount = 0;
      totalCount = 0;
      candidateCount = 0;
    }
  }
}

/// 自动缺页修复开关（用户 2026-10-16；默认关）。
///
/// 开启后，下载任务完成时若该漫画被问题队列检出缺页，自动按章生成
/// 修复任务入队（`RepairDownloadTask.enqueue` 同一套分组逻辑），无需
/// 用户再手动逐章勾选。系统设置「下载管理」与缺页修复弹窗标题右侧
/// 的模式下拉都读写这一个键。
bool get autoRepairMissingPages =>
    appdata.settings['autoRepairMissingPages'] == true;

void setAutoRepairMissingPages(bool value) {
  appdata.settings['autoRepairMissingPages'] = value;
  appdata.saveData();
}

/// 漫画信息采集/章节更新 自动模式总开关（默认关，2026-10-16）。
///
/// 开启后，打开漫画时按来源判定模式：本地库打开=本地模式只读本地、
/// 搜索/收藏网络打开=网络模式及时更新。系统设置「漫画管理」与漫画详情页
/// 模式下拉都读写这一个键。
bool get comicInfoAutoUpdate =>
    appdata.settings['comicInfoAutoUpdate'] == true;

void setComicInfoAutoUpdate(bool value) {
  appdata.settings['comicInfoAutoUpdate'] = value;
  appdata.saveData();
}
