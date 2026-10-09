// S9.5-b · 阅读侧读工程产物 —— app 侧（持久化 + 取字节 + 定位）。
//
// 与 `studio_reader.dart` 的分工，照 `glossary_store.dart` / `glossary_store_app.dart`
// 的老办法：
//
// | 层 | 文件 | 依赖 | 为什么 |
// |---|---|---|---|
// | 纯逻辑 | `studio_reader.dart` | `dart:core` | 能在 `init()` **之前**被 headless 注入故障 |
// | app 侧 | 本文件 | Flutter / appdata / 磁盘 | 只有它碰持久化与文件系统 |
//
// 🔴 分开的**唯一理由**是 `A01 §3`：本会话没有渲染表面，所以"选哪一份产物"这个
// 判断必须能在没有 Flutter 的环境里被验证。凡是能放进纯逻辑的，都别放进来。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/foundation/chapter_directory.dart';
import 'package:mangrove/foundation/comic_type.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/translation_project/project.dart';
import 'package:mangrove/foundation/translation_project/project_bootstrap.dart';
import 'package:mangrove/foundation/translation_project/project_io.dart';
import 'package:mangrove/foundation/translation_project/result_renderer.dart';
import 'package:mangrove/foundation/translation_project/studio_reader.dart';

/// 「素材漫画的某章 → 工作室工程」绑定表的**唯一 owner**。
///
/// 照 [GlossaryStore] 的规矩：不另开一份进程内缓存，每次都从 `appdata.implicitData`
/// 重新取 —— 导入备份替换掉那份 map 之后自动就是新的，少一处"记得清缓存"。
abstract final class StudioReaderStore {
  StudioReaderStore._();

  static const String implicitKey = 'studioReaderBindings';

  /// 产物内容变更计数。
  ///
  /// 🔴 它是阅读器的**缓存失效键**。阅读器的图片 provider 一旦建成就会被
  /// Flutter 的 imageCache 记住（`ReaderImageProvider.key`），下次不会重新读盘；
  /// 所以"工作室刚重生成完 result/"这件事必须能改变那个 key，否则用户看到的
  /// 永远是旧图。`BtProjectManager` 那侧用的是 json 的 mtime（有 IO），这里用
  /// 进程内计数（零 IO，且同进程的保存/重生成必然经过本类）。
  static int _revision = 0;

  static int get revision => _revision;

  static void markArtifactsChanged() => _revision++;

  static StudioReaderBindings get bindings =>
      StudioReaderBindings.from(appdata.implicitData[implicitKey]);

  static StudioReaderBinding? bindingFor({
    required String cid,
    required String? sourceKey,
    required String eid,
  }) {
    return bindings[StudioReaderBindings.key(
      cid: cid,
      sourceKey: sourceKey,
      eid: eid,
    )];
  }

  static void put({
    required String cid,
    required String? sourceKey,
    required String eid,
    required StudioReaderBinding binding,
  }) {
    final table = bindings;
    table.put(
      StudioReaderBindings.key(cid: cid, sourceKey: sourceKey, eid: eid),
      binding,
    );
    // 🔴 写的是 `toJson()`（只含合法条目）：一次读-改-写就把损坏的条目自然清掉。
    appdata.implicitData[implicitKey] = table.toJson();
    appdata.writeImplicitData();
    markArtifactsChanged();
  }

  static void remove({
    required String cid,
    required String? sourceKey,
    required String eid,
  }) {
    final table = bindings;
    table.remove(StudioReaderBindings.key(
      cid: cid,
      sourceKey: sourceKey,
      eid: eid,
    ));
    appdata.implicitData[implicitKey] = table.toJson();
    appdata.writeImplicitData();
    markArtifactsChanged();
  }
}

/// 阅读器要显示的一页 → 工程产物的字节。
///
/// 返回 `null` 表示"没有可读产物"，调用方照旧显示原图。**绝不抛**：这里是阅读
/// 路径，一页工程的 json 坏掉不该让整章读不出来（`_decodeBounded` 那类失败在
/// 旧 `renderBtPage` 里也是同一个处理）。
abstract final class StudioReaderRenderer {
  StudioReaderRenderer._();

  /// [imagePath] 是阅读器给的图片路径（可能带 `file://`）。
  static Future<Uint8List?> render({
    required String jsonPath,
    required String imagePath,
    required String comicDirectory,
  }) async {
    final file = File(jsonPath);
    if (!file.existsSync()) return null;
    final TranslationProject project;
    try {
      project = await TranslationProjectIo.load(file);
    } catch (e, s) {
      Log.error('Studio Reader', 'load $jsonPath failed: $e', s);
      return null;
    }
    final pageKey = projectPageKeyFor(
      projectPageKeys: project.pageOrder,
      imagePath: imagePath,
      comicDirectory: comicDirectory,
    );
    if (pageKey == null) return null;
    final page = project.pages[pageKey];
    // 🔴 判据全在纯逻辑层（`chooseReaderPageSource`），这里只负责按它的结论取
    // 字节 —— 否则同一个判断会有两处实现，而只有一处能被 headless 打红。
    final source = chooseReaderPageSource(
      hasResult: project.resultPath(pageKey) != null,
      hasInpainted: project.inpaintedPath(pageKey) != null,
      hasBlocks: page?.hasTranslation ?? false,
    );
    switch (source) {
      case ReaderPageSource.original:
        return null;
      case ReaderPageSource.projectResult:
        final path = project.resultPath(pageKey);
        if (path == null) return null;
        return File(path).readAsBytes();
      case ReaderPageSource.projectRender:
        // 与工作室「保存后重生成」用的是**同一个**函数，所以阅读器看到的
        // 排版与导出/工作室预览逐像素同源。
        return renderProjectResultPage(project, pageKey);
    }
  }
}

/// 一次运行需要的定位信息（一本素材漫画的某一章）。
class StudioReaderTarget {
  const StudioReaderTarget({
    required this.comicDirectory,
    required this.chapterName,
    required this.projectName,
  });

  /// 素材原图根（`downloads/<漫画>`）—— 页键相对**这个**根。
  final String comicDirectory;

  /// 章节目录名（相对 [comicDirectory]）。无章节的漫画是空串。
  final String chapterName;

  /// 建议的工程名。
  final String projectName;

  @override
  String toString() =>
      'StudioReaderTarget($comicDirectory / "$chapterName" as "$projectName")';
}

/// 绑定与工程的实际落地（S9.5-b 的"打开开关 = 该章入队工作室管线"那一半）。
abstract final class StudioReaderLink {
  StudioReaderLink._();

  /// 从本地库定位一本素材漫画的某一章。取不到返回 null（未下载 / 目录不在）。
  ///
  /// 🔴 只接受**本地已下载**的漫画：工程要把原图**复制**进 `source/`
  /// （`ProjectBootstrap` 的硬约束 1），在线的漫画没有原图可复制。
  static StudioReaderTarget? locate({
    required String cid,
    required String sourceKey,
    required String eid,
  }) {
    final comic = LocalManager().find(cid, ComicType.local);
    if (comic == null) return null;
    final base = comic.baseDir;
    if (base.isEmpty || !Directory(base).existsSync()) return null;
    final chapters = comic.chapters;
    // 无章节的漫画：页直接躺在 `baseDir` 下，`eid` 恒为 '0'。
    var chapterName = '';
    if (chapters != null && eid != '0') {
      chapterName = chapterDirectoryName(chapters, eid);
    }
    final title = LocalManager.getChapterDirectoryName(comic.title);
    final stub = chapterName.isEmpty
        ? title
        : '$title-${LocalManager.getChapterDirectoryName(chapterName)}';
    final bounded = stub.length > 60 ? stub.substring(0, 60) : stub;
    return StudioReaderTarget(
      comicDirectory: ProjectBootstrap.normalizeDirectoryPath(base),
      chapterName: chapterName,
      projectName: bounded.isEmpty ? 'studio-project' : bounded,
    );
  }

  /// 确保 [target] 有一个工程，并把绑定写进 store。返回绑定，或**人能读的
  /// 拒绝理由**。
  ///
  /// 幂等：已经绑定过、且 json 还在 ⇒ 直接返回既有绑定，不碰磁盘。
  static Future<(StudioReaderBinding?, String?)> ensureBinding({
    required String cid,
    required String? sourceKey,
    required String eid,
    required StudioReaderTarget target,
    bool forceRescan = false,
  }) async {
    final existing = StudioReaderStore.bindingFor(
      cid: cid,
      sourceKey: sourceKey,
      eid: eid,
    );
    if (!forceRescan &&
        existing != null &&
        File(existing.jsonPath).existsSync()) {
      return (existing, null);
    }

    final projectsRoot = _projectsRoot();
    if (projectsRoot == null) {
      return (null, 'no-project-root');
    }
    final plan = ProjectBootstrap.plan(
      comicDirectory: target.comicDirectory,
      chapterName: target.chapterName,
    );
    if (plan.isEmpty) return (null, 'chapter-has-no-page');

    final result = await ProjectBootstrap.create(
      projectsRoot: projectsRoot,
      name: target.projectName,
      plan: plan,
      force: forceRescan,
    );
    if (!result.created) {
      // "已存在"不是错误：复用既有工程并绑定到它，正是我们想要的结果。
      if (result.jsonFile.existsSync()) {
        final binding = StudioReaderBinding(
          jsonPath: result.jsonFile.path,
          comicDirectory: target.comicDirectory,
          projectDirectory: '${result.root}/${ProjectBootstrap.sourceDirectoryName}',
        );
        StudioReaderStore.put(
          cid: cid,
          sourceKey: sourceKey,
          eid: eid,
          binding: binding,
        );
        return (binding, result.missingSources.isEmpty ? null : 'missing-source');
      }
      return (null, result.error ?? 'create-failed');
    }

    final binding = StudioReaderBinding(
      jsonPath: result.jsonFile.path,
      comicDirectory: target.comicDirectory,
      projectDirectory: result.sourceRoot,
    );
    StudioReaderStore.put(
      cid: cid,
      sourceKey: sourceKey,
      eid: eid,
      binding: binding,
    );
    if (result.missingSources.isNotEmpty) {
      // 复制不全是**必须上报**的：缺的那几页在工作室里显示成"没有可读页图"，
      // 而"少了几页"与"页面本来就是空的"在界面上长得一样。
      Log.warning(
        'Studio Reader',
        'Project "${target.projectName}": '
            '${result.missingSources.length} page(s) could not be copied '
            '(${result.missingSources.take(5).join(", ")})',
      );
    }
    return (binding, result.missingSources.isEmpty ? null : 'missing-source');
  }

  /// 工程应当建在哪儿（复用 `BtProjectManager` 的唯一规则，别写第二份）。
  static String? _projectsRoot() {
    final manager = LocalManager();
    if (manager.isInitialized && manager.path.isNotEmpty) {
      final parent = Directory(manager.path).parent.path;
      if (parent.isNotEmpty) {
        return '${parent.replaceAll('\\', '/')}/projects';
      }
    }
    return null;
  }
}
