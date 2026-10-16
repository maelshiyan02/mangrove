part of 'reader.dart';

class _ChaptersView extends StatefulWidget {
  const _ChaptersView(this.reader);

  final _ReaderState reader;

  @override
  State<_ChaptersView> createState() => _ChaptersViewState();
}

class _ChaptersViewState extends State<_ChaptersView> {
  bool desc = false;

  late final ScrollController _scrollController;

  var downloaded = <String>[];

  /// 「本地显示模式」（P-DL6）下该章节是否保留：隐藏未下载的白色章节，
  /// 蓝(已下载)/黄(下载中)/红(问题)/浅绿(待命)保留。与详情页共用
  /// foundation 层的同一套状态判定。
  bool _keptInLocalMode(int index0) {
    final chapters = widget.reader.widget.chapters;
    if (chapters == null) return true;
    if (index0 < 0 || index0 >= chapters.ids.length) return true;
    return chapterDownloadStatusFor(
          comicId: widget.reader.cid,
          comicType: widget.reader.type,
          chapters: chapters,
          chapterKey: chapters.ids.elementAt(index0),
        ) !=
        ChapterDownloadStatus.notDownloaded;
  }

  List<int> get _visibleIndices => [
    for (final chapter in widget.reader.chapterOrder)
      if (!widget.reader.isChapterHidden(chapter) ||
          widget.reader.chapter == chapter)
        // 本地显示模式下隐藏未下载章节；当前章节始终保留，历史记录指向
        // 的章节才有得高亮。
        if (!comicDisplayLocalMode ||
            widget.reader.chapter == chapter ||
            _keptInLocalMode(chapter - 1))
          chapter - 1,
  ];

  @override
  void initState() {
    super.initState();
    final epIndex = _visibleIndices.indexOf(widget.reader.chapter - 1) - 1;
    _scrollController = ScrollController(
      initialScrollOffset: (epIndex * 48.0 + 52).clamp(0, double.infinity),
    );
    var local = LocalManager().find(widget.reader.cid, widget.reader.type);
    if (local != null) {
      downloaded = local.downloadedChapters;
    }
    // 本地模式不焊死（P-DL6）：其他下载任务完成/出错时刷新列表，
    // 新下载好的章节会自动出现在本地模式章节列表里。
    LocalManager().addListener(_onLocalChange);
  }

  void _onLocalChange() {
    if (!mounted) return;
    setState(() {
      var local = LocalManager().find(widget.reader.cid, widget.reader.type);
      downloaded = local?.downloadedChapters ?? const [];
    });
  }

  @override
  void dispose() {
    LocalManager().removeListener(_onLocalChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var chapters = widget.reader.widget.chapters!;
    var current = widget.reader.chapter - 1;
    // Flat 0-based indices still shown after "hide duplicate chapters". The
    // current chapter is kept even when hidden, so a history entry pointing at
    // a duplicate still highlights something.
    final visible = _visibleIndices;
    return Scaffold(
      body: SmoothCustomScrollView(
        controller: _scrollController,
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(
            style: AppbarStyle.shadow,
            title: Text("Chapters".tl),
            actions: [
              Tooltip(
                message: "Click to change the order".tl,
                child: TextButton.icon(
                  icon: Icon(
                    !desc ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 18,
                  ),
                  label: Text(!desc ? "Ascending".tl : "Descending".tl),
                  onPressed: () {
                    setState(() {
                      desc = !desc;
                    });
                  },
                ),
              ),
            ],
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                var index = visible[desc ? visible.length - 1 - i : i];
                var chapter = chapters.titles.elementAt(index);
                return _ChapterListTile(
                  onTap: () {
                    widget.reader.toChapter(index + 1);
                    Navigator.of(context).pop();
                  },
                  title: parseChapterTitle(chapter).displayTitle,
                  subtitle: chapters.isVersioned
                      ? chapters.scanlationGroupAt(index)
                      : null,
                  isActive: current == index,
                  isDownloaded:
                      downloaded.contains(chapters.ids.elementAt(index)),
                );
              },
              childCount: visible.length,
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupedChaptersView extends StatefulWidget {
  const _GroupedChaptersView(this.reader);

  final _ReaderState reader;

  @override
  State<_GroupedChaptersView> createState() => _GroupedChaptersViewState();
}

class _GroupedChaptersViewState extends State<_GroupedChaptersView>
    with SingleTickerProviderStateMixin {
  ComicChapters get chapters => widget.reader.widget.chapters!;

  late final TabController tabController;

  late final ScrollController _scrollController;

  late final String initialGroupName;

  var downloaded = <String>[];

  /// 与扁平视图同一套「本地显示模式」保留判定（P-DL6）。
  bool _keptInLocalMode(int index0) {
    if (index0 < 0 || index0 >= chapters.ids.length) return true;
    return chapterDownloadStatusFor(
          comicId: widget.reader.cid,
          comicType: widget.reader.type,
          chapters: chapters,
          chapterKey: chapters.ids.elementAt(index0),
        ) !=
        ChapterDownloadStatus.notDownloaded;
  }

  @override
  void initState() {
    super.initState();
    int index = 0;
    int epIndex = widget.reader.chapter - 1;
    while (epIndex >= 0) {
      epIndex -= chapters.getGroupByIndex(index).length;
      index++;
    }
    tabController = TabController(
      length: chapters.groups.length,
      vsync: this,
      initialIndex: index - 1,
    );
    initialGroupName = chapters.groups.elementAt(index - 1);
    final epIndexAtGroup = _visibleChapters(
      initialGroupName,
    ).indexOf(widget.reader.chapter);
    _scrollController = ScrollController(
      initialScrollOffset: (epIndexAtGroup * 48.0).clamp(0, double.infinity),
    );
    var local = LocalManager().find(widget.reader.cid, widget.reader.type);
    if (local != null) {
      downloaded = local.downloadedChapters;
    }
    // 与扁平视图同理：本地模式不焊死，任务完成时刷新。
    LocalManager().addListener(_onLocalChange);
  }

  void _onLocalChange() {
    if (!mounted) return;
    setState(() {
      var local = LocalManager().find(widget.reader.cid, widget.reader.type);
      downloaded = local?.downloadedChapters ?? const [];
    });
  }

  @override
  void dispose() {
    LocalManager().removeListener(_onLocalChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Appbar(title: Text("Chapters".tl)),
        AppTabBar(
          controller: tabController,
          tabs: chapters.groups.map((e) => Tab(text: e)).toList(),
        ),
        Expanded(
          child: TabViewBody(
            controller: tabController,
            children: chapters.groups.map(buildGroup).toList(),
          ),
        ),
      ],
    );
  }

  List<int> _visibleChapters(String groupName) {
    var group = chapters.getGroup(groupName);
    // Flat 1-based chapter number of this group's first entry.
    var base = 1;
    for (var g in chapters.groups) {
      if (g == groupName) break;
      base += chapters.getGroup(g).length;
    }
    // Chapters of this group in reading order that survive "hide duplicate
    // chapters"; the current chapter is kept even when hidden.
    // 本地显示模式（P-DL6）下再过滤掉未下载的白色章节，当前章节保留。
    return [
      for (final chapter in widget.reader.chapterOrder)
        if (chapter >= base &&
            chapter < base + group.length &&
            (!widget.reader.isChapterHidden(chapter) ||
                widget.reader.chapter == chapter) &&
            (!comicDisplayLocalMode ||
                widget.reader.chapter == chapter ||
                _keptInLocalMode(chapter - 1)))
          chapter,
    ];
  }

  Widget buildGroup(String groupName) {
    final visible = _visibleChapters(groupName);
    return SmoothCustomScrollView(
      controller: initialGroupName == groupName ? _scrollController : null,
      slivers: [
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, position) {
              final i = visible[position];
              final name = chapters.titles.elementAt(i - 1);
              return _ChapterListTile(
                onTap: () {
                  widget.reader.toChapter(i);
                  context.pop();
                },
                title: parseChapterTitle(name).displayTitle,
                isActive: widget.reader.chapter == i,
                isDownloaded: downloaded.contains(
                  chapters.ids.elementAt(i - 1),
                ),
              );
            },
            childCount: visible.length,
          ),
        ),
      ],
    );
  }
}

class _ChapterListTile extends StatelessWidget {
  const _ChapterListTile({
    required this.title,
    this.subtitle,
    required this.isActive,
    required this.isDownloaded,
    required this.onTap,
  });

  final String title;

  /// Optional secondary line, e.g. scanlation group for versioned chapters.
  final String? subtitle;

  final bool isActive;

  final bool isDownloaded;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color:
                  isActive ? context.colorScheme.primary : Colors.transparent,
              width: 4,
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: isActive
                        ? ts.withColor(context.colorScheme.primary).bold.s16
                        : ts.s16,
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts.s10.withColor(
                        context.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (isDownloaded)
              Icon(
                Icons.download_done_rounded,
                color: context.colorScheme.secondary,
              ),
          ],
        ),
      ),
    );
  }
}
