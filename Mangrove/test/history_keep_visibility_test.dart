import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

// Covers the two write semantics HistoryManager needs for the `hidden` column:
//
// - `addHistory` (_insertHistorySql) omits `hidden`, so `insert or replace`
//   resets it to NULL and the comic reappears in the list. That is intended for
//   reading — see history_hide_preserves_read_state_test.dart.
// - `updateHistoryKeepingVisibility` (_updateHistoryKeepVisibilitySql) carries
//   the existing flag over, so a maintenance write (cover resolution, local
//   rescan, info refresh) cannot resurrect a record the user deleted (#270).
//
// The subquery reading `hidden` sits inside the VALUES row, so whether it sees
// the pre-existing flag or the already-deleted row is SQLite behaviour, not
// something the Dart side can enforce. That ordering is what these tests pin
// down, against the exact SQL HistoryManager runs.

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

// _insertHistorySql — reading; drops `hidden`.
const _insert = """
  insert or replace into history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
  values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
""";

// _updateHistoryKeepVisibilitySql — maintenance; preserves `hidden`.
const _insertKeepVisibility = """
  insert or replace into history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group, hidden)
  values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, (select hidden from history where id == ? and type == ?));
""";

int _listCount(Database db) => db
    .select("select count(*) from history where ifnull(hidden, 0) = 0;")
    .first[0] as int;

Row? _find(Database db, String id, int type) {
  var res = db.select(
    "select * from history where id == ? and type == ?;",
    [id, type],
  );
  return res.isEmpty ? null : res.first;
}

void _read(Database db, String id, {int time = 1000, String cover = "c.jpg"}) {
  db.execute(_insert, [id, "t-$id", "", cover, time, 1, 3, 42, "1,2", 100, null]);
}

void _maintain(
  Database db,
  String id, {
  int time = 1000,
  String cover = "c.jpg",
}) {
  db.execute(_insertKeepVisibility, [
    id,
    "t-$id",
    "",
    cover,
    time,
    1,
    3,
    42,
    "1,2",
    100,
    null,
    id,
    1,
  ]);
}

void _hide(Database db, String id) => db.execute(
  "update history set hidden = 1 where id == ? and type == ?;",
  [id, 1],
);

void main() {
  late Database db;

  setUp(() {
    db = sqlite3.openInMemory();
    db.execute(_schema);
  });

  tearDown(() => db.dispose());

  test('maintenance write on a hidden row leaves it hidden', () {
    _read(db, "a");
    _hide(db, "a");
    expect(_listCount(db), 0);

    // A background cover fetch landing after the user deleted the record.
    _maintain(db, "a", cover: "https://example.test/new.jpg");

    expect(_listCount(db), 0, reason: "deleted record stays out of the list");
    expect(_find(db, "a", 1)!["cover"], "https://example.test/new.jpg",
        reason: "the refreshed field is still written");
    expect(_find(db, "a", 1)!["hidden"], 1);
  });

  test('repeated maintenance writes keep it hidden', () {
    _read(db, "a");
    _hide(db, "a");

    // The image provider retries with backoff; each attempt writes again.
    for (var i = 0; i < 4; i++) {
      _maintain(db, "a", cover: "https://example.test/$i.jpg");
    }

    expect(_listCount(db), 0, reason: "no resurrection across retries");
  });

  test('maintenance write on a visible row leaves it visible', () {
    _read(db, "a");
    expect(_listCount(db), 1);

    _maintain(db, "a", cover: "https://example.test/new.jpg");

    expect(_listCount(db), 1);
    expect(_find(db, "a", 1)!["hidden"], isNull);
  });

  test('maintenance write creating a new row makes it visible', () {
    // No pre-existing row: the subquery yields NULL, which reads as visible.
    _maintain(db, "fresh");

    expect(_listCount(db), 1);
    expect(_find(db, "fresh", 1)!["hidden"], isNull);
  });

  test('maintenance write preserves reading state like any other write', () {
    _read(db, "a");
    _hide(db, "a");

    _maintain(db, "a");

    final row = _find(db, "a", 1)!;
    expect(row["readEpisode"], "1,2");
    expect(row["ep"], 3);
    expect(row["page"], 42);
  });

  test('reading still un-hides — maintenance writes did not change that', () {
    _read(db, "a");
    _hide(db, "a");
    _maintain(db, "a");
    expect(_listCount(db), 0);

    // Opening the comic goes through addHistory, which clears the flag.
    _read(db, "a", time: 2000);

    expect(_listCount(db), 1, reason: "reading brings the comic back");
  });

  test('maintenance write touches only the addressed row', () {
    _read(db, "a");
    _read(db, "b");
    _hide(db, "a");

    _maintain(db, "a");

    expect(_find(db, "b", 1)!["hidden"], isNull);
    expect(_listCount(db), 1, reason: "b unaffected");
  });
}
