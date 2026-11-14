part of 'reader.dart';

const _readerChromeAnimationDuration = Duration(milliseconds: 140);

class _ReaderScaffold extends StatefulWidget {
  const _ReaderScaffold({required this.child});

  final Widget child;

  @override
  State<_ReaderScaffold> createState() => _ReaderScaffoldState();
}

class _ReaderScaffoldState extends State<_ReaderScaffold> {
  bool get isReversed =>
      context.reader.mode == ReaderMode.galleryRightToLeft ||
      context.reader.mode == ReaderMode.continuousRightToLeft;

  _ReaderGestureDetectorState? _gestureDetectorState;

  /// P56：桌面专属控件统一读这个开关，不再各自散读 `App.isDesktop`。
  /// `readerLayoutMode = auto` 时按平台 + 窗宽推断；显式值可强制覆盖。
  bool get desktopLayout => isDesktopReaderLayout(
    setting: appdata.settings[kReaderLayoutSettingKey],
    desktopPlatform: App.isDesktop,
    windowWidth: context.width,
  );

  _DragListener? _imageFavoriteDragListener;

  /// 桌面布局下缩放簇常驻（comix.to 右下百分比 + ±）；旧的 opt-in 开关
  /// 仍作为移动端布局 / 非桌面平台下的可选增强。
  bool get zoomBarEnabled =>
      desktopLayout ||
      (App.isDesktop && appdata.settings['readerShowZoomBar'] == true);

  bool _zoomBarVisible = false;

  Timer? _zoomBarTimer;

  /// Called on any pointer activity over the page: the cluster fades in and
  /// disappears again after 2s of stillness, so it never competes with the art.
  void pokeZoomBar() {
    if (!zoomBarEnabled) return;
    _zoomBarTimer?.cancel();
    _zoomBarTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _zoomBarVisible = false);
    });
    if (_zoomBarVisible) return;
    setState(() => _zoomBarVisible = true);
  }

  void addDragListener() async {
    if (!mounted) return;

    // 横向阅读的时候, 如果纵向滑就触发收藏, 纵向阅读的时候, 如果横向滑动就触发收藏
    if (appdata.settings['quickCollectImage'] == 'Swipe') {
      if (_imageFavoriteDragListener == null) {
        double crossAxisDistance = 0;
        double mainAxisDistance = 0;
        bool startedAtEdge = false;
        bool startedZoomed = false;
        // 系统返回手势（iOS 滑动返回、安卓手势导航）从屏幕左右边缘起始；
        // 该区域起始的拖动不参与滑动收藏判定，否则返回手势会被误认成收藏。
        const edgeExclusion = 44.0;
        _imageFavoriteDragListener = _DragListener(
          onStart: (point) {
            crossAxisDistance = 0;
            mainAxisDistance = 0;
            var width = context.reader.size.width;
            startedAtEdge =
                point.dx < edgeExclusion || point.dx > width - edgeExclusion;
            // 图片放大后单指拖动是平移图片，不应被判成滑动收藏（#143）。
            startedZoomed =
                context.reader._imageViewController?.isImageZoomed ?? false;
          },
          onMove: (offset) {
            // 每次读取当前阅读模式：监听器只注册一次，若捕获创建时的模式，
            // 阅读中途切换方向后收藏手势的轴向判断会一直沿用旧模式。
            switch (context.reader.mode) {
              case ReaderMode.continuousTopToBottom:
              case ReaderMode.galleryTopToBottom:
                crossAxisDistance += offset.dx;
                mainAxisDistance += offset.dy;
              case ReaderMode.continuousLeftToRight:
              case ReaderMode.galleryLeftToRight:
              case ReaderMode.galleryRightToLeft:
              case ReaderMode.continuousRightToLeft:
                crossAxisDistance += offset.dy;
                mainAxisDistance += offset.dx;
            }
          },
          onEnd: () {
            // 除跨轴位移达标外，还要求整段手势明显以跨轴为主：长距离翻页/滚动
            // 里的斜向漂移（主轴位移远大于跨轴）不应触发收藏。放大状态下（拖动=
            // 平移图片）整段手势不参与收藏判定。
            final zoomedNow =
                context.reader._imageViewController?.isImageZoomed ?? false;
            if (!startedAtEdge &&
                !startedZoomed &&
                !zoomedNow &&
                crossAxisDistance.abs() > 150 &&
                crossAxisDistance.abs() > mainAxisDistance.abs() * 2) {
              addImageFavorite();
            }
            crossAxisDistance = 0;
            mainAxisDistance = 0;
          },
        );
      }
      _gestureDetectorState!.addDragListener(_imageFavoriteDragListener!);
    } else if (_imageFavoriteDragListener != null) {
      _gestureDetectorState!.removeDragListener(_imageFavoriteDragListener!);
    }
  }

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 200), addDragListener);
  }

  @override
  void dispose() {
    _zoomBarTimer?.cancel();
    // The orientation lock belongs to the reader only: hand the device back to
    // the platform default so other pages stay unaffected.
    if (rotation != null) {
      SystemChrome.setPreferredOrientations(resolveReadingOrientations(null));
    }
    super.dispose();
  }

  /// Reader-only orientation lock: null follows the device, false locks
  /// portrait, true locks landscape. Reverted in [dispose].
  bool? rotation;

  void update() {
    setState(() {});
  }

  /// Eid of the chapter whose missing-pages banner the user dismissed with
  /// "Later". Null until dismissed. Lets the banner reappear for a *different*
  /// incomplete chapter but stay hidden for the one the user chose to ignore.
  String? _dismissedMissingEid;

  /// Count of pages missing from the chapter currently open, from
  /// `missing_pages.json` (P5/S2). 0 when the chapter is complete or the comic
  /// isn't stored locally.
  int _missingInCurrentChapter() {
    final reader = context.reader;
    final local = LocalManager().find(reader.widget.cid, reader.type);
    if (local == null) return 0;
    // 与下载侧同一个函数：目录名规则分叉会让"缺页"标记永远查不到。
    // 语义匹配（D1）兼容目录名带/不带 `[站点]` 两种写法。
    final dir = chapterDirectoryName(reader.widget.chapters, reader.eid);
    return MissingPages.peek(local.baseDir)?.countOfChapterFuzzy(dir) ?? 0;
  }

  /// One-time, dismissible notice shown when the reader opens an incomplete
  /// chapter (P5/S3-b). Does not block reading — "Later" hides it for this
  /// chapter; navigating to another missing chapter shows it again.
  Widget _buildMissingBanner(BuildContext context, int count) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            context.padding.left + 12,
            8,
            context.padding.right + 8,
            8,
          ),
          child: Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: cs.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "This chapter is missing @a pages. Repair later from details."
                      .tlParams({"a": count}),
                  style: ts.s12.withColor(cs.onErrorContainer),
                ),
              ),
              TextButton(
                onPressed: () {
                  final local = LocalManager().find(
                    context.reader.cid,
                    context.reader.type,
                  );
                  if (local != null) {
                    RepairDownloadTask.repairChapter(
                      local,
                      chapterDirectoryName(
                        context.reader.widget.chapters,
                        context.reader.eid,
                      ),
                    );
                  }
                  setState(() {
                    _dismissedMissingEid = context.reader.eid;
                  });
                },
                child: Text(
                  "Repair chapter".tl,
                  style: TextStyle(color: cs.onErrorContainer),
                ),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _dismissedMissingEid = context.reader.eid;
                }),
                child: Text(
                  "Later".tl,
                  style: TextStyle(color: cs.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 左缘页轨：桌面布局常驻（用户明确要求「页面树保留在左下/左缘」），
  /// 移动端布局左缘属于系统返回手势，只在显式设置了 'left' 时显示。
  bool get pageRailEnabled =>
      desktopLayout ||
      (App.isDesktop &&
          appdata.settings['readerProgressBarPosition'] == 'left');

  void toggleReadingOrientation() {
    setState(() {
      rotation = nextReadingOrientation(rotation);
    });
    SystemChrome.setPreferredOrientations(resolveReadingOrientations(rotation));
  }

  @override
  Widget build(BuildContext context) {
    final isOnChapterCommentsPage = context.reader.isOnChapterCommentsPage;
    final reader = context.reader;
    // R4-2 / R4-3：两个新滤镜都读漫画级 → 设备级 → 全局三级回落，与其余
    // 阅读设置保持一致。
    final greyscale = readerGreyscaleEnabled(
      appdata.settings.getReaderSetting(
        reader.cid,
        reader.type.sourceKey,
        'readerGreyscale',
      ),
    );
    final dim = readerDimStrength(
      appdata.settings.getReaderSetting(
        reader.cid,
        reader.type.sourceKey,
        'readerDimStrength',
      ),
    );
    return Stack(
      children: [
        Positioned.fill(
          child: AbsorbPointer(
            absorbing: context.reader.isPageAnimating,
            // R4-2 一键灰度。滤镜挂在"图片区"这一层而不是逐张图片上：
            // gallery 的单图走 `imageProvider` 路径（PhotoView 内部自己建
            // Image，没有可以插入的 child 包装点），硬改会牵动初值缩放与
            // maxScale 的语义；挂在整层则两种模式、所有页一视同仁。
            // 已知取舍：章尾导航卡与章末评论页同属这一层，开启灰度时也会
            // 一并去色（文字仍可读，只是饱和度归零）。
            child: greyscale
                ? ColorFiltered(
                    colorFilter: kReaderGreyscaleFilter,
                    child: widget.child,
                  )
                : widget.child,
          ),
        ),
        // Translucent: the hover is reported to this region *and* still reaches
        // the reader underneath, so the zoom cluster wakes on any mouse
        // movement without stealing a single gesture.
        if (zoomBarEnabled)
          Positioned.fill(
            child: MouseRegion(
              // Not opaque: the hover is reported here *and* the event still
              // reaches the reader underneath, so the cluster wakes on any
              // mouse movement without stealing a gesture.
              opaque: false,
              onHover: (_) => pokeZoomBar(),
              child: const SizedBox.expand(),
            ),
          ),
        // 全局三档外观（白天/夜间/护眼）已在 App 设置与阅读器底栏切换按钮，
        // 旧的阅读器夜间遮罩（readerNightMode 暖色叠加）已移除，避免与全局
        // 暗色主题重复。
        // R4-3 压暗。与已删除的夜间遮罩是两套东西：压暗只降亮度不换色，可单开，
        // 亦可叠加在全局暗色主题之上。护眼相关的档位仍在设置里归到同一分组。
        if (dim > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(color: Colors.black.toOpacity(dim)),
            ),
          ),
        if (appdata.settings['showPageNumberInReader'] == true &&
            !isOnChapterCommentsPage)
          buildPageInfoText(),
        // P56：右下 58×58 浮动箭头按钮已删除，腾出的位置放常驻缩放簇。
        // 桌面布局下不再靠 hover 唤起（comix.to 的百分比 + ± 是常驻的）。
        // P57.2：时钟/电量与缩放簇合成同一行右对齐 —— 两者共用一条中线，
        // 不再各写一个 `bottom` 互相错位。
        if (!isOnChapterCommentsPage)
          Positioned(
            right: 12,
            bottom: context.padding.bottom + 12,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (appdata.settings['enableClockAndBatteryInfoInReader'] ==
                    true) ...[
                  buildStatusInfo(),
                  const SizedBox(width: 10),
                ],
                if (zoomBarEnabled)
                  ReaderZoomBar(visible: desktopLayout || _zoomBarVisible),
              ],
            ),
          ),
        // 左上角极简返回钮：顶栏已删除，但退出阅读器必须保留入口。
        // 与右上章节簇 / 右下缩放簇同一套「纯透明底 + 主题轮廓线」样式。
        Positioned(
          top: context.padding.top + 8,
          left: context.padding.left + 8,
          child: RepaintBoundary(
            child: IconButton(
              tooltip: "Back".tl,
              icon: Icon(
                Icons.arrow_back,
                color: context.colorScheme.onSurface,
              ),
              style: IconButton.styleFrom(
                backgroundColor: Colors.transparent,
                side: BorderSide(
                  color: context.colorScheme.outline.withValues(alpha: 0.55),
                ),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                ),
              ),
              onPressed: () => Navigator.maybePop(context),
            ),
          ),
        ),
        // 常驻右上角控件簇（桌面 / 有章节时）：章节胶囊 + 外观切换 + 更多菜单
        // + 设置，独立于任何顶栏，始终可见（P57/P57.x：章节框正常显示在右上角）。
        if (desktopLayout && context.reader.widget.chapters != null)
          Positioned(
            top: context.padding.top + 8,
            right: context.padding.right + 8,
            child: RepaintBoundary(child: _buildTopRightCluster()),
          ),
        if (_missingInCurrentChapter() > 0 &&
            _dismissedMissingEid != context.reader.eid)
          Positioned(
            top: context.padding.top,
            left: 0,
            right: 0,
            child: _buildMissingBanner(context, _missingInCurrentChapter()),
          ),
        // R5 可选右缘竖工具栏：从右缘滑入，垂直居中，与顶/底栏并存。
        Positioned(
          right: 10,
          top: 0,
          bottom: 0,
          child: Center(child: ReaderSideToolbar()),
        ),
        // 左缘页轨：图层上移为最顶层（浮动控件），自左缘向右展开。
        if (pageRailEnabled)
          AnimatedPositioned(
            duration: _readerChromeAnimationDuration,
            left: 0,
            // 收缩时仅贴左缘细条；展开时浮现面板并向右生长，不占用画布。
            top: 0,
            bottom: 0,
            width: kPageRailWidth,
            child: const RepaintBoundary(child: ReaderPageRail()),
          ),
      ],
    );
  }

  /// 桌面常驻右上角控件簇：外观切换（白天/夜间/护眼）+ 章节胶囊
  /// （‹ Ch.n / N ›）+ 更多菜单 + 设置。顶/底工具栏已移除（P57.x），
  /// 这些控件直接常驻于右上角，始终可见。
  Widget _buildTopRightCluster() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const ReaderAppearanceToggle(),
        const ChapterCapsule(),
        MenuButton(entries: buildMoreMenuEntries()),
        Tooltip(
          message: "Settings".tl,
          child: IconButton(
            icon: const Icon(Icons.settings),
            onPressed: openSetting,
          ),
        ),
      ],
    );
  }

  bool isLiked() {
    return ImageFavoriteManager().has(
      context.reader.cid,
      context.reader.type.sourceKey,
      context.reader.eid,
      context.reader.page,
      context.reader.chapter,
    );
  }

  /// Whether the in-reader download button should show: only for online source
  /// comics (not local ones, whose images are file:// paths) that aren't already
  /// fully downloaded, and whose source can actually download (#16).
  bool canDownloadFromReader() {
    final reader = context.reader;
    if (reader.type == ComicType.local) return false;
    final source = ComicSource.find(reader.type.sourceKey);
    if (source == null || source.loadComicPages == null) return false;
    final images = reader.images;
    if (images != null && images.isNotEmpty && images[0].contains('file://')) {
      return false;
    }
    return true;
  }

  /// Queue a download from inside the reader. For a multi-chapter comic this
  /// downloads the chapter currently open; for a single-chapter comic it
  /// downloads the whole thing. Mirrors the dedup checks the detail page uses
  /// so tapping it twice is harmless (#16).
  void downloadFromReader() async {
    final reader = context.reader;
    final source = ComicSource.find(reader.type.sourceKey);
    if (source == null) return;
    final chapters = reader.widget.chapters;

    if (chapters == null) {
      // Single-chapter comic: download the whole comic if not already done.
      if (LocalManager().isDownloading(reader.cid, reader.type) ||
          LocalManager().isDownloaded(reader.cid, reader.type, 0)) {
        showToast(message: "Already downloaded".tl, context: context);
        return;
      }
      if (!await ensureDownloadStorageWritable()) return;
      LocalManager().addTask(
        ImagesDownloadTask(
          source: source,
          comicId: reader.cid,
          comicTitle: reader.widget.name,
        ),
      );
      if (!mounted) return;
      showToast(message: "Download started".tl, context: context);
      return;
    }

    // Multi-chapter: download just the chapter currently being read.
    final eid = reader.eid;
    final local = LocalManager().find(reader.cid, reader.type);
    if (local != null && local.downloadedChapters.contains(eid)) {
      showToast(message: "Already downloaded".tl, context: context);
      return;
    }
    if (LocalManager().isDownloading(reader.cid, reader.type)) {
      // A task already exists; appending a single chapter to a running task is
      // out of scope here, so point the user at the queue instead of silently
      // doing nothing.
      showToast(message: "The comic is downloading".tl, context: context);
      return;
    }
    if (!await ensureDownloadStorageWritable()) return;
    LocalManager().addTask(
      ImagesDownloadTask(
        source: source,
        comicId: reader.cid,
        comicTitle: reader.widget.name,
        chapters: [eid],
      ),
    );
    if (!mounted) return;
    showToast(message: "Download started".tl, context: context);
  }

  void addImageFavorite() async {
    // 章节评论页不是图片页：滑动收藏 / 双击收藏手势在此会被误触发，
    // 既没有可收藏的图片，按页码换算出的索引还会越过图片列表导致崩溃，直接忽略。
    if (context.reader.isOnChapterCommentsPage) {
      return;
    }
    try {
      if (context.reader.images![0].contains('file://')) {
        showToast(
          message: "Local comic collection is not supported at present".tl,
          context: context,
        );
        return;
      }
      String id = context.reader.cid;
      int ep = context.reader.chapter;
      String eid = context.reader.eid;
      String title = context.reader.history!.title;
      String subTitle = context.reader.history!.subtitle;
      int maxPage = context.reader.images!.length;
      int? page = await selectImage();
      if (page == null) return;
      page += 1;
      String sourceKey = context.reader.type.sourceKey;
      String imageKey = context.reader.images![page - 1];
      List<String> tags = context.reader.widget.tags;
      String author = context.reader.widget.author;

      var epName =
          context.reader.widget.chapters?.titles.elementAtOrNull(
            context.reader.chapter - 1,
          ) ??
          "E${context.reader.chapter}";
      var translatedTags = tags.map((e) => e.translateTagsToCN).toList();

      if (isLiked()) {
        ImageFavoriteManager().deleteImageFavorite([
          ImageFavorite(page, imageKey, null, eid, id, ep, sourceKey, epName),
        ]);
        showToast(
          message: "Uncollected the image".tl,
          context: context,
          seconds: 1,
        );
      } else {
        var imageFavoritesComic =
            ImageFavoriteManager().find(id, sourceKey) ??
            ImageFavoritesComic(
              id,
              [],
              title,
              sourceKey,
              tags,
              translatedTags,
              DateTime.now(),
              author,
              {},
              subTitle,
              maxPage,
            );
        ImageFavorite imageFavorite = ImageFavorite(
          page,
          imageKey,
          null,
          eid,
          id,
          ep,
          sourceKey,
          epName,
        );
        ImageFavoritesEp? imageFavoritesEp = imageFavoritesComic
            .imageFavoritesEp
            .firstWhereOrNull((e) {
              return e.ep == ep;
            });
        if (imageFavoritesEp == null) {
          if (page != firstPage &&
              appdata.settings['autoFavoriteCover'] == true) {
            var copy = imageFavorite.copyWith(
              page: firstPage,
              isAutoFavorite: true,
              imageKey: context.reader.images![0],
            );
            // 不是第一页且开启了自动收藏封面, 自动塞一个封面进去
            imageFavoritesEp = ImageFavoritesEp(
              eid,
              ep,
              [copy, imageFavorite],
              epName,
              maxPage,
            );
          } else {
            imageFavoritesEp = ImageFavoritesEp(
              eid,
              ep,
              [imageFavorite],
              epName,
              maxPage,
            );
          }
          imageFavoritesComic.imageFavoritesEp.add(imageFavoritesEp);
        } else {
          if (imageFavoritesEp.eid != eid) {
            // 空字符串说明是从pica导入的, 那我们就手动刷一遍保证一致
            if (imageFavoritesEp.eid == "") {
              imageFavoritesEp.eid == eid;
            } else {
              // 避免多章节漫画源的章节顺序发生变化, 如果情况比较多, 做一个以eid为准更新ep的功能
              showToast(
                message:
                    "The chapter order of the comic may have changed, temporarily not supported for collection"
                        .tl,
                context: context,
              );
              return;
            }
          }
          imageFavoritesEp.imageFavorites.add(imageFavorite);
        }

        ImageFavoriteManager().addOrUpdateOrDelete(imageFavoritesComic);
        showToast(
          message: "Successfully collected".tl,
          context: context,
          seconds: 1,
        );
      }
      update();
    } catch (e, stackTrace) {
      Log.error("Image Favorite", e, stackTrace);
      showToast(message: e.toString(), context: context, seconds: 1);
    }
  }

  /// Low-frequency actions, folded into the top bar's menu to keep both bars
  /// short: chapter download, desktop fullscreen and share.
  List<MenuEntry> buildMoreMenuEntries() {
    return [
      if (canDownloadFromReader())
        MenuEntry(
          icon: Icons.download_outlined,
          text: "Download".tl,
          onClick: downloadFromReader,
        ),
      if (App.isDesktop)
        MenuEntry(
          icon: Icons.fullscreen,
          text: "${"Full Screen".tl}(F12)",
          onClick: () => context.reader.fullscreen(),
        ),
      MenuEntry(icon: Icons.share, text: "Share".tl, onClick: share),
    ];
  }

  // P57.x：顶/底工具栏已移除，原 buildBottom / buildSlider 一并删除。

  Widget buildPageInfoText() {
    var epName =
        context.reader.widget.chapters?.titles.elementAtOrNull(
          context.reader.chapter - 1,
        ) ??
        "E${context.reader.chapter}";
    if (epName.length > 8) {
      epName = "${epName.substring(0, 8)}...";
    }
    var pageText = "${context.reader.page}/${context.reader.maxPage}";
    var text = context.reader.widget.chapters != null
        ? "$epName : $pageText"
        : pageText;

    return Positioned(
      bottom: 13,
      left: 25,
      child: Stack(
        children: [
          Text(
            text,
            style: TextStyle(
              fontSize: 14,
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.4
                ..color = context.colorScheme.onInverseSurface,
            ),
          ),
          Text(text),
        ],
      ),
    );
  }

  /// 时钟 + 电量：作为右下角簇的左半部分，与缩放簇共用一行、同一中线。
  /// 字号收到 13（与缩放簇百分比读数一致），高度靠 `crossAxisAlignment.center`
  /// 与 34dp 的缩放簇胶囊对齐。
  Widget buildStatusInfo() {
    if (appdata.settings['enableClockAndBatteryInfoInReader'] != true) {
      return const SizedBox.shrink();
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _ClockWidget(),
        const SizedBox(width: 8),
        _BatteryWidget(),
      ],
    );
  }

  void openChapterDrawer() {
    final chapters = context.reader.widget.chapters;
    if (chapters == null) return;
    final body = chapters.isGrouped
        ? _GroupedChaptersView(context.reader)
        : _ChaptersView(context.reader);
    if (!desktopLayout) {
      _openSideBar(body, width: 400);
      return;
    }
    // P56 / comix.to 实测：右上角胶囊是**入口**，点开的是居中模态
    // （约 555×480 + 全屏遮罩），不是右上角锚定的下拉浮层。
    showDialog(
      context: context,
      builder: (dialogContext) => ContentDialog(
        title: "Chapter list".tl,
        content: SizedBox(width: 555, height: 480, child: body),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text("Close".tl),
          ),
        ],
      ),
    );
  }

  void saveCurrentImage() async {
    var result = await selectImageToData();
    if (result == null) {
      return;
    }
    var (imageIndex, data) = result;
    var fileType = detectFileType(data);
    // Save file name: ComicName_EP{chapter}_P{page}.{ext} to avoid conflict.
    // The chapter index of different group is continuous, so we use chapter number is enough.
    var filename =
        "${context.reader.widget.name}_EP${context.reader.chapter}_P${imageIndex + 1}${fileType.ext}";
    saveFile(data: data, filename: filename);
  }

  void share() async {
    var result = await selectImageToData();
    if (result == null) {
      return;
    }
    var (imageIndex, data) = result;
    var fileType = detectFileType(data);
    var filename =
        "${context.reader.widget.name}_EP${context.reader.chapter}_P${imageIndex + 1}${fileType.ext}";
    Share.shareFile(data: data, filename: filename, mime: fileType.mime);
  }

  void openSetting() {
    _openSideBar(
      ReaderSettings(
        comicId: context.reader.cid,
        comicSource: context.reader.type.sourceKey,
        // 🔴 S9.5-b：翻译开关是**每章**的，面板必须知道是哪一章。推导与
        // `images.dart::_createImageProviderFromKey` 逐字同源（章节目录表的
        // ids，无章节的漫画是 `'0'`）—— 两处不一致会让开关指向另一章的绑定。
        chapterEid: _currentChapterEid(),
        onChanged: (key) {
          if (key == "readerMode") {
            context.reader.mode = ReaderMode.fromKey(
              appdata.settings.getReaderSetting(
                context.reader.cid,
                context.reader.type.sourceKey,
                key,
              ),
            );
          }
          if (key == "enableTurnPageByVolumeKey") {
            if (appdata.settings.getReaderSetting(
              context.reader.cid,
              context.reader.type.sourceKey,
              key,
            )) {
              context.reader.handleVolumeEvent();
            } else {
              context.reader.stopVolumeEvent();
            }
          }
          if (key == "quickCollectImage") {
            addDragListener();
          }
          if (key == "showSystemStatusBar") {
            final showSystemStatusBar =
                appdata.settings.getReaderSetting(
                  context.reader.cid,
                  context.reader.type.sourceKey,
                  key,
                ) ==
                true;
            applyReaderSystemUiMode(showSystemStatusBar);
          }
          if (key == "showChapterComments" ||
              key == "showChapterCommentsAtEnd") {
            update();
          }
          // Changing this comic's language pair or text-removal mode addresses a
          // different translation cache generation, but the image providers are
          // keyed on the page identity alone — without dropping them the reader
          // would keep showing the render made with the previous settings.
          if (key == "imageTranslationSource" ||
              key == "imageTranslationTarget" ||
              key == "imageTranslationInpaintMode" ||
              key == "enableImageTranslation") {
            PaintingBinding.instance.imageCache.clear();
            PaintingBinding.instance.imageCache.clearLiveImages();
          }
          context.reader.update();
        },
      ),
      width: 400,
    );
  }

  /// 当前这一章的 eid，与 `images.dart::_createImageProviderFromKey` 逐字同源。
  ///
  /// 无章节的漫画（`chapters == null`）恒为 `'0'` —— 与下载任务、任务列表里
  /// 的用法一致（那里也是拿 `'0'` 当一个"整本只有一章"的 id）。
  String _currentChapterEid() {
    final reader = context.reader;
    return reader.widget.chapters?.ids.elementAtOrNull(reader.chapter - 1) ??
        '0';
  }

  void _openSideBar(Widget widget, {double width = 400}) {
    _gestureDetectorState?.ignoreNextTap();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showSideBar(
        context,
        widget,
        width: width,
        dismissible: true,
      ).whenComplete(() {
        _gestureDetectorState?.clearIgnoreNextTap();
      });
    });
  }

  bool shouldShowChapterComments() {
    // Check if chapters exist
    if (context.reader.widget.chapters == null) return false;

    // Check if setting is enabled
    var showChapterComments = appdata.settings.getReaderSetting(
      context.reader.cid,
      context.reader.type.sourceKey,
      'showChapterComments',
    );
    if (showChapterComments != true) return false;

    // Check if comic source supports chapter comments
    var source = ComicSource.find(context.reader.type.sourceKey);
    if (source == null || source.chapterCommentsLoader == null) return false;

    return true;
  }

  void openChapterComments() {
    var source = ComicSource.find(context.reader.type.sourceKey);
    if (source == null) return;

    var chapters = context.reader.widget.chapters;
    if (chapters == null) return;

    var chapterIndex = context.reader.chapter - 1;
    var epId = chapters.ids.elementAt(chapterIndex);
    var chapterTitle = chapters.titles.elementAt(chapterIndex);

    showSideBar(
      context,
      ChapterCommentsPage(
        comicId: context.reader.cid,
        epId: epId,
        source: source,
        comicTitle: context.reader.widget.name,
        chapterTitle: chapterTitle,
      ),
    );
  }

  /// If there is only one image on screen, return it.
  ///
  /// If there are multiple images on screen,
  /// show an overlay to let the user select an image.
  ///
  /// The return value is the index of the selected image.
  Future<int?> selectImage() async {
    var reader = context.reader;
    var imageViewController = context.reader._imageViewController;

    bool needsSelection = false;
    int? singleImageIndex;

    if (imageViewController is _GalleryModeState) {
      var range = imageViewController.getCurrentPageImageRange();
      if (range != null) {
        var (startIndex, endIndex) = range;
        int actualImageCount = endIndex - startIndex;
        if (actualImageCount == 1) {
          needsSelection = false;
          singleImageIndex = startIndex;
        } else {
          needsSelection = true;
        }
      }
    } else if (imageViewController is _ContinuousModeState) {
      needsSelection = false;
      singleImageIndex = reader.page - 1;
    }

    if (!needsSelection && singleImageIndex != null) {
      return singleImageIndex;
    } else {
      var location = await _showSelectImageOverlay();
      if (location == null) {
        return null;
      }
      var imageKey = imageViewController!.getImageKeyByOffset(location);
      if (imageKey == null) {
        return null;
      }
      return reader.images!.indexOf(imageKey);
    }
  }

  /// Same as [selectImage], but return the image data with its index.
  /// Returns (imageIndex, imageData) or null if cancelled.
  Future<(int, Uint8List)?> selectImageToData() async {
    var i = await selectImage();
    if (i == null) {
      return null;
    }
    var imageKey = context.reader.images![i];
    Uint8List data;
    if (imageKey.startsWith("file://")) {
      data = await File(imageKey.substring(7)).readAsBytes();
    } else {
      final cache = await CacheManager().findCache(
        "$imageKey@${context.reader.type.sourceKey}@${context.reader.cid}@${context.reader.eid}",
      );
      if (cache == null) {
        return null;
      }
      data = await cache.readAsBytes();
    }
    return (i, data);
  }

  Future<Offset?> _showSelectImageOverlay() {
    var completer = Completer<Offset?>();

    var overlay = Overlay.of(context);
    OverlayEntry? entry;
    entry = OverlayEntry(
      builder: (context) {
        return Positioned.fill(
          child: _SelectImageOverlayContent(
            onTap: (offset) {
              completer.complete(offset);
              entry!.remove();
            },
            onDispose: () {
              if (!completer.isCompleted) {
                completer.complete(null);
              }
            },
          ),
        );
      },
    );
    overlay.insert(entry);

    return completer.future;
  }
}

class _BatteryWidget extends StatefulWidget {
  @override
  _BatteryWidgetState createState() => _BatteryWidgetState();
}

class _BatteryWidgetState extends State<_BatteryWidget> {
  late Battery _battery;
  late int _batteryLevel = 100;
  Timer? _timer;
  bool _hasBattery = false;
  BatteryState state = BatteryState.unknown;

  @override
  void initState() {
    super.initState();
    _battery = Battery();
    _checkBatteryAvailability();
  }

  void _checkBatteryAvailability() async {
    try {
      _batteryLevel = await _battery.batteryLevel;
      if (!mounted) return;
      state = await _battery.batteryState;
      if (!mounted) return;
      if (_batteryLevel > 0 && state != BatteryState.unknown) {
        setState(() {
          _hasBattery = true;
        });
        _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
          _battery.batteryLevel.then((level) {
            if (!mounted) return;
            if (_batteryLevel != level) {
              setState(() {
                _batteryLevel = level;
              });
            }
          });
        });
      }
    } catch (_) {
      // ignore
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasBattery) {
      return const SizedBox.shrink(); //Empty Widget
    }
    return _batteryInfo(_batteryLevel);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _batteryInfo(int batteryLevel) {
    IconData batteryIcon;
    Color batteryColor = context.colorScheme.onSurface;

    if (state == BatteryState.charging) {
      batteryIcon = Icons.battery_charging_full;
    } else if (batteryLevel >= 96) {
      batteryIcon = Icons.battery_full_sharp;
    } else if (batteryLevel >= 84) {
      batteryIcon = Icons.battery_6_bar_sharp;
    } else if (batteryLevel >= 72) {
      batteryIcon = Icons.battery_5_bar_sharp;
    } else if (batteryLevel >= 60) {
      batteryIcon = Icons.battery_4_bar_sharp;
    } else if (batteryLevel >= 48) {
      batteryIcon = Icons.battery_3_bar_sharp;
    } else if (batteryLevel >= 36) {
      batteryIcon = Icons.battery_2_bar_sharp;
    } else if (batteryLevel >= 24) {
      batteryIcon = Icons.battery_1_bar_sharp;
    } else if (batteryLevel >= 12) {
      batteryIcon = Icons.battery_0_bar_sharp;
    } else {
      batteryIcon = Icons.battery_alert_sharp;
      batteryColor = Colors.red;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(
          batteryIcon,
          size: 15,
          color: batteryColor,
          // Stroke
          shadows: List.generate(9, (index) {
            if (index == 4) {
              return null;
            }
            double offsetX = (index % 3 - 1) * 0.8;
            double offsetY = ((index / 3).floor() - 1) * 0.8;
            return Shadow(
              color: context.colorScheme.onInverseSurface,
              offset: Offset(offsetX, offsetY),
            );
          }).whereType<Shadow>().toList(),
        ),
        Stack(
          children: [
            Text(
              '$batteryLevel%',
              style: TextStyle(
                fontSize: 13,
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 1.4
                  ..color = context.colorScheme.onInverseSurface,
              ),
            ),
            Text('$batteryLevel%', style: const TextStyle(fontSize: 13)),
          ],
        ),
      ],
    );
  }
}

class _ClockWidget extends StatefulWidget {
  @override
  _ClockWidgetState createState() => _ClockWidgetState();
}

class _ClockWidgetState extends State<_ClockWidget> {
  late String _currentTime;
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    _currentTime = _getCurrentTime();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final time = _getCurrentTime();
      if (!mounted) return;
      if (_currentTime != time) {
        setState(() {
          _currentTime = time;
        });
      }
    });
  }

  String _getCurrentTime() {
    final now = DateTime.now();
    return "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Text(
          _currentTime,
          style: TextStyle(
            // 与缩放簇百分比读数同字号，视觉上同属一行控件。
            fontSize: 13,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.4
              ..color = context.colorScheme.onInverseSurface,
          ),
        ),
        Text(_currentTime, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}

class _SelectImageOverlayContent extends StatefulWidget {
  const _SelectImageOverlayContent({
    required this.onTap,
    required this.onDispose,
  });

  final void Function(Offset) onTap;

  final void Function() onDispose;

  @override
  State<_SelectImageOverlayContent> createState() =>
      _SelectImageOverlayContentState();
}

class _SelectImageOverlayContentState
    extends State<_SelectImageOverlayContent> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        widget.onTap(details.globalPosition);
      },
      child: Container(
        color: Colors.black.withAlpha(50),
        child: Align(
          alignment: Alignment(0, -0.8),
          child: Container(
            width: 232,
            height: 42,
            decoration: BoxDecoration(
              color: context.colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.colorScheme.outlineVariant),
            ),
            child: Row(
              children: [
                const SizedBox(width: 8),
                const Icon(Icons.info_outline),
                const SizedBox(width: 16),
                Text(
                  "Click to select an image".tl,
                  style: TextStyle(
                    fontSize: 16,
                    color: context.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 阅读器的全局外观切换：单按钮弹出「白天 / 夜间 / 护眼」三选项。
/// 图标随当前档位变化，选中后写入 `theme_mode` 并全局重建（取代旧夜间模式按钮）。
///
/// 弹出面板使用项目自绘的 [MangrovePopupMenuButton]（非 Windows/原生
/// `PopupMenuButton`），与三档主题 / 护眼纸面统一。
class ReaderAppearanceToggle extends StatelessWidget {
  const ReaderAppearanceToggle({super.key});

  static const List<(String, IconData, String)> kModes = [
    ('light', Icons.wb_sunny_outlined, '白天'),
    ('dark', Icons.nightlight_round, '夜间'),
    ('sepia', Icons.visibility_outlined, '护眼'),
  ];

  @override
  Widget build(BuildContext context) {
    final mode = appdata.settings['theme_mode'] as String?;
    final colorScheme = Theme.of(context).colorScheme;
    final active = kModes.firstWhere(
      (m) => m.$1 == mode,
      orElse: () => kModes.first,
    );
    return MangrovePopupMenuButton<String>(
      tooltip: "Appearance".tl,
      icon: Icon(active.$2, color: colorScheme.onSurface),
      initialValue: mode,
      onSelected: (value) {
        appdata.settings['theme_mode'] = value;
        appdata.saveData();
        App.forceRebuild();
      },
      items: [
        for (final m in kModes)
          MangrovePopupItem(
            value: m.$1,
            leading: m.$2,
            label: m.$3,
            selected: m.$1 == mode,
          ),
      ],
    );
  }
}
