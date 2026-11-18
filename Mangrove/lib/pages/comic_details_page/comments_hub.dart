part of 'comic_page.dart';

/// P64 · 详情页评论中心：作品评价 / 单话留言两个分栏。
///
/// 拷贝漫画把评论拆成两层 —— 作品整体评价（App 端 `/api/v3/comments?comic_id=`）
/// 与单话留言（`/api/v3/roasts?chapter_id=`）。旧的「评论」按钮只能看到前者，
/// 想看某一话的留言必须**打开那一话、一路读到章末**才行，这是用户反馈的核心痛点。
///
/// 本页把两者并列，并给单话留言配一个可搜索的章节选择器：任何一话的留言都是
/// 一次点击的距离。分栏里的列表直接复用 [CommentsPage]（`embedded: true`），
/// 不另写一套渲染，避免两处对角标/点赞/回复的处理分叉。
class CommentsHubPage extends StatefulWidget {
  const CommentsHubPage({super.key, required this.data, required this.source});

  final ComicDetails data;

  final ComicSource source;

  @override
  State<CommentsHubPage> createState() => _CommentsHubPageState();
}

class _CommentsHubPageState extends State<CommentsHubPage> {
  bool _chapterMode = false;

  /// 0-based，指向 [_chapters]。
  int _chapterIndex = 0;

  late final List<_HubChapter> _chapters = _buildChapters();

  bool get _hasComicComments => widget.source.commentsLoader != null;

  bool get _hasChapterComments => widget.source.chapterCommentsLoader != null;

  List<_HubChapter> _buildChapters() {
    final chapters = widget.data.chapters;
    if (chapters == null) return const [];
    final ids = chapters.ids.toList();
    final titles = chapters.titles.toList();
    return <_HubChapter>[
      for (var i = 0; i < ids.length; i++)
        _HubChapter(
          id: ids[i],
          title: i < titles.length ? titles[i] : ids[i],
          number: i + 1,
        ),
    ];
  }

  @override
  void initState() {
    super.initState();
    // 只有一个分栏可用时直接进那一个，不留一个点了没内容的分栏。
    if (!_hasComicComments && _hasChapterComments) {
      _chapterMode = true;
    }
    _restoreLastReadChapter();
  }

  /// 默认落在「最近读到的那一话」：接着看的人的诉求，比从第 1 话从头找更强。
  /// 分组章节的历史 `ep` 是**组内序号**，要先按组长度折算成扁平下标。
  void _restoreLastReadChapter() {
    if (_chapters.isEmpty) return;
    final history = HistoryManager().find(widget.data.id, widget.data.comicType);
    final ep = history?.ep;
    if (ep == null || ep < 1) return;
    var flat = ep;
    final group = history?.group;
    final chapters = widget.data.chapters;
    if (group != null && group > 1 && chapters != null) {
      for (var i = 0; i < group - 1 && i < chapters.groupCount; i++) {
        flat += chapters.getGroupByIndex(i).length;
      }
    }
    if (flat >= 1 && flat <= _chapters.length) {
      _chapterIndex = flat - 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final showSwitch = _hasComicComments && _hasChapterComments;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: Appbar(
        title: Row(
          children: [
            Text("Comments".tl),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                widget.data.title,
                style: ts.s12.copyWith(color: context.colorScheme.outline),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        style: AppbarStyle.shadow,
      ),
      body: Column(
        children: [
          if (showSwitch) buildSwitch(context),
          if (_chapterMode) buildChapterBar(context),
          Expanded(child: buildList()),
        ],
      ),
    );
  }

  Widget buildSwitch(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: Text("Comic Comments".tl)),
              ButtonSegment(value: true, label: Text("Chapter Comments".tl)),
            ],
            selected: {_chapterMode},
            showSelectedIcon: false,
            onSelectionChanged: (value) {
              setState(() => _chapterMode = value.first);
            },
          ),
        ],
      ),
    );
  }

  Widget buildChapterBar(BuildContext context) {
    if (_chapters.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Text("Chapter list not loaded".tl, style: ts.s12),
      );
    }
    final current = _chapters[_chapterIndex];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: "Previous chapter".tl,
            icon: const Icon(Icons.chevron_left),
            onPressed: _chapterIndex > 0
                ? () => setState(() => _chapterIndex--)
                : null,
          ),
          Expanded(
            child: Material(
              color: context.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: pickChapter,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          current.title,
                          style: ts.s14,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        "${_chapterIndex + 1}/${_chapters.length}",
                        style: ts.s12.copyWith(
                          color: context.colorScheme.outline,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(Icons.expand_more, size: 18),
                    ],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: "Next chapter".tl,
            icon: const Icon(Icons.chevron_right),
            onPressed: _chapterIndex < _chapters.length - 1
                ? () => setState(() => _chapterIndex++)
                : null,
          ),
        ],
      ),
    );
  }

  Widget buildList() {
    if (!_chapterMode) {
      return CommentsPage(
        key: const ValueKey("p64_comic_comments"),
        data: widget.data,
        source: widget.source,
        embedded: true,
      );
    }
    if (_chapters.isEmpty) {
      return Center(child: Text("Chapter list not loaded".tl, style: ts.s14));
    }
    if (!_hasChapterComments) {
      return Center(
        child: Text("This source has no chapter comments".tl, style: ts.s14),
      );
    }
    final current = _chapters[_chapterIndex];
    // key 带上 epId：切章必须换一个 State，否则会把上一话的列表当成新话的首页。
    return CommentsPage(
      key: ValueKey("p64_chapter_comments_${current.id}"),
      data: widget.data,
      source: widget.source,
      embedded: true,
      epId: current.id,
      chapterTitle: current.title,
    );
  }

  Future<void> pickChapter() async {
    final result = await showDialog<int>(
      context: context,
      builder: (context) =>
          _ChapterPickerDialog(chapters: _chapters, current: _chapterIndex),
    );
    if (result != null && mounted && result != _chapterIndex) {
      setState(() => _chapterIndex = result);
    }
  }
}

class _HubChapter {
  const _HubChapter({
    required this.id,
    required this.title,
    required this.number,
  });

  final String id;

  final String title;

  final int number;
}

/// 章节选择器：带搜索框的模态列表。
///
/// 拷贝的单部作品动辄上百话，纯下拉既长又难翻；输入「23」或「第23话」都能筛出来。
class _ChapterPickerDialog extends StatefulWidget {
  const _ChapterPickerDialog({required this.chapters, required this.current});

  final List<_HubChapter> chapters;

  final int current;

  @override
  State<_ChapterPickerDialog> createState() => _ChapterPickerDialogState();
}

class _ChapterPickerDialogState extends State<_ChapterPickerDialog> {
  final controller = TextEditingController();

  late List<int> _filtered = _allIndices;

  List<int> get _allIndices =>
      List<int>.generate(widget.chapters.length, (i) => i);

  @override
  void initState() {
    super.initState();
    controller.addListener(_applyFilter);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _applyFilter() {
    final query = controller.text.trim().toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filtered = _allIndices;
        return;
      }
      _filtered = _allIndices.where((i) {
        final chapter = widget.chapters[i];
        return chapter.title.toLowerCase().contains(query) ||
            chapter.number.toString() == query;
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      title: Text("Select Chapter".tl),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: "Chapter".tl,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        SizedBox(
          width: 420,
          height: 420,
          child: _filtered.isEmpty
              ? Center(child: Text("No results".tl, style: ts.s14))
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: _filtered.length,
                  itemBuilder: (context, index) {
                    final i = _filtered[index];
                    final chapter = widget.chapters[i];
                    final selected = i == widget.current;
                    return ListTile(
                      dense: true,
                      selected: selected,
                      title: Text(chapter.title, style: ts.s14),
                      trailing: selected
                          ? const Icon(Icons.check, size: 18)
                          : Text(
                              "${i + 1}/${widget.chapters.length}",
                              style: ts.s12.copyWith(
                                color: context.colorScheme.outline,
                              ),
                            ),
                      onTap: () => Navigator.of(context).pop(i),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
