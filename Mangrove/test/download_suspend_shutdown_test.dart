import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/foundation/comic_source/comic_source.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/missing_pages.dart';
import 'package:mangrove/network/download.dart';
import 'package:mangrove/network/repair_download.dart';
import 'package:mangrove/utils/translations.dart';

/// 关闭软件时"安全暂停"下载的契约测试。
///
/// 关键不变量：调用 [DownloadTask.suspendForShutdown] 后，任务的
/// `toJson()['wasRunning']` 必须为 `true`（即使此刻循环已停），否则
/// `LocalManager._autoResumeDownloads` 不会在下次启动时续传，安全暂停就失效了。
/// 未 suspend 且未运行时，toJson 写出 `wasRunning=false`（与手动 pause 一致）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late String originalDataPath;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'mangrove-suspend-test-',
    );
    originalDataPath = App.dataPath;
    App.dataPath = directory.path;
    await appdata.init();
    await AppTranslation.init();
  });

  tearDownAll(() async {
    App.dataPath = originalDataPath;
    await directory.delete(recursive: true);
  });

  ComicSource minimalSource(String key) => ComicSource(
        'Test $key', // name
        key, // key
        null, // account
        null, // categoryData
        null, // categoryComicsData
        null, // favoriteData
        const [], // explorePages: List<ExplorePageData> 非空
        null, // searchPageData
        null, // settings
        null, // loadComicInfo
        null, // loadComicThumbnail
        null, // loadComicPages
        null, // getImageLoadingConfig
        null, // getThumbnailLoadingConfig
        '', // filePath: String 非空
        '', // url: String 非空
        '', // version: String 非空
        null, // commentsLoader
        null, // sendCommentFunc
        null, // chapterCommentsLoader
        null, // sendChapterCommentFunc
        null, // likeOrUnlikeComic
        null, // voteCommentFunc
        null, // likeCommentFunc
        null, // idMatcher
        null, // translations
        null, // handleClickTagEvent
        null, // onTagSuggestionSelected
        null, // linkHandler
        false, // enableTagsSuggestions: bool 非空
        false, // enableTagsTranslate: bool 非空
        null, // starRatingFunc
        null, // archiveDownloader
      );

  ComicDetails minimalDetails(String id) => ComicDetails.fromJson({
        'title': id,
        'cover': '',
        'comicId': id,
        'sourceKey': 'test',
        'tags': <String, List<String>>{},
        'chapters': <String, String>{},
      });

  group('suspendForShutdown persists wasRunning=true so it auto-resumes', () {
    test('ImagesDownloadTask.toJson writes wasRunning=true under suspend', () {
      final task = ImagesDownloadTask(
        source: minimalSource('img'),
        comicId: 'c1',
      );
      // 未运行时 suspendForShutdown 会直接 return，无需真实网络。
      expect(task.isPaused, isTrue);
      task.suspendShutdown = true;
      final json = task.toJson();
      expect(json['wasRunning'], isTrue,
          reason: 'suspend 必须把 wasRunning 写为 true，否则下次启动不会续传');
      expect(json['userPaused'], isFalse);
    });

    test('toJson without suspend follows _isRunning (false when not running)', () {
      final task = ImagesDownloadTask(
        source: minimalSource('img2'),
        comicId: 'c2',
      );
      final json = task.toJson();
      expect(json['wasRunning'], isFalse,
          reason: '未 suspend 且未运行时 wasRunning 应为 false（与手动 pause 一致）');
    });

    test('ArchiveDownloadTask.toJson writes wasRunning=true under suspend', () {
      final task = ArchiveDownloadTask(
        'https://example.com/a.zip',
        minimalDetails('arc'),
      );
      task.suspendShutdown = true;
      final json = task.toJson();
      expect(json['wasRunning'], isTrue);
    });

    test('RepairDownloadTask.toJson writes wasRunning=true under suspend', () {
      final task = RepairDownloadTask(
        source: minimalSource('rep'),
        comicId: 'c3',
        targets: const <MissingPageEntry>[],
      );
      task.suspendShutdown = true;
      final json = task.toJson();
      expect(json['wasRunning'], isTrue);
    });
  });

  group('LocalManager download-shutdown guards', () {
    test('hasRunningDownloads is false with no tasks', () {
      expect(LocalManager().hasRunningDownloads, isFalse);
    });

    test('suspendAllRunningDownloads is safe with no running tasks', () async {
      // 不应抛错，也不应改变 anything。
      await LocalManager().suspendAllRunningDownloads();
      expect(LocalManager().hasRunningDownloads, isFalse);
    });
  });
}
