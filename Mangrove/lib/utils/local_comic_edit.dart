import 'package:mangrove/foundation/chapter_directory.dart';
import 'package:mangrove/foundation/chapter_title_parser.dart';
import 'package:mangrove/foundation/comic_source/comic_source.dart';
import 'package:mangrove/foundation/comic_type.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/translation_project/finished_export.dart';
import 'package:mangrove/utils/cover_pool.dart';
import 'package:mangrove/utils/io.dart';
import 'package:mangrove/utils/local_comic_scanner.dart';

/// 本地漫画的"手动自建 / 加章 / 删章 / 换封面"数据层。
///
/// 与网络下载侧（`ImagesDownloadTask` / 源 `loadComicInfo`）完全解耦 —— 这些都是
/// **不涉及任何网络来源链接**的本地操作。新建的漫画就是库根下的一个目录，章节是
/// 它的子目录，章节目录名走全应用唯一的 [chapterDirectoryName]（带翻译组时形如
/// `<话号> [组名]`），章节矩阵用版本化 [ComicChapters] 存翻译组信息，封面按
/// `cover*` 优先、否则首章首图的规则从磁盘识别。
const _imgExtensions = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'jpe'};

/// 判断文件名是否为漫画图片（供导入过滤与阅读器读取共用同一扩展名集合）。
///
/// 导入（[addChapterToLocalComic] / [refreshLocalComicChapters]）与阅读器
/// （[getImagesForComic]）都只认这些扩展名，视频 / 压缩包等一律忽略、绝不删除，
/// 从而保持磁盘完整性。
bool isComicImageFile(String name) {
  final dot = name.lastIndexOf('.');
  return dot >= 0 &&
      _imgExtensions.contains(name.substring(dot + 1).toLowerCase());
}

bool _isImage(File file) => isComicImageFile(file.name);

/// 在库根下新建一本空白本地漫画（**无网源链接**）。
///
/// - 目录名用 [findValidDirectoryName] 取一个不与现有冲突的名字；
/// - 注册时 `chapters` 为 null（还没有任何章节）、`cover` 为空（还没图）；
/// - 之后通过 [addChapterToLocalComic] 往里加章节、自动补封面。
///
/// 返回新建的 [LocalComic]，用户取消/失败返回 null。
Future<LocalComic?> createLocalComic({
  required String title,
  String subtitle = '',
  List<String> tags = const [],
  String description = '',
}) async {
  final root = LocalManager().path;
  final safeTitle = title.trim();
  final dirName = findValidDirectoryName(root, sanitizePathSegment(safeTitle));
  final dir = Directory(FilePath.join(root, dirName));
  await dir.create(recursive: true);
  final id = LocalManager().findValidId(ComicType.local);
  final comic = LocalComic(
    id: id,
    title: safeTitle.isEmpty ? dirName : safeTitle,
    subtitle: subtitle.trim(),
    tags: List<String>.from(tags),
    directory: dirName,
    chapters: null,
    cover: '',
    comicType: ComicType.local,
    downloadedChapters: const [],
    createdAt: DateTime.now(),
    description: description,
  );
  LocalManager().add(comic, id);
  return comic;
}

/// 给一本漫画设置/替换封面图（把 [coverFile] 复制为库目录下的 `cover.jpg`）。
///
/// 用户手动丢进来的 `cover.jpg` 之所以"不被识别"，往往是因为它落在了被
/// `_copyDirectories` 误改名的 `_old` 备份目录里、或根本没进库根。这里显式
/// 落到库根并登记 `cover` 字段，保证一定生效。
Future<LocalComic?> setCoverFromFile(LocalComic comic, File coverFile) async {
  final dst = File(FilePath.join(comic.baseDir, 'cover.jpg'));
  try {
    await dst.create();
    await dst.writeAsBytes(await coverFile.readAsBytes());
  } catch (e, s) {
    Log.error('LocalComicEdit', 'Failed to set cover: $e', s);
    return null;
  }
  final updated = _copyLocalComicWith(comic, cover: 'cover.jpg');
  LocalManager().updateComicDirect(updated);
  return updated;
}

/// 复制一份 [LocalComic] 并替换个别字段。
///
/// 🔴 不要手抄 `LocalComic(...)` 构造：本文件里曾经有三处各抄一份，其中
/// `setCoverFromFile` 漏了 `source` / `updateTime`——用户先"编辑信息"填了
/// 来源和更新时间，再换一次封面，这两个字段就被静默清空了。
LocalComic _copyLocalComicWith(LocalComic comic, {String? cover}) => LocalComic(
  id: comic.id,
  title: comic.title,
  subtitle: comic.subtitle,
  tags: comic.tags,
  directory: comic.directory,
  chapters: comic.chapters,
  cover: cover ?? comic.cover,
  comicType: comic.comicType,
  downloadedChapters: comic.downloadedChapters,
  createdAt: comic.createdAt,
  description: comic.description,
  source: comic.source,
  updateTime: comic.updateTime,
);

/// 把封面切换成封面池里的某一张（P12）。
///
/// 只改本地记录里的 `cover` 指针，**不动任何文件**——池里的图本来就是候选，
/// 删一张/加一张都由用户在资源管理器里做。
Future<LocalComic?> selectCoverFromPool(
  LocalComic comic,
  String relativePath,
) async {
  if (!coverStillExists(comic.baseDir, relativePath)) return null;
  final updated = _copyLocalComicWith(comic, cover: relativePath);
  LocalManager().updateComicDirect(updated);
  return updated;
}

///
/// 不走 [scanLocalComicDirectory] —— 那个会从目录名重建**扁平**章节矩阵、把我们已经
/// 精心维护的版本化（带翻译组）矩阵冲掉。这里只读封面，绝不碰章节矩阵。
Future<String> deriveCover(String baseDir, ComicChapters? chapters) async {
  final root = Directory(baseDir);
  if (!await root.exists()) return '';
  final rootImages = <File>[];
  final chapterDirs = <Directory>[];
  Directory? coverPool;
  await for (final e in root.list()) {
    if (e is File) {
      if (_isImage(e)) rootImages.add(e);
    } else if (e is Directory) {
      // P12：封面池不是章节，不能进 chapterDirs（否则"首章首图"可能取到封面）。
      if (isCoverDirectoryName(e.name)) {
        coverPool = e;
      } else {
        chapterDirs.add(e);
      }
    }
  }
  // ① 封面池优先：多季度封面时默认用季度号最大的（最新季度）。
  if (coverPool != null) {
    final picked = await pickCoverFromPool(coverPool);
    if (picked != null) return picked;
  }
  // ② 旧布局：根目录的 `cover*` 文件。
  rootImages.sort((a, b) => a.name.compareTo(b.name));
  for (final img in rootImages) {
    if (img.name.toLowerCase().startsWith('cover')) return img.name;
  }
  if (rootImages.isNotEmpty) return rootImages.first.name;
  chapterDirs.sort((a, b) => a.name.compareTo(b.name));
  for (final d in chapterDirs) {
    final imgs = <File>[];
    await for (final e in d.list()) {
      if (e is File && _isImage(e)) imgs.add(e);
    }
    imgs.sort((a, b) => a.name.compareTo(b.name));
    if (imgs.isNotEmpty) return FilePath.join(d.name, imgs.first.name);
  }
  return '';
}

/// 重算封面，但**尊重用户手选**（P12）：旧封面文件还在就保留，只有失效才重算。
///
/// 加章、删章、刷新章节三条路径都会走到这里。少了这一层，用户从封面池里挑了
/// season(1)，只要加一章就被打回 season(2)——这种"改了又自己变回去"的 bug
/// 极难归因，所以把判断收在一个地方。
Future<String> _deriveCoverKeepSelection(
  LocalComic comic,
  ComicChapters? chapters,
) async {
  if (coverStillExists(comic.baseDir, comic.cover)) return comic.cover;
  return deriveCover(comic.baseDir, chapters);
}

/// 把 [src] 目录里的**图片文件**（不含子目录）拷贝进 [dst]。
///
/// 章节图片通常平铺在文件夹里（comix-downloader 扩展导出即如此），只拷图片、
/// 忽略嵌套子目录，避免把无关文件夹也带进来。
Future<void> _copyImages(Directory src, Directory dst) async {
  await for (final e in src.list()) {
    if (e is File && _isImage(e)) {
      final target = File(FilePath.join(dst.path, e.name));
      await target.create();
      await target.writeAsBytes(await e.readAsBytes());
    }
  }
}

/// 把 [files] 里**是图片**的文件拷进 [dst]（忽略非图片，绝不删源文件）。
///
/// 供"添加章节 → 导入多张图片"使用：用户在文件选择器里挑了若干文件，这里只认
/// 图片、跳过其它（如顺手选中的 txt），且只做复制、不触碰来源。
Future<void> _copyImageFiles(List<File> files, Directory dst) async {
  for (final f in files) {
    if (!isComicImageFile(f.name)) continue;
    final target = File(FilePath.join(dst.path, f.name));
    await target.create();
    await target.writeAsBytes(await f.readAsBytes());
  }
}

/// 把一本（可能扁平/分组/版本化/空的）漫画的章节矩阵，转成我们要维护的
/// 版本化 [Map<String, List<ComicChapterVersion>>]。
///
/// 新建漫画从 null 起；导入的扁平漫画在这里被 best-effort 升级成版本化，以便
/// "设置翻译组"的章节能正常显示翻译组 chips。转换只看话号与目录名，不引入组名。
Map<String, List<ComicChapterVersion>> _toVersionedMap(
  ComicChapters? existing,
) {
  final map = <String, List<ComicChapterVersion>>{};
  if (existing == null) return map;
  if (existing.isVersioned) {
    for (final e in existing.allVersions) {
      map.putIfAbsent(e.chapterNumber, () => []).add(e.version);
    }
  } else if (existing.isGrouped) {
    for (final groupName in existing.groups) {
      final g = existing.getGroup(groupName);
      for (final key in g.keys) {
        final num = parseChapterTitle(key).chapterNumber?.toString() ?? key;
        map.putIfAbsent(num, () => []).add(ComicChapterVersion(
              title: g[key] ?? '',
              chapterKey: sanitizePathSegment(num),
            ));
      }
    }
  } else {
    for (final key in existing.ids) {
      final num = parseChapterTitle(key).chapterNumber?.toString() ?? key;
      map.putIfAbsent(num, () => []).add(ComicChapterVersion(
            title: existing[key] ?? '',
            chapterKey: sanitizePathSegment(num),
          ));
    }
  }
  return map;
}

/// 给一本漫画新增（或合并）一个章节：来源是**图片文件夹**或**多张图片文件**，
/// 配 话号 + 翻译组。
///
/// - 维护版本化章节矩阵（带组名 → 目录名 `<话号> [组名]`）；
/// - 图片拷贝进章节目录（只认图片，忽略视频 / 压缩包，不删来源）；
/// - 自动补封面（根无 cover 时取首章首图）；
/// - 把该章计入 `downloadedChapters`（已是已下载）。
///
/// 若 [chapterNumber]+[group] 已在矩阵里，则只把图片合并进既有目录、不重复登记。
///
/// [imagesFolder] 与 [imageFiles] 二选一：前者为"导入图片文件夹"，后者为
/// "导入多张图片文件"（[selectImages] 选出来的路径列表）。
Future<LocalComic?> addChapterToLocalComic(
  LocalComic comic, {
  required String chapterNumber,
  String? group,
  Directory? imagesFolder,
  List<File>? imageFiles,
}) async {
  if (imagesFolder == null && (imageFiles == null || imageFiles.isEmpty)) {
    return null;
  }
  final g = (group != null && group.trim().isNotEmpty) ? group.trim() : null;
  final key = g != null
      ? sanitizePathSegment('$chapterNumber [$g]')
      : sanitizePathSegment(chapterNumber);

  final map = _toVersionedMap(comic.chapters);
  map.putIfAbsent(chapterNumber, () => []);
  if (!map[chapterNumber]!.any((v) => v.chapterKey == key)) {
    map[chapterNumber]!.add(ComicChapterVersion(
      scanlationGroup: g,
      title: '',
      chapterKey: key,
    ));
  }
  final newChapters = ComicChapters.versioned(map);
  final dirName = chapterDirectoryName(newChapters, key);
  final chapterDir = Directory(FilePath.join(comic.baseDir, dirName));
  await chapterDir.create(recursive: true);
  if (imagesFolder != null) {
    await _copyImages(imagesFolder, chapterDir);
  } else if (imageFiles != null) {
    await _copyImageFiles(imageFiles, chapterDir);
  }

  final cover = await _deriveCoverKeepSelection(comic, newChapters);
  final downloaded = <String>{
    ...comic.downloadedChapters,
    key,
  }.toList();

  final updated = LocalComic(
    id: comic.id,
    title: comic.title,
    subtitle: comic.subtitle,
    tags: comic.tags,
    directory: comic.directory,
    chapters: newChapters,
    cover: cover,
    comicType: comic.comicType,
    downloadedChapters: downloaded,
    createdAt: comic.createdAt,
    description: comic.description,
  );
  // [add] 会合并 downloadedChapters 且不会缩小矩阵（我们在变大），可安全复用。
  LocalManager().add(updated, comic.id);
  return updated;
}

/// 刷新一本本地漫画的章节：扫描其根目录下的子文件夹，把未被登记的章节补登。
///
/// ## 为什么需要
///
/// 用户可能**事先手动**把文件夹复制进漫画目录（而不是走「添加章节」挑文件夹）。
/// 这种场景下磁盘上已经有章、但矩阵里没有 ⇒ 阅读器看不到。点「刷新章节」即可识别新增。
///
/// ## 不破坏完整性
///
/// - **绝不删除任何文件/目录**，只注册；非图片文件（视频/压缩包）原样保留。
/// - 与导入逻辑一致：只把"有图"的文件夹认作章节，避免把无关目录登记成空章。
///
/// ## 幂等去重（"记录表"）
///
/// 已登记的章节以**目录名**为准排除（规范名 `chapterDirectoryName` + 原始 key 名都纳
/// 入），重复点刷新不会重复建章 —— 这正是 P2 那次"刷新后漫画翻倍"的根因同类问题，这里
/// 用目录名集合做幂等闸门。对每个待登记文件夹，同时按"规范名"和"原始名"比对，避免
/// "Chapter 5" 与 "5" 这类被解析成同一话号却不同目录名的重复识别。
///
/// 返回新登记的章节数（0 = 没有新增）。
Future<int> refreshLocalComicChapters(LocalComic comic) async {
  final base = Directory(comic.baseDir);
  if (!base.existsSync()) return 0;

  // 已知目录名集合（小写）：规范名 + 原始 key 名都纳入，确保幂等、不重复识别。
  final knownDirNames = <String>{};
  final existing = comic.chapters;
  if (existing != null) {
    for (final key in existing.allVersionKeys) {
      knownDirNames.add(chapterDirectoryName(existing, key).toLowerCase());
      knownDirNames.add(sanitizePathSegment(key).toLowerCase());
    }
  }

  final map = _toVersionedMap(existing);
  // P13：老记录的 title 就是目录名（`49 [Rokari Comics] [comix.to]`），顺手
  // 清洗成显示名。这不是"改名"——chapterKey 一律不动，只换展示文案。
  var relabeled = false;
  for (final versions in map.values) {
    for (var i = 0; i < versions.length; i++) {
      final version = versions[i];
      final clean = chapterDisplayName(version.chapterKey);
      if (version.title == clean) continue;
      versions[i] = ComicChapterVersion(
        scanlationGroup: version.scanlationGroup,
        title: clean,
        chapterKey: version.chapterKey,
      );
      relabeled = true;
    }
  }
  final List<String> newKeys = [];
  var added = 0;
  await for (final entry in base.list()) {
    if (entry is! Directory) continue;
    if (entry.name.startsWith('.')) continue;
    // 🔴 P12：`cover/` 是封面候选池，不是章节。漏了这一条，点一次"刷新章节"
    // 就会多出一个叫 "cover" 的假章节，点开全是封面图。
    if (isCoverDirectoryName(entry.name)) continue;
    final rawName = sanitizePathSegment(entry.name).toLowerCase();
    // 幂等闸门：该文件夹（按规范名或原始名）已登记过 ⇒ 跳过，重复刷新不重复建章。
    final canonicalName = sanitizePathSegment(
      chapterDirectoryName(existing, sanitizePathSegment(entry.name)),
    ).toLowerCase();
    if (knownDirNames.contains(rawName) ||
        knownDirNames.contains(canonicalName)) {
      continue;
    }
    // 只认"有图"的文件夹，避免把无关目录登记成空章。
    if (!await _directoryHasImage(entry)) continue;
    final key = sanitizePathSegment(entry.name);
    if (map.containsKey(key)) continue;
    map.putIfAbsent(key, () => []).add(ComicChapterVersion(
          scanlationGroup: null,
          title: entry.name,
          chapterKey: key,
        ));
    newKeys.add(key);
    added++;
  }
  // 只有显示名变了也要写回：否则这一次刷新只改了内存里的 map，磁盘记录还是
  // 旧标题（下次打开详情页又是长串目录名，看起来像"改了没生效"）。
  if (added == 0 && !relabeled) return 0;

  final newChapters = ComicChapters.versioned(map);
  final downloaded = <String>{
    ...comic.downloadedChapters,
    ...newKeys,
  }.toList();
  // P12：刷新章节不该把用户手选的封面换掉——只有旧值真的失效（那季封面
  // 被删了）时才回落到默认封面。
  final cover = await _deriveCoverKeepSelection(comic, newChapters);
  final updated = LocalComic(
    id: comic.id,
    title: comic.title,
    subtitle: comic.subtitle,
    tags: comic.tags,
    directory: comic.directory,
    chapters: newChapters,
    cover: cover,
    comicType: comic.comicType,
    downloadedChapters: downloaded,
    createdAt: comic.createdAt,
    description: comic.description,
  );
  // `add` 会合并 downloadedChapters 且不会缩小矩阵（我们在变大），可安全复用。
  LocalManager().add(updated, comic.id);
  return added;
}

/// 目录是否包含至少一张图片（仅看直接子文件，不递归 —— 与阅读器的读取口径一致：
/// 阅读器也只列章节目录的直接图片文件，嵌套子目录里的图不会被当页读出来）。
Future<bool> _directoryHasImage(Directory dir) async {
  try {
    await for (final e in dir.list()) {
      if (e is File && _isImage(e)) return true;
    }
  } catch (_) {
    return false;
  }
  return false;
}

/// 列出一本漫画当前的章节目录名（从磁盘读取，最贴近真实）。
List<String> listChapterDirectories(LocalComic comic) {
  final root = Directory(comic.baseDir);
  if (!root.existsSync()) return const [];
  final dirs = <String>[];
  for (final e in root.listSync()) {
    if (e is Directory) dirs.add(e.name);
  }
  dirs.sort();
  return dirs;
}

/// 把磁盘章节目录名反查成章节 key（用于删除）。
///
/// 优先在版本化矩阵里按目录名匹配；匹配不到（如目录名是纯话号、矩阵为 null）
/// 则退化为目录名本身（[deleteChapters] 会据此物理删除目录）。
List<String> dirNamesToChapterKeys(
  LocalComic comic,
  List<String> dirNames,
) {
  final chapters = comic.chapters;
  final keys = <String>[];
  for (final dir in dirNames) {
    var matched = false;
    if (chapters != null) {
      for (final k in chapters.allVersionKeys) {
        if (chapterDirectoryName(chapters, k) == dir) {
          keys.add(k);
          matched = true;
          break;
        }
      }
    }
    if (!matched) keys.add(sanitizePathSegment(dir));
  }
  return keys;
}

/// 删除一本漫画的若干章节（按磁盘目录名）。
///
/// - 物理删除目录；
/// - 从版本化矩阵里剔除对应版本（[LocalManager.updateComicDirect] 直写，绕过
///   "拒绝缩小"守卫，否则被删章节会在列表里阴魂不散）；
/// - 重新算封面；
/// - 若删光了且没有任何已下载章节，整卡删除；否则回写收小后的矩阵与
///   downloadedChapters。
///
/// 返回是否仍保留该漫画卡（false = 卡被整体删除）。
Future<bool> deleteChapters(
  LocalComic comic,
  List<String> dirNames,
) async {
  if (dirNames.isEmpty) return true;
  final keys = dirNamesToChapterKeys(comic, dirNames);
  // 物理删除目录（无论能否在矩阵里解析出 key，都确保磁盘上的章被删掉）。
  for (final d in dirNames) {
    await Directory(FilePath.join(comic.baseDir, d))
        .deleteIgnoreError(recursive: true);
  }

  final chapters = comic.chapters;
  ComicChapters? newChapters = chapters;
  if (chapters != null && chapters.isVersioned) {
    final map = <String, List<ComicChapterVersion>>{};
    for (final e in chapters.allVersions) {
      if (keys.contains(e.version.chapterKey)) continue;
      map.putIfAbsent(e.chapterNumber, () => []).add(e.version);
    }
    newChapters = map.isEmpty ? null : ComicChapters.versioned(map);
  } else if (chapters != null) {
    // 扁平/分组：重建时剔除被删 key。
    final kept = <String, String>{};
    for (final k in chapters.allChapters.keys) {
      if (keys.contains(k)) continue;
      kept[k] = chapters.allChapters[k]!;
    }
    newChapters = kept.isEmpty ? null : ComicChapters(kept);
  }

  final newDownloaded =
      comic.downloadedChapters.where((k) => !keys.contains(k)).toList();
  if (newDownloaded.isEmpty && newChapters == null) {
    LocalManager().removeComic(comic);
    return false;
  }

  final cover = await _deriveCoverKeepSelection(comic, newChapters);
  final updated = LocalComic(
    id: comic.id,
    title: comic.title,
    subtitle: comic.subtitle,
    tags: comic.tags,
    directory: comic.directory,
    chapters: newChapters,
    cover: cover,
    comicType: comic.comicType,
    downloadedChapters: newDownloaded,
    createdAt: comic.createdAt,
    description: comic.description,
  );
  LocalManager().updateComicDirect(updated);
  return true;
}

/// 刷新本地库时，把 `ComicLibrary/downloads/` 下**已存在但软件未登记**的素材文件夹
/// 补登记成本地漫画记录。
///
/// 这是用户痛点「Mangrove 不会把文件夹识别成漫画」的直接解法：磁盘上丢进来一个
/// 文件夹（空或有图），点刷新就能出现在本地库里。
///
/// 判据与处理：
/// - 已登记（同目录 basename 已存在 / 标题已被导入）跳过；
/// - 文件夹**有图能扫出封面** → [scanLocalComicDirectory] 取章节矩阵 + 封面后 `add`；
/// - 文件夹**为空 / 无封面** → 登记为**可填充的空漫画**（`chapters=null`、`cover=''`）。
///   正是这类空文件夹以前既进不了库、也因 `status==notDownloaded` 开不了详情页
///   （见 P1 链路修复）。
///
/// 返回新登记的文件夹数。`projects/`（工程）与 `translated/`（成品）不在此处理：
/// 前者交给 [BtProjectManager.scan]，后者由 [registerUnlistedProductFolders] 处理
/// （P6 起成品也随刷新补登记）。
Future<int> registerUnlistedDownloadFolders() async {
  final root = Directory(LocalManager().path);
  if (!await root.exists()) return 0;
  // 排除键 = 所有漫画记录的"目录 basename"（小写），**不按 comicType 过滤**。
  // 坑点：网络下载漫画的 comicType 不是 ComicType.local，若只收集本地类型，
  // 它们的磁盘文件夹会漏出 known，被当成"未登记"重新登记成 ComicType.local
  // 副本 —— 这就是刷新后漫画成倍重复的根因。bt_/ft_ 记录的目录 basename 是
  // `bt_xxx`/`ft_xxx`，不会与素材文件夹名冲突，一起纳入排除集合是安全的。
  final known = LocalManager()
      .getComics(LocalSortType.defaultSort)
      .map((c) =>
          c.directory.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last)
      .where((s) => s.isNotEmpty)
      .map((s) => s.toLowerCase())
      .toSet();
  var count = 0;
  await for (final entry in root.list()) {
    if (entry is! Directory) continue;
    if (entry.name.startsWith('.')) continue;
    // 已经登记过（按目录 basename）或已被导入（按标题）的跳过，避免重复 / 误建空壳。
    if (known.contains(entry.name.toLowerCase())) continue;
    if (LocalManager().findImportedByName(entry.name) != null) continue;

    final id = LocalManager().findValidId(ComicType.local);
    final scanned =
        await scanLocalComicDirectory(entry, id: id, useRelativePath: true);
    LocalComic comic;
    if (scanned != null) {
      comic = scanned;
    } else {
      // 空文件夹 / 无封面：登记为可填充空漫画，让用户能进详情页往里加章节。
      comic = LocalComic(
        id: id,
        title: entry.name,
        subtitle: '',
        tags: const [],
        directory: entry.name,
        chapters: null,
        cover: '',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: DateTime.now(),
        description: '',
      );
    }
    LocalManager().add(comic, id);
    count++;
  }
  return count;
}

/// 刷新本地库时，把 `ComicLibrary/translated/` 下**已存在但软件未登记**的成品文件夹
/// 补登记成 `ft_` 成品记录（P6）。
///
/// ## 为什么成品也要登记
///
/// 成品（`ft_<hash>`）过去**只在导出那一刻**登记（`FinishedExport._register`）。
/// 于是这些情况下成品会从本地库"消失"：
/// * 换了设备 / 重装了软件（`local.db` 没了，磁盘上的成品还在）；
/// * 用户在资源管理器里把 `translated/` 整个搬过来；
/// * 记录被误删。
///
/// 素材有 `registerUnlistedDownloadFolders` 兜底，成品却没有 —— 这就是 P2 留下的
/// "留待 Phase 6 统一适配 `ft_` 前缀与成品详情"那笔账。
///
/// ## id 必须与导出时**逐字节一致**
///
/// id 由 `FinishedExport.idFor(目录绝对路径)` 决定，而导出时算的是
/// `Directory('<translatedRoot>/<漫画名>').path`。这里必须用**同一个函数**、**同一个
/// 路径形态**（`Directory.path`，Windows 上是反斜杠）—— 算出来的 id 差一个字符，
/// 成品就会在库里变成"两张卡"（导出登记的那张 + 刷新补登记的这张）。
///
/// 返回新登记的成品数。
Future<int> registerUnlistedProductFolders() async {
  final libraryRoot = LocalManager().path;
  if (libraryRoot.isEmpty) return 0;
  final root = Directory(
    FilePath.join(Directory(libraryRoot).parent.path, 'translated'),
  );
  if (!await root.exists()) return 0;
  final manager = LocalManager();
  var count = 0;
  await for (final entry in root.list()) {
    if (entry is! Directory) continue;
    if (entry.name.startsWith('.')) continue;
    // 🔴 id 用**导出时那个函数**算，路径形态也一致（`Directory.path`）。
    final id = FinishedExport.idFor(entry.path);
    final previous = manager.find(id, ComicType.local);
    // 已有记录 ⇒ 刷新它（成品可能新增了章节），不算"新登记"。
    final scanned = await scanLocalComicDirectory(
      entry,
      previous: previous,
      id: id,
      title: previous?.title ?? FinishedExport.titleFor(entry.name),
      subtitle: previous?.subtitle,
      tags: previous?.tags ?? const ['Translated'],
      // `rejectExisting: false` —— 与导出登记同一条：成品与素材同名是正常的
      // （"X · 翻译版"），不能被扫描器的重名守卫挡下。
      rejectExisting: false,
    );
    // 扫不出来（没有封面 / 章节目录里有子目录）⇒ 这不是一个能读的成品，跳过。
    if (scanned == null) continue;
    await manager.add(scanned, id);
    if (previous == null) count++;
  }
  if (count > 0) {
    Log.info('LocalComicEdit', 'Registered $count finished product(s).');
  }
  return count;
}

/// 清理 `downloads/` 下"同一磁盘文件夹被多条记录引用"的重复记录。
///
/// 只删数据库记录、**绝不删磁盘目录**（副本与原记录共用同一文件夹，误删目录会
/// 把原记录的图一起干掉）。判定规则：
/// - 按目录 basename（不区分大小写）分组；
/// - 组内存在非本地（网络下载）记录 → 该组所有 `ComicType.local` 副本都是刷新
///   产生的多余壳，删之，文件夹由网络记录继续持有；
/// - 组内全是本地记录（理论上不会，因文件夹名在磁盘上唯一）→ 保最"重"的一条
///   （章节多 / 有封面 / id 最小），删其余。
///
/// 返回清理掉的记录数。刷新入口应先调用本函数再扫描，使重复可自愈。
Future<int> dedupeDownloadFolderRecords() async {
  final all = LocalManager().getComics(LocalSortType.defaultSort);
  final groups = <String, List<LocalComic>>{};
  for (final c in all) {
    final base = c.directory
        .split(RegExp(r'[/\\]'))
        .where((s) => s.isNotEmpty)
        .last
        .toLowerCase();
    if (base.isEmpty) continue;
    (groups[base] ??= []).add(c);
  }
  final toRemove = <LocalComic>[];
  for (final group in groups.values) {
    if (group.length < 2) continue;
    final nonLocal = group.where((c) => c.comicType != ComicType.local).toList();
    if (nonLocal.isNotEmpty) {
      toRemove.addAll(group.where((c) => c.comicType == ComicType.local));
    } else {
      LocalComic keep = group.first;
      for (final c in group.skip(1)) {
        final dKeep = keep.downloadedChapters.length + (keep.cover.isNotEmpty ? 1 : 0);
        final dC = c.downloadedChapters.length + (c.cover.isNotEmpty ? 1 : 0);
        if (dC > dKeep || (dC == dKeep && c.id.compareTo(keep.id) < 0)) {
          keep = c;
        }
      }
      toRemove.addAll(group.where((c) => c.id != keep.id));
    }
  }
  if (toRemove.isNotEmpty) {
    // removeFileOnDisk=false：只删记录，保文件夹；removeFavoriteAndHistory=false：不动原记录收藏/历史。
    LocalManager().batchDeleteComics(toRemove, false, false);
    Log.info(
      'LocalComicEdit',
      'Deduped ${toRemove.length} duplicate record(s) by folder.',
    );
  }
  return toRemove.length;
}
