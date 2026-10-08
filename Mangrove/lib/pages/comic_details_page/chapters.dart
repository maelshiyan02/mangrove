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

  /// Original flat indices actually rendered, in list order. Hiding duplicates
  /// only removes entries here — the indices themselves keep their original
  /// values, because [_ComicPageActions.read] and the download picker address
  /// chapters by flat index.
  late List<int> visible;

  @override
  Set<String> get selectableKeys =>
      visible.map((i) => (i + 1).toString()).toSet();

  void _computeVisible() {
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
    visible = [
      for (final i in ordered)
        if (!hidden.contains(i)) i,
    ];
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
                        if (chapters.isVersioned &&
                            chapters.scanlationGroupsSorted.length > 1)
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
                                parseChapterTitle(value).displayTitle,
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
                              if (_displayChapters.isVersioned &&
                                  _displayChapters.scanlationGroupAt(i) != null)
                                Text(
                                  _displayChapters.scanlationGroupAt(i)!,
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

  /// Scrollable row of filter chips for selecting a scanlation group.
  /// Shown only when there are 2+ groups in versioned chapters.
  Widget _buildScanlationGroupChips(BuildContext context) {
    final groups = chapters.scanlationGroupsSorted;
    final selected = _selectedScanlationGroup;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: groups.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final group = groups[index];
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
    return _memberLocalComic?.groupAt(i + 1);
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
    visible = [
      for (final i in ordered)
        if (!hidden.contains(offset + i)) i,
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
                                parseChapterTitle(value).displayTitle,
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

/// 将章节 key（源章节 id）转换为缺失页表里使用的章节目录名。
///
/// 必须与下载侧完全一致 —— 两边现在都调 [chapterDirectoryName]（`foundation/
/// chapter_directory.dart`）。以前这里是抄了一份规则，下载侧一改就会读不到。
String chapterDirectoryId(ComicChapters? chapters, String chapterKey) =>
    chapterDirectoryName(chapters, chapterKey);

/// 按下载状态取章节标签配色：
/// 白=基础 / 黄=下载中 / 蓝=已下载 / 红=缺页或下载失败。
/// 红色依赖 S2 的缺失页记录表（missing_pages.json），优先级最高：
/// 红 > 黄 > 蓝 > 基础。已读灰字逻辑由调用方保留（仅作用于未着色的基础态）。
_ChapterChipColors chapterChipColorFor(
  BuildContext context,
  ComicDetails comic,
  String chapterKey,
) {
  final local = LocalManager().find(comic.id, comic.comicType);
  // 缺页（红色）最高优先级：已知不完整的章节优先于下载中/已下载，
  // 提示用户"这章没下全"，不会被蓝色/黄色覆盖。
  int missing = 0;
  if (local != null) {
    final dir = chapterDirectoryId(comic.chapters, chapterKey);
    missing = MissingPages.peek(local.baseDir)?.countOfChapter(dir) ?? 0;
  }
  final isDark = context.colorScheme.brightness == Brightness.dark;
  if (missing > 0) {
    return _ChapterChipColors(
      isDark ? const Color(0xFF4A1414) : const Color(0xFFFFCDD2),
      isDark ? const Color(0xFFEF9A9A) : const Color(0xFFB71C1C),
    );
  }
  final downloading = LocalManager().downloadingTasks.any(
    (t) =>
        t.id == comic.id &&
        t.comicType == comic.comicType &&
        // `chapters` 在 ImagesDownloadTask 上；其它任务类型视为整部下载。
        (t is! ImagesDownloadTask ||
            t.chapters == null ||
            t.chapters!.contains(chapterKey)),
  );
  if (downloading) {
    return _ChapterChipColors(
      isDark ? const Color(0xFF4E4011) : const Color(0xFFFFE082),
      isDark ? const Color(0xFFFFD54F) : const Color(0xFF7A5900),
    );
  }
  final downloaded = local?.downloadedChapters.contains(chapterKey) ?? false;
  if (downloaded) {
    return _ChapterChipColors(
      isDark ? const Color(0xFF1D3A5F) : const Color(0xFFBBDEFB),
      isDark ? const Color(0xFFA6C8FF) : const Color(0xFF0D47A1),
    );
  }
  return _ChapterChipColors(context.colorScheme.surfaceContainerLow, null);
}
