import 'dart:io';

import 'package:path/path.dart' as p;

/// 便携根探测与"搬家自愈"——所有在磁盘上以**绝对路径**记录数据本体位置的
/// 地方（`local_path`、`settings['btProjectRoot']`、工程 json 的 `directory`、
/// 漫画源目录），在整个项目目录被移动/改名后统一从这里找回新位置。
///
/// ## 背景
///
/// 旧实现把库根明文写在 `%APPDATA%/.../local_path`、把工程根写在
/// `appdata.json['btProjectRoot']`、把原图强根写在每个工程 json 的
/// `directory`。项目从 `D:\Mangrove_Windows` 搬到工作区后，这三处全部指向
/// 不存在的旧目录：库根静默回落成空的默认目录（已下载漫画"全部消失"），
/// 工程扫描整根跳过，工程打开后原图落到 json 父目录。
///
/// ## 便携根（portable root）
///
/// 从可执行文件所在目录**向上最多 6 级**，找第一个满足下列任一签名的目录 `P`：
///
/// 1. 显式标志文件 `P/mangrove.portable`（用户主动声明，最强意图）；
/// 2. 隐式签名 `P/ComicLibrary/downloads` 目录存在（项目树自带，无需任何操作）。
///
/// 部署态 `builds/mangrove/mangrove.exe` 上溯 2 级命中项目根；开发态
/// `build/windows/x64/runner/Debug/mangrove.exe` 上溯 5 级命中源码根。
/// 探测只走 exe 的直系祖先、深度有界、且必须有签名目录，不会误中
/// `Program Files` 之类的位置。
///
/// ## 自愈后写回"相对形式"
///
/// 自动重定位成功时，`local_path` / `btProjectRoot` 回写成**相对便携根**的
/// 形式（`ComicLibrary/downloads`），而不是新的绝对路径——以后再搬一次家，
/// 连自愈动作都不需要，解析时直接按便携根重放。用户在设置里**手动选择**的
/// 库目录（可能在移动硬盘等项目树之外）保持绝对路径不动。
///
/// 本文件只用 `dart:io` 与 `package:path`，不引任何 Flutter binding，
/// 因此能被 headless 自检（App 启动前）直接打红。
class PathRoots {
  PathRoots._();

  /// 便携根下的固定布局（与 `A03 §1` 的三个根一致）。
  static const String libraryDirName = 'ComicLibrary';
  static const String downloadsDirName = 'downloads';
  static const String projectsDirName = 'projects';
  static const String translatedDirName = 'translated';

  /// 漫画源脚本目录（与 `%APPDATA%/.../comic_source` 同名）。
  static const String comicSourceDirName = 'comic_source';

  /// 用户主动声明便携根的标志文件名。
  static const String portableMarkerFile = 'mangrove.portable';

  /// 向上探测的最大层数：覆盖开发态最深的
  /// `build/windows/x64/runner/Debug`（5 级）。
  static const int maxAscent = 6;

  /// LocalManager 解析出的**当前生效** downloads 根。工程 json 的
  /// `directory` 重基时以它为锚；未注册（headless 纯函数测试）时只能用
  /// 便携根探测结果。
  static String? currentDownloadsRoot;

  static String? _exeDirOverride;
  static String? _cachedPortableRoot;
  static bool _probed = false;

  /// 仅供 headless/单测注入 exe 目录；生产代码不要调用。
  static void debugOverride({String? exeDir, String? downloadsRoot}) {
    _exeDirOverride = exeDir;
    currentDownloadsRoot = downloadsRoot;
    _cachedPortableRoot = null;
    _probed = false;
  }

  static String _normalize(String path) =>
      p.normalize(path).replaceAll('\\', '/');

  /// 路径是否为绝对路径（覆盖 Windows 盘符与 UNC；非 Windows 上以 `/` 起头）。
  static bool isAbsolute(String path) {
    final t = path.trim();
    if (t.isEmpty) return false;
    if (Platform.isWindows) {
      return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(t) || t.startsWith(r'\\');
    }
    return t.startsWith('/');
  }

  /// 便携根探测（结果缓存）。找不到返回 null——所有调用方必须把 null
  /// 当作"没有便携布局，维持旧行为"处理。
  static String? portableRoot() {
    if (_probed) return _cachedPortableRoot;
    _probed = true;
    final exeDir =
        _exeDirOverride ?? p.dirname(Platform.resolvedExecutable);
    return _cachedPortableRoot = probePortableRoot(exeDir: exeDir);
  }

  /// 纯函数版探测：从 [exeDir] 逐级上溯找签名目录。
  static String? probePortableRoot({required String exeDir}) {
    var dir = p.normalize(exeDir);
    String? prev;
    for (var i = 0; i <= maxAscent && dir != prev; i++) {
      final marker = File(p.join(dir, portableMarkerFile));
      final libraryDownloads = Directory(
        p.join(dir, libraryDirName, downloadsDirName),
      );
      if (marker.existsSync() || libraryDownloads.existsSync()) {
        return _normalize(dir);
      }
      prev = dir;
      dir = p.dirname(dir);
    }
    return null;
  }

  /// `<root>/ComicLibrary/downloads`（不检查存在性）。便携根未知时为 null
  /// —— 绝不能退化成相对 cwd 的路径，否则 cwd 下恰好有同名目录会被误判
  /// 成库根（headless/计划任务的 cwd 可能正好是仓库根）。
  static String? joinLibrary(String? root) {
    final base = root ?? portableRoot();
    if (base == null || base.isEmpty) return null;
    return p.join(base, libraryDirName, downloadsDirName);
  }

  /// `<root>/ComicLibrary/projects`。
  static String? joinProjects(String? root) {
    final base = root ?? portableRoot();
    if (base == null || base.isEmpty) return null;
    return p.join(base, libraryDirName, projectsDirName);
  }

  /// `<root>/comic_source`。
  static String? joinComicSource(String? root) {
    final base = root ?? portableRoot();
    if (base == null || base.isEmpty) return null;
    return p.join(base, comicSourceDirName);
  }

  /// 便携布局下的 downloads 根（**存在才返回**）。
  static String? portableLibraryRoot([String? root]) {
    final candidate = joinLibrary(root);
    if (candidate == null) return null;
    final normalized = _normalize(candidate);
    return Directory(normalized).existsSync() ? normalized : null;
  }

  /// 便携布局下的 projects 根（**存在才返回**）。
  static String? portableProjectsRoot([String? root]) {
    final candidate = joinProjects(root);
    if (candidate == null) return null;
    final normalized = _normalize(candidate);
    return Directory(normalized).existsSync() ? normalized : null;
  }

  /// 便携布局下的漫画源目录（**存在才返回**）。
  static String? portableComicSourceDir([String? root]) {
    final candidate = joinComicSource(root);
    if (candidate == null) return null;
    final normalized = _normalize(candidate);
    return Directory(normalized).existsSync() ? normalized : null;
  }

  /// 把绝对路径转成"相对便携根"的正斜杠形式；不在便携根下时返回 null。
  static String? relativeToPortable(String absolutePath, {String? root}) {
    final base = root ?? portableRoot();
    if (base == null) return null;
    final rel = p.relative(p.normalize(absolutePath), from: base);
    if (rel == '..' || rel.startsWith('..${p.separator}')) return null;
    return _normalize(rel);
  }

  /// 解析 `local_path` 的存值。
  ///
  /// * [LibraryResolution.path] 为应使用的库根（已规范化为正斜杠绝对路径），
  ///   null 表示便携层也找不到，调用方回落平台默认目录；
  /// * [LibraryResolution.relativeStored] 非空表示自愈后**建议回写**的
  ///   相对形式（相对便携根），写它以后再次搬家无需自愈；
  /// * [LibraryResolution.healed] 表示存值已失效、本次是自动找回的。
  static LibraryResolution resolveLibraryPath(String? stored) {
    final trimmed = stored?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      // 1) 绝对路径且仍然存在：用户显式选择优先，原样使用。
      if (isAbsolute(trimmed)) {
        if (Directory(trimmed).existsSync()) {
          return LibraryResolution(_normalize(trimmed));
        }
      } else {
        // 2) 相对形式（旧版本自愈写入 / 用户手写）：相对便携根重放，
        //    再试相对 exe 目录。
        final root = portableRoot();
        final candidates = <String>[
          if (root != null) p.join(root, trimmed),
          p.join(_exeDirOverride ?? p.dirname(Platform.resolvedExecutable),
              trimmed),
        ];
        for (final candidate in candidates) {
          if (Directory(candidate).existsSync()) {
            return LibraryResolution(
              _normalize(candidate),
              healed: root == null,
            );
          }
        }
      }
    }
    // 3) 存值缺失/失效：便携布局下的固定库根。
    final candidate = portableLibraryRoot();
    if (candidate != null) {
      return LibraryResolution(
        candidate,
        relativeStored:
            relativeToPortable(candidate) ?? '$libraryDirName/$downloadsDirName',
        healed: trimmed.isNotEmpty && isAbsolute(trimmed),
      );
    }
    return LibraryResolution(null, healed: trimmed.isNotEmpty);
  }

  /// 重定位单个 `btProjectRoot` 条目（分号分隔列表中的一项）。
  ///
  /// * 根仍存在 → 返回 null（调用方保留原值）；
  /// * 根失效但便携布局存在且 `ComicLibrary/projects` 存在 → 返回新根；
  /// * [autoWhenEmpty]：存值为空时是否自动启用便携 projects 根
  ///   （让标准三格布局在零配置下也能被工作室看到）。
  static String? rebaseProjectsRoot(
    String? stored, {
    bool autoWhenEmpty = false,
  }) {
    final trimmed = stored?.trim() ?? '';
    if (trimmed.isNotEmpty && Directory(trimmed).existsSync()) {
      return null;
    }
    if (trimmed.isEmpty && !autoWhenEmpty) return null;
    return portableProjectsRoot();
  }

  /// 工程 json `directory` 的重基：存值指向的原图根已不存在时，取路径中
  /// 最后一个 `downloads` 段之后的尾段（通常是 `<漫画>[/<章节>]`），拼到
  /// 当前生效的 downloads 根。**拼出的路径必须真实存在才采用**，避免把
  /// 不相关的 `downloads` 段误判成库根。
  ///
  /// 例：`D:/old/ComicLibrary/downloads/Some Comic` + 新库根
  /// `D:/new/ComicLibrary/downloads` → `D:/new/.../downloads/Some Comic`。
  static String? rebaseAnchoredUnderDownloads(String stored) {
    if (stored.trim().isEmpty || Directory(stored).existsSync()) {
      return null;
    }
    final segments =
        _normalize(stored).split('/').where((s) => s.isNotEmpty).toList();
    final anchor = segments.lastIndexOf(downloadsDirName);
    if (anchor < 0 || anchor == segments.length - 1) return null;
    final tail = segments.sublist(anchor + 1).join('/');
    final base = currentDownloadsRoot ?? portableLibraryRoot();
    if (base == null) return null;
    final candidate = _normalize(p.join(base, tail));
    return Directory(candidate).existsSync() ? candidate : null;
  }
}

/// [PathRoots.resolveLibraryPath] 的结果。
class LibraryResolution {
  const LibraryResolution(
    this.path, {
    this.relativeStored,
    this.healed = false,
  });

  /// 解析出的库根；null = 便携层未命中，调用平台默认。
  final String? path;

  /// 自愈成功时建议持久化的"相对便携根"形式；null = 无需改写。
  final String? relativeStored;

  /// true = 原存值失效，本次为自动找回。
  final bool healed;
}
