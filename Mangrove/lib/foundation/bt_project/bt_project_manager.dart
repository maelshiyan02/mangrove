import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../appdata.dart';
import '../comic_source/comic_source.dart' show ComicChapters;
import '../comic_type.dart';
import '../image_translation/page_renderer.dart';
import '../image_translation/translation_types.dart';
import '../local.dart';
import '../log.dart';
import '../path_roots.dart';
import '../../utils/file_type.dart';
import '../../utils/io.dart';
import '../chapter_title_parser.dart';
import 'bt_project.dart';
import '../translation_project/artifact_reconciliation.dart';
import '../translation_project/project.dart';
import '../translation_project/project_bootstrap.dart';
import '../translation_project/project_io.dart';
import '../translation_project/studio_project_meta.dart';

/// Registers BallonsTranslator projects as read-only local comics.
///
/// [appdata.settings['btProjectRoot']] points at BT's own workspace root (kept
/// outside the comic library so the raw-comic scanner never picks it up). A
/// scan walks that tree for `imgtrans_*.json` files — each one becomes one
/// [LocalComic] whose id carries [idPrefix] so every later decision (page
/// listing, reader rendering, delete-dialog defaults) can recognise it without
/// touching paths.
class BtProjectManager extends ChangeNotifier {
  static BtProjectManager? _instance;

  BtProjectManager._();

  factory BtProjectManager() => _instance ??= BtProjectManager._();

  static const idPrefix = 'bt_';

  /// BT artifact directories that mirror the source tree — skipping them keeps
  /// the walk from descending into hundreds of generated images.
  static const _skippedDirs = {'mask', 'inpainted', 'result', 'assets'};

  /// comicId -> parsed project. Rebuilt by [scan].
  final Map<String, BtProject> _projects = {};

  /// comicId -> imgtrans json mtime (ms), also used as the reader cache buster.
  final Map<String, int> _mtimes = {};

  /// 漫画级卡片 id -> （章节键 -> 章节工程 id）。P53 起翻译工程是两级：
  /// 网格里一张卡 = 一本漫画（漫画级根），点进详情页看章节 = 章节级工程。
  ///
  /// 🔴 为什么章节键就是**子目录名**：它既是 `imgtrans_*.json` 的所在目录，
  /// 也是源漫画里那一章的目录名（阅读键）。三者同一个字符串，才不会出现
  /// "详情页第 109 话" 点开却是第 108 话的工程。
  final Map<String, Map<String, String>> _comicChapters = {};

  /// Shared scan future. Concurrent callers (startup + local page + reader)
  /// all await the SAME scan instead of one of them getting an empty "done"
  /// while another walk is still in flight.
  Future<void>? _scanFuture;

  /// The configured workspace root; empty disables the feature.
  ///
   /// Kept for callers that only need one path (settings UI, diagnostics). New
   /// code should use [roots]: a studio project lives in `ComicLibrary/projects`
   /// while an old in-place FT project still sits next to its images in
   /// `ComicLibrary/downloads`, and pointing the setting at either one alone
   /// means the other becomes invisible.
  static String get root =>
      (appdata.settings['btProjectRoot'] as String? ?? '').trim();

  /// Every configured root. Semicolon-separated so the setting stays a plain
  /// string and an existing single-path value keeps working untouched.
  ///
  /// Each entry is resolved through [PathRoots] so a moved project folder
  /// self-heals: absolute roots that still exist win; roots that disappeared
  /// are rebased onto the portable root's `ComicLibrary/projects`; entries
  /// stored in portable-relative form (`ComicLibrary/projects`) are replayed
  /// against the current portable root. When the library lives in the portable
  /// layout but the setting is empty, the sibling `projects` root is added
  /// automatically so a fresh checkout needs zero configuration.
  static List<String> get roots {
    final raw = appdata.settings['btProjectRoot'];
    final result = <String>[];
    void addDistinct(String candidate) {
      final norm = candidate.trim().replaceAll('\\', '/');
      if (norm.isNotEmpty && !result.contains(norm)) {
        result.add(norm);
      }
    }

    final entries = <String>[];
    if (raw is String) {
      entries.addAll(
        raw
            .split(';')
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty),
      );
    }
    final portableRoot = PathRoots.portableRoot();
    for (final entry in entries) {
      if (!PathRoots.isAbsolute(entry)) {
        // Portable-relative form: replay under the current portable root.
        if (portableRoot != null) {
          final candidate =
              FilePath.join(portableRoot, entry).replaceAll('\\', '/');
          if (Directory(candidate).existsSync()) {
            addDistinct(candidate);
            continue;
          }
        }
        // No portable context and the relative path does not resolve against
        // cwd — drop it from the scan view; persistPortableSelfHeal keeps the
        // original text so it can recover later.
        if (Directory(entry).existsSync()) addDistinct(entry);
        continue;
      }
      if (Directory(entry).existsSync()) {
        addDistinct(entry);
        continue;
      }
      final rebased = PathRoots.rebaseProjectsRoot(entry);
      if (rebased != null) addDistinct(rebased);
    }
    final portableProjects =
        PathRoots.rebaseProjectsRoot(null, autoWhenEmpty: true);
    if (portableProjects != null) addDistinct(portableProjects);
    return result;
  }

  /// Persists the portable self-heal result back into the setting **once per
  /// launch** (called after all stores are initialized): surviving entries are
  /// rewritten in portable-relative form so the next folder move needs no
  /// resolution at all.
  ///
  /// Entries that vanished AND cannot be rebased (e.g. a detached external
  /// drive holding a user-chosen root) are preserved verbatim — dropping them
  /// would destroy configuration the moment a drive is unplugged.
  static Future<void> persistPortableSelfHeal() async {
    final raw = (appdata.settings['btProjectRoot'] as String? ?? '').trim();
    final entries = raw
        .split(';')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    final needsHeal = entries.any(
          (entry) =>
              PathRoots.isAbsolute(entry) && !Directory(entry).existsSync(),
        ) ||
        (entries.isEmpty && PathRoots.portableProjectsRoot() != null);
    if (!needsHeal) return;

    final effective = roots; // already resolved + de-duplicated
    final persisted = <String>[...effective];
    for (final entry in entries) {
      final missing =
          PathRoots.isAbsolute(entry) && !Directory(entry).existsSync();
      final rebased = missing ? PathRoots.rebaseProjectsRoot(entry) : null;
      if (missing && rebased == null && !persisted.contains(entry)) {
        // Unresolved custom root (drive offline?) — keep the raw text.
        persisted.add(entry);
      }
    }
    final stored = persisted
        .map((path) => PathRoots.relativeToPortable(path) ?? path)
        .join(';');
    if (stored == raw) return;
    appdata.settings['btProjectRoot'] = stored;
    await appdata.saveData(false);
    Log.info(
      'BT Project',
      'btProjectRoot self-healed after folder move: "$raw" -> "$stored".',
    );
  }

  static bool get isEnabled => roots.isNotEmpty;

  /// Every comic this manager registered carries the prefix.
  static bool isBtComic(String? id) => id != null && id.startsWith(idPrefix);

  /// 工程 → 解析结果。
  ///
  /// 🔴 支持两种 id：**章节级**工程 id（json 路径哈希，工作室真正打开的东西）
  /// 与**漫画级**卡片 id（详情页那张卡）。后者回落到它下面的第一个章节工程 ——
  /// 否则"从网格点进翻译工程"会得到 null，界面上表现为空白页。
  BtProject? projectFor(String comicId) {
    final direct = _projects[comicId];
    if (direct != null) return direct;
    final chapters = _comicChapters[comicId];
    if (chapters == null || chapters.isEmpty) return null;
    return _projects[chapters.values.first];
  }

  /// 漫画级卡片下的章节键（源章节目录名），按目录序。
  List<String> chapterKeysOf(String comicId) =>
      _comicChapters[comicId]?.keys.toList() ?? const [];

  /// 某个章节键对应的**章节级**工程 id；没有这个章节的工程则 null。
  String? chapterProjectId(String comicId, String chapterKey) =>
      _comicChapters[comicId]?[chapterKey];

  /// 章节键对应的解析结果。
  BtProject? chapterProjectFor(String comicId, String chapterKey) {
    final id = chapterProjectId(comicId, chapterKey);
    return id == null ? null : _projects[id];
  }

  /// 漫画级卡片 id：由**漫画级根目录**哈希而来。
  ///
  /// 与 [comicIdForJsonFile] 同一个哈希、同一份归一化，只是喂进去的是根目录
  /// （末尾补 `/`）。两者不会撞：json 路径不可能以 `/` 结尾。
  static String comicIdForComicRoot(String comicRoot) {
    final root = comicRoot.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    return comicIdForJsonFile('$root/');
  }

  /// 一个工程 json 属于哪个**漫画级根**。
  ///
  /// 判据：自己的目录里有一份**章节级**边车、**父目录**里有一份**漫画级**边车
  /// ⇒ 父目录就是漫画级根。老工程（P53 之前，直接在 `projects/<名>/`）没有
  /// 漫画级父边车，回落成"自己就是根"，行为与旧版完全一致。
  static String comicRootForJson(String jsonPath) {
    final normalized = jsonPath.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    if (slash <= 0) return normalized;
    final dir = normalized.substring(0, slash);
    final own = StudioProjectMeta.readFromProjectDir(dir);
    if (own != null && own.isComicLevel) return dir;
    final parentSlash = dir.lastIndexOf('/');
    if (parentSlash <= 0) return dir;
    final parent = dir.substring(0, parentSlash);
    final upper = StudioProjectMeta.readFromProjectDir(parent);
    if (upper != null && upper.isComicLevel) return parent;
    return dir;
  }

  /// All known project comic ids (the manager's registry keys). UI lists use
  /// this to enumerate projects without reaching into the private map.
  List<String> get projectIds => _projects.keys.toList();

  /// Runs a scan when the in-memory registry is empty. The registry is the
  /// only thing that can answer reader/cover requests, and not every entry
  /// point (home history, favorites, deep links) passes through the local
  /// comics page that historically owned scanning.
  Future<void> ensureReady() async {
    if (!isEnabled) return;
    if (_projects.isNotEmpty) return;
    await scan();
  }

  /// Returns the project after making sure at least one scan has run. Null
  /// means the project genuinely does not exist under [root].
  Future<BtProject?> ensureProject(String comicId) async {
    final cached = _projects[comicId];
    if (cached != null) return cached;
    await ensureReady();
    // 🔴 缓存未命中时**再扫一次**，而不是就此返回 null。
    //
    // `ensureReady()` 只要 `_projects` 非空就短路（它保证的是"至少扫过一次"，
    // 不是"扫的是最新"）。于是刚建好的工程若在那一次扫里被漏掉 —— json 还在
    // 落盘、或被任何一处判据跳过 —— 这次 miss 会一直 miss 到下次重启，表现正是
    // "建完跳进工作室显示没找到工程，退出重进就好了"。
    //
    // 只补扫**一次**（不是循环）：miss 是罕见路径（工程真不存在 / 刚创建），
    // 命中路径一次都不多扫，正常打开不受影响。
    if (!_projects.containsKey(comicId) && isEnabled) {
      await scan();
    }
    return _projects[comicId];
  }

  /// mtime of the project's json file, 0 when unknown. Mixed into the reader's
  /// image-provider key so saving in BT refreshes the displayed page.
  int jsonMtimeMs(String comicId) => _mtimes[comicId] ?? 0;

  /// Page image urls (`file://` + absolute path) of chapter [ep] in BT's
  /// reading order. Throws when the project is unknown so the reader surfaces
  /// an error instead of silently listing the raw directory.
  Future<List<String>> getImages(String comicId, Object ep) async {
    final project = await ensureProject(comicId);
    if (project == null) {
      throw "BT project not found (rescan needed)";
    }
    return project
        .pageKeysForChapter(ep)
        .map((key) => 'file://${project.displayPath(key)}')
        .toList();
  }

  /// Resolves a project's cover: a `cover.*` file in the project directory
  /// takes priority; otherwise the first existing page image in BT's page
  /// order. Returns null when the project is unknown or no usable file exists.
  Future<BtCover?> loadCover(String comicId) async {
    final project = await ensureProject(comicId);
    if (project == null) return null;
    final key = coverKeyFor(project);
    if (key == null) return null;
    final path = coverPathFor(project, key);
    if (path == null) return null;
    final bytes = await File(path).readAsBytes();
    if (bytes.isEmpty) return null;
    return BtCover(key, bytes);
  }

  /// Absolute path of the cover file for [key], or null when it is not on disk.
  ///
  /// 🔴 `cover.<ext>` lives in **two possible places**, and checking only one of
  /// them is exactly what silently degraded every studio project's cover to
  /// "the chapter's first page":
  /// - the project's image root ([BtProject.directory]) —— 工作室工程这里是
  ///   `<工程根>/source/`；
  /// - the json's parent directory (the project root) —— `ProjectBootstrap` 在
  ///   本查找存在之前写封面的地方。
  ///
  /// 工作室工程的 `directory` 指向 `source/`，所以写到工程根的封面**永远查不到**，
  /// `coverKeyFor` 于是穿过它落到 `pageOrder.first`（章节第一页）。两处都查，
  /// 新老工程就回到同一条规则上，不需要迁移任何文件。
  static String? coverPathFor(BtProject project, String key) {
    if (key.startsWith('cover.')) {
      return resolveCoverFile(
        directory: project.directory,
        jsonPath: project.jsonFile.path,
        key: key,
      );
    }
    return project.displayPath(key) ?? project.originalPath(key);
  }

  /// [coverPathFor] 的路径规则本身：`cover.<ext>` 在 `directory` 里 ⇒ 命中；
  /// 否则在 json 的**父目录**里 ⇒ 命中；两处都没有 ⇒ null。
  ///
  /// 🔴 抽成只吃三个字符串的纯函数（只碰文件系统），是为了让"封面查哪两处"
  /// 这条规则能被 headless 单独打红 —— 内联在 [coverPathFor] 里就必须先造一个
  /// [BtProject]（私有构造）才能验，实际上等于验不了。
  static String? resolveCoverFile({
    required String directory,
    required String jsonPath,
    required String key,
  }) {
    final inDirectory = '${directory.replaceAll('\\', '/')}/$key';
    if (File(inDirectory).existsSync()) return inDirectory;
    final parent = jsonPath.replaceAll('\\', '/');
    final slash = parent.lastIndexOf('/');
    if (slash > 0) {
      final inRoot = '${parent.substring(0, slash)}/$key';
      if (File(inRoot).existsSync()) return inRoot;
    }
    return null;
  }

  /// Cover key: `cover.<ext>` if a cover file exists in the project image root
  /// **or the project root**, otherwise the first page key (in BT reading
  /// order) whose image file exists.
  ///
  /// 🔴 Uses [BtProject.displayPath] (original → inpainted → mask), not the raw
  /// original: a project whose raw comic folder was moved/deleted used to have
  /// no resolvable cover, which made [scan] drop the whole project and left the
  /// studio list silently empty with no clue why.
  static String? coverKeyFor(BtProject project) {
    for (final ext in ['jpg', 'jpeg', 'png', 'webp']) {
      if (coverPathFor(project, 'cover.$ext') != null) {
        return 'cover.$ext';
      }
    }
    final key = project.pageOrder.firstWhere(
      (key) => BtProject.isImagePage(key) && project.hasDisplayImage(key),
      orElse: () => '',
    );
    return key.isEmpty ? null : key;
  }

  /// Sets a custom cover for a BT project. Writes the bytes to
  /// `directory/cover.<ext>`, removes any previous cover file with a
  /// different extension, updates the LocalComic cover field, and evicts
  /// cached image entries so the UI refreshes immediately.
  Future<bool> setCover(String comicId, Uint8List bytes) async {
    final project = await ensureProject(comicId);
    if (project == null) return false;
    final fileType = detectFileType(bytes);
    final coverPath = '${project.directory}/cover${fileType.ext}';

    // Remove old cover files with different extensions.
    for (final ext in ['jpg', 'jpeg', 'png', 'webp']) {
      final old = File('${project.directory}/cover.$ext');
      if (old.existsSync() && 'cover.$ext' != 'cover${fileType.ext}') {
        await old.delete();
      }
    }

    await File(coverPath).writeAsBytes(bytes);
    final coverKey = 'cover${fileType.ext}';

    // Update LocalComic so the grid and history pick up the new cover.
    final manager = LocalManager();
    final old = manager.find(comicId, ComicType.local);
    if (old != null) {
      manager.add(
        LocalComic(
          id: old.id,
          title: old.title,
          subtitle: old.subtitle,
          tags: old.tags,
          directory: old.directory,
          chapters: old.chapters,
          cover: coverKey,
          comicType: old.comicType,
          downloadedChapters: old.downloadedChapters,
          createdAt: old.createdAt,
          description: old.description,
        ),
      );
    }

    // Evict cached image so the new cover shows immediately.
    PaintingBinding.instance.imageCache.clear();

    return true;
  }

  /// 新工程应当建在哪儿。
  ///
  /// 🔴 `projects/` 必须是 `downloads/` 的**兄弟**（本地库扫描器红线：章节目录
  /// 内出现子目录 → 整本被拒，`A03 §1`），所以优先从本地库路径反推，而不是
  /// 沿用配置里的第一个根 —— 后者可能是就地布局的老 FT 工程目录。
  ///
  /// 两者都取不到时返回 `null`：这时宁可报错，也不要默认到一个可能踩红线的
  /// 位置。
  static String? defaultProjectsRoot() {
    final manager = LocalManager();
    if (manager.isInitialized && manager.path.isNotEmpty) {
      final parent = Directory(manager.path).parent.path;
      if (parent.isNotEmpty) {
        return '${parent.replaceAll('\\', '/')}/projects';
      }
    }
    final configured = roots;
    if (configured.isNotEmpty) return configured.first;
    return null;
  }

  /// 从一本**已下载的漫画**开一个工作室工程（**原图复制进 `source/`**）。
  ///
  /// 补的是 `P6 §4.10.2` 表 #3 记下的产品缺口：此前本类只有 `ensureProject`
  /// / `scan`，`ProjectWriter.adopt` 只被 validator 调用，用户在 GUI 里想给
  /// 一本下好的漫画开工程没有路径 —— 整章载体只能靠离线脚本
  /// `tools/_make_chapter_carrier.py` 生成。
  ///
  /// 三条硬约束（详见 `ProjectBootstrap`）：
  /// 1. **原图复制进 `<工程根>/source/`**，`directory` 指向副本（P10.15 §4.1 ·
  ///    P1 选项②）—— 抹字是**破坏性**的（`TextInpainter.erase` 就地改像素），
  ///    底图若取 `downloads/` 里唯一那份原图，一次逻辑错就是**擦掉用户的原
  ///    图**。复制把这条风险从"数据丢失"降为"重跑一次"，代价是磁盘；
  /// 2. 产物绝不进 `downloads/` —— 由 `ProjectBootstrap.validate` 硬挡；
  /// 3. json 只写实测字段，**不写 `workspace` 键**。
  ///
  /// 🔴 `downloads/` 由此降级为**只读保底**：翻译链路不再写它。
  ///
  /// 返回 `null` 表示拿不到工程根（本地库未初始化且没配 `btProjectRoot`）。
  /// [result.error] 非 null 表示被红线或"已存在"挡下了，此时 [result.created]
  /// 恒为 false 且**目标文件一个字节都没动**。
  ///
  /// ⚠️ 新建的工程要出现在工作室列表里，`btProjectRoot` 必须包含
  /// [defaultProjectsRoot]；不包含时这里会打一条警告而不是偷偷改设置 ——
  /// 静默改用户的配置比"建完看不见"更糟。
  Future<ProjectBootstrapResult?> createFromDownload({
    required String comicDirectory,
    required String chapterName,
    required String name,
    String comicName = '',
    bool force = false,
    bool rescan = true,
  }) async {
    final root = defaultProjectsRoot();
    if (root == null) {
      Log.error(
        'BT Project',
        'Cannot create project "$name": no project root '
            '(local library not initialized and btProjectRoot is empty).',
      );
      return null;
    }
    final plan = ProjectBootstrap.plan(
      comicDirectory: comicDirectory,
      chapterName: chapterName,
    );
    if (plan.isEmpty) {
      Log.warning(
        'BT Project',
        'Chapter "$chapterName" under $comicDirectory has no page image; '
            'project "$name" was not created.',
      );
    }
    // 🔴 P53：两级布局 —— 章节级工程落在**漫画级根**下面（`parentName`）。
    // 根的名字优先用 `comicName`（= 漫画名），没给就退回 `name`（保持老布局，
    // 免得离线工具凭空多出一层）。
    final parentName = comicName.trim().isEmpty ? '' : comicName.trim();
    if (parentName.isNotEmpty) {
      await ProjectBootstrap.ensureComicRoot(
        projectsRoot: root,
        name: parentName,
        meta: StudioProjectMeta(
          comicId: '',
          comicTitle: parentName,
          sourceKey: '',
          eid: '0',
          level: StudioProjectMeta.levelComic,
          originalPath: comicDirectory,
        ),
        coverFrom: ProjectBootstrap.comicCoverPathIn(comicDirectory),
      );
    }
    final result = await ProjectBootstrap.create(
      projectsRoot: root,
      name: name,
      parentName: parentName,
      plan: plan,
      force: force,
    );
    if (result.created && rescan) {
      if (!roots.any((candidate) => _samePath(candidate, root))) {
        Log.warning(
          'BT Project',
          'Created "$name" under $root, but btProjectRoot does not include '
              'it — the studio list will not show it until the setting does.',
        );
      }
      await scan();
    }
    return result;
  }

  static bool _samePath(String a, String b) {
    String norm(String value) =>
        value.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    return norm(a).toLowerCase() == norm(b).toLowerCase();
  }

  /// Full FT-contract model for [comicId], parsed on demand.
  ///
  /// [BtProject] is the reader's view: it keeps only rect/text/colour, which is
  /// all a re-render needs. The studio's property panel has to show
  /// `font_family` / `alignment` / `vertical` / `line_spacing` verbatim, so it
  /// re-reads the same json through the full model. Only one project is open at
  /// a time, so the second parse costs a few hundred kilobytes once.
  Future<TranslationProject?> ensureTranslationProject(String comicId) async {
    final project = await ensureProject(comicId);
    if (project == null) return null;
    return TranslationProjectIo.load(project.jsonFile);
  }

  /// Renders one BT page: inpainted base + translated blocks drawn with the
  /// existing translation pipeline. Returns null when the page has no usable
  /// translation or no inpainted image — the caller then shows the original.
  Future<Uint8List?> renderBtPage(String comicId, String imageKey) async {
    var project = _projects[comicId];
    // The reader can open a BT comic straight from history before any scan ran.
    project ??= await ensureProject(comicId);
    if (project == null) return null;
    final path = imageKey.startsWith('file://')
        ? imageKey.substring(7)
        : imageKey;
    final prefix = '${project.directory}/';
    if (!path.startsWith(prefix)) return null;
    final pageKey = path.substring(prefix.length);
    final regions = project.regionsFor(pageKey);
    if (regions.isEmpty) return null;
    final inpaintedPath = project.inpaintedPath(pageKey);
    if (inpaintedPath == null) return null;
    final bytes = await File(inpaintedPath).readAsBytes();
    if (bytes.isEmpty) return null;

    final decoded = await _decodeBounded(bytes);
    final scale = decoded.width / decoded.originalWidth;
    final scaled = [
      for (final region in regions)
        TranslatedRegion(
          rect: IntRect(
            (region.rect.left * scale).round(),
            (region.rect.top * scale).round(),
            (region.rect.right * scale).round(),
            (region.rect.bottom * scale).round(),
          ),
          text: region.text,
          backgroundColor: region.backgroundColor,
          textColor: region.textColor,
          lineHeight: region.lineHeight > 0
              ? (region.lineHeight * scale).round()
              : 0,
        ),
    ];
    // The inpainted PNG is already text-free, so render in smart mode: the
    // decoded pixels are used as the base directly without another erase pass.
    return renderTranslatedPage(
      bytes,
      decoded.image,
      scaled,
      mode: InpaintMode.smart,
    );
  }

  /// Rescans the configured root: registers new/updated projects and drops
  /// registrations whose json disappeared. Safe to call repeatedly; concurrent
  /// callers share one in-flight scan.
  Future<void> scan() {
    return _scanFuture ??= _scan().whenComplete(() {
      _scanFuture = null;
    });
  }

  Future<void> _scan() async {
    final seen = <String>{};
    // 漫画级根 -> 该根下的章节工程 id 列表。
    final groups = <String, List<String>>{};
    for (final rootDir in roots.map(Directory.new)) {
      if (!await rootDir.exists()) continue;
      final files = <File>[];
      await _collectJsonFiles(rootDir, files, 0);
      for (final file in files) {
        try {
          final id = comicIdForJsonFile(file.path);
          final mtime = (await file.lastModified()).millisecondsSinceEpoch;
          var project = _projects[id];
          if (project == null || _mtimes[id] != mtime) {
            project = await BtProject.load(file);
            // The loader reports a fallback instead of logging it, so that the
            // parsing file stays Flutter-free; surface it here where a logger
            // is already available.
            if (BtProject.lastLoadUsedLegacyParser) {
              Log.warning(
                'BT Project',
                'Translation model rejected ${file.path} '
                    '(${BtProject.lastLoadError}); used the legacy parser.',
              );
            }
          }
          // The parsed project is cached for readers no matter whether the
          // local-comic database is ready yet; DB registration is best effort
          // and healed on the next scan / local-page visit.
          //
          // 🔴 A project with no resolvable image at all is genuinely broken
          // (json + neither original nor inpainted/mask on disk). Skipping it
          // silently is what made a project vanish from the studio with no
          // diagnostic, so say so loudly instead.
          //
          // P5 起多一条放行：**空壳工程**（一页图都没有、也没有封面）也是正当的
          // 工程 —— 用户可以先建壳再往里填页。它靠"有显式归属边车"来证明自己
          // 不是坏文件；两者都没有 ⇒ 仍然是坏工程，继续跳过。
          final association = associationFor(project);
          if (coverKeyFor(project) == null && association == null) {
            Log.warning(
              'BT Project',
              'Skipped ${file.path}: no cover and no page image found '
                  '(looked in ${project.directory} and ${project.workspace}/'
                  'inpainted|mask).',
            );
            continue;
          }
          _projects[id] = project;
          _mtimes[id] = mtime;
          seen.add(id);
          // 🔴 登记推迟到整轮扫完之后：漫画级卡片要看到**它下面所有**章节工程
          // 才能建出一张"有几章、哪几章有工程"的卡；边扫边登记就会建出
          // "只有第一章"的卡，后面每多一章就重写一次，中间态还会被 UI 看见。
          groups.putIfAbsent(comicRootForJson(file.path), () => []).add(id);
        } catch (e, s) {
          Log.error('BT Project', 'Failed to load ${file.path}: $e', s);
        }
      }
    }

    // ── 登记：漫画级根 ⇒ 一张卡；老布局 ⇒ 一个工程一张卡 ───────────────────
    final manager = LocalManager();
    _comicChapters.clear();
    for (final entry in groups.entries) {
      final comicRoot = entry.key;
      final ids = entry.value..sort();
      final meta = StudioProjectMeta.readFromProjectDir(comicRoot);
      final isComicRoot = meta != null && meta.isComicLevel;
      if (!isComicRoot) {
        // 老工程（P53 之前）：工程目录自己就是卡片，行为与旧版一致。
        if (manager.isInitialized) {
          for (final id in ids) {
            final project = _projects[id];
            if (project != null) _registerLocal(manager, id, project, _mtimes[id] ?? 0);
          }
        }
        continue;
      }
      final comicId = comicIdForComicRoot(comicRoot);
      final byChapter = <String, String>{};
      for (final id in ids) {
        final project = _projects[id];
        if (project == null) continue;
        byChapter[chapterKeyForProject(project)] = id;
      }
      // 🔴 顺序必须按**话号**，不能按工程 id（哈希）：详情页的章节列表与
      // `comic.chapters` 同序，读者的"第 N 章"（ep）也是这个序 —— 两处一旦
      // 不同序，点第 3 个章节会打开第 1 章的工程，而且界面上完全看不出来。
      final ordered = byChapter.keys.toList()..sort(_chapterKeyOrder);
      _comicChapters[comicId] = {
        for (final key in ordered) key: byChapter[key]!,
      };
      seen.add(comicId);
      if (manager.isInitialized) {
        _registerComicLocal(manager, comicId, comicRoot, byChapter, meta);
      }
    }

    // Drop registrations whose json vanished (or root was cleared).
    final staleProjects = _projects.keys
        .where((id) => !seen.contains(id))
        .toList();
    for (final id in staleProjects) {
      _projects.remove(id);
      _mtimes.remove(id);
    }
    if (manager.isInitialized) {
      final staleComics = manager
          .getComics(LocalSortType.defaultSort)
          .where((c) => isBtComic(c.id) && !seen.contains(c.id))
          .toList();
      for (final comic in staleComics) {
        manager.remove(comic.id, comic.comicType);
      }
    }
    if (staleProjects.isNotEmpty || seen.isNotEmpty) {
      notifyListeners();
    }
  }

  Future<void> _collectJsonFiles(
    Directory dir,
    List<File> out,
    int depth,
  ) async {
    if (depth > 6) return;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        final name = _basename(entity.path);
        if (entity is File) {
          if (isProjectJsonFileName(name)) {
            out.add(entity);
          }
        } else if (entity is Directory) {
          if (name.startsWith('.')) continue;
          // 🔴 `_` 开头的是**备份目录**（P53 迁移留的 `_p53_backup_<时间戳>/`），
          // 里面有一份工程 json 的副本。扫到它就会凭空多出第二张工程卡 ——
          // 而且那张卡和真卡长得一模一样，用户点进去会发现"怎么有两个"。
          if (name.startsWith('_')) continue;
          if (_skippedDirs.contains(name.toLowerCase())) continue;
          await _collectJsonFiles(entity, out, depth + 1);
        }
      }
    } catch (e, s) {
      Log.error('BT Project', 'Failed to list ${dir.path}: $e', s);
    }
  }

  /// Whether [name] is a **project** json — the file to register as one
  /// translation project. Not every `imgtrans_*.json` qualifies.
  ///
  /// 🔴 产物对账表**就躺在工程 json 旁边**，名叫 `imgtrans_<名>.artifacts.json`
  /// （见 [ArtifactReconciliation.pathFor]）—— 它同样 `imgtrans_` 开头、`.json`
  /// 结尾，于是旧的"前缀 + 后缀"判据把它也当成一个工程登记：本地库/主页多出
  /// 一张**空**卡片（对账表里没有 `pages`，解析出来是个零页工程），而且它是
  /// "删不掉"的 —— 磁盘上并没有一个与之对应的工程，删真实工程也带不走它，
  /// 因为它挂的是**同一本**工程所在的目录（2026-10-09 实测：保存一次就多一个）。
  ///
  /// 用**共享后缀** [ArtifactReconciliation.fileSuffix] 排除，而不是在这里再写
  /// 一遍字面量：对账表换名时若这条漏改，就会静默地再长出幽灵卡片。
  static bool isProjectJsonFileName(String name) {
    if (!name.startsWith('imgtrans_')) return false;
    if (!name.endsWith('.json')) return false;
    return !name.endsWith(ArtifactReconciliation.fileSuffix);
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash < 0 ? normalized : normalized.substring(slash + 1);
  }

  /// Stable 8-hex-char id derived from the json path so the same project keeps
  /// its comic entry (and history) across rescans.
  ///
  /// 🔴 Public on purpose: the "create a translation project" entry point
  /// (`pages/translation_studio/studio_project_menu.dart`) has just written a
  /// json at a known path and needs the id to navigate into the studio with.
  /// Re-deriving the hash there would be a **second implementation** of the
  /// identity rule — and a drifted one shows up as "the project I just created
  /// is not in the list", with a working-looking project on disk.
  static String comicIdForJsonFile(String jsonPath) {
    // 🔴 分隔符**必须先归一化**：同一个 json 会从两个地方拿路径算 id——
    // `scan()` 的路径来自 `Directory.list()`（Windows 上是 `\`），而创建流程
    // 手里的路径来自 `ProjectBootstrap`（`/`）。不归一化的话两条路径算出**两个
    // 不同的 id**，于是一个刚建好的工程：`scan()` 用 `\` 变体把它登记进
    // `_projects`，创建向导却用 `/` 变体去查 ⇒ `projectFor()` 返回 null ⇒
    // 弹"工程不在工作室工程根目录下"，点【打开翻译工程】跳过去也查不到工程
    // （空白页），而本地库/主页从 DB 拿到的又是 `\` 变体所以显示正常。
    // 归一化成 `/` 后两边算出同一个 id，写入与查询才对得上。
    final normalized = jsonPath.replaceAll('\\', '/').toLowerCase();
    var hash = 0x811c9dc5;
    for (final unit in normalized.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return '$idPrefix${hash.toRadixString(16).padLeft(8, '0')}';
  }

  /// 这个工程的**显式归属**（它属于哪一本来源漫画），没有则 null。
  ///
  /// 🔴 只认**边车**（`mangrove_project.json`，写在工程根）：那是工程自己携带
  /// 的归属，不依赖任何外部表，也不会因为"表被清空"而失效。
  ///
  /// 刻意**不**在这里回落绑定表（`StudioReaderStore`）：那个表住在
  /// `translation_project/studio_reader_app.dart`，而那个文件 import 了这个文件
  /// —— 反向 import 会把两个模块缠成一个环。归类页那一侧（两个方向都能 import）
  /// 才做绑定表兜底。
  static StudioProjectMeta? associationFor(BtProject project) {
    final jsonPath = project.jsonFile.path.replaceAll('\\', '/');
    final slash = jsonPath.lastIndexOf('/');
    if (slash <= 0) return null;
    return StudioProjectMeta.readFromProjectDir(jsonPath.substring(0, slash));
  }

  /// 章节级工程的**章节键**：json 所在目录名（= 源漫画里那一章的目录名）。
  static String chapterKeyForProject(BtProject project) {
    final jsonPath = project.jsonFile.path.replaceAll('\\', '/');
    final slash = jsonPath.lastIndexOf('/');
    if (slash <= 0) return '';
    final dir = jsonPath.substring(0, slash);
    final parentSlash = dir.lastIndexOf('/');
    return parentSlash < 0 ? dir : dir.substring(parentSlash + 1);
  }

  /// 章节键排序：话号（数值）优先，其余按字典序；无话号的排最后。
  ///
  /// 与 `chapters.dart` 的章节列表同序 —— 详情页顺序和源漫画不一致会让人以为
  /// 工程建错了章。
  static int _chapterKeyOrder(String a, String b) {
    final na = chapterNumberValueOf(a);
    final nb = chapterNumberValueOf(b);
    if (na != null && nb != null && na != nb) return na.compareTo(nb);
    if (na != null && nb == null) return -1;
    if (na == null && nb != null) return 1;
    return a.compareTo(b);
  }

  /// 素材漫画：工程借它的封面 / 标题 / 简介 / 标签（用户的原话：
  /// "翻译工程详情页的封面和漫画信息等借用对应的漫画素材详情页即可"）。
  LocalComic? _sourceComic(LocalManager manager, StudioProjectMeta meta) {
    if (meta.comicId.isEmpty) return null;
    final local = manager.find(meta.comicId, ComicType.local);
    if (local != null) return local;
    if (meta.sourceKey.isEmpty) return null;
    try {
      return manager.find(meta.comicId, ComicType.fromKey(meta.sourceKey));
    } catch (_) {
      return null;
    }
  }

  /// 登记**漫画级**卡片：一张卡 = 一本漫画的翻译工程集合。
  ///
  /// 🔴 这一层不是"另造一种漫画"，而是**本来就是一本书**：它有自己的封面、
  /// 标题、简介与章节列表，所以它可以和素材漫画放在同一个合集里，详情页也走
  /// 同一套 UI（`ComicPage`）。差别只在点开章节时进的是翻译工作室（复合多
  /// 重显示），而不是图片扫描阅读器。
  ///
  /// 章节列表只列**已有工程**的章节：用户要的是"这里显示的是翻译工程，不是
  /// 普通漫画"。没建工程的章节不出现，避免点开一片空白。
  void _registerComicLocal(
    LocalManager manager,
    String comicId,
    String comicRoot,
    Map<String, String> byChapter,
    StudioProjectMeta meta,
  ) {
    final source = _sourceComic(manager, meta);
    final keys = byChapter.keys.where((k) => k.isNotEmpty).toList()
      ..sort(_chapterKeyOrder);

    final displayTitles = <String, String>{};
    for (final key in keys) {
      final borrowed = _sourceChapterTitle(source, key);
      displayTitles[key] =
          borrowed.isNotEmpty ? borrowed : parseChapterTitle(key).displayTitle;
    }

    // 封面：优先用漫画级根下自己那份（创建时从素材漫画复制的），其次素材漫画。
    var cover = meta.cover;
    if (cover.isEmpty || !File('$comicRoot/$cover').existsSync()) {
      cover = '';
      for (final ext in const ['jpg', 'jpeg', 'png', 'webp']) {
        if (File('$comicRoot/cover.$ext').existsSync()) {
          cover = 'cover.$ext';
          break;
        }
      }
    }
    if (cover.isEmpty) cover = source?.cover ?? '';

    final title = meta.comicTitle.isNotEmpty
        ? meta.comicTitle
        : (source?.title ?? _basename(comicRoot));

    final comic = LocalComic(
      id: comicId,
      title: title,
      // 与素材漫画一致：副标题是"又名/副题"，不是"projects"。
      subtitle: source?.subtitle ?? '',
      tags: source?.tags.isNotEmpty == true ? source!.tags : const ['BT'],
      directory: comicRoot,
      chapters: keys.isEmpty ? null : ComicChapters(displayTitles),
      cover: cover,
      comicType: ComicType.local,
      downloadedChapters: keys,
      createdAt: source?.createdAt ??
          DateTime.fromMillisecondsSinceEpoch(
            _mtimes[byChapter.values.first] ?? 0,
          ),
      description: source?.description ?? '翻译工程',
      source: source?.source ?? '',
      updateTime: source?.updateTime ?? '',
      altTitles: source?.altTitles ?? const [],
    );

    final old = manager.find(comicId, ComicType.local);
    if (old != null &&
        old.title == comic.title &&
        old.subtitle == comic.subtitle &&
        old.directory == comic.directory &&
        old.cover == comic.cover &&
        old.description == comic.description &&
        old.chapters?.length == comic.chapters?.length &&
        old.downloadedChapters.length == comic.downloadedChapters.length &&
        old.downloadedChapters.toSet().containsAll(comic.downloadedChapters)) {
      return; // unchanged
    }
    manager.add(comic);
  }

  /// 素材漫画里这一章的标题；没有则空串。
  static String _sourceChapterTitle(LocalComic? source, String chapterKey) {
    final chapters = source?.chapters;
    if (chapters == null) return '';
    try {
      final title = chapters[chapterKey];
      return title?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Writes/refreshes the [LocalComic] row for [project]. The parsed project
  /// itself is cached by the caller regardless of this outcome; this only keeps
  /// the local-comic database (grid, favorites, state) in sync.
  void _registerLocal(
    LocalManager manager,
    String id,
    BtProject project,
    int mtime,
  ) {
    final coverKey = coverKeyFor(project);
    final association = associationFor(project);
    // 🔴 没有封面**不等于**这个工程该消失：空壳工程（还没往里填页）就是这一副
    // 模样，但它有显式归属边车 ⇒ 是用户自己建的正当工程。没有封面**也没有**
    // 归属的，才是真的坏文件，交给调用方跳过。
    if (coverKey == null && association == null) return;

    final jsonPath = project.jsonFile.path.replaceAll('\\', '/');
    final parent = _basename(_dirname(jsonPath));
    final grandParent = _basename(_dirname(_dirname(jsonPath)));
    final chapterNames = project.chapters.keys.toList();
    final displayTitles = {
      for (final name in chapterNames)
        name: parseChapterTitle(name).displayTitle,
    };

    final comic = LocalComic(
      id: id,
      title: parent.isEmpty ? project.jsonFile.path : parent,
      // 🔴 副标题过去是"祖父目录名"，而工程布局是
      // `<projectsRoot>/<漫画名>-<章节名>/` ⇒ 祖父目录**永远是** `projectsRoot`
      // 自己，于是所有工程卡的副标题都显示成 "projects"，且归类页按它分组时
      // 会把同一个 root 下的**所有**工程并成一页。
      //
      // 有显式归属时改用**来源漫画名** —— 这才是副标题该表达的东西（"这一章
      // 属于哪一本"）。没有边车的老工程仍旧回落到祖父目录名（不改动既有行为）。
      subtitle: association?.comicTitle.isNotEmpty == true
          ? association!.comicTitle
          : grandParent,
      tags: const ['BT'],
      directory: project.directory,
      chapters: chapterNames.isEmpty ? null : ComicChapters(displayTitles),
      cover: coverKey ?? '',
      comicType: ComicType.local,
      downloadedChapters: chapterNames,
      createdAt: DateTime.fromMillisecondsSinceEpoch(mtime),
      description: 'BallonsTranslator 工程',
    );

    final old = manager.find(id, ComicType.local);
    // downloadedChapters in the old row must match exactly (same set, no
    // duplicates); otherwise a rewrite heals rows grown by older rescans.
    final sameDownloadedChapters =
        old != null &&
        old.downloadedChapters.length == chapterNames.length &&
        old.downloadedChapters.toSet().containsAll(chapterNames);
    if (old != null &&
        sameDownloadedChapters &&
        old.title == comic.title &&
        // 🔴 副标题也要比：边车是**后**写的（工程建成之后才有归属），所以第一
        // 次扫描登记的行副标题还是 "projects"，边车落盘后的第二次扫描必须能把
        // 它改成漫画名 —— 不比这一项，这一行就永远停在旧值上。
        old.subtitle == comic.subtitle &&
        old.directory == comic.directory &&
        old.cover == comic.cover &&
        old.createdAt.millisecondsSinceEpoch == mtime &&
        old.chapters?.length == comic.chapters?.length) {
      return; // unchanged: skip the write and its notifyListeners churn
    }
    manager.add(comic);
  }

  static String _dirname(String normalizedPath) {
    final slash = normalizedPath.lastIndexOf('/');
    return slash < 0 ? '' : normalizedPath.substring(0, slash);
  }
}

/// A resolved BT project cover: its page key relative to the project dir and
/// the loaded file bytes.
class BtCover {
  BtCover(this.key, this.bytes);

  final String key;
  final Uint8List bytes;
}

class _BoundedDecode {
  _BoundedDecode(this.image, this.originalWidth);
  final RgbaImage image;

  /// Width of the undecoded source, needed to scale BT's original-resolution
  /// coordinates down to the working image.
  final int originalWidth;

  int get width => image.width;
}

/// Mirrors the translation pipeline's decode budget (≤12MP, ≤8000px on a side)
/// so a BT page costs the same memory as a pipeline page. BT's xyxy boxes are
/// in the source's full resolution; the caller scales them by
/// `image.width / originalWidth`.
Future<_BoundedDecode> _decodeBounded(Uint8List bytes) async {
  var buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  var descriptor = await ui.ImageDescriptor.encoded(buffer);
  const maxPixels = 12 * 1024 * 1024;
  const maxDimension = 8000;
  var w = descriptor.width;
  var h = descriptor.height;
  var scale = 1.0;
  if (w * h > maxPixels) {
    scale = math.sqrt(maxPixels / (w * h));
  }
  if (math.max(w, h) * scale > maxDimension) {
    scale = maxDimension / math.max(w, h);
  }
  int? targetW;
  int? targetH;
  if (scale < 1.0) {
    targetW = math.max(1, (w * scale).round());
    targetH = math.max(1, (h * scale).round());
  }
  var codec = await descriptor.instantiateCodec(
    targetWidth: targetW,
    targetHeight: targetH,
  );
  var frame = await codec.getNextFrame();
  var image = frame.image;
  try {
    var data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw Exception('Failed to read image pixels');
    }
    return _BoundedDecode(
      RgbaImage(image.width, image.height, data.buffer.asUint8List()),
      w,
    );
  } finally {
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}
