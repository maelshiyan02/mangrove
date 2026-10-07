import 'package:flutter/material.dart';

import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/missing_pages.dart';
import 'package:venera/network/repair_download.dart';
import 'package:venera/utils/translations.dart';

/// Open a dialog listing every missing page of [comic] (grouped by chapter),
/// with one-tap repair for a single page, a whole chapter, or the entire comic
/// (P5-S4). Shows a toast and closes itself; the download queue then runs the
/// repair and the table updates live.
void showMissingPagesDialog(BuildContext context, LocalComic comic) {
  final table = MissingPages.peek(comic.baseDir);
  if (table == null || table.isEmpty) {
    context.showMessage(message: "No missing pages".tl);
    return;
  }
  showDialog(
    context: context,
    builder: (ctx) => _MissingPagesDialog(comic: comic, table: table),
  );
}

class _MissingPagesDialog extends StatefulWidget {
  final LocalComic comic;
  final MissingPagesTable table;

  const _MissingPagesDialog({required this.comic, required this.table});

  @override
  State<_MissingPagesDialog> createState() => _MissingPagesDialogState();
}

class _MissingPagesDialogState extends State<_MissingPagesDialog> {
  late MissingPagesTable _table;

  @override
  void initState() {
    super.initState();
    _table = widget.table;
    // A repair run mutates the table on disk; rebuild the list live so rows
    // disappear as pages are recovered while the dialog stays open.
    LocalManager().addListener(_refresh);
  }

  @override
  void dispose() {
    LocalManager().removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {
      _table =
          MissingPages.peek(widget.comic.baseDir) ??
          MissingPagesTable(sourceKey: '', comicId: '');
    });
  }

  @override
  Widget build(BuildContext context) {
    final chapters = _table.chapterIds.toList();
    return AlertDialog(
      title: Text("Missing pages (@a)".tlParams({"a": _table.count})),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.auto_fix_high),
              title: Text("Repair all".tl),
              onTap: () {
                Navigator.of(context).pop();
                RepairDownloadTask.repairComic(widget.comic);
              },
            ),
            const Divider(),
            if (_table.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text("No missing pages".tl),
              )
            else
              for (final cid in chapters) ...[
                _chapterHeader(cid),
                for (final e in _table.entries.where((x) => x.chapterId == cid))
                  ListTile(
                    title: Text("Page ${e.index + 1}"),
                    subtitle: Text("${e.error} · ${e.attempts} attempts"),
                    trailing: IconButton(
                      icon: const Icon(Icons.auto_fix_high),
                      tooltip: "Repair this page".tl,
                      onPressed: () {
                        Navigator.of(context).pop();
                        RepairDownloadTask.repairEntry(widget.comic, e);
                      },
                    ),
                  ),
              ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text("Close".tl),
        ),
      ],
    );
  }

  Widget _chapterHeader(String cid) {
    final count = _table.countOfChapter(cid);
    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 4, right: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              cid.isEmpty ? "Other".tl : cid,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Text("$count"),
          IconButton(
            icon: const Icon(Icons.auto_fix_high),
            tooltip: "Repair chapter".tl,
            onPressed: () {
              Navigator.of(context).pop();
              RepairDownloadTask.repairChapter(widget.comic, cid);
            },
          ),
        ],
      ),
    );
  }
}
