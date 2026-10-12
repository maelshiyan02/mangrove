// 本地库「删除」的**判据**与**磁盘路径解析**（S9.6）。
//
// ## 为什么单独一个文件
//
// 三类卡片的"记录"与"文件"根本不在一个地方：
//
// | 卡片 | 记录在哪 | 文件在哪 | 「只删记录」之后 |
// |---|---|---|---|
// | 素材 `downloads/<名>` | `local.db` 的一行 | 相对 `<library>/<directory>` | 真的没了 |
// | 工程 `projects/<名>` | **就是磁盘上的 `imgtrans_*.json`** | 工程根目录 | **下次扫描原地复活** |
// | 成品 `translated/<名>` | `local.db` 的一行 | 绝对 `<directory>` | 真的没了 |
//
// 第二行是工程卡独有的：`BtProjectManager.scan()` 每次启动都会按 `imgtrans_*.json`
// 重建那一行（见 `_registerLocal`）。所以"只删记录"对工程卡是**不成立**的 ——
// 用户会反复删同一本工程，每次都显示成功，下次打开又回来了。这件事必须在弹窗里
// 说出来（[comicRecordReturnsAfterDelete]），而不是让用户自己发现。
//
// ## 🔴 老的按盘删除对后两类是**静默失效**的
//
// `LocalManager.batchDeleteComics(..., removeFileOnDisk: true)` 一律
// `Directory(FilePath.join(path, c.directory))`，而 `path.join` 遇到绝对路径
// **不会**覆盖前一段 —— `join('…/ComicLibrary/downloads', 'D:/x/projects/p')`
// 拼出一个不存在的路径（`…/downloads/D:/x/projects/p`），`existsSync()` 为假
// ⇒ 目录静静地留在磁盘上，而记录已经没了。用户看到的是"删掉了"，实际上文件夹
// 还在。所以"彻底删除"必须走本文件的 [comicOnDiskRoot]，不能复用那条 join。
//
// ## 🔴 宁可不删，也不删过头
//
// [comicOnDiskRoot] 的输入全部来自数据库 / 工程 json。任何一个字段为空或异常
// 都会让 `join(root, '')` 变成 **`root` 本身** —— 那是整个漫画库。所以落盘之前
// 一律过 [comicRootIsSafeToDelete]：必须是漫画库所在目录的**真后代**，且不是
// 三个分类根（downloads / projects / translated）本身。
library;

import 'dart:async';
import 'dart:io';

import 'package:mangrove/foundation/bt_project/bt_project_manager.dart';
import 'package:mangrove/foundation/comic_card_kind.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/translation_project/studio_reader_app.dart';
import 'package:path/path.dart' as p;

/// 一次删除的范围 —— 就是弹窗里那个勾选框的两种状态。
enum ComicDeletionScope {
  /// 只删 mangrove 里的记录，磁盘上的文件原样保留。
  recordsOnly,

  /// 记录 + 磁盘文件一起删（弹窗里勾上「同时删除磁盘上的文件」）。
  recordsAndFiles,
}

/// 一张卡的"记录"存在哪。见文件头表格。
enum ComicRecordHome {
  /// `local.db` 的 `comics` 表：删了就没了。
  database,

  /// 磁盘上的 `imgtrans_*.json`：删了会被下一次扫描重建。
  projectJson,
}

ComicRecordHome comicRecordHomeOf(ComicCardKind kind) =>
    kind == ComicCardKind.project
    ? ComicRecordHome.projectJson
    : ComicRecordHome.database;

/// 删掉记录之后，它会不会**自己回来**。
///
/// 只有工程卡会（见 [ComicRecordHome.projectJson]）。弹窗据此给一句警告。
bool comicRecordReturnsAfterDelete(ComicCardKind kind) =>
    comicRecordHomeOf(kind) == ComicRecordHome.projectJson;

/// 一张卡在磁盘上的**根目录**；解析不出来时返回 `null`（那就不删文件）。
///
/// 三类各自的判据不同，不能只用 `c.directory`：
///
/// * 素材：`c.directory` 是**相对**下载根的名字（`My Dragon Girlfriend…`）；
/// * 工程：`c.directory` 是工程**内部**那份原图副本（`projects/<名>/source`），
///   删它只会把工程弄残 —— 真正该删的是 `imgtrans_*.json` 的**父目录**
///   （`projects/<名>`，里面有 json + source/ + mask/ + inpainted/ + result/）；
/// * 成品：`c.directory` 就是发布时写进去的**绝对**路径。
String? comicOnDiskRoot(LocalComic comic) {
  switch (comicCardKindOf(comic.id)) {
    case ComicCardKind.project:
      final json = BtProjectManager().projectFor(comic.id)?.jsonFile;
      if (json == null) return null;
      return json.parent.path;
    case ComicCardKind.product:
    case ComicCardKind.downloaded:
      final dir = comic.directory;
      if (dir.trim().isEmpty) return null;
      if (p.isAbsolute(dir)) return p.normalize(dir);
      final root = LocalManager().path;
      if (root.isEmpty) return null;
      return p.normalize(p.join(root, dir));
  }
}

/// 磁盘上**绝不**允许被这条删除路径碰到的目录：漫画库自身、它上面任何一层、
/// 以及三个分类根。
///
/// 单独抽出来是为了能被 headless 直接喂故障（见 `headless_p9_checks.dart` 的
/// `deletion.refuses_the_library_root`）。
Set<String> reservedComicLibraryPaths({String? libraryRoot}) {
  final root = libraryRoot ?? LocalManager().path;
  if (root.isEmpty) return const {};
  final norm = p.normalize(root);
  return {
    // 漫画库自身。`join(root, '')` 会算成它 —— 那就是"删掉整个库"。
    norm,
    // 它上面每一层，一直到最后都不许动。
    for (var dir = p.dirname(norm); p.dirname(dir) != dir; dir = p.dirname(dir))
      dir,
    // 三个分类根：它们是**容器**，不是某一本漫画。
    p.join(p.dirname(norm), 'projects'),
    p.join(p.dirname(norm), 'translated'),
    p.join(p.dirname(norm), 'exports'),
  };
}

/// [root] 是否可以被安全删除。
///
/// 三条：非空、存在、且**不是** [reservedComicLibraryPaths] 里的任何一个。
bool comicRootIsSafeToDelete(String root, {String? libraryRoot}) {
  if (root.trim().isEmpty) return false;
  final norm = p.normalize(root);
  if (reservedComicLibraryPaths(libraryRoot: libraryRoot).contains(norm)) {
    return false;
  }
  // 再挡一道：必须是漫画库的**后代**。路径形态千奇百怪（相对/绝对/大小写），
  // 只靠上面那份集合挡不住 `../` 这类写法。
  //
  // 🔴 两条路径里只要有一条不是绝对路径就**拒绝**：相对路径下 `isWithin` 的
  // 结果取决于"当前工作目录"，而当前工作目录在桌面应用里是会变的 ——
  // 一个会随 CWD 改变的安全判据等于没有判据。拒绝的代价只是"这次不删文件"，
  // 而放开它的代价是"某次删掉了漫画库"。
  final lib = libraryRoot ?? LocalManager().path;
  if (lib.isEmpty) return false;
  final libNorm = p.normalize(lib);
  if (!p.isAbsolute(libNorm) || !p.isAbsolute(norm)) return false;
  return p.isWithin(p.dirname(libNorm), norm);
}

/// 一次删除的结果 —— 界面据此**如实**报一句，而不是笼统的"已删除"。
class ComicDeletionReport {
  const ComicDeletionReport({
    required this.recordsRemoved,
    required this.dirsRemoved,
    required this.dirsRefused,
    required this.dirsMissing,
  });

  /// 从 `local.db` 删掉的行数。
  final int recordsRemoved;

  /// 真正交给磁盘的目录数（异步删除，返回时可能还在删）。
  final int dirsRemoved;

  /// 被 [comicRootIsSafeToDelete] 拒绝的目录（绝不删，但要告诉用户）。
  final List<String> dirsRefused;

  /// 记录指向的目录本来就不存在（记录是残留的）。
  final List<String> dirsMissing;

  bool get anythingRefused => dirsRefused.isNotEmpty;
}

/// 执行一次本地库删除。
///
/// 顺序刻意是**先删记录、再删目录**（与 [LocalManager.batchDeleteComics] 一致）：
/// 记录是事务性的、瞬时的；目录删除在桌面是同步的 `deleteSync`，几百 MB 的
/// 工程会让界面卡住。先把记录落定，界面立刻刷新，文件在后面慢慢消失。
///
/// 🔴 `removeFileOnDisk` 一律传 `false` 给 [LocalManager.batchDeleteComics]：
/// 它那条 join 对工程/成品是错的（见文件头），目录由本函数自己按种类解析。
ComicDeletionReport deleteLocalComics(
  List<LocalComic> comics, {
  required ComicDeletionScope scope,
  bool removeFavoriteAndHistory = true,
}) {
  final dirs = <Directory>[];
  final refused = <String>[];
  final missing = <String>[];
  // 工程卡被删时**顺带**要清的阅读器绑定（`studioReaderBindings`）。绑定表是
  // "磁盘上有这么个工程"的缓存，工程没了、缓存也必须没 —— 否则它下一次会在
  // `创建翻译工程` 里以"这一章已有工程"的身份把用户挡回去（P14 那个 bug）。
  // 🔴 在删目录**之前**取：`projectFor` 读的是内存里的扫描结果，而下面那次
  // `scan()` 会把它清掉。
  final deletedProjectJsons = <String>[];

  if (scope == ComicDeletionScope.recordsAndFiles) {
    for (final comic in comics) {
      if (comicCardKindOf(comic.id) == ComicCardKind.project) {
        final json = BtProjectManager().projectFor(comic.id)?.jsonFile.path;
        if (json != null) deletedProjectJsons.add(json);
      }
      final root = comicOnDiskRoot(comic);
      if (root == null) continue;
      if (!comicRootIsSafeToDelete(root)) {
        refused.add(root);
        continue;
      }
      if (!Directory(root).existsSync()) {
        missing.add(root);
        continue;
      }
      dirs.add(Directory(root));
    }
  }

  final manager = LocalManager();
  final before = comics.length;
  manager.batchDeleteComics(comics, false, removeFavoriteAndHistory);

  // 清绑定：**只**在"记录 + 文件一起删"时做。只删记录时工程目录还在，绑定依然
  // 指着一个存在的 json，清了反而会让工作室失去这条来源身份（术语表 scope）。
  for (final json in deletedProjectJsons) {
    StudioReaderStore.removeForJsonPath(json);
  }

  if (dirs.isNotEmpty) {
    LocalManager.deleteDirectories(dirs);
  }

  // 工程卡的注册是**扫描出来的**，不是我们写进去的：文件删掉之后必须让扫描器
  // 重新走一遍，否则 `bt_` 那一行会以"json 不见了"的理由被它自己清掉之前，
  // 一直挂在内存里（工程列表页还会显示它）。反过来，只删记录的场合**不能**扫
  // —— 那正好会把我们刚删掉的那一行原样恢复（`comicRecordReturnsAfterDelete`）。
  if (scope == ComicDeletionScope.recordsAndFiles &&
      comics.any((c) => comicCardKindOf(c.id) == ComicCardKind.project)) {
    unawaited(BtProjectManager().scan());
  }

  return ComicDeletionReport(
    recordsRemoved: before,
    dirsRemoved: dirs.length,
    dirsRefused: refused,
    dirsMissing: missing,
  );
}
