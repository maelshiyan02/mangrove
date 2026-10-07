import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/domain_database.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/source_platform.dart';

void main() {
  setUpAll(() {
    if (Platform.isWindows) {
      open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open('winsqlite3.dll'),
      );
    }
  });

  test('creates stable canonical identity for local and remote comics', () {
    final repository = ComicStateRepository();

    final local = repository.identityFor('local', 'abc');
    final remote = repository.identityFor('source_a', 'abc');
    final unknown = repository.identityFor('Unknown:999', 'abc');

    expect(local.comicId, 'local:abc');
    expect(local.isLocal, isTrue);
    expect(remote.comicId, 'remote:source_a:abc');
    expect(remote.isLocal, isFalse);
    expect(unknown.comicId, 'legacy:999:abc');
    expect(unknown.type.value, 999);
  });

  test(
    'mirrors remote comic metadata into canonical domain database',
    () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'venera_domain_repo_',
      );
      final domain = DomainDatabase();

      try {
        await domain.init(tempDir.path);
        final repository = ComicStateRepository(domain: domain);
        final comic = Comic(
          'Title',
          'cover.jpg',
          'remote-id',
          'Sub',
          const ['genre:Action', 'status:连载中'],
          'Desc',
          'source_a',
          null,
          'zh',
        );

        final comicId = repository.mirrorComic(comic);
        final rows = domain.db.select(
          '''
        SELECT c.title, c.subtitle, c.description, c.status, s.platform_id
        FROM comics c
        JOIN comic_sources s ON s.comic_id = c.comic_id
        WHERE c.comic_id = ?;
        ''',
          [comicId],
        );

        expect(comicId, 'remote:source_a:remote-id');
        expect(rows.single['title'], 'Title');
        expect(rows.single['subtitle'], 'Sub');
        expect(rows.single['description'], 'Desc');
        expect(rows.single['status'], '连载中');
        expect(rows.single['platform_id'], 'remote:source_a');

        final display = repository.displayInfoFor(comic);
        expect(display.title, 'Title');
        expect(display.author, 'Sub');
        expect(display.status, '连载中');
        expect(display.tags, contains('genre:Action'));
        expect(display.tags, isNot(contains('status:连载中')));
      } finally {
        domain.close();
        tempDir.deleteSync(recursive: true);
      }
    },
  );

  test(
    'local comic display tags use the current local comic after refresh',
    () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'venera_domain_local_tags_',
      );
      final domain = DomainDatabase();

      try {
        await domain.init(tempDir.path);
        domain.ensureComicSource(
          platform: SourcePlatformResolver.fromSourceKey('local'),
          sourceComicId: 'local-id',
          title: 'Title',
          tags: const ['genre:old', 'genre:Same'],
        );
        final repository = ComicStateRepository(domain: domain);
        final localComic = LocalComic(
          id: 'local-id',
          title: 'Title',
          subtitle: '',
          tags: const ['new', 'Same'],
          directory: tempDir.path,
          chapters: null,
          cover: 'cover.jpg',
          comicType: ComicType.local,
          downloadedChapters: const [],
          createdAt: DateTime(2026),
        );

        final display = repository.displayInfoFor(localComic);

        expect(display.tags, ['new', 'Same']);
      } finally {
        domain.close();
        tempDir.deleteSync(recursive: true);
      }
    },
  );

  test('related sources include the current comic source by default', () async {
    final tempDir = Directory.systemTemp.createTempSync(
      'venera_domain_related_self_',
    );
    final domain = DomainDatabase();

    try {
      await domain.init(tempDir.path);
      final repository = ComicStateRepository(domain: domain);
      final comic = Comic(
        'Title',
        'cover.jpg',
        'self-id',
        'Author',
        const ['status:连载中'],
        'Desc',
        'source_a',
        null,
        'zh',
      );

      final links = repository.relatedSourcesFor(comic);

      expect(links, hasLength(1));
      expect(links.single.comicId, 'remote:source_a:self-id');
      expect(links.single.sourceComicId, 'self-id');
      expect(links.single.status, 'accepted');
      expect(links.single.sourceName, 'source_a');
    } finally {
      domain.close();
      tempDir.deleteSync(recursive: true);
    }
  });

  test(
    'comic display status is serialization status, not update read state',
    () {
      const repository = ComicStateRepository();
      final favorite = FavoriteItem(
        id: 'fav-id',
        name: 'Favorite',
        coverPath: 'cover.jpg',
        author: 'Author',
        type: ComicType.fromKey('source_a'),
        tags: const ['status:连载中', 'genre:Drama'],
      );
      final updateInfo = FavoriteItemWithUpdateInfo(
        favorite,
        '2026-05-11',
        true,
        null,
      );

      final display = repository.displayInfoFor(updateInfo);

      expect(display.status, '连载中');
      expect(display.updateTime, '2026-05-11');
      expect(display.hasNewUpdate, isTrue);
      expect(display.status, isNot('Unread'));
    },
  );

  test('chapter progress uses mirrored chapter titles', () async {
    final tempDir = Directory.systemTemp.createTempSync(
      'venera_domain_chapters_',
    );
    final domain = DomainDatabase();

    try {
      await domain.init(tempDir.path);
      final repository = ComicStateRepository(domain: domain);
      final staleComic = ComicDetails.fromJson({
        'title': 'Title',
        'subtitle': 'Author',
        'cover': 'cover.jpg',
        'description': '',
        'tags': <String, List<String>>{},
        'chapters': {for (var i = 1; i <= 8; i++) '$i': '第$i話'},
        'sourceKey': 'source_a',
        'comicId': 'comic-id',
      });
      final comic = ComicDetails.fromJson({
        'title': 'Title',
        'subtitle': 'Author',
        'cover': 'cover.jpg',
        'description': '',
        'tags': <String, List<String>>{},
        'chapters': {
          '1': '第1.1話',
          '2': '第1.2話',
          '3': '第2.1話',
          '4': '第2.2話',
          '5': '第2.3話',
          '6': '第11話',
        },
        'sourceKey': 'source_a',
        'comicId': 'comic-id',
      });
      repository.mirrorComicDetails(staleComic);
      repository.mirrorComicDetails(comic);

      final progress = repository.chapterProgressFor(
        Comic(
          'Title',
          'cover.jpg',
          'comic-id',
          'Author',
          const [],
          '第8話',
          'source_a',
          null,
          null,
        ),
        History.fromModel(model: comic, ep: 5, page: 11),
      );

      expect(progress.currentTitle, '第2.3話');
      expect(progress.latestTitle, '第11話');
    } finally {
      domain.close();
      tempDir.deleteSync(recursive: true);
    }
  });

  test(
    'chapter parser preserves grouped tabs when flat entries also exist',
    () {
      final chapters = ComicChapters.fromJson({
        '单行本': {'v1': '第一卷'},
        '连载版': {'c1': '第1话'},
        '2': '第2话',
      });

      expect(chapters.isGrouped, isTrue);
      expect(chapters.groups, containsAll(['单行本', '连载版', '默认']));
      expect(chapters.groupCount, 3);
      expect(chapters.titleAt(1, group: 1), '第一卷');
      expect(chapters.titleAt(1, group: 2), '第1话');
      expect(chapters.titleAt(1, group: 3), '第2话');
    },
  );

  test('versioned chapters keep multi-group versions while flat API stays stable', () {
    final chapters = ComicChapters.versioned({
      '1': [
        const ComicChapterVersion(
          scanlationGroup: 'Luna Toons',
          title: '第1话',
          chapterKey: 'ch-1-a',
        ),
        const ComicChapterVersion(
          scanlationGroup: 'Pink Panda',
          title: '第1话',
          chapterKey: 'ch-1-b',
        ),
      ],
      '2': [
        const ComicChapterVersion(
          scanlationGroup: 'Luna Toons',
          title: '第2话',
          chapterKey: 'ch-2-a',
        ),
      ],
    });

    expect(chapters.isVersioned, isTrue);
    expect(chapters.isGrouped, isFalse);
    expect(chapters.length, 2);
    // Chapter keys sort ascending by number: '1' before '2'（用户定案：第1话
    // →最新，而非旧的"最新→第1话"倒序）。
    // Within a chapter, versions sort by group name ascending (no timestamps):
    // Luna Toons before Pink Panda (L < P alphabetically).
    expect(chapters.allChapters, {
      'ch-1-a': '第1话', // chapter '1' first (asc); Luna Toons first (alpha asc)
      'ch-2-a': '第2话', // chapter '2' second (asc)
    });
    expect(chapters.ids.toList(), ['ch-1-a', 'ch-2-a']);
    expect(chapters.titles.toList(), ['第1话', '第2话']);
    expect(chapters['ch-1-b'], '第1话');
    // scanlationGroupAt follows the sorted chapter order:
    // index 0 → chapter '1' → Luna Toons (first version after sort)
    // index 1 → chapter '2' → Luna Toons
    expect(chapters.scanlationGroupAt(0), 'Luna Toons');
    expect(chapters.scanlationGroupAt(1), 'Luna Toons');
    expect(chapters.versionCountAt(0), 2); // chapter '1' has 2 versions
    expect(chapters.versionCountAt(1), 1); // chapter '2' has 1 version
    // toJson round trip preserves uploadedAt=null (omitted) and re-sorts.
    final restored = ComicChapters.fromJson(chapters.toJson());
    expect(restored.isVersioned, isTrue);
    // After sort, chapter '1' versions: Luna Toons (first), Pink Panda (last)
    expect(restored.versionsFor('1')!.last.scanlationGroup, 'Pink Panda');
    expect(restored.allChapters, chapters.allChapters);
    // scanlationGroupsSorted: no timestamps → alphabetical
    expect(chapters.scanlationGroupsSorted, ['Luna Toons', 'Pink Panda']);
  });

  test('versioned chapters with uploadedAt sort newest first', () {
    final chapters = ComicChapters.versioned({
      '5': [
        ComicChapterVersion(
          scanlationGroup: 'Luna Toons',
          title: '第5话',
          chapterKey: 'ch-5-a',
          uploadedAt: DateTime(2026, 9, 20), // older
        ),
        ComicChapterVersion(
          scanlationGroup: 'Pink Panda',
          title: '第5话',
          chapterKey: 'ch-5-b',
          uploadedAt: DateTime(2026, 9, 28), // newer
        ),
      ],
      '3': [
        ComicChapterVersion(
          scanlationGroup: 'Luna Toons',
          title: '第3话',
          chapterKey: 'ch-3-a',
          uploadedAt: DateTime(2026, 9, 25),
        ),
      ],
    });

    // Chapter keys: '3' before '5' (asc numeric, 用户定案正序).
    // Chapter '5' versions: Pink Panda (newer) before Luna Toons (older).
    // Chapter '3' versions: Luna Toons only.
    expect(chapters.allChapters, {
      'ch-3-a': '第3话',
      'ch-5-b': '第5话', // Pink Panda newer → first
    });
    // preferredVersionKey with null preferredGroup picks the newest version
    expect(chapters.preferredVersionKey('5', null), 'ch-5-b');
    expect(chapters.preferredVersionKey('5', 'Luna Toons'), 'ch-5-a');
    // scanlationGroupsSorted: Pink Panda's newest is 9-28, Luna Toons' newest is 9-25
    expect(chapters.scanlationGroupsSorted, ['Pink Panda', 'Luna Toons']);
  });

  test('duplicate chapter titles without group info stay flat, not versioned', () {
    final chapters = ComicChapters.fromJson({
      'ch-1': '第1话',
      'ch-1-dup': '第1话',
      'ch-2': '第2话',
    });

    expect(chapters.isVersioned, isFalse);
    expect(chapters.allChapters.keys, containsAll(['ch-1', 'ch-1-dup', 'ch-2']));
    expect(chapters.length, 3);
  });

  test('chapter progress resolves grouped history chapter title', () {
    const repository = ComicStateRepository();
    final comic = ComicDetails.fromJson({
      'title': 'Title',
      'subtitle': 'Author',
      'cover': 'cover.jpg',
      'description': '',
      'tags': <String, List<String>>{},
      'chapters': {
        '单行本': {'v1': '第一卷'},
        '连载版': {'c1': '第1话', 'c2': '第2话'},
      },
      'sourceKey': 'source_a',
      'comicId': 'comic-id',
    });

    final progress = repository.chapterProgressFromDetails(
      comic,
      History.fromModel(model: comic, ep: 2, page: 7, group: 2),
    );

    expect(progress.currentTitle, '第2话');
    expect(progress.latestTitle, '第2话');
  });

  test('chapter progress does not synthesize chapter numbers', () async {
    final tempDir = Directory.systemTemp.createTempSync(
      'venera_domain_no_chapters_',
    );
    final domain = DomainDatabase();

    try {
      await domain.init(tempDir.path);
      final repository = ComicStateRepository(domain: domain);
      final details = ComicDetails.fromJson({
        'title': 'Title',
        'subtitle': 'Author',
        'cover': 'cover.jpg',
        'description': '',
        'tags': <String, List<String>>{},
        'sourceKey': 'source_a',
        'comicId': 'comic-id',
      });
      final comic = Comic(
        'Title',
        'cover.jpg',
        'comic-id',
        'Author',
        const [],
        '',
        'source_a',
        null,
        null,
      );
      repository.mirrorComic(comic);

      final progress = repository.chapterProgressFor(
        comic,
        History.fromModel(model: details, ep: 8, page: 1),
      );

      expect(progress.currentTitle, isNull);
      expect(progress.latestTitle, isNull);
    } finally {
      domain.close();
      tempDir.deleteSync(recursive: true);
    }
  });

  test('chapter progress falls back to saved latest chapter title', () async {
    final tempDir = Directory.systemTemp.createTempSync(
      'venera_domain_latest_fallback_',
    );
    final domain = DomainDatabase();

    try {
      await domain.init(tempDir.path);
      final repository = ComicStateRepository(domain: domain);
      final details = ComicDetails.fromJson({
        'title': 'Title',
        'subtitle': 'Author',
        'cover': 'cover.jpg',
        'description': '',
        'tags': <String, List<String>>{},
        'sourceKey': 'source_a',
        'comicId': 'comic-id',
      });
      final favorite = FavoriteItem(
        id: 'comic-id',
        name: 'Title',
        coverPath: 'cover.jpg',
        author: 'Author',
        type: ComicType.fromKey('source_a'),
        tags: const [],
      );
      final updateInfo = FavoriteItemWithUpdateInfo(
        favorite,
        '第11話',
        true,
        null,
      );

      final progress = repository.chapterProgressFor(
        updateInfo,
        History.fromModel(model: details, ep: 8, page: 1),
      );

      expect(progress.currentTitle, isNull);
      expect(progress.latestTitle, '第11話');
    } finally {
      domain.close();
      tempDir.deleteSync(recursive: true);
    }
  });

  group('quick page count', () {
    Comic comicWith({int? maxPage, List<String>? tags}) => Comic(
      'Title',
      'cover.jpg',
      'id',
      'Author',
      tags,
      'Desc',
      'source_a',
      maxPage,
      'zh',
    );

    test('prefers maxPage over tags', () {
      const repository = ComicStateRepository();
      expect(
        repository.quickPageCountFor(
          comicWith(maxPage: 42, tags: const ['pages:99']),
        ),
        '42',
      );
    });

    test('falls back to a page count tag across namespaces', () {
      const repository = ComicStateRepository();
      expect(repository.quickPageCountFor(comicWith(tags: const ['pages:31'])), '31');
      expect(repository.quickPageCountFor(comicWith(tags: const ['Page: 7'])), '7');
      expect(repository.quickPageCountFor(comicWith(tags: const ['页数:18'])), '18');
      expect(repository.quickPageCountFor(comicWith(tags: const ['頁數:25'])), '25');
    });

    test('ignores a non-positive maxPage and unrelated tags', () {
      const repository = ComicStateRepository();
      expect(repository.quickPageCountFor(comicWith(maxPage: 0)), isNull);
      expect(
        repository.quickPageCountFor(comicWith(tags: const ['author:someone'])),
        isNull,
      );
      expect(repository.quickPageCountFor(comicWith(tags: const [])), isNull);
      expect(repository.quickPageCountFor(comicWith()), isNull);
    });

    test('a zero maxPage still falls back to a tag', () {
      const repository = ComicStateRepository();
      expect(
        repository.quickPageCountFor(
          comicWith(maxPage: 0, tags: const ['pages:12']),
        ),
        '12',
      );
    });
  });
}
