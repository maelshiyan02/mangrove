// 本地库「删除」的**二级确认弹窗**（S9.6）。
//
// ## 它补的是哪一课
//
// 旧弹窗只有一个标题 `Delete` + 两个勾选框，**不写要删的是哪一本**：
// 在磁贴菜单上误点一下，用户看到的是"删除 [x] 同时删除磁盘上的文件 [确定]"，
// 而"删除"这两个字指向的那本漫画只存在于他刚才点的那一格列表里。多选时更糟
// —— 选中 5 本之后，弹窗里没有任何一行能让他核对"我到底选了哪 5 本"。
//
// ## 🔴 三类卡片的"删除"不是同一件事
//
// 素材与成品的记录在 `local.db`，工程卡的记录**就是磁盘上的 imgtrans 文件**
// （见 `comic_deletion.dart` 头部）。所以弹窗必须：
//
// * 逐本列出**标题 + 类型 + 磁盘路径**（路径为 null 时不编一个出来）；
// * 勾选框切换时**如实改口**：不勾 = 只删记录、文件留着；勾上 = 记录与文件
//   一起删、不可恢复；
// * 选中里含工程卡时，额外说明"不勾选的话下次扫描它会回来"—— 那是工程卡
//   独有的、用户自己绝对猜不到的行为。
//
// 这三件事都是"写错不报错、只是把用户的东西删了"那一类，所以判据全放在
// `comic_deletion.dart`（能 headless 断言），本文件只负责把它摆出来。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mangrove/components/components.dart';
import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/comic_card_kind.dart';
import 'package:mangrove/foundation/comic_deletion.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/utils/translations.dart';

/// 打开二级删除确认。返回 `true` 表示确实删了（调用方据此退出多选模式）。
///
/// 弹窗**不自己执行**删除：它只收集两个选择（范围、是否连收藏/历史一起清），
/// 由本函数在弹窗关闭后执行并报一句结果 —— 这样弹窗里没有任何 async 分支，
/// "点了确定但其实没删"这类状态不可能出现。
Future<bool> showComicDeleteDialog(
  BuildContext context,
  List<LocalComic> comics,
) async {
  if (comics.isEmpty) return false;
  final choice = await showDialog<_DeleteChoice>(
    context: context,
    builder: (ctx) => _ComicDeleteDialog(comics: comics),
  );
  if (choice == null) return false;

  final report = deleteLocalComics(
    comics,
    scope: choice.scope,
    removeFavoriteAndHistory: choice.removeFavoriteAndHistory,
  );

  final root = App.rootContext;
  if (!root.mounted) return true;
  if (report.anythingRefused) {
    root.showMessage(
      message: 'Skipped @n folder(s) outside the comic library'
          .tlParams({'n': report.dirsRefused.length}),
    );
  } else if (report.dirsRemoved > 0) {
    root.showMessage(
      message: 'Deleted @n records and @m folders'.tlParams({
        'n': report.recordsRemoved,
        'm': report.dirsRemoved,
      }),
    );
  } else {
    root.showMessage(
      message: 'Deleted @n records'.tlParams({'n': report.recordsRemoved}),
    );
  }
  return true;
}

/// 弹窗的两个选择。
class _DeleteChoice {
  const _DeleteChoice({required this.scope, required this.removeFavoriteAndHistory});

  final ComicDeletionScope scope;
  final bool removeFavoriteAndHistory;
}

class _ComicDeleteDialog extends StatefulWidget {
  const _ComicDeleteDialog({required this.comics});

  final List<LocalComic> comics;

  @override
  State<_ComicDeleteDialog> createState() => _ComicDeleteDialogState();
}

class _ComicDeleteDialogState extends State<_ComicDeleteDialog> {
  /// 🔴 默认**不**删文件。这是唯一一个方向安全的默认值：勾错一次，用户的下载
  /// 或工程就没了；不勾错一次，他再删一遍记录而已（而且工程卡本来就是"只删
  /// 记录"那条路上唯一有反馈的）。
  bool _deleteFiles = false;
  bool _removeFavoriteAndHistory = true;

  bool get _hasProject => widget.comics.any(
    (c) => comicCardKindOf(c.id) == ComicCardKind.project,
  );

  /// 本次会真正落盘的目录（不存在的路径不列 —— 列出来会让用户以为磁盘上有
  /// 东西可删）。解析不出来的卡片也在这里被过滤掉，且**不编一个路径**。
  List<({LocalComic comic, String root})> get _fileTargets => [
    for (final c in widget.comics)
      if (comicOnDiskRoot(c) case final String root) (comic: c, root: root),
  ];

  String _kindLabel(ComicCardKind kind) => switch (kind) {
    ComicCardKind.downloaded => 'Artwork'.tl,
    ComicCardKind.project => 'Project'.tl,
    ComicCardKind.product => 'Published'.tl,
  };

  @override
  Widget build(BuildContext context) {
    final comics = widget.comics;
    final single = comics.length == 1;
    final ts = TextStyle();
    final targets = _fileTargets;

    return ContentDialog(
      title: single
          ? 'Delete "@title"?'.tlParams({'title': comics.first.title})
          : 'Delete @c comics?'.tlParams({'c': comics.length}),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 逐本列出：确认"删的是哪一本"的唯一依据。多选时这一列会滚。
          for (final comic in comics)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(switch (comicCardKindOf(comic.id)) {
                ComicCardKind.downloaded => Icons.local_library_outlined,
                ComicCardKind.project => Icons.translate_rounded,
                ComicCardKind.product => Icons.auto_stories_outlined,
              }),
              title: Text(comic.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${_kindLabel(comicCardKindOf(comic.id))} · '
                '${comicOnDiskRoot(comic) ?? comic.directory}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const Divider(),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _deleteFiles,
            onChanged: (v) => setState(() => _deleteFiles = v ?? false),
            title: Text('Also remove files on disk'.tl),
            subtitle: Text(
              // 🔴 单字面量。写成两个相邻字面量再对第二个调 `.tl`，Dart 解析期
              // 就拼好了，而 i18n 扫描器只看得见后半截 ⇒ 登记表里那个键永远
              // 查不到（`run_dialog.dart` 头部有完整版）。
              _deleteFiles
                  ? 'The record and the files listed below are removed. This cannot be undone.'
                        .tl
                  : 'Only the Mangrove record is removed; the files stay on disk.'
                        .tl,
            ),
          ),
          // 勾上之后把**真正会删的路径**摊开。用户点的是"删除这一本"，不该
          // 靠信任去猜我们删的是哪个目录 —— 尤其工程卡的 `c.directory` 是内部
          // 的 `source/` 副本，而实际删的是它上一层。
          if (_deleteFiles)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final t in targets)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '• ${t.root}',
                        style: ts.s12,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (targets.isEmpty)
                    Text('No files to delete for the selection.'.tl, style: ts.s12),
                  // 🔴 工程卡独有：它的记录**就是**磁盘上那个 imgtrans 文件。
                  if (_hasProject)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'A project is registered from its imgtrans file on disk, so it comes back on the next scan unless you also delete the files.'
                            .tl,
                        style: ts.s12,
                      ),
                    ),
                ],
              ),
            ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _removeFavoriteAndHistory,
            onChanged: (v) =>
                setState(() => _removeFavoriteAndHistory = v ?? false),
            title: Text('Remove local favorite and history'.tl),
          ),
        ],
      ),
      actions: [
        // 单章删除只对单本有意义，且工程卡没有"章节"这个概念（它的章节是
        // json 里的，不是下载出来的）。
        if (comics.length == 1 &&
            comics.first.hasChapters &&
            !_hasProject)
          Button.text(
            onPressed: () {
              final target = comics.first;
              Navigator.pop(context);
              showDeleteChaptersPopWindow(App.rootContext, target);
            },
            child: Text('Delete Chapters'.tl),
          ),
        Button.text(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel'.tl),
        ),
        Button.filled(
          onPressed: () => Navigator.pop(
            context,
            _DeleteChoice(
              scope: _deleteFiles
                  ? ComicDeletionScope.recordsAndFiles
                  : ComicDeletionScope.recordsOnly,
              removeFavoriteAndHistory: _removeFavoriteAndHistory,
            ),
          ),
          child: Text('Delete'.tl),
        ),
      ],
    );
  }
}

/// 「删除章节」的二级面板 —— 只删某一本里的**几章**，整本保留。
///
/// 从 `local_comics_page.dart` 搬到本文件：它是删除流程的一个分支，而删除流程
/// 现在整体在这里（原来它留在页面里，弹窗与本函数被两个文件分着，改一个忘一个）。
void showDeleteChaptersPopWindow(BuildContext context, LocalComic comic) {
  var chapters = <String>[];

  showPopUpWidget(
    context,
    PopUpWidgetScaffold(
      title: "Delete Chapters".tl,
      body: StatefulBuilder(
        builder: (context, setState) {
          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  itemCount: comic.downloadedChapters.length,
                  itemBuilder: (context, index) {
                    var id = comic.downloadedChapters[index];
                    var chapter = comic.chapters![id] ?? "Unknown Chapter";
                    return CheckboxListTile(
                      title: Text(chapter),
                      value: chapters.contains(id),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            chapters.add(id);
                          } else {
                            chapters.remove(id);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton(
                      onPressed: () {
                        Future.delayed(const Duration(milliseconds: 200), () {
                          LocalManager().deleteComicChapters(comic, chapters);
                        });
                        App.rootContext.pop();
                      },
                      child: Text("Submit".tl),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
