import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/source_platform.dart';

// Issue #277: a local comic never resumed where the reader left off. History is
// looked up under ComicType.local (0), but the details page derived the write
// type from `sourceKey.hashCode`, so the record landed under a type nothing
// queries. These tests lock the write type to the lookup type, and cover the
// startup migration that moves already-written rows onto type 0.

ComicDetails _details(String sourceKey) => ComicDetails.fromJson({
  'title': 't',
  'subtitle': '',
  'cover': '',
  'description': '',
  'tags': <String, List<String>>{},
  'chapters': null,
  'sourceKey': sourceKey,
  'comicId': 'c1',
  'thumbnails': null,
  'recommend': null,
  'isFavorite': null,
  'subId': null,
  'likesCount': null,
  'isLiked': null,
  'commentCount': null,
  'uploader': null,
  'uploadTime': null,
  'updateTime': null,
  'url': null,
  'stars': null,
  'maxPage': null,
  'comments': null,
});

const _schema = """
  create table history (
    id text,
    title text,
    subtitle text,
    cover text,
    time int,
    type int,
    ep int,
    page int,
    readEpisode text,
    max_page int,
    chapter_group int,
    hidden int,
    primary key (id, type)
  );
""";

const _insert = """
  insert or replace into history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group, hidden)
  values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
""";

void _seed(
  Database db, {
  required int type,
  required int time,
  required int page,
  String reads = '',
  int? hidden,
}) {
  db.execute(_insert, [
    'c1',
    't',
    '',
    '',
    time,
    type,
    1,
    page,
    reads,
    100,
    null,
    hidden,
  ]);
}

Row? _find(Database db, int type) {
  var res = db.select('select * from history where id == ? and type == ?;', [
    'c1',
    type,
  ]);
  return res.isEmpty ? null : res.first;
}

void main() {
  group('write type matches lookup type', () {
    test('local comic history is written under ComicType.local', () {
      final details = _details(SourcePlatformResolver.localCanonicalKey);
      expect(details.historyType, ComicType.local);
      expect(details.historyType.value, 0);
    });

    test('history type always agrees with comicType', () {
      for (final key in [
        SourcePlatformResolver.localCanonicalKey,
        'some_plugin_source',
      ]) {
        final details = _details(key);
        expect(details.historyType, details.comicType, reason: key);
      }
    });

    test('an unregistered plugin key keeps its previous type value', () {
      // Only the local key changes; a plugin source must map to the same value
      // as before so existing rows stay reachable.
      final details = _details('some_plugin_source');
      expect(details.historyType.value, 'some_plugin_source'.hashCode);
    });
  });

  // Mirrors the SQL of HistoryManager._migrateLegacyLocalType on an in-memory
  // database: the manager itself needs App.dataPath + DatabaseGateway, which a
  // plain unit test cannot stand up.
  group('legacy local rows migrate onto type 0', () {
    final legacyType = SourcePlatformResolver.localCanonicalKey.hashCode;
    late Database db;

    setUp(() {
      db = sqlite3.openInMemory();
      db.execute(_schema);
    });

    tearDown(() => db.dispose());

    int asInt(Object? v) => v is int ? v : int.tryParse('${v ?? ''}') ?? 0;

    Set<String> asReads(Object? v) =>
        '${v ?? ''}'.split(',').where((e) => e.isNotEmpty).toSet();

    void migrate() {
      final legacyRows = db.select('select * from history where type == ?;', [
        legacyType,
      ]);
      if (legacyRows.isEmpty) return;
      for (final legacy in legacyRows) {
        final id = legacy['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final current = db.select(
          'select * from history where id == ? and type == ?;',
          [id, ComicType.local.value],
        );
        final existing = current.isEmpty ? null : current.first;
        final winner =
            existing != null && asInt(existing['time']) > asInt(legacy['time'])
            ? existing
            : legacy;
        final reads = <String>{
          ...asReads(legacy['readEpisode']),
          if (existing != null) ...asReads(existing['readEpisode']),
        };
        final visible =
            asInt(legacy['hidden']) == 0 ||
            (existing != null && asInt(existing['hidden']) == 0);
        db.execute(_insert, [
          id,
          winner['title']?.toString() ?? '',
          winner['subtitle']?.toString() ?? '',
          winner['cover']?.toString() ?? '',
          asInt(winner['time']),
          ComicType.local.value,
          asInt(winner['ep']),
          asInt(winner['page']),
          reads.join(','),
          winner['max_page'],
          winner['chapter_group'],
          visible ? null : 1,
        ]);
        db.execute('delete from history where id == ? and type == ?;', [
          id,
          legacyType,
        ]);
      }
    }

    test('moves a row nothing was querying onto the local type', () {
      _seed(db, type: legacyType, time: 1000, page: 42, reads: '1,2');

      migrate();

      expect(_find(db, legacyType), isNull);
      final migrated = _find(db, ComicType.local.value)!;
      expect(migrated['page'], 42);
      expect(migrated['readEpisode'], '1,2');
    });

    test('keeps the newer position and unions read marks when both exist', () {
      _seed(db, type: legacyType, time: 2000, page: 42, reads: '1,2');
      _seed(db, type: ComicType.local.value, time: 1000, page: 7, reads: '3');

      migrate();

      final migrated = _find(db, ComicType.local.value)!;
      expect(migrated['page'], 42);
      expect(
        (migrated['readEpisode'] as String).split(',').toSet(),
        {'1', '2', '3'},
      );
    });

    test('a row hidden on both sides stays out of the list', () {
      _seed(db, type: legacyType, time: 2000, page: 42, hidden: 1);
      _seed(db, type: ComicType.local.value, time: 1000, page: 7, hidden: 1);

      migrate();

      expect(_find(db, ComicType.local.value)!['hidden'], 1);
    });

    test('a row visible on either side stays in the list', () {
      _seed(db, type: legacyType, time: 2000, page: 42, hidden: 1);
      _seed(db, type: ComicType.local.value, time: 1000, page: 7);

      migrate();

      expect(_find(db, ComicType.local.value)!['hidden'], isNull);
    });

    test('is a no-op when there are no legacy rows', () {
      _seed(db, type: ComicType.local.value, time: 1000, page: 7);

      migrate();

      expect(_find(db, ComicType.local.value)!['page'], 7);
    });

    test('a row with null columns still migrates', () {
      // A backup written by another build can leave these columns null; reading
      // the row through History.fromRow would throw and abort the migration.
      db.execute(_insert, [
        'c1',
        null,
        null,
        null,
        null,
        legacyType,
        null,
        null,
        null,
        null,
        null,
        null,
      ]);

      migrate();

      expect(_find(db, legacyType), isNull);
      expect(_find(db, ComicType.local.value), isNotNull);
    });
  });
}
