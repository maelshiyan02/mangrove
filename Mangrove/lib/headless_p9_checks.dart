// 「创建翻译工程」UI 入口的断言集（S9.5-b · 追补批次）。
//
// ## 为什么单独一个文件
//
// 同 P1 / P7 / P8 的理由：`headless.dart` 已经 3100 行，把断言塞进去会让"再加
// 一条"变成"动核心文件"。
//
// ## 这一批钉的是什么
//
// 入口做三件事：**筛漫画 → 筛章节 → 建工程**。三件事的出错形态都是静默的：
//
// * 筛错漫画 ⇒ 列表里出现一本建不出工程的（`bt_` 产物 / 没下载）；
// * 筛错章节 ⇒ 选中一个空目录，建出来的工程 0 页（界面上只是一张空白）；
// * 命名规则与阅读器开关不一致 ⇒ **同一章两个工程**，术语表也分家；
// * 自己再建一次工程而不走 `StudioReaderLink` ⇒ 工程建出来了但**没有绑定**，
//   阅读器永远读不到它（"我有工程啊，怎么打开还是不翻译"）。
//
// 所以每一条都写成"**判据 + 一个故意做错的同类实现**"：绿路径喂正确实现，
// 红路径喂那一个错误实现，**同一个判据**必须翻脸。判据恒真 = 装饰品。
//
// ## 与 P8 的分工
//
// P8 管的是**读**（阅读器读哪一份产物）；这里是**建**（工程从哪来）。
// 两边共用 `studio_reader.dart` / `studio_project_entry.dart` 这两层纯逻辑。
library;

import 'dart:io';

import 'package:mangrove/foundation/comic_card_kind.dart';
import 'package:mangrove/foundation/comic_source/comic_source.dart';
import 'package:mangrove/foundation/translation_project/studio_project_entry.dart';
import 'package:mangrove/headless_p1_checks.dart' show CheckSink;

const _entryPath =
    'lib/foundation/translation_project/studio_project_entry.dart';
const _menuPath = 'lib/pages/translation_studio/studio_project_menu.dart';
const _studioPagePath = 'lib/pages/translation_studio/studio_page.dart';
const _launcherPath = 'lib/pages/translated_comics_page.dart';
const _readerAppPath =
    'lib/foundation/translation_project/studio_reader_app.dart';
const _bootstrapPath =
    'lib/foundation/translation_project/project_bootstrap.dart';
const _btManagerPath = 'lib/foundation/bt_project/bt_project_manager.dart';
const _homePagePath = 'lib/pages/home_page.dart';
const _localComicsPath = 'lib/pages/local_comics_page.dart';
const _localDartPath = 'lib/foundation/local.dart';
const _cardKindPath = 'lib/foundation/comic_card_kind.dart';

class _Probe {
  const _Probe(this.name, this.green, this.red, this.detail);

  final String name;
  final bool Function() green;
  final bool Function() red;
  final String Function() detail;
}

void runP9Checks(CheckSink check, {required Directory packageRoot}) {
  final probes = <_Probe>[];
  void probe(
    String name,
    bool Function() green,
    bool Function() red,
    String Function() detail,
  ) {
    probes.add(_Probe(name, green, red, detail));
  }

  String code(String rel) =>
      File('${packageRoot.path}/$rel').readAsStringSync();
  bool codeHas(String rel, String needle) => code(rel).contains(needle);

  // ── 1 · 命名规则：全仓唯一实现，且与阅读器开关同源 ────────────────────

  probe(
    'name_rule_matches_the_reader_toggle_formula',
    // 行为判据：`<漫画名>[-<章节目录名>]`。期望值是**硬编码**的，不是用同一个
    // 函数再算一遍 —— 那样就成了同义反复。
    () =>
        studioProjectNameFor(comicTitle: 'Comic', chapterName: '1 [Asura]') ==
            'Comic-1 [Asura]' &&
        studioProjectNameFor(comicTitle: 'Comic', chapterName: '') == 'Comic' &&
        // 无章节且漫画名为空 → 兜底名，不是空串（空串会让工程建在
        // `projectsRoot/` 自己身上）。
        studioProjectNameFor(comicTitle: '', chapterName: '') ==
            'studio-project' &&
        // 非法字符清洗（`sanitizePathSegment` 的规则：分隔符 → `_`）。
        studioProjectNameFor(comicTitle: 'a/b', chapterName: '') == 'a_b',
    // 故障路径 = 不清洗、不兜底的那一版。
    () =>
        _rawName(comicTitle: 'Comic', chapterName: '1 [Asura]') ==
            'Comic-1 [Asura]' &&
        _rawName(comicTitle: 'Comic', chapterName: '') == 'Comic' &&
        _rawName(comicTitle: '', chapterName: '') == 'studio-project' &&
        _rawName(comicTitle: 'a/b', chapterName: '') == 'a_b',
    () => '绿=名字规则（清洗 + 兜底） / 故障=不清洗的那版在 a/b 上不成立',
  );

  probe(
    'name_rule_bounds_the_length',
    // 60 是 Windows 路径总长留下的余量；不截会让 `projects/<name>/source/...`
    // 撞 260。判据同时要求"确实截了"和"截在正确的长度上"。
    () {
      final name = studioProjectNameFor(comicTitle: 'x' * 80, chapterName: '');
      return name.length == studioProjectNameLimit && name == 'x' * 60;
    },
    // 故障路径 = 去掉上限的那一版（80 字符原样返回 ⇒ 判据翻脸）。
    () => _unboundedName('x' * 80).length == studioProjectNameLimit,
    () => '绿=截到 $studioProjectNameLimit / 故障=不截的那版长度为 80 ⇒ 判据不成立',
  );

  probe(
    'name_rule_is_shared_with_the_reader_toggle',
    // 🔴 本批最要紧的一条：`StudioReaderLink.locate` 必须**调**共享函数，
    // 不能内联一份。内联的后果不是报错，是同一章建出两个工程。
    () => _usesSharedNameRule(code(_readerAppPath)),
    // 故障路径 = 把内联公式（旧写法）喂给同一个判据。
    () => _usesSharedNameRule(
      "final title = LocalManager.getChapterDirectoryName(comic.title);\n"
      "final stub = chapterName.isEmpty ? title : '\$title-\$chapterName';\n"
      "final bounded = stub.length > 60 ? stub.substring(0, 60) : stub;",
    ),
    () => '绿=阅读器开关走共享命名规则 / 故障=内联旧公式不满足判据',
  );

  probe(
    'logic_layer_holds_no_widgets',
    // 这一层要能被 headless 直接调（`A01 §3`：本会话没有渲染表面，凡牵涉
    // 像素的只能在 GUI 会话里验）。所以它必须是**纯判断**，一行 UI 都没有。
    () =>
        !codeHas(_entryPath, 'package:flutter/material.dart') &&
        !codeHas(_entryPath, 'Widget'),
    // 对照组：菜单 UI 文件**真的**有 Widget ⇒ 同一判据在它身上为 false，
    // 说明这个扫描看得见。
    () => !codeHas(_menuPath, 'Widget'),
    () => '绿=入口逻辑层没有 UI / 故障=对照组（菜单 UI）确实有 Widget ⇒ 判据非恒真',
  );

  // ── 2 · 候选人筛选：三条判据 ──────────────────────────────────────────

  probe(
    'derived_cards_are_not_candidates',
    // `bt_<hash>` 是**工程**、`ft_<hash>` 是**成品**，两者都是从素材派生出来的
    // 产物。给产物再建工程，新工程的"原图"会指向上一层的中间产物
    // （`projects/<名>/source/` 或 `translated/<名>/`）。
    // 🔴 注意：不能顺手写成"在线漫画被排除" —— 从 comix.to 下载到本地的漫画
    // 是最正统的素材，而它**不是** `ComicType.local`（见下一条）。
    () =>
        !studioProjectComicEligible(
          isDerivedCard: true,
          hasLocalPages: true,
          isFlat: false,
        ),
    // 故障路径 = 忽略 `isDerivedCard` 的那一版（它返回 true ⇒ 判据翻脸）。
    () =>
        !_eligibleIgnoringDerivedCard(
          isDerivedCard: true,
          hasLocalPages: true,
          isFlat: false,
        ),
    () => '绿=bt_/ft_ 产物被排除 / 故障=忽略该判据的版本会放它进来',
  );

  probe(
    'the_source_type_is_not_the_eligibility_rule',
    // 🔴 本批**最要紧**的一条，钉的就是 2026-10-09 实测出来的那个真 bug：第一版
    // 把"是不是素材"写成 `comicType == ComicType.local`，于是
    // - `ft_` 成品卡（也是 `local`）被放行 —— 列表里唯一一本就是它；
    // - 从 comix.to 下载到本地的 `My Dragon Girlfriend Has Returned`
    //   （`comic_type = 496108553`，即源类型）被排除 —— 真正的素材一本都不在。
    //
    // 判据：判据函数**只吃三个布尔**，源码里不许出现按 `comicType` 分类的写法。
    () =>
        studioProjectComicEligible(
          isDerivedCard: false,
          hasLocalPages: true,
          isFlat: false,
        ),
    // 故障路径 = 真按 `comicType` 分类的那一版。三行实测数据：
    // 下载素材（`comic_type` 是源类型 `496108553`）**必须**仍被判为素材。
    () =>
        _eligibleByComicType(
          isLocalType: false, // ← 从网络源下载到本地：不是 ComicType.local
          isBtProject: false,
          chapterCount: 9,
        ),
    () =>
        '绿=从网络源下载到本地的漫画仍是素材 / '
        '故障=按 comicType 分类的那版会把它排除掉（2026-10-09 实测三行的形态）',
  );

  probe(
    'eligibility_never_reads_the_comic_type',
    // 上一条是**行为**，这一条钉**源码**：判据函数体里不许出现 `comicType`。
    // 🔴 只能扫**函数体** —— 文件头的注释里必然要写"不能写成
    // `comicType == ComicType.local`"，整文件扫 `contains('comicType')` 恒真，
    // 那是恒真的装饰品（M11）。
    () => _eligibilityBodyHasNoComicType(code(_entryPath)),
    () => _eligibilityBodyHasNoComicType(_eligibilityByComicTypeSource),
    () => '绿=判据函数体不出现 comicType / 故障=按 comicType 分类的那版被抓出来',
  );

  probe(
    'comics_without_local_pages_are_not_candidates',
    // 工程要把原图**复制**进 `source/`（`ProjectBootstrap` 的硬约束 1）。本地一页
    // 都没有 ⇒ 建出来的工程 0 页，而界面上只是一张空白，看不出为什么。
    () =>
        !studioProjectComicEligible(
          isDerivedCard: false,
          hasLocalPages: false,
          isFlat: false,
        ),
    () =>
        !_eligibleIgnoringLocalPages(
          isDerivedCard: false,
          hasLocalPages: false,
          isFlat: false,
        ),
    () => '绿=没有本地页的漫画被排除 / 故障=忽略该判据的版本会放它进来',
  );

  probe(
    'a_flat_comic_still_has_one_choice',
    // 无章节漫画（页躺在漫画根下）**不是**"没有本地页"：它有一个 eid='0' 的伪
    // 章节，否则"本地导入一个纯图片文件夹"这种最普通的形态反而建不了工程。
    // 🔴 故障路径刻意同时关掉 `isFlat` —— 判据必须翻脸，否则这一条区分不出
    // "有空章节目录的漫画"与"页在根下的漫画"。
    () =>
        studioProjectComicEligible(
          isDerivedCard: false,
          hasLocalPages: false,
          isFlat: true,
        ),
    () =>
        studioProjectComicEligible(
          isDerivedCard: false,
          hasLocalPages: false,
          isFlat: false,
        ),
    () => '绿=扁平漫画（页在根下）可选 / 故障=关掉 isFlat 后判据为 false',
  );

  // ── 2b · 本地库展示：产物卡与素材卡同表混排 ──────────────────────────
  //
  // 同一个根因的两张脸：`bt_`（工程）与 `ft_`（成品）两张**产物卡**也登记在
  // `local.db`，而且 `comic_type` 同样是 `0(local)` —— 所以按类型分不开，只能
  // 按 id 前缀分。主页"本地"分区漏了这一刀，于是出现 `MDGH-ch1` 这种工程名。

  probe(
    'the_library_splits_by_card_kind',
    // 本地库页按 [ComicCardKind] **三分**（素材 / 工程 / 成品），与磁盘上
    // `ComicLibrary/` 的三个下属文件夹一一对应。三行实测 id（`local.db`
    // 2026-10-09）。
    // 🔴 认不出来的前缀一律归 `downloaded`：多列一条素材是可解释的（点进去会说
    // 这一本没有页图），少列一条是静默的（用户找不到自己下好的漫画）。
    () =>
        comicCardKindOf('bt_d2844d22') == ComicCardKind.project &&
        comicCardKindOf('ft_0166fe70') == ComicCardKind.product &&
        comicCardKindOf('gm28k//my-dragon-girlfriend-has-returned') ==
            ComicCardKind.downloaded &&
        comicCardKindOf(null) == ComicCardKind.downloaded &&
        localLibraryKinds.length == 3,
    // 故障路径 = 按 `comicType` 分类的那一版：`bt_`/`ft_` 都是 `local`，
    // `ft_` 会被误判成工程（⇒ 合取式在它身上不成立）。
    () =>
        _kindByComicType(isLocalType: true) == ComicCardKind.project &&
        _kindByComicType(isLocalType: true) == ComicCardKind.product &&
        _kindByComicType(isLocalType: false) == ComicCardKind.downloaded,
    () => '绿=按 id 前缀三分（bt_=工程 / ft_=成品 / 其余=素材） / '
        '故障=按 comicType 分类的版本把 ft_ 判成工程',
  );

  probe(
    'home_local_section_shows_artwork_only',
    // 主页「本地」栏的收录范围 = `ComicLibrary/downloads/`（**只有素材**）：
    // 工程归「翻译工作室」分区，成品归本地库页的「成品」段。三者都不该挤在一栏
    // —— 挤进来就是"本地库里有 MDGH-ch1"那个困惑。
    () =>
        !isShownInHomeLocal('bt_d2844d22') &&
        !isShownInHomeLocal('ft_0166fe70') &&
        isShownInHomeLocal('gm28k//my-dragon-girlfriend-has-returned') &&
        isShownInHomeLocal(null),
    // 故障路径 = 什么都不排除的那一版（它在 `bt_` 上就让判据不成立）。
    () => !_showsEverythingInHomeLocal('bt_d2844d22'),
    () => '绿=主页本地栏只收素材（排除 bt_/ft_）/ 故障=不排除的版本不成立',
  );

  probe(
    'home_and_library_read_the_same_card_kind_module',
    // 🔴 主页「本地」与本地库页**各写一遍** `isBtComic` 就必然漂移 —— 实测正是
    // 主页漏排。两处都必须只读 `comic_card_kind.dart`。
    () =>
        _usesSharedHiddenPrefixList(
          // 🔴 只能扫**这一段**：`home_page.dart` 的「翻译工作室」分区本来就该用
          // `isBtComic`（那一栏要的正是工程卡），整文件扫会误判。
          _classBodyOf(code(_homePagePath), 'class _LocalState'),
        ) &&
        _librarySplitsByCardKind(
          _methodBodyOf(code(_localComicsPath), 'List<LocalComic> _collectComics()'),
        ),
    // 故障路径 = 内联 `BtProjectManager.isBtComic` 的那一版。
    () => _usesSharedHiddenPrefixList(
      'all = all.where((c) => !BtProjectManager.isBtComic(c.id)).toList();',
    ),
    () => '绿=两处（主页本地分区 / 本地库页列表）都读同一份卡片判据 / '
        '故障=内联 isBtComic 的版本不满足判据',
  );

  probe(
    'card_kind_reads_the_prefix_from_its_owner',
    // `bt_` / `ft_` 两个前缀的**唯一定义**分别在 `BtProjectManager.idPrefix` 与
    // `FinishedExport.idPrefix`。这里引用而不是抄一份字符串：抄了之后哪天前缀
    // 改了，"本地库隐藏"就静默失效（主页又开始显示工程卡）。
    () =>
        codeHas(_cardKindPath, 'BtProjectManager.idPrefix') &&
        codeHas(_cardKindPath, 'FinishedExport.idPrefix'),
    () =>
        _readsOwnerPrefix(
          "if (id.startsWith('bt_')) return ComicCardKind.project;",
        ),
    () => '绿=前缀取自各管理器 / 故障=硬编码字符串的版本不满足判据',
  );

  probe(
    'prefix_exclusion_sql_is_parameter_bound',
    // 🔴 写完这一条的前一刻，`local.dart` 里两个新方法真的就是这个坏形态：
    // SQL 里有 `?` 占位符却**没传参数** ⇒ 运行时直接抛。它是"编译得过"的，
    // 所以只能靠这条断言挡。
    // 顺带钉住 `LIKE 'bt_%'` 那个坑：`_` 是单字符通配符，`'bt_%'` 会连
    // `btX…` 一起命中，必须走 `substr(id, 1, n) <> ?`。
    () => _prefixExclusionIsBound(code(_localDartPath)),
    // 故障形态（2026-10-09 真实发生过）：条件函数是对的（有 `substr` 占位符），
    // 但调用处**忘了传参数** ⇒ 运行时抛。它编译得过，只能靠这条挡。
    () => _prefixExclusionIsBound(
      "String _prefixExclusionWhere(List<String> p) => 'substr(id, 1, ?) <> ?';\n"
      "final res = _db.select('SELECT * FROM comics WHERE \$where');",
    ),
    () => '绿=每条带占位符的 SQL 都绑定了参数 / 故障=有占位符却不传参的版本被抓出',
  );

  // ── 3 · 章节扫描：与建工程同一条走法 ─────────────────────────────────

  probe(
    'chapter_scan_is_the_same_walk_as_project_creation',
    // 🔴 可选项的判据必须与"真的建不出来"是同一条。各写一遍就会出现"列表里
    // 可选、点下去报 chapter-has-no-page"。
    () =>
        _scansViaBootstrap(code(_entryPath)) &&
        codeHas(_bootstrapPath, 'scanPageNames('),
    // 故障路径 = 自己再列一次目录的那一版（`Directory(...).listSync()`）。
    () =>
        _scansViaBootstrap('final names = Directory(dir).listSync();') &&
        codeHas(_bootstrapPath, 'scanPageNames('),
    () => '绿=入口调 scanPageNames（唯一走法） / 故障=自己列目录的版本不满足',
  );

  probe(
    'scan_page_names_is_shared_by_plan_and_counting',
    // `plan` 也必须走 `scanPageNames` —— 两处各列一次目录，就会出现"数出来 94
    // 页、建出来 93 页"这种只在末尾差一页的分歧。
    () => _planDelegatesToScanNames(code(_bootstrapPath)),
    () => _planDelegatesToScanNames(
      'static ProjectBootstrapPlan plan({required String comicDirectory, '
      'required String chapterName}) {\n'
      '  final names = <String>[];\n'
      '  return ProjectBootstrapPlan(pageKeys: const [], sizes: const {});\n'
      '}',
    ),
    () => '绿=plan 走 scanPageNames / 故障=plan 自己列目录不满足',
  );

  probe(
    'option_selectability_equals_page_count',
    // 行为判据，跑在**真的临时目录**上：`<tmp>/comic/ch1/` 有两页、`ch2/` 里
    // 只有一个 `notes.txt`（白名单外 ⇒ 不是页）。
    () {
      final dir = Directory.systemTemp.createTempSync('mangrove_p9_');
      try {
        File('${dir.path}/ch1/1.webp').createSync(recursive: true);
        File('${dir.path}/ch1/2.png').createSync();
        File('${dir.path}/ch2/notes.txt').createSync(recursive: true);
        final options = studioChapterOptions(
          comicDirectory: dir.path,
          chapters: const [
            StudioChapterRef(eid: '1', label: 'Ch 1', chapterName: 'ch1'),
            StudioChapterRef(eid: '2', label: 'Ch 2', chapterName: 'ch2'),
          ],
        );
        return options.length == 2 &&
            options[0].pageCount == 2 &&
            options[0].selectable &&
            !options[1].selectable &&
            options[1].blockedReason == 'no-page';
      } finally {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    },
    // 故障路径 = 不看磁盘、一律认为可选的那一版 —— 同一个命题（"ch2 不可选"）
    // 在它身上必须为 false。
    () => !_alwaysSelectable().selectable,
    () => '绿=ch1 可选/ch2 灰掉 / 故障=不看磁盘的版本会把 ch2 判成可选',
  );

  // ── 4 · 命名校验：在建任何文件之前挡住 ───────────────────────────────

  probe(
    'bad_names_are_rejected_before_the_disk_is_touched',
    // 入口在**调创建之前**就要挡住，否则失败会以"工程建不出来"的形式出现，
    // 而真正的原因（名字里有 `/`）看不见。
    () =>
        studioProjectNameProblem('') == 'empty' &&
        studioProjectNameProblem('   ') == 'empty' &&
        studioProjectNameProblem('a/b') == 'separator' &&
        studioProjectNameProblem(r'a\b') == 'separator' &&
        studioProjectNameProblem('..') == 'separator' &&
        studioProjectNameProblem('x' * 61) == 'too-long' &&
        studioProjectNameProblem('ok') == null &&
        studioProjectNameProblem('x' * 60) == null,
    // 故障路径 = 不查长度的那一版（61 字符会被放行 ⇒ 判据在那一项上翻脸）。
    () =>
        _problemWithoutLength('') == 'empty' &&
        _problemWithoutLength('   ') == 'empty' &&
        _problemWithoutLength('a/b') == 'separator' &&
        _problemWithoutLength(r'a\b') == 'separator' &&
        _problemWithoutLength('..') == 'separator' &&
        _problemWithoutLength('x' * 61) == 'too-long' &&
        _problemWithoutLength('ok') == null &&
        _problemWithoutLength('x' * 60) == null,
    () => '绿=空/分隔符/过长都被挡 / 故障=不查长度的版本会放过 61 字符',
  );

  // ── 5 · 接线：同一个组件、同一条创建链路 ─────────────────────────────

  probe(
    'both_entry_points_use_the_same_widget',
    // 详细页与列表页各挂一份，但必须是**同一个** `StudioProjectMenu`。两处
    // 各写一个菜单 = 加第二个动作时必然只加一处。
    () =>
        _mountsSharedMenu(code(_studioPagePath)) &&
        _mountsSharedMenu(code(_launcherPath)),
    // 故障路径 = 一个自己搭 `PopupMenuButton` 的页面。
    () => _mountsSharedMenu(
      "actions: [\n"
      "  PopupMenuButton<String>(\n"
      "    icon: const Icon(Icons.more_vert),\n"
      "    itemBuilder: (context) => const [],\n"
      "  ),\n"
      "]",
    ),
    () => '绿=两处都挂 StudioProjectMenu / 故障=手搭 PopupMenuButton 不满足判据',
  );

  probe(
    'creation_goes_through_the_reader_link',
    // 🔴 建工程 + 写绑定只有一份实现（`StudioReaderLink`）。自己调
    // `ProjectBootstrap.create` 会建出一个**没有绑定**的工程 —— 磁盘上一切
    // 正常，阅读器永远读不到它。
    () => _usesReaderLink(code(_menuPath)),
    // 故障路径 = 自己建工程、不写绑定的那一版。
    () => _usesReaderLink(
      'final result = await ProjectBootstrap.create(\n'
      '  projectsRoot: root, name: name, plan: plan);',
    ),
    () => '绿=走 locate + ensureBinding / 故障=直接 create 的版本不满足判据',
  );

  probe(
    'the_id_is_not_re_derived',
    // 工程 id 的算法只有一个 owner（`BtProjectManager.comicIdForJsonFile`）。
    // 入口自己再算一遍 FNV，漂移时表现为"刚建的工程不在列表里"。
    () => codeHas(_menuPath, 'BtProjectManager.comicIdForJsonFile('),
    // 故障路径 = 把内联哈希版喂给同一个判据（`0x811c9dc5` 是 FNV 的起始值）。
    () => _usesPublicIdHelper('var hash = 0x811c9dc5;'),
    () => '绿=入口用公开的 comicIdForJsonFile / 故障=内联哈希的版本不满足',
  );

  probe(
    'the_id_helper_has_exactly_one_implementation',
    // 公开出来的时候**改名**而不是加一层包装：两层同体是"同一份逻辑两处可改"
    // 的最小形态，而下一次改只会改一处。
    () => _singleIdImplementation(code(_btManagerPath)),
    // 故障路径 = 公开名 + 私有名并存的那一版（包装层）。
    () => _singleIdImplementation(
      'static String comicIdForJsonFile(String p) => _comicIdFor(p);\n'
      'static String _comicIdFor(String p) { return ""; }',
    ),
    () => '绿=只剩一个公开实现 / 故障=公开名与私有名并存不满足判据',
  );

  probe(
    'chapter_refs_are_built_in_the_logic_layer',
    // 规则本身在 `studio_project_entry.dart` 里；UI 只负责把"下了哪些版本"喂进去。
    // 写在 UI 里的判据没法被 headless 注入故障打红 —— 而这条规则出错的形态恰好
    // 是最看不出来的那种（列出一个不存在的章）。
    () => _delegatesChapterRefs(code(_menuPath)),
    // 故障路径 = 自己拿 `chapters.ids` 拼一遍的那一版。
    () => _delegatesChapterRefs('final refs = [for (final k in chapters.ids) k];'),
    () => '绿=菜单调 studioChapterRefs / 故障=自己拼章节列表不满足判据',
  );

  probe(
    'chapter_refs_prefer_downloaded_versions',
    // 📌 行为判据。同一话两个版本：**DivaScans 更新（版本列表首位）**，而用户
    // 下载的是 **Asura Scans**。`ids` 取第一位，所以不看"哪一版已下载"的实现
    // 会给出 `k-diva` —— 而那个目录在磁盘上不存在。
    () {
      final refs = studioChapterRefs(
        _twoVersionChapter(),
        preferredKeys: {'k-asura'},
      );
      return refs.length == 1 && refs.single.eid == 'k-asura';
    },
    // 故障路径 = 忘了传 preferredKeys（原始序 ⇒ 首版 DivaScans）。
    () {
      final refs = studioChapterRefs(_twoVersionChapter());
      return refs.length == 1 && refs.single.eid == 'k-asura';
    },
    () => '绿=已下载版本被提到首位 / 故障=原始序的版本会落到 k-diva',
  );

  probe(
    'flat_comic_uses_the_zero_eid',
    // 📌 行为判据。无章节漫画的 `eid` 必须与阅读器 `_currentChapterEid` 的回落
    // 一致（'0'）—— 不一致就是"同一章两个绑定键"。
    () {
      final refs = studioChapterRefs(null);
      return refs.length == 1 &&
          refs.single.eid == '0' &&
          refs.single.chapterName.isEmpty;
    },
    // 故障路径 = 用空串当 eid 的那一版。
    () => _flatRefsWithBlankEid().single.eid == '0',
    () => "绿=无章节漫画用 eid='0' / 故障=用空串的版本不满足判据",
  );

  probe(
    'entry_does_not_touch_settings',
    // 入口只收集选择；默认值/语向不归它管（与 `run_dialog.dart` 同一条边界）。
    () => !codeHas(_menuPath, 'appdata'),
    // 对照组：`settings/reader.dart` 确实读写 appdata ⇒ 判据非恒真。
    () => !codeHas('lib/pages/settings/reader.dart', 'appdata'),
    () => '绿=入口不碰 appdata / 故障=对照组（设置页）确实含 appdata',
  );

  probe(
    'projects_root_is_the_managed_rule',
    // 工程建在哪儿只有一份规则（`BtProjectManager.defaultProjectsRoot`）。
    // `studio_reader_app` 早先内联了一份"几乎一样"的：差别只在本地库没初始化
    // 时那一份会回落到 `btProjectRoot`，内联的直接返回 null ⇒ 配好了工程根的
    // 环境被报成 `no-project-root`。两处各写一遍的规律就是"几乎一样"。
    () => _usesTheManagedProjectsRoot(code(_readerAppPath)),
    // 故障路径 = 内联"上一级 + `/projects`"的那一版。🔴 必须把**同一个判据**
    // 喂给它（`_usesTheManagedProjectsRoot`），不能只写 `_inlinesProjectsRoot(坏
    // 实现)` —— 判据的极性与 §480 那套约定相反，写反了它会恒真，于是这条断言
    // 变成"无论源码怎样都绿"的装饰品，而 `edit-check` 会如实把它标成 FAIL。
    () => _usesTheManagedProjectsRoot(
      "final parent = Directory(manager.path).parent.path;\n"
      "return '\$parent/projects';",
    ),
    () => '绿=走 defaultProjectsRoot / 故障=内联"上一级 + /projects"不满足判据',
  );

  probe(
    'reports_when_the_project_is_not_listed',
    // 工程建好了却没被本地库登记（工程根不在 `btProjectRoot` 里）时，磁盘上
    // 一切正常而工作室看不到它。这必须**说出来** —— 不然用户看到的是
    // "工程没找到，请重扫工程根"，而该做的是去设置里加那个目录。
    () =>
        codeHas(_menuPath, 'projectFor(comicId)') &&
        codeHas(_menuPath, 'listed:'),
    // 故障路径 = 建完直接跳转、不核对登记状态的那一版。
    () => _reportsUnlistedProject(
      'await BtProjectManager().scan();\n'
      'context.pop(StudioProjectOutcome(comicId: id, reusedExisting: false));',
    ),
    () => '绿=核对 projectFor 并且上报 listed / 故障=不核对的那版不满足判据',
  );

  // ── 跑 ──────────────────────────────────────────────────────────────

  for (final item in probes) {
    bool green;
    bool red;
    String err = '';
    try {
      green = item.green();
    } catch (e) {
      green = false;
      err = 'green threw: $e';
    }
    try {
      red = item.red();
    } catch (e) {
      // 故障路径抛异常 ≠ 断言变红。
      red = true;
      err = '${err.isEmpty ? '' : '$err | '}red threw: $e';
    }
    check(
      'projectEntry.${item.name}',
      green && !red,
      '${item.detail()} | 绿路径=${green ? 'true' : 'FALSE'} '
      '故障路径=${red ? '仍绿(装饰品)' : '变红'}${err.isEmpty ? '' : ' | $err'}',
    );
  }
}

// ── 故意做错的同类实现（红路径的对照物） ──────────────────────────────
//
// 🔴 红路径必须检验**同一个命题**，只是喂不同的实现。若红路径检验的是另一个
// 命题，它为 true 只说明那个命题成立，判据依然没被证伪（P7 第一版栽的坑）。

/// 不清洗、不兜底的命名 —— "内联公式"的那一版（少了 `sanitizePathSegment`）。
String _rawName({required String comicTitle, required String chapterName}) {
  final stub = chapterName.isEmpty ? comicTitle : '$comicTitle-$chapterName';
  return stub.isEmpty ? 'studio-project' : stub;
}

/// 截断上限被拿掉的那一版。
String _unboundedName(String comicTitle) =>
    comicTitle.isEmpty ? 'studio-project' : comicTitle;

/// 按 `comicType` 分类的那一版判据的**源码文本**（红路径的喂料）。
///
/// 它必须与真实现是同一种写法（一个 `bool studioProjectComicEligible(...)`
/// 的表达式体），否则 [_eligibilityBodyHasNoComicType] 切片切不到东西，
/// 判据会因为"找不到函数"而不是"函数用了 comicType"翻脸 —— 那是另一种装饰品。
const _eligibilityByComicTypeSource = '''
bool studioProjectComicEligible({
  required ComicType comicType,
  required bool isBtProject,
  required int chapterCount,
}) => comicType == ComicType.local && !isBtProject && chapterCount > 0;
''';

/// 判据**函数体**里有没有出现 `comicType`。
///
/// 🔴 只切函数体（签名收尾 `})` 到语句结束 `;`）：同文件注释里必然要写
/// "不能写成 `comicType == ComicType.local`"，整文件扫会恒真。
bool _eligibilityBodyHasNoComicType(String source) {
  final signature = source.indexOf('bool studioProjectComicEligible(');
  if (signature < 0) return false;
  final bodyStart = source.indexOf('})', signature);
  if (bodyStart < 0) return false;
  final rest = source.substring(bodyStart);
  final close = rest.indexOf(';');
  if (close < 0) return false;
  final body = rest.substring(0, close);
  return !body.contains('comicType') && !body.contains('ComicType');
}

/// 🔴 用 `comicType == ComicType.local` 当"是素材"的那一版 —— **这就是第一版
/// 上线时的真 bug**：产物卡（`bt_`/`ft_`）恰恰也登记成 `local`，被放行；从
/// comix.to 下载到本地的漫画 `comicType` 是源类型，反倒被排除。界面上的症状是
/// "素材列表里只有一本成品，真正的素材一本都不在"（2026-10-09 实测）。
///
/// 留在这里当对照物：判据必须能把它和正确实现区分开。
bool _eligibleByComicType({
  required bool isLocalType,
  required bool isBtProject,
  required int chapterCount,
}) => isLocalType && !isBtProject && chapterCount > 0;

/// 忽略 `isDerivedCard` 的资格判据。
bool _eligibleIgnoringDerivedCard({
  required bool isDerivedCard,
  required bool hasLocalPages,
  required bool isFlat,
}) => hasLocalPages || isFlat;

/// 忽略 `hasLocalPages` 的资格判据 —— 只看"不是产物卡"。
///
/// 🔴 不能写成 `!isDerivedCard && isFlat`：那样对 `(false, false, false)` 返回
/// false，红路径就**不翻脸**（实测：这一条第一版就是这么写的，报"仍绿(装饰品)"）。
/// "忽略某一条"的意思是**把它从合取式里拿掉**，不是换成别的项。
bool _eligibleIgnoringLocalPages({
  required bool isDerivedCard,
  required bool hasLocalPages,
  required bool isFlat,
}) => !isDerivedCard;

/// 忽略 `isFlat` 的资格判据。
bool _eligibleIgnoringFlat({
  required bool isDerivedCard,
  required bool hasLocalPages,
  required bool isFlat,
}) => !isDerivedCard && hasLocalPages;

/// 不看磁盘、一律认为可选的那一版。
StudioChapterOption _alwaysSelectable() => const StudioChapterOption(
  ref: StudioChapterRef(eid: 'x', label: 'x', chapterName: 'x'),
  pageCount: 1,
);

/// 不查长度的命名校验。
String? _problemWithoutLength(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'empty';
  if (trimmed == '.' || trimmed == '..') return 'separator';
  if (trimmed.contains('/') || trimmed.contains(r'\')) return 'separator';
  return null;
}

/// 什么都不排除的那一版"主页本地栏可见性"（红路径的对照物）。
bool _showsEverythingInHomeLocal(String? id) => true;

/// 按 `comicType == ComicType.local` 分类的那一版卡片判据。
///
/// `bt_`/`ft_` 两张产物卡**都**是按 `local` 登记的 ⇒ 这一版会把 `ft_` 判成工程，
/// 而真正从网络源下载的素材（`comic_type` 是源类型）被判成素材 —— 恰好是
/// "成品混进工程段、素材倒是对的"这种半对，最难发现。
ComicCardKind _kindByComicType({required bool isLocalType}) =>
    isLocalType ? ComicCardKind.project : ComicCardKind.downloaded;

/// 本地库页是不是按 [comicCardKindOf] 三分，而不是就地写前缀判断。
bool _librarySplitsByCardKind(String source) =>
    source.contains('comicCardKindOf(') &&
    !source.contains('BtProjectManager.isBtComic');

/// 一个页面是不是**引用共享排除清单**，而不是就地再写一遍 `isBtComic`。
///
/// 🔴 反向条件不能省：只查"有没有引用清单"的话，一份**同时**引用清单又内联
/// `isBtComic` 的代码也会通过，而漂移照样会发生。
///
/// "共享"的两种形态都算：主页直接传 `hiddenFromHomeLocalPrefixes` 给查询，
/// 或调 `isShownInHomeLocal`（它内部由同一份清单推出来）。
/// 🔴 反向条件不能省：只查"有没有引用"的话，一份**同时**引用又内联 `isBtComic`
/// 的代码也会通过，而漂移照样会发生。
bool _usesSharedHiddenPrefixList(String source) =>
    (source.contains('hiddenFromHomeLocalPrefixes') ||
        source.contains('isShownInHomeLocal')) &&
    !source.contains('BtProjectManager.isBtComic');

/// 切出一个**顶层类**的正文（[decl] 形如 `class _LocalState`）。
///
/// 类的收尾大括号在列 0，所以找 `\n}`。方法收尾是缩进过的 `\n  }`，不会撞上。
String _classBodyOf(String source, String decl) {
  final start = source.indexOf(decl);
  if (start < 0) return '';
  final end = source.indexOf('\n}', start);
  return end < 0 ? source.substring(start) : source.substring(start, end);
}

/// 切出一个**方法**的正文（[signature] 形如 `List<X> _foo()`）。
///
/// 方法收尾是缩进两格的 `\n  }`；顶层类的 `\n}` 不会被误认（前面多了两个空格）。
String _methodBodyOf(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) return '';
  final end = source.indexOf('\n  }', start);
  return end < 0 ? source.substring(start) : source.substring(start, end);
}

/// 卡片种类判据是不是**读各管理器自己的前缀常量**。
bool _readsOwnerPrefix(String source) =>
    source.contains('BtProjectManager.idPrefix') &&
    source.contains('FinishedExport.idPrefix');

/// `local.dart` 里每一条带 `?` 占位符的排除 SQL **是不是都绑了参数**。
///
/// 做法：找每一处 `WHERE $where`，看它后面一段窗口里有没有
/// `_prefixExclusionArgs(`。同时要求占位符真的用了 `substr(...) <> ?`
/// 而不是 `LIKE 'bt_%'`。
bool _prefixExclusionIsBound(String source) {
  if (!source.contains('substr(id, 1, ?) <> ?')) return false;
  // 🔴 `LIKE` 里的 `_` 是单字符通配符：`'bt_%'` 会连 `btX…` 一起命中。
  // 只扫 `_prefixExclusionWhere` 的**函数体**：注释里必然要写"别用
  // `NOT LIKE 'bt_%'`"，整文件扫会恒假（判据就成了永远不通过的装饰品）。
  final whereBody = _methodBodyOf(source, 'String _prefixExclusionWhere(');
  if (whereBody.isEmpty || whereBody.contains('LIKE')) return false;
  const needle = 'WHERE \$where';
  var found = 0;
  var idx = source.indexOf(needle);
  while (idx >= 0) {
    found++;
    final end = idx + 400 < source.length ? idx + 400 : source.length;
    if (!source.substring(idx, end).contains('_prefixExclusionArgs(')) {
      return false;
    }
    idx = source.indexOf(needle, idx + needle.length);
  }
  return found >= 2;
}

/// 阅读器开关那一侧**是不是**调了共享命名规则，而不是内联一份公式。
bool _usesSharedNameRule(String source) {
  if (!source.contains('studioProjectNameFor(')) return false;
  // 内联公式的指纹：自己做 60 截断，或自己拼 `'$title-…'`。
  final inlined =
      RegExp(r'length\s*>\s*60').hasMatch(source) ||
      RegExp(r'\$title-').hasMatch(source);
  return !inlined;
}

/// 入口是不是**经 `ProjectBootstrap`** 数页，而不是自己列目录。
bool _scansViaBootstrap(String source) =>
    source.contains('ProjectBootstrap.scanPageNames(') &&
    !source.contains('Directory(');

/// `plan(` 的实现体里是不是调了 `scanPageNames(`。
///
/// 🔴 不能直接找第一个 `\n  }` —— 那个签名是多行的，参数表的收尾 `  }) {` 里
/// 就有一个（第一版正是栽在这里：切片在签名处就断了，判据恒为 false）。
/// 所以先定位 `) {`（函数体的开始），再从它往后找收尾大括号。
bool _planDelegatesToScanNames(String source) {
  final signature = source.indexOf('static ProjectBootstrapPlan plan(');
  if (signature < 0) return false;
  final bodyStart = source.indexOf(') {', signature);
  if (bodyStart < 0) return false;
  final rest = source.substring(bodyStart);
  final close = rest.indexOf('\n  }');
  final slice = close < 0 ? rest : rest.substring(0, close);
  return slice.contains('scanPageNames(');
}

/// 页面是不是挂了共享的 `StudioProjectMenu`（而不是手搭一个菜单）。
bool _mountsSharedMenu(String source) =>
    source.contains('StudioProjectMenu()') &&
    !RegExp(r'PopupMenuButton<\s*String\s*>\(').hasMatch(source);

/// 这段源码是不是**只**经 `StudioReaderLink` 建工程（不自己调 bootstrap）。
bool _usesReaderLink(String source) =>
    source.contains('StudioReaderLink.locate(') &&
    source.contains('StudioReaderLink.ensureBinding(') &&
    !source.contains('ProjectBootstrap.create(');

/// 这段源码是不是用公开的 id 助手，而不是内联哈希。
bool _usesPublicIdHelper(String source) =>
    source.contains('comicIdForJsonFile(') && !source.contains('0x811c9dc5');

/// id 算法是不是只剩一个公开实现（没有同名私有包装）。
bool _singleIdImplementation(String source) =>
    source.contains('static String comicIdForJsonFile(') &&
    !source.contains('static String _comicIdFor(');

/// 章节候选是不是经纯逻辑层的 `studioChapterRefs` 建的（而不是在 UI 里拼）。
bool _delegatesChapterRefs(String source) =>
    source.contains('studioChapterRefs(');

/// 同一话两个版本的章节矩阵。
///
/// 🔴 顺序是这一条判据的关键：`ComicChapters.versioned` 按 `uploadedAt` **新的
/// 在前**排版本，而 `ids` 取第一位。所以这里让 **DivaScans 更新**（排在首位）、
/// **Asura Scans 是用户下载的那一版**（排在后面）。于是"忘了看哪一版已下载"
/// 的实现必然给出 `k-diva`。
ComicChapters _twoVersionChapter() => ComicChapters.versioned({
  '1': [
    ComicChapterVersion(
      title: 'Ch 1',
      chapterKey: 'k-diva',
      scanlationGroup: 'DivaScans',
      uploadedAt: DateTime(2026, 1, 10),
    ),
    ComicChapterVersion(
      title: 'Ch 1',
      chapterKey: 'k-asura',
      scanlationGroup: 'Asura Scans',
      uploadedAt: DateTime(2026, 1, 1),
    ),
  ],
});

/// 无章节漫画的伪章节 —— 用空串当 eid 的那一版。
List<StudioChapterRef> _flatRefsWithBlankEid() => const [
  StudioChapterRef(eid: '', label: '', chapterName: ''),
];

/// 这段源码是不是自己算了一遍工程根（而不是调 `defaultProjectsRoot`）。
bool _inlinesProjectsRoot(String source) =>
    source.contains('.parent.path') && source.contains('/projects');

/// 这段源码有没有把"工程建在哪儿"交给唯一那份规则
/// （`BtProjectManager.defaultProjectsRoot`），而不是自己内联一份
/// "上一级 + `/projects`"。
///
/// 🔴 判据本身就是"调了它 **且** 没有内联"—— 两条缺一不可：只查前半条时，
/// 一份"调了之后又自己拼一遍"的源码照样通过，而那种写法最终用的是拼出来的
/// 那个路径。
bool _usesTheManagedProjectsRoot(String source) =>
    source.contains('BtProjectManager.defaultProjectsRoot()') &&
    !_inlinesProjectsRoot(source);

/// 这段源码有没有核对"工程真的被登记了"。
bool _reportsUnlistedProject(String source) =>
    source.contains('projectFor(') && source.contains('listed:');
