import 'dart:convert';
import 'dart:io';

import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';

/// One page that could not be downloaded and is therefore absent from the
/// chapter directory on disk.
///
/// The entry keeps everything a later repair run needs: where the file should
/// have gone ([chapterId] / [index]) and the original [url] to fetch it again.
class MissingPageEntry {
  /// Name of the chapter directory (the VeneraX cid). Empty for comics that
  /// have no chapters (all pages live directly in the comic root).
  final String chapterId;

  /// Human readable chapter title. Display only, never used as a key.
  final String chapterTitle;

  /// Page index. The page file is named `{index}.{ext}`.
  final int index;

  /// Source url of the page, so a repair run can fetch exactly this one.
  final String url;

  /// Last error message.
  String error;

  /// Total attempts across every run (a repair that also fails adds to it).
  int attempts;

  DateTime? firstFailedAt;

  DateTime? lastFailedAt;

  MissingPageEntry({
    required this.chapterId,
    required this.chapterTitle,
    required this.index,
    required this.url,
    required this.error,
    this.attempts = 1,
    DateTime? firstFailedAt,
    DateTime? lastFailedAt,
  }) : firstFailedAt = firstFailedAt ?? DateTime.now(),
       lastFailedAt = lastFailedAt ?? DateTime.now();

  /// Stable identity of a page inside one comic.
  String get key => "$chapterId#$index";

  Map<String, dynamic> toJson() => {
    "chapterId": chapterId,
    "chapterTitle": chapterTitle,
    "index": index,
    "url": url,
    "error": error,
    "attempts": attempts,
    "firstFailedAt": firstFailedAt?.toIso8601String(),
    "lastFailedAt": lastFailedAt?.toIso8601String(),
  };

  static MissingPageEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final index = json["index"];
    if (index is! int) return null;
    DateTime? date(Object? v) => v is String ? DateTime.tryParse(v) : null;
    return MissingPageEntry(
      chapterId: (json["chapterId"] ?? "").toString(),
      chapterTitle: (json["chapterTitle"] ?? "").toString(),
      index: index,
      url: (json["url"] ?? "").toString(),
      error: (json["error"] ?? "unknown").toString(),
      attempts: json["attempts"] is int ? json["attempts"] as int : 1,
      firstFailedAt: date(json["firstFailedAt"]),
      lastFailedAt: date(json["lastFailedAt"]),
    );
  }
}

/// 给定页文件里**实际存在**的下标集合，返回缺席的下标（升序）。
///
/// 判据只依赖磁盘，不需要联网、也不需要知道"期望页数"：VeneraX 自己的下载器
/// 恒定按 `0..n-1` 命名页文件（`_ImageDownloadWrapper(index: i)` →
/// `"$index$ext"`），所以 `{0..max}` 中任何缺席的下标都必然是真实缺页。
///
/// ⚠️ 只对**网络下载**的漫画成立。本地导入的目录可能 1-based、可能自定义
/// 命名，所以调用方（`LocalManager.reconcileMissingPages`）必须先按
/// `comicType != ComicType.local` 过滤，否则会把整章的起始偏移误判成缺页。
///
/// ⚠️ 只能发现"内部与头部空洞"。**尾部截断**（最后几页没下完且目录里也没有
/// 更大的下标）无法离线判定 —— 期望页数没有落盘，需要联网取章节页列表。
List<int> pageIndexGaps(Iterable<int> presentIndexes, {int? expectedCount}) {
  final present =
      presentIndexes is Set<int> ? presentIndexes : presentIndexes.toSet();
  if (present.isEmpty) return const [];
  var max = 0;
  for (final v in present) {
    if (v > max) max = v;
  }
  final upper =
      expectedCount != null && expectedCount - 1 > max ? expectedCount - 1 : max;
  final gaps = <int>[];
  for (var i = 0; i <= upper; i++) {
    if (!present.contains(i)) gaps.add(i);
  }
  return gaps;
}

/// The per-comic table persisted as `missing_pages.json` in the comic root.
class MissingPagesTable {
  /// Source key of the comic. Empty for a table that was just created and has
  /// not been written yet.
  String sourceKey;

  /// Comic id in the source. Empty for a freshly created table.
  String comicId;

  final List<MissingPageEntry> entries;

  MissingPagesTable({
    required this.sourceKey,
    required this.comicId,
    List<MissingPageEntry>? entries,
  }) : entries = entries ?? <MissingPageEntry>[];

  bool get isEmpty => entries.isEmpty;

  int get count => entries.length;

  MissingPageEntry? find(String chapterId, int index) {
    for (final e in entries) {
      if (e.chapterId == chapterId && e.index == index) return e;
    }
    return null;
  }

  /// Insert or merge an entry. A page that fails again during a repair run
  /// keeps its original [MissingPageEntry.firstFailedAt] and accumulates
  /// attempts, so repeated failures stay visible instead of being rewritten.
  void upsert(MissingPageEntry entry) {
    final existing = find(entry.chapterId, entry.index);
    if (existing == null) {
      entries.add(entry);
      return;
    }
    existing.attempts += entry.attempts;
    existing.error = entry.error;
    existing.lastFailedAt = entry.lastFailedAt ?? DateTime.now();
    existing.firstFailedAt ??= entry.firstFailedAt;
  }

  void remove(String chapterId, int index) {
    entries.removeWhere((e) => e.chapterId == chapterId && e.index == index);
  }

  int countOfChapter(String chapterId) {
    return entries.where((e) => e.chapterId == chapterId).length;
  }

  Set<int> indexesOfChapter(String chapterId) {
    return {
      for (final e in entries)
        if (e.chapterId == chapterId) e.index,
    };
  }

  Set<String> get chapterIds => {for (final e in entries) e.chapterId};

  /// 章节目录改名后同步 [MissingPageEntry.chapterId]（S7U/U3-4 迁移用）。
  ///
  /// 该字段存的是**目录名**，目录一改名条目就指向一个不存在的目录，红色
  /// "缺页"标记会静默消失。返回是否真的改写了。
  bool remapChapterIds(Map<String, String> remap) {
    if (remap.isEmpty || entries.isEmpty) return false;
    final rebuilt = <MissingPageEntry>[];
    var touched = false;
    for (final e in entries) {
      final next = remap[e.chapterId];
      if (next == null) {
        rebuilt.add(e);
        continue;
      }
      rebuilt.add(
        MissingPageEntry(
          chapterId: next,
          chapterTitle: e.chapterTitle,
          index: e.index,
          url: e.url,
          error: e.error,
          attempts: e.attempts,
          firstFailedAt: e.firstFailedAt,
          lastFailedAt: e.lastFailedAt,
        ),
      );
      touched = true;
    }
    if (!touched) return false;
    entries
      ..clear()
      ..addAll(rebuilt);
    return true;
  }

  Map<String, dynamic> toJson() => {
    "version": 1,
    "source": sourceKey,
    "comicId": comicId,
    "updatedAt": DateTime.now().toIso8601String(),
    "entries": entries.map((e) => e.toJson()).toList(),
  };

  static MissingPagesTable fromJson(Map<String, dynamic> json) {
    final raw = json["entries"];
    final entries = <MissingPageEntry>[];
    if (raw is List) {
      for (final item in raw) {
        final entry = MissingPageEntry.fromJson(item);
        if (entry == null) continue;
        // Defensive: a duplicated (chapterId, index) pair would make the
        // repair loop fetch the same page twice.
        entries.removeWhere(
          (e) => e.chapterId == entry.chapterId && e.index == entry.index,
        );
        entries.add(entry);
      }
    }
    return MissingPagesTable(
      sourceKey: (json["source"] ?? "").toString(),
      comicId: (json["comicId"] ?? "").toString(),
      entries: entries,
    );
  }
}

/// Read/write access to `missing_pages.json`, one table per comic directory.
///
/// Location is the comic root (plan option A): every missing page of a comic is
/// visible in one file, and the file travels with the comic directory, so it
/// survives moves/renames done outside the app (as long as the whole folder is
/// moved).
class MissingPages {
  MissingPages._();

  static const String fileName = "missing_pages.json";

  /// In-memory mirror of what is on disk. `null` means "known to have no
  /// missing pages", a missing key means "not loaded yet".
  static final Map<String, MissingPagesTable?> _cache = {};

  /// Serializes writes so two tasks (or a task and a repair run) can't clobber
  /// each other's file content.
  static Future<void> _lock = Future.value();

  static File fileOf(String comicDirectory) =>
      File(FilePath.join(comicDirectory, fileName));

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {}
  }

  /// Synchronous read with a cache, safe to call from UI code (S3 badges).
  /// Returns null when there is no table or the file is unusable.
  static MissingPagesTable? peek(String comicDirectory) {
    if (comicDirectory.isEmpty) return null;
    if (_cache.containsKey(comicDirectory)) return _cache[comicDirectory];
    final file = fileOf(comicDirectory);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException("root is not an object");
      }
      final table = MissingPagesTable.fromJson(decoded);
      if (table.isEmpty) {
        // Leftover empty table: drop it so "nothing missing" leaves no noise.
        _deleteQuietly(file);
        _cache[comicDirectory] = null;
        return null;
      }
      _cache[comicDirectory] = table;
      return table;
    } catch (e, s) {
      Log.error("MissingPages", "Corrupted table at $comicDirectory: $e", s);
      // Keep the broken file instead of overwriting it: the entries may still
      // be recoverable by hand.
      try {
        file.renameSync(
          "${file.path}.corrupted-${DateTime.now().millisecondsSinceEpoch}",
        );
      } catch (_) {}
      _cache[comicDirectory] = null;
      return null;
    }
  }

  static Future<MissingPagesTable> load(String comicDirectory) async {
    return peek(comicDirectory) ??
        MissingPagesTable(sourceKey: "", comicId: "");
  }

  static bool hasMissing(String comicDirectory) =>
      peek(comicDirectory)?.isEmpty == false;

  static int missingCount(String comicDirectory) =>
      peek(comicDirectory)?.count ?? 0;

  /// Persist [table]. An empty table deletes the file so a healthy comic has no
  /// leftover bookkeeping.
  static Future<void> save(String comicDirectory, MissingPagesTable table) {
    final op = _lock.then((_) => _write(comicDirectory, table));
    _lock = op.catchError((Object _) {});
    return op;
  }

  static void _write(String comicDirectory, MissingPagesTable table) {
    if (comicDirectory.isEmpty) return;
    _cache[comicDirectory] = table.isEmpty ? null : table;
    final file = fileOf(comicDirectory);
    try {
      if (table.isEmpty) {
        if (file.existsSync()) {
          file.deleteSync();
        }
        return;
      }
      final dir = Directory(comicDirectory);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      file.writeAsStringSync(jsonEncode(table.toJson()));
    } catch (e, s) {
      Log.error("MissingPages", "Failed to write table: $e", s);
    }
  }

  /// Drop the cache entry for a directory (after the comic was deleted/moved).
  static void invalidate(String comicDirectory) {
    _cache.remove(comicDirectory);
  }

  /// Mark one page as recovered. No-op when the comic has no table.
  static Future<void> removeEntry(
    String comicDirectory,
    String chapterId,
    int index,
  ) async {
    final table = peek(comicDirectory);
    if (table == null) return;
    table.remove(chapterId, index);
    await save(comicDirectory, table);
  }

  /// 磁盘校验：把一章的**真实**缺页状态同步进表里（新增空洞 / 清掉已补回的）。
  ///
  /// 🔴 为什么需要它：`missing_pages.json` 曾是"缺页"的**唯一**真相，而它只在
  /// 下载任务的**末轮**才落盘（`ImagesDownloadTask._roundTimeouts` 的第 4 轮，
  /// 见 download.dart 的 `recordMissing`）。任何在末轮之前被暂停 / 取消 / 崩溃
  /// 的运行，整章的失败页会**凭空消失**——既不落盘也不显示红色标记，UI 于是把
  /// 一本残缺的章节显示成"已下载完成"，修复入口也列不出这些页。
  ///
  /// 实测（2026-10-06）：`My Dragon Girlfriend Has Returned / 6 [DivaScans]`
  /// 源侧 177 页（日志 `pages: 177 images from API payload`），磁盘只有 145 个
  /// 文件、32 个空洞（33/41/47/…/141 + 146/150/153/155/157…/175），而表里
  /// **只有 index 5 一条** —— 因为文件分三个批次写入（20:17/20:25/20:34），
  /// 每次都在末轮之前被截断。用户点击一次"修复"只补回了 index 5，其余 31 个
  /// 空洞依然既不报错也不可见。
  ///
  /// [presentIndexes] 是该章目录里实际存在的页下标。返回被改写的条目数。
  static Future<int> reconcileChapter(
    String comicDirectory, {
    required String chapterId,
    required String chapterTitle,
    required Set<int> presentIndexes,
    String sourceKey = '',
    String comicId = '',
    String error = 'page file absent on disk',
  }) async {
    if (comicDirectory.isEmpty || presentIndexes.isEmpty) return 0;
    final table = await load(comicDirectory);
    var changed = 0;
    // 1) 已经补回来的页：清掉陈旧条目，否则修完之后红色标记永不消失。
    final stale = [
      for (final e in table.entries)
        if (e.chapterId == chapterId && presentIndexes.contains(e.index)) e,
    ];
    for (final e in stale) {
      table.remove(chapterId, e.index);
      changed++;
    }
    // 2) 磁盘上的空洞：补记。已有条目一律保留 —— 它可能带着可用的 url 与更
    //    准确的错误信息，磁盘探测只知道"文件不在"。
    for (final index in pageIndexGaps(presentIndexes)) {
      if (table.find(chapterId, index) != null) continue;
      table.upsert(
        MissingPageEntry(
          chapterId: chapterId,
          chapterTitle: chapterTitle,
          index: index,
          url: '',
          error: error,
          attempts: 0,
        ),
      );
      changed++;
    }
    if (changed == 0) return 0;
    if (table.sourceKey.isEmpty) table.sourceKey = sourceKey;
    if (table.comicId.isEmpty) table.comicId = comicId;
    await save(comicDirectory, table);
    return changed;
  }

  /// Update an existing entry's error/attempts — used by a repair run that
  /// fails again so repeated failures stay recorded with an accurate attempt
  /// count (P5-S4). No-op when there is no table; if the entry is unknown it is
  /// inserted.
  static Future<void> putEntry(
    String comicDirectory,
    MissingPageEntry entry,
  ) async {
    final table = peek(comicDirectory);
    if (table == null) {
      final created = MissingPagesTable(sourceKey: "", comicId: "");
      created.upsert(entry);
      await save(comicDirectory, created);
      return;
    }
    final existing = table.find(entry.chapterId, entry.index);
    if (existing == null) {
      table.upsert(entry);
    } else {
      existing.attempts = entry.attempts;
      existing.error = entry.error;
      existing.lastFailedAt = DateTime.now();
    }
    await save(comicDirectory, table);
  }
}
