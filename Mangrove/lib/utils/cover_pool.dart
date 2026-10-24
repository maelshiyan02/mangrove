import 'dart:io';

import 'package:mangrove/foundation/chapter_directory.dart';
import 'package:mangrove/utils/io.dart';

/// 封面候选池的 IO 层（P12，2026-10-24）。
///
/// 一本漫画因季度更新会有多张封面，全部放在 `<漫画目录>/cover/` 里，文件名
/// 带语义：`[cover]season(1).jpg` / `[cover]season(2).jpg`。
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

/// 排序：季度号从新到旧；没有季度号的（贺图/特典）排在后面按文件名。
int _compareCover(File a, File b) {
  final seasonA = coverSeasonOf(a.name);
  final seasonB = coverSeasonOf(b.name);
  if (seasonA != null && seasonB != null && seasonA != seasonB) {
    return seasonB.compareTo(seasonA);
  }
  if (seasonA != null && seasonB == null) return -1;
  if (seasonA == null && seasonB != null) return 1;
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

/// 默认封面：季度号最大的那张（"最新季度封面"）。
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
