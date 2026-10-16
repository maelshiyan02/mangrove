import 'package:flutter/material.dart';
import 'package:mangrove/components/components.dart';
import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/appdata.dart';
import 'package:mangrove/foundation/bt_project/bt_project_manager.dart';
import 'package:mangrove/foundation/comic_card_kind.dart';
import 'package:mangrove/foundation/comic_type.dart';
import 'package:mangrove/foundation/download_manager_store.dart';
import 'package:mangrove/foundation/export_tasks.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/missing_pages.dart';
import 'package:mangrove/foundation/open_folder.dart';
import 'package:mangrove/pages/comic_delete_dialog.dart';
import 'package:mangrove/pages/comic_details_page/comic_page.dart';
import 'package:mangrove/pages/download_manager_dialogs.dart';
import 'package:mangrove/pages/missing_pages_dialog.dart';
import 'package:mangrove/pages/translation_studio/studio_page.dart';
import 'package:mangrove/pages/webdav_migration_dialog.dart';
import 'package:mangrove/network/download.dart';
import 'package:mangrove/pages/downloading_page.dart';
import 'package:mangrove/pages/favorites/favorites_page.dart';
import 'package:mangrove/utils/io.dart';
import 'package:mangrove/utils/translations.dart';
import 'package:mangrove/pages/home_page.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:mangrove/foundation/translation_project/finished_export.dart';
import 'package:mangrove/foundation/translation_project/project.dart';
import 'package:mangrove/pages/translation_studio/studio_project_menu.dart';

/// Short remaining-time text for the download progress label, e.g. "45s",
/// "5m 30s", "1h 5m".
String _formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s2 = d.inSeconds % 60;
  if (h > 0) return "${h}h ${m}m";
  if (m > 0) return "${m}m ${s2}s";
  return "${s2}s";
}

class LocalComicsPage extends StatefulWidget {
  const LocalComicsPage({super.key});

  @override
  State<LocalComicsPage> createState() => _LocalComicsPageState();
}

class _LocalComicsPageState extends State<LocalComicsPage>
    with
        SingleTickerProviderStateMixin,
        SelectionMixin<LocalComicsPage, LocalComic> {
  late List<LocalComic> comics;

  late LocalSortType sortType;

  String keyword = "";

  bool searchMode = false;

  @override
  List<LocalComic> get selectableItems => comics;

  LocalComicStatus? currentTab; // null means "全部" (all)

  /// 当前选中的**来源**段（素材 / 工程 / 成品），与 `ComicLibrary/` 的三个下属
  /// 文件夹一一对应。默认「素材」—— 打开本地库想看的是自己下载的漫画，不是工程。
  ComicCardKind kindFilter = ComicCardKind.downloaded;

  /// 只有素材才有下载状态；工程/成品段把状态 tab 整行藏掉（否则会出现
  /// "成品 + 下载中"这种永不为空也不会非空的格子）。
  bool get _statusTabsVisible => kindFilter == ComicCardKind.downloaded;

  void _selectKind(ComicCardKind kind) {
    if (kindFilter == kind) return;
    setState(() {
      kindFilter = kind;
      // 换段时状态筛选必须回到"全部"：tab 藏起来期间用户看不见它，回来时如果
      // 还停在第 3 格，看到的是一个"什么都不显示"的列表，而原因看不见。
      currentTab = null;
      _tabController.index = 0;
      comics = _collectComics();
    });
  }

  /// Download tasks we've attached a listener to, so tiles repaint as bytes
  /// arrive instead of only when a task starts/finishes. Mirrors the sync in
  /// DownloadingPage (#P5/S1).
  final _listenedTasks = <DownloadTask>{};

  /// Matches a library entry to its live download task, if any.
  DownloadTask? _taskFor(LocalComic comic) {
    for (final t in LocalManager().downloadingTasks) {
      if (t.id == comic.id && t.comicType == comic.comicType) {
        return t;
      }
    }
    return null;
  }

  /// Card overlay for a downloading comic: bar + short label, colored by state
  /// (yellow = downloading, grey = paused, red = failed) — the same palette
  /// agreed for the chapter chips.
  ComicTileProgress? _downloadProgress(LocalComic comic) {
    final t = _taskFor(comic);
    if (t == null) return null;
    if (t.isError) {
      return ComicTileProgress(
        t.progress,
        label: "Error".tl,
        color: Colors.red,
      );
    }
    if (t.isPaused) {
      return ComicTileProgress(
        t.progress,
        label: "Paused".tl,
        color: Colors.grey,
      );
    }
    final percent = (t.progress * 100).clamp(0, 100).round();
    final eta = t.eta;
    final label = eta == null
        ? "$percent%"
        : "$percent% · ~${_formatDuration(eta)}";
    return ComicTileProgress(t.progress, label: label, color: Colors.amber);
  }

  /// 本地库卡片右上角的分类小标签：素材（普通漫画）/ 工程 / 成品（翻译版）。
  ///
  /// 判据走纯逻辑层的 [comicCardKindOf]（按 id 前缀分三类，见该文件注释），不在这里
  /// 各写一遍前缀 —— 加第三种产物时只改一处，避免"某类又混进本地库"。
  static const Map<ComicCardKind, String> _categoryLabels = {
    ComicCardKind.downloaded: '素材',
    ComicCardKind.project: '工程',
    ComicCardKind.product: '成品',
  };

  String _categoryLabel(LocalComic comic) =>
      _categoryLabels[comicCardKindOf(comic.id)] ?? '素材';

  /// 本地库「工程 / 成品」段为空时，在网格位置渲染一张占位卡：
  /// 虚线边框 + 加号，点击进入对应二级弹窗。
  /// - 工程段：打开「创建翻译工程」向导（复用 [createStudioProject]）。
  /// - 成品段：弹出一个本地工程列表，选一个导出成品到 `translated/`。
  Widget _buildEmptySegmentSliver(BuildContext context) {
    final isProduct = kindFilter == ComicCardKind.product;
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return SliverToBoxAdapter(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: isProduct
                  ? () => _pickProjectAndPublish(context)
                  : () async {
                      await createStudioProject(context);
                      if (mounted) {
                        await BtProjectManager().scan();
                        update();
                      }
                    },
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: cs.outline),
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.add, size: 48),
                    const SizedBox(height: 12),
                    Text(
                      isProduct
                          ? 'No published works yet'.tl
                          : 'No translation projects yet'.tl,
                      style: textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      isProduct
                          ? 'Pick a project to export a finished comic'.tl
                          : 'Create a new translation project'.tl,
                      style: textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 成品段为空时的二级弹窗：列出本地翻译工程，选一个导出成品到
  /// `ComicLibrary/translated/`（复用工作室已有的 [FinishedExport.publish]）。
  Future<void> _pickProjectAndPublish(BuildContext context) async {
    await BtProjectManager().ensureReady();
    final ids = BtProjectManager().projectIds;
    if (ids.isEmpty) {
      context.showMessage(message: 'No translation projects found'.tl);
      return;
    }
    final projects = <TranslationProject>[];
    for (final id in ids) {
      final tp = await BtProjectManager().ensureTranslationProject(id);
      if (tp != null) projects.add(tp);
    }
    if (projects.isEmpty) {
      context.showMessage(message: 'No translation projects found'.tl);
      return;
    }
    final chosen = await showDialog<TranslationProject>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Select a project to export'.tl),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: projects.length,
            itemBuilder: (context, i) {
              final p = projects[i];
              return ListTile(
                title: Text(FinishedExport.comicNameFor(p)),
                subtitle: Text(p.directory),
                onTap: () => context.pop(p),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => context.pop(),
            child: Text('Cancel'.tl),
          ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    final libraryRoot = LocalManager().path;
    if (libraryRoot.isEmpty) {
      context.showMessage(message: 'Local library is not ready yet.'.tl);
      return;
    }
    final translatedRoot = FilePath.join(
      Directory(libraryRoot).parent.path,
      'translated',
    );
    final comicName = FinishedExport.comicNameFor(chosen);
    final controller = showLoadingDialog(
      context,
      message: 'Publishing…'.tl,
      barrierDismissible: false,
      withProgress: true,
    );
    FinishedExportReport report;
    try {
      report = await FinishedExport.publish(
        project: chosen,
        translatedRoot: translatedRoot,
        comicName: comicName,
        onProgress: (done, total) {
          if (total > 0) controller.setProgress(done / total);
        },
      );
    } catch (e, s) {
      Log.error('Local Library', 'Publish failed', s);
      controller.close();
      if (mounted) {
        context.showMessage(message: 'Publish failed: @a'.tlParams({'a': e}));
      }
      return;
    }
    controller.close();
    if (!mounted) return;
    context.showMessage(
      message: report.ok
          ? 'Exported @name to translated/'.tlParams({'name': comicName})
          : (report.error != null
              ? 'Publish failed: @a'.tlParams({'a': report.error!})
          : 'Nothing published (@a)'.tlParams({'a': comicName})),
    );
    update();
  }

  /// Re-attach task listeners whenever the queue contents change.
  void _syncTaskListeners() {
    final current = LocalManager().downloadingTasks.toSet();
    for (final t in current.difference(_listenedTasks)) {
      t.addListener(_onTaskProgress);
    }
    for (final t in _listenedTasks.difference(current)) {
      t.removeListener(_onTaskProgress);
    }
    _listenedTasks
      ..clear()
      ..addAll(current);
  }

  /// Progress notification: repaint only, never re-query the library.
  void _onTaskProgress() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Builds the comic list for the current tab/keyword, merging active
  /// downloading tasks that aren't persisted in the database yet, so an
  /// in-progress comic shows under "All"/"Downloading" right away instead of
  /// only after switching tabs forces a rebuild (#90).
  List<LocalComic> _collectComics() {
    List<LocalComic> all;
    if (keyword.isEmpty) {
      all = LocalManager().getComics(sortType);
    } else {
      all = LocalManager().search(keyword);
    }
    // Merge active downloading tasks that aren't yet in the database
    var existingIds = all.map((c) => '${c.id}_${c.comicType}').toSet();
    var downloadingComics = LocalManager().downloadingTasks
        .where((task) => !existingIds.contains('${task.id}_${task.comicType}'))
        .map((task) => task.toLocalComic())
        .toList();
    all = [...downloadingComics, ...all];
    // 按**来源**分（素材 / 工程 / 成品）。判据取自 [comicCardKindOf] —— 三者
    // 在 `local.db` 里同表混排、`comic_type` 又都是 `local`，只能按 id 前缀分。
    // 各处各写一遍 `startsWith('bt_')` 就会漂移（实测：主页漏排 → 主页显示
    // `MDGH-ch1`，而那是 `projects/` 里的一个工程）。
    all = all.where((c) => comicCardKindOf(c.id) == kindFilter).toList();
    return currentTab == null
        ? all
        : all.where((c) => c.status == currentTab).toList();
  }

  void update() {
    setState(() {
      comics = _collectComics();
    });
  }

  /// Library changed (task added/removed, comic deleted...): rebuild the list
  /// and keep the per-task progress listeners in sync.
  void _onLocalChanged() {
    _syncTaskListeners();
    update();
  }

  late TabController _tabController;

  @override
  void initState() {
    var sort = appdata.implicitData["local_sort"] ?? "default";
    sortType = LocalSortType.fromString(sort);
    comics = _collectComics();
    LocalManager().addListener(_onLocalChanged);
    BtProjectManager().addListener(update);
    _syncTaskListeners();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(_onTabChanged);
    super.initState();
    // Registers imgtrans_*.json projects as comics; no-op when unconfigured.
    if (BtProjectManager.isEnabled) {
      BtProjectManager().scan();
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    LocalManager().removeListener(_onLocalChanged);
    BtProjectManager().removeListener(update);
    for (final t in _listenedTasks) {
      t.removeListener(_onTaskProgress);
    }
    _listenedTasks.clear();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    setState(() {
      currentTab = switch (_tabController.index) {
        1 => LocalComicStatus.downloaded,
        2 => LocalComicStatus.downloading,
        3 => LocalComicStatus.notDownloaded,
        _ => null,
      };
    });
    update();
  }

  void sort() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Sort".tl,
              content: RadioGroup<LocalSortType>(
                groupValue: sortType,
                onChanged: (v) {
                  setState(() {
                    sortType = v ?? sortType;
                  });
                },
                child: Column(
                  children: [
                    RadioListTile<LocalSortType>(
                      title: Text("Default".tl),
                      value: LocalSortType.defaultSort,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Name Asc".tl),
                      value: LocalSortType.name,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Name Desc".tl),
                      value: LocalSortType.nameDesc,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Newest First".tl),
                      value: LocalSortType.timeDesc,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Oldest First".tl),
                      value: LocalSortType.timeAsc,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Author".tl),
                      value: LocalSortType.author,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Last Read".tl),
                      value: LocalSortType.lastRead,
                    ),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () {
                    appdata.implicitData["local_sort"] = sortType.value;
                    appdata.writeImplicitData();
                    Navigator.pop(context);
                    update();
                  },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget buildMultiSelectMenu() {
    return MenuButton(
      entries: [
        MenuEntry(
          icon: Icons.delete_outline,
          text: "Delete".tl,
          onClick: () {
            deleteComics(selectedItems.keys.toList()).then((value) {
              if (value) {
                exitSelectMode();
              }
            });
          },
        ),
        MenuEntry(
          icon: Icons.favorite_border,
          text: "Add to favorites".tl,
          onClick: () {
            addFavorite(selectedItems.keys.toList());
          },
        ),
        if (selectedItems.length == 1)
          MenuEntry(
            icon: Icons.folder_open,
            text: "Open Folder".tl,
            onClick: () {
              openComicFolder(selectedItems.keys.first);
            },
          ),
        if (selectedItems.length == 1)
          MenuEntry(
            icon: Icons.chrome_reader_mode_outlined,
            text: "View Detail".tl,
            onClick: () {
              context.to(
                () => ComicPage(
                  id: selectedItems.keys.first.id,
                  sourceKey: selectedItems.keys.first.sourceKey,
                ),
              );
            },
          ),
        if (selectedItems.isNotEmpty)
          ...exportActions(selectedItems.keys.toList()),
        if (selectedItems.isNotEmpty)
          MenuEntry(
            icon: Icons.archive_outlined,
            text: "Export .mangrove_comics".tl,
            onClick: () => _startMangroveExport(selectedItems.keys.toList()),
          ),
        if (selectedItems.isNotEmpty)
          MenuEntry(
            icon: Icons.cloud_upload_outlined,
            text: "Migrate to WebDAV source".tl,
            onClick: () => _startWebdavMigration(selectedItems.keys.toList()),
          ),
      ],
    );
  }

  /// 第一级筛选：**来源**（素材 / 工程 / 成品）。
  ///
  /// 与磁盘上 `ComicLibrary/` 的三个下属文件夹一一对应 —— 用户说"明明已经分成
  /// 三个文件夹了"，那界面上就该有三段，而不是把三类混在一张列表里。
  Widget _buildKindSegments(BuildContext context) {
    final label = <ComicCardKind, String>{
      ComicCardKind.downloaded: "Artwork".tl,
      ComicCardKind.project: "Project".tl,
      ComicCardKind.product: "Published".tl,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SegmentedButton<ComicCardKind>(
        segments: [
          for (final kind in localLibraryKinds)
            ButtonSegment<ComicCardKind>(
              value: kind,
              label: Text(label[kind]!),
              icon: Icon(switch (kind) {
                ComicCardKind.downloaded => Icons.local_library_outlined,
                ComicCardKind.project => Icons.translate_rounded,
                ComicCardKind.product => Icons.auto_stories_outlined,
              }),
            ),
        ],
        selected: {kindFilter},
        onSelectionChanged: (next) => _selectKind(next.first),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: "Select All".tl,
        onPressed: selectAll,
      ),
      IconButton(
        icon: const Icon(Icons.deselect),
        tooltip: "Deselect".tl,
        onPressed: deSelect,
      ),
      IconButton(
        icon: const Icon(Icons.flip),
        tooltip: "Invert Selection".tl,
        onPressed: invertSelection,
      ),
      buildMultiSelectMenu(),
    ];

    List<Widget> normalActions = [
      Tooltip(
        message: "Search".tl,
        child: IconButton(
          icon: const Icon(Icons.search),
          onPressed: () {
            setState(() {
              searchMode = true;
            });
          },
        ),
      ),
      Tooltip(
        message: "Sort".tl,
        child: IconButton(icon: const Icon(Icons.sort), onPressed: sort),
      ),
      Tooltip(
        message: "Downloading".tl,
        child: IconButton(
          icon: const Icon(Icons.download),
          onPressed: () {
            showPopUpWidget(context, const DownloadingPage());
          },
        ),
      ),
      MenuButton(
        entries: [
          MenuEntry(
            icon: Icons.file_download_outlined,
            text: "Import".tl,
            onClick: () {
              showDialog(
                barrierDismissible: false,
                context: context,
                builder: (context) => const ImportComicsWidget(),
              );
            },
          ),
          MenuEntry(
            icon: Icons.file_upload_outlined,
            text: "Export".tl,
            onClick: () {
              setState(() {
                multiSelectMode = true;
              });
            },
          ),
        ],
      ),
    ];

    var body = Scaffold(
      body: SmoothCustomScrollView(
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          if (!searchMode)
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Back".tl,
                child: IconButton(
                  onPressed: () {
                    if (multiSelectMode) {
                      exitSelectMode();
                    } else {
                      context.pop();
                    }
                  },
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.arrow_back),
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedItems.length.toString())
                  : Text("Local".tl),
              actions: multiSelectMode ? selectActions : normalActions,
            )
          else if (searchMode)
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Cancel".tl,
                child: IconButton(
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.close),
                  onPressed: () {
                    if (multiSelectMode) {
                      exitSelectMode();
                    } else {
                      setState(() {
                        searchMode = false;
                        keyword = "";
                        update();
                      });
                    }
                  },
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedItems.length.toString())
                  : AppSearchField(
                      autofocus: true,
                      height: AppSearchField.toolbarHeight,
                      onChanged: (v) {
                        keyword = v;
                        update();
                      },
                    ).paddingRight(8),
              actions: multiSelectMode ? selectActions : null,
            ),
          if (!searchMode && !multiSelectMode)
            SliverToBoxAdapter(
              child: Material(child: _buildKindSegments(context)),
            ),
          if (!searchMode && !multiSelectMode && _statusTabsVisible)
            SliverToBoxAdapter(
              child: Material(
                child: AppTabBar(
                  controller: _tabController,
                  tabs: [
                    Tab(text: "All".tl),
                    Tab(text: "Downloaded".tl),
                    Tab(text: "Downloading".tl),
                    Tab(text: "Not Downloaded".tl),
                  ],
                ),
              ),
            ),
          if (comics.isEmpty &&
              !searchMode &&
              !multiSelectMode &&
              (kindFilter == ComicCardKind.project ||
                  kindFilter == ComicCardKind.product))
            _buildEmptySegmentSliver(context)
          else
            SliverGridComics(
            comics: comics,
            enableHero: false,
            // 右上角分类小标签（素材 / 工程 / 成品），颜色在 [ComicTile] 里按文案区分。
            badgeBuilder: (c) => c is LocalComic ? _categoryLabel(c) : null,
            progressBuilder: (c) => _downloadProgress(c as LocalComic),
            missingBuilder: (c) {
              if (c is! LocalComic) return null;
              final n = MissingPages.missingCount(c.baseDir);
              return n > 0 ? n : null;
            },
            selections: selectedItems,
            onLongPressed: (c, heroID) {
              setState(() {
                multiSelectMode = true;
                selectedItems[c as LocalComic] = true;
              });
            },
            onTap: (c, heroID) {
              if (multiSelectMode) {
                toggleSelect(c as LocalComic);
              } else {
                // `c` is already a LocalComic from the list; re-querying via
                // find() returns null for a still-downloading comic that isn't
                // persisted yet, and the `!` would crash. Use it directly.
                var comic = c as LocalComic;
                if (BtProjectManager.isBtComic(comic.id)) {
                  // The "翻译工作室" tab is the studio's front door: an FT
                  // project opens in the read-only canvas, not in the reader.
                  // Reading it as a comic still works — the reader's BT branch
                  // re-renders from `inpainted/` + json — but the canvas is
                  // where the styles are inspectable.
                  context.to(() => TranslationStudioPage(comicId: comic.id));
                } else if (comic.status == LocalComicStatus.notDownloaded) {
                  _showNotDownloadedDialog(comic);
                } else {
                  // Unified entry: open the comic detail page (same as online
                  // comics). The detail page loads local data first so it opens
                  // instantly and can be read offline.
                  context.to(
                    () => ComicPage(id: comic.id, sourceKey: comic.sourceKey),
                  );
                }
              }
            },
            menuBuilder: (c) {
              final comic = c as LocalComic;
              final missing = MissingPages.missingCount(comic.baseDir);
              return [
                ..._downloadActions(comic),
                if (missing > 0) ...[
                  MenuEntry(
                    icon: Icons.auto_fix_high,
                    text: "Repair missing (@a)".tlParams({"a": missing}),
                    // 2026-10-16：与漫画详细页同款升级 —— 打开二级确认
                    // 弹窗按章节选择性修复（每章一个独立任务），不再一键
                    // 全本并成一个浓缩任务。
                    onClick: () {
                      final table = MissingPages.peek(comic.baseDir);
                      if (table == null || table.isEmpty) return;
                      showMissingRepairDialog(
                        context,
                        single: ComicMissingReport(
                          comic: comic,
                          table: table,
                        ),
                      );
                    },
                  ),
                  MenuEntry(
                    icon: Icons.list_alt,
                    text: "View missing pages".tl,
                    onClick: () => showMissingPagesDialog(context, comic),
                  ),
                ],
                MenuEntry(
                  icon: Icons.folder_open,
                  text: "Open Folder".tl,
                  onClick: () {
                    openComicFolder(c as LocalComic);
                  },
                ),
                MenuEntry(
                  icon: Icons.delete,
                  text: "Delete".tl,
                  onClick: () {
                    deleteComics([c as LocalComic]).then((value) {
                      if (value && multiSelectMode) {
                        exitSelectMode();
                      }
                    });
                  },
                ),
                ...exportActions([c as LocalComic]),
              ];
            },
          ),
        ],
      ),
    );

    return PopScope(
      canPop: !multiSelectMode && !searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (multiSelectMode) {
          exitSelectMode();
        } else if (searchMode) {
          setState(() {
            searchMode = false;
            keyword = "";
            update();
          });
        }
      },
      child: body,
    );
  }

  /// Pause / resume / cancel for a comic that has a live download task.
  /// Empty for everything else, so normal tiles are unaffected.
  List<MenuEntry> _downloadActions(LocalComic comic) {
    final t = _taskFor(comic);
    if (t == null) return const [];
    return [
      if (!t.isError && !t.isPaused)
        MenuEntry(
          icon: Icons.pause,
          text: "Pause".tl,
          onClick: () => LocalManager().pauseTask(t),
        )
      else
        MenuEntry(
          icon: t.isError ? Icons.refresh : Icons.play_arrow,
          text: t.isError ? "Retry".tl : "Resume".tl,
          onClick: () => LocalManager().resumeTask(t),
        ),
      MenuEntry(
        icon: Icons.close,
        text: "Cancel".tl,
        color: Colors.red,
        onClick: () => t.cancel(),
      ),
    ];
  }

  void _showNotDownloadedDialog(LocalComic comic) {
    final hasSource =
        comic.comicType != ComicType.local &&
        comic.comicType.comicSource != null;
    showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: "Comic Not Available".tl,
          content: Text(
            "This comic has not been downloaded yet. You can import local files or download it from the source."
                .tl,
          ).paddingHorizontal(16).paddingVertical(8),
          actions: [
            Button.text(
              onPressed: () {
                Navigator.pop(context);
                showDialog(
                  barrierDismissible: false,
                  context: this.context,
                  builder: (context) => const ImportComicsWidget(),
                );
              },
              child: Text("Import".tl),
            ),
            if (hasSource)
              Button.filled(
                onPressed: () {
                  Navigator.pop(context);
                  this.context.to(
                    () => ComicPage(id: comic.id, sourceKey: comic.sourceKey),
                  );
                },
                child: Text("Download".tl),
              ),
          ],
        );
      },
    );
  }

  Future<String?> _pickExportFolder() async {
    if (App.isAndroid) {
      return (await DirectoryPicker().pickDirectory())?.path;
    } else if (App.isIOS) {
      return await selectDirectoryIOS();
    } else {
      return await selectDirectory();
    }
  }

  String _exportTaskMessage(ExportTask task) {
    // Show the current phase so the dialog no longer reads "Exporting N/N"
    // frozen while packaging and writing to the destination run (#92).
    switch (task.phase) {
      case ExportPhase.packaging:
        return "Packaging".tl;
      case ExportPhase.writing:
        var pct = task.writeProgress;
        if (pct != null) {
          return "Writing to folder @p%".tlParams({
            'p': (pct * 100).clamp(0, 100).toStringAsFixed(0),
          });
        }
        return "Writing to folder".tl;
      case ExportPhase.preparing:
      case ExportPhase.processing:
        return "Exporting @done/@total".tlParams({
          'done': task.done,
          'total': task.total,
        });
    }
  }

  /// Picks a destination folder, then starts a background export task that
  /// writes each comic as one file into it (issue #54). A bound loading dialog
  /// shows progress and offers a "Background" button; the task keeps running
  /// in the background and is visible in the Tasks page.
  /// Asks whether to merge into a single .mangrove_comics bundle (default off),
  /// then starts the export. Per-comic files (default) keep the export
  /// resumable and importable from a folder.
  void _startMangroveExport(List<LocalComic> comics) async {
    if (comics.isEmpty) return;
    bool merge = false;
    var go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => ContentDialog(
          title: "Export .mangrove_comics".tl,
          content: SwitchListTile(
            title: Text("Merge into a single .mangrove_comics".tl),
            value: merge,
            onChanged: (v) => setLocal(() => merge = v),
          ),
          actions: [
            Button.text(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text("Cancel".tl),
            ),
            Button.filled(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text("Export".tl),
            ),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;
    var manager = ExportTaskManager.instance;
    if (manager.hasActiveTask) {
      context.showMessage(message: "An export task is already running".tl);
      return;
    }
    var folder = await _pickExportFolder();
    if (folder == null || !mounted) return;
    var task = manager.startExport(
      folderPath: folder,
      format: ExportFormat.mangroveComics,
      comics: comics,
      merged: merge,
    );
    if (task == null) return;
    _trackExportProgress(manager, task);
  }

  /// Default export root: the last folder the user picked, or — to keep all
  /// translation/export artefacts out of the pristine download folders —
  /// `<local library>/../translated/exports`, i.e. ComicLibrary/translated/
  /// exports when the library is ComicLibrary/downloads.
  String _suggestedExportFolder() {
    var remembered = appdata.settings['exportLastDirectory'];
    if (remembered is String && remembered.isNotEmpty) return remembered;
    return FilePath.join(
      Directory(LocalManager().path).parent.path,
      'translated',
      'exports',
    );
  }

  Future<({String folder, bool useTranslations})?> _showExportOptions(
    ExportFormat format,
    int comicCount,
  ) async {
    var useTranslations = false;
    var folder = _suggestedExportFolder();
    final formatLabel = switch (format) {
      ExportFormat.cbz => 'CBZ',
      ExportFormat.pdf => 'PDF',
      ExportFormat.epub => 'EPUB',
      ExportFormat.images => 'image folder',
      ExportFormat.mangroveComics => 'mangrove_comics',
    };
    return showDialog<({String folder, bool useTranslations})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => ContentDialog(
          title: "Export as @format".tlParams({'format': formatLabel}),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text("Render stored translations".tl),
                subtitle: Text(
                  "Pages with saved translations are exported with the translated artwork; every other page is copied unchanged."
                      .tl,
                ),
                value: useTranslations,
                onChanged: (v) => setLocal(() => useTranslations = v),
              ),
              const Divider(),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text("Destination folder".tl),
                subtitle: Text(
                  format.isDirectoryOutput
                      ? "${"Each comic becomes a subfolder inside".tl}:\n$folder"
                      : folder,
                ),
                trailing: Button.text(
                  onPressed: () async {
                    var picked = await _pickExportFolder();
                    if (picked != null) {
                      setLocal(() => folder = picked);
                    }
                  },
                  child: Text("Change".tl),
                ),
              ),
            ],
          ),
          actions: [
            Button.text(
              onPressed: () => Navigator.pop(ctx),
              child: Text("Cancel".tl),
            ),
            Button.filled(
              onPressed: () => Navigator.pop(ctx, (
                folder: folder,
                useTranslations: useTranslations,
              )),
              child: Text("Export @n comics".tlParams({'n': '$comicCount'})),
            ),
          ],
        ),
      ),
    );
  }

  void _startExportTask(List<LocalComic> comics, ExportFormat format) async {
    if (comics.isEmpty) return;
    var manager = ExportTaskManager.instance;
    if (manager.hasActiveTask) {
      context.showMessage(message: "An export task is already running".tl);
      return;
    }
    var options = await _showExportOptions(format, comics.length);
    if (options == null || !mounted) return;
    var folder = options.folder;
    try {
      Directory(folder).createSync(recursive: true);
    } catch (e) {
      if (mounted) {
        context.showMessage(message: "Cannot create folder: $e");
      }
      return;
    }
    appdata.settings['exportLastDirectory'] = folder;
    appdata.saveData();
    var task = manager.startExport(
      folderPath: folder,
      format: format,
      comics: comics,
      useTranslations: options.useTranslations,
    );
    if (task == null) return;
    _trackExportProgress(manager, task);
  }

  /// Binds the foreground loading dialog to a running [task] (shared by the
  /// regular export flow and the .mangrove_comics flow).
  void _trackExportProgress(ExportTaskManager manager, ExportTask task) {
    var controller = showLoadingDialog(
      context,
      withProgress: true,
      barrierDismissible: false,
      message: _exportTaskMessage(task),
      secondaryButtonText: "Background",
      onSecondary: () {
        // The task keeps running and lives on in the Tasks page; tell the user
        // where to find it since the dialog can't be re-summoned (#92).
        App.rootContext.showMessage(
          message: "Export moved to background; see the Tasks page".tl,
        );
      },
      cancelButtonText: "Cancel",
      onCancel: () => manager.cancel(task.id),
    );
    void listener() {
      if (controller.closed) {
        manager.removeListener(listener);
        return;
      }
      // Prefer real byte progress while writing to the destination; fall back
      // to the per-comic ratio for the earlier phases, and an indeterminate
      // bar while packaging in the isolate.
      double? barValue;
      if (task.phase == ExportPhase.writing) {
        barValue = task.writeProgress;
      } else if (task.phase == ExportPhase.packaging) {
        barValue = null;
      } else {
        barValue = task.total == 0 ? null : task.progress;
      }
      controller.setProgress(barValue);
      controller.setMessage(_exportTaskMessage(task));
      if (!task.isActive) {
        manager.removeListener(listener);
        controller.close();
        if (task.status == ExportTaskStatus.completed) {
          App.rootContext.showMessage(message: "Export completed".tl);
        } else if (task.status == ExportTaskStatus.failed) {
          App.rootContext.showMessage(
            message: (task.error ?? "Export failed").tl,
          );
        }
      }
    }

    manager.addListener(listener);
    listener();
  }

  /// Migrates the selected comics into the configured WebDAV comic library,
  /// re-laid-out so the WebDAV source can browse them (issue #149). The shared
  /// dialog filters to downloaded comics and starts the background task.
  void _startWebdavMigration(List<LocalComic> comics) async {
    final started = await startWebdavMigrationFlow(comics);
    if (started && mounted) {
      exitSelectMode();
    }
  }

  /// 删除选中的卡片（磁贴菜单与多选菜单共用的唯一入口）。
  ///
  /// 判据（"记录"在哪、"文件"在哪、"只删记录会不会自己回来"）全在
  /// `comic_deletion.dart`，弹窗在 `comic_delete_dialog.dart`。这里只做接线
  /// —— 三处各写一遍删除逻辑，就是 2026-10-09 那个「`ft_` 卡片说删了、目录还在」
  /// 的成因（旧实现一律 `join(library, c.directory)`，而工程/成品卡存的是绝对
  /// 路径）。
  Future<bool> deleteComics(List<LocalComic> comics) =>
      showComicDeleteDialog(context, comics);

  List<MenuEntry> exportActions(List<LocalComic> comics) {
    return [
      MenuEntry(
        icon: Icons.outbox_outlined,
        text: "Export as cbz".tl,
        onClick: () => _startExportTask(comics, ExportFormat.cbz),
      ),
      MenuEntry(
        icon: Icons.picture_as_pdf_outlined,
        text: "Export as pdf".tl,
        onClick: () => _startExportTask(comics, ExportFormat.pdf),
      ),
      MenuEntry(
        icon: Icons.import_contacts_outlined,
        text: "Export as epub".tl,
        onClick: () => _startExportTask(comics, ExportFormat.epub),
      ),
      MenuEntry(
        icon: Icons.folder_outlined,
        text: "Export as image folder".tl,
        onClick: () => _startExportTask(comics, ExportFormat.images),
      ),
    ];
  }
}

/// Opens the folder containing the comic in the system file explorer
///
/// 平台分支在 `foundation/open_folder.dart` 的 [openFolderPath] —— 那才是唯一
/// 一份；本文件与「创建成功」弹窗都朝它依赖（抽到任一侧都会成环，见那里的注释）。
Future<void> openComicFolder(LocalComic comic) => openFolderPath(comic.baseDir);
