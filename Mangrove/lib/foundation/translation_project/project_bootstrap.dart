import 'dart:io';

import 'project.dart';
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
    this.project,
    this.report,
    this.error,
  });

  /// 工程目录（`<projectsRoot>/<name>`）。
  final String root;

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

/// 从一本**已下载的漫画**开一个工作室工程（`A08 §5` · `P6 §4.10.2` 表 #3）。
///
/// 三条硬约束，与离线工具 `tools/_make_chapter_carrier.py` 同源：
///
/// 1. **原图不复制** —— `directory` 指向 `downloads/<漫画>`，产物落在
///    `projects/<工程名>`。复制 94×852KB 既慢又没意义。
/// 2. **`projects/` 必须是 `downloads/` 的兄弟** —— 章节目录内出现任何子目录
///    → 本地库扫描器**整本拒绝**（`A03 §1`）。所以 [rootIsSafe] 直接禁掉
///    把工程建在源目录里。
/// 3. **json 只写实测字段** —— `image_info` 只有 `width`/`height`，**不写
///    `workspace` 键**（FT 自己也不写；写了就是编造，会让零字节 diff 失败）。
///
/// 整个文件**零 Flutter 依赖**，所以能在 `init()` 之前被 headless 验证。
abstract final class ProjectBootstrap {
  ProjectBootstrap._();

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
  static Map<String, Object?> buildRaw(ProjectBootstrapPlan plan) {
    final keys = plan.pageKeys;
    return <String, Object?>{
      'directory': normalizeDirectoryPath(plan.comicDirectory),
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

  /// 把 [plan] 落成 `<projectsRoot>/<name>/imgtrans_<name>.json`。
  ///
  /// 目标已存在且 [force] 为 false 时**什么都不写**，返回 `created: false`
  /// —— 静默覆盖用户已有的工程是最坏的一种失败。
  static Future<ProjectBootstrapResult> create({
    required String projectsRoot,
    required String name,
    required ProjectBootstrapPlan plan,
    bool force = false,
    bool ensureArtifactDirectories = true,
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

    final project = TranslationProject.buildFrom(buildRaw(plan), jsonFile);
    // 🔴 只给 `directory`，**不给 `workspace`**：`ProjectWriter.save` 只在传了
    // 的时候写这两个键，所以不传 = json 里没有 `workspace`，与 FT 一致，
    // 而 `TranslationProject.workspace` 会回落到 json 的父目录 —— 正是我们要的
    // 「产物落在 projects/ 下」。
    final report = await ProjectWriter.save(
      root: root,
      project: project,
      jsonFileName: jsonFileName,
      directory: normalizeDirectoryPath(plan.comicDirectory),
      ensureArtifactDirectories: ensureArtifactDirectories,
    );
    return ProjectBootstrapResult(
      root: root,
      jsonFile: report.jsonFile,
      created: true,
      project: project,
      report: report,
    );
  }
}
