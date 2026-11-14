import 'dart:io';

import 'package:mangrove/foundation/log.dart';

import 'project.dart';
import 'project_io.dart';
import 'project_writer.dart';
import 'studio_project_meta.dart';

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
    this.chapters = const {},
  });

  /// 源漫画根目录（`ComicLibrary/downloads/<漫画>`）。工程只**引用**它，不复制。
  final String comicDirectory;

  /// 章节目录名（相对 [comicDirectory]）。整本漫画计划（[chapters] 非空）时为
  /// 空串，此时以 [chapters] 为准。
  final String chapterName;

  /// 页键，形如 `<章节>/<文件名>`，正斜杠，按阅读顺序（数字页按数值排）。
  ///
  /// 单章节计划 = 那一章的页；整本漫画计划 = 所有章节的页（[chapters] 展平）。
  final List<String> pageKeys;

  /// 实测到的尺寸。
  ///
  /// 🔴 **读不出尺寸的页不在这个表里，但仍然在 [pageKeys] 里** —— 「量不出
  /// 宽高」和「这一页不存在」是两件事，前者不能让页静默消失（A02 §7.1 空结果
  /// 判 FAIL 的同源错误：把"没量到"当成"没有"）。
  final Map<String, PageImageSize> sizes;

  /// 整本漫画计划的多章节结构：章节名 → 该章页键（格式同 [pageKeys]）。
  ///
  /// 🔴 P53：空 = 单章节计划（用 [chapterName] + [pageKeys]）；非空 = 整本
  /// 漫画计划。`buildRaw` 据此决定 json 里写几个 `chapters` 条目。两个字段
  /// 互斥承载，[pageKeys] 始终是 [chapters] 展平后的全集，供复用逻辑只读一份。
  final Map<String, List<String>> chapters;

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

/// 一次「把 `source/` 链接到原件目录」的结果。
class ProjectBootstrapLink {
  const ProjectBootstrapLink({
    required this.linked,
    this.copied = const [],
    this.missing = const [],
  });

  /// 是否成功建立了 junction/符号链接（true 表示**未复制**原件）。
  final bool linked;

  /// 链接失败回退复制时成功复制的页键。
  final List<String> copied;

  /// 链接失败回退复制时源文件不在的页键。
  final List<String> missing;

  int get copiedCount => copied.length;
  int get missingCount => missing.length;
}

/// 一次「建/复用漫画级工程根」的结果。
class ProjectComicRoot {
  const ProjectComicRoot({
    required this.root,
    required this.meta,
    required this.created,
  });

  /// 漫画级工程根（`<projectsRoot>/<工程名>`）。
  final String root;

  /// 落盘后的漫画级边车。
  final StudioProjectMeta meta;

  /// 本次是否新建（false = 复用了已有的漫画级根）。
  final bool created;
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

  /// 漫画根下存"季封 / 特典封面"的目录名（应用自己写的，**不是**一章）。
  static const String coverDirectoryName = 'cover';

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

  /// 扫描**整本漫画**的所有章节，产出涵盖全部页键的整本计划。
  ///
  /// 🔴 P53：翻译工程从「每章一个」改为「每本一个」。本方法把漫画根下每个章节
  /// 子目录的页都收进来，`chapters` 字段承载「章节名 → 页键」结构；扁平漫画
  /// （页直接躺在根下、无章节子目录）则回落到单章节计划（[chapterName] 为空）。
  ///
  /// [chapterNames] 是**权威章节表**（来自本地库 `LocalComic.chapters`，由
  /// `chapterDirectoryName` 算出）。给了它就用它，不再猜目录 —— 目录里可能有
  /// 非章节目录（`cover/`），而记录表才是"这一本有哪些话"的真相。为 null /
  /// 空时回落到扫目录（`headless create-project` 这类手里没有库的场景）。
  ///
  /// 不写任何文件、不读任何文件头以外的数据；章节目录**不递归**（与
  /// [scanPageNames] 一致：子目录意味着"这本不该被收录"）。
  static ProjectBootstrapPlan planComic({
    required String comicDirectory,
    List<String>? chapterNames,
  }) {
    final root = normalizeDirectoryPath(comicDirectory);
    final comicDir = Directory(root);
    if (!comicDir.existsSync()) {
      return ProjectBootstrapPlan(
        comicDirectory: root,
        chapterName: '',
        pageKeys: const [],
        sizes: const {},
      );
    }
    final authoritative = [
      for (final name in chapterNames ?? const <String>[])
        if (name.trim().isNotEmpty) name,
    ];
    final chapterDirs = authoritative.isEmpty
        ? comicChapterDirs(root)
        : [
            for (final name in authoritative)
              if (Directory('$root/$name').existsSync()) name,
          ];

    // 扁平漫画：没有章节子目录，页直接躺在根下。
    if (chapterDirs.isEmpty) {
      final names = scanPageNames(comicDirectory: root, chapterName: '');
      final keys = [...names];
      final sizes = <String, PageImageSize>{};
      for (var i = 0; i < names.length; i++) {
        final s = PageImageHeader.ofFile(File('$root/${names[i]}'));
        if (s != null) sizes[names[i]] = s;
      }
      return ProjectBootstrapPlan(
        comicDirectory: root,
        chapterName: '',
        pageKeys: keys,
        sizes: sizes,
      );
    }

    final chapters = <String, List<String>>{};
    final allKeys = <String>[];
    final sizes = <String, PageImageSize>{};
    for (final ch in chapterDirs) {
      final names = scanPageNames(comicDirectory: root, chapterName: ch);
      final keys = [for (final n in names) '$ch/$n'];
      chapters[ch] = keys;
      allKeys.addAll(keys);
      for (var i = 0; i < names.length; i++) {
        final s = PageImageHeader.ofFile(File('$root/$ch/${names[i]}'));
        if (s != null) sizes[keys[i]] = s;
      }
    }
    return ProjectBootstrapPlan(
      comicDirectory: root,
      chapterName: '',
      pageKeys: allKeys,
      sizes: sizes,
      chapters: chapters,
    );
  }

  /// 整本漫画的章节子目录名（跳过隐藏目录与 `cover/`、不递归），按**话号**序。
  ///
  /// 🔴 与 [planComic] 共用这一份"哪些子目录算章节"的判据：两处各写一遍，
  /// 就会出现"建工程扫到 20 章、数缺页只算 19 章"这种静默偏差。
  ///
  /// 🔴 `cover/` **必须排除**：应用自己会往漫画根写一个 `cover/` 目录存季封/
  /// 特典图（实测 `第一次告白/cover/[KR][cover]season(1).jpg`）。按"任何子目录
  /// 都是章节"扫，那张封面就会变成工程里的一页 —— 用户会在 63 话正常页中间
  /// 看到一张封面，而且它还会被送去翻译。
  static List<String> comicChapterDirs(String comicDirectory) {
    final root = normalizeDirectoryPath(comicDirectory);
    final dir = Directory(root);
    if (!dir.existsSync()) return const [];
    final names = <String>[];
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = _basename(entity.path);
      if (name.isEmpty || name.startsWith('.')) continue;
      if (name.toLowerCase() == coverDirectoryName) continue;
      names.add(name);
    }
    names.sort(_chapterNameCompare);
    return names;
  }

  /// 章节名排序：纯数字按数值、其余按字典序，数字段排在字母段之前。
  ///
  /// 与 [_pageNameCompare] 的区别：章节名不是文件名，**没有扩展名**，不能
  /// 复用"去掉最后一个点之后的部分"那套（`ch.01` 会被读成 `ch`）。
  static int _chapterNameCompare(String a, String b) {
    final na = int.tryParse(a);
    final nb = int.tryParse(b);
    if (na != null && nb != null) return na.compareTo(nb);
    if (na != null) return -1;
    if (nb != null) return 1;
    return a.compareTo(b);
  }

  /// 整本漫画的页键全集，**只列目录项、不读文件头**。
  ///
  /// [planComic] 会为每一页读 64KB 文件头拿尺寸（建工程必须），而"数缺页 /
  /// 数总页数"只要键。用它避免为了一个数字把整本的文件头读一遍。
  static List<String> planComicPageKeys(String comicDirectory) {
    final root = normalizeDirectoryPath(comicDirectory);
    if (!Directory(root).existsSync()) return const [];
    final chapters = comicChapterDirs(root);
    if (chapters.isEmpty) {
      return [...scanPageNames(comicDirectory: root, chapterName: '')];
    }
    return [
      for (final chapter in chapters)
        for (final name
            in scanPageNames(comicDirectory: root, chapterName: chapter))
          '$chapter/$name',
    ];
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
        if (plan.chapters.isNotEmpty)
          for (final entry in plan.chapters.entries)
            <String, Object?>{
              'name': entry.key,
              'pages': <Object?>[...entry.value],
            },
        if (plan.chapters.isEmpty && plan.chapterName.isNotEmpty)
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

  /// 把工程的 `source/` 链接到原件目录（**不复制**），从而工程透明读取原件。
  ///
  /// 🔴 P53：翻译工程不再复制原件以省磁盘。`source/` 是一个指向
  /// [fromDirectory]（`<ComicLibrary>/downloads/<漫画>`）的 **junction**（Windows
  /// `mklink /J`，无需管理员）或符号链接（其它平台 `ln -s`）。抹字产物
  /// （`inpainted/mask/result`）写进工程自己的 `workspace`，**绝不经过**这个
  /// 链接，所以原件只被读取、不被写入 —— 破坏性擦除风险在"不复制"模型下依旧
  /// 安全（见 [BtProjectManager] 头部说明）。
  ///
  /// 链接失败（权限/跨盘符不支持）时**回落到复制**（[copySources]），保证工程
  /// 仍可用，只是退回到占用磁盘的旧行为并打警告。
  static Future<ProjectBootstrapLink> linkSource({
    required String root,
    required ProjectBootstrapPlan plan,
    required String fromDirectory,
  }) async {
    final target = normalizeDirectoryPath('$root/$sourceDirectoryName');
    final from = normalizeDirectoryPath(fromDirectory);
    // 🔴 **父目录必须先存在**：`mklink /J` 不会替我们建父目录，缺了就直接
    // 报"系统找不到指定的路径"（实测，退出码 1）—— 而我们的回退是"复制"，
    // 于是"不复制原件"这条需求会**静默失效**，磁盘照旧被占满，界面上看不出
    // 任何异常。`copySources` 以前顺手建了这个目录，所以旧路径没暴露这个坑。
    await Directory(normalizeDirectoryPath(root)).create(recursive: true);
    if (!Directory(from).existsSync()) {
      Log.warning(
        'ProjectBootstrap',
        'Original dir missing, falling back to copy: $from',
      );
      final copy = await copySources(
        root: target,
        plan: plan,
        fromDirectory: from,
      );
      return ProjectBootstrapLink(
        linked: false,
        copied: copy.copied,
        missing: copy.missing,
      );
    }
    // 已存在（junction / 符号链接 / 普通目录）⇒ 复用，不重复建。
    //
    // 🔴 三种情况必须分开处理，混为一谈会各出一次事故：
    // * 链接且能解析 → 复用（正常）；
    // * 链接但**断了**（原件被挪走/盘符变了）→ 删掉这条坏链接再重建。
    //   不删的话 `mklink` 会报"文件已存在"，而我们又会落到复制分支 —— 复制
    //   一个不存在的源目录，工程就成空的，用户只看到"所有页都读不到图"；
    // * 普通目录（旧版本复制的副本，或某个真实目录）→ 复用，**绝不删**，
    //   删了就是删用户的产物。
    final existingType = FileSystemEntity.typeSync(target, followLinks: false);
    if (existingType == FileSystemEntityType.link) {
      if (Directory(target).existsSync()) {
        return const ProjectBootstrapLink(linked: true);
      }
      try {
        Link(target).deleteSync();
      } catch (e) {
        Log.warning('ProjectBootstrap', 'stale link unlink failed: $e');
      }
    } else if (existingType != FileSystemEntityType.notFound) {
      return const ProjectBootstrapLink(linked: true);
    }

    try {
      if (Platform.isWindows) {
        final result = await Process.run(
          'cmd',
          [
            '/c',
            'mklink',
            '/J',
            target.replaceAll('/', '\\'),
            from.replaceAll('/', '\\'),
          ],
          runInShell: false,
        );
        if (result.exitCode == 0) {
          return const ProjectBootstrapLink(linked: true);
        }
        Log.warning(
          'ProjectBootstrap',
          'mklink /J failed (${result.exitCode}): ${result.stderr}',
        );
      } else {
        final result = await Process.run('ln', ['-s', from, target]);
        if (result.exitCode == 0) {
          return const ProjectBootstrapLink(linked: true);
        }
        Log.warning(
          'ProjectBootstrap',
          'ln -s failed (${result.exitCode}): ${result.stderr}',
        );
      }
    } catch (e, s) {
      Log.error('ProjectBootstrap', 'link source failed: $e', s);
    }

    // 回退复制。
    final copy = await copySources(
      root: target,
      plan: plan,
      fromDirectory: from,
    );
    return ProjectBootstrapLink(
      linked: false,
      copied: copy.copied,
      missing: copy.missing,
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

  /// 拼 `<a>/<b>/<c>`，忽略空段（`/` 归一化）。
  static String _join(String a, String b, String c) {
    final parts = <String>[
      normalizeDirectoryPath(a),
      if (b.trim().isNotEmpty) b.trim(),
      if (c.trim().isNotEmpty) c.trim(),
    ];
    return parts.join('/');
  }

  /// 建/复用「漫画级翻译工程根」：`<projectsRoot>/<name>/`。
  ///
  /// 这一层只有两样东西：**边车**（`level: comic`，记 `comicId`/`sourceKey`/
  /// 原件目录）与**封面**。章节级工程是它的子目录（[create] 的 `parentName`）。
  ///
  /// 🔴 为什么封面是**复制**而页面是**链接**：用户要的是"创建工程不单单是命名
  /// 工程，还有配套的封面和详细信息，这些借用已有漫画的"。一页图几十上百 KB ×
  /// 上百页才是磁盘大头；封面只有一个文件，链接它省不了多少，却会在素材漫画被
  /// 移动/删除后让卡片变成空白 —— 一张没有封面的工程卡在网格里等于找不到。
  ///
  /// 🔴 幂等且**不覆盖**已有边车：漫画级根一旦建成就代表"这本已经有工程了"，
  /// 第二次进来只补缺（缺封面补封面、缺原件路径补路径），绝不改漫画归属 ——
  /// 改了就会把别人的章节工程认领走。
  static Future<ProjectComicRoot> ensureComicRoot({
    required String projectsRoot,
    required String name,
    required StudioProjectMeta meta,
    String? coverFrom,
  }) async {
    final root = _join(projectsRoot, name, '');
    await Directory(root).create(recursive: true);

    final existing = StudioProjectMeta.readFromProjectDir(root);
    final resolved = (existing != null && existing.isComicLevel) ? existing : null;

    // 封面：优先复用根下已有的 `cover.*`，否则从素材漫画复制一份。
    var cover = resolved?.cover ?? '';
    if (cover.isEmpty || !File('$root/$cover').existsSync()) {
      cover = _existingCoverName(root) ?? '';
      if (cover.isEmpty && coverFrom != null && File(coverFrom).existsSync()) {
        final dot = coverFrom.lastIndexOf('.');
        final ext = dot >= 0 ? coverFrom.substring(dot).toLowerCase() : '.jpg';
        final target = 'cover$ext';
        try {
          await File(coverFrom).copy('$root/$target');
          cover = target;
        } catch (e, s) {
          Log.error('ProjectBootstrap', 'comic cover copy failed: $e', s);
        }
      }
    }

    final next = StudioProjectMeta(
      comicId: meta.comicId,
      comicTitle: (resolved?.comicTitle.isNotEmpty ?? false)
          ? resolved!.comicTitle
          : meta.comicTitle,
      sourceKey: (resolved?.sourceKey.isNotEmpty ?? false)
          ? resolved!.sourceKey
          : meta.sourceKey,
      eid: meta.eid,
      level: StudioProjectMeta.levelComic,
      originalPath: (resolved?.originalPath.isNotEmpty ?? false)
          ? resolved!.originalPath
          : meta.originalPath,
      cover: cover,
    );
    if (resolved == null ||
        resolved.cover != next.cover ||
        resolved.originalPath != next.originalPath) {
      await StudioProjectMeta.writeToProjectDir(root, next);
    }
    return ProjectComicRoot(
      root: root,
      meta: next,
      created: resolved == null,
    );
  }

  /// 目录里已有的**工程 json**（`imgtrans_*.json`，排除产物对账表），没有则 null。
  static File? _existingProjectJson(String root) {
    final dir = Directory(normalizeDirectoryPath(root));
    if (!dir.existsSync()) return null;
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final name = _basename(entity.path);
        if (!name.startsWith('imgtrans_')) continue;
        if (!name.endsWith('.json')) continue;
        if (name.endsWith('.artifacts.json')) continue;
        return entity;
      }
    } catch (_) {
      // 列不出来就当没有（下面的"按新名字判断"仍会兜住）。
    }
    return null;
  }

  /// 工程根下已有的封面文件名（`cover.<ext>`），没有则 null。
  static String? _existingCoverName(String root) {
    for (final ext in const ['jpg', 'jpeg', 'png', 'webp']) {
      for (final name in [
        'cover.$ext',
        'COVER.$ext',
        'cover.${ext.toUpperCase()}',
      ]) {
        if (File('$root/$name').existsSync()) return name;
      }
    }
    return null;
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
    String parentName = '',
    bool force = false,
    bool ensureArtifactDirectories = true,
    bool copySources = true,
  }) async {
    // 🔴 P53：翻译工程是「漫画级根 → 章节级工程」两级。`parentName` 是漫画级
    // 根目录名（= 详情页那张卡片的身份），`name` 是章节键（源章节目录名）。
    // 布局：`<projectsRoot>/<parentName>/<name>/imgtrans_<name>.json`。
    // 不传 `parentName` 时保持老布局（`<projectsRoot>/<name>/`），供夹具与离线
    // 工具使用 —— 它们手里没有"漫画"这一层。
    final root = _join(projectsRoot, parentName, name);
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
    // 🔴 目标目录里已经有工程 json ⇒ **复用它**，不要新建第二份。
    //
    // 为什么要多这一层：工程 json 的**文件名**跟着"工程名"走，而工程名在不同
    // 时期不一样（老工程用漫画名/章节名，新约定用章节键）。所以同一章的工程
    // 在目录里的 json 可能叫 `imgtrans_做个恶女好安逸.json`，而这次要建的是
    // `imgtrans_109 [Violet Scans] [comix.to].json` —— 只按新名字判断，就会
    // 在同一个目录里**再建一份**，用户于是看到两个工程、两次翻译、两条术语表。
    final existingJson = _existingProjectJson(root);
    if (existingJson != null && !force) {
      return ProjectBootstrapResult(
        root: root,
        jsonFile: existingJson,
        created: false,
        error: '工程已存在：${_basename(existingJson.path)}（需要覆盖请显式给 force）',
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

    // 🔴 先建 source/（junction 或副本）、后写 json。顺序反过来会留下一个
    // "json 指着 source/ 而 source/ 还不存在"的中间态；`TranslationProject.directory`
    // 在目录不存在时会**静默回落**到 json 所在目录（`project.dart` 的 getter），
    // 于是那个中间态在界面上看起来完全正常，读的却是错的目录。
    //
    // 🔴 P53：产品路径一律 junction（`useJunction`）—— `source/` 是**指向原件
    // 目录的链接**，不复制一页。链接失败才回落复制（[linkSource] 内部）。
    // `copySources` 为 false 时退回旧引用布局（`directory` 直接指向源漫画目录，
    // 不建 source/），仅供夹具与离线工具。
    final bool useJunction = copySources;
    final String sourceRoot =
        useJunction ? '$root/$sourceDirectoryName' : plan.comicDirectory;
    var copied = <String>[];
    var missing = <String>[];
    if (useJunction) {
      final link = await ProjectBootstrap.linkSource(
        root: root,
        plan: plan,
        fromDirectory: plan.comicDirectory,
      );
      copied = link.copied;
      missing = link.missing;
      if (!link.linked) {
        // 链接失败、已回退复制：补封面（与旧行为一致），避免工程封面变成第一页。
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
      // link.linked == true ⇒ junction 透明，原件封面可在 `<sourceRoot>/cover.<ext>`
      // 读到，**无需复制** —— 这正是"不复制原件"要省下的那部分。
    }
    // 旧引用布局（copySources=false）什么都不做：directory 直接指向源漫画目录，
    // 封面经 directory 即可读到，无需复制。

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
