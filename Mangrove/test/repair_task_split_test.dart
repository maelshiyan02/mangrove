import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/foundation/download_manager_store.dart';
import 'package:mangrove/foundation/missing_pages.dart';
import 'package:mangrove/network/repair_download.dart';

/// Per-chapter repair task splitting (2026-10-16, user-tested feedback):
///
/// The old flow merged every selected chapter of a comic into ONE
/// "condensed" [RepairDownloadTask] whose `id` was `repair:<comicId>` — the
/// same id for the whole book. The queue and the "downloading" dialog index
/// tasks by id, so a second task for the same comic overwrote the first and
/// the UI rendered blank placeholders. Now every missing chapter gets its
/// own task with a chapter-scoped id.
///
/// Disk/queue IO ([RepairDownloadTask.enqueue] needs `LocalManager` +
/// `App.dataPath`) is left to GUI/manual checks — same policy as the other
/// store tests in this directory; these tests cover the pure decision
/// functions the flow is built on.
void main() {
  MissingPageEntry page(String chapterId, int index, {String title = ''}) =>
      MissingPageEntry(
        chapterId: chapterId,
        chapterTitle: title,
        index: index,
        url: 'u',
        error: 'e',
      );

  group('groupRepairEntriesByChapter', () {
    test('splits a multi-chapter selection into per-chapter groups', () {
      final entries = [
        page('100', 0),
        page('101', 3),
        page('100', 7),
        page('102', 1),
      ];
      final groups = groupRepairEntriesByChapter(entries);
      expect(groups.keys.toList(), ['100', '101', '102']);
      expect(groups['100']!.length, 2);
      expect(groups['101']!.length, 1);
      expect(groups['102']!.length, 1);
    });

    test('a single-chapter selection stays one group', () {
      final groups = groupRepairEntriesByChapter([page('100', 0), page('100', 5)]);
      expect(groups.length, 1);
      expect(groups['100']!.length, 2);
    });

    test('empty selection produces no groups', () {
      expect(groupRepairEntriesByChapter(const []), isEmpty);
    });

    test('group order follows first appearance (stable for the queue)', () {
      // The repair dialog sorts chapters for display; the grouping itself
      // must not reorder, so a resumed queue keeps its original sequence.
      final groups = groupRepairEntriesByChapter([
        page('zz', 0),
        page('aa', 0),
        page('zz', 1),
      ]);
      expect(groups.keys.toList(), ['zz', 'aa']);
    });
  });

  group('repairTaskId', () {
    test('chapter-scoped id keeps tasks of one comic distinct', () {
      // The exact collision the user hit: two chapters of the same comic
      // must never share an id.
      expect(repairTaskId('c1', '100'), 'repair:c1:100');
      expect(repairTaskId('c1', '101'), 'repair:c1:101');
      expect(repairTaskId('c1', '100') == repairTaskId('c1', '101'), isFalse);
    });

    test('missing/empty chapter falls back to the legacy whole-book id', () {
      // Persisted tasks written before the split carry no chapterId; they
      // must restore under the old id format.
      expect(repairTaskId('c1', null), 'repair:c1');
      expect(repairTaskId('c1', ''), 'repair:c1');
    });

    test('distinct comics never collide', () {
      expect(repairTaskId('c1', '100') == repairTaskId('c2', '100'), isFalse);
    });
  });

  group('auto repair mode setting', () {
    test('defaults to off (manual) so behaviour is unchanged on upgrade', () {
      // 2026-10-16: auto missing-page repair ships disabled. Users opt in
      // via Settings > Download Management or the repair dialog dropdown.
      // Reading the default map only — no disk IO (saveData writes to
      // App.dataPath, unavailable in the test sandbox).
      expect(autoRepairMissingPages, isFalse);
      expect(appdata.settings['autoRepairMissingPages'], isFalse);
    });
  });

  group('download manager tab labels are localised', () {
    // The four queue tabs read English keys via .tl; zh_CN/zh_TW must carry
    // the Chinese labels or the UI shows raw English (user screenshot 1).
    Map<String, dynamic> tableFor(String lang) {
      final raw = File('assets/translation.json').readAsStringSync();
      return (jsonDecode(raw) as Map<String, dynamic>)[lang];
    }

    test('zh_CN: Past/Problems/Standby translate', () {
      final t = tableFor('zh_CN');
      expect(t['Past'], '历史');
      expect(t['Problems'], '问题');
      expect(t['Standby'], '待命');
    });

    test('zh_TW: Past/Problems/Standby translate', () {
      final t = tableFor('zh_TW');
      expect(t['Past'], '歷史');
      expect(t['Problems'], '問題');
      expect(t['Standby'], '待命');
    });

    test('empty repair dialog shows the "no missing pages" hint', () {
      // User requirement: opening the repair dialog with nothing missing
      // must display 无缺页 inside the dialog.
      expect(tableFor('zh_CN')['No missing pages to repair'], '无缺页');
      expect(tableFor('zh_TW')['No missing pages to repair'], '無缺頁');
    });

    test('auto/manual mode switch labels are localised', () {
      // The repair dialog title trailing + the settings "Download
      // Management" group share this auto/manual dropdown (2026-10-16).
      expect(tableFor('zh_CN')['Auto'], '自动');
      expect(tableFor('zh_CN')['Manual'], '手动');
      expect(tableFor('zh_TW')['Auto'], '自動');
      expect(tableFor('zh_TW')['Manual'], '手動');
    });

    test('repair buttons share one name across every entry point', () {
      // Detail page / local comics menu / manager header / home section all
      // read the same key now (only the scope differs).
      for (final lang in ['zh_CN', 'zh_TW']) {
        final t = tableFor(lang);
        expect(t['Missing Page Repair'], isNotNull);
        expect(t['Missing Page Repair (@a)'], isNotNull);
        expect(t['Download Management'], isNotNull);
        expect(t['Auto Repair Missing Pages'], isNotNull);
        expect(t['Auto-created @a repair task(s)'], isNotNull);
      }
    });
  });
}
