// 下载管理分区的主页面（用户需求 #1–#10，2026-10-14）。
//
// 四个队列（#2）：当前任务 / 过往任务 / 问题任务 / 待命任务。
// 卡片样式（#3）：封面 + 标题，右侧信息对齐「下载中」弹窗 —— 来源完整名、
// 翻译组（可能没有）、章节；动效（#4）统一走 `DownloadWaveProgress`：
// 暂停即静止、启动阶段之外不做频繁波动。
//
// 顶层功能（#5–#7）：统计缺页 / 修复缺页（二级弹窗见
// `download_manager_dialogs.dart`）、创建下载任务（#11 多步流程延后，
// 这里先给入口与说明）。
library;

import 'package:flutter/material.dart';

import 'package:intl/intl.dart';

import 'package:mangrove/components/components.dart';
import 'package:mangrove/components/download_wave_progress.dart';
import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/comic_source/comic_source.dart';
import 'package:mangrove/foundation/comic_type.dart';
import 'package:mangrove/foundation/download_manager_store.dart';
import 'package:mangrove/foundation/image_provider/cached_image.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/network/download.dart';
import 'package:mangrove/pages/comic_details_page/comic_page.dart';
import 'package:mangrove/utils/io.dart';
import 'package:mangrove/utils/translations.dart';

import 'download_manager_dialogs.dart';

class DownloadManagerPage extends StatefulWidget {
  const DownloadManagerPage({super.key, this.initialBucket});

  /// 打开时落到哪个队列（问题卡片"查看全部"等场景）。
  final DownloadTaskBucket? initialBucket;

  @override
  State<DownloadManagerPage> createState() => _DownloadManagerPageState();
}

class _DownloadManagerPageState extends State<DownloadManagerPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  static int _indexOf(DownloadTaskBucket? bucket) => switch (bucket) {
        DownloadTaskBucket.past => 1,
        DownloadTaskBucket.problem => 2,
        DownloadTaskBucket.standby => 3,
        _ => 0,
      };

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 4,
      vsync: this,
      initialIndex: _indexOf(widget.initialBucket),
    );
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    LocalManager().addListener(_update);
    DownloadHistoryStore.instance.addListener(_update);
    DownloadProblemScanner.instance.addListener(_update);
    // #8 自动检测：进页先快扫已登记的缺页表（毫秒级），保证问题队列
    // 即时可用；磁盘深扫由「统计缺页」弹窗触发，避免进页就全盘 IO。
    DownloadProblemScanner.instance.quickScan();
  }

  @override
  void dispose() {
    LocalManager().removeListener(_update);
    DownloadHistoryStore.instance.removeListener(_update);
    DownloadProblemScanner.instance.removeListener(_update);
    _tabController.dispose();
    super.dispose();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  void _openComic(String id, ComicType type, String cover, String title) {
    context.to(
      () => ComicPage(
        id: id,
        sourceKey: type.sourceKey,
        cover: cover,
        title: title,
        heroID: Object.hash('download-manager', id, type.value),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tasks = LocalManager().downloadingTasks.toList();
    final current = tasks
        .where((t) => classifyDownloadTask(t) == DownloadTaskBucket.current)
        .toList();
    final standby = tasks
        .where((t) => classifyDownloadTask(t) == DownloadTaskBucket.standby)
        .toList();
    final problemTasks = tasks.where((t) => t.isError).toList();
    final scanner = DownloadProblemScanner.instance;
    // 同一本漫画同时有报错任务在队时，任务卡已表达问题；缺页卡不重复出。
    final problemComics = scanner.reports
        .where(
          (r) => !problemTasks.any(
            (t) => t.id == r.comicId && t.comicType == r.comic.comicType,
          ),
        )
        .toList();

    final counts = [
      current.length,
      DownloadHistoryStore.instance.count,
      problemTasks.length + problemComics.length,
      standby.length,
    ];

    return PopScope(
      child: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(counts),
              TabBar(
                controller: _tabController,
                tabs: [
                  for (var i = 0; i < _tabLabels.length; i++)
                    Tab(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_tabLabels[i].tl),
                          if (counts[i] > 0) ...[
                            const SizedBox(width: 6),
                            Text(
                              counts[i].toString(),
                              style: ts.s12.copyWith(
                                color: i == 2
                                    ? context.colorScheme.error
                                    : context.colorScheme.primary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _TaskListView(
                      tasks: current,
                      bucket: DownloadTaskBucket.current,
                      onOpenComic: _openComic,
                    ),
                    _HistoryListView(onOpenComic: _openComic),
                    _ProblemListView(
                      problemTasks: problemTasks,
                      problemComics: problemComics,
                      onOpenComic: _openComic,
                    ),
                    _TaskListView(
                      tasks: standby,
                      bucket: DownloadTaskBucket.standby,
                      onOpenComic: _openComic,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const List<String> _tabLabels = [
    'Current',
    'Past',
    'Problems',
    'Standby',
  ];

  Widget _buildHeader(List<int> counts) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          Tooltip(
            message: "Back".tl,
            child: IconButton(
              onPressed: () => context.pop(),
              icon: const Icon(Icons.arrow_back),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              "Download Manager".tl,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: "Missing Pages Statistics".tl,
            icon: const Icon(Icons.fact_check_outlined),
            onPressed: () => showMissingStatsDialog(context),
          ),
          IconButton(
            tooltip: "Repair Missing Pages".tl,
            icon: const Icon(Icons.auto_fix_high),
            onPressed: () => showMissingRepairDialog(context),
          ),
          MenuButton(
            entries: [
              MenuEntry(
                icon: Icons.add_link,
                text: "Create Download Task".tl,
                onClick: _showCreateTaskPlaceholder,
              ),
              MenuEntry(
                icon: Icons.delete_sweep_outlined,
                text: "Clear Past Records".tl,
                color: context.colorScheme.error,
                onClick: _confirmClearHistory,
              ),
            ],
          ),
        ],
      ).paddingHorizontal(8),
    );
  }

  void _showCreateTaskPlaceholder() {
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: "Create Download Task".tl,
        content: Text(
          "Create Download Task Hint".tl,
        ).paddingHorizontal(16),
        actions: [
          Button.filled(
            onPressed: () => Navigator.of(context).pop(),
            child: Text("OK".tl),
          ),
        ],
      ),
    );
  }

  void _confirmClearHistory() {
    if (DownloadHistoryStore.instance.count == 0) return;
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: "Clear Past Records".tl,
        content: Text("Clear download history? Downloaded comics are not affected."
                .tl)
            .paddingHorizontal(16),
        actions: [
          Button.text(
            onPressed: () => Navigator.of(context).pop(),
            child: Text("Cancel".tl),
          ),
          Button.filled(
            color: context.colorScheme.error,
            onPressed: () {
              Navigator.of(context).pop();
              DownloadHistoryStore.instance.clear();
            },
            child: Text("Confirm".tl),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 当前 / 待命 / 问题任务 卡片
// ---------------------------------------------------------------------------

class _TaskListView extends StatelessWidget {
  const _TaskListView({
    required this.tasks,
    required this.bucket,
    required this.onOpenComic,
  });

  final List<DownloadTask> tasks;
  final DownloadTaskBucket bucket;
  final void Function(String id, ComicType type, String cover, String title)
      onOpenComic;

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return Center(
        child: Text(
          switch (bucket) {
            DownloadTaskBucket.standby => "No standby tasks".tl,
            DownloadTaskBucket.problem => "No problems detected".tl,
            _ => "No active download tasks".tl,
          },
          style: ts.s14.copyWith(color: context.colorScheme.outline),
        ),
      );
    }
    return ListView.builder(
      itemCount: tasks.length,
      itemBuilder: (context, index) => _TaskCard(
        key: ValueKey('dlm-${tasks[index].id}-${tasks[index].comicType.value}'),
        task: tasks[index],
        bucket: bucket,
        onOpenComic: onOpenComic,
      ),
    );
  }
}

class _TaskCard extends StatefulWidget {
  const _TaskCard({
    super.key,
    required this.task,
    required this.bucket,
    required this.onOpenComic,
  });

  final DownloadTask task;
  final DownloadTaskBucket bucket;
  final void Function(String id, ComicType type, String cover, String title)
      onOpenComic;

  @override
  State<_TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<_TaskCard> {
  late DownloadTask task;

  @override
  void initState() {
    super.initState();
    task = widget.task;
    task.addListener(_update);
  }

  @override
  void didUpdateWidget(covariant _TaskCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task != widget.task) {
      oldWidget.task.removeListener(_update);
      task = widget.task;
      task.addListener(_update);
    }
  }

  @override
  void dispose() {
    task.removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (mounted) setState(() {});
  }

  String get _statusLine {
    final eta = task.eta;
    if (!task.isPaused && !task.isError && eta != null) {
      final m = eta.inMinutes, s = eta.inSeconds % 60;
      final etaText = m > 0 ? "${m}m ${s}s" : "${s}s";
      return "${task.message} · ${"~@t left".tlParams({"t": etaText})}";
    }
    return task.message;
  }

  @override
  Widget build(BuildContext context) {
    final t = task;
    final bucket = widget.bucket;
    final running = !t.isPaused && !t.isError;
    // 待命任务从未开始：没有进度可画，不铺波浪。
    final showWave = bucket != DownloadTaskBucket.standby;
    return InkWell(
      onTap: () => widget.onOpenComic(t.id, t.comicType, t.cover ?? '', t.title),
      child: Container(
        height: 132,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Row(
          children: [
            _CoverBox(
              url: t.cover,
              sourceKey: t.comicType.sourceKey,
              cid: t.id,
              width: 82,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          t.title,
                          style: Theme.of(context).textTheme.bodyMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      _taskActions(context, t, bucket),
                    ],
                  ),
                  // #3：来源完整名 · 翻译组 · 章节（与「下载中」弹窗同源）。
                  if (t.subtitle != null)
                    Text(
                      t.subtitle!,
                      style: ts.s12.copyWith(
                        color: context.colorScheme.outline,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const Spacer(),
                  Text(
                    _statusLine,
                    style: ts.s12.copyWith(
                      color: t.isError ? context.colorScheme.error : null,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  if (showWave)
                    // #4：暂停即静止；启动阶段（progress==0）缓慢漂移，
                    // 传输阶段克制波动。
                    DownloadWaveProgress(
                      progress: t.progress == 0 ? null : t.progress,
                      running: running,
                    )
                  else
                    Text(
                      "Queued".tl,
                      style: ts.s12.copyWith(
                        color: context.colorScheme.outline,
                      ),
                    ),
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _taskActions(
    BuildContext context,
    DownloadTask t,
    DownloadTaskBucket bucket,
  ) {
    final manager = LocalManager();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (bucket == DownloadTaskBucket.problem || t.isError)
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: "Retry".tl,
            onPressed: () => manager.resumeTask(t),
          )
        else if (bucket == DownloadTaskBucket.standby)
          IconButton(
            icon: const Icon(Icons.play_arrow, size: 20),
            tooltip: "Start Now".tl,
            onPressed: () {
              manager.moveToFirst(t);
              manager.resumeTask(t);
            },
          )
        else if (t.isPaused)
          IconButton(
            icon: const Icon(Icons.play_arrow, size: 20),
            tooltip: "Start".tl,
            onPressed: () => manager.resumeTask(t),
          )
        else
          IconButton(
            icon: const Icon(Icons.pause, size: 20),
            tooltip: "Pause".tl,
            onPressed: () => manager.pauseTask(t),
          ),
        MenuButton(
          entries: [
            if (bucket == DownloadTaskBucket.current)
              MenuEntry(
                icon: Icons.vertical_align_top,
                text: "Move To First".tl,
                onClick: () => manager.moveToFirst(t),
              ),
            MenuEntry(
              icon: Icons.close,
              text: "Cancel".tl,
              onClick: () => t.cancel(),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 问题漫画卡片（缺页检测）
// ---------------------------------------------------------------------------

class _ProblemListView extends StatelessWidget {
  const _ProblemListView({
    required this.problemTasks,
    required this.problemComics,
    required this.onOpenComic,
  });

  final List<DownloadTask> problemTasks;
  final List<ComicMissingReport> problemComics;
  final void Function(String id, ComicType type, String cover, String title)
      onOpenComic;

  @override
  Widget build(BuildContext context) {
    if (problemTasks.isEmpty && problemComics.isEmpty) {
      return Center(
        child: Text(
          "No problems detected".tl,
          style: ts.s14.copyWith(color: context.colorScheme.outline),
        ),
      );
    }
    return ListView.builder(
      itemCount: problemTasks.length + problemComics.length,
      itemBuilder: (context, index) {
        if (index < problemTasks.length) {
          final task = problemTasks[index];
          return _TaskCard(
            key: ValueKey(
              'dlm-p-${task.id}-${task.comicType.value}',
            ),
            task: task,
            bucket: DownloadTaskBucket.problem,
            onOpenComic: onOpenComic,
          );
        }
        final report = problemComics[index - problemTasks.length];
        return _ProblemComicCard(
          key: ValueKey(
            'dlm-m-${report.comicId}-${report.comic.comicType.value}',
          ),
          report: report,
          onOpenComic: onOpenComic,
        );
      },
    );
  }
}

class _ProblemComicCard extends StatelessWidget {
  const _ProblemComicCard({
    super.key,
    required this.report,
    required this.onOpenComic,
  });

  final ComicMissingReport report;
  final void Function(String id, ComicType type, String cover, String title)
      onOpenComic;

  @override
  Widget build(BuildContext context) {
    final comic = report.comic;
    final sourceName = ComicSource.find(comic.sourceKey)?.name;
    final cover = comic.cover.isEmpty
        ? null
        : "file://${FilePath.join(comic.baseDir, comic.cover)}";
    return InkWell(
      onTap: () => onOpenComic(comic.id, comic.comicType, comic.cover, comic.title),
      child: Container(
        height: 96,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Row(
          children: [
            _CoverBox(
              url: cover,
              sourceKey: comic.sourceKey,
              cid: comic.id,
              width: 58,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    comic.title,
                    style: Theme.of(context).textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  if (sourceName != null)
                    Text(
                      sourceName,
                      style: ts.s12.copyWith(
                        color: context.colorScheme.outline,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const Spacer(),
                  Text(
                    "@a chapters · @b pages missing".tlParams({
                      "a": report.chapterCount,
                      "b": report.pageCount,
                    }),
                    style: ts.s12.copyWith(
                      color: context.colorScheme.error,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.auto_fix_high, size: 20),
              tooltip: "Repair".tl,
              onPressed: () => showMissingRepairDialog(context, single: report),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 过往任务（历史）
// ---------------------------------------------------------------------------

class _HistoryListView extends StatelessWidget {
  const _HistoryListView({required this.onOpenComic});

  final void Function(String id, ComicType type, String cover, String title)
      onOpenComic;

  @override
  Widget build(BuildContext context) {
    final entries = DownloadHistoryStore.instance.entries;
    if (entries.isEmpty) {
      return Center(
        child: Text(
          "No history yet".tl,
          style: ts.s14.copyWith(color: context.colorScheme.outline),
        ),
      );
    }
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return _HistoryCard(
          key: ValueKey('dlm-h-$index-${entry.comicId}-${entry.time}'),
          entry: entry,
          onOpenComic: onOpenComic,
        );
      },
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    super.key,
    required this.entry,
    required this.onOpenComic,
  });

  final DownloadHistoryEntry entry;
  final void Function(String id, ComicType type, String cover, String title)
      onOpenComic;

  String get _detailLine {
    final sourceName = ComicSource.find(entry.sourceKey)?.name;
    final detail = switch (entry.kind) {
      'repair' when (entry.failed ?? 0) > 0 =>
        "Repaired @a, still missing @b".tlParams({
          "a": entry.repaired ?? 0,
          "b": entry.failed ?? 0,
        }),
      'repair' => "Repaired @a pages".tlParams({"a": entry.repaired ?? 0}),
      _ when entry.chapters != null =>
        "@a chapters downloaded".tlParams({"a": entry.chapters ?? 0}),
      _ => "Downloaded".tl,
    };
    if (sourceName == null) return detail;
    return "$sourceName · $detail";
  }

  @override
  Widget build(BuildContext context) {
    final type = ComicType(entry.comicTypeValue);
    final time = DateFormat('yyyy-MM-dd HH:mm').format(entry.time);
    return InkWell(
      onTap: () => onOpenComic(entry.comicId, type, entry.cover ?? '', entry.title),
      child: Container(
        height: 88,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Row(
          children: [
            _CoverBox(
              url: entry.cover,
              sourceKey: entry.sourceKey,
              cid: entry.comicId,
              width: 56,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    style: Theme.of(context).textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _detailLine,
                    style: ts.s12.copyWith(
                      color: (entry.failed ?? 0) > 0
                          ? context.colorScheme.error
                          : context.colorScheme.outline,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Spacer(),
                  Text(
                    time,
                    style: ts.s12.copyWith(
                      color: context.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            // 修复类记录带个小徽标，一眼区分「下载完成」与「修复完成」。
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: entry.kind == 'repair'
                    ? context.colorScheme.tertiaryContainer
                    : context.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                entry.kind == 'repair' ? "Repair".tl : "Download".tl,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 共用小组件
// ---------------------------------------------------------------------------

class _CoverBox extends StatelessWidget {
  const _CoverBox({
    required this.url,
    required this.sourceKey,
    required this.cid,
    required this.width,
  });

  final String? url;
  final String sourceKey;
  final String cid;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: context.colorScheme.primaryContainer,
      ),
      clipBehavior: Clip.antiAlias,
      child: url == null || url!.isEmpty
          ? null
          : Image(
              image: CachedImageProvider(
                url!,
                sourceKey: sourceKey,
                cid: cid,
              ),
              filterQuality: FilterQuality.medium,
              fit: BoxFit.cover,
            ),
    );
  }
}
