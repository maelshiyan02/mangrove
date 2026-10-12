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
import 'package:mangrove/foundation/bt_project/bt_project_manager.dart';
import 'package:mangrove/foundation/chapter_directory.dart';
import 'package:mangrove/foundation/comic_type.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/translation_project/edit_command.dart';
import 'package:mangrove/foundation/translation_project/glossary_scope.dart';
import 'package:mangrove/foundation/translation_project/project.dart';
import 'package:mangrove/foundation/translation_project/project_bootstrap.dart';
import 'package:mangrove/foundation/translation_project/project_io.dart';
import 'package:mangrove/foundation/translation_project/project_writer.dart';
import 'package:mangrove/foundation/translation_project/result_renderer.dart';
import 'package:mangrove/foundation/translation_project/studio_project_entry.dart';
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
    // 🔴 绑定表是「磁盘上有这么个工程」的**缓存**，磁盘才是真相。工程被删除之后
    // （应用内删 / 资源管理器里删 / 同步覆盖），表里那条会变成幽灵：创建向导据此
    // 把这一章判成"已有工程"，把用户挡在创建门外；点【创建】弹的是"已打开既有
    // 工程"、工程文件夹为空、跳转按钮永不亮 —— 而磁盘上明明已经删干净了。
    // 所以每次取绑定都当场用磁盘核一遍（判据在纯逻辑层 `liveBindingFor`，这里
    // 只负责喂 IO）。
    return bindings.liveBindingFor(
      StudioReaderBindings.key(cid: cid, sourceKey: sourceKey, eid: eid),
      jsonExists: (path) => File(path).existsSync(),
    );
  }

  /// 这一本漫画已经绑过工程的 `eid` 集合。见 [StudioReaderBindings.eidsFor]。
  static Set<String> eidsFor({
    required String cid,
    required String? sourceKey,
  }) => bindings.eidsFor(cid: cid, sourceKey: sourceKey);

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

  /// 清掉**所有**指向 [jsonPath] 的绑定，返回删掉的条数。工程被删除时调用。
  ///
  /// 🔴 与 [bindingFor] 的磁盘校验是**两件**必须都做的事：
  /// * 校验让幽灵绑定**读不出来**（挡住"已有工程"的误判，也挡住绕开删除路径的
  ///   丢失：用户在资源管理器里直接删文件夹）；
  /// * 本方法把它**从表里删掉**（否则死条目会无限积累，并在导入/导出备份里跟着
  ///   走，还会让 `eidsFor` 之类的批量判断把"早就删掉的章"算成已处理）。
  static int removeForJsonPath(String jsonPath) {
    final table = bindings;
    final removed = table.removeForJsonPath(jsonPath);
    if (removed.isEmpty) return 0;
    appdata.implicitData[implicitKey] = table.toJson();
    appdata.writeImplicitData();
    markArtifactsChanged();
    return removed.length;
  }

  /// **工程 json → 它的来源身份**（术语表 scope + 翻译组）。
  ///
  /// 工作室那一侧的唯一入口：它手里只有工程 id（`bt_<hash>`），而工程 json 是
  /// FT 兼容格式、顶层键序被断言锁死（`headless_p3_checks` 的
  /// `key_order_matches_ft`）⇒ 来源只能记在绑定表里。
  ///
  /// 返回 null = 这条工程没有绑定（本表出现之前建的老工程，或者没经阅读器开关
  /// 建的工程）。**调用方必须显式处理这个 null**，回落到 `comicId` —— 回落
  /// 成一个"看起来正常但另一份"的 scope，正是这次要消灭的那种分裂。
  static (String scope, String group)? originForProject(String jsonPath) {
    final binding = bindings.forJsonPath(jsonPath);
    if (binding == null || binding.originScope.isEmpty) return null;
    return (binding.originScope, binding.group);
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

/// 一章在**工作室工程**里有成品的页数（判据侧见
/// `chapter_translation_state.dart`）。
///
/// 这是 S9.5-b 半迁移的读取侧：详情页原先只读旧 `TranslationStore`，而工作室
/// 管线一行都不写它 —— 于是工作室翻完的章在章节列表里**看不到**已翻译标记。
abstract final class StudioChapterProductCount {
  StudioChapterProductCount._();

  /// 素材漫画 `cid@sourceKey` 的**每一章**（`eid` → 工程成品页数）。
  ///
  /// 🔴 与绑定存活判定走**同一个** `bindingFor`（它内部已校验 json 在盘上），
  /// 所以"绑定在但工程被删"的那一章不进结果集 ⇒ 不会被算成已翻译。
  static Future<Map<String, int>> forComic({
    required String cid,
    required String? sourceKey,
  }) async {
    final out = <String, int>{};
    final eids = StudioReaderStore.bindings.eidsFor(
      cid: cid,
      sourceKey: sourceKey,
    );
    for (final eid in eids) {
      final count = await forChapter(
        cid: cid,
        sourceKey: sourceKey,
        eid: eid,
      );
      if (count > 0) out[eid] = count;
    }
    return out;
  }

  /// 单章的工程成品页数。绑定不存在 / json 不在 / 读坏 ⇒ **0**（不是抛）。
  ///
  /// 🔴 只数**两种**成品，缺一不可：
  /// - `result/` 位图（用户能直接看到的成品）；
  /// - 带译文的块（工程 json 里 `hasTranslation`）。
  ///
  /// 只数后者的话，一页都没跑管线就被手工填了块的工程会被算成已翻译；只数前者
  /// 的话，"刚跑完识别还没出图"的中间态会闪一下未翻译。两者取并集 = 用户看得见
  /// 成品、或工程里确实写着译文，就算这一页翻过了。
  static Future<int> forChapter({
    required String cid,
    required String? sourceKey,
    required String eid,
  }) async {
    final binding = StudioReaderStore.bindingFor(
      cid: cid,
      sourceKey: sourceKey,
      eid: eid,
    );
    if (binding == null) return 0;
    final file = File(binding.jsonPath);
    if (!file.existsSync()) return 0;
    final TranslationProject project;
    try {
      project = await TranslationProjectIo.load(file);
    } catch (e, s) {
      Log.error(
        'Studio Reader',
        'load ${binding.jsonPath} failed: $e',
        s,
      );
      return 0;
    }
    var count = 0;
    for (final pageKey in project.pageOrder) {
      final page = project.pages[pageKey];
      if (page?.hasTranslation ?? false) count++;
      // `resultPath` 内部已判存在性；对没有块的页给出成品位图同样算数
      // （例如块被清空后只剩上一轮出图）。
      else if (project.resultPath(pageKey) != null) count++;
    }
    return count;
  }

  /// 清掉一章的**工作室侧**成品：工程里每一页的译文块 + `mask/`/`inpainted/`/
  /// `result/` 产物。
  ///
  /// 🔴 这是 S9.5-b 半迁移的**写侧**缺口：`ImageTranslationService.retranslate`
  /// 只清 `TranslationStore` + 渲染缓存，**一行都不碰工程** —— 于是详情页
  /// 「删除译文」在工作室翻过的章上会**点了没反应**，而
  /// `result/` 里的成品还好好躺着，阅读器继续显示它。
  ///
  /// 🔴 落地必须走 `captureBlockListEdit` + `ProjectWriter.save`（硬规矩 3）：
  /// 直接 `rawBlocks.clear()` 就绕过了脏页登记，`result/` 的增量重渲会漏页，
  /// 而且**下一次工作室打开**会把内存里的旧块写回去（用户会以为删除失败）。
  ///
  /// 返回被清掉的页数。没有绑定 / json 不在 ⇒ **0**（不是抛：调用方要清的是
  /// "这一章的译文"，工程不在就等于没有可清的）。
  static Future<int> clearChapter({
    required String cid,
    required String? sourceKey,
    required String eid,
  }) async {
    final binding = StudioReaderStore.bindingFor(
      cid: cid,
      sourceKey: sourceKey,
      eid: eid,
    );
    if (binding == null) return 0;
    final file = File(binding.jsonPath);
    if (!file.existsSync()) return 0;
    final TranslationProject project;
    try {
      project = await TranslationProjectIo.load(file);
    } catch (e, s) {
      Log.error('Studio Reader', 'load ${binding.jsonPath} failed: $e', s);
      return 0;
    }
    final history = EditHistory();
    var cleared = 0;
    for (final pageKey in project.pageOrder) {
      final page = project.pages[pageKey];
      if (page == null || page.rawBlocks.isEmpty) {
        // 没有块也要删产物：一页可能只剩上一轮出图的 `result/`。
        await ProjectWriter.deletePageArtifacts(
          project.workspace,
          pageKey,
        );
        continue;
      }
      // 走 capture：块清空是一次真实的编辑，必须能被 Undo 撤销，也能被
      // 脏页追踪看见（`history.dirtyPages`）。
      final command = captureBlockListEdit(
        page.rawBlocks,
        page.rawBlocks.clear,
        pageKey: pageKey,
        label: 'Clear chapter',
      );
      history.push(command);
      cleared++;
      await ProjectWriter.deletePageArtifacts(
        project.workspace,
        pageKey,
      );
    }
    if (cleared == 0) return 0;
    await ProjectWriter.save(
      root: project.workspace,
      project: project,
      keepBackup: true,
    );
    history.markSaved();
    StudioReaderStore.markArtifactsChanged();
    return cleared;
  }
}

/// 一次运行需要的定位信息（一本素材漫画的某一章）。
class StudioReaderTarget {
  const StudioReaderTarget({
    required this.comicDirectory,
    required this.chapterName,
    required this.projectName,
    this.group = glossarySharedGroup,
  });

  /// 素材原图根（`downloads/<漫画>`）—— 页键相对**这个**根。
  final String comicDirectory;

  /// 章节目录名（相对 [comicDirectory]）。无章节的漫画是空串。
  final String chapterName;

  /// 建议的工程名。
  final String projectName;

  /// 这一章的翻译组（comix.to 这类版本化源才有；其余恒为空串）。
  ///
  /// 与 [chapterName] 同源同序地算出来，因为两者都是"这一章是谁"的一部分：
  /// 分开算会让一个用 `preferDownloaded` 后的序、一个用原始序，落到不同的版本。
  final String group;

  @override
  String toString() =>
      'StudioReaderTarget($comicDirectory / "$chapterName" as "$projectName"'
      '${group.isEmpty ? '' : ' @$group'})';
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
    // 🔴 不能写死 `ComicType.local`：从网络源（如 comix.to）下载到本地的漫画，
    // 它在 `local.db` 里的 `comic_type` 是**源类型整数**（例如 `496108553`），
    // 不是 0。写死 local 会让 `LocalManager().find` 的精确匹配永远失败 ⇒ 明明
    // downloads 里躺着原件，却报"本地没有这本漫画的副本"，删除工程后无法重建。
    // 类型从 `sourceKey` 重建（`'local'`→local；`'comix_to'`→496108553），并保留
    // `local` 兜底（本地导入的漫画、sourceKey 归一化为空时都落到 local）。
    final type = ComicType.fromKey(sourceKey);
    var comic = LocalManager().find(cid, type);
    if (comic == null && type != ComicType.local) {
      comic = LocalManager().find(cid, ComicType.local);
    }
    if (comic == null) return null;
    final base = comic.baseDir;
    if (base.isEmpty || !Directory(base).existsSync()) return null;
    final chapters = comic.chapters;
    // 无章节的漫画：页直接躺在 `baseDir` 下，`eid` 恒为 '0'。
    var chapterName = '';
    if (chapters != null && eid != '0') {
      chapterName = chapterDirectoryName(chapters, eid);
    }
    // 🔴 与 `chapterName` **同一份** `chapters`（即 `preferDownloaded` 之后的
    // 那一份）上取组名。若另取一份"原始序"的 chapters，用户下载的是非首选组时
    // 会拿到目录名与组名对不上的一对。
    final group = glossaryGroupOf(
      chapters?.versionEntryOf(eid)?.version.scanlationGroup,
    );
    // 🔴 工程名与「创建翻译工程」入口走**同一个函数**（`studioProjectNameFor`）。
    // 内联一份在这里，入口再算一份，两者迟早会漂移 —— 而漂移的后果是同一章
    // 建出两个工程、术语表也分家，界面上完全看不出来。
    return StudioReaderTarget(
      comicDirectory: ProjectBootstrap.normalizeDirectoryPath(base),
      chapterName: chapterName,
      projectName: studioProjectNameFor(
        comicTitle: comic.title,
        chapterName: chapterName,
      ),
      group: group,
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
    final originScope = glossaryScopeOf(cid: cid, sourceKey: sourceKey);
    StudioReaderBinding bindingFor(String jsonPath, String projectDirectory) =>
        StudioReaderBinding(
          jsonPath: jsonPath,
          comicDirectory: target.comicDirectory,
          projectDirectory: projectDirectory,
          originScope: originScope,
          group: target.group,
        );

    final existing = StudioReaderStore.bindingFor(
      cid: cid,
      sourceKey: sourceKey,
      eid: eid,
    );
    if (!forceRescan &&
        existing != null &&
        File(existing.jsonPath).existsSync()) {
      // 老绑定（在本表加 `originScope`/`group` 之前写的）在这里就地补齐 —— 不
      // 补的话工作室永远回落到 `comicId`，而这条绑定看上去完全可用。
      if (existing.originScope.isEmpty) {
        final upgraded = bindingFor(
          existing.jsonPath,
          existing.projectDirectory,
        );
        StudioReaderStore.put(
          cid: cid,
          sourceKey: sourceKey,
          eid: eid,
          binding: upgraded,
        );
        return (upgraded, null);
      }
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
        final binding = bindingFor(
          result.jsonFile.path,
          '${result.root}/${ProjectBootstrap.sourceDirectoryName}',
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

    final binding = bindingFor(result.jsonFile.path, result.sourceRoot);
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
  ///
  /// 🔴 这里原先内联了一份"`LocalManager.path` 的上一级 + `/projects`"。它与
  /// `BtProjectManager.defaultProjectsRoot()` **几乎**一样，只差最后一步：
  /// 本地库没初始化时那一份会回落到 `btProjectRoot` 的第一个根，而内联的这份
  /// 直接返回 null ⇒ 一个已经配好工程根的环境会被报成 `no-project-root`。
  /// 两处各写一遍的规律就是"几乎一样" —— 差的那一点正好是最难查的。
  static String? _projectsRoot() => BtProjectManager.defaultProjectsRoot();
}
