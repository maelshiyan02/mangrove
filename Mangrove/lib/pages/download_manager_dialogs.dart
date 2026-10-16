// 「下载管理」的两个二级弹窗（用户需求 #5–#10，2026-10-14）：
//
// * [showMissingStatsDialog] —— 统计缺页：对全库素材漫画跑一轮磁盘深扫
//   （`DownloadProblemScanner.deepScan` → 逐本 `reconcileDiskState`），
//   把"半截章节 + 磁盘空洞"补记进 `missing_pages.json`，然后按
//   漫画 → 章节 → 缺页数 展示（#9）。
// * [showMissingRepairDialog] —— 修复缺页：勾选要修的**章节**创建修复任务
//   （#10：不是一口气全修，可以有选择性地优先修复），完成后在弹窗内
//   显示结果反馈（#7）。
//
// 两个弹窗都不直接碰磁盘细节：扫描在 `DownloadProblemScanner`，修复在
// `RepairDownloadTask`，这里只做选择与展示。
library;

import 'package:flutter/material.dart';

import 'package:mangrove/components/components.dart';
import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/download_manager_store.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/network/repair_download.dart';
import 'package:mangrove/utils/io.dart';
import 'package:mangrove/utils/translations.dart';

/// 打开「统计缺页」弹窗，进入即自动开始一轮深扫。
void showMissingStatsDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (context) => const _MissingStatsDialog(),
  );
}

/// 打开「修复缺页」弹窗。[single] 传入时只列出这一本（问题队列卡片的
/// 每本入口）；不传则列出扫描器当前的全部问题漫画。
void showMissingRepairDialog(
  BuildContext context, {
  ComicMissingReport? single,
}) {
  final reports = single != null
      ? [single]
      : DownloadProblemScanner.instance.reports;
  if (reports.isEmpty) {
    context.showMessage(message: "No problems detected".tl);
    return;
  }
  showDialog(
    context: context,
    builder: (context) => _MissingRepairDialog(reports: reports),
  );
}

// ---------------------------------------------------------------------------
// 统计缺页
// ---------------------------------------------------------------------------

class _MissingStatsDialog extends StatefulWidget {
  const _MissingStatsDialog();

  @override
  State<_MissingStatsDialog> createState() => _MissingStatsDialogState();
}

class _MissingStatsDialogState extends State<_MissingStatsDialog> {
  @override
  void initState() {
    super.initState();
    DownloadProblemScanner.instance.addListener(_update);
    // 统计的意义就是拿最新状态：进弹窗先跑一轮深扫（可中止）。
    // deepScan 自带重入守卫，重复打开弹窗不会叠扫。
    DownloadProblemScanner.instance.deepScan();
  }

  @override
  void dispose() {
    DownloadProblemScanner.instance.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scanner = DownloadProblemScanner.instance;
    final reports = scanner.reports;
    final totalChapters = reports.fold<int>(0, (a, r) => a + r.chapterCount);
    final totalPages = reports.fold<int>(0, (a, r) => a + r.pageCount);

    return ContentDialog(
      dismissible: !scanner.scanning,
      title: "Missing Pages Statistics".tl,
      content: SizedBox(
        width: 640,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (scanner.scanning)
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      scanner.totalCount > 0
                          ? "Scanning @a/@b".tlParams({
                              "a": scanner.scannedCount,
                              "b": scanner.totalCount,
                            })
                          : "Scanning...".tl,
                      style: ts.s12,
                    ),
                  ),
                  Button.text(
                    onPressed: () => scanner.cancelScan(),
                    child: Text("Cancel Scan".tl),
                  ),
                ],
              ),
            const SizedBox(height: 4),
            Text(
              "@a comics · @b chapters · @c pages missing".tlParams({
                "a": reports.length,
                "b": totalChapters,
                "c": totalPages,
              }),
              style: ts.s12.copyWith(
                color: context.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: reports.isEmpty && !scanner.scanning
                  ? Center(
                      child: Text(
                        "No problems detected".tl,
                        style: ts.s14.copyWith(
                          color: context.colorScheme.outline,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: reports.length,
                      itemBuilder: (context, index) =>
                          _StatsComicGroup(report: reports[index]),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        Button.text(
          onPressed: () => Navigator.of(context).pop(),
          child: Text("Close".tl),
        ),
        if (reports.isNotEmpty)
          Button.filled(
            onPressed: () {
              Navigator.of(context).pop();
              showMissingRepairDialog(App.rootContext);
            },
            child: Text("Repair Missing Pages".tl),
          ),
      ],
    );
  }
}

/// 一本问题漫画的折叠分组：标题行 + 章节缺页明细（#9）。
class _StatsComicGroup extends StatelessWidget {
  const _StatsComicGroup({required this.report});

  final ComicMissingReport report;

  @override
  Widget build(BuildContext context) {
    // 章节聚合：chapterId -> (显示名, 缺页数)。显示名优先用登记时的
    // 章节标题，回落到目录名（chapterId 本身）。
    final labels = <String, String>{};
    final counts = <String, int>{};
    for (final e in report.table.entries) {
      counts[e.chapterId] = (counts[e.chapterId] ?? 0) + 1;
      if ((labels[e.chapterId] ?? '').isEmpty && e.chapterTitle.isNotEmpty) {
        labels[e.chapterId] = e.chapterTitle;
      }
    }
    final chapters = counts.keys.toList()..sort();
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
      childrenPadding: const EdgeInsets.only(left: 16, bottom: 8),
      title: Text(
        report.comic.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ts.s14.bold,
      ),
      subtitle: Text(
        "@a chapters · @b pages missing".tlParams({
          "a": report.chapterCount,
          "b": report.pageCount,
        }),
        style: ts.s12.copyWith(
          color: context.colorScheme.error,
        ),
      ),
      children: [
        for (final cid in chapters)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              "${labels[cid] ?? (cid.isEmpty ? "Other".tl : cid)} · "
              "${"@a pages missing".tlParams({"a": counts[cid]!})}",
              style: ts.s12,
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 修复缺页（选择性）
// ---------------------------------------------------------------------------

class _MissingRepairDialog extends StatefulWidget {
  const _MissingRepairDialog({required this.reports});

  final List<ComicMissingReport> reports;

  @override
  State<_MissingRepairDialog> createState() => _MissingRepairDialogState();
}

class _MissingRepairDialogState extends State<_MissingRepairDialog> {
  /// 选中要修复的章节：`报告下标 -> 章节 id 集合`。默认全不选（#10：
  /// 有选择性地修，不一口气全修）。
  final Map<int, Set<String>> _selected = {};

  /// 非空 = 已创建修复任务的结果反馈（#7），此时关闭选择。
  String? _result;

  bool _creating = false;

  int get _selectedChapterCount =>
      _selected.values.fold(0, (a, s) => a + s.length);

  void _toggleComic(int index) {
    setState(() {
      final current = _selected[index];
      final all = widget.reports[index].table.chapterIds.toSet();
      if (current != null && current.length == all.length) {
        _selected.remove(index);
      } else {
        _selected[index] = all;
      }
    });
  }

  void _toggleChapter(int index, String cid) {
    setState(() {
      final set = _selected.putIfAbsent(index, () => <String>{});
      if (!set.add(cid)) {
        set.remove(cid);
        if (set.isEmpty) _selected.remove(index);
      }
    });
  }

  Future<void> _createTasks() async {
    setState(() => _creating = true);
    var taskCount = 0;
    var chapterCount = 0;
    var pageCount = 0;
    for (var i = 0; i < widget.reports.length; i++) {
      final sel = _selected[i];
      if (sel == null || sel.isEmpty) continue;
      final report = widget.reports[i];
      final entries = report.table.entries
          .where((e) => sel.contains(e.chapterId))
          .toList();
      if (entries.isEmpty) continue;
      final source = report.comic.comicType.comicSource;
      if (source == null) continue;
      // 与 RepairDownloadTask.enqueue 相同的任务构造，但不走它内置的逐单
      // toast —— 批量选择时一本一个 toast 会刷屏；结果统一显示在本弹窗里。
      registerRepairDownloadTaskType();
      final task = RepairDownloadTask(
        source: source,
        comicId: report.comic.id,
        targets: entries,
        comicTitle: report.comic.title,
        comicCover: report.comic.cover.isEmpty
            ? null
            : "file://${FilePath.join(report.comic.baseDir, report.comic.cover)}",
      )..path = report.comic.baseDir;
      LocalManager().addTask(task);
      taskCount++;
      chapterCount += sel.length;
      pageCount += entries.length;
    }
    setState(() {
      _creating = false;
      if (taskCount > 0) {
        _result = "Created @a repair task(s) for @b chapter(s), @c page(s)"
            .tlParams({
          "a": taskCount,
          "b": chapterCount,
          "c": pageCount,
        });
      }
    });
    if (taskCount > 0) {
      App.rootContext.showMessage(message: "Repair started".tl);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      dismissible: !_creating,
      title: "Repair Missing Pages".tl,
      content: SizedBox(
        width: 640,
        height: 480,
        child: _result != null
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.auto_fix_high, size: 44),
                  const SizedBox(height: 12),
                  Text(_result!, style: ts.s14, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(
                    "Repair runs in the download queue; the problem list updates when pages are recovered."
                        .tl,
                    style: ts.s12.copyWith(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Select chapters to repair".tl,
                    style: ts.s12.copyWith(
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: ListView.builder(
                      itemCount: widget.reports.length,
                      itemBuilder: (context, index) => _RepairComicGroup(
                        report: widget.reports[index],
                        selected: _selected[index] ?? const <String>{},
                        onToggleComic: () => _toggleComic(index),
                        onToggleChapter: (cid) => _toggleChapter(index, cid),
                      ),
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        Button.text(
          onPressed: () {
            if (_creating) return;
            Navigator.of(context).pop();
          },
          child: Text(_result != null ? "Close".tl : "Cancel".tl),
        ),
        if (_result == null)
          Button.filled(
            isLoading: _creating,
            onPressed: () {
              if (_selectedChapterCount == 0) return;
              _createTasks();
            },
            child: Text(
              "@a chapters selected".tlParams({"a": _selectedChapterCount}),
            ),
          ),
      ],
    );
  }
}

class _RepairComicGroup extends StatelessWidget {
  const _RepairComicGroup({
    required this.report,
    required this.selected,
    required this.onToggleComic,
    required this.onToggleChapter,
  });

  final ComicMissingReport report;
  final Set<String> selected;
  final VoidCallback onToggleComic;
  final void Function(String cid) onToggleChapter;

  @override
  Widget build(BuildContext context) {
    final chapters = report.table.chapterIds.toList()..sort();
    final allSelected =
        selected.length == chapters.length && chapters.isNotEmpty;
    return Column(
      children: [
        CheckboxListTile(
          value: allSelected,
          tristate: false,
          title: Text(
            report.comic.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ts.s14.bold,
          ),
          subtitle: Text(
            "@a chapters · @b pages missing".tlParams({
              "a": report.chapterCount,
              "b": report.pageCount,
            }),
            style: ts.s12.copyWith(color: context.colorScheme.error),
          ),
          onChanged: (_) => onToggleComic(),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 24),
          child: Column(
            children: [
              for (final cid in chapters)
                CheckboxListTile(
                  dense: true,
                  value: selected.contains(cid),
                  title: Text(
                    cid.isEmpty ? "Other".tl : cid,
                    style: ts.s12,
                  ),
                  subtitle: Text(
                    "@a pages missing".tlParams({
                      "a": report.table.countOfChapter(cid),
                    }),
                    style: ts.s12,
                  ),
                  onChanged: (_) => onToggleChapter(cid),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
