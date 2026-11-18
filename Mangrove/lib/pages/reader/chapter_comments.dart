part of 'reader.dart';

bool _shouldBlockComment(Comment comment) {
  var blockedWords = appdata.settings["blockedCommentWords"] as List;
  if (blockedWords.isEmpty) return false;

  var content = comment.content.toLowerCase();
  for (var word in blockedWords) {
    if (content.contains(word.toString().toLowerCase())) {
      return true;
    }
  }
  return false;
}

class ChapterCommentsPage extends StatefulWidget {
  const ChapterCommentsPage({
    super.key,
    required this.comicId,
    required this.epId,
    required this.source,
    required this.comicTitle,
    required this.chapterTitle,
    this.replyComment,
  });

  final String comicId;
  final String epId;
  final ComicSource source;
  final String comicTitle;
  final String chapterTitle;
  final Comment? replyComment;

  @override
  State<ChapterCommentsPage> createState() => _ChapterCommentsPageState();
}

class _ChapterCommentsPageState extends State<ChapterCommentsPage> {
  /// P65：默认把拷贝 App 的「最新在前」翻成「从旧到新」。
  CommentOrder _order = CommentOrder.oldestFirst;

  bool _loading = true;
  List<Comment>? _comments;
  String? _error;
  int _page = 1;
  int? maxPage;
  var controller = TextEditingController();
  bool sending = false;

  /// Both loads are build-triggered (loading placeholder / list tail); a
  /// rebuild during the request used to fire a duplicate one, double-loading
  /// the same page.
  bool _requestInFlight = false;

  /// P68：某个方向已确认没有更多页（拿回空页），别再反复请求。
  bool _exhausted = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<Res<List<Comment>>> _load(int page) {
    return widget.source.chapterCommentsLoader!(
      widget.comicId,
      widget.epId,
      page,
      widget.replyComment?.id,
    );
  }

  void firstLoad() async {
    if (_requestInFlight) return;
    _requestInFlight = true;
    var res = await _load(1);
    final serverMaxPage = res.error ? null : res.subData;
    var target = commentFirstPage(maxPage: serverMaxPage, order: _order);
    if (!res.error && target != 1) {
      res = await _load(target);
      // P68：尾页可能空（源站 maxPage 高估一页）→ 逐页回退，别停在空列表。
      var attempts = 0;
      while (!res.error && res.data.isEmpty && target > 1) {
        final back = commentFallbackPage(page: target, attempts: attempts);
        if (back == null) break;
        target = back;
        attempts++;
        res = await _load(target);
      }
    }
    _requestInFlight = false;
    if (!mounted) return;
    if (res.error) {
      setState(() {
        _error = res.errorMessage;
        _loading = false;
      });
    } else {
      var filteredComments = res.data
          .where((c) => !_shouldBlockComment(c))
          .toList();
      filteredComments = orderComments(filteredComments, _order, (c) => c.time);
      setState(() {
        _comments = filteredComments;
        _page = target;
        _loading = false;
        maxPage = serverMaxPage;
        _exhausted = commentPagingExhausted(
          page: target,
          order: _order,
          rawCount: res.data.length,
        );
      });
    }
  }

  void loadMore() async {
    final next = commentNextPage(
      page: _page,
      maxPage: maxPage,
      order: _order,
      exhausted: _exhausted,
    );
    if (next == null || _requestInFlight) return;
    _requestInFlight = true;
    var res = await _load(next);
    _requestInFlight = false;
    if (!mounted) return;
    if (res.error) {
      context.showMessage(message: res.errorMessage ?? "Unknown Error");
    } else {
      var filteredComments = res.data
          .where((c) => !_shouldBlockComment(c))
          .toList();
      filteredComments = orderComments(filteredComments, _order, (c) => c.time);
      setState(() {
        // P68：整体替换而不是往 _comments 里 addAll —— 排序产物是新建列表，
        // 依赖它可增长曾经在 setState 里抛异常，页码不推进 → 无限请求。
        _comments = [...?_comments, ...filteredComments];
        _page = next;
        if (maxPage == null && res.data.isEmpty) {
          maxPage = _order == CommentOrder.oldestFirst ? 1 : _page;
        }
        _exhausted = commentPagingExhausted(
          page: next,
          order: _order,
          rawCount: res.data.length,
        );
      });
    }
  }

  void toggleCommentOrder() {
    setState(() {
      _order = _order == CommentOrder.oldestFirst
          ? CommentOrder.newestFirst
          : CommentOrder.oldestFirst;
      if (_comments != null) {
        _comments = orderComments(_comments!, _order, (c) => c.time);
      }
    });
  }

  Widget buildOrderBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Align(
        alignment: Alignment.centerRight,
        child: InkWell(
          onTap: toggleCommentOrder,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.swap_vert, size: 15, color: context.colorScheme.primary),
                const SizedBox(width: 4),
                Text(
                  _order == CommentOrder.oldestFirst
                      ? "Oldest first".tl
                      : "Newest first".tl,
                  style: ts.s12.copyWith(color: context.colorScheme.primary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: Appbar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Chapter Comments".tl, style: ts.s18),
            Text(widget.chapterTitle, style: ts.s12),
          ],
        ),
        style: AppbarStyle.shadow,
      ),
      body: buildBody(context),
    );
  }

  Widget buildBody(BuildContext context) {
    if (_loading) {
      firstLoad();
      return const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      return NetworkError(
        message: _error!,
        retry: () {
          setState(() {
            _loading = true;
          });
        },
        withAppbar: false,
      );
    } else {
      var showAvatar =
          _comments!.any((e) {
            return e.avatar != null;
          }) ||
          (widget.replyComment?.avatar != null);
      return Column(
        children: [
          buildOrderBar(),
          Expanded(
            child: SmoothScrollProvider(
              builder: (context, controller, physics) {
                return ListView.builder(
                  controller: controller,
                  physics: physics,
                  primary: false,
                  padding: EdgeInsets.zero,
                  itemCount: _comments!.length + 2,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      if (widget.replyComment != null) {
                        return Column(
                          children: [
                            _ChapterCommentTile(
                              comment: widget.replyComment!,
                              source: widget.source,
                              comicId: widget.comicId,
                              epId: widget.epId,
                              showAvatar: showAvatar,
                              showActions: false,
                            ),
                            const SizedBox(height: 8),
                            Container(
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(
                                    color: context.colorScheme.outlineVariant,
                                    width: 0.6,
                                  ),
                                ),
                              ),
                              child: Text("Replies".tl, style: ts.s18),
                            ),
                          ],
                        );
                      } else {
                        return const SizedBox();
                      }
                    }
                    index--;

                    if (index == _comments!.length) {
                      if (commentNextPage(
                            page: _page,
                            maxPage: maxPage,
                            order: _order,
                          ) !=
                          null) {
                        loadMore();
                        return const ListLoadingIndicator();
                      } else {
                        return const SizedBox();
                      }
                    }

                    return _ChapterCommentTile(
                      comment: _comments![index],
                      source: widget.source,
                      comicId: widget.comicId,
                      epId: widget.epId,
                      showAvatar: showAvatar,
                    );
                  },
                );
              },
            ),
          ),
          buildBottom(context),
        ],
      );
    }
  }

  Widget buildBottom(BuildContext context) {
    if (widget.source.sendChapterCommentFunc == null) {
      return const SizedBox(height: 0);
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Material(
        color: context.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(24),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isCollapsed: true,
                  hintText: "Comment".tl,
                ),
                minLines: 1,
                maxLines: 5,
              ),
            ),
            if (sending)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                onPressed: () async {
                  if (controller.text.isEmpty) {
                    return;
                  }
                  setState(() {
                    sending = true;
                  });
                  var b = await widget.source.sendChapterCommentFunc!(
                    widget.comicId,
                    widget.epId,
                    controller.text,
                    widget.replyComment?.id,
                  );
                  if (!b.error) {
                    controller.text = "";
                    setState(() {
                      sending = false;
                      _loading = true;
                      _comments?.clear();
                      _page = 1;
                      maxPage = null;
                    });
                  } else {
                    context.showMessage(message: b.errorMessage ?? "Error");
                    setState(() {
                      sending = false;
                    });
                  }
                },
                icon: Icon(
                  Icons.send,
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
          ],
        ).paddingLeft(16).paddingRight(4),
      ),
    );
  }
}

class _ChapterCommentTile extends StatefulWidget {
  const _ChapterCommentTile({
    required this.comment,
    required this.source,
    required this.comicId,
    required this.epId,
    required this.showAvatar,
    this.showActions = true,
  });

  final Comment comment;
  final ComicSource source;
  final String comicId;
  final String epId;
  final bool showAvatar;
  final bool showActions;

  @override
  State<_ChapterCommentTile> createState() => _ChapterCommentTileState();
}

class _ChapterCommentTileState extends State<_ChapterCommentTile> {
  @override
  void initState() {
    likes = widget.comment.score ?? 0;
    isLiked = widget.comment.isLiked ?? false;
    voteStatus = widget.comment.voteStatus;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showAvatar)
            Container(
              width: 36,
              height: 36,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: Theme.of(context).colorScheme.secondaryContainer,
              ),
              child: widget.comment.avatar == null
                  ? null
                  : AnimatedImage(
                      image: CachedImageProvider(
                        widget.comment.avatar!,
                        sourceKey: widget.source.key,
                      ),
                    ),
            ).paddingRight(8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.comment.userName,
                  style: ts.bold.copyWith(fontSize: commentsFontSize),
                ),
                if (widget.comment.time != null)
                  Text(widget.comment.time!, style: ts.s12),
                const SizedBox(height: 4),
                _CommentContent(text: widget.comment.content),
                buildActions(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildActions() {
    if (!widget.showActions) {
      return const SizedBox();
    }
    if (widget.comment.score == null && widget.comment.replyCount == null) {
      return const SizedBox();
    }
    return SizedBox(
      height: 36,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (widget.comment.score != null &&
              widget.source.voteCommentFunc != null)
            buildVote(),
          if (widget.comment.score != null &&
              widget.source.likeCommentFunc != null)
            buildLike(),
          // Only show reply button if comment has both id and replyCount
          if (widget.comment.replyCount != null && widget.comment.id != null)
            buildReply(),
        ],
      ),
    ).paddingTop(8);
  }

  Widget buildReply() {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          // Get the parent page's widget to access comicTitle and chapterTitle
          var parentState = context
              .findAncestorStateOfType<_ChapterCommentsPageState>();
          showSideBar(
            context,
            ChapterCommentsPage(
              comicId: widget.comicId,
              epId: widget.epId,
              source: widget.source,
              comicTitle: parentState?.widget.comicTitle ?? '',
              chapterTitle: parentState?.widget.chapterTitle ?? '',
              replyComment: widget.comment,
            ),
            showBarrier: false,
          );
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_comment_outlined, size: 16),
            const SizedBox(width: 8),
            Text(widget.comment.replyCount.toString()),
          ],
        ).padding(const EdgeInsets.symmetric(horizontal: 12, vertical: 4)),
      ),
    );
  }

  bool isLiking = false;
  bool isLiked = false;
  var likes = 0;

  Widget buildLike() {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          if (isLiking) return;
          setState(() {
            isLiking = true;
          });
          var res = await widget.source.likeCommentFunc!(
            widget.comicId,
            widget.epId,
            widget.comment.id!,
            !isLiked,
          );
          if (res.success) {
            isLiked = !isLiked;
            likes += isLiked ? 1 : -1;
          } else {
            context.showMessage(message: res.errorMessage ?? "Error");
          }
          setState(() {
            isLiking = false;
          });
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLiking)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(),
              )
            else if (isLiked)
              Icon(
                Icons.favorite,
                size: 16,
                color: context.useTextColor(Colors.red),
              )
            else
              const Icon(Icons.favorite_border, size: 16),
            const SizedBox(width: 8),
            Text(likes.toString()),
          ],
        ).padding(const EdgeInsets.symmetric(horizontal: 12, vertical: 4)),
      ),
    );
  }

  int? voteStatus;
  bool isVotingUp = false;
  bool isVotingDown = false;

  void vote(bool isUp) async {
    if (isVotingUp || isVotingDown) return;
    setState(() {
      if (isUp) {
        isVotingUp = true;
      } else {
        isVotingDown = true;
      }
    });
    var isCancel = (isUp && voteStatus == 1) || (!isUp && voteStatus == -1);
    var res = await widget.source.voteCommentFunc!(
      widget.comicId,
      widget.epId,
      widget.comment.id!,
      isUp,
      isCancel,
    );
    if (res.success) {
      if (isCancel) {
        voteStatus = 0;
      } else {
        if (isUp) {
          voteStatus = 1;
        } else {
          voteStatus = -1;
        }
      }
      widget.comment.voteStatus = voteStatus;
      widget.comment.score = res.data ?? widget.comment.score;
    } else {
      context.showMessage(message: res.errorMessage ?? "Error");
    }
    setState(() {
      isVotingUp = false;
      isVotingDown = false;
    });
  }

  Widget buildVote() {
    var upColor = context.colorScheme.outline;
    if (voteStatus == 1) {
      upColor = context.useTextColor(Colors.red);
    }
    var downColor = context.colorScheme.outline;
    if (voteStatus == -1) {
      downColor = context.useTextColor(Colors.blue);
    }

    return Container(
      margin: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Button.icon(
            isLoading: isVotingUp,
            icon: const Icon(Icons.arrow_upward),
            size: 18,
            color: upColor,
            onPressed: () => vote(true),
          ),
          const SizedBox(width: 4),
          Text(widget.comment.score.toString()),
          const SizedBox(width: 4),
          Button.icon(
            isLoading: isVotingDown,
            icon: const Icon(Icons.arrow_downward),
            size: 18,
            color: downColor,
            onPressed: () => vote(false),
          ),
        ],
      ),
    );
  }
}

class _CommentContent extends StatelessWidget {
  const _CommentContent({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return CommentContent(text: text, fontSize: commentsFontSize);
  }
}

/// Embedded chapter comments page for displaying at end of chapter in gallery mode.
class _EmbeddedChapterCommentsPage extends StatefulWidget {
  const _EmbeddedChapterCommentsPage({
    required this.comicId,
    required this.epId,
    required this.source,
    required this.comicTitle,
    required this.chapterTitle,
  });

  final String comicId;
  final String epId;
  final ComicSource source;
  final String comicTitle;
  final String chapterTitle;

  @override
  State<_EmbeddedChapterCommentsPage> createState() =>
      _EmbeddedChapterCommentsPageState();
}

class _EmbeddedChapterCommentsPageState
    extends State<_EmbeddedChapterCommentsPage> {
  /// P65：与独立章节评论页共用同一套默认顺序（旧→新）。
  CommentOrder _order = CommentOrder.oldestFirst; // P65-embedded

  bool _loading = true;
  List<Comment>? _comments;
  String? _error;
  int _page = 1;
  int? maxPage;
  var textController = TextEditingController();
  final scrollController = ScrollController();
  bool sending = false;

  /// Both loads are build-triggered (loading placeholder / list tail); a
  /// rebuild during the request used to fire a duplicate one, double-loading
  /// the same page.
  bool _requestInFlight = false;

  /// P68：某个方向已确认没有更多页（拿回空页），别再反复请求。
  bool _exhausted = false;

  @override
  void dispose() {
    textController.dispose();
    scrollController.dispose();
    super.dispose();
  }

  Future<Res<List<Comment>>> _load(int page) {
    return widget.source.chapterCommentsLoader!(
      widget.comicId,
      widget.epId,
      page,
      null,
    );
  }

  void firstLoad() async {
    if (_requestInFlight) return;
    _requestInFlight = true;
    var res = await _load(1);
    // 与独立评论页一致：第一趟只为拿 maxPage，旧→新要从最后一页开始显示。
    final serverMaxPage = res.error ? null : res.subData;
    var target = commentFirstPage(maxPage: serverMaxPage, order: _order);
    if (!res.error && target != 1) {
      res = await _load(target);
      // P68：尾页可能空（源站 maxPage 高估一页）→ 逐页回退，别停在空列表。
      var attempts = 0;
      while (!res.error && res.data.isEmpty && target > 1) {
        final back = commentFallbackPage(page: target, attempts: attempts);
        if (back == null) break;
        target = back;
        attempts++;
        res = await _load(target);
      }
    }
    _requestInFlight = false;
    if (!mounted) return;
    if (res.error) {
      setState(() {
        _error = res.errorMessage;
        _loading = false;
      });
    } else {
      var filteredComments = res.data
          .where((c) => !_shouldBlockComment(c))
          .toList();
      filteredComments = orderComments(filteredComments, _order, (c) => c.time);
      setState(() {
        _comments = filteredComments;
        _page = target;
        _loading = false;
        maxPage = serverMaxPage;
        _exhausted = commentPagingExhausted(
          page: target,
          order: _order,
          rawCount: res.data.length,
        );
      });
    }
  }

  void loadMore() async {
    final next = commentNextPage(
      page: _page,
      maxPage: maxPage,
      order: _order,
      exhausted: _exhausted,
    );
    if (next == null || _requestInFlight) return;
    _requestInFlight = true;
    var res = await _load(next);
    _requestInFlight = false;
    if (!mounted) return;
    if (res.error) {
      context.showMessage(message: res.errorMessage ?? "Unknown Error");
    } else {
      var filteredComments = res.data
          .where((c) => !_shouldBlockComment(c))
          .toList();
      filteredComments = orderComments(filteredComments, _order, (c) => c.time);
      setState(() {
        // P68：整体替换而不是往 _comments 里 addAll —— 排序产物是新建列表，
        // 依赖它可增长曾经在 setState 里抛异常，页码不推进 → 无限请求。
        _comments = [...?_comments, ...filteredComments];
        _page = next;
        if (maxPage == null && res.data.isEmpty) {
          maxPage = _order == CommentOrder.oldestFirst ? 1 : _page;
        }
        _exhausted = commentPagingExhausted(
          page: next,
          order: _order,
          rawCount: res.data.length,
        );
      });
    }
  }

  void toggleCommentOrder() {
    setState(() {
      _order = _order == CommentOrder.oldestFirst
          ? CommentOrder.newestFirst
          : CommentOrder.oldestFirst;
      if (_comments != null) {
        _comments = orderComments(_comments!, _order, (c) => c.time);
      }
    });
  }

  Widget buildOrderBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Align(
        alignment: Alignment.centerRight,
        child: InkWell(
          onTap: toggleCommentOrder,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.swap_vert,
                  size: 15,
                  color: context.colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  _order == CommentOrder.oldestFirst
                      ? "Oldest first".tl
                      : "Newest first".tl,
                  style: ts.s12.copyWith(color: context.colorScheme.primary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: context.colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            buildOrderBar(),
            Expanded(child: _buildBody()),
            _buildBottom(),
            // Only this spacer may depend on the keyboard inset: reading it at
            // the page root rebuilt the whole comments grid on every frame of
            // the IME animation (#107). Scoped here, those frames only resize
            // an empty box and relayout the column.
            Builder(
              builder: (context) =>
                  SizedBox(height: MediaQuery.viewInsetsOf(context).bottom),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              Navigator.of(context).pop();
            },
            tooltip: "Exit".tl,
          ),
          const SizedBox(width: 4),
          Icon(Icons.comment, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Chapter Comments".tl, style: ts.s18),
                Text(widget.chapterTitle, style: ts.s12),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      firstLoad();
      return const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      return NetworkError(
        message: _error!,
        retry: () {
          setState(() {
            _loading = true;
            _error = null;
          });
        },
        withAppbar: false,
      );
    } else if (_comments == null || _comments!.isEmpty) {
      return Center(child: Text("No comments yet".tl, style: ts.s14));
    } else {
      var showAvatar = _comments!.any((e) => e.avatar != null);
      return _buildCommentsList(showAvatar);
    }
  }

  Widget _buildCommentsList(bool showAvatar) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final crossAxisCount = isLandscape ? 2 : 1;

    return AppScrollBar(
      controller: scrollController,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: MasonryGridView.count(
          controller: scrollController,
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: 0,
          crossAxisSpacing: 0,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          itemCount: _comments!.length + 1,
          itemBuilder: (context, index) {
            if (index == _comments!.length) {
              if (commentNextPage(
                    page: _page,
                    maxPage: maxPage,
                    order: _order,
                  ) !=
                  null) {
                loadMore();
                return const ListLoadingIndicator();
              } else {
                return const SizedBox();
              }
            }
            return _ChapterCommentTile(
              comment: _comments![index],
              source: widget.source,
              comicId: widget.comicId,
              epId: widget.epId,
              showAvatar: showAvatar,
            );
          },
        ),
      ),
    );
  }

  Widget _buildBottom() {
    if (widget.source.sendChapterCommentFunc == null) {
      return const SizedBox(height: 0);
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Material(
        color: context.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(24),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: textController,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isCollapsed: true,
                  hintText: "Comment".tl,
                ),
                minLines: 1,
                maxLines: 5,
              ),
            ),
            if (sending)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                onPressed: () async {
                  if (textController.text.isEmpty) {
                    return;
                  }
                  setState(() {
                    sending = true;
                  });
                  var b = await widget.source.sendChapterCommentFunc!(
                    widget.comicId,
                    widget.epId,
                    textController.text,
                    null,
                  );
                  if (!b.error) {
                    textController.text = "";
                    setState(() {
                      sending = false;
                      _loading = true;
                      _comments?.clear();
                      _page = 1;
                      maxPage = null;
                    });
                  } else {
                    if (mounted) {
                      context.showMessage(message: b.errorMessage ?? "Error");
                    }
                    setState(() {
                      sending = false;
                    });
                  }
                },
                icon: Icon(
                  Icons.send,
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
          ],
        ).paddingLeft(16).paddingRight(4),
      ),
    );
  }
}
