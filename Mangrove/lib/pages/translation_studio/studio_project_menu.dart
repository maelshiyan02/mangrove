// 「创建翻译工程」UI 入口（S9.5-b · 追补）。
//
// ## 它补的是哪个缺口
//
// S9.5-b 之前，"把一本下载好的漫画变成工作室工程"这件事**只有**一个入口：
// 在阅读器里把某一章的"翻译"开关打开。于是：
//
// * 想先建工程、再决定翻哪几页的用户没有路可走（开关一开就是整章排队）；
// * 工程列表页在没有任何工程时只有一句"未找到翻译工程"，没有下一步；
// * `ProjectBootstrap` 这套能力层早就交付了（`A03 §4`），却只有一个开关在用。
//
// ## 🔴 它**不**自己建工程
//
// 建工程 + 写绑定这条链路只有一份实现：`StudioReaderLink.locate` +
// `ensureBinding`（阅读器开关走的也是它）。这里做的是**收集三个选择**，
// 然后把它们交给那条链路。自己再走一遍 bootstrap 的落盘那一步，就会出现
// "入口建的工程没有绑定" —— 界面上完全正常，只是阅读器永远读不到它。
//
// 由此顺带一个**有意的**行为（用户已确认保留）：建完工程会顺手写绑定，
// 于是阅读器立刻能读这一章的产物。这不是副作用，是同一个事实的两次表述
// ——"这一章由这个工程负责"。拆成两张表会让用户必须做两遍同一件事，
// 而两遍之间迟早会不一致。为了不让它**静默**发生，创建成功后会给一句
// 明确提示（见 [createStudioProject]）。
//
// ## 🔴 自己搭 Dialog 而不是用 `ContentDialog`
//
// `ContentDialog` 内部有 `IntrinsicWidth`，而本弹窗的列表是 `ListView`
// —— 视口不给内禀尺寸，`IntrinsicWidth` 会在布局期抛断言。换个固定尺寸的
// `Dialog` 既避开它，又让"标题栏 / 滚动体 / 按钮行"三段自己说了算。
//
// ## 🔴 文案纪律（P9.3 的教训）
//
// 本文件的**每一个** `'…'.tl` / `'…'.tlParams` 字面量都会被 `edit-check` 的
// `i18n.studio_tooltips_registered` 扫到（它扫整个 `pages/translation_studio/`
// 目录），并与 `assets/translation.json` 的 `zh_CN` 表核对。漏登记不会报错，
// 只会**显示英文** —— 加按钮反复栽在这上面。
//
// 两条具体纪律（`run_dialog.dart` 头部有完整版）：
// * 绝不写两个相邻字面量再对第二个调 `.tl`（Dart 解析期就拼好了，扫描匹配到
//   的是后半截 ⇒ 登记表里那个键永远不会被查到）；
// * 绝不把标签藏进 `Map` 常量（扫描看不见）。选项表在 `build()` 里现搭。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/bt_project/bt_project_manager.dart';
import 'package:mangrove/foundation/comic_card_kind.dart';
import 'package:mangrove/foundation/context.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/foundation/log.dart';
import 'package:mangrove/foundation/translation_project/project_bootstrap.dart';
import 'package:mangrove/foundation/translation_project/studio_project_entry.dart';
import 'package:mangrove/foundation/translation_project/studio_reader.dart';
import 'package:mangrove/foundation/translation_project/studio_reader_app.dart';
import 'package:mangrove/foundation/widget_utils.dart';
import 'package:mangrove/utils/translations.dart';

import 'studio_page.dart';

/// 菜单项的值。只有一个，但用 `String` 而不是 `VoidCallback`：后续加
/// "重扫工程根""从剪贴板导入"之类的动作时，只加一个 `PopupMenuItem`。
const String _createAction = 'create';

/// 「创建翻译工程」入口。挂在**三处**：工作室详细页、工程列表页、漫画详情页。
///
/// 用可展开菜单（`PopupMenuButton`）而不是一个裸按钮：后续动作往菜单里加，
/// 不必再往 `AppBar.actions` 里挤一排图标 —— 那一排已经有十来个了。
///
/// [presetComicId] 是"用户此刻正在看哪一本漫画"。给了它、且那一本**可建工程**
/// 时，向导从第 2 步（选章节）开始：在详情页里再让用户从一长串漫画里挑出自己
/// 刚刚打开的那一本，是把已经知道的事情又问一遍。
///
/// 🔴 它只是**预先选中**，不是"锁定"：第 2 步仍可【上一步】回到选漫画。这条
/// 很重要 —— 详情页那一份与另外两处**共用同一个** `_StudioProjectDialog`，
/// 差异只有开局站在第几步，所以"三处入口行为不一致"这类漂移不可能发生。
class StudioProjectMenu extends StatelessWidget {
  const StudioProjectMenu({super.key, this.presetComicId});

  final String? presetComicId;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Translation project'.tl,
      icon: const Icon(Icons.more_vert),
      onSelected: (value) {
        if (value == _createAction) {
          unawaited(createStudioProject(context, presetComicId: presetComicId));
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          value: _createAction,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.create_new_folder_outlined),
            title: Text('Create translation project'.tl),
            subtitle: Text('Pick a downloaded comic and one chapter'.tl),
          ),
        ),
      ],
    );
  }
}

/// 一次建工程的结果（成功时）。
class StudioProjectOutcome {
  const StudioProjectOutcome({
    required this.comicId,
    required this.projectName,
    required this.missingSources,
    required this.reusedExisting,
    this.listed = true,
  });

  /// 建好的工程在本地库里的 id（`bt_<hash>`）。
  final String comicId;

  final String projectName;

  /// 复制原图时**源文件不在**的页数。>0 必须上报：那些页在工作室里表现为
  /// "没有可读页图"，与"页面本来就是空的"长得一样。
  final int missingSources;

  /// 这一章本来就有绑定 ⇒ 打开的是既有工程，**没有**新建。
  final bool reusedExisting;

  /// 工程建好之后，本地库真的登记了它。
  ///
  /// 🔴 `false` 意味着工程根不在 `btProjectRoot` 里 —— 磁盘上一切正常，但工作室
  /// 列表与 `TranslationStudioPage` 都找不到它。这是**必须说出来**的一种失败：
  /// 不说的话用户看到的是"工程没找到，请重扫工程根"，而真正该做的是去设置里
  /// 把那个目录加进去。
  final bool listed;
}

/// 打开三步向导；用户确认创建后跳进工作室。
///
/// 🔴 提示语用 [App.rootContext] 发：紧接着就是一次页面跳转，用被跳走的那个
/// `context` 发提示会让它随页面一起消失（"什么都没提示"）。
Future<void> createStudioProject(
  BuildContext context, {
  String? presetComicId,
}) async {
  final outcome = await showDialog<StudioProjectOutcome>(
    context: context,
    builder: (_) => _StudioProjectDialog(presetComicId: presetComicId),
  );
  if (outcome == null || !context.mounted) return;
  await context.to(() => TranslationStudioPage(comicId: outcome.comicId));
  final message = outcome.reusedExisting
      ? 'Opened the existing project: @a'.tlParams({'a': outcome.projectName})
      : 'Project created: @a'.tlParams({'a': outcome.projectName});
  App.rootContext.showMessage(message: message);
  if (!outcome.listed) {
    App.rootContext.showMessage(
      message: 'The project is outside the studio workspace root, so the studio list will not show it. Add that folder in Settings.'.tl,
    );
  }
  if (outcome.missingSources > 0) {
    App.rootContext.showMessage(
      message: '@a page(s) could not be copied'.tlParams({
        'a': '${outcome.missingSources}',
      }),
    );
  }
}

/// 一本可选漫画 + 它的候选章节。
class _ComicChoice {
  const _ComicChoice({required this.comic, required this.chapters});

  final LocalComic comic;
  final List<StudioChapterRef> chapters;
}

/// 三步向导：选漫画 → 选章节 → 命名。
///
/// 三步都**先选后确认**（点一行 = 选中，按【下一步】才前进），而不是点一行就
/// 自动跳走：整章建工程要复制几十上百个文件，值得让用户在看清楚之前停一下。
class _StudioProjectDialog extends StatefulWidget {
  const _StudioProjectDialog({this.presetComicId});

  /// 见 [StudioProjectMenu.presetComicId]。
  final String? presetComicId;

  @override
  State<_StudioProjectDialog> createState() => _StudioProjectDialogState();
}

class _StudioProjectDialogState extends State<_StudioProjectDialog> {
  static const int _stepCount = 3;

  late final List<_ComicChoice> _comics;

  int _step = 0;
  _ComicChoice? _comic;
  List<StudioChapterOption>? _options;
  StudioChapterOption? _chapter;
  late final TextEditingController _name;
  bool _busy = false;
  String _error = '';

  /// 上一次自动填进名字框的值。用来判断"框里这个值是不是我填的"，
  /// 免得把用户手敲的名字冲掉。
  String _lastSuggestedName = '';

  @override
  void initState() {
    super.initState();
    _comics = _loadComicChoices();
    _name = TextEditingController();
    // 详情页进来的：它已经知道是哪一本，直接站到第 2 步。**找不到就照常从
    // 第 1 步开始** —— 详情页也可能是某本没下载的在线漫画，那时"你看的这一本"
    // 根本不可建工程，列表才是正确答案。
    final preset = _choiceForId(widget.presetComicId);
    if (preset != null) {
      _comic = preset;
      _step = 1;
      unawaited(_scanChapters(preset));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  // ── 候选（步 1） ────────────────────────────────────────────────────

  _ComicChoice? _choiceForId(String? id) {
    if (id == null) return null;
    for (final choice in _comics) {
      if (choice.comic.id == id) return choice;
    }
    return null;
  }

  /// 本地库里所有**建得出工程**的漫画。
  ///
  /// 🔴 判据走纯逻辑层的 `studioProjectComicEligible`。它只有两句："不是产物卡"
  /// 且"本地真的有页"。第一版把它写成了 `comicType == ComicType.local`，结果
  /// 只列出 `ft_` **成品**卡、把真正下到本地的素材全排除了（见该函数的注释）。
  /// 身份用 `isDerivedComicCard`（`bt_` 工程 / `ft_` 成品），**不看** `comicType`。
  List<_ComicChoice> _loadComicChoices() {
    final manager = LocalManager();
    if (!manager.isInitialized) return const [];
    final choices = <_ComicChoice>[];
    for (final comic in manager.getComics(LocalSortType.defaultSort)) {
      if (!studioProjectComicEligible(
        isDerivedCard: isDerivedComicCard(comic.id),
        hasLocalPages: comic.downloadedChapters.isNotEmpty,
        // `chapters == null` = 页直接躺在漫画根下的"扁平"漫画（本地导入一个
        // 纯图片文件夹）。它 `downloadedChapters` 是空的，但照样能建工程。
        isFlat: comic.chapters == null,
      )) {
        continue;
      }
      choices.add(_ComicChoice(comic: comic, chapters: _chapterRefsFor(comic)));
    }
    return choices;
  }

  /// 一本漫画的候选章节。
  ///
  /// 🔴 规则整条在纯逻辑层（`studioChapterRefs`）—— 这里只负责把"这一本下了
  /// 哪些版本"喂进去。判据写在 UI 里就没法在 headless 里被注入故障打红，而这条
  /// 规则出错的形态恰好是最看不出来的那种（列出一个不存在的章）。
  List<StudioChapterRef> _chapterRefsFor(LocalComic comic) => studioChapterRefs(
    comic.chapters,
    preferredKeys: comic.downloadedChapters.toSet(),
  );

  // ── 步进 ────────────────────────────────────────────────────────────

  void _selectComic(_ComicChoice choice) {
    if (identical(_comic, choice)) return;
    setState(() {
      _comic = choice;
      _options = null;
      _chapter = null;
      _error = '';
    });
    unawaited(_scanChapters(choice));
  }

  /// 扫这一本每一章的页图数。**异步**：94 页 × 20 章的目录列出不该卡住界面。
  Future<void> _scanChapters(_ComicChoice choice) async {
    final directory = choice.comic.baseDir;
    final options = await Future(() {
      try {
        return studioChapterOptions(
          comicDirectory: directory,
          chapters: choice.chapters,
        );
      } catch (e, s) {
        Log.error('Studio Entry', 'scan ${choice.comic.title} failed: $e', s);
        return <StudioChapterOption>[];
      }
    });
    if (!mounted || !identical(_comic, choice)) return;
    setState(() => _options = options);
  }

  void _next() {
    if (_step == 0) {
      if (_comic == null) return;
      setState(() {
        _error = '';
        _step = 1;
      });
      return;
    }
    if (_step == 1) {
      final chapter = _chapter;
      if (chapter == null) return;
      // 名字在**进入第三步时**填。若框里还是上一次的自动建议值（用户没动过），
      // 跟着新章节走；用户手敲过就绝不覆盖。
      final suggested = studioProjectNameFor(
        comicTitle: _comic?.comic.title ?? '',
        chapterName: chapter.ref.chapterName,
      );
      final current = _name.text.trim();
      if (current.isEmpty || current == _lastSuggestedName) {
        _name.text = suggested;
      }
      _lastSuggestedName = suggested;
      setState(() {
        _error = '';
        _step = 2;
      });
    }
  }

  void _back() {
    setState(() {
      _error = '';
      if (_step == 2) {
        _step = 1;
      } else if (_step == 1) {
        _step = 0;
      }
    });
  }

  // ── 创建 ────────────────────────────────────────────────────────────

  /// 这一章现在是不是已经绑了工程（绑了就不会新建）。
  StudioReaderBinding? get _existingBinding {
    final comic = _comic;
    final chapter = _chapter;
    if (comic == null || chapter == null) return null;
    return StudioReaderStore.bindingFor(
      cid: comic.comic.id,
      sourceKey: comic.comic.sourceKey,
      eid: chapter.ref.eid,
    );
  }

  Future<void> _create() async {
    final comic = _comic;
    final chapter = _chapter;
    if (comic == null || chapter == null) return;
    final name = _name.text.trim();
    final problem = studioProjectNameProblem(name);
    if (problem != null) {
      setState(() => _error = _nameProblemText(problem));
      return;
    }

    // 已绑定时**不新建**：一个工程 = 一章（`studio_reader.dart` 的绑定键）。
    // 悄悄按用户输入的名字再建一个，会让同一章有两个工程、术语表也分家。
    final existing = _existingBinding;
    if (existing != null) {
      context.pop(
        StudioProjectOutcome(
          comicId: BtProjectManager.comicIdForJsonFile(existing.jsonPath),
          projectName: _projectDirectoryName(existing) ?? name,
          missingSources: 0,
          reusedExisting: true,
        ),
      );
      return;
    }

    setState(() {
      _busy = true;
      _error = '';
    });
    final cid = comic.comic.id;
    final sourceKey = comic.comic.sourceKey;
    // 🔴 定位交给 `StudioReaderLink.locate`（与阅读器开关同一条路），然后**只**
    // 覆盖工程名 —— 用户在这一步改的就是名字，别的一律照它的结果。
    final located = StudioReaderLink.locate(
      cid: cid,
      sourceKey: sourceKey,
      eid: chapter.ref.eid,
    );
    if (located == null) {
      setState(() {
        _busy = false;
        _error = 'This comic is not available locally.'.tl;
      });
      return;
    }
    final target = StudioReaderTarget(
      comicDirectory: located.comicDirectory,
      chapterName: located.chapterName,
      projectName: name,
      group: located.group,
    );
    final (binding, reason) = await StudioReaderLink.ensureBinding(
      cid: cid,
      sourceKey: sourceKey,
      eid: chapter.ref.eid,
      target: target,
    );
    if (!mounted) return;
    if (binding == null) {
      setState(() {
        _busy = false;
        _error = _failureText(reason);
      });
      return;
    }
    // 工程刚落到磁盘 ⇒ 让本地库把它登记成一行，否则跳过去的 `bt_<hash>`
    // 在 `_projects` 里查不到（`ensureProject` 会扫，但那次扫发生在跳转
    // 之后，界面会先显示"没找到"）。
    await BtProjectManager().scan();
    if (!mounted) return;
    final comicId = BtProjectManager.comicIdForJsonFile(binding.jsonPath);
    context.pop(
      StudioProjectOutcome(
        comicId: comicId,
        projectName: name,
        missingSources: _countMissing(target, binding),
        reusedExisting: false,
        // 🔴 登记不到就**必须**上报：工程根不在 `btProjectRoot` 里时，磁盘上
        // 一切正常而工作室看不到它（见 [StudioProjectOutcome.listed]）。
        listed: BtProjectManager().projectFor(comicId) != null,
      ),
    );
  }

  /// 既有工程的名字（工程目录名）。取不到就返回 null。
  static String? _projectDirectoryName(StudioReaderBinding binding) {
    final slash = binding.jsonPath.replaceAll('\\', '/').lastIndexOf('/');
    if (slash <= 0) return null;
    final dir = binding.jsonPath.substring(0, slash);
    final dirSlash = dir.replaceAll('\\', '/').lastIndexOf('/');
    return dir.substring(dirSlash + 1);
  }

  /// 复制不全的页数。
  ///
  /// 🔴 `ensureBinding` 只回一个 `'missing-source'` 码（不给清单），所以这里
  /// 用"源目录扫出来的页 vs 副本目录里实际存在的文件"再数一遍。这个数在
  /// "工程早就建好了"的情形下是 0（页都在），那正是对的。
  int _countMissing(StudioReaderTarget target, StudioReaderBinding binding) {
    final root = binding.projectDirectory;
    final chapterName = target.chapterName;
    if (root.isEmpty) return 0;
    var missing = 0;
    for (final name in ProjectBootstrap.scanPageNames(
      comicDirectory: target.comicDirectory,
      chapterName: chapterName,
    )) {
      final pageKey = chapterName.isEmpty ? name : '$chapterName/$name';
      if (!File('$root/$pageKey').existsSync()) missing++;
    }
    return missing;
  }

  String _nameProblemText(String problem) {
    if (problem == 'empty') return 'A project name cannot be empty.'.tl;
    if (problem == 'separator') {
      return 'A project name cannot contain a path separator.'.tl;
    }
    return 'Project names are limited to @a characters.'.tlParams({
      'a': '$studioProjectNameLimit',
    });
  }

  String _failureText(String? reason) {
    if (reason == 'no-project-root') {
      return 'The studio workspace root is not set. Set it in Settings first.'.tl;
    }
    if (reason == 'chapter-has-no-page') {
      return 'This chapter has no page image.'.tl;
    }
    if (reason == 'missing-source') {
      return 'Some page images could not be copied.'.tl;
    }
    return 'Could not create the project. See the log for details.'.tl;
  }

  // ── 界面 ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: context.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: context.brightness == Brightness.dark
            ? BorderSide(color: context.colorScheme.outlineVariant)
            : BorderSide.none,
      ),
      child: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          children: [
            _header(),
            const Divider(height: 1),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _buildStep(),
              ),
            ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error,
                    style: ts.s12.withColor(context.colorScheme.error),
                  ),
                ),
              ),
            const Divider(height: 1),
            _actions(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: _busy ? null : () => context.pop(),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Create translation project'.tl,
              style: ts.s16,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            'Step @a of @b'.tlParams({'a': '${_step + 1}', 'b': '$_stepCount'}),
            style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
        ],
      ),
    );
  }

  Widget _actions() {
    final last = _step == _stepCount - 1;
    return SizedBox(
      height: 56,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: _busy ? null : () => context.pop(),
            child: Text('Cancel'.tl),
          ),
          if (_step > 0)
            TextButton(
              onPressed: _busy ? null : _back,
              child: Text('Back'.tl),
            ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _busy ? null : (last ? _create : _next),
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(last ? Icons.check : Icons.arrow_forward),
            label: Text(last ? 'Create'.tl : 'Next'.tl),
          ),
          const SizedBox(width: 12),
        ],
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 0:
        return _buildComicStep();
      case 1:
        return _buildChapterStep();
      default:
        return _buildNameStep();
    }
  }

  Widget _buildComicStep() {
    if (_comics.isEmpty) {
      return Center(
        child: Text(
          'No downloaded comic found. Download a comic first.'.tl,
          textAlign: TextAlign.center,
          style: ts.s14,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Choose a comic'.tl, style: ts.s14.bold),
        const SizedBox(height: 4),
        Text(
          'Only downloaded comics are listed: a project copies the original images into its own source folder.'
              .tl,
          style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: ListView.builder(
            itemCount: _comics.length,
            itemBuilder: (context, index) {
              final choice = _comics[index];
              return ListTile(
                dense: true,
                selected: identical(choice, _comic),
                leading: SizedBox(
                  width: 32,
                  height: 44,
                  child: _ComicThumb(comic: choice.comic),
                ),
                title: Text(
                  choice.comic.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '@a chapter(s)'.tlParams({'a': '${choice.chapters.length}'}),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _selectComic(choice),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildChapterStep() {
    final options = _options;
    if (options == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (options.every((o) => !o.selectable)) {
      return Center(
        child: Text(
          'No chapter with page images. Pick another comic.'.tl,
          textAlign: TextAlign.center,
          style: ts.s14,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Choose a chapter'.tl, style: ts.s14.bold),
        const SizedBox(height: 4),
        Text(
          'A greyed-out chapter has no page image, so no project can be built from it.'
              .tl,
          style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: ListView.builder(
            itemCount: options.length,
            itemBuilder: (context, index) {
              final option = options[index];
              return ListTile(
                dense: true,
                enabled: option.selectable,
                selected: identical(option, _chapter),
                title: Text(
                  option.ref.label.isEmpty
                      ? 'Whole comic (no chapter)'.tl
                      : option.ref.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  option.selectable
                      ? '@a page(s)'.tlParams({'a': '${option.pageCount}'})
                      : 'This chapter has no page image.'.tl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: option.selectable
                    ? () => setState(() {
                        _chapter = option;
                        _error = '';
                      })
                    : null,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildNameStep() {
    final existing = _existingBinding;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Name the project'.tl, style: ts.s14.bold),
          const SizedBox(height: 6),
          TextField(
            controller: _name,
            autofocus: true,
            enabled: !_busy,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: 'Project name'.tl,
            ),
            onChanged: (_) {
              if (_error.isNotEmpty) setState(() => _error = '');
            },
          ),
          const SizedBox(height: 8),
          Text(
            'The project is created under the studio workspace root, next to the downloaded comics.'
                .tl,
            style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Text(
            'A project built here is also read by the reader for this chapter.'.tl,
            style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
          ),
          if (existing != null) ...[
            const SizedBox(height: 8),
            Text(
              'This chapter already has a project. Creating will open the existing one instead.'
                  .tl,
              style: ts.s12.withColor(context.colorScheme.primary),
            ),
          ],
        ],
      ),
    );
  }
}

/// 漫画封面缩略图。取不到就画一个占位图标 —— 一张读不到的封面不该让
/// 整个列表报错（本地库里有 cover 字段指向不存在文件的条目）。
class _ComicThumb extends StatelessWidget {
  const _ComicThumb({required this.comic});

  final LocalComic comic;

  @override
  Widget build(BuildContext context) {
    return Image.file(
      comic.coverFile,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stack) => Icon(
        Icons.broken_image_outlined,
        size: 20,
        color: context.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
