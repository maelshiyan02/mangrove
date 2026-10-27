// 翻译工程 ↔ 来源漫画的**显式归属**边车文件。
//
// ## 为什么是单独的边车，而不是写进 `imgtrans_*.json`
//
// `imgtrans_*.json` 的顶层键序被 `headless_p3_checks` 的 `key_order_matches_ft`
// 逐键锁死（与 Fan Translation 工具对齐）。往里塞一个 `comicId` 顶层键会立刻让
// 那个断言失败、且破坏"读回再存一次零字节 diff"的契约。所以归属信息只能放在**工程
// 目录里另一份文件**里，与 `ArtifactReconciliation` 的 `.artifacts.json` 同一条思路。
//
// ## 这份文件存在的唯一理由
//
// P4（翻译工程详情页）过去按 `subtitle` 隐式归类：`subtitle` 取的是工程 json 的
// **祖父目录名**，而 `ProjectBootstrap.create` 建出来的布局是
// `<projectsRoot>/<comicTitle>-<chapterName>/imgtrans_*.json` —— 祖父目录永远是
// `projectsRoot` 本身（"projects"），于是"同一本漫画多个工程归到一页"这个目标
// 实际上变成了"同一 root 下所有工程归到一页"，且页标题显示成 "projects"。这是
// 典型的隐式归类漂移。
//
// 本文件把"这个工程属于哪一本漫画"**显式**写下来（工程创建那一刻就写），P4 据此
// 归类、不再猜目录结构。即使将来工程布局变了，归类也不受影响。
//
// ## 与绑定表的关系
//
// 阅读器开关那条链路会把来源写进 `studioReaderBindings`（[StudioReaderStore]），
// 但那是"漫画某章 → 工程"的缓存，且老工程可能没有 `originScope`。边车是工程**自己
// 携带**的归属，不依赖任何外部表，因此是最稳的单一真相。P4 仍会把绑定表作为
// 没有边车时的兜底（见 `translation_project_detail_page.dart`）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:mangrove/foundation/log.dart';

/// 一个翻译工程对其来源漫画的显式归属。
class StudioProjectMeta {
  const StudioProjectMeta({
    required this.comicId,
    required this.comicTitle,
    required this.sourceKey,
    required this.eid,
    this.level = levelChapter,
    this.originalPath = '',
    this.cover = '',
  });

  /// 边车层级：**漫画级**工程根（`<projectsRoot>/<工程名>/`）。
  ///
  /// 🔴 P53：翻译工程是「漫画 → 章节」两级 —— 漫画级根持有一张卡片（可入合集、
  /// 详情页借用素材漫画的封面/信息），章节级子目录才是真正的翻译工程
  /// （`imgtrans_*.json` + `source/` 链接 + 产物）。两者都需要身份，所以边车
  /// 分两级写，读的时候靠这个字段区分。
  static const String levelComic = 'comic';

  /// 边车层级：**章节级**工程（`<漫画级根>/<章节键>/`）。
  static const String levelChapter = 'chapter';

  /// 见 [levelComic] / [levelChapter]。缺省 `chapter`（P53 之前的边车全是
  /// 章节/单工程级，那样才读得回来）。
  final String level;

  /// 封面文件名（相对漫画级工程根，如 `cover.webp`）。
  ///
  /// 🔴 用户的原话是「创建工程不单单是命名工程，还有配套的封面和详细信息，
  /// 这些借用已有漫画的」。单页链接省不下一个封面文件的几百 KB，却会让卡片
  /// 在素材漫画被删/移动后变成空白 —— 所以封面是**复制**，页面才是链接。
  final String cover;

  bool get isComicLevel => level == levelComic;

  /// 来源漫画在 `local.db` 里的 id（`cid`，可能是 `comix:496108553:42` 这种
  /// 网络源 id，也可能是本地导入的纯数字 id）。
  final String comicId;

  /// 来源漫画的标题（用于 P4 页标题与本地库卡片副标题的展示）。
  final String comicTitle;

  /// 来源漫画的 sourceKey（`''` 表示本地导入 / 归一化为空）。
  final String sourceKey;

  /// 绑定的章节 eid（无章节漫画恒为 `'0'`）。漫画级根用 `'0'`（它不对应任何
  /// 一章；章节级子工程各自带自己的 eid）。
  ///
  /// 原件真实目录（`<ComicLibrary>/downloads/<漫画>`）。P53 起工程 `source/`
  /// 是指向它的 junction，原件只读不写；把它写进边车，junction 坏掉也能找回
  /// 来源。（字段声明在下方，这里一并说明。）
  final String eid;

  /// 原件真实目录（`<ComicLibrary>/downloads/<漫画>`）。
  ///
  /// 🔴 P53 起翻译工程**不再复制原件**：工程 `source/` 是指向这里的 junction
  /// （目录重解析点），原图只被读取、不被写入。真实路径进边车，junction 损坏
  /// 时仍能找回来源漫画，而不必猜 `directory` 指向哪。
  final String originalPath;

  /// 边车文件名。刻意不叫 `imgtrans_*`，以免被工程扫描当成又一个工程登记。
  static const fileName = 'mangrove_project.json';

  Map<String, Object?> toJson() => {
        'comicId': comicId,
        'comicTitle': comicTitle,
        'sourceKey': sourceKey,
        'eid': eid,
        'level': level,
        if (originalPath.isNotEmpty) 'originalPath': originalPath,
        if (cover.isNotEmpty) 'cover': cover,
      };

  /// 从工程目录读取边车。目录不存在 / 文件损坏 / 缺 `comicId` ⇒ 返回 null。
  ///
  /// 🔴 任何解析失败都返回 null（**不抛**）：边车只是归类辅助，缺它最多让 P4
  /// 回落到绑定表 / `subtitle`，绝不是要让一轮扫描炸掉。
  static StudioProjectMeta? readFromProjectDir(String projectDir) {
    final dir = projectDir.replaceAll('\\', '/');
    if (dir.isEmpty) return null;
    final file = File('$dir/$fileName');
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      final id = decoded['comicId']?.toString().trim() ?? '';
      if (id.isEmpty) return null;
      final level = decoded['level']?.toString() ?? '';
      return StudioProjectMeta(
        comicId: id,
        comicTitle: decoded['comicTitle']?.toString() ?? '',
        sourceKey: decoded['sourceKey']?.toString() ?? '',
        eid: decoded['eid']?.toString() ?? '0',
        level: level == levelComic ? levelComic : levelChapter,
        originalPath: decoded['originalPath']?.toString() ?? '',
        cover: decoded['cover']?.toString() ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  /// 把边车写入工程目录。失败静默（归类兜底能接住）。
  ///
  /// 🔴 **原子写**（临时文件 + rename）：半截 JSON 解析失败 ⇒ 边车读成 null ⇒
  /// 归类静默退回到 `subtitle` 兜底 —— 而那正是本特性要消灭的东西。宁可写失败
  /// 一次（下一轮补写），也不要留下一个"看起来存在但读不出来"的文件。
  static Future<void> writeToProjectDir(String projectDir, StudioProjectMeta meta) async {
    final dir = projectDir.replaceAll('\\', '/');
    if (dir.isEmpty) return;
    try {
      final file = File('$dir/$fileName');
      final temporary = File('$dir/$fileName.$pid.tmp');
      await temporary.writeAsString(jsonEncode(meta.toJson()), flush: true);
      await temporary.rename(file.path);
    } catch (e) {
      Log.warning('StudioProjectMeta', 'write failed for $dir: $e');
    }
  }
}
