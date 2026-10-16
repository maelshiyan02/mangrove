// 章节下载状态的统一判定（2026-10-16，P-DL6「网络/本地显示模式」）。
//
// 两类消费方共用同一套判定：
// * 详情页章节 chips 的五态配色（白/浅绿/黄/蓝/红）——原
//   `chapterChipColorFor`（comic_page 的 part 文件）里的判定逻辑上提至此；
// * 「本地模式」的章节过滤 —— 详情页与阅读器的章节列表都要隐藏"纯白"
//   未下载章节，而阅读器无法 import 详情页的 part 文件，必须落在
//   foundation 层。
//
// 状态优先级（与旧版四态一致，新增待命/出错两态）：
//   缺页(红) > 任务出错(红) > 下载中(黄) > 待命(浅绿) > 已下载(蓝) > 未下载(白)
library;

import 'package:mangrove/foundation/chapter_directory.dart';
import 'package:mangrove/foundation/comic_source/comic_source.dart'
    show ComicChapters;
import 'package:mangrove/foundation/comic_type.dart';
import 'package:mangrove/foundation/download_manager_store.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/missing_pages.dart';
import 'package:mangrove/network/download.dart';

/// 一章在本机的下载状态（配色与过滤共用）。
enum ChapterDownloadStatus {
  /// 白：未下载的网络章节（本地模式下隐藏）。
  notDownloaded,

  /// 浅绿：已建立下载任务、排队待命（本地模式下保留，随任务完成变蓝）。
  standby,

  /// 黄：下载中（含下到一半被暂停的活任务，见 classifyDownloadTask）。
  downloading,

  /// 蓝：已下载。
  downloaded,

  /// 红：缺页（missing_pages.json 有记录）或下载任务出错。
  missing,
}

/// 判定一章的 [ChapterDownloadStatus]。
///
/// [chapterKey] 必须是源章节 id（与 `downloadedChapters` / 任务
/// `chapters` 列表同域）；[chapters] 传漫画的章节矩阵，仅用于把
/// chapterKey 换算成缺页表里的章节目录名。
ChapterDownloadStatus chapterDownloadStatusFor({
  required String comicId,
  required ComicType comicType,
  required ComicChapters? chapters,
  required String chapterKey,
}) {
  final local = LocalManager().find(comicId, comicType);
  // 缺页（红色）最高优先级：已知不完整的章节优先于下载中/已下载。
  if (local != null) {
    final dir = chapterDirectoryName(chapters, chapterKey);
    final missing =
        MissingPages.peek(local.baseDir)?.countOfChapter(dir) ?? 0;
    if (missing > 0) return ChapterDownloadStatus.missing;
  }
  // 队列里的任务：出错→红，下载中→黄，待命→浅绿。同一章有多只任务时
  // 按红 > 黄 > 绿取最"显眼"的状态，因此先收集齐再判定。
  var hasProblem = false;
  var hasCurrent = false;
  var hasStandby = false;
  for (final t in LocalManager().downloadingTasks) {
    if (t.id != comicId || t.comicType != comicType) continue;
    // `chapters` 在 ImagesDownloadTask 上；其它任务类型视为整本下载。
    if (t is! ImagesDownloadTask ||
        t.chapters == null ||
        t.chapters!.contains(chapterKey)) {
      switch (classifyDownloadTask(t)) {
        case DownloadTaskBucket.problem:
          hasProblem = true;
        case DownloadTaskBucket.current:
          hasCurrent = true;
        case DownloadTaskBucket.standby:
          hasStandby = true;
        case DownloadTaskBucket.past:
          break;
      }
    }
  }
  if (hasProblem) return ChapterDownloadStatus.missing;
  if (hasCurrent) return ChapterDownloadStatus.downloading;
  if (hasStandby) return ChapterDownloadStatus.standby;
  final downloaded =
      local?.downloadedChapters.contains(chapterKey) ?? false;
  if (downloaded) return ChapterDownloadStatus.downloaded;
  return ChapterDownloadStatus.notDownloaded;
}
