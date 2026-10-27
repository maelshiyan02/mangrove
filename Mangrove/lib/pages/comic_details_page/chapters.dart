part of 'comic_page.dart';

class _ComicChapters extends StatelessWidget {
  const _ComicChapters({this.history, required this.groupedMode});

  final History? history;

  final bool groupedMode;

  @override
  Widget build(BuildContext context) {
    return groupedMode
        ? _GroupedComicChapters(history)
        : _NormalComicChapters(history);
  }
}

/// Shared multi-select state & actions for the chapters list.
///
/// Selection keys use the SAME string format the reader writes into
/// [History.readEpisode]: plain chapter index ("3") for normal comics, and
/// "group-chapter" ("2-5") for grouped comics. Keeping the format identical is
/// what makes a manual mark actually toggle the "visited" style.
mixin _ChapterSelectionMixin<T extends StatefulWidget> on State<T> {
  bool selectMode = false;

  /// Selected chapter keys (in reader format).
  final Set<String> selected = {};

  _ComicPageState get pageState;

  /// 覆盖层主键（域库 `comic_id`），模式开关/本地覆盖都挂在它上面。
  /// 普通视图与分组视图共用，所以放在 mixin 里；实现只有 [pageState] 一处。
  String get _overrideComicId => pageState.overrideComicId;

  /// 章节格子的**主标题**：记录表话号 > 标题/目录名里的话号。
  ///
  /// 为什么记录表能顶掉标题（P51，2026-10-27）：key 是**源站的**，改了它
  /// 断下载、断阅读进度、断翻译工程；但源站的话号又未必是读者认知的话号
  /// （UUID 当 id 的源、跨源补章坐标系不同、源侧把简介写进标题）。
  /// 所以让记录表单独说"这一章是第几话"，key 一个字节都不动 —— 这就是用户
  /// 要的"密码本"：两边的术语靠一张表对齐，文件与目录保持原样。
  String _chapterTitleOf(String key, String value) {
    final number = ComicOverrideStore.instance.chapterNumberOf(
      _overrideComicId,
      key,
    );
    if (number == null) return chapterNumberLabel(value);
    final text = number == number.roundToDouble()
        ? number.toInt().toString()
        : number.toString();
    return '第$text话';
  }

  History? get history;

  set history(History? value);

  /// All selectable chapter keys in the current context.
  /// Normal: every chapter. Grouped: only the current group's chapters.
  Set<String> get selectableKeys;

  void enterSelectMode() {
    setState(() {
      selectMode = true;
      selected.clear();
    });
  }

  void exitSelectMode() {
    setState(() {
      selectMode = false;
      selected.clear();
    });
  }

  void toggleSelect(String key) {
    setState(() {
      if (!selected.remove(key)) {
        selected.add(key);
      }
    });
  }

  void selectAll() {
    setState(() {
      selected.addAll(selectableKeys);
    });
  }

  void invertSelection() {
    setState(() {
      final keys = selectableKeys;
      final next = keys.where((k) => !selected.contains(k)).toSet();
      selected
        ..removeAll(keys)
        ..addAll(next);
    });
  }

  /// Apply read/unread to the current selection, persist, and refresh.
  void _applyMark(bool read) {
    if (selected.isEmpty) {
      exitSelectMode();
      return;
    }
    final current = Set<String>.from(history?.readEpisode ?? const <String>{});
    if (read) {
      current.addAll(selected);
    } else {
      current.removeAll(selected);
    }
    final updated = HistoryManager().updateReadEpisodes(
      pageState.comic,
      current,
    );
    pageState.history = updated;
    setState(() {
      history = updated;
      selectMode = false;
      selected.clear();
    });
  }

  /// The toolbar shown in place of the title row while selecting.
  Widget buildSelectionBar(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;
        return Row(
          children: [
            Tooltip(
              message: "Cancel".tl,
              child: IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: exitSelectMode,
              ),
            ),
            Expanded(
              child: Text(
                "Selected @count".tlParams({"count": selected.length}),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (compact)
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded),
                onSelected: (value) {
                  switch (value) {
                    case 'all':
                      selectAll();
                      break;
                    case 'invert':
                      invertSelection();
                      break;
                    case 'read':
                      _applyMark(true);
                      break;
                    case 'unread':
                      _applyMark(false);
                      break;
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(value: 'all', child: Text("Select All".tl)),
                  PopupMenuItem(
                    value: 'invert',
                    child: Text("Invert Selection".tl),
                  ),
                  PopupMenuItem(
                    value: 'read',
                    enabled: selected.isNotEmpty,
                    child: Text("Mark as read".tl),
                  ),
                  PopupMenuItem(
                    value: 'unread',
                    enabled: selected.isNotEmpty,
                    child: Text("Mark as unread".tl),
                  ),
                ],
              )
            else ...[
              Tooltip(
                message: "Select All".tl,
                child: IconButton(
                  icon: const Icon(Icons.select_all_rounded),
                  onPressed: selectAll,
                ),
              ),
              Tooltip(
                message: "Invert Selection".tl,
                child: IconButton(
                  icon: const Icon(Icons.flip_rounded),
                  onPressed: invertSelection,
                ),
              ),
              Tooltip(
                message: "Mark as read".tl,
                child: IconButton(
                  icon: const Icon(Icons.done_all_rounded),
                  onPressed: selected.isEmpty ? null : () => _applyMark(true),
                ),
              ),
              Tooltip(
                message: "Mark as unread".tl,
                child: IconButton(
                  icon: const Icon(Icons.remove_done_rounded),
                  onPressed: selected.isEmpty ? null : () => _applyMark(false),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// The trailing controls of the title row when NOT selecting.
  Widget buildNormalTitle(
    BuildContext context, {
    required bool reverse,
    required VoidCallback onToggleOrder,
    required VoidCallback onCustomizeOrder,
  }) {
    return _ComicSectionHeader(
      icon: Icons.view_list_rounded,
      title: "Chapters".tl,
      horizontalPadding: 0,
      // The list on screen came from cache/local data while the real request
      // is still running; make the ongoing refresh visible.
      titleBadge: pageState.isDetailsLoading
          ? const _ChaptersUpdatingIndicator()
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // P8（2026-10-23）：本地漫画的章节标题行**常驻**「添加章节」「刷新章节」入口。
          // 之前只在 `chapters==null`（空漫画）时由 buildChapters 的空状态引导
          // 提供该按钮；一旦加了章节，常规章节列表里就再没有任何「添加章节」
          // 入口，用户无法继续加章。这里挂在标题行 trailing，空/非空都可见，
          // 且只对本地漫画显示（网络漫画的章节来自源站，不在此处添加）。
          //
          // 🔴 P6：**成品（`ft_`）不给这两个按钮** —— 成品是导出结果，往它的目录里
          // 加章/刷新加章，下次导出同一本就会被覆盖（用户加的章无声消失）。成品该有的
          // 是「只读」提示，而不是编辑入口。
          //
          // 🔴 **用 `_localComic` 而非 `comic as LocalComic`**：`pageState.comic` 是
          // `ComicDetails`（详情页统一数据形态），而 `LocalComic` 并不继承
          // `ComicDetails`，强转会抛 CastError —— 这正是「添加章节按钮点了没反应」
          // 的根因（详情页加载后 `data` 是 ComicDetails，空状态那次能用是因为
          // 它走的是单独的 `_localComic`）。
          if (pageState._localComic != null && !pageState._isProduct) ...[
            Tooltip(
              message: "添加章节".tl,
              child: IconButton(
                icon: const Icon(Icons.add),
                onPressed: () async {
                  final updated = await showAddChapterDialog(
                    context,
                    pageState._localComic!,
                  );
                  if (updated != null) pageState.update();
                },
              ),
            ),
            Tooltip(
              message: "刷新章节".tl,
              child: IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => _refreshChapters(context),
              ),
            ),
          ],
          Tooltip(
            message: "Batch manage".tl,
            child: IconButton(
              icon: const Icon(Icons.checklist_rounded),
              onPressed: enterSelectMode,
            ),
          ),
          Tooltip(
            message: "Order".tl,
            child: IconButton(
              icon: Icon(
                reverse
                    ? Icons.arrow_upward_rounded
                    : Icons.arrow_downward_rounded,
              ),
              onPressed: onToggleOrder,
            ),
          ),
          Tooltip(
            message: "Customize chapter order".tl,
            child: IconButton(
              icon: const Icon(Icons.reorder_rounded),
              onPressed: onCustomizeOrder,
            ),
          ),
        ],
      ),
    );
  }

  /// 刷新章节：扫描漫画根目录下的子文件夹，把"磁盘上有、矩阵里没有"的章节补登。
  ///
  /// 主要用于支持"用户事先手动把文件夹复制进漫画目录"的场景 —— 点一下就能识别
  /// 新增章，不必走「添加章节」重新挑文件夹。去重以**目录名**为准（规范名 + 原始
  /// key 名都排除），重复点不会重复建章；且**绝不删除任何文件/目录**，只注册。
  Future<void> _refreshChapters(BuildContext context) async {
    final comic = pageState._localComic;
    if (comic == null) return;
    final controller = showLoadingDialog(
      context,
      message: "刷新章节…".tl,
      barrierDismissible: false,
    );
    final added = await refreshLocalComicChapters(comic);
    controller.close();
    if (!mounted) return;
    if (added > 0) {
      pageState.update();
      context.showMessage(
        message: "新增 @n 个章节".tlParams({'n': added}),
      );
    } else {
      context.showMessage(message: "没有新增章节".tl);
    }
  }
}

class _NormalComicChapters extends StatefulWidget {
  const _NormalComicChapters(this.history);

  final History? history;

  @override
  State<_NormalComicChapters> createState() => _NormalComicChaptersState();
}

class _NormalComicChaptersState extends State<_NormalComicChapters>
    with _ChapterSelectionMixin {
  late _ComicPageState state;

  late bool reverse;

  bool showAll = false;

  History? _history;

  late ComicChapters chapters;

  /// Currently selected scanlation group for versioned chapters.
  /// Null = show all (default newest version per chapter).
  ///
  /// P17：扁平本地漫画也复用它做**显示筛选**。区别在于版本化章节是真的换
  /// `_displayChapters`（组就是版本），而扁平章节只在 [visible] 里过滤
  /// index——绝不能重建 `ComicChapters`，否则下标重排，"已读"标记和
  /// `read(i+1)` 全部错位到别的章节上。
  String? _selectedScanlationGroup;

  @override
  _ComicPageState get pageState => state;

  @override
  History? get history => _history;

  @override
  set history(History? value) => _history = value;

  /// Effective chapters object, possibly filtered by scanlation group.
  late ComicChapters _displayChapters;

  void _computeDisplayChapters() {
    if (!chapters.isVersioned) {
      _displayChapters = chapters;
      return;
    }
    final filtered = chapters.filterForScanlationGroup(
      _selectedScanlationGroup,
    );
    _displayChapters = filtered ?? chapters;
    // If the selected group yielded no results, fall back to showing all.
    if (filtered == null && _selectedScanlationGroup != null) {
      _selectedScanlationGroup = null;
    }
  }

  /// 扁平本地漫画的翻译组名（P17，2026-10-24）。
  ///
  /// 本地漫画的组名只存在于目录名里（`6 [Asura Scans] [comix.to]`），没有
  /// 版本矩阵可问。这里扫一遍全部章节键取出组名，按登场次数降序（主组在
  /// 前）、同次数按名字排，结果只用于 chips 与格子小字，**不参与任何 key
  /// 或路径计算**。版本化/分组章节返回空表——它们有自己的组来源。
  List<String> get _localGroups =>
      _localGroupsCache ??= _computeLocalGroups();

  List<String>? _localGroupsCache;

  List<String> _computeLocalGroups() {
    if (chapters.isVersioned || chapters.isGrouped) return const [];
    final counts = <String, int>{};
    for (final key in chapters.allChapters.keys) {
      final ref = parseChapterDirectoryName(key);
      if (ref == null || ref.groups.isEmpty) continue;
      final label = ref.groups.join(' ');
      counts[label] = (counts[label] ?? 0) + 1;
    }
    if (counts.isEmpty) return const [];
    final names = counts.keys.toList()
      ..sort((a, b) {
        final cmp = counts[b]!.compareTo(counts[a]!);
        return cmp != 0 ? cmp : a.compareTo(b);
      });
    return names;
  }

  /// 章节键属于哪个翻译组；读不出来返回 null。
  String? _groupOfKey(String key) {
    final ref = parseChapterDirectoryName(key);
    if (ref == null || ref.groups.isEmpty) return null;
    return ref.groups.join(' ');
  }

  /// Original flat indices actually rendered, in list order. Hiding duplicates
  /// only removes entries here — the indices themselves keep their original
  /// values, because [_ComicPageActions.read] and the download picker address
  /// chapters by flat index.
  late List<int> visible;

  @override
  Set<String> get selectableKeys =>
      visible.map((i) => (i + 1).toString()).toSet();

  /// 章节格子的翻译组小字（P16）。取不到返回 null，整块不渲染。
  ///
  /// 版本化章节直接问版本矩阵；扁平本地漫画的组名藏在目录名里
  /// （`6 [DivaScans] [comix.to]`），只能从 key 反解。注意用**原始**
  /// [chapters] 而不是 [_displayChapters] 算判别集合——一旦按组筛选，
  /// _displayChapters 里只剩一个组，就再也看不出"这号有两个组"了。
  String? _chapterGroupLabel(int i, String key) {
    // 人工/脚本写死的展示标签优先级最高（`英文 · Asura Scans · comix.to`）。
    //
    // 为什么需要它：扁平章节的 key 只是一个数字（`"152"`），组名和站点只
    // 存在于目录名里，而扁平 map 没有 scanlationGroup，`chapterDirectoryName`
    // 反算出来还是光秃秃的数字 —— 跨源补进来的话就永远显示不出"谁翻的、
    // 从哪来的"。目录名靠不住时，就让记录表直接说。
    final explicit = ComicOverrideStore.instance.chapterLabelOf(
      _overrideComicId,
      key,
    );
    if (explicit != null) return explicit;
    // P49：语种是分类第一维，先出「简中」再出组名。
    // `[zh-Hans] 120 [Rokari Comics] [comix.to]` → `简中 · Rokari Comics`
    //
    // P50：语种**两个落点**，记录表优先。目录名是约定不是所有权 —— 有些源
    // （或其镜像）的目录不归我们改（改名断翻译工程、断别的设备的认知，
    // 下次下载还会被源侧覆盖回来），那种情况下语言只能标在这本漫画自己的
    // 记录里。顺序：`chapter_languages` 覆盖 > 目录名 `[lang]` 段。
    final lang = chapterLanguageLabel(
      ComicOverrideStore.instance.chapterLanguageOf(_overrideComicId, key) ??
          parseChapterDirectoryName(key)?.language,
    );
    final langPrefix = lang.isEmpty ? '' : lang;
    if (_displayChapters.isVersioned) {
      final group = _displayChapters.scanlationGroupAt(i);
      if (group != null && group.isNotEmpty) {
        return langPrefix.isEmpty ? group : '$langPrefix · $group';
      }
    }
    final ref = parseChapterDirectoryName(key);
    if (ref == null) return langPrefix.isEmpty ? null : langPrefix;
    // P17：扁平本地漫画的组名**一律显示**。旧实现只在一话多组时才给，导致
    // 单组的那几本（Lua Comic / Violet Scans / HiveToons）整页看不到"谁翻的"。
    // 组名是分类标识，只占 10px 一行，比"读者猜是哪来的"划算。
    if (ref.groups.isEmpty) return langPrefix.isEmpty ? null : langPrefix;
    final group = ref.groups.join(' ');
    return langPrefix.isEmpty ? group : '$langPrefix · $group';
  }

  void _computeVisible() {
    _localGroupsCache = null;
    _computeDisplayChapters();
    // duplicateChapterIndices are flat indices into the FULL chapters list.
    // When a scanlation-group filter is active, _displayChapters is a
    // different (filtered) list whose indices don't line up — applying the
    // full-list indices there would wrongly hide unrelated chapters. Skip
    // duplicate-hiding while filtered; a single group has no versions to
    // collapse anyway.
    final hidden =
        (_selectedScanlationGroup == null && state.hideDuplicateChapters)
        ? state.duplicateChapterIndices
        : const <int>{};
    final ordered = ChapterOrderPrefs.orderedIndices(
      _displayChapters,
      state.comic.id,
      state.comic.sourceKey,
    );
    // 「本地显示模式」（P-DL6）：隐藏未下载的白色章节，蓝(已下载)/
    // 黄(下载中)/红(问题)/浅绿(待命)全部保留。状态判定与配色共用
    // [chapterDownloadStatusFor]；下载任务完成时 LocalManager 通知刷新，
    // 本章会自动从过滤列表里"长"回来，列表不焊死。
    // 🔴 P11（2026-10-24）：模式从全局开关升级为**每本漫画独立**，未设置过
    // 的本子回落到全局默认值（`ComicOverrideStore.defaultDisplayMode`）。
    final localMode =
        ComicOverrideStore.instance.displayModeFor(_overrideComicId) ==
        ComicDisplayMode.local;
    // P17：扁平本地漫画的组筛选只作用在 [visible] 上（不重建 chapters，
    // 保住 index 语义）。版本化章节的组筛选已经在 _computeDisplayChapters
    // 里做完了，这里传 null 即不过滤。
    final groupFilter = chapters.isVersioned ? null : _selectedScanlationGroup;
    visible = [
      for (final i in ordered)
        if (!hidden.contains(i) &&
            (groupFilter == null ||
                _groupOfKey(_displayChapters.ids.elementAt(i)) ==
                    groupFilter) &&
            !(localMode &&
                chapterDownloadStatusFor(
                      comicId: state.comic.id,
                      comicType: state.comic.comicType,
                      chapters: state.comic.chapters,
                      chapterKey: _displayChapters.ids.elementAt(i),
                    ) ==
                    ChapterDownloadStatus.notDownloaded))
          i,
    ];
    // 组筛选把列表筛空了（目录名被手工改过、那组已不存在）→ 退回"全部"，
    // 而不是给用户一片空白。清空后 groupFilter 变 null，不会无限递归。
    if (visible.isEmpty && groupFilter != null) {
      _selectedScanlationGroup = null;
      _computeVisible();
    }
  }

  /// 章节标签四态配色（#P5/S3-a，2026-10-05 用户确认）。
  /// 状态判定在顶层 [chapterChipColorFor]——普通视图与分组视图是两个
  /// State 类，共用逻辑必须放在类外。
  _ChapterChipColors _chapterChipColor(String chapterKey, bool isSelected) {
    if (isSelected) {
      return _ChapterChipColors(
        context.colorScheme.primaryContainer,
        context.colorScheme.onPrimaryContainer,
      );
    }
    return chapterChipColorFor(context, state.comic, chapterKey);
  }

  Future<void> _customizeOrder() async {
    final changed = await showChapterOrderEditor(
      context: context,
      chapters: chapters,
      comicId: state.comic.id,
      sourceKey: state.comic.sourceKey,
    );
    if (changed == true && mounted) {
      setState(_computeVisible);
      state.update();
    }
  }

  @override
  void initState() {
    super.initState();
    reverse = appdata.settings["reverseChapterOrder"] ?? false;
    _history = widget.history;
    // 下载完成/出错会通知 LocalManager，驱动章节标签颜色实时刷新
    // （黄→蓝、或写入缺失页表后变红），无需重建页面 (#P5/S3-a)。
    LocalManager().addListener(_onLocalChange);
  }

  void _onLocalChange() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    state = context.findAncestorStateOfType<_ComicPageState>()!;
    chapters = state.comic.chapters!;
    _computeVisible();
    super.didChangeDependencies();
  }

  @override
  void didUpdateWidget(covariant _NormalComicChapters oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A background details refresh can replace the chapter map while this
    // widget stays mounted (cache-first load). Freeze it during multi-select:
    // selection keys are chapter indices, so a list that grows or reorders
    // mid-selection would shift them under the user. Re-read once selection
    // ends; picked up on the next rebuild.
    if (!selectMode) {
      setState(() {
        chapters = state.comic.chapters!;
        _computeVisible();
        _history = widget.history;
      });
    }
  }

  @override
  void dispose() {
    LocalManager().removeListener(_onLocalChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The duplicate switch is toggled from the page menu, which only calls
    // update() on the page state — recompute here so the change lands without
    // waiting for a details refresh.
    _computeVisible();
    return SliverLayoutBuilder(
      builder: (context, constrains) {
        int length = visible.length;
        bool canShowAll = showAll || selectMode;
        if (!canShowAll) {
          var width = constrains.crossAxisExtent - 16;
          var crossItems = width ~/ 200;
          if (width % 200 != 0) {
            crossItems += 1;
          }
          length = math.min(length, crossItems * 8);
          if (length == visible.length) {
            canShowAll = true;
          }
        }

        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: selectMode
                  ? buildSelectionBar(context).paddingHorizontal(8)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        buildNormalTitle(
                          context,
                          reverse: reverse,
                          onToggleOrder: () =>
                              setState(() => reverse = !reverse),
                          onCustomizeOrder: _customizeOrder,
                        ),
                        // Chip visibility must be decided by the ORIGINAL
                        // chapters object, never by _displayChapters: once a
                        // group filter is applied, _displayChapters contains a
                        // single group (length == 1), which hid the whole chip
                        // row and left no way to unselect the filter.
                        //
                        // P17：条件从"2 组以上"放宽到"有组名就显示"，且来源
                        // 不再只认版本化章节——本地漫画的组名藏在目录名里。
                        // 单组时渲染只读标签（以前整行都不出现，读者看不到这本
                        // 是谁翻的）。
                        if (_displayGroupNames.isNotEmpty)
                          _buildScanlationGroupChips(context),
                      ],
                    ),
            ),
            SliverGrid(
              delegate: SliverChildBuilderDelegate(childCount: length, (
                context,
                slot,
              ) {
                if (reverse) {
                  slot = visible.length - slot - 1;
                }
                // Display slot -> original flat index. Every consumer downstream
                // (read(), history keys, download) addresses chapters by that
                // index, so hiding must never renumber them.
                var i = visible[slot];
                var key = _displayChapters.ids.elementAt(i);
                var value = _displayChapters[key]!;
                var epKey = (i + 1).toString();
                bool visited = (_history?.readEpisode ?? const {}).contains(
                  epKey,
                );
                bool isSelected = selected.contains(epKey);
                final chipColor = _chapterChipColor(key, isSelected);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                  child: Material(
                    color: chipColor.color,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      onTap: () => selectMode
                          ? toggleSelect(epKey)
                          : state.read(i + 1, null, null, _displayChapters),
                      onLongPress: selectMode
                          ? null
                          : () {
                              enterSelectMode();
                              toggleSelect(epKey);
                            },
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _chapterTitleOf(key, value),
                                maxLines: 1,
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isSelected
                                      ? context.colorScheme.onPrimaryContainer
                                      : chipColor.textColor ??
                                            (visited
                                                ? context.colorScheme.outline
                                                : null),
                                ),
                              ),
                              if (_chapterGroupLabel(i, key) case final label?)
                                Text(
                                  label,
                                  maxLines: 1,
                                  textAlign: TextAlign.center,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: isSelected
                                        ? context.colorScheme.onPrimaryContainer
                                        : context.colorScheme.outline,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
              gridDelegate: const SliverGridDelegateWithFixedHeight(
                maxCrossAxisExtent: 220,
                itemHeight: 44,
              ),
            ).sliverPadding(EdgeInsets.zero),
            if (!canShowAll)
              SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.center,
                  child: TextButton.icon(
                    icon: const Icon(Icons.arrow_drop_down),
                    onPressed: () {
                      setState(() {
                        showAll = true;
                      });
                    },
                    label: Text("${"Show all".tl} (${visible.length})"),
                  ).paddingTop(12),
                ),
              ),
            const SliverPadding(padding: EdgeInsets.only(bottom: 12)),
          ],
        );
      },
    );
  }

  /// 章节区要显示的翻译组名：版本化章节问版本矩阵，扁平本地漫画问目录名。
  List<String> get _displayGroupNames =>
      chapters.isVersioned ? chapters.scanlationGroupsSorted : _localGroups;

  /// Scrollable row of filter chips for selecting a scanlation group.
  ///
  /// 多组：`全部` + 每个组，点选筛选（P17 补上"全部"，以前只能再点一次
  /// 已选中的 chip 来取消，用户不知道能这么退出筛选）。
  /// 单组：只渲染一个只读标签——组信息必须可见（否则本地漫画看不出是哪个
  /// 组翻的），但没有可切换的对象，给可点的 FilterChip 只会让人以为点了没反应。
  Widget _buildScanlationGroupChips(BuildContext context) {
    final groups = _displayGroupNames;
    final selected = _selectedScanlationGroup;
    if (groups.length == 1) {
      return Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.centerLeft,
        child: Chip(
          label: Text('${"翻译组".tl}：${groups.first}'),
          visualDensity: VisualDensity.compact,
          backgroundColor: Colors.transparent,
          side: BorderSide(color: context.colorScheme.outlineVariant),
        ),
      );
    }
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: groups.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          if (index == 0) {
            return FilterChip(
              label: Text("全部".tl),
              selected: selected == null,
              showCheckmark: false,
              onSelected: (_) {
                setState(() {
                  _selectedScanlationGroup = null;
                  _computeVisible();
                });
              },
            );
          }
          final group = groups[index - 1];
          final isSelected = group == selected;
          return FilterChip(
            label: Text(group),
            selected: isSelected,
            showCheckmark: false,
            onSelected: (_) {
              setState(() {
                _selectedScanlationGroup = isSelected ? null : group;
                _computeVisible();
              });
            },
          );
        },
      ),
    );
  }
}

class _GroupedComicChapters extends StatefulWidget {
  const _GroupedComicChapters(this.history);

  final History? history;

  @override
  State<_GroupedComicChapters> createState() => _GroupedComicChaptersState();
}

class _GroupedComicChaptersState extends State<_GroupedComicChapters>
    with SingleTickerProviderStateMixin, _ChapterSelectionMixin {
  late _ComicPageState state;

  late bool reverse;

  bool showAll = false;

  History? _history;

  late ComicChapters chapters;

  late TabController tabController;

  bool _hasTabController = false;

  late int index;

  /// 章节标签四态配色，与普通视图共用 [chapterChipColorFor]。
  _ChapterChipColors _chapterChipColor(String chapterKey, bool isSelected) {
    if (isSelected) {
      return _ChapterChipColors(
        context.colorScheme.primaryContainer,
        context.colorScheme.onPrimaryContainer,
      );
    }
    return chapterChipColorFor(context, state.comic, chapterKey);
  }

  @override
  _ComicPageState get pageState => state;

  @override
  History? get history => _history;

  @override
  set history(History? value) => _history = value;

  /// The collection this comic is, or null for an ordinary grouped comic. When
  /// set, each tab corresponds to one member, so tabs become editable.
  String? get _collectionId =>
      ComicCollectionStore.isCollectionSourceKey(state.comic.sourceKey)
      ? state.comic.id
      : null;

  /// Long-press / right-click actions for a collection's tab: rename the member
  /// or move it, since tab order is chapter order.
  void _showTabActions(int tabIndex) {
    final id = _collectionId;
    if (id == null) return;
    final collection = ComicCollectionStore.find(id);
    final member = collection?.members.elementAtOrNull(tabIndex);
    if (collection == null || member == null) return;
    final count = collection.members.length;

    showMenuX(context, Offset(context.width / 2, context.padding.top + 120), [
      MenuEntry(
        icon: Icons.label_outline,
        text: "Display name".tl,
        onClick: () {
          showInputDialog(
            context: App.rootContext,
            title: "Display name".tl,
            initialValue: member.displayName,
            hintText: "Leave empty to use the comic's title".tl,
            onConfirm: (value) {
              member.displayName = value;
              ComicCollectionStore.update(id, members: collection.members);
              _applyCollectionEdit();
              return null;
            },
          );
        },
      ),
      if (tabIndex > 0)
        MenuEntry(
          icon: Icons.arrow_back,
          text: "Move left".tl,
          onClick: () {
            ComicCollectionStore.reorderMember(id, tabIndex, tabIndex - 1);
            _applyCollectionEdit();
          },
        ),
      if (tabIndex < count - 1)
        MenuEntry(
          icon: Icons.arrow_forward,
          text: "Move right".tl,
          onClick: () {
            ComicCollectionStore.reorderMember(id, tabIndex, tabIndex + 1);
            _applyCollectionEdit();
          },
        ),
      MenuEntry(
        icon: Icons.remove_circle_outline,
        text: "Remove from collection".tl,
        color: context.colorScheme.error,
        onClick: () {
          ComicCollectionStore.removeMember(
            id,
            member.sourceKey,
            member.comicId,
          );
          _applyCollectionEdit();
        },
      ),
    ]);
  }

  /// Rebuilds the collection's source and reloads the detail, so the new tab
  /// name or order shows immediately. The source captures the chapter layout,
  /// so skipping the refresh would keep serving the old one.
  void _applyCollectionEdit() {
    ComicSourceManager().refreshCollectionSources();
    state.reloadDetails();
  }

  /// 当前 tab 对应的本地漫画（合集成员）。非合集、或该成员不是本地漫画时
  /// 返回 null —— 网络成员没有 LocalComic 行，也就没有"已下载版本"可问。
  LocalComic? get _memberLocalComic {
    final id = _collectionId;
    if (id == null) return null;
    final member = ComicCollectionStore.find(id)?.members.elementAtOrNull(
      index,
    );
    if (member == null) return null;
    final type = ComicType.fromKey(member.sourceKey);
    if (type != ComicType.local) return null;
    return LocalManager().find(member.comicId, ComicType.local);
  }

  /// 组内第 [i] 个章节（0-based）的翻译组名，取不到返回 null。
  String? _groupLabelAt(int i) {
    if (chapters.isVersioned) {
      final group = chapters.scanlationGroupAt(i);
      if (group != null) return group;
    }
    final fromCollection = _memberLocalComic?.groupAt(i + 1);
    if (fromCollection != null) return fromCollection;
    // 扁平本地漫画（磁盘目录就是章节）：组名藏在目录名里
    // （`6 [DivaScans] [comix.to]`）。但整本同一个组时不显示——
    // 50 章全挂一行 "Rokari Comics" 是纯噪音，读者从话号就能认出是第几话。
    // 只有「同一话号真的存在多个组」时，组名才有区分价值（MDGH 的第 6 话
    // 既有 Asura 又有 Diva，不标出来就是两个一模一样的「第6话」）。
    if (index >= chapters.groupCount) return null;
    final keys = chapters.getGroupByIndex(index).keys;
    if (i >= keys.length) return null;
    final ref = parseChapterDirectoryName(keys.elementAt(i));
    if (ref == null || ref.groups.isEmpty) return null;
    final label = ref.groups.join(' ');
    return _ambiguousGroups.contains(label) ? label : null;
  }

  /// 全书「同一话号存在多个翻译组」时，涉及的组名集合。
  ///
  /// 只用来决定次要标签要不要出现，不参与任何 key / 路径计算。
  /// 缓存一次，`_computeVisible()` 每次重算前清掉（下载新章后可能新增重复话号）。
  Set<String>? _ambiguousCache;

  Set<String> get _ambiguousGroups =>
      _ambiguousCache ??= _computeAmbiguousGroups();

  Set<String> _computeAmbiguousGroups() {
    final byNumber = <String, Set<String>>{};
    for (final key in chapters.allVersionKeys) {
      final ref = parseChapterDirectoryName(key);
      if (ref == null || ref.groups.isEmpty) continue;
      byNumber.putIfAbsent(ref.number, () => <String>{}).add(
        ref.groups.join(' '),
      );
    }
    final ambiguous = <String>{};
    for (final groups in byNumber.values) {
      if (groups.length > 1) ambiguous.addAll(groups);
    }
    return ambiguous;
  }

  /// 0-based flat index of the first chapter in the current group.
  int get _groupOffset {
    var offset = 0;
    for (var j = 0; j < index; j++) {
      offset += chapters.getGroupByIndex(j).length;
    }
    return offset;
  }

  /// Indices WITHIN the current group that are actually rendered, in list order.
  /// Hiding duplicates only removes entries; the values keep their original
  /// within-group position, which is what the reader/history keys are built from.
  late List<int> visible;

  /// Within-group indices to hide for the current tab. Duplicates are detected
  /// per group, so a title repeated across tabs ("英文版"/"西班牙语" both having
  /// "第一话") is never touched.
  void _computeVisible() {
    _ambiguousCache = null;
    if (chapters.groupCount == 0) {
      visible = const [];
      return;
    }
    final hidden = state.hideDuplicateChapters
        ? state.duplicateChapterIndices
        : const <int>{};
    final offset = _groupOffset;
    final ordered = ChapterOrderPrefs.orderedIndicesForGroup(
      chapters,
      state.comic.id,
      state.comic.sourceKey,
      index,
    );
    // 「本地显示模式」（P-DL6）：与普通视图同规则，隐藏未下载的白色章节。
    // chapterKey 取当前组的源章节 id（与下方渲染一致）。
    // P11：模式改为每本独立，分组视图与普通视图共用同一个 `_overrideComicId`。
    final localMode =
        ComicOverrideStore.instance.displayModeFor(_overrideComicId) ==
        ComicDisplayMode.local;
    final groupKeys = chapters.getGroupByIndex(index).keys;
    visible = [
      for (final i in ordered)
        if (!hidden.contains(offset + i) &&
            !(localMode &&
                chapterDownloadStatusFor(
                      comicId: state.comic.id,
                      comicType: state.comic.comicType,
                      chapters: chapters,
                      chapterKey: groupKeys.elementAt(i),
                    ) ==
                    ChapterDownloadStatus.notDownloaded))
          i,
    ];
  }

  Future<void> _customizeOrder() async {
    final changed = await showChapterOrderEditor(
      context: context,
      chapters: chapters,
      comicId: state.comic.id,
      sourceKey: state.comic.sourceKey,
      initialGroupIndex: index,
    );
    if (changed == true && mounted) {
      setState(_computeVisible);
      state.update();
    }
  }

  /// Selectable keys = ONLY the current group's visible chapters, in reader
  /// format "group-chapter" (both 1-based).
  @override
  Set<String> get selectableKeys =>
      visible.map((i) => "${index + 1}-${i + 1}").toSet();

  @override
  void initState() {
    super.initState();
    reverse = appdata.settings["reverseChapterOrder"] ?? false;
    _history = widget.history;
    if (_history?.group != null) {
      index = _history!.group! - 1;
    } else {
      index = 0;
    }
    // 与 _NormalComicChaptersState 同理：下载完成/出错时刷新章节标签配色。
    LocalManager().addListener(_onLocalChange);
  }

  void _onLocalChange() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    state = context.findAncestorStateOfType<_ComicPageState>()!;
    chapters = state.comic.chapters!;
    _syncTabController();
    _computeVisible();
    super.didChangeDependencies();
  }

  void _syncTabController() {
    final length = chapters.groupCount;
    if (length == 0) {
      return;
    }
    index = math.min(math.max(index, 0), length - 1);
    if (_hasTabController && tabController.length == length) {
      return;
    }
    if (_hasTabController) {
      tabController.removeListener(onTabChange);
      tabController.dispose();
    }
    tabController = TabController(
      initialIndex: index,
      length: length,
      vsync: this,
    );
    tabController.addListener(onTabChange);
    _hasTabController = true;
  }

  void onTabChange() {
    if (index != tabController.index) {
      setState(() {
        index = tabController.index;
        showAll = false;
        // Duplicates are scoped per group, so the visible set is per tab.
        _computeVisible();
        // Selection is scoped to a group; leaving the group clears it.
        selected.clear();
      });
    }
  }

  @override
  void didUpdateWidget(covariant _GroupedComicChapters oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The chapter map is re-read on every rebuild, not just captured on first
    // mount: renaming/reordering a collection's members, or a background
    // details refresh adding chapters/tabs, reloads the detail in place, and a
    // captured map would keep showing the previous tabs until the page was left
    // and re-entered. Frozen during multi-select: selection keys are
    // group-chapter indices, so a list that grows or reorders mid-selection
    // would shift them under the user.
    if (!selectMode) {
      chapters = state.comic.chapters!;
      _syncTabController();
      _computeVisible();
      setState(() {
        _history = widget.history;
      });
    }
  }

  @override
  void dispose() {
    LocalManager().removeListener(_onLocalChange);
    if (_hasTabController) {
      tabController.removeListener(onTabChange);
      tabController.dispose();
    }
    super.dispose();
  }

  /// In grouped mode the reader historically may have stored a chapter either
  /// as "group-chapter" (current format) or as a flat "rawIndex" (legacy /
  /// [chapters.dart] visited check tolerates both). When marking read we add
  /// the canonical "group-chapter" key; when marking unread we must also strip
  /// the matching flat key so the chapter doesn't stay greyed out.
  @override
  void _applyMark(bool read) {
    if (selected.isEmpty) {
      exitSelectMode();
      return;
    }
    final current = Set<String>.from(history?.readEpisode ?? const <String>{});
    final offset = _groupOffset;
    for (final groupedKey in selected) {
      // groupedKey == "${index+1}-${i+1}"; derive the flat 1-based index.
      final dashAt = groupedKey.indexOf('-');
      final within = int.tryParse(groupedKey.substring(dashAt + 1)) ?? 0;
      final rawKey = (offset + within).toString();
      if (read) {
        current.add(groupedKey);
      } else {
        current
          ..remove(groupedKey)
          ..remove(rawKey);
      }
    }
    final updated = HistoryManager().updateReadEpisodes(
      pageState.comic,
      current,
    );
    pageState.history = updated;
    setState(() {
      history = updated;
      selectMode = false;
      selected.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (chapters.groupCount == 0 || !_hasTabController) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    // The duplicate switch is toggled from the page menu, which only calls
    // update() on the page state — recompute here so the change lands without
    // waiting for a details refresh.
    _computeVisible();
    return SliverLayoutBuilder(
      builder: (context, constrains) {
        var group = chapters.getGroupByIndex(index);
        int length = visible.length;
        bool canShowAll = showAll || selectMode;
        if (!canShowAll) {
          var width = constrains.crossAxisExtent - 16;
          var crossItems = width ~/ 200;
          if (width % 200 != 0) {
            crossItems += 1;
          }
          length = math.min(length, crossItems * 8);
          if (length == visible.length) {
            canShowAll = true;
          }
        }

        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: selectMode
                  ? buildSelectionBar(context).paddingHorizontal(8)
                  : buildNormalTitle(
                      context,
                      reverse: reverse,
                      onToggleOrder: () => setState(() => reverse = !reverse),
                      onCustomizeOrder: _customizeOrder,
                    ),
            ),
            SliverToBoxAdapter(
              child: AppTabBar(
                withUnderLine: false,
                controller: tabController,
                tabs: [
                  for (var i = 0; i < chapters.groups.length; i++)
                    Tab(
                      child: _collectionId == null
                          ? Text(chapters.groups.elementAt(i))
                          // For a collection each tab IS a member comic, so the
                          // tab is where renaming and reordering it belongs.
                          : GestureDetector(
                              onLongPress: () => _showTabActions(i),
                              onSecondaryTapDown: (_) => _showTabActions(i),
                              child: Text(chapters.groups.elementAt(i)),
                            ),
                    ),
                ],
              ),
            ),
            SliverPadding(padding: const EdgeInsets.only(top: 8)),
            SliverGrid(
              delegate: SliverChildBuilderDelegate(childCount: length, (
                context,
                slot,
              ) {
                if (reverse) {
                  slot = visible.length - slot - 1;
                }
                // Display slot -> original within-group index. The reader and
                // the history keys are built from that index, so hiding must
                // never renumber it.
                var i = visible[slot];
                var key = group.keys.elementAt(i);
                var value = group[key]!;
                var chapterIndex = _groupOffset + i;
                String rawIndex = (chapterIndex + 1).toString();
                String groupedIndex = "${index + 1}-${i + 1}";
                bool visited = false;
                if (_history != null) {
                  visited =
                      _history!.readEpisode.contains(groupedIndex) ||
                      _history!.readEpisode.contains(rawIndex);
                }
                bool isSelected = selected.contains(groupedIndex);
                final chipColor = _chapterChipColor(key, isSelected);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                  child: Material(
                    color: chipColor.color,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      onTap: () => selectMode
                          ? toggleSelect(groupedIndex)
                          : state.read(chapterIndex + 1),
                      onLongPress: selectMode
                          ? null
                          : () {
                              enterSelectMode();
                              toggleSelect(groupedIndex);
                            },
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _chapterTitleOf(key, value),
                                maxLines: 1,
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isSelected
                                      ? context.colorScheme.onPrimaryContainer
                                      : chipColor.textColor ??
                                            (visited
                                                ? context.colorScheme.outline
                                                : null),
                                ),
                              ),
                              // 翻译组标签（U2）。分组视图本身丢掉了版本
                              // 结构（grouped 与 versioned 互斥），所以这里
                              // 回头问"这一 tab 是哪本本地漫画"，用
                              // LocalComic.groupAt 取组名 —— 组信息在
                              // local.db 的 chapters 列里，不需要文件名标记。
                              // 取不到就整块省略（不渲染空标签）。
                              if (_groupLabelAt(i) case final label?)
                                Text(
                                  label,
                                  maxLines: 1,
                                  textAlign: TextAlign.center,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: isSelected
                                        ? context.colorScheme.onPrimaryContainer
                                        : context.colorScheme.outline,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
              gridDelegate: const SliverGridDelegateWithFixedHeight(
                maxCrossAxisExtent: 220,
                itemHeight: 44,
              ),
            ).sliverPadding(EdgeInsets.zero),
            if (!canShowAll)
              SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.center,
                  child: TextButton.icon(
                    icon: const Icon(Icons.arrow_drop_down),
                    onPressed: () {
                      setState(() {
                        showAll = true;
                      });
                    },
                    label: Text("${"Show all".tl} (${visible.length})"),
                  ).paddingTop(12),
                ),
              ),
            const SliverPadding(padding: EdgeInsets.only(bottom: 12)),
          ],
        );
      },
    );
  }
}

/// "Updating" text + spinner next to the "Chapters" title while the background
/// details fetch refreshes a chapter list that is already on screen.
class _ChaptersUpdatingIndicator extends StatelessWidget {
  const _ChaptersUpdatingIndicator();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.6,
            color: context.colorScheme.outline,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          "Updating".tl,
          style: ts.s12.withColor(context.colorScheme.outline),
        ),
      ],
    );
  }
}

/// 章节标签的底色与文字色对（null 文字色 = 跟随主题默认）。
/// 详见 [chapterChipColorFor]（#P5/S3-a）。
class _ChapterChipColors {
  const _ChapterChipColors(this.color, this.textColor);

  final Color color;
  final Color? textColor;
}

/// 按下载状态取章节标签配色：
/// 白=基础 / 浅绿=待命 / 黄=下载中 / 蓝=已下载 / 红=缺页或下载失败。
/// 状态判定统一在 foundation 层 [chapterDownloadStatusFor]（P-DL6 上提，
/// 与"本地模式"章节过滤、阅读器章节列表共用一套判定）。优先级：
/// 红 > 黄 > 绿 > 蓝 > 基础。已读灰字逻辑由调用方保留（仅作用于未着色的基础态）。
_ChapterChipColors chapterChipColorFor(
  BuildContext context,
  ComicDetails comic,
  String chapterKey,
) {
  final status = chapterDownloadStatusFor(
    comicId: comic.id,
    comicType: comic.comicType,
    chapters: comic.chapters,
    chapterKey: chapterKey,
  );
  final isDark = context.colorScheme.brightness == Brightness.dark;
  switch (status) {
    case ChapterDownloadStatus.missing:
      return _ChapterChipColors(
        isDark ? const Color(0xFF4A1414) : const Color(0xFFFFCDD2),
        isDark ? const Color(0xFFEF9A9A) : const Color(0xFFB71C1C),
      );
    case ChapterDownloadStatus.downloading:
      return _ChapterChipColors(
        isDark ? const Color(0xFF4E4011) : const Color(0xFFFFE082),
        isDark ? const Color(0xFFFFD54F) : const Color(0xFF7A5900),
      );
    case ChapterDownloadStatus.standby:
      // 待命章节（用户 2026-10-16 定色）：浅绿色，介于"未下载(白)"与
      // "下载中(黄)"之间——任务已建好、排队等跑，本地模式下保留显示。
      return _ChapterChipColors(
        isDark ? const Color(0xFF1B3A24) : const Color(0xFFC8E6C9),
        isDark ? const Color(0xFF81C784) : const Color(0xFF1B5E20),
      );
    case ChapterDownloadStatus.downloaded:
      return _ChapterChipColors(
        isDark ? const Color(0xFF1D3A5F) : const Color(0xFFBBDEFB),
        isDark ? const Color(0xFFA6C8FF) : const Color(0xFF0D47A1),
      );
    case ChapterDownloadStatus.notDownloaded:
      return _ChapterChipColors(context.colorScheme.surfaceContainerLow, null);
  }
}

/// 「本地显示模式」下该章节是否保留：隐藏纯白未下载章节，蓝(已下载)/
/// 黄(下载中)/红(问题)/浅绿(待命)全部保留。判断与配色共用同一状态函数，
/// 下载任务完成时 LocalManager 通知刷新，章节会自动从过滤列表里"长"回来。
bool chapterKeptInLocalMode(ComicDetails comic, String chapterKey) =>
    chapterDownloadStatusFor(
      comicId: comic.id,
      comicType: comic.comicType,
      chapters: comic.chapters,
      chapterKey: chapterKey,
    ) !=
    ChapterDownloadStatus.notDownloaded;
