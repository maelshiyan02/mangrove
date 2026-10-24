import 'dart:io';

import 'package:mangrove/foundation/chapter_directory.dart';
import 'package:mangrove/utils/io.dart';

/// 封面候选池的 IO 层（P12，2026-10-24）。
///
/// 一本漫画因季度更新会有多张封面，全部放在 `<漫画目录>/cover/` 里，文件名
/// 带语义，三种写法并存（P19，2026-10-24）：
/// - `[LANG][cover]season(1).jpg` —— 韩漫的**季**（季度完结制，一季一张）；
/// - `[LANG][cover]vol(3).jpg`    —— 日漫的**单行本卷**；
/// - `[LANG][cover]event(chuseok).jpg` —— 节日贺图/特别插画，不算新的一季。
/// 详见 [coverSeasonOf] / [coverVolumeOf] / [coverEventOf]。
///
/// 为什么单独一个文件而不是塞进 `local_comic_edit.dart`：那个文件已经是
/// 1900+ 行的"本地漫画写操作总汇"，而封面池是**只读的候选枚举**，两边职责
/// 不同。扫描器（导入）与刷新（加章）都要用它，所以必须比 edit 更低层。
const _coverImageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'jpe'};

bool _isCoverImage(File file) {
  final name = file.name.toLowerCase();
  final dot = name.lastIndexOf('.');
  return dot >= 0 && _coverImageExtensions.contains(name.substring(dot + 1));
}

/// 排序：正篇封面（`season(N)` 韩漫 / `vol(N)` 日漫）按序号从大到小，
/// 贺图（`event(名)`）整体排在正篇之后；同序号内按语言优先级
/// （KR > CN > EN > JP，P17）；都相同时按文件名。
///
/// 为什么序号要合并季与卷：一本漫画的 cover/ 里可能同时躺着网络版季封面
/// （`season(1)`）和单行本各卷封面（`vol(1)..vol(4)`）。只比 season 的话，
/// 没有 season 段的卷封面会被整体判成"无季度"排到最后，读者看到的是旧的
/// 网络版主视觉；只比 vol 又会让季节封面全部落到后面。注意这不是说两种
/// 编号属于同一套体系——它们是韩漫/日漫各自的维度（见 [coverSeasonOf] 与
/// [coverVolumeOf]），合算只是为了排出"哪张最新"。
///
/// 贺图没有版本号，因此永远落在正篇后面：默认封面不该被一张愚人节或秋夕
/// 的活动图顶掉（见 [coverEventOf]）。
int _compareCover(File a, File b) {
  final versionA = coverVersionOf(a.name);
  final versionB = coverVersionOf(b.name);
  if (versionA != null && versionB != null && versionA != versionB) {
    return versionB.compareTo(versionA);
  }
  if (versionA != null && versionB == null) return -1;
  if (versionA == null && versionB != null) return 1;
  final rankA = coverLanguageRank(coverLanguageOf(a.name));
  final rankB = coverLanguageRank(coverLanguageOf(b.name));
  if (rankA != rankB) return rankA.compareTo(rankB);
  return a.name.compareTo(b.name);
}

/// 列出封面池里的全部候选，返回**相对漫画根目录**的路径，按季度从新到旧。
///
/// 池不存在或为空时返回空列表（旧布局的漫画就是这种情况，调用方回落到
/// 根目录的 `cover.jpg`）。
Future<List<String>> listCoverCandidates(String baseDir) async {
  final pool = Directory(FilePath.join(baseDir, coverDirectoryName));
  if (!await pool.exists()) return const [];
  final files = <File>[];
  try {
    await for (final entry in pool.list()) {
      if (entry is File && _isCoverImage(entry)) files.add(entry);
    }
  } catch (_) {
    return const [];
  }
  if (files.isEmpty) return const [];
  files.sort(_compareCover);
  return [
    for (final file in files) FilePath.join(coverDirectoryName, file.name),
  ];
}

/// 默认封面：序号最大的那张（"最新封面"——最新一季，或最新一卷单行本）。
///
/// 返回相对漫画根目录的路径；池为空返回 null。
Future<String?> pickCoverFromPool(Directory pool) async {
  final poolName = pool.name;
  final files = <File>[];
  try {
    await for (final entry in pool.list()) {
      if (entry is File && _isCoverImage(entry)) files.add(entry);
    }
  } catch (_) {
    return null;
  }
  if (files.isEmpty) return null;
  files.sort(_compareCover);
  return FilePath.join(poolName, files.first.name);
}

/// 某个封面路径是否仍存在于磁盘（用户可能在资源管理器里删掉了某季封面）。
///
/// 用于"刷新章节时不要无脑覆盖用户手选的封面"：先验证旧值还在，不在才回落
/// 到默认封面。
bool coverStillExists(String baseDir, String? coverPath) {
  if (coverPath == null || coverPath.isEmpty) return false;
  return File(FilePath.join(baseDir, coverPath)).existsSync();
}
