import 'package:flutter_test/flutter_test.dart';
import 'package:mangrove/foundation/comic_type.dart';
import 'package:mangrove/foundation/download_manager_store.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/missing_pages.dart';
import 'package:mangrove/network/download.dart';

/// Pure-logic coverage for the download-manager data layer (2026-10-14):
///
/// * [classifyDownloadTask] — the four-bucket routing (current/past/problem/
///   standby) that the home section and the manager page share.
/// * [DownloadHistoryEntry] — JSON round-trip + malformed-input rejection
///   (the "past" queue is rebuilt from persisted JSON on every launch).
/// * [MissingPagesTable] — the chapter/page aggregation that
///   [ComicMissingReport.chapterCount]/[ComicMissingReport.pageCount]
///   delegate to, plus the [MissingPages.peek] "no table" path the scanner
///   relies on.
///
/// Disk IO ([DownloadHistoryStore] persistence, [DownloadProblemScanner]) needs
/// `App.dataPath` + `LocalManager` and is left to headless/manual checks — same
/// policy as the other store tests in this directory.
class _FakeTask extends DownloadTask {
  _FakeTask({this.paused = false, this.error = false, this.prog = 0.0});

  final bool paused;
  final bool error;
  final double prog;

  @override
  double get progress => prog;
  @override
  bool get isError => error;
  @override
  bool get isPaused => paused;
  @override
  int get speed => 0;
  @override
  void cancel() {}
  @override
  void pause() {}
  @override
  void resume() {}
  @override
  Future<void> suspendForShutdown() async {}
  @override
  String get title => 'fake';
  @override
  String? get cover => null;
  @override
  String get message => 'fake';
  @override
  Map<String, dynamic> toJson() => const {};
  @override
  LocalComic toLocalComic() => throw UnimplementedError();
  @override
  String get id => 'fake-id';
  @override
  ComicType get comicType => ComicType.local;
}

void main() {
  group('classifyDownloadTask', () {
    test('running task -> current', () {
      expect(classifyDownloadTask(_FakeTask()), DownloadTaskBucket.current);
    });

    test('errored task -> problem even mid-download', () {
      expect(
        classifyDownloadTask(_FakeTask(error: true, prog: 0.9)),
        DownloadTaskBucket.problem,
      );
    });

    test('user-paused half-done task stays current (not standby)', () {
      // Regression guard: a task paused at 40% is still a live "current" task
      // the user can resume — it must NOT fall into the standby queue.
      expect(
        classifyDownloadTask(_FakeTask(paused: true, prog: 0.4)),
        DownloadTaskBucket.current,
      );
    });

    test('never-started task -> standby', () {
      expect(
        classifyDownloadTask(_FakeTask(paused: true, prog: 0.0)),
        DownloadTaskBucket.standby,
      );
    });
  });

  group('DownloadHistoryEntry JSON', () {
    test('download entry round-trips, dropping absent optional fields', () {
      final e = DownloadHistoryEntry(
        comicId: 'c1',
        comicTypeValue: 42,
        title: 'Some Comic',
        time: DateTime.utc(2026, 10, 14, 12, 0),
        kind: 'download',
        cover: 'cover.jpg',
        sourceKey: 'src',
        chapters: 12,
      );
      final json = e.toJson();
      // Absent optionals must not appear as keys (keeps the file lean).
      expect(json.containsKey('repaired'), isFalse);
      expect(json.containsKey('failed'), isFalse);

      final r = DownloadHistoryEntry.fromJson(json)!;
      expect(r.comicId, 'c1');
      expect(r.comicTypeValue, 42);
      expect(r.title, 'Some Comic');
      expect(r.kind, 'download');
      expect(r.cover, 'cover.jpg');
      expect(r.sourceKey, 'src');
      expect(r.chapters, 12);
      expect(r.repaired, isNull);
      expect(r.failed, isNull);
      expect(r.time.toIso8601String(), e.time.toIso8601String());
    });

    test('repair entry round-trips repaired/failed', () {
      final e = DownloadHistoryEntry(
        comicId: 'c2',
        comicTypeValue: ComicType.local.value,
        title: 'Repaired Book',
        time: DateTime.utc(2026, 10, 14, 13, 0),
        kind: 'repair',
        repaired: 5,
        failed: 2,
      );
      final r = DownloadHistoryEntry.fromJson(e.toJson())!;
      expect(r.kind, 'repair');
      expect(r.repaired, 5);
      expect(r.failed, 2);
      expect(r.chapters, isNull);
    });

    test('missing comicType defaults to local; unknown kind normalises to '
        'download', () {
      final r = DownloadHistoryEntry.fromJson({
        'id': 'c3',
        'title': 't',
        'time': '2026-10-14T12:00:00.000Z',
        'kind': 'weird-unknown',
      })!;
      expect(r.comicTypeValue, ComicType.local.value);
      expect(r.kind, 'download');
    });

    test('non-int comicType falls back to local', () {
      final r = DownloadHistoryEntry.fromJson({
        'id': 'c4',
        'title': 't',
        'time': '2026-10-14T12:00:00.000Z',
        'comicType': 'not-an-int',
      })!;
      expect(r.comicTypeValue, ComicType.local.value);
    });

    test('rejects malformed records (reverse verification)', () {
      // A corrupt line must be dropped, never crash the load path.
      expect(DownloadHistoryEntry.fromJson(null), isNull);
      expect(DownloadHistoryEntry.fromJson('not a map'), isNull);
      expect(DownloadHistoryEntry.fromJson(<String, dynamic>{}), isNull);
      // Missing required title/time.
      expect(
        DownloadHistoryEntry.fromJson({'id': 'c', 'title': 't'}),
        isNull,
      );
      // Unparseable time.
      expect(
        DownloadHistoryEntry.fromJson({
          'id': 'c',
          'title': 't',
          'time': 'not-a-date',
        }),
        isNull,
      );
      // Wrong-typed required id.
      expect(
        DownloadHistoryEntry.fromJson({
          'id': 123,
          'title': 't',
          'time': '2026-10-14T12:00:00.000Z',
        }),
        isNull,
      );
    });
  });

  group('MissingPagesTable (ComicMissingReport aggregation source)', () {
    MissingPageEntry page(
      String chapterId,
      int index, {
      String title = '',
      String url = 'u',
    }) => MissingPageEntry(
      chapterId: chapterId,
      chapterTitle: title,
      index: index,
      url: url,
      error: 'e',
    );

    test('empty table reports nothing missing', () {
      final t = MissingPagesTable(sourceKey: 's', comicId: 'c');
      expect(t.isEmpty, isTrue);
      expect(t.count, 0);
      expect(t.chapterIds, isEmpty);
    });

    test('counts pages per chapter and in total', () {
      final t = MissingPagesTable(sourceKey: 's', comicId: 'c');
      t.upsert(page('ch1', 0, title: 'Chapter 1'));
      t.upsert(page('ch1', 3, title: 'Chapter 1'));
      t.upsert(page('ch2', 1, title: 'Chapter 2'));
      // These are exactly what ComicMissingReport.chapterCount/pageCount read.
      expect(t.count, 3);
      expect(t.chapterIds, {'ch1', 'ch2'});
      expect(t.countOfChapter('ch1'), 2);
      expect(t.countOfChapter('ch2'), 1);
      expect(t.isEmpty, isFalse);
    });

    test('upsert merges a repeated failure instead of duplicating it', () {
      final t = MissingPagesTable(sourceKey: 's', comicId: 'c');
      t.upsert(page('ch1', 0, url: 'u'));
      t.upsert(
        MissingPageEntry(
          chapterId: 'ch1',
          chapterTitle: '',
          index: 0,
          url: 'u',
          error: 'second-failure',
        ),
      );
      expect(t.count, 1);
      expect(t.entries.single.attempts, 2);
      expect(t.entries.single.error, 'second-failure');
    });
  });

  group('MissingPages.peek (scanner read path)', () {
    test('returns null for an empty or missing directory', () {
      expect(MissingPages.peek(''), isNull);
      expect(
        MissingPages.peek('/nonexistent/mangrove/test/comic-dir'),
        isNull,
      );
    });
  });
}
