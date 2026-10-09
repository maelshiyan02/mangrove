// S9.5-b · 阅读侧读工程产物 —— 纯逻辑层。
//
// ## 这个文件回答的唯一一个问题
//
// **阅读器要显示的这一页，有没有工程产物可以读？读哪一份？**
//
// 三件事同时在这里发生，而且都是"选错了不报错、只是显示错的图"那一类：
//
// 1. **一本素材漫画的哪一章绑定到哪个工程**（`StudioReaderBinding`）；
// 2. **阅读器拿到的绝对图片路径 → 工程的页键**（`relativePageKey`）；
// 3. **这一页显示 `result/` 还是现绘还是原图**（`chooseReaderPageSource`）。
//
// ## 为什么必须与 Flutter 无关
//
// 因为 S9.5-b 的前置是一条硬规矩：**任何"已完成 ✅"都要有反向验证**，而本会话
// 没有渲染表面（`A01 §3`）—— 图像像素只能人工验，但"选哪一份"是纯判断，必须
// 能在 headless 里被注入故障打红。把持久化抽到 `studio_reader_app.dart`
// （照 `glossary_store_app.dart` 的办法），这个文件就只依赖 `dart:core`。
//
// ## 与 `BtProjectManager` 的分工
//
// BT 工程漫画（`bt_<hash>`）本来就在走 `renderBtPage`，不需要本文件。这里只处理
// **素材漫画**：用户下载下来的普通漫画，被 S9.5-b 的开关绑定到一个新建的工程上。
library;

/// 阅读器这一页的图片来源。**顺序即契约**，见 [chooseReaderPageSource]。
enum ReaderPageSource {
  /// 原图。没有工程、没有产物，或者开关关着。
  original,

  /// `<workspace>/result/<页键>.png` —— 已排好版的成品位图。
  ///
  /// 最便宜：一次读文件，不解码、不重绘（`project.dart` 的 `resultPath` 注释
  /// 写明的就是这条）。
  projectResult,

  /// `inpainted/` 底图 + 工程里的块**现绘**。
  ///
  /// 比 [projectResult] 贵（要解码 + 重绘），但**永不过期**：工作室刚改完、
  /// `result/` 还没重生成的那一页，只有这条路径立刻反映编辑。
  projectRender,
}

/// 这一页该显示什么。
///
/// ## 顺序是契约，不是偏好
///
/// 1. 有 `result/` ⇒ [ReaderPageSource.projectResult]（便宜）。
/// 2. 否则有 `inpainted/` **且**至少有块可绘 ⇒ [ReaderPageSource.projectRender]。
///    `hasBlocks` 必须一起判：只有底图没有块时重绘等于画一张去字的白页，
///    比原图更糟 —— 用户会以为"翻译把字弄没了"。
/// 3. 否则 [ReaderPageSource.original]。
///
/// 🔴 这里**没有**"OCR 即时缓存"这一支。S9.5-b 把它下线了（
/// `ImageTranslationService` 的读时翻译入口退出 UX，引擎层原样保留）：一个
/// 只有旧缓存的页现在是原图，而不是"安静地显示一份没人再维护的产物"。
ReaderPageSource chooseReaderPageSource({
  required bool hasResult,
  required bool hasInpainted,
  required bool hasBlocks,
}) {
  if (hasResult) return ReaderPageSource.projectResult;
  if (hasInpainted && hasBlocks) return ReaderPageSource.projectRender;
  return ReaderPageSource.original;
}

/// 一本素材漫画的某一章 ↔ 一个工作室工程。
///
/// 存的是 **json 的绝对路径**而不是工程名：工程名与 json 名的换算规则改过一次
/// （`directory` 从 downloads 改成 `source/`，`P10.15 §4.1`），而 json 路径是
/// 磁盘上的事实。
///
/// ## 除了"哪一章 → 哪个工程"，它还记住"这一章是谁"
///
/// [originScope] / [group] 是**术语表的身份**（见 `glossary_scope.dart`）。
/// 为什么必须存在这里：工作室只拿到工程 id（`bt_<hash>`），而工程 json 是 FT
/// 兼容格式、**顶层键序被断言锁死**（`headless_p3_checks` 的
/// `key_order_matches_ft`）⇒ 没法把来源写进 json。绑定表是唯一既有又允许加字段
/// 的落点。
///
/// 🔴 没有这两个字段会怎样：工作室只能拿 `comicId` 当 scope，于是同一本漫画的
/// 20 章各有一份互不相通的术语表 —— 而界面上一切都"正常"。
class StudioReaderBinding {
  const StudioReaderBinding({
    required this.jsonPath,
    required this.comicDirectory,
    required this.projectDirectory,
    this.originScope = '',
    this.group = '',
  });

  /// `imgtrans_*.json` 的绝对路径。
  final String jsonPath;

  /// 素材原图根（`downloads/<漫画>`）—— 页键就是相对**这个**根的路径。
  ///
  /// 🔴 不是工程的 `directory`（那是 `source/` 副本根）。阅读器拿到的是
  /// `downloads` 下的绝对路径，两者靠"同一个相对路径"对应起来。
  final String comicDirectory;

  /// 工程的 `source/` 副本根，仅用于诊断与校验。
  final String projectDirectory;

  /// 来源漫画身份 `cid@sourceKey`（术语表 scope）。
  ///
  /// 空串 = 老绑定 / 取不到来源 ⇒ 调用方回落到 `comicId`。
  final String originScope;

  /// 这一章所属的翻译组（术语表 group）。非版本化源恒为空串。
  final String group;

  Map<String, Object?> toJson() => {
    'json': jsonPath,
    'comicDirectory': comicDirectory,
    'projectDirectory': projectDirectory,
    // 空值不写：老绑定读回来还是空串，行为与"写了空串"完全一致，
    // 但盘上少两个恒定无意义的键。
    if (originScope.isNotEmpty) 'originScope': originScope,
    if (group.isNotEmpty) 'group': group,
  };

  /// 解析一条持久化记录。**缺字段即整条作废**（返回 null）：半条绑定比没有
  /// 绑定更危险 —— 它会以"有工程"的身份通过判据，然后在读页键时静默落原图。
  ///
  /// [originScope] / [group] 是**可选**的：老绑定没有它们，回落成空串即可
  /// （调用方据此回落到 `comicId`），不该让整条绑定作废。
  static StudioReaderBinding? fromJson(Object? raw) {
    if (raw is! Map) return null;
    String field(String key) => raw[key]?.toString().trim() ?? '';
    final json = field('json');
    final comic = field('comicDirectory');
    if (json.isEmpty || comic.isEmpty) return null;
    return StudioReaderBinding(
      jsonPath: json,
      comicDirectory: comic,
      projectDirectory: field('projectDirectory'),
      originScope: field('originScope'),
      group: field('group'),
    );
  }

  @override
  String toString() => 'StudioReaderBinding($comicDirectory -> $jsonPath'
      '${originScope.isEmpty ? '' : ' [$originScope/${group.isEmpty ? '-' : group}]'})';
}

/// 绑定表：`'<cid>@<sourceKey>@<eid>' -> [StudioReaderBinding]`。
///
/// 键里带 `eid` 是因为**一个工程就是一"章"**（`ProjectBootstrap.plan` 按
/// `comicDirectory + chapterName` 建工程）。按 cid 一个键会让多章漫画的第二章
/// 覆盖掉第一章的绑定，而覆盖之后界面完全正常、只是读错了工程。
///
/// 做成薄薄一层包在 `Map` 上（而不是静态方法），是为了让"损坏的条目"这件事
/// 只在一个地方处理：`fromJson` 返回 null 的条目**读的时候跳过、写的时候不
/// 复制**，所以一次读-改-写就会把坏条目自然清掉。
class StudioReaderBindings {
  StudioReaderBindings([Map<String, Object?>? raw]) : _raw = raw ?? {};

  final Map<String, Object?> _raw;

  /// 从 implicitData 里取到的任意值构造。非 Map 一律当空表。
  static StudioReaderBindings from(Object? stored) {
    if (stored is! Map) return StudioReaderBindings();
    return StudioReaderBindings({
      for (final entry in stored.entries) entry.key.toString(): entry.value,
    });
  }

  bool get isEmpty => _raw.isEmpty;

  Iterable<String> get keys => _raw.keys;

  /// 绑定键。`sourceKey` 为 null 时用空串 —— 与阅读器侧
  /// `'$cid@$sourceKey@$eid'` 的拼法一致（`null` 会拼成字面量 `null`，
  /// 那会让"同一个漫画"在两条路径上有两个键）。
  static String key({
    required String cid,
    required String? sourceKey,
    required String eid,
  }) => '$cid@${sourceKey ?? ''}@$eid';

  StudioReaderBinding? operator [](String key) =>
      StudioReaderBinding.fromJson(_raw[key]);

  /// 反查：哪条绑定指向 [jsonPath]。
  ///
  /// 这是工作室那一侧的入口 —— 它手里只有工程（`bt_<hash>`），需要经这里拿回
  /// [StudioReaderBinding.originScope] / [StudioReaderBinding.group] 才知道自己
  /// 该读写哪一份术语表。
  ///
  /// 🔴 比较走 [normaliseReaderPath] + 小写折叠：json 路径在 `implicitData` 里
  /// 是写定时记下的，而工作室那边是 `Directory.listSync` / `File.path` 拼出来
  /// 的，两者可能差一个盘符大小写或一个斜杠方向 —— 而"差一点就算不上"的后果
  /// 是术语表静默回落到 `comicId`。
  StudioReaderBinding? forJsonPath(String jsonPath) {
    final wanted = normaliseReaderPath(jsonPath).toLowerCase();
    if (wanted.isEmpty) return null;
    for (final entry in _raw.entries) {
      final binding = StudioReaderBinding.fromJson(entry.value);
      if (binding == null) continue;
      if (normaliseReaderPath(binding.jsonPath).toLowerCase() == wanted) {
        return binding;
      }
    }
    return null;
  }

  void put(String key, StudioReaderBinding binding) =>
      _raw[key] = binding.toJson();

  /// 这一本漫画（`cid@sourceKey`）已经绑过工程的 `eid` 集合。
  ///
  /// 用于"这一章有没有绑过工程"的**批量**判断（详情页的已翻译筛选、章节列表
  /// 的状态标记）：一次遍历就够，不必对每一章各拼一次键再查一次表。
  ///
  /// 🔴 前缀用 [key] 这个**同一个**函数拼出来（`eid` 传空串），不手写
  /// `'$cid@$sourceKey@'`：手写一遍之后 [key] 的拼法一改，这里会静默地一个都
  /// 匹配不上 —— 返回空集合，表现为"筛选之后一章都没有"，而不是报错。
  Set<String> eidsFor({required String cid, required String? sourceKey}) {
    final prefix = key(cid: cid, sourceKey: sourceKey, eid: '');
    final result = <String>{};
    for (final entryKey in _raw.keys) {
      if (!entryKey.startsWith(prefix)) continue;
      // 坏条目（`fromJson` 返回 null）不算"已翻译"：它读的时候会被跳过，
      // 这里也不该把它当成一条存在的绑定。
      if (StudioReaderBinding.fromJson(_raw[entryKey]) == null) continue;
      result.add(entryKey.substring(prefix.length));
    }
    return result;
  }

  void remove(String key) => _raw.remove(key);

  /// 一份**只含合法条目**的普通 Map，用于写回 implicitData。
  Map<String, Object?> toJson() => {
    for (final entry in _raw.entries)
      if (StudioReaderBinding.fromJson(entry.value) case final binding?)
        entry.key: binding.toJson(),
  };
}

/// 阅读器路径 → 工程页键。
///
/// 工程页键是"相对 `directory` 的路径"（`1 [Asura Scans]/1.webp`），阅读器
/// 拿到的是绝对路径（`file://D:/…/downloads/<漫画>/1 [Asura Scans]/1.webp`），
/// 两者只差 [comicDirectory] 这个前缀。
///
/// 🔴 **前缀不匹配就返回 null，绝不猜**。这里没有"取文件名"之类的兜底：猜错的
/// 后果是给用户看**另一页**的图，而那种错在界面上看起来完全正常。
String? relativePageKey(String imagePath, String comicDirectory) {
  final path = normaliseReaderPath(imagePath);
  final root = normaliseReaderPath(comicDirectory);
  if (root.isEmpty || path.length <= root.length + 1) return null;
  // Windows 路径大小写不敏感：`D:` 与 `d:` 是同一个盘。用长度不变的折叠来比较
  // （这些路径是 ASCII + CJK，折叠不改变长度），切片仍取**原始**串，以免把
  // 页键的原始大小写改掉。
  final foldedPath = path.toLowerCase();
  final foldedRoot = root.toLowerCase();
  if (foldedPath.length != path.length || foldedRoot.length != root.length) {
    return null;
  }
  if (!foldedPath.startsWith('$foldedRoot/')) return null;
  final rel = path.substring(root.length + 1);
  return rel.isEmpty ? null : rel;
}

/// 去掉 `file://`、统一分隔符、去掉结尾斜杠。
///
/// 三者都要做：`file://D:/x/y`（阅读器给的）、`D:\x\y`（数据库里的）、
/// `D:/x/y/`（用户手填的设置）指的是同一个目录，而字符串比较区分它们。
String normaliseReaderPath(String raw) {
  var path = raw.trim();
  if (path.startsWith('file://')) path = path.substring(7);
  path = path.replaceAll('\\', '/');
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

/// [imagePath] 在 [projectPageKeys] 里对应的那个页键，没有则 null。
///
/// 比较在**归一化后**进行（分隔符 / 大小写）：工程 json 里可能是 `0\1.webp`
/// 而磁盘上是 `0/1.webp`，两者指同一页。
///
/// 🔴 只接受**完全相等**的相对路径。用"文件名相同就算同一页"会让
/// `第1话/1.webp` 撞上 `第2话/1.webp` —— 每一话的第一页都是 `1.webp`。
String? projectPageKeyFor({
  required Iterable<String> projectPageKeys,
  required String imagePath,
  required String comicDirectory,
}) {
  final rel = relativePageKey(imagePath, comicDirectory);
  if (rel == null) return null;
  final wanted = normaliseReaderPath(rel).toLowerCase();
  for (final key in projectPageKeys) {
    if (normaliseReaderPath(key).toLowerCase() == wanted) return key;
  }
  return null;
}

/// 这一章里**还需要跑**的页。
///
/// 判据只有一条：`result/` 还没有的页。
///
/// 🔴 用 `result/`（最终产物）而不是 `mask/`/`inpainted/`：后两者是中间态，而
/// "有 `inpainted/` 没有 `result/`"恰恰正是**需要重跑**的那种页 —— S9.5-a 的
/// 78 页就是这个状态。拿中间态当"跑过了"，那一批页会永远不再被处理。
///
/// [chapterPages] 的顺序即执行顺序（阅读顺序），排序由调用方负责。
List<String> studioPagesNeedingWork({
  required List<String> chapterPages,
  required Set<String> pagesWithResult,
}) {
  return [
    for (final page in chapterPages)
      if (!pagesWithResult.contains(page)) page,
  ];
}

/// 一个工程里属于 [chapterName] 这一章的页键，**保持工程给的顺序**。
///
/// 输入是 `project.pageOrder`（工程自己排好的键序），输出是它的一个**子序列**
/// —— 顺序不动，因为执行顺序就是阅读顺序（进度条与用户翻页的顺序一致）。
///
/// 🔴 判据是 `'<chapterName>/'` **前缀**，与阅读器算章节目录名用的是同一条
/// （`chapterDirectoryName`）。不按"文件名"判：每一话的第一页都叫 `1.webp`，
/// 按文件名匹配会让 `第2话` 的页混进 `第1话`。
///
/// [chapterName] 为空 = 无章节的漫画：页直接躺在工程根下，**全部**都属于它。
List<String> studioChapterPageKeys({
  required List<String> projectPageKeys,
  required String chapterName,
}) {
  final prefix = normaliseReaderPath(chapterName);
  if (prefix.isEmpty) return List<String>.of(projectPageKeys);
  // Windows 路径大小写不敏感（json 里可能是 `1 [Asura Scans]`，磁盘上是
  // `1 [asura scans]`）。比较用折叠串，**输出仍取原始键**，免得把页键的原始
  // 大小写改掉、之后对不上 `result/` 的文件名。
  final wanted = '${prefix.toLowerCase()}/';
  return [
    for (final key in projectPageKeys)
      if (normaliseReaderPath(key).toLowerCase().startsWith(wanted)) key,
  ];
}
