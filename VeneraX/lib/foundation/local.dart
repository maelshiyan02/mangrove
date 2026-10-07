import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/chapter_directory.dart';
import 'package:venera/foundation/chapter_title_parser.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/download_keepalive.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/missing_pages.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

import 'app.dart';

/// UI-facing guard for the four download entry points. Ensures the download
/// directory is writable, prompting for storage permission on Android when it
/// isn't (#89). Shows a message and returns false when downloads must not
/// proceed, so callers can simply `if (!await ensureDownloadStorageWritable())
/// return;`. Always true off Android.
Future<bool> ensureDownloadStorageWritable() async {
  if (await LocalManager().ensureDownloadWritable()) {
    return true;
  }
  App.rootContext.showMessage(
    message: "Storage permission is required to download comics".tl,
  );
  return false;
}

class LocalComic with HistoryMixin implements Comic {
  @override
  final String id;

  @override
  final String title;

  @override
  final String subtitle;

  @override
  final List<String> tags;

  /// The name of the directory where the comic is stored
  final String directory;

  /// key: chapter id, value: chapter title
  ///
  /// chapter id is the name of the directory in `LocalManager.path/$directory`
  final ComicChapters? chapters;

  bool get hasChapters => chapters != null;

  /// 阅读/展示用的 chapters：把每话**已下载**的版本提到首位。
  ///
  /// 一维投影（[ComicChapters.ids] 等只取首个版本）因此落在有内容的版本上 ——
  /// 否则"下载了非首选组"的章节在库里显示为未下载、点开是空白页。
  /// 库里的 [chapters] 本身保持源顺序不动。
  ComicChapters? get effectiveChapters =>
      chapters?.preferDownloaded(downloadedChapters.toSet());

  /// relative path to the cover image
  @override
  final String cover;

  final ComicType comicType;

  final List<String> downloadedChapters;

  final DateTime createdAt;

  @override
  final String description;

  const LocalComic({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.directory,
    required this.chapters,
    required this.cover,
    required this.comicType,
    required this.downloadedChapters,
    required this.createdAt,
    this.description = "",
  });

  LocalComic.fromRow(Row row)
    : id = row['id'] as String,
      title = row['title'] as String,
      subtitle = row['subtitle'] as String,
      tags = List.from(jsonDecode(row['tags'] as String)),
      directory = row['directory'] as String,
      chapters =
          ComicChapters.fromJsonOrNull(jsonDecode(row['chapters'] as String)),
      cover = row['cover'] as String,
      comicType = ComicType(row['comic_type'] as int),
      downloadedChapters =
          List.from(jsonDecode(row['downloadedChapters'] as String)),
      createdAt = DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      description = (row['description'] as String?) ?? "";

  File get coverFile => File(FilePath.join(baseDir, cover));

  String get baseDir => (directory.contains('/') || directory.contains('\\'))
      ? directory
      : FilePath.join(LocalManager().path, directory);

  LocalComicStatus get status {
    if (LocalManager().isDownloading(id, comicType)) {
      return LocalComicStatus.downloading;
    }
    final dir = Directory(baseDir);
    if (!dir.existsSync()) return LocalComicStatus.notDownloaded;
    try {
      final contents = dir.listSync();
      if (contents.isEmpty) return LocalComicStatus.notDownloaded;
      final hasContent = contents.any((e) =>
          e is File || (e is Directory && e.listSync().isNotEmpty));
      return hasContent
          ? LocalComicStatus.downloaded
          : LocalComicStatus.notDownloaded;
    } catch (_) {
      return LocalComicStatus.notDownloaded;
    }
  }

  @override
  String get sourceKey => comicType.sourceKey;

  @override
  Map<String, dynamic> toJson() {
    return {
      "title": title,
      "cover": cover,
      "id": id,
      "subTitle": subtitle,
      "tags": tags,
      "description": description,
      "sourceKey": sourceKey,
      "chapters": chapters?.toJson(),
    };
  }

  @override
  int? get maxPage => null;

  void read() {
    var history = HistoryManager().find(id, comicType);
    // Local ids are reused after deletion, so a surviving history row may
    // still carry the previous comic's title/cover (issue #135). Refresh the
    // display fields from the comic itself before the reader persists it.
    if (history != null) {
      history.title = title;
      history.subtitle = subtitle;
      history.cover = cover;
    }
    int? firstDownloadedChapter;
    int? firstDownloadedChapterGroup;
    final chapters = effectiveChapters;
    if (downloadedChapters.isNotEmpty && chapters != null) {
      if (chapters.isGrouped) {
        for (int i = 0; i < chapters.groupCount; i++) {
          var group = chapters.getGroupByIndex(i);
          var keys = group.keys.toList();
          for (int j = 0; j < keys.length; j++) {
            var chapterId = keys[j];
            if (downloadedChapters.contains(chapterId)) {
              firstDownloadedChapter = j + 1;
              firstDownloadedChapterGroup = i + 1;
              break;
            }
          }
        }
      } else {
        var keys = chapters.allChapters.keys;
        for (int i = 0; i < keys.length; i++) {
          if (downloadedChapters.contains(keys.elementAt(i))) {
            firstDownloadedChapter = i + 1;
            break;
          }
        }
      }
    }
    App.rootContext.to(
      () => Reader(
        type: comicType,
        cid: id,
        name: title,
        chapters: chapters,
        initialChapter: history?.ep ?? firstDownloadedChapter,
        initialPage: history?.page,
        initialChapterGroup: history?.group ?? firstDownloadedChapterGroup,
        history: history ?? History.fromModel(model: this, ep: 0, page: 0),
        author: subtitle,
        tags: tags,
      ),
    );
  }

  @override
  HistoryType get historyType => comicType;

  @override
  String? get subTitle => subtitle;

  /// 第 [ep] 话（1-based，与 [ComicChapters.ids] 的投影顺序一致）所属的翻译组。
  ///
  /// 数据来源是 `local.db` 里原样保存的版本化 chapters，**不需要文件名标记
  /// 也不需要边车**。没有组信息时返回 null，调用方应整块省略标签而不是
  /// 渲染一个空 chip —— 本地导入的 chapters 是扁平的（`local_comic_scanner`
  /// 用目录名建 key），`bt_`/`ft_` 派生卡同样没有版本信息，这两种来源必然 null。
  ///
  /// 同一话下载了多个组时优先返回**已下载**那个版本的组，否则回落首版本。
  String? groupAt(int ep) {
    final chapters = this.chapters;
    if (chapters == null || ep < 1) return null;
    final key = chapters.ids.elementAtOrNull(ep - 1);
    if (key == null) return null;
    final entry = chapters.versionEntryOf(key);
    if (entry == null) return null;
    final versions = chapters.versionsFor(entry.chapterNumber);
    if (versions == null || versions.isEmpty) return null;
    for (final v in versions) {
      if (downloadedChapters.contains(v.chapterKey)) {
        return v.scanlationGroup;
      }
    }
    return versions.first.scanlationGroup;
  }

  @override
  String? get language => null;

  @override
  String? get favoriteId => null;

  @override
  double? get stars => null;
}

/// Keeps flat local-comic history attached to chapter IDs after a rescan.
void remapLocalComicHistory(
  History history,
  LocalComic previous,
  LocalComic refreshed,
) {
  history.title = refreshed.title;
  history.subtitle = refreshed.subtitle;
  history.cover = refreshed.cover;

  final previousIds = previous.chapters?.ids.toList() ?? const <String>[];
  final refreshedIds = refreshed.chapters?.ids.toList() ?? const <String>[];
  if (previousIds.isEmpty || history.group != null) {
    return;
  }
  if (refreshedIds.isEmpty) {
    history.ep = 0;
    history.page = 0;
    history.readEpisode = <String>{};
    return;
  }

  final previousIndex = history.ep - 1;
  if (previousIndex >= 0 && previousIndex < previousIds.length) {
    final refreshedIndex = refreshedIds.indexOf(previousIds[previousIndex]);
    history.ep = refreshedIndex >= 0
        ? refreshedIndex + 1
        : history.ep.clamp(1, refreshedIds.length).toInt();
  }

  final remappedReadEpisodes = <String>{};
  for (final value in history.readEpisode) {
    final oldPosition = int.tryParse(value);
    if (oldPosition == null ||
        oldPosition < 1 ||
        oldPosition > previousIds.length) {
      remappedReadEpisodes.add(value);
      continue;
    }
    final refreshedIndex = refreshedIds.indexOf(previousIds[oldPosition - 1]);
    if (refreshedIndex >= 0) {
      remappedReadEpisodes.add('${refreshedIndex + 1}');
    }
  }
  history.readEpisode = remappedReadEpisodes;
}

class LocalManager with ChangeNotifier {
  static LocalManager? _instance;

  LocalManager._();

  factory LocalManager() {
    return _instance ??= LocalManager._();
  }

  late Database _db;

  /// path to the directory where all the comics are stored
  late String path;

  Directory get directory => Directory(path);

  void _checkNoMedia() {
    if (App.isAndroid) {
      var file = File(FilePath.join(path, '.nomedia'));
      if (!file.existsSync()) {
        file.createSync();
      }
    }
  }

  /// Sentinel returned by [setNewPath] when the chosen directory is not empty
  /// and the caller has not opted in to merging. Callers should compare the
  /// return value against this constant (not show it as an error) to decide
  /// whether to ask the user for confirmation.
  static const dirNotEmptySignal = "__venera_dir_not_empty__";

  // return error message if failed, [dirNotEmptySignal] if the target is not
  // empty and [allowNonEmpty] is false.
  Future<String?> setNewPath(String newPath, {bool allowNonEmpty = false}) async {
    var newDir = Directory(newPath);
    if (!await newDir.exists()) {
      return "Directory does not exist";
    }
    if (!allowNonEmpty && !await newDir.list().isEmpty) {
      // Don't hard-fail: let the caller confirm merging into a non-empty
      // directory (e.g. an existing folder on an SD card). Returning a sentinel
      // keeps the "must be empty" safety while giving the user a way forward.
      return dirNotEmptySignal;
    }
    final oldDir = directory;
    try {
      await copyDirectoryIsolate(oldDir, newDir);
      // Verify the copy looks complete before destroying the source. SAF
      // targets can fail silently; deleting the source after an incomplete
      // copy would lose data. We only abort when we can positively confirm the
      // destination has fewer files than the source — if the count itself
      // throws (slow/unsupported on some SAF impls), we trust the copy.
      if (!await _verifyCopied(oldDir, newDir)) {
        return "Failed to copy all files to the new location";
      }
      await File(
        FilePath.join(App.dataPath, 'local_path'),
      ).writeAsString(newPath);
    } catch (e, s) {
      Log.error("IO", e, s);
      return e.toString();
    }
    // The data now lives at [newPath]; clearing the old directory is
    // best-effort. A failure here must not roll back the switch, so swallow it.
    try {
      await oldDir.deleteContents(recursive: true);
    } catch (e, s) {
      Log.error("IO", "Failed to clean old storage path: $e", s);
    }
    path = newPath;
    _checkNoMedia();
    return null;
  }

  /// Best-effort completeness check: returns false only when the destination is
  /// confirmed to contain fewer files than the source. Any error while counting
  /// is treated as "cannot disprove" and returns true so a valid copy is not
  /// rejected on platforms where recursive listing is unreliable.
  Future<bool> _verifyCopied(Directory source, Directory dest) async {
    try {
      int countFiles(Directory d) {
        if (!d.existsSync()) return 0;
        return d.listSync(recursive: true).whereType<File>().length;
      }

      final srcCount = countFiles(source);
      final dstCount = countFiles(dest);
      if (srcCount == 0) return true;
      return dstCount >= srcCount;
    } catch (e, s) {
      Log.error("IO", "Copy verification skipped: $e", s);
      return true;
    }
  }

  Future<String> findDefaultPath() async {
    if (App.isAndroid) {
      var external = await getExternalStorageDirectories();
      if (external != null && external.isNotEmpty) {
        return FilePath.join(external.first.path, 'local');
      } else {
        return FilePath.join(App.dataPath, 'local');
      }
    } else if (App.isIOS) {
      var oldPath = FilePath.join(App.dataPath, 'local');
      if (Directory(oldPath).existsSync() &&
          Directory(oldPath).listSync().isNotEmpty) {
        return oldPath;
      } else {
        var directory = await getApplicationDocumentsDirectory();
        return FilePath.join(directory.path, 'local');
      }
    } else {
      return FilePath.join(App.dataPath, 'local');
    }
  }

  Future<void> _checkPathValidation() async {
    var testFile = File(FilePath.join(path, 'venera_test'));
    try {
      testFile.createSync();
      testFile.deleteSync();
    } catch (e) {
      Log.error(
        "IO",
        "Failed to create test file in local path: $e\nUsing default path instead.",
      );
      path = await findDefaultPath();
    }
  }

  bool isInitialized = false;

  String get _dbPath => '${App.dataPath}/local.db';

  void close() {
    if (!isInitialized) return;
    isInitialized = false;
    DatabaseGateway.instance.closeManaged(_dbPath);
  }

  Future<void> init() async {
    _db = DatabaseGateway.instance.openManaged(_dbPath);
    _ensureSchema();
    if (File(FilePath.join(App.dataPath, 'local_path')).existsSync()) {
      path = File(FilePath.join(App.dataPath, 'local_path')).readAsStringSync();
      if (!directory.existsSync()) {
        path = await findDefaultPath();
      }
    } else {
      path = await findDefaultPath();
    }
    try {
      if (!directory.existsSync()) {
        await directory.create();
      }
    } catch (e, s) {
      Log.error("IO", "Failed to create local folder: $e", s);
    }
    _checkPathValidation();
    _checkNoMedia();
    isInitialized = true;
    // 章节目录"带组改名"迁移：必须在恢复下载任务之前跑，否则任务会拿
    // 旧目录名去补页。内部自带 try/catch 与一次性标记。
    migrateChapterDirectories();
    await ComicSourceManager().ensureInit();
    restoreDownloadingTasks();
    // Defer auto-resume so a cold start (DB init, home page) isn't competing
    // with download network/IO, and to steer clear of startup races in this
    // historically crash-prone path. Tasks the user manually paused stay paused
    // (wasRunning was persisted as false for them).
    Future.delayed(const Duration(seconds: 3), _autoResumeDownloads);
  }

  /// Creates the comics table when missing and upgrades older layouts.
  /// Idempotent; also run after [restoreFrom], whose page-level copy may bring
  /// in a backup created by an older app version.
  void _ensureSchema() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS comics (
        id TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT NOT NULL,
        tags TEXT NOT NULL,
        directory TEXT NOT NULL,
        chapters TEXT NOT NULL,
        cover TEXT NOT NULL,
        comic_type INTEGER NOT NULL,
        downloadedChapters TEXT NOT NULL,
        created_at INTEGER,
        description TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (id, comic_type)
      );
    ''');
    final cols = _db
        .select('PRAGMA table_info(comics);')
        .map((r) => r['name'] as String)
        .toList();
    if (!cols.contains('description')) {
      _db.execute(
          "ALTER TABLE comics ADD COLUMN description TEXT NOT NULL DEFAULT '';");
    }
  }

  /// Replaces the local-library database content with the file at
  /// [sourcePath] by closing the connection, swapping the file, and
  /// reopening — see [restoreDatabaseFiles]. Path configuration, download-task
  /// state and comic-source init are process-level and deliberately not
  /// re-run here.
  Future<void> restoreFrom(String sourcePath) async {
    if (!isInitialized) {
      throw StateError("LocalManager is not initialized; cannot restore");
    }
    DatabaseGateway.instance.closeManaged(_dbPath);
    try {
      restoreDatabaseFiles({_dbPath: sourcePath});
    } finally {
      _db = DatabaseGateway.instance.openManaged(_dbPath);
    }
    _ensureSchema();
    notifyListeners();
  }

  /// Resume downloads that were genuinely running when the app was last closed,
  /// up to the configured parallelism. Tasks the user manually paused stay
  /// paused (wasRunning was persisted as false for them).
  void _autoResumeDownloads() {
    final limit = _maxParallelDownloads;
    var started = 0;
    for (final t in downloadingTasks) {
      if (started >= limit) break;
      if (t.wasRunning && !t.isError && !t.userPaused) {
        t.resume();
        started++;
      }
    }
    if (started > 0) {
      DownloadKeepAlive.instance.refresh();
    }
  }

  /// Next free numeric id for [type].
  ///
  /// Only plain-number ids take part. Derived rows — `bt_…` FT projects and
  /// `ft_…` published translations — are registered by other managers and are
  /// not part of the import numbering, so they must neither advance the counter
  /// nor be handed to [int.parse]. SQLite's `CAST('bt_5be94984' AS INTEGER)`
  /// is 0, which made such a row sort last and then crash the next folder
  /// import with a `FormatException` (observed on `Error the Echo`, whose
  /// project card shared its title with the artwork).
  String findValidId(ComicType type) {
    final res = _db.select(
      '''
      SELECT id FROM comics
      WHERE comic_type = ? AND id GLOB '[0-9]*'
      ORDER BY CAST(id AS INTEGER) DESC
      LIMIT 1;
      ''',
      [type.value],
    );
    if (res.isEmpty) {
      return '1';
    }
    final highest = int.tryParse(res.first[0] as String);
    if (highest == null) {
      return '1';
    }
    return (highest + 1).toString();
  }

  Future<void> add(LocalComic comic, [String? id]) async {
    var old = find(id ?? comic.id, comic.comicType);
    // downloaded chapters are a set: union with the existing row without
    // growing duplicates on every rescan/re-register.
    var downloaded = <String>{
      ...comic.downloadedChapters,
      if (old != null) ...old.downloadedChapters,
    }.toList();
    // 🔴 章节矩阵只许**变多**，不许变少。
    // `_writeComic` 是整行 `INSERT OR REPLACE`，所以任何一个"章节信息更少"的
    // 写入源都会把库里的版本矩阵冲掉。最危险的是**下载任务完成**这条路径：
    // `completeTask()` → `task.toLocalComic()` 携带的是**那次任务自己的**
    // `ComicDetails.chapters`，一旦它来自按翻译组过滤后的选章器或旧缓存，
    // 库里就只剩一个组的章节 —— 实测 `My Dragon Girlfriend Has Returned`
    // 从"11 组 × 7 话"退化成"1 组 × 6 话"，详情页的翻译组 chips 需要 2+ 组
    // 才渲染，于是整行组分类凭空消失（用户报告："理应出现的翻译组分类 UI
    // 消失了"，恰好在点过一次下载/修复之后）。
    final previous = old?.chapters;
    var chapters = comic.chapters;
    if (previous != null && previous.isVersioned) {
      final incomingVersions = chapters?.allVersions.length ?? 0;
      if (chapters == null || incomingVersions < previous.allVersions.length) {
        Log.warning(
          "LocalManager",
          "Refusing to shrink the stored chapter matrix of '${comic.title}' "
          "(${previous.allVersions.length} versions kept, "
          "$incomingVersions offered) — the incoming record came from a "
          "partial view (group-filtered download or stale details cache)",
        );
        chapters = previous;
      }
    }
    _writeComic(comic, id ?? comic.id, downloaded, chapters: chapters);
    try {
      const ComicStateRepository().mirrorLocalComic(comic);
    } catch (_) {}
    notifyListeners();
  }

  void _writeComic(
    LocalComic comic,
    String id,
    List<String> downloadedChapters, {
    ComicChapters? chapters,
  }) {
    _db.execute(
      'INSERT OR REPLACE INTO comics '
      '(id, title, subtitle, tags, directory, chapters, cover, comic_type, '
      'downloadedChapters, created_at, description) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        id,
        comic.title,
        comic.subtitle,
        jsonEncode(comic.tags),
        comic.directory,
        jsonEncode(chapters ?? comic.chapters),
        comic.cover,
        comic.comicType.value,
        jsonEncode(downloadedChapters),
        comic.createdAt.millisecondsSinceEpoch,
        comic.description,
      ],
    );
  }

  /// Replaces a pure local comic after a successful directory rescan.
  /// Stable identity and user state live outside the refreshed metadata row.
  void replaceLocalComic(LocalComic comic) {
    final previous = find(comic.id, comic.comicType);
    final existingHistory = HistoryManager().find(comic.id, comic.comicType);
    if (previous != null && existingHistory != null) {
      remapLocalComicHistory(existingHistory, previous, comic);
    }
    _writeComic(comic, comic.id, List<String>.from(comic.downloadedChapters));
    try {
      const ComicStateRepository().mirrorLocalComic(comic);
    } catch (_) {}
    if (existingHistory != null) {
      // A rescan refreshes metadata only; it must not pull a record the user
      // deleted back into the history list (issue #270).
      HistoryManager().updateHistoryKeepingVisibility(existingHistory);
    }

    final favorites = LocalFavoritesManager();
    final folders = favorites.find(comic.id, comic.comicType);
    final favorite = FavoriteItem(
      id: comic.id,
      name: comic.title,
      coverPath: comic.cover,
      author: comic.subtitle,
      type: comic.comicType,
      tags: comic.tags,
      favoriteTime: comic.createdAt,
    );
    for (var i = 0; i < folders.length; i++) {
      favorites.updateInfo(
        folders[i],
        favorite,
        i == folders.length - 1,
        false,
      );
    }
    notifyListeners();
  }

  void remove(String id, ComicType comicType) async {
    _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
      id,
      comicType.value,
    ]);
    notifyListeners();
  }

  void removeComic(LocalComic comic) {
    remove(comic.id, comic.comicType);
    notifyListeners();
  }

  List<LocalComic> getComics(LocalSortType sortType) {
    if (sortType == LocalSortType.lastRead) {
      return _getComicsSortedByLastRead();
    }
    if (sortType == LocalSortType.author) {
      return _getComicsSortedByAuthor();
    }
    String orderColumn;
    String orderDir;
    switch (sortType) {
      case LocalSortType.name:
        orderColumn = 'title';
        orderDir = 'ASC';
      case LocalSortType.nameDesc:
        orderColumn = 'title';
        orderDir = 'DESC';
      case LocalSortType.timeAsc:
        orderColumn = 'created_at';
        orderDir = 'ASC';
      case LocalSortType.timeDesc:
        orderColumn = 'created_at';
        orderDir = 'DESC';
      default:
        orderColumn = 'created_at';
        orderDir = 'DESC';
    }
    var res = _db.select('''
      SELECT * FROM comics ORDER BY $orderColumn $orderDir;
    ''');
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  List<LocalComic> getComicsByStatus(LocalComicStatus status, LocalSortType sortType) {
    return getComics(sortType).where((c) => c.status == status).toList();
  }

  bool hasComicsWithImages() {
    return getComics(LocalSortType.defaultSort).any(
      (c) => c.status == LocalComicStatus.downloaded,
    );
  }

  List<LocalComic> _getComicsSortedByAuthor() {
    var res = _db.select('SELECT * FROM comics;');
    var comics = res.map((row) => LocalComic.fromRow(row)).toList();
    comics.sort((a, b) => a.subtitle.compareTo(b.subtitle));
    return comics;
  }

  List<LocalComic> _getComicsSortedByLastRead() {
    var allComics = _db.select('SELECT * FROM comics;');
    var comics = allComics.map((row) => LocalComic.fromRow(row)).toList();
    comics.sort((a, b) {
      var historyA = HistoryManager().find(a.id, a.comicType);
      var historyB = HistoryManager().find(b.id, b.comicType);
      var timeA = historyA?.time ?? DateTime.fromMillisecondsSinceEpoch(0);
      var timeB = historyB?.time ?? DateTime.fromMillisecondsSinceEpoch(0);
      return timeB.compareTo(timeA);
    });
    return comics;
  }

  LocalComic? find(String id, ComicType comicType) {
    final res = _db.select(
      'SELECT * FROM comics WHERE id = ? AND comic_type = ?;',
      [id, comicType.value],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalComic.fromRow(res.first);
  }

  @override
  void dispose() {
    super.dispose();
    DatabaseGateway.instance.closeManaged(_dbPath);
  }

  List<LocalComic> getRecent() {
    final res = _db.select('''
      SELECT * FROM comics
      ORDER BY created_at DESC
      LIMIT 20;
    ''');
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  int get count {
    final res = _db.select('''
      SELECT COUNT(*) FROM comics;
    ''');
    return res.first[0] as int;
  }

  LocalComic? findByName(String name) {
    final res = _db.select(
      '''
      SELECT * FROM comics
      WHERE title = ? OR directory = ?;
    ''',
      [name, name],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalComic.fromRow(res.first);
  }

  /// Whether a comic the user *imported* already owns [name] or [directory].
  ///
  /// Deliberately narrower than [findByName]: rows whose id is not a plain
  /// number are not imports. `bt_…` is an FT project and `ft_…` a published
  /// translation — both are *derived* from a comic rather than being one, and
  /// both can carry the same title as the artwork they were built from. Letting
  /// them answer the import guard made "import Error the Echo" fail with
  /// "Comic already exists" while the only existing row was the project.
  LocalComic? findImportedByName(String name) {
    final res = _db.select(
      '''
      SELECT * FROM comics
      WHERE (title = ? OR directory = ?) AND id GLOB '[0-9]*';
    ''',
      [name, name],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalComic.fromRow(res.first);
  }

  List<LocalComic> search(String keyword) {
    final res = _db.select(
      '''
      SELECT * FROM comics
      WHERE title LIKE ? OR tags LIKE ? OR subtitle LIKE ?
      ORDER BY created_at DESC;
    ''',
      ['%$keyword%', '%$keyword%', '%$keyword%'],
    );
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  Future<List<String>> getImages(String id, ComicType type, Object ep) async {
    var comic = find(id, type) ?? (throw "Comic Not Found");
    return getImagesForComic(comic, ep);
  }

  /// Lists local pages without looking the comic up again in the database.
  Future<List<String>> getImagesForComic(LocalComic comic, Object ep) async {
    if (ep is! String && ep is! int) {
      throw "Invalid ep";
    }
    var directory = Directory(comic.baseDir);
    if (comic.hasChapters) {
      var cid = ep is int
          ? comic.effectiveChapters!.ids.elementAt(ep - 1)
          : (ep as String);
      // 必须与下载侧同一个函数：目录名规则一旦分叉就"下完读不到"。
      cid = chapterDirectoryName(comic.chapters, cid);
      directory = Directory(FilePath.join(directory.path, cid));
    }
    var files = <File>[];
    await for (var entity in directory.list()) {
      if (entity is File) {
        // Do not exclude comic.cover, since it may be the first page of the chapter.
        // A file with name starting with 'cover.' is not a comic page.
        if (entity.name.startsWith('cover.')) {
          continue;
        }
        //Hidden file in some file system
        if (entity.name.startsWith('.')) {
          continue;
        }
        files.add(entity);
      }
    }
    files.sort((a, b) {
      var ai = int.tryParse(a.name.split('.').first);
      var bi = int.tryParse(b.name.split('.').first);
      if (ai != null && bi != null) {
        return ai.compareTo(bi);
      }
      return a.name.compareTo(b.name);
    });
    return files.map((e) => "file://${e.path}").toList();
  }

  bool isDownloaded(
    String id,
    ComicType type, [
    int? ep,
    ComicChapters? chapters,
  ]) {
    var comic = find(id, type);
    if (comic == null) return false;
    if (comic.chapters == null || ep == null) return true;
    if (chapters != null) {
      if (comic.chapters?.length != chapters.length) {
        // update
        add(
          LocalComic(
            id: comic.id,
            title: comic.title,
            subtitle: comic.subtitle,
            tags: comic.tags,
            directory: comic.directory,
            chapters: chapters,
            cover: comic.cover,
            comicType: comic.comicType,
            downloadedChapters: comic.downloadedChapters,
            createdAt: comic.createdAt,
            description: comic.description,
          ),
        );
      }
    }
    return comic.downloadedChapters.contains(
      (chapters ?? comic.effectiveChapters)!.ids.elementAtOrNull(ep - 1),
    );
  }

  List<DownloadTask> downloadingTasks = [];

  bool isDownloading(String id, ComicType type) {
    return downloadingTasks.any(
      (element) => element.id == id && element.comicType == type,
    );
  }

  Future<Directory> findValidDirectory(
    String id,
    ComicType type,
    String name,
  ) async {
    var comic = find(id, type);
    if (comic != null) {
      return Directory(FilePath.join(path, comic.directory));
    }
    const comicDirectoryMaxLength = 80;
    if (name.length > comicDirectoryMaxLength) {
      name = name.substring(0, comicDirectoryMaxLength);
    }
    var dir = findValidDirectoryName(path, name);
    return Directory(FilePath.join(path, dir)).create().then((value) => value);
  }

  void completeTask(DownloadTask task) {
    final finishedTitle = task.title;
    add(task.toLocalComic());
    downloadingTasks.remove(task);
    // 刚下完就立刻对一次账：① 这一次运行自己漏记的失败页（末轮之前就被取消 /
    // 异常退出的页）必须马上变成红色标记，而不是等用户下次打开详情页才发现；
    // ② 磁盘上已经存在但没被 `completeTask` 登记过的章节（半截下载、修复补完）
    // 要把 key 并回 `downloadedChapters`，否则"有文件却显示未下载"。
    //
    // 🔴 顺序不能反：`reconcile*` 里都有 `isDownloading` 守卫，任务还留在
    // `downloadingTasks` 里时这些守卫会直接返回 0 —— 那是一次静默空转，
    // 表现为"下完了也没有红色标记、也没被登记"。
    final stored = find(task.id, task.comicType);
    if (stored != null) {
      unawaited(reconcileDiskState(stored));
    }
    notifyListeners();
    saveCurrentDownloadingTasks();
    // Notify when the whole queue has drained (nothing left, or only paused/
    // errored leftovers) so a background download run ends with a single
    // "done" notification rather than silence (#10).
    final moreToRun = downloadingTasks.any((t) => !t.isError && !t.userPaused);
    if (!moreToRun) {
      DownloadKeepAlive.instance.notifyComplete(finishedTitle);
    }
    _advanceQueue();
  }

  void removeTask(DownloadTask task) {
    downloadingTasks.remove(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
    // Advance so cancelling the active task doesn't stall the rest of the queue.
    _advanceQueue();
  }

  void moveToFirst(DownloadTask task) {
    if (downloadingTasks.first != task) {
      var shouldResume = !downloadingTasks.first.isPaused;
      downloadingTasks.first.pause();
      downloadingTasks.remove(task);
      downloadingTasks.insert(0, task);
      notifyListeners();
      saveCurrentDownloadingTasks();
      if (shouldResume) {
        downloadingTasks.first.resume();
      }
      DownloadKeepAlive.instance.refresh();
    }
  }

  /// User-initiated pause of a single task. Marks it [DownloadTask.userPaused]
  /// so the queue won't auto-resume it, then lets the queue fill the freed slot
  /// with the next runnable task (#9).
  void pauseTask(DownloadTask task) {
    task.userPaused = true;
    task.pause();
    notifyListeners();
    _advanceQueue();
  }

  /// User-initiated resume/retry of a single task. Clears [userPaused] and the
  /// auto-retry budget so an errored task gets a fresh start (#9 retry).
  void resumeTask(DownloadTask task) {
    task.userPaused = false;
    task.autoRetryCount = 0;
    task.resume();
    notifyListeners();
    DownloadKeepAlive.instance.refresh();
  }

  /// Pause every task and remember that the user did so, so nothing auto-resumes
  /// until the user explicitly resumes (#9).
  void pauseAll() {
    for (final t in downloadingTasks) {
      t.userPaused = true;
      if (!t.isPaused) t.pause();
    }
    notifyListeners();
    saveCurrentDownloadingTasks();
    DownloadKeepAlive.instance.refresh();
  }

  /// Clear the user-paused flag on every task and let the queue resume up to the
  /// configured parallelism (#9).
  void resumeAll() {
    for (final t in downloadingTasks) {
      t.userPaused = false;
      t.autoRetryCount = 0;
    }
    notifyListeners();
    _advanceQueue();
  }

  /// Cancel every queued/active download (#9). Iterates over a copy because
  /// [DownloadTask.cancel] mutates [downloadingTasks].
  void cancelAll() {
    for (final t in downloadingTasks.toList()) {
      t.cancel();
    }
    notifyListeners();
    DownloadKeepAlive.instance.refresh();
  }

  /// Forget every persisted task record **without deleting downloaded data**.
  ///
  /// Deliberately not [cancelAll]: `DownloadTask.cancel()` removes partially
  /// downloaded chapter directories from disk, which is right for the GUI's
  /// "cancel" button but destroys a CLI run's work. This only pauses in-flight
  /// work (keeping finished pages) and drops the records.
  ///
  /// Used by `venera.exe --headless download-check --clean`: a run killed by
  /// SIGTERM leaves its tasks in `downloading_tasks.json`, they are restored on
  /// the next launch and occupy every queue slot, so the new task never gets a
  /// slot and simply waits out the wall clock.
  void dropAllTaskRecords() {
    final dropped = downloadingTasks.length;
    for (final t in downloadingTasks.toList()) {
      // Pause rather than cancel: stops in-flight work, keeps downloaded pages.
      t.pause();
      downloadingTasks.remove(t);
    }
    notifyListeners();
    saveCurrentDownloadingTasks();
    Log.info("LocalManager", "dropAllTaskRecords: dropped $dropped task(s)");
  }

  /// Reorder a task within the queue (drag-and-drop, #9). Pauses whatever was
  /// running and re-fills slots from the new order so the user's intended
  /// priority takes effect immediately. [newIndex] is a final list index
  /// (already adjusted for the removal, as `onReorderItem` reports).
  void reorderTask(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= downloadingTasks.length) return;
    if (newIndex < 0 || newIndex >= downloadingTasks.length) return;
    if (oldIndex == newIndex) return;
    final task = downloadingTasks.removeAt(oldIndex);
    downloadingTasks.insert(newIndex, task);
    // Pause non-user-paused running tasks so _advanceQueue re-picks from the
    // top of the new order rather than leaving a lower-priority task running.
    for (final t in downloadingTasks) {
      if (!t.userPaused && !t.isPaused && !t.isError) t.pause();
    }
    notifyListeners();
    saveCurrentDownloadingTasks();
    _advanceQueue();
  }

  static const _maxAutoRetry = 3;

  /// True while the network guard wants downloads held (e.g. "WiFi only" is on
  /// and the device is on cellular). Queued tasks won't auto-resume and active
  /// ones are paused until the block clears (#15).
  bool _networkBlocked = false;

  /// Toggle the metered-network block. When blocking, pauses currently-running
  /// tasks WITHOUT marking them user-paused, so they auto-resume once an
  /// unmetered connection returns. When unblocking, re-fills the queue.
  void setNetworkBlocked(bool blocked) {
    if (_networkBlocked == blocked) return;
    _networkBlocked = blocked;
    if (blocked) {
      for (final t in downloadingTasks) {
        if (!t.isPaused && !t.isError) t.pause();
      }
      notifyListeners();
      saveCurrentDownloadingTasks();
      DownloadKeepAlive.instance.refresh();
    } else {
      _advanceQueue();
    }
  }

  /// Invoked by a task when it enters the error state. Keeps the queue moving:
  /// the failed task is parked at the end so a persistent failure can't block
  /// healthy tasks, then the next runnable task starts. A few bounded, delayed
  /// auto-retries are attempted before leaving it for the user (#7).
  void onTaskError(DownloadTask task) {
    if (!downloadingTasks.contains(task)) return;
    if (downloadingTasks.length > 1 && downloadingTasks.first == task) {
      downloadingTasks.remove(task);
      downloadingTasks.add(task);
    }
    notifyListeners();
    saveCurrentDownloadingTasks();
    _advanceQueue();
  }

  /// How many comics may download at once. Default 1 keeps the historical
  /// serial behavior; the user can opt into 2–3 (#3).
  int get _maxParallelDownloads {
    final v = (appdata.settings["maxParallelDownloads"] as num?)?.toInt() ?? 1;
    return v.clamp(1, 3);
  }

  /// Ensure up to [_maxParallelDownloads] non-error tasks are downloading,
  /// resuming queued ones in order. If every task has errored, fall back to a
  /// bounded delayed auto-retry of the least-tried task (#7).
  void _advanceQueue() {
    if (downloadingTasks.isEmpty) {
      DownloadKeepAlive.instance.refresh();
      return;
    }
    // Metered-network block ("WiFi only"): pause anything running without
    // marking it user-paused, and resume nothing until the block clears.
    if (_networkBlocked) {
      for (final t in downloadingTasks) {
        if (!t.isPaused && !t.isError) t.pause();
      }
      DownloadKeepAlive.instance.refresh();
      return;
    }
    final limit = _maxParallelDownloads;
    for (final t in downloadingTasks) {
      final running =
          downloadingTasks.where((x) => !x.isPaused && !x.isError).length;
      if (running >= limit) break;
      // A user-paused task waits for the user; only auto-resume tasks that are
      // merely queued (paused but not user-paused) and not in error.
      if (!t.isError && t.isPaused && !t.userPaused) {
        t.resume();
      }
    }
    DownloadKeepAlive.instance.refresh();
    // Only fall back to error auto-retry when nothing is runnable AND the user
    // hasn't deliberately paused everything.
    final anyRunning = downloadingTasks.any((t) => !t.isPaused && !t.isError);
    final anyQueued =
        downloadingTasks.any((t) => t.isPaused && !t.userPaused && !t.isError);
    if (!anyRunning && !anyQueued) {
      _scheduleErrorAutoRetry();
    }
  }

  /// All tasks have errored: give the least-tried one a delayed auto-retry,
  /// up to [_maxAutoRetry] attempts, then leave it for the user.
  void _scheduleErrorAutoRetry() {
    DownloadTask? candidate;
    for (final t in downloadingTasks) {
      if (t.autoRetryCount >= _maxAutoRetry) continue;
      if (candidate == null || t.autoRetryCount < candidate.autoRetryCount) {
        candidate = t;
      }
    }
    if (candidate == null) return; // gave up; the user can retry manually
    final task = candidate;
    task.autoRetryCount++;
    final delay = Duration(seconds: 15 * task.autoRetryCount); // 15s/30s/45s
    Future.delayed(delay, () {
      if (!downloadingTasks.contains(task) || !task.isError) return;
      if (downloadingTasks.any((t) => !t.isPaused && !t.isError)) return;
      task.resume();
      DownloadKeepAlive.instance.refresh();
    });
  }

  Timer? _saveDebounce;
  bool _isSavingTasks = false;
  bool _saveTasksAgain = false;

  /// Debounced, low-priority persistence for the high-frequency per-image
  /// progress updates. Coalesces a burst of calls into at most one write per
  /// ~1.5s instead of re-serializing the entire task list (including every
  /// chapter's image-URL map) on every single image — see #1.
  void scheduleSaveDownloadingTasks() {
    _saveDebounce ??= Timer(const Duration(milliseconds: 1500), () {
      _saveDebounce = null;
      _flushDownloadingTasks();
    });
  }

  /// Durable, immediate persistence for important transitions (add/remove/
  /// complete/pause, chapter list fetched, etc.). Flushes any pending debounce.
  Future<void> saveCurrentDownloadingTasks() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    await _flushDownloadingTasks();
  }

  /// Single-flight, atomic writer. Serializes all writes through one in-flight
  /// operation (re-running once if more changes arrived meanwhile) so two
  /// concurrent `writeAsString` calls can never interleave and corrupt
  /// downloading_tasks.json — see B4. Writes to a temp file then renames.
  Future<void> _flushDownloadingTasks() async {
    if (_isSavingTasks) {
      _saveTasksAgain = true;
      return;
    }
    _isSavingTasks = true;
    try {
      final path = FilePath.join(App.dataPath, 'downloading_tasks.json');
      final tmp = '$path.tmp';
      do {
        _saveTasksAgain = false;
        final data = jsonEncode(downloadingTasks.map((e) => e.toJson()).toList());
        final tmpFile = File(tmp);
        await tmpFile.writeAsString(data, flush: true);
        try {
          // rename() does not overwrite an existing file on Windows, so remove
          // the destination first. If the rename still fails (e.g. cross-device
          // temp dir), fall back to a direct write.
          final dest = File(path);
          if (dest.existsSync()) dest.deleteSync();
          tmpFile.renameSync(path);
        } catch (_) {
          await File(path).writeAsString(data, flush: true);
          tmpFile.deleteIgnoreError();
        }
      } while (_saveTasksAgain);
    } catch (e) {
      Log.error("LocalManager", "Failed to save downloading tasks: $e");
    } finally {
      _isSavingTasks = false;
    }
  }

  void restoreDownloadingTasks() {
    var file = File(FilePath.join(App.dataPath, 'downloading_tasks.json'));
    if (file.existsSync()) {
      try {
        var tasks = jsonDecode(file.readAsStringSync());
        for (var e in tasks) {
          var task = DownloadTask.fromJson(e);
          if (task != null) {
            downloadingTasks.add(task);
          }
        }
      } catch (e) {
        file.delete();
        Log.error("LocalManager", "Failed to restore downloading tasks: $e");
      }
    }
  }

  /// Ensures the download directory is actually writable before a download is
  /// enqueued. On Android a custom folder in shared storage silently no-ops
  /// writes without all-files-access permission, so a download would "finish"
  /// while nothing lands on disk (#89). This probes the folder, requests the
  /// permission when it's missing, and re-resolves the saved path so the user's
  /// chosen folder is restored without an app restart.
  ///
  /// Returns true when downloads may proceed. Non-Android platforms always
  /// return true.
  Future<bool> ensureDownloadWritable() async {
    if (!App.isAndroid) return true;
    var savedPathFile = File(FilePath.join(App.dataPath, 'local_path'));
    var saved = savedPathFile.existsSync()
        ? savedPathFile.readAsStringSync().trim()
        : '';
    // A custom download folder in shared storage is the #89 scenario. Without
    // all-files access, init()'s validation either silently keeps it (writes
    // no-op rather than throw, so the folder stays selected but downloads land
    // nowhere) or falls back to app-private storage (so `path` is writable but
    // points at the wrong place). Either way, make the user's *chosen* folder
    // writable first so downloads land where they expect — don't let a writable
    // fallback path mask the problem.
    if (saved.isNotEmpty && saved != path) {
      if (await StoragePermission.ensureGranted(saved)) {
        path = saved;
        _checkNoMedia();
        return true;
      }
      // The user's folder still isn't writable even after prompting. Refuse
      // rather than silently downloading into the fallback location, which is
      // exactly the "looks done but folder is empty" symptom being fixed.
      return false;
    }
    // No custom folder (default is app-private external storage, writable
    // without the permission), or it's already the active path: just verify.
    return await StoragePermission.ensureGranted(path);
  }

  void addTask(DownloadTask task) {
    downloadingTasks.add(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
    _advanceQueue();
  }

  /// Enqueue several tasks at once with a single persistence write and a single
  /// queue advance, instead of paying both costs per comic. Used by batch
  /// "download selected" so adding 50 comics doesn't trigger 50 full-list
  /// serializations (#17).
  void addTasks(Iterable<DownloadTask> tasks) {
    var added = false;
    for (final task in tasks) {
      downloadingTasks.add(task);
      added = true;
    }
    if (!added) return;
    notifyListeners();
    saveCurrentDownloadingTasks();
    _advanceQueue();
  }

  void deleteComic(LocalComic c, [bool removeFileOnDisk = true]) {
    if (removeFileOnDisk) {
      var dir = Directory(FilePath.join(path, c.directory));
      dir.deleteIgnoreError(recursive: true);
    }
    // Deleting a local comic means that it's no longer available, thus both favorite and history should be deleted.
    if (c.comicType == ComicType.local) {
      if (HistoryManager().find(c.id, c.comicType) != null) {
        HistoryManager().remove(c.id, c.comicType);
      }
      var folders = LocalFavoritesManager().find(c.id, c.comicType);
      for (var f in folders) {
        LocalFavoritesManager().deleteComicWithId(f, c.id, c.comicType);
      }
      const ComicStateRepository().removeLocalComicMirror(c.id);
    }
    remove(c.id, c.comicType);
    notifyListeners();
  }

  void deleteComicChapters(LocalComic c, List<String> chapters) {
    if (chapters.isEmpty) {
      return;
    }
    var newDownloadedChapters = c.downloadedChapters
        .where((e) => !chapters.contains(e))
        .toList();
    if (newDownloadedChapters.isNotEmpty) {
      _db.execute(
        'UPDATE comics SET downloadedChapters = ? WHERE id = ? AND comic_type = ?;',
        [jsonEncode(newDownloadedChapters), c.id, c.comicType.value],
      );
    } else {
      _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
        c.id,
        c.comicType.value,
      ]);
      if (c.comicType == ComicType.local) {
        const ComicStateRepository().removeLocalComicMirror(c.id);
      }
    }
    var shouldRemovedDirs = <Directory>[];
    for (var chapter in chapters) {
      // [chapters] 里放的是 chapterKey（不是目录名），目录名必须现算，
      // 否则带组目录的章节永远删不掉（dir.existsSync() 恒 false）。
      var dir = Directory(
        FilePath.join(c.baseDir, chapterDirectoryName(c.chapters, chapter)),
      );
      if (dir.existsSync()) {
        shouldRemovedDirs.add(dir);
      }
    }
    if (shouldRemovedDirs.isNotEmpty) {
      _deleteDirectories(shouldRemovedDirs);
    }
    notifyListeners();
  }

  void batchDeleteComics(
    List<LocalComic> comics, [
    bool removeFileOnDisk = true,
    bool removeFavoriteAndHistory = true,
  ]) {
    if (comics.isEmpty) {
      return;
    }

    var shouldRemovedDirs = <Directory>[];
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var c in comics) {
        if (removeFileOnDisk) {
          var dir = Directory(FilePath.join(path, c.directory));
          if (dir.existsSync()) {
            shouldRemovedDirs.add(dir);
          }
        }
        _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
          c.id,
          c.comicType.value,
        ]);
      }
    } catch (e, s) {
      Log.error("LocalManager", "Failed to batch delete comics: $e", s);
      _db.execute('ROLLBACK;');
      return;
    }
    _db.execute('COMMIT;');

    var comicIDs = comics.map((e) => ComicID(e.comicType, e.id)).toList();

    for (var c in comics) {
      if (c.comicType == ComicType.local) {
        const ComicStateRepository().removeLocalComicMirror(c.id);
      }
    }

    if (removeFavoriteAndHistory) {
      LocalFavoritesManager().batchDeleteComicsInAllFolders(comicIDs);
      HistoryManager().batchDeleteHistories(comicIDs);
    }

    notifyListeners();

    if (removeFileOnDisk) {
      _deleteDirectories(shouldRemovedDirs);
    }
  }

  /// Deletes the directories without blocking the UI thread.
  ///
  /// On Android the file paths may be SAF (android://) URIs that can only be
  /// resolved through [SAFTaskWorker], so deletion runs in a dedicated isolate
  /// that initializes the worker. On other platforms the paths are plain file
  /// system paths, so we delete them directly with async I/O — spawning a SAF
  /// isolate there is unnecessary and, because the worker's receive port is
  /// never closed, leaks an isolate on every delete (and could hang on
  /// platforms without the SAF channel).
  static void _deleteDirectories(List<Directory> directories) {
    if (directories.isEmpty) return;
    if (App.isAndroid) {
      Isolate.run(() async {
        await SAFTaskWorker().init();
        for (var dir in directories) {
          try {
            if (dir.existsSync()) {
              await dir.delete(recursive: true);
            }
          } catch (e) {
            continue;
          }
        }
      });
    } else {
      for (var dir in directories) {
        dir.deleteIgnoreError(recursive: true);
      }
    }
  }

  /// 只做非法字符清洗。**不要用它算章节目录名** —— 那需要话号与组名，
  /// 一律走 [chapterDirectoryName]；这个只留给不掌握 chapters 的调用方
  /// （WebDAV 迁移等）做纯字符串清洗。
  static String getChapterDirectoryName(String name) =>
      sanitizePathSegment(name);

  /// 章节目录"带组改名"的一次性迁移（S7U/U3-4）。
  ///
  /// 旧规则下目录名是 `parseChapterTitle(key).chapterNumber ?? key`；新规则
  /// 在版本化且能取到组名时是 `<话号> [组名]`。已下载的漫画必须跟着搬，
  /// 否则升级后读不到旧文件。
  ///
  /// 保守原则：**取不到组信息就保持原样**（不猜、不删）。目标已存在时也
  /// 跳过（可能是用户自己放的同名目录）。
  ///
  /// 只搬一次：完成标记写在 implicitData（设备本地，不进备份）。
  static const _chapterDirMigrationKey = 'chapterDirGroupMigration';

  void migrateChapterDirectories() {
    if (appdata.implicitData[_chapterDirMigrationKey] == true) return;
    var renamed = 0;
    try {
      for (final comic in getComics(LocalSortType.defaultSort)) {
        renamed += _migrateComicChapterDirs(comic);
      }
    } catch (e, s) {
      Log.error("LocalManager", "Chapter directory migration failed: $e", s);
    }
    Log.info("LocalManager", "Chapter directory migration: $renamed renamed");
    appdata.implicitData[_chapterDirMigrationKey] = true;
    appdata.writeImplicitData();
  }

  /// 返回被改名的目录数。
  int _migrateComicChapterDirs(LocalComic comic) {
    final chapters = comic.chapters;
    if (chapters == null || !chapters.isVersioned) return 0;
    final base = comic.baseDir;
    final remap = <String, String>{}; // 旧目录名 -> 新目录名
    for (final key in comic.downloadedChapters) {
      final oldName = sanitizePathSegment(
        parseChapterTitle(key).chapterNumber?.toString() ?? key,
      );
      final newName = chapterDirectoryName(chapters, key);
      if (oldName == newName || oldName.isEmpty || newName.isEmpty) continue;
      remap[oldName] = newName;
    }
    if (remap.isEmpty) return 0;

    var count = 0;
    for (final entry in remap.entries) {
      final oldDir = Directory(FilePath.join(base, entry.key));
      final newDir = Directory(FilePath.join(base, entry.value));
      if (!oldDir.existsSync() || newDir.existsSync()) continue;
      try {
        oldDir.renameSync(newDir.path);
        count++;
      } catch (e) {
        Log.error(
          "LocalManager",
          "Failed to rename chapter dir '${entry.key}' -> '${entry.value}': $e",
        );
      }
    }
    if (count > 0) {
      _remapMissingPageChapters(base, remap);
    }
    return count;
  }

  /// 目录改名后同步缺页表的 chapterId（见 [MissingPages.reconcileChapter]）。
  void _remapMissingPageChapters(String base, Map<String, String> remap) {
    try {
      final table = MissingPages.peek(base);
      if (table == null || table.entries.isEmpty) return;
      if (table.remapChapterIds(remap)) {
        unawaited(MissingPages.save(base, table));
      }
    } catch (e, s) {
      Log.error("LocalManager", "Failed to remap missing pages: $e", s);
    }
  }

  /// 把源刷新到的**完整**章节矩阵并回本地记录，只增不减。返回是否真的写了。
  ///
  /// 与 [add] 的"拒绝缩小"是同一件事的两半：那边防退化（写入源信息更少时拒绝），
  /// 这边负责自愈（拿到更全的矩阵时补回来）。本地已有的话号与版本一律保留 ——
  /// 源上可能已经下架了用户当初下载的那一版。
  Future<bool> enrichComicChapters(
    String id,
    ComicType type,
    ComicChapters? online,
  ) async {
    if (online == null || !online.isVersioned) return false;
    final old = find(id, type);
    if (old == null) return false;
    final merged = old.chapters?.mergedWith(online) ?? online;
    final before = old.chapters?.versionCount ?? 0;
    if (merged.versionCount <= before) return false;
    _writeComic(old, id, old.downloadedChapters, chapters: merged);
    notifyListeners();
    Log.info(
      "LocalManager",
      "Chapter matrix enriched for '${old.title}': $before -> "
          "${merged.versionCount} version(s), ${merged.scanlationGroups.length} "
          "group(s)",
    );
    return true;
  }

  /// 用磁盘现状校对缺页表：把"页文件真的不在"的洞补记进
  /// `missing_pages.json`，并清掉已经补回来的陈旧条目。返回被改写的条目数。
  ///
  /// 扫描对象是**磁盘上的章节目录**，不是 `downloadedChapters`：
  /// - 目录名本身就是缺页表/阅读器/删除侧共用的 `chapterId`，不需要（可能已经
  ///   退化的）`chapters` 矩阵去反推，所以未登记的半截目录也能被查出来；
  /// - 这正是用户遇到的形态：`6 [DivaScans]` 有 32 个空洞，但它**不在**
  ///   `downloadedChapters` 里（当初没下完，没走 `completeTask`），过去任何
  ///   基于登记表的检查都看不见它。
  ///
  /// ⚠️ 只对**网络下载**的漫画生效（[ComicType.local] 跳过）：本地导入的目录
  /// 可能是 1-based 或自定义命名，按 `0..max` 判空洞会把起始偏移误判成缺页。
  /// ⚠️ 该漫画正在下载时直接跳过：半截目录里的每个洞都还不是"缺页"。
  Future<int> reconcileMissingPages(LocalComic comic) async {
    if (comic.comicType == ComicType.local) return 0;
    if (isDownloading(comic.id, comic.comicType)) return 0;
    final base = comic.baseDir;
    final root = Directory(base);
    if (!root.existsSync()) return 0;

    var changed = 0;
    Future<void> scan(String chapterId, Directory dir) async {
      final present = _pageIndexesIn(dir);
      // 目录里一个可解析的页文件都没有 → 这不是"缺几页"，是整章不存在，
      // 交给下载状态去表达，不要在这里凭空造几百条 missing。
      if (present.isEmpty) return;
      changed += await MissingPages.reconcileChapter(
        base,
        chapterId: chapterId,
        chapterTitle: chapterId,
        presentIndexes: present,
        sourceKey: comic.sourceKey,
        comicId: comic.id,
      );
    }

    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      // ⚠️ 不能用 `entity.uri.pathSegments.last`：目录 URI **必带结尾斜杠**，
      // 最后一段是空串，且真实名字是百分号编码的（`6 [DivaScans]` →
      // `6%20%5BDivaScans%5D`）。用扩展的 `name`（＝`p.basename(path)`）。
      final name = entity.name;
      if (name.isEmpty || name.startsWith('.')) continue;
      await scan(name, entity);
    }
    // 无章节的漫画：页文件直接躺在漫画根目录下。
    if (comic.chapters == null) {
      await scan('', root);
    }

    if (changed > 0) {
      Log.warning(
        "LocalManager",
        "Page reconcile found $changed missing page(s) on disk for "
        "'${comic.title}' that no download run had recorded",
      );
      notifyListeners();
    }
    return changed;
  }

  /// 用磁盘现状校对**已下载登记表**：磁盘上真实存在页文件的章节目录，把对应的
  /// chapterKey 并回 `downloadedChapters`。返回新登记的 key 数。
  ///
  /// 为什么必须要有这一步：`downloadedChapters` 是"这一话在本地"的**唯一判据**
  /// —— 章节标签配色（[chapterChipColorFor]）、下载页的勾选框
  /// （`_buildDownloadSections`）、阅读器的章节列表、`effectiveChapters` 的
  /// `preferDownloaded`，全部只读它。但它**只有一条写入路径**：
  /// `completeTask()` → `add(task.toLocalComic())`。于是任何**没走
  /// `completeTask`** 的本地副本对它都是隐形的：
  /// - 下载在整章结束前被取消 / 异常退出（半截目录留在磁盘上）；
  /// - `RepairDownloadTask` 只补页，按设计不回写库（见其 `_finalize`）。
  ///
  /// 实测形态：`My Dragon Girlfriend Has Returned / 6 [DivaScans]` 磁盘 177 页
  /// 齐全（`0..176` 零空洞），却因为上面两条被判成"未下载" —— 用户看到的
  /// "磁盘里明明有这一话、界面说没下载"就是这个冲突。
  ///
  /// 判据与 [LocalComicStatus] 对齐：**目录里有页文件就等于有本地副本**。
  /// 完不完整交给缺页表去表达（红 > 蓝），不在这里二次猜测。
  /// - 跳过 [ComicType.local]：本地导入的目录名本身就是 key，且可能是 1-based；
  /// - 该漫画正在下载时跳过：正在写入的半截目录还不是"已下载"。
  Future<int> reconcileDownloadedChapters(LocalComic comic) async {
    if (comic.comicType == ComicType.local) return 0;
    if (isDownloading(comic.id, comic.comicType)) return 0;
    // 拿库里最新一行，而不是调用方可能已经过时的对象：写回是整行
    // `INSERT OR REPLACE`，用旧对象会把别的字段一起回退。
    final row = find(comic.id, comic.comicType) ?? comic;
    final chapters = row.chapters;
    if (chapters == null) return 0;
    final root = Directory(row.baseDir);
    if (!root.existsSync()) return 0;

    // 目录名 → chapterKey。与下载侧、读取侧共用 `chapterDirectoryName`
    // （唯一真相），所以这里反查出的 key 一定和 UI 判据用的是同一个。
    final keyByDir = <String, String>{};
    for (final key in chapters.allVersionKeys) {
      final name = chapterDirectoryName(chapters, key);
      if (name.isNotEmpty) keyByDir.putIfAbsent(name, () => key);
    }

    final known = <String>{
      ...comic.downloadedChapters,
      ...row.downloadedChapters,
    };
    final added = <String>[];
    final unmapped = <String>[];
    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      // ⚠️ 不能用 `entity.uri.pathSegments.last`：目录 URI **必带结尾斜杠**，
      // 最后一段恒为空串，且真实名字是百分号编码的。用扩展的 `name`。
      final name = entity.name;
      if (name.isEmpty || name.startsWith('.')) continue;
      final key = keyByDir[name];
      if (key == null) {
        // 目录在磁盘上，但章节矩阵里没有对应版本（矩阵被冲掉、或该版本已从
        // 源上下架）。不猜、不删、不登记，只留一条可诊断的日志。
        unmapped.add(name);
        continue;
      }
      if (known.contains(key)) continue;
      // 只有 `cover.jpg` 之类的伴随文件不算一话。
      if (_pageIndexesIn(entity).isEmpty) continue;
      added.add(key);
    }

    if (unmapped.isNotEmpty) {
      Log.warning(
        "LocalManager",
        "Chapter director${unmapped.length == 1 ? 'y' : 'ies'} on disk with no "
        "matching chapter version (left unregistered): ${unmapped.join(', ')}",
      );
    }
    if (added.isEmpty) return 0;

    known.addAll(added);
    _writeComic(row, row.id, known.toList(), chapters: chapters);
    notifyListeners();
    Log.info(
      "LocalManager",
      "Registered ${added.length} chapter(s) of '${row.title}' as downloaded "
      "from disk: ${added.map((k) => chapterDirectoryName(chapters, k)).join(', ')}",
    );
    return added.length;
  }

  /// 一次磁盘扫描同时做两件事：补 `missing_pages.json`（[
  /// reconcileMissingPages]）+ 把磁盘上真实存在的章节目录并回
  /// `downloadedChapters`（[reconcileDownloadedChapters]）。两者都是
  /// "磁盘 > 数据库"的自愈，调用点永远一致，合并成一个入口避免漏调。
  ///
  /// 返回是否有任何改写，供调用方决定要不要刷界面。
  Future<bool> reconcileDiskState(LocalComic comic) async {
    final registered = await reconcileDownloadedChapters(comic);
    final recorded = await reconcileMissingPages(comic);
    return registered > 0 || recorded > 0;
  }

  /// 章节目录里实际存在的页下标（`123.webp` → 123）。非数字命名一律忽略，
  /// 所以 `cover.jpg` 之类的伴随文件不会参与连续性判断。
  static Set<int> _pageIndexesIn(Directory dir) {
    final found = <int>{};
    try {
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        final dot = name.indexOf('.');
        if (dot <= 0) continue;
        final idx = int.tryParse(name.substring(0, dot));
        if (idx != null) found.add(idx);
      }
    } catch (e, s) {
      Log.error("LocalManager", "Failed to scan ${dir.path}: $e", s);
    }
    return found;
  }
}

enum LocalSortType {
  defaultSort("default"),
  name("name"),
  nameDesc("name_desc"),
  timeDesc("time_desc"),
  timeAsc("time_asc"),
  author("author"),
  lastRead("last_read");

  final String value;

  const LocalSortType(this.value);

  static LocalSortType fromString(String value) {
    for (var type in values) {
      if (type.value == value) {
        return type;
      }
    }
    return defaultSort;
  }
}

enum LocalComicStatus {
  downloaded,
  downloading,
  notDownloaded,
}
