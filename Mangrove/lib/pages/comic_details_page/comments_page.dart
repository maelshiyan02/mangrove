part of 'comic_page.dart';

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

class CommentsPage extends StatefulWidget {
  const CommentsPage({
    super.key,
    required this.data,
    required this.source,
    this.replyComment,
    this.epId,
    this.chapterTitle,
    this.embedded = false,
  });

  final ComicDetails data;

  final ComicSource source;

  final Comment? replyComment;

  /// P64：非空时改为加载**该章节**的留言。
  ///
  /// 拷贝漫画把评论拆成两层：作品评价（`/api/v3/comments?comic_id=`）与单话留言
  /// （`/api/v3/roasts?chapter_id=`）。网页端把两者都关了，只有手机 App 能看，
  /// 所以这里必须走 App 签名通道（`chapterCommentsLoader`），不能退回网页端。
  final String? epId;

  /// 章节名，仅用于副标题。
  final String? chapterTitle;

  /// 作为分栏内容嵌入（评论中心）时不要自己的 Scaffold。
  final bool embedded;

  @override
  State<CommentsPage> createState() => _CommentsPageState();
}

class _CommentsPageState extends State<CommentsPage> {
  /// P65：拷贝接口默认「最新在前」，这里默认翻成「从旧到新」。
  /// 切换只重排已加载的页，不重新取数（避免丢掉用户的滚动位置）。
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

  /// 统一的取数入口：章节模式走 `chapterCommentsLoader`，作品模式走
  /// `commentsLoader`。两处调用（首屏 / 加载更多）共用它，避免分叉出两套分页语义。
  Future<Res<List<Comment>>> _load(int page) {
    final epId = widget.epId;
    if (epId != null) {
      final loader = widget.source.chapterCommentsLoader;
      if (loader == null) {
        return Future.value(const Res<List<Comment>>.error("No chapter comments"));
      }
      return loader(widget.data.comicId, epId, page, widget.replyComment?.id);
    }
    final loader = widget.source.commentsLoader;
    if (loader == null) {
      return Future.value(const Res<List<Comment>>.error("No comments"));
    }
    return loader(widget.data.comicId, widget.data.subId, page, widget.replyComment?.id);
  }

  void firstLoad() async {
    if (_requestInFlight) return;
    _requestInFlight = true;
    var res = await _load(1);
    // 第一趟只为了拿服务端的 maxPage；旧→新要从最后一页开始显示。
    final serverMaxPage = res.error ? null : res.subData;
    var target = commentFirstPage(maxPage: serverMaxPage, order: _order);
    if (!res.error && target != 1) {
      res = await _load(target);
      // P68：源的 maxPage 可能高估一页（总数恰好整除页大小时历史算法就是这么
      // 算的），拿尾页请求会得到空列表 → 界面上只剩排序条 + 转圈。逐页回退到
      // 有数据为止，避免"看起来一直在加载"。
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
    if (res.error) {
      setState(() {
        _error = res.errorMessage;
        _loading = false;
      });
    } else if (mounted) {
      var filteredComments = res.data.where((c) => !_shouldBlockComment(c)).toList();
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
    if (next == null) return;
    if (_requestInFlight) return;
    _requestInFlight = true;
    var res = await _load(next);
    _requestInFlight = false;
    if (res.error) {
      context.showMessage(message: res.errorMessage ?? "Unknown Error");
    } else if (mounted) {
      var filteredComments = res.data.where((c) => !_shouldBlockComment(c)).toList();
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
    final body = buildBody(context);
    if (widget.embedded) return body;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: Appbar(
        title: Text("Comments".tl),
        style: AppbarStyle.shadow,
      ),
      body: body,
    );
  }

  Widget buildBody(BuildContext context) {
    if (_loading) {
      firstLoad();
      return const Center(
        child: CircularProgressIndicator(),
      );
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
                            _CommentTile(
                              comment: widget.replyComment!,
                              source: widget.source,
                              comic: widget.data,
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
                              child: Text(
                                "Replies".tl,
                                style: ts.s18,
                              ),
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

                    return _CommentTile(
                      comment: _comments![index],
                      source: widget.source,
                      comic: widget.data,
                      showAvatar: showAvatar,
                    );
                  },
                );
              },
            ),
          ),
          buildBottom(context)
        ],
      );
    }
  }

  Widget buildBottom(BuildContext context) {
    final epId = widget.epId;
    final canSend = epId != null
        ? widget.source.sendChapterCommentFunc != null
        : widget.source.sendCommentFunc != null;
    if (!canSend) {
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
                    hintText: "Comment".tl),
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
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                  ),
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
                  var b = epId != null
                      ? await widget.source.sendChapterCommentFunc!(
                          widget.data.comicId,
                          epId,
                          controller.text,
                          widget.replyComment?.id,
                        )
                      : await widget.source.sendCommentFunc!(
                          widget.data.comicId,
                          widget.data.subId,
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
              )
          ],
        ).paddingLeft(16).paddingRight(4),
      ),
    );
  }
}

class _CommentTile extends StatefulWidget {
  const _CommentTile({
    required this.comment,
    required this.source,
    required this.comic,
    required this.showAvatar,
    this.showActions = true,
  });

  final Comment comment;

  final ComicSource source;

  final ComicDetails comic;

  final bool showAvatar;

  final bool showActions;

  @override
  State<_CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends State<_CommentTile> {
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
                  color: Theme.of(context).colorScheme.secondaryContainer),
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
          )
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
          if (widget.comment.replyCount != null) buildReply(),
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
          showSideBar(
            context,
            CommentsPage(
              data: widget.comic,
              source: widget.source,
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
            widget.comic.comicId,
            widget.comic.subId,
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
      widget.comic.comicId,
      widget.comic.subId,
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
