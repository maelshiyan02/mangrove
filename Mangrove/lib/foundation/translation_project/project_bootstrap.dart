import 'dart:io';

import 'package:mangrove/foundation/log.dart';

import 'project.dart';
import 'project_io.dart';
import 'project_writer.dart';

/// 一张页图的像素尺寸。
class PageImageSize {
  const PageImageSize(this.width, this.height);

  final int width;
  final int height;

  @override
  String toString() => '${width}x$height';
}

/// 只读**文件头**解析图片尺寸，不解码像素。
///
/// 🔴 存在的理由：`dart:ui` 的图像解码需要渲染表面（`A01 §3`），headless 与
/// 「批量从下载建工程」这两种场景都没有它。而 FT 的 `image_info` 只要宽高 ——
/// 读头就够了，而且不必把整张图读进内存。
///
/// 解析不出来一律返回 `null`（**不是抛异常**）：调用方把"尺寸未知"当作一种
/// 正常的页状态，页照旧进 `pages`，只是不写 `image_info` 条目。
/// 反过来若这里抛异常，一页坏图会让整本漫画建不出工程。
abstract final class PageImageHeader {
  PageImageHeader._();

  /// JPEG 的 SOF 段可能出现在任意偏移（缩略图、EXIF 之后），所以头要多读一些。
  static const int maxHeaderBytes = 64 * 1024;

  static const List<int> _pngSignature = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  ];
  static const List<int> _riffSignature = [0x52, 0x49, 0x46, 0x46];
  static const List<int> _webpSignature = [0x57, 0x45, 0x42, 0x50];
  static const List<int> _vp8xSignature = [0x56, 0x50, 0x38, 0x58];
  static const List<int> _vp8Signature = [0x56, 0x50, 0x38, 0x20];
  static const List<int> _vp8lSignature = [0x56, 0x50, 0x38, 0x4C];

  /// 读 [file] 的头部并解析尺寸。文件打不开 / 太短 / 格式不认 → `null`。
  static PageImageSize? ofFile(File file) {
    RandomAccessFile? handle;
    try {
      handle = file.openSync();
      final length = handle.lengthSync();
      if (length <= 0) return null;
      final take = length < maxHeaderBytes ? length : maxHeaderBytes;
      return ofBytes(handle.readSync(take));
    } catch (_) {
      return null;
    } finally {
      try {
        handle?.closeSync();
      } catch (_) {}
    }
  }

  /// 从一段（至少是文件开头的）字节里解析尺寸。
  static PageImageSize? ofBytes(List<int> bytes) {
    if (bytes.isEmpty) return null;
    final png = _png(bytes);
    if (png != null) return png;
    final gif = _gif(bytes);
    if (gif != null) return gif;
    final bmp = _bmp(bytes);
    if (bmp != null) return bmp;
    final webp = _webp(bytes);
    if (webp != null) return webp;
    return _jpeg(bytes);
  }

  static PageImageSize? _png(List<int> b) {
    if (!_matches(b, 0, _pngSignature) || b.length < 24) return null;
    final width = _be32(b, 16);
    final height = _be32(b, 20);
    if (width <= 0 || height <= 0) return null;
    return PageImageSize(width, height);
  }

  static PageImageSize? _gif(List<int> b) {
    if (b.length < 10) return null;
    if (b[0] != 0x47 || b[1] != 0x49 || b[2] != 0x46) return null; // 'GIF'
    if (b[3] != 0x38) return null; // '8'
    if (b[4] != 0x37 && b[4] != 0x39) return null; // '7' | '9'
    if (b[5] != 0x61) return null; // 'a'
    final width = _le16(b, 6);
    final height = _le16(b, 8);
    if (width <= 0 || height <= 0) return null;
    return PageImageSize(width, height);
  }

  static PageImageSize? _bmp(List<int> b) {
    if (b.length < 26 || b[0] != 0x42 || b[1] != 0x4D) return null; // 'BM'
    final width = _le32(b, 18);
    final height = _le32(b, 22).abs(); // 自下而上存储时高度为负
    if (width <= 0 || height <= 0) return null;
    return PageImageSize(width, height);
  }

  static PageImageSize? _webp(List<int> b) {
    if (!_matches(b, 0, _riffSignature) || !_matches(b, 8, _webpSignature)) {
      return null;
    }
    // VP8X（扩展型）：画布宽高存成 24 位的「实际值 - 1」。
    if (_matches(b, 12, _vp8xSignature)) {
      if (b.length < 30) return null;
      return PageImageSize(_le24(b, 24) + 1, _le24(b, 27) + 1);
    }
    // VP8（有损）：宽高是 14 位字段，藏在帧头里。
    if (_matches(b, 12, _vp8Signature)) {
      if (b.length < 30) return null;
      final width = _le16(b, 26) & 0x3FFF;
      final height = _le16(b, 28) & 0x3FFF;
      if (width <= 0 || height <= 0) return null;
      return PageImageSize(width, height);
    }
    // VP8L（无损）：宽高打包在一个 32 位里，各 14 位，同样存「实际值 - 1」。
    if (_matches(b, 12, _vp8lSignature)) {
      if (b.length < 25) return null;
      final bits = _le32(b, 21);
      return PageImageSize((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
    }
    return null;
  }

  static PageImageSize? _jpeg(List<int> b) {
    if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
    var offset = 2;
    while (offset + 9 < b.length) {
      if (b[offset] != 0xFF) {
        offset++;
        continue;
      }
      final marker = b[offset + 1];
      // 无长度字段的独立标记：SOI / TEM / RSTn。
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        offset += 2;
        continue;
      }
      if (marker == 0xD9) return null; // EOI：没有找到 SOF
      final segmentLength = _be16(b, offset + 2);
      if (segmentLength < 2) return null;
      // SOFn（0xC0~0xCF），排除 DHT(0xC4) / JPG(0xC8) / DAC(0xCC)。
      final isStartOfFrame =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isStartOfFrame) {
        final height = _be16(b, offset + 5);
        final width = _be16(b, offset + 7);
        if (width <= 0 || height <= 0) return null;
        return PageImageSize(width, height);
      }
      offset += 2 + segmentLength;
    }
    return null;
  }

  static bool _matches(List<int> b, int offset, List<int> signature) {
    if (b.length < offset + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (b[offset + i] != signature[i]) return false;
    }
    return true;
  }

  static int _be16(List<int> b, int i) => (b[i] << 8) | b[i + 1];

  static int _le16(List<int> b, int i) => b[i] | (b[i + 1] << 8);

  static int _be32(List<int> b, int i) =>
      (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

  static int _le32(List<int> b, int i) =>
      b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

  static int _le24(List<int> b, int i) =>
      b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
}

/// 「从下载创建工程」的一次计划：扫描一个章节目录的结果，**尚未落盘**。
///
/// 分成「计划」和「落盘」两步的理由：计划是**纯函数**（只读文件系统），
/// 因此可以在 headless 下被断言完整覆盖，而落盘那一步还牵扯红线校验。
class ProjectBootstrapPlan {
  const ProjectBootstrapPlan({
    required this.comicDirectory,
    required this.chapterName,
    required this.pageKeys,
    required this.sizes,
  });

  /// 源漫画根目录（`ComicLibrary/downloads/<漫画>`）。工程只**引用**它，不复制。
  final String comicDirectory;

  /// 章节目录名（相对 [comicDirectory]）。
  final String chapterName;

  /// 页键，形如 `<章节>/<文件名>`，正斜杠，按阅读顺序（数字页按数值排）。
  final List<String> pageKeys;

  /// 实测到的尺寸。
  ///
  /// 🔴 **读不出尺寸的页不在这个表里，但仍然在 [pageKeys] 里** —— 「量不出
  /// 宽高」和「这一页不存在」是两件事，前者不能让页静默消失（A02 §7.1 空结果
  /// 判 FAIL 的同源错误：把"没量到"当成"没有"）。
  final Map<String, PageImageSize> sizes;

  /// 头部解析失败的页键。
  List<String> get unknownSizeKeys => [
        for (final key in pageKeys)
          if (!sizes.containsKey(key)) key,
      ];

  bool get isEmpty => pageKeys.isEmpty;

  int get length => pageKeys.length;
}

/// 一次创建的结果。
class ProjectBootstrapResult {
  const ProjectBootstrapResult({
    required this.root,
    required this.jsonFile,
    required this.created,
    this.sourceRoot = '',
    this.copiedSources = const [],
    this.missingSources = const [],
    this.project,
    this.report,
    this.error,
  });

  /// 工程目录（`<projectsRoot>/<name>`）。
  final String root;

  /// 原图副本根（`<root>/source`）。json 的 `directory` 指向它 —— 见
  /// [ProjectBootstrap.sourceDirectoryName]。
  final String sourceRoot;

  /// 成功复制过来的页键。
  final List<String> copiedSources;

  /// 复制时**源文件不在**的页键。
  ///
  /// 🔴 必须上报而不是静默跳过：副本目录仍然会被创建出来（所以
  /// `TranslationProject.directory` 不会回落到 json 所在目录），但那些页在
  /// 工作室里会显示成"没有可读页图"。**"少了几页"与"页面本来就是空的"在
  /// 界面上长得一样**，只有这里的计数分得开。
  final List<String> missingSources;

  final File jsonFile;

  /// 是否真的新建了。[ProjectBootstrap.create] 遇到已存在的工程且未给
  /// `force` 时返回 `false`，**并且不动那个文件一个字节**。
  final bool created;

  /// 新建出来的工程模型（[created] 为 false 时为 null）。
  final TranslationProject? project;

  final ProjectSaveReport? report;

  /// 拒绝创建的原因（红线校验没过）。非 null 时 [created] 恒为 false。
  final String? error;

  bool get ok => error == null;
}

/// 一次「原图副本化」的搬运结果（新工程与既有工程共用）。
class ProjectBootstrapCopy {
  const ProjectBootstrapCopy({
    required this.root,
    required this.copied,
    required this.missing,
  });

  /// 副本根目录。
  final String root;

  final List<String> copied;
  final List<String> missing;

  int get copiedCount => copied.length;

  int get missingCount => missing.length;

  bool get complete => missing.isEmpty && copied.isNotEmpty;
}

/// 从一本**已下载的漫画**开一个工作室工程（`A08 §5` · `P6 §4.10.2` 表 #3）。
///
/// 三条硬约束，与离线工具 `tools/_make_chapter_carrier.py` 同源：
///
/// 1. **原图复制进 `source/`**（P10.15 §4.1 · P1 选项②）—— `directory` 指向
///    `<工程根>/source`，产物落在 `<工程根>/{mask,inpainted,result}`。
///    🔴 这条是**反过来的**：上一版刻意"不复制"，而那个决定是错的。抹字是
///    **破坏性**的（`TextInpainter.erase` 就地改像素），一旦底图取的是
///    `downloads/` 里唯一那份原图，一次逻辑错就是**擦掉用户的原图**。副本化
///    把这条风险从"数据丢失"降为"重跑一次"，代价是磁盘。
///    由此 `downloads/` 降级为**只读保底**，翻译链路不再写它。
/// 2. **`projects/` 必须是 `downloads/` 的兄弟** —— 章节目录内出现任何子目录
///    → 本地库扫描器**整本拒绝**（`A03 §1`）。所以 [rootIsSafe] 直接禁掉
///    把工程建在源目录里。
/// 3. **json 只写实测字段** —— `image_info` 只有 `width`/`height`，**不写
///    `workspace` 键**（FT 自己也不写；写了就是编造，会让零字节 diff 失败）。
///    副本化之后 `directory` 仍然**是**要写的（它本来就有这个键），只是值从
///    下载目录改成了副本目录。
///
/// 整个文件**零 Flutter 依赖**，所以能在 `init()` 之前被 headless 验证。
abstract final class ProjectBootstrap {
  ProjectBootstrap._();

  /// 原图副本所在的子目录名（相对工程根）。
  ///
  /// 🔴 放在工程根下、与 `mask/` `inpainted/` `result/` 平级：这样
  /// `TranslationProject.workspace`（= json 所在目录）与 `directory`
  /// （= `<root>/source`）是两个**真实存在**的不同目录，双 root 分离
  /// （`ProjectWriter` 的「Two roots, one implementation」）才真正成立。
  static const String sourceDirectoryName = 'source';

  /// 与本地库扫描器一致的白名单（`A03 §1`），不是 `TranslationProject` 那份
  /// 更宽的名单 —— 这里扫的是下载目录，读者把什么当页，我们就认什么。
  static const Set<String> pageImageExtensions = {
    '.jpg',
    '.jpeg',
    '.jpe',
    '.png',
    '.webp',
    '.gif',
  };

  /// 统一成正斜杠并去掉结尾斜杠。
  ///
  /// 🔴 不能无脑 `replaceAll(RegExp(r'/+$'), '')`：`D:/` 会被削成 `D:`。
  static String normalizeDirectoryPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final trimmed = normalized.replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isEmpty) return normalized;
    if (RegExp(r'^[A-Za-z]:$').hasMatch(trimmed)) return normalized;
    return trimmed;
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash < 0 ? normalized : normalized.substring(slash + 1);
  }

  /// 扫出 [chapterName] 目录里的页图**文件名**（按阅读顺序）。**不写任何文件，
  /// 也不读任何文件头。**
  ///
  /// 🔴 [plan] 与"建工程入口"的可选性判断**共用这一个实现**：入口要在列表里
  /// 把"扫不出页图的章节"灰掉，而"灰掉的判据"与"真的建不出来"必须是同一条
  /// —— 各写一遍就会出现"列表里可选、点下去报 chapter-has-no-page"。
  /// 这里刻意**不**返回尺寸：列出章节的可选性时，读 94 个文件头只为数个数
  /// 是纯浪费，而 [plan] 需要的尺寸在它自己那里补齐。
  static List<String> scanPageNames({
    required String comicDirectory,
    required String chapterName,
  }) {
    final root = normalizeDirectoryPath(comicDirectory);
    final chapter = chapterName
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    final chapterDir = Directory('$root/$chapter');

    final names = <String>[];
    if (chapterDir.existsSync()) {
      // 🔴 刻意不递归：本地库把章节目录当扁平目录，子目录意味着"这本不该
      // 被收录"。递归进去会把别人的素材当成页。
      for (final entity in chapterDir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final name = _basename(entity.path);
        final dot = name.lastIndexOf('.');
        if (dot < 0) continue;
        if (!pageImageExtensions.contains(name.substring(dot).toLowerCase())) {
          continue;
        }
        names.add(name);
      }
    }
    names.sort(_pageNameCompare);
    return names;
  }

  /// 扫描 [chapterName] 目录，产出页键与实测尺寸。**不写任何文件。**
  static ProjectBootstrapPlan plan({
    required String comicDirectory,
    required String chapterName,
  }) {
    final root = normalizeDirectoryPath(comicDirectory);
    final chapter = chapterName
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    final chapterDir = Directory('$root/$chapter');

    final names = scanPageNames(
      comicDirectory: comicDirectory,
      chapterName: chapterName,
    );

    final keys = [for (final name in names) '$chapter/$name'];
    final sizes = <String, PageImageSize>{};
    for (var i = 0; i < names.length; i++) {
      final size = PageImageHeader.ofFile(File('${chapterDir.path}/${names[i]}'));
      if (size != null) sizes[keys[i]] = size;
    }
    return ProjectBootstrapPlan(
      comicDirectory: root,
      chapterName: chapter,
      pageKeys: keys,
      sizes: sizes,
    );
  }

  /// 🔴 数字页按**数值**排，不是字典序 —— 否则 `10.webp` 会排在 `2.webp` 前面。
  static int _pageNameCompare(String a, String b) {
    final keyA = _pageOrderKey(a);
    final keyB = _pageOrderKey(b);
    if (keyA.$1 != keyB.$1) return keyA.$1.compareTo(keyB.$1);
    if (keyA.$1 == 0) return (keyA.$2 as int).compareTo(keyB.$2 as int);
    return (keyA.$2 as String).compareTo(keyB.$2 as String);
  }

  /// `(0, 数值)` 表示纯数字文件名，`(1, 词干)` 表示其余。
  static (int, Object) _pageOrderKey(String name) {
    final dot = name.lastIndexOf('.');
    final stem = dot < 0 ? name : name.substring(0, dot);
    final value = int.tryParse(stem);
    return value == null ? (1, stem) : (0, value);
  }

  /// 按 FT 的键序组装工程 JSON。
  ///
  /// 键序刻意与 `TranslationProject.create` / FT 一致，这样「建完立刻存一次」
  /// 看起来就像是 FT 自己写的。
  ///
  /// [directory] 覆盖 `directory` 的值。默认是 [ProjectBootstrapPlan] 记下的
  /// **源漫画目录**（= 不复制的那种布局，纯函数测试用）；[create] 传的是
  /// 副本目录 —— 于是"`directory` 到底指向哪"这件事只有**一个**写入点，
  /// 而不是"计划里一个、落盘时又改一个"。
  static Map<String, Object?> buildRaw(
    ProjectBootstrapPlan plan, {
    String? directory,
  }) {
    final keys = plan.pageKeys;
    return <String, Object?>{
      'directory': normalizeDirectoryPath(directory ?? plan.comicDirectory),
      'pages': <String, Object?>{for (final key in keys) key: <Object?>[]},
      'current_img': keys.isEmpty ? '' : keys.first,
      'image_info': <String, Object?>{
        for (final key in keys)
          if (plan.sizes[key] case final size?)
            key: <String, Object?>{'width': size.width, 'height': size.height},
      },
      'page_order': <Object?>[...keys],
      'chapters': <Object?>[
        if (plan.chapterName.isNotEmpty)
          <String, Object?>{
            'name': plan.chapterName,
            'pages': <Object?>[...keys],
          },
      ],
    };
  }

  /// 把 [plan] 里的页图**逐个复制**到 [root] 下，保持 `<章节>/<文件名>` 结构。
  ///
  /// [root] **一定会被建出来**，即使一页都没复制成功 —— 于是
  /// `TranslationProject.directory` 不会静默回落到 json 所在目录，缺图表现为
  /// "这一页没有可读原图"而不是"悄悄读错目录"。
  ///
  /// 🔴 为什么是"逐个页键"而不是"整个章节目录复制"：`plan.pageKeys` 里只有
  /// 扫描器认得的**页图**（白名单扩展名 + 不递归），而整目录复制会把
  /// `notes.txt`、`.DS_Store`、子目录一起搬过来 —— 那些东西出现在工程根下
  /// 只会让后续"这一页为什么在"变成一个问题。
  static Future<ProjectBootstrapCopy> copySources({
    required String root,
    required ProjectBootstrapPlan plan,
    required String fromDirectory,
  }) async {
    final targetRoot = normalizeDirectoryPath(root);
    final sourceRoot = normalizeDirectoryPath(fromDirectory);
    // 🔴 一页都没有也要把副本根建出来：`TranslationProject.directory` 在目录
    // **不存在**时会静默回落到 json 所在目录（`project.dart` 的 getter），于是
    // 「json 指着 `source/` 而 `source/` 还没建」这个中间态在界面上完全正常，
    // 读的却是错的目录。建出来就把这种静默堵死 —— 缺图的页会明明白白地变成
    // 「这一页没有可读原图」，而不是悄悄换一个目录去找图。
    await Directory(targetRoot).create(recursive: true);
    final copied = <String>[];
    final missing = <String>[];
    for (final key in plan.pageKeys) {
      final from = File('$sourceRoot/$key');
      if (!from.existsSync()) {
        missing.add(key);
        continue;
      }
      final to = File('$targetRoot/$key');
      if (!to.parent.existsSync()) {
        await to.parent.create(recursive: true);
      }
      await from.copy(to.path);
      copied.add(key);
    }
    return ProjectBootstrapCopy(
      root: targetRoot,
      copied: copied,
      missing: missing,
    );
  }

  /// 落盘前校验。返回 `null` 表示可以建，否则是人能读的拒绝理由。
  ///
  /// 🔴 这里挡的是**唯一一条会造成不可逆后果的红线**：产物写进 `downloads/`
  /// → 该漫画整本从本地库消失（`A03 §1`）。
  static String? validate({
    required String projectsRoot,
    required String comicDirectory,
    required String name,
  }) {
    if (name.trim().isEmpty) return '工程名为空';
    if (name.contains('/') || name.contains('\\')) {
      return '工程名不能含路径分隔符：$name';
    }
    if (!Directory(normalizeDirectoryPath(comicDirectory)).existsSync()) {
      return '源漫画目录不存在：$comicDirectory';
    }
    if (!rootIsSafe(projectsRoot, comicDirectory)) {
      return '工程根不能落在源漫画目录内（会让本地库整本拒绝这本漫画）：'
          '$projectsRoot ⊆ $comicDirectory';
    }
    return null;
  }

  /// [projectsRoot] 是否安全（不是源目录，也不是它的子目录）。
  static bool rootIsSafe(String projectsRoot, String comicDirectory) {
    final root = normalizeDirectoryPath(projectsRoot).toLowerCase();
    final source = normalizeDirectoryPath(comicDirectory).toLowerCase();
    if (root == source) return false;
    if (root.startsWith('$source/')) return false;
    return true;
  }

  /// 把 [plan] 落成 `<projectsRoot>/<name>/imgtrans_<name>.json`，并把页图
  /// 复制进 `<projectsRoot>/<name>/source/`（§4.1）。
  ///
  /// 目标已存在且 [force] 为 false 时**什么都不写**，返回 `created: false`
  /// —— 静默覆盖用户已有的工程是最坏的一种失败。
  ///
  /// `copySources` 为 false 时退回旧布局（`directory` 直接指向源漫画目录）。
  /// 只留给夹具与离线工具，产品路径**一律复制**。
  static Future<ProjectBootstrapResult> create({
    required String projectsRoot,
    required String name,
    required ProjectBootstrapPlan plan,
    bool force = false,
    bool ensureArtifactDirectories = true,
    bool copySources = true,
  }) async {
    final root = '${normalizeDirectoryPath(projectsRoot)}/$name';
    final jsonFileName = TranslationProject.jsonFileNameFor(name);
    final jsonFile = File(ProjectWriter.jsonPath(root, jsonFileName));

    final refusal = validate(
      projectsRoot: projectsRoot,
      comicDirectory: plan.comicDirectory,
      name: name,
    );
    if (refusal != null) {
      return ProjectBootstrapResult(
        root: root,
        jsonFile: jsonFile,
        created: false,
        error: refusal,
      );
    }
    if (jsonFile.existsSync() && !force) {
      return ProjectBootstrapResult(
        root: root,
        jsonFile: jsonFile,
        created: false,
        error: '工程已存在：$jsonFileName（需要覆盖请显式给 force）',
      );
    }

    // 🔴 先复制、后写 json。顺序反过来会留下一个"json 指着 source/ 而
    // source/ 还不存在"的中间态；`TranslationProject.directory` 在目录不存在
    // 时会**静默回落**到 json 所在目录（`project.dart` 的 getter），于是那个
    // 中间态在界面上看起来完全正常，读的却是错的目录。
    final sourceRoot =
        copySources ? '$root/$sourceDirectoryName' : plan.comicDirectory;
    var copied = <String>[];
    var missing = <String>[];
    if (copySources) {
      final copy = await ProjectBootstrap.copySources(
        root: sourceRoot,
        plan: plan,
        fromDirectory: plan.comicDirectory,
      );
      copied = copy.copied;
      missing = copy.missing;
      // 🔴 封面优先用**原漫画自带的封面**（`comicDirectory/cover.<ext>`），而不是
      // 复制好的第一页 —— 工程封面该是"这一本"的封面，而章节第一页可能是扉页/
      // 广告/版权页（P9 实测：龙女友两话工程因此都用了第一页当封面）。
      // 原漫画没有封面时才回落到第一页（老行为）。
      //
      // 落点仍是工程根 `root`：`BtProjectManager.coverPathFor` 现在**两处都查**
      // （`source/` 与工程根），所以新老工程都能命中，无需迁移文件。
      final comicCover = comicCoverPathIn(plan.comicDirectory);
      if (comicCover != null) {
        final dot = comicCover.lastIndexOf('.');
        final ext = dot >= 0 ? comicCover.substring(dot) : '';
        try {
          await File(comicCover).copy('$root/cover$ext');
        } catch (e, s) {
          Log.error('ProjectBootstrap', 'comic cover copy failed: $e', s);
        }
      } else if (copied.isNotEmpty) {
        final firstKey = copied.first;
        final dot = firstKey.lastIndexOf('.');
        final ext = dot >= 0 ? firstKey.substring(dot) : '';
        final coverFrom = File('$sourceRoot/$firstKey');
        final coverTo = File('$root/cover$ext');
        try {
          await coverFrom.copy(coverTo.path);
        } catch (e, s) {
          Log.error('ProjectBootstrap', 'cover image copy failed: $e', s);
        }
      }
    }

    final project = TranslationProject.buildFrom(
      buildRaw(plan, directory: sourceRoot),
      jsonFile,
    );
    // 🔴 只给 `directory`，**不给 `workspace`**：`ProjectWriter.save` 只在传了
    // 的时候写这两个键，所以不传 = json 里没有 `workspace`，与 FT 一致，
    // 而 `TranslationProject.workspace` 会回落到 json 的父目录 —— 正是我们要的
    // 「产物落在 projects/ 下」。
    final report = await ProjectWriter.save(
      root: root,
      project: project,
      jsonFileName: jsonFileName,
      directory: normalizeDirectoryPath(sourceRoot),
      ensureArtifactDirectories: ensureArtifactDirectories,
    );
    return ProjectBootstrapResult(
      root: root,
      jsonFile: report.jsonFile,
      created: true,
      sourceRoot: normalizeDirectoryPath(sourceRoot),
      copiedSources: copied,
      missingSources: missing,
      project: project,
      report: report,
    );
  }

  /// 原漫画自带的封面（`comicDirectory/cover.<ext>`）；没有则 null。
  ///
  /// 🔴 漫画名普遍太长，卡片上要靠**封面图像**来认书，所以工程封面必须是
  /// "这一本"的封面，而不是复制进来的某一页。抽成函数而不是内联在 `create`
  /// 里，是为了让"原封面优先于第一页"这条规则能被 headless 单独打红 ——
  /// 内联的话它只能跟着整次 `create` 一起被验，故障定位不了。
  ///
  /// 与 `BtProjectManager.coverKeyFor` 同序同集合（jpg/jpeg/png/webp）：两处
  /// 各写一份扩展名列表迟早会漂，漂的后果是"能复制但读不到"。
  static String? comicCoverPathIn(String comicDirectory) {
    if (comicDirectory.isEmpty) return null;
    for (final ext in const ['jpg', 'jpeg', 'png', 'webp']) {
      final path = '$comicDirectory/cover.$ext';
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// 把一个**已经存在**的工程从"引用 `downloads/` 原图"迁到"自带
  /// `<工程根>/source/` 副本"（§4.1 · P1 选项② 的既有工程那一半）。
  ///
  /// ## 为什么要有这个入口
  ///
  /// 新建工程已经自带副本，但 `MDGH-ch1` 这种**在改动之前建的**工程，json 的
  /// `directory` 仍然指着下载目录。而抹字是破坏性的 —— 那份下载目录是用户
  /// **唯一**一份原图。这条迁移就是把它复制进来、然后把 `directory` 指过去。
  ///
  /// ## 幂等
  ///
  /// 已经迁过的工程（`directory` 已经指向一个存在的 `source/`，且所有页图都在）
  /// 直接返回 `alreadyMigrated: true` 且一个字节都不写。再点一次不会重复复制，
  /// 也不会把 `directory` 改成别的东西。
  ///
  /// ## 顺序
  ///
  /// 复制全部成功**之后**才改 json。中途失败（源文件缺、磁盘满）时 json
  /// 保持原样 —— 半迁移状态（json 指着不存在的 `source/`）会触发
  /// `TranslationProject.directory` 的静默回落，读的是错目录而界面上看不出来。
  static Future<ProjectBootstrapMigration> migrateSources({
    required File jsonFile,
    bool copyAllPages = true,
  }) async {
    final project = await TranslationProjectIo.load(jsonFile);
    final current = project.directory;
    final desired = '${project.jsonDirectory}/$sourceDirectoryName';

    final imageKeys = [
      for (final key in project.pageOrder)
        if (TranslationProject.isImagePage(key)) key,
    ];
    // 已经指向一个真实存在的 source/，且页图齐全 ⇒ 无事可做。
    if (normalizeDirectoryPath(current) == normalizeDirectoryPath(desired) &&
        Directory(desired).existsSync() &&
        imageKeys.every((key) => File('$desired/$key').existsSync())) {
      return ProjectBootstrapMigration(
        jsonFile: jsonFile,
        previousDirectory: current,
        directory: desired,
        alreadyMigrated: true,
        copied: [
          for (final key in imageKeys)
            if (File('$desired/$key').existsSync()) key,
        ],
        missing: const [],
        wroteJson: false,
      );
    }

    // 源 = 工程**当前**解析出来的 directory（可能已经是副本目录，那说明上一
    // 次迁了一半；从它继续复制是安全的，因为副本目录是只读保底）。
    final copy = await ProjectBootstrap.copySources(
      root: desired,
      plan: ProjectBootstrapPlan(
        comicDirectory: current,
        chapterName: '',
        pageKeys: copyAllPages ? imageKeys : const [],
        sizes: const {},
      ),
      fromDirectory: current,
    );
    // 🔴 少了页就**不改 json**：只复制到一半就改 `directory` 会让缺的那些页
    // 静默变成"这一页没有原图"。宁可让调用方看到 missing 并重跑。
    if (copy.missing.isNotEmpty) {
      return ProjectBootstrapMigration(
        jsonFile: jsonFile,
        previousDirectory: current,
        directory: current,
        alreadyMigrated: false,
        copied: copy.copied,
        missing: copy.missing,
        wroteJson: false,
      );
    }

    await ProjectWriter.save(
      root: project.jsonDirectory,
      project: project,
      directory: normalizeDirectoryPath(desired),
      // 既有工程的产物目录早就在了；这里再建一次是幂等的，且能补上缺失的。
      ensureArtifactDirectories: true,
    );
    return ProjectBootstrapMigration(
      jsonFile: jsonFile,
      previousDirectory: current,
      directory: normalizeDirectoryPath(desired),
      alreadyMigrated: false,
      copied: copy.copied,
      missing: const [],
      wroteJson: true,
    );
  }
}

/// 一次「既有工程原图副本化」的结果。
class ProjectBootstrapMigration {
  const ProjectBootstrapMigration({
    required this.jsonFile,
    required this.previousDirectory,
    required this.directory,
    required this.alreadyMigrated,
    required this.copied,
    required this.missing,
    required this.wroteJson,
  });

  final File jsonFile;
  final String previousDirectory;

  /// 迁移**之后**应有的 `directory`（[wroteJson] 为 false 时说明没改成功，
  /// 值仍是 [previousDirectory]）。
  final String directory;

  /// 本来就已经迁过，一个字节都没写。
  final bool alreadyMigrated;

  final List<String> copied;
  final List<String> missing;

  /// 是否真的改写了 json。
  final bool wroteJson;

  bool get ok => missing.isEmpty && (wroteJson || alreadyMigrated);
}
