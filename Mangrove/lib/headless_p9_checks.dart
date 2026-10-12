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
import 'dart:math' as math;

import 'package:mangrove/foundation/bt_project/bt_project_manager.dart';
import 'package:mangrove/foundation/comic_card_kind.dart';
import 'package:mangrove/foundation/comic_deletion.dart';
import 'package:mangrove/foundation/comic_source/comic_source.dart';
import 'package:mangrove/foundation/image_translation/font_fit.dart';
import 'package:mangrove/foundation/translation_project/chapter_translation_state.dart';
import 'package:mangrove/foundation/translation_project/studio_project_entry.dart';
import 'package:mangrove/foundation/translation_project/studio_reader.dart';
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
const _deletionPath = 'lib/foundation/comic_deletion.dart';
const _deleteDialogPath = 'lib/pages/comic_delete_dialog.dart';

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

  // ── 删除：记录在哪、文件在哪、删到哪一步为止（S9.6）─────────────────
  //
  // 这一批三件事全是"写错不报错、只是把用户的东西删了"那一类，所以判据放在
  // `comic_deletion.dart`（纯逻辑可喂故障），弹窗只负责摆出来。

  probe(
    'deletion.record_home_follows_the_card_kind',
    // 工程卡的"记录"**就是**磁盘上那个 `imgtrans_*.json`（`BtProjectManager`
    // 每次扫描按它重建 `local.db` 那一行）⇒ 只删记录 = 下次扫描原地复活。
    // 素材/成品的记录是 `local.db` 的一行，删了就没了。
    () =>
        comicRecordHomeOf(ComicCardKind.project) ==
            ComicRecordHome.projectJson &&
        comicRecordHomeOf(ComicCardKind.downloaded) ==
            ComicRecordHome.database &&
        comicRecordHomeOf(ComicCardKind.product) == ComicRecordHome.database &&
        comicRecordReturnsAfterDelete(ComicCardKind.project) &&
        !comicRecordReturnsAfterDelete(ComicCardKind.downloaded) &&
        !comicRecordReturnsAfterDelete(ComicCardKind.product),
    // 故障路径 = 三类一律当"记录在数据库"的那一版。它的症状是弹窗里**没有**
    // "工程下次扫描会回来"那句警告 —— 用户反复删同一本工程，每次都以为成功了。
    () => _recordHomeIgnoringKind(ComicCardKind.project) ==
            ComicRecordHome.projectJson &&
        _recordHomeIgnoringKind(ComicCardKind.downloaded) ==
            ComicRecordHome.database &&
        _recordHomeIgnoringKind(ComicCardKind.product) ==
            ComicRecordHome.database &&
        _returnsAfterDeleteIgnoringKind(ComicCardKind.project) &&
        !_returnsAfterDeleteIgnoringKind(ComicCardKind.downloaded) &&
        !_returnsAfterDeleteIgnoringKind(ComicCardKind.product),
    () => '绿=工程卡记录来自磁盘 json、素材/成品来自数据库 / '
        '故障=一律当数据库的那版在工程卡上不成立',
  );

  probe(
    'deletion.refuses_to_step_outside_the_library',
    // "宁可不删，也不删过头"：`comicOnDiskRoot` 的输入全来自数据库/工程 json，
    // 任何一个字段为空都会让"join(库, 空)"算成**库本身**。所以落盘前一律过守卫。
    () => _deletionGuardHolds(comicRootIsSafeToDelete),
    // 故障路径 = 没有任何守卫的那一版（只判"非空"）。
    () => _deletionGuardHolds(_unguardedRootIsSafeToDelete),
    () => '绿=漫画库自身/其上层/三个分类根/相对路径一律拒绝，真漫画放行 / '
        '故障=无守卫的版本会同意删掉漫画库本身',
  );

  probe(
    'deletion.never_asks_local_manager_to_delete_files',
    // 🔴 `LocalManager.batchDeleteComics(removeFileOnDisk: true)` 一律
    // `join(path, c.directory)`，而工程/成品卡存的是**绝对**路径 —— `path.join`
    // 不覆盖前段，拼出一个不存在的路径 ⇒ 目录静静留在磁盘上，记录却没了
    // （用户看到"删掉了"但文件夹还在）。所以那条路的这个开关必须恒为 false，
    // 目录由本模块自己按种类解析。
    () => _deletionPassesDoNotDeleteFiles(
      _classBodyOf(code(_deletionPath), 'ComicDeletionReport deleteLocalComics('),
    ),
    // 故障路径 = 把 scope 直接透传下去的那一版（正是修复前的行为）。
    () => _deletionPassesDoNotDeleteFiles(
      _classBodyOf(
        _scopeForwardingDeletionSource,
        'ComicDeletionReport deleteLocalComics(',
      ),
    ),
    () => '绿=删除模块自己解析路径、不让 LocalManager 动盘 / '
        '故障=透传 removeFileOnDisk 的版本在工程/成品上静默失效',
  );

  probe(
    'deletion.dialog_names_what_is_deleted',
    // 用户点的是"删除这一本"，弹窗必须写出**标题 + 路径** —— 旧弹窗只有一个
    // `Delete` 标题加两个勾选框，"删的是哪一本"只存在于他刚才点的那格列表里。
    () => _deleteDialogNamesTheTarget(code(_deleteDialogPath)),
    // 故障路径 = 修复前那个弹窗的原文（标题固定、不列标题、不列路径）。
    () => _deleteDialogNamesTheTarget(_oldDeleteDialogSource),
    () => '绿=弹窗逐本列出标题与磁盘路径 / '
        '故障=旧弹窗（写死的 Delete 标题 + 两个勾选框）不满足判据',
  );

  // ── 绑定表：工程删掉之后，那条绑定就不能再当"已有工程"（P14）─────────
  //
  // 🔴 这两个断言钉的是"删了工程却建不回来"：绑定表是磁盘的**缓存**，工程被删除
  // （应用内删 / 资源管理器里删 / 同步覆盖）之后表里那条会变成**幽灵** —— 创建
  // 向导据此把这一章判成"已有工程"、把用户挡在创建门外；点【创建】弹出的是
  // "已打开既有工程"，工程文件夹显示为空、跳转按钮永远不亮，而磁盘上明明已经
  // 删干净了（2026-10-09 实测）。

  probe(
    'binding.json_gone_is_not_a_project',
    // 行为判据：**同一条**绑定，json 在 ⇒ 查得出来；json 没了 ⇒ 查不出来。
    () => _ghostBindingRejected(_liveBindingLookup),
    // 故障路径 = 只看键、不核磁盘的那一版（修复前的 `operator []`）。
    () => _ghostBindingRejected(_keyOnlyBindingLookup),
    () => '绿=json 没了就不算已有工程 / '
        '故障=只看键的那版仍把幽灵绑定当工程',
  );

  probe(
    'deletion.purges_the_reader_binding_of_the_deleted_project',
    // 行为判据：按 json 清理时**只有**指向它的那条消失，其余原样保留。
    () => _purgeRemovesExactly(_purgeByJsonPath),
    // 故障路径 = 什么都不删的那一版（幽灵绑定会永远留在表里）。
    () => _purgeRemovesExactly(_purgeDoesNothing),
    () => '绿=只清掉指向被删工程的那条绑定 / '
        '故障=不清理的那版把幽灵绑定留在表里',
  );

  // ── 工程 id 与封面路径：两条会静默错位的路径规则（P14 追补）───────────
  //
  // 🔴 这两条钉的是同一类 bug 的两个面：**同一个工程，两个地方算出两个答案**。
  // * id：`scan()` 手里的路径来自 `Directory.list()`（Windows 上是 `\`），创建
  //   向导手里的路径来自 `ProjectBootstrap`（`/`）—— 不归一化就算出两个 id，
  //   于是刚建好的工程"不在工作室工程根目录下"、点【打开翻译工程】跳进去空白，
  //   而本地库/主页从 DB 拿到的是另一个变体所以看上去一切正常（2026-10-09 实测）；
  // * 封面：工程 json 的 `directory` 指 `<工程根>/source/`，而封面 `cover.<ext>`
  //   落在**工程根** —— 只查 `directory` 的那版会 miss，然后回落到"章节第一页"，
  //   卡片上看起来完全正常（就是用了错的那张图）。

  probe(
    'the_project_id_is_separator_insensitive',
    // 行为判据：**同一个 json** 用 `/` 与 `\` 两种写法必须算出同一个 id。
    () => _idIsSeparatorInsensitive(BtProjectManager.comicIdForJsonFile),
    // 故障路径 = 不归一化分隔符的那一版（修复前的实现）。
    () => _idIsSeparatorInsensitive(_rawComicId),
    () => '绿=id 对分隔符不敏感 / 故障=不归一化的版本在 `\\\\` 上算出另一个 id',
  );

  probe(
    'cover.in_the_project_folder_is_found',
    // 行为判据：封面在 `source/` 里 ⇒ 命中；只在**工程根**（json 同级）里 ⇒ 也
    // 命中；两处都没有 ⇒ null（必须要求 null，否则一个"恒返回某个路径"的实现
    // 也能通过）。
    () => _coverFoundInBothPlaces(BtProjectManager.resolveCoverFile),
    // 故障路径 = 只查 `directory` 的那一版（修复前的查找范围）。
    () => _coverFoundInBothPlaces(_directoryOnlyCover),
    () => '绿=封面查 source/ 与工程根两处 / '
        '故障=只查 source 的版本找不到工程根的封面',
  );

  // ── 扫描器：对账表 sidecar 不是工程（P16）──────────────────────────────
  //
  // 🔴 钉的是"保存一次就多一张空卡片"：产物对账表 `imgtrans_<名>.artifacts.json`
  // 与工程 json **同级**、同样 `imgtrans_` 开头 `.json` 结尾，旧的"前缀 + 后缀"
  // 判据把它当成第二个工程登记 ⇒ 本地库/主页多一张**零页**幽灵卡片，删真实工程
  // 也带不走它（它挂的是同一本工程所在的目录）——2026-10-09 实测：按一次保存
  // 就多一个，而磁盘上明明只有两个工程。

  probe(
    'scan.artifacts_sidecar_is_not_a_project',
    // 行为判据：真工程算；对账表 sidecar 不算；备份/无关文件也不算。
    () => _sidecarIsNotAProject(BtProjectManager.isProjectJsonFileName),
    // 故障路径 = 修复前的前缀+后缀判据（sidecar 会漏进来）。
    () => _sidecarIsNotAProject(_legacyProjectNameRule),
    () => '绿=对账表 sidecar 不算工程 / '
        '故障=只查前缀与后缀的旧判据把 sidecar 也当工程',
  );

  // ── 字号上限：用户设置的字号不能被"检测到的源字号"压住（P15）──────────
  //
  // 🔴 钉的是"把字号滑块拖到 120，屏幕上的字纹丝不动"：`_fitFontSize` 里原本是
  // `min(42, lineHeight*0.9, maxFontSize)` 三个 `min` 连乘，而检测块的
  // `font_size` 恰好等于 `_detected_font_size`（`text_block.dart` 写入时同源），
  // 于是用户的请求永远被源字号（或那个写死的 42）压住。P0-1 声称"把 `font_size`
  // 交给渲染器"，实际效果被这两层 `min` 完全抵消（2026-10-09 实测）。

  probe(
    'font.the_user_size_wins_over_the_measured_lettering',
    // 行为判据：用户把字号从检测值(49)拖到 120 ⇒ 上限就是 120；拖小到 10 ⇒ 10。
    () =>
        fitFontSizeCap(requested: 120, measured: 49) == 120 &&
        fitFontSizeCap(requested: 10, measured: 49) == 10,
    // 故障路径 = 修复前的三个 `min` 连乘：120 被压回 49*0.9 = 44.1。
    () => _capByEverything(requested: 120, measured: 49) == 120,
    () => '绿=用户设定的字号就是上限 / 故障=旧 min 连乘把 120 压回 44.1',
  );

  probe(
    'font.untouched_block_keeps_the_measured_cap',
    // 行为判据：没动过滑块的块（`font_size` == 检测值）沿用 0.9 的源字号补偿，
    // 行为**不变**；两个值都没有时回落到 42。
    () =>
        (fitFontSizeCap(requested: 49, measured: 49) - 44.1).abs() < 0.01 &&
        (fitFontSizeCap(requested: null, measured: 49) - 44.1).abs() < 0.01 &&
        fitFontSizeCap(requested: null, measured: 0) == 42.0,
    // 故障路径 = 丢掉 0.9 补偿的那一版（译文会和原文一样大）。
    () => _noSourceScaleCompensation(requested: 49, measured: 49) == 44.1,
    () => '绿=未动过的块保留源字号补偿 / 故障=不做补偿的那版返回 49',
  );

  // ── 章节「已翻译」判据：并集，不是"换成工程"（P17）────────────────────
  //
  // 🔴 钉的是 S9.5-b 留下的半迁移：产出搬进了工作室（成品落工程 `result/`），
  // 但详情页**读**那一侧有四处仍只读旧 `TranslationStore`，而工作室管线一行都
  // 不写它 ⇒ 用户用工作室翻完一整章之后，章节列表**看不到**已翻译标记、
  // 长按菜单里**没有**「重译/删除」、「已翻译」页签**筛不出**这一章。
  // 症状与"翻译没生效"几乎一样，但译文其实就在 `result/` 里躺着。
  //
  // 🔴 为什么判据是**并集**而不是替换：旧库里躺着 S9.5-b 之前翻的、别处同步来
  // 的章。改成只认工程 ⇒ 那些章的标记/菜单/页签**全部消失** —— 从"能看见"
  // 变成"看不见"，是更糟的回归。所以两侧任一有成品就算已翻译。

  probe(
    'chapter_state.the_union_survives_both_sides',
    // 行为判据（四个场景一次比完，绿红两版喂**同一组**输入）：
    // ① 只有工作室侧有 90 页 ⇒ 已翻译（S9.5-b 之前**判不出来**的那一支）；
    // ② 两侧都有 ⇒ both；
    // ③ 只有旧库有 12 页 ⇒ 仍然已翻译（"只认工程"会**弄丢**的那一支）；
    // ④ 两侧都为 0 ⇒ 未翻译且不显示徽标；负数夹到 0。
    () => _chapterStateActual(_chapterTranslationSourceUnion) == _chapterStateTruth,
    // 故障路径 A = **只读旧库**（S9.5-b 之前那一版）：工作室侧整个被丢掉。
    () => _chapterStateActual(_chapterTranslationSourceLegacyOnly) == _chapterStateTruth,
    () => '绿=并集四场景全对 / '
        '故障=只读旧库(工作室侧丢) / 另两个故障副本由下一条断言钉住',
  );

  probe(
    'chapter_state.the_other_two_faults_are_caught_too',
    // 🔴 `probe` 只有**一条**红路径，而这一轮踩到的坑正是"红路径写成另一个也成立
    // 的输入 ⇒ 断言变装饰品"。所以另两个故障副本（只认工程 / 有绑定就算）
    // 单独用一条断言钉：要求它们**都**与产品版结论不同。
    //
    // 这一条的红路径 = "判据不再区分两侧"（产品版与故障版给出同一个结论）
    // —— 那正是"把两侧并成同一个数"这类改写会造成的退化，此时本条与上一条
    // 一起失效。
    () =>
        _chapterStateActual(_chapterTranslationSourceStudioOnly) !=
            _chapterStateTruth &&
        _chapterStateActual(_chapterTranslationSourceBindingIsEnough) !=
            _chapterStateTruth,
    () => _chapterStateActual(_chapterTranslationSourceStudioOnly) ==
            _chapterStateTruth,
    () => '绿=只认工程/有绑定就算 两个故障版都判出不同结论 / '
        '故障=判据不再区分两侧时本条与上一条一起失效',
  );

  probe(
    'chapter_state.the_badge_counts_both_sides',
    // 行为判据：徽标页数 = 两侧**之和**（90+3=93）。工作室的 `result/` 与旧缓存
    // 的页是**不同的页集合**（工程页键 vs `cacheKey`），相加不重复计数；取 max
    // 会让"工作室翻了 90 页、旧缓存 3 页"显示成 90 —— 用户以为只翻了 90，
    // 实际 93 页有成品。徽标与页签归属必须**同源**。
    () => _badgeActual(_badgeUnion) == _badgeTruth,
    // 故障路径 = 取 max 的那一版：3 页旧缓存被吞掉，显示成 90。
    () => _badgeActual(_badgeMax) == _badgeTruth,
    () => '绿=徽标页数取两侧之和(90+3=93) / 故障=取 max 时 3 页被吞',
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

/// 切出一个**顶层声明的正文**（[decl] 形如 `class _LocalState` 或一个顶层函数
/// 的签名）。收尾锚点是**列 0 的收尾大括号**：`\n}\n`，不是裸的 `\n}`。
///
/// 🔴 这条纪律是修出来的，不是想出来的。带具名参数、签名跨行的顶层函数在参数
/// 表收尾处就有 `\n}) {` —— 那**也是**一个 `\n}`。拿它当收尾会把函数体整段切掉：
/// `deleteLocalComics` 实测切出 144 个字符（只有签名），于是
/// `deletion.never_asks_local_manager_to_delete_files` 的绿路径恒假 —— 一条
/// 报"绿路径=FALSE"的断言，而原因是**切片器**，不是被测代码。
///
/// 方法收尾是缩进两格的 `\n  }`，顶层类/函数的收尾在列 0 —— 两者不会撞上。
String _classBodyOf(String source, String decl) {
  final start = source.indexOf(decl);
  if (start < 0) return '';
  final end = _topLevelCloseAfter(source, start);
  return end < 0 ? source.substring(start) : source.substring(start, end);
}

/// [from] 之后第一个"列 0 的收尾大括号"的位置（`}` 后面必须是换行或文件末）。
///
/// 找不到返回 `-1`。**不要**退化成裸 `indexOf('\n}')` —— 见 [_classBodyOf]。
int _topLevelCloseAfter(String source, int from) {
  var at = source.indexOf('\n}', from);
  while (at >= 0) {
    final next = at + 2;
    if (next >= source.length || source[next] == '\n') return at;
    at = source.indexOf('\n}', next);
  }
  return -1;
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

// ── 删除（S9.6）红路径的对照物 ────────────────────────────────────────

/// 三类卡片一律当"记录在数据库"的那一版（丢掉了工程卡的 json 身份）。
ComicRecordHome _recordHomeIgnoringKind(ComicCardKind kind) =>
    ComicRecordHome.database;

/// "删了不会回来"的那一版 —— 工程卡的下一次扫描会把它原地恢复。
bool _returnsAfterDeleteIgnoringKind(ComicCardKind kind) => false;

/// 没有任何守卫的那一版落盘判据：只判"非空"。
///
/// 这正是写这个守卫之前的形态 —— `join(库, '')` 算成库本身，于是一次字段为空的
/// 删除会请求删掉**整个漫画库**。
bool _unguardedRootIsSafeToDelete(String root, {String? libraryRoot}) =>
    root.trim().isNotEmpty;

/// 「宁可不删，也不删过头」那一组判据，喂一个 [guard] 实现。
///
/// 🔴 绿/红走的是**同一个函数**，只换传入的 guard：条款写在函数体里，红路径就
/// 不可能只覆盖其中一半（P9.3 栽过的坑 —— 红路径只写判据的片段，极性会反过来）。
bool _deletionGuardHolds(
  bool Function(String root, {String? libraryRoot}) guard,
) {
  const lib = r'D:\lib\downloads';
  bool safe(String root) => guard(root, libraryRoot: lib);
  return !safe(lib) && // 漫画库自身：`join(lib, '')` 会算成它
      !safe(r'D:\lib') && // 它上面一层
      !safe(r'D:\lib\projects') && // 三个分类根是**容器**，不是某一本
      !safe(r'D:\lib\translated') &&
      !safe('relative/thing') && // 相对路径靠 CWD，拒绝
      !safe('') &&
      safe(r'D:\lib\downloads\Some Comic') && // 真素材
      safe(r'D:\lib\translated\Some Product') && // 真成品
      safe(r'D:\lib\projects\Some Project'); // 真工程
}

/// 删除模块是不是**不**让 `LocalManager` 去动盘（`removeFileOnDisk` 恒 false）。
///
/// 🔴 切的是整个**顶层函数体**，用 [_classBodyOf]（收尾是列 0 的 `\n}\n`）。
/// `_methodBodyOf` 在这里不适用两遍：它的收尾锚点是缩进两格的 `\n  }`，而这个
/// 函数体里第一个两格缩进的 `}` 是 `if (scope == …)` 的收尾 —— 切出来的片段在
/// `batchDeleteComics` **之前**就断了，判据恒假。
bool _deletionPassesDoNotDeleteFiles(String source) =>
    source.contains('batchDeleteComics(comics, false,');

/// 把 `removeFileOnDisk` 直接透传下去的那一版（修复前的形态）。
const _scopeForwardingDeletionSource = '''
ComicDeletionReport deleteLocalComics(
  List<LocalComic> comics, {
  required ComicDeletionScope scope,
  bool removeFavoriteAndHistory = true,
}) {
  final manager = LocalManager();
  manager.batchDeleteComics(
    comics,
    scope == ComicDeletionScope.recordsAndFiles,
    removeFavoriteAndHistory,
  );
  return const ComicDeletionReport(
    recordsRemoved: 0, dirsRemoved: 0, dirsRefused: [], dirsMissing: []);
}
''';

/// 修复前那个删除弹窗的原文（标题写死、不列标题、不列路径）。
const _oldDeleteDialogSource = '''
ContentDialog(
  title: "Delete".tl,
  content: Column(children: [
    CheckboxListTile(
      title: Text("Remove local favorite and history".tl), value: true),
    CheckboxListTile(title: Text("Also remove files on disk".tl), value: true),
  ]),
  actions: [FilledButton(child: Text("Confirm".tl))],
)
''';

/// 弹窗有没有写清"删的是哪一本"：标题带名字、逐本列标题、逐本列磁盘路径。
///
/// 三条缺一不可 —— 只查"有没有 `comic.title`"时，一个把书名当装饰画在角落、
/// 却不写路径的弹窗照样通过；而用户要确认的正是"这本的东西在哪、我会删到哪
/// 一层"。
bool _deleteDialogNamesTheTarget(String source) =>
    source.contains('Delete "@title"?') &&
    source.contains('comic.title') &&
    source.contains('comicOnDiskRoot(comic)');

// ── 绑定表（P14）：幽灵绑定的判据与对照物 ───────────────────────────────

/// 探测用的绑定键。
const _ghostKey = 'cid@comic@1';

/// 判据：**同一条**绑定里，json 在 ⇒ 查得到，json 没了 ⇒ 查不到。
///
/// 🔴 两个方向都要查：只查"没了查不到"时，一个恒返回 null 的实现也会通过 ——
/// 那正是这条断言最该挡住的东西（一个什么都没做对的实现）。
bool _ghostBindingRejected(
  StudioReaderBinding? Function(StudioReaderBindings table, bool jsonExists)
  lookup,
) {
  final table = StudioReaderBindings({
    _ghostKey: const StudioReaderBinding(
      jsonPath: 'D:/lib/projects/P/imgtrans_P.json',
      comicDirectory: 'D:/lib/downloads/C',
      projectDirectory: 'D:/lib/projects/P/source',
    ).toJson(),
  });
  return lookup(table, true) != null && lookup(table, false) == null;
}

/// 绿路径：经 `liveBindingFor` 把"json 在不在"喂进去（真实现）。
StudioReaderBinding? _liveBindingLookup(
  StudioReaderBindings table,
  bool jsonExists,
) => table.liveBindingFor(_ghostKey, jsonExists: (_) => jsonExists);

/// 故障路径：只看键的那一版（修复前 `bindingFor` 的行为）。
StudioReaderBinding? _keyOnlyBindingLookup(
  StudioReaderBindings table,
  bool jsonExists,
) => table[_ghostKey];

/// 判据：按 json 清理时，**只有**指向它的那条被删，其余原样保留。
///
/// 🔴 必须要求"另一条还在"：只查"少了一条"时，一个把整张表清空的实现也会通过。
bool _purgeRemovesExactly(List<String> Function(StudioReaderBindings) purge) {
  StudioReaderBinding binding(String name) => StudioReaderBinding(
    jsonPath: 'D:/lib/projects/$name/imgtrans_$name.json',
    comicDirectory: 'D:/lib/downloads/C',
    projectDirectory: 'D:/lib/projects/$name/source',
  );
  final table = StudioReaderBindings({
    'cid@c@1': binding('A').toJson(),
    'cid@c@2': binding('B').toJson(),
  });
  final removed = purge(table);
  return removed.length == 1 &&
      removed.single == 'cid@c@1' &&
      table['cid@c@1'] == null &&
      table['cid@c@2'] != null;
}

/// 绿路径：真实现（按 json 路径清理）。
List<String> _purgeByJsonPath(StudioReaderBindings table) =>
    table.removeForJsonPath('D:/lib/projects/A/imgtrans_A.json');

/// 故障路径：什么都不删的那一版。
List<String> _purgeDoesNothing(StudioReaderBindings table) => const [];

/// 判据：`/` 与 `\` 两种分隔符必须算出**同一个** id。
bool _idIsSeparatorInsensitive(String Function(String) idFor) =>
    idFor('D:/lib/projects/P/imgtrans_P.json') ==
    idFor(r'D:\lib\projects\P\imgtrans_P.json');

/// 故障路径：不归一化分隔符的那一版（修复前的 `comicIdForJsonFile`）。
///
/// 用 `jsonPath.hashCode` 冒充是不够的 —— 红路径必须检验**同一个命题**，所以
/// 这里照抄修复前的实现（同一套 FNV，只少了那一步 `replaceAll`）。
String _rawComicId(String jsonPath) {
  var hash = 0x811c9dc5;
  for (final unit in jsonPath.toLowerCase().codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return 'bt_${hash.toRadixString(16).padLeft(8, '0')}';
}

/// 判据：封面在 `directory`（= 工程 `source/`）里 **或** 在工程根（json 同级）
/// 里都算找到；两处都没有必须返回 null。
///
/// 用**真临时目录**而不是假路径：这条规则的错法就是"少查了一处"，而少查的那处
/// 在假路径上永远不存在 —— 假路径喂出来的判据恒真，等于没验。
bool _coverFoundInBothPlaces(
  String? Function({
    required String directory,
    required String jsonPath,
    required String key,
  })
  resolve,
) {
  final tmp = Directory.systemTemp.createTempSync('mangrove_p9_cover');
  try {
    final root = '${tmp.path.replaceAll('\\', '/')}/proj';
    final source = '$root/source';
    Directory(source).createSync(recursive: true);
    final jsonPath = '$root/imgtrans_P.json';
    File(jsonPath).writeAsStringSync('{}');
    // (a) 只有工程根有封面（`ProjectBootstrap` 当前写的位置）。
    File('$root/cover.jpg').writeAsBytesSync(const [1, 2, 3]);
    final inRoot = resolve(
      directory: source,
      jsonPath: jsonPath,
      key: 'cover.jpg',
    );
    // (b) 只有 `source/` 有封面（`setCover` 写的位置）。
    File('$root/cover.jpg').deleteSync();
    File('$source/cover.jpg').writeAsBytesSync(const [4, 5, 6]);
    final inSource = resolve(
      directory: source,
      jsonPath: jsonPath,
      key: 'cover.jpg',
    );
    // (c) 两处都没有 ⇒ 不能报"找到了"。
    File('$source/cover.jpg').deleteSync();
    final missing = resolve(
      directory: source,
      jsonPath: jsonPath,
      key: 'cover.jpg',
    );
    return inRoot != null && inSource != null && missing == null;
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录清不掉不该让判据翻脸。
    }
  }
}

/// 故障路径：只查 `directory` 的那一版（修复前 `coverPathFor` 的查找范围）。
String? _directoryOnlyCover({
  required String directory,
  required String jsonPath,
  required String key,
}) {
  final path = '${directory.replaceAll('\\', '/')}/$key';
  return File(path).existsSync() ? path : null;
}

// ── 扫描器名字判据（P16）红路径的对照物 ───────────────────────────────

/// 判据：真工程 json 算工程；对账表 sidecar（`imgtrans_<名>.artifacts.json`）不算；
/// 备份与无关文件本来就不满足。
///
/// 🔴 "真工程算"这一支不能省：若只断言 sidecar 被排除，一个"恒返回 false"的实现
/// 也会通过 —— 而那会让**所有**工程从列表里消失（比多一张空卡片严重得多）。
bool _sidecarIsNotAProject(bool Function(String) isProject) {
  final project = isProject('imgtrans_MDGH-ch1.json');
  final sidecar = isProject('imgtrans_MDGH-ch1.artifacts.json');
  final backup = isProject('imgtrans_MDGH-ch1.json.backup');
  final unrelated = isProject('other.json');
  return project && !sidecar && !backup && !unrelated;
}

/// 故障路径：修复前的名字判据（`startsWith('imgtrans_') && endsWith('.json')`）。
bool _legacyProjectNameRule(String name) =>
    name.startsWith('imgtrans_') && name.endsWith('.json');

// ── 字号上限（P15）红路径的对照物 ─────────────────────────────────────

/// 故障路径：修复前的 `min(42, measured*0.9, requested)` 三连压。
///
/// 数值上"绿路径"喂 [fitFontSizeCap]，红路径喂它 —— 同一个判据
/// （"请求 120 就得到 120"）必须一个通过、一个翻脸。
double _capByEverything({
  required double requested,
  required double measured,
}) {
  var cap = 42.0;
  if (measured > 0) cap = math.min(cap, math.max(10.0, measured * 0.9));
  if (requested > 0) cap = math.min(cap, requested);
  return cap;
}

/// 故障路径：不做 0.9 的源字号补偿，直接拿 `measured` 当上限。
double _noSourceScaleCompensation({
  required double? requested,
  required double measured,
}) {
  if (requested != null && requested > 0) return requested;
  return measured > 0 ? measured : 42.0;
}

// ── 章节「已翻译」判据（P17）绿路径与故障路径 ───────────────────────────
// 🔴 为什么要写成"判据函数 + 探针"两层，而不是把输入直接写进断言：
// 2026-10-09 第一版把红路径写成"换一个**也成立**的输入"（例如断言"只有旧库
// 12 页时已翻译"，却拿它当"只读旧库"那个故障的反例）—— 结果四条里有两条的
// 故障路径**仍然是绿的**，等于装饰品。门禁如实报了
// `故障路径=仍绿(装饰品)`（`A02`：失效的断言比不完整的断言危险得多）。
//
// 正确形状：**同一个判据签名**下放多份实现（产品版 + 三个故障版），喂**同一组**
// 输入；断言只比"结论字符串"，于是绿红两版可以直接对照，不必在探针里判断
// "我现在跑的是不是产品版"（那需要函数同一性比较，脆弱且会掩盖真正的失败）。

typedef _ChapterSource = ChapterTranslationSource Function(int, int);

/// 产品版：并集判据（`chapter_translation_state.dart` 的本体）。
ChapterTranslationSource _chapterTranslationSourceUnion(
  int studio,
  int legacy,
) => chapterTranslationSource(
  studioProductPages: studio,
  legacyStoredPages: legacy,
);

/// 故障路径 A：**只读旧 `TranslationStore`** —— S9.5-b 之前详情页那一版。
/// 工作室侧的页数被整个丢掉。
ChapterTranslationSource _chapterTranslationSourceLegacyOnly(
  int studio,
  int legacy,
) => chapterTranslationSource(
  studioProductPages: 0,
  legacyStoredPages: legacy,
);

/// 故障路径 B：**只认工程** —— "迁移"最直觉的那个改法。
/// 旧库里 S9.5-b 之前翻的、WebDAV 同步来的章会被判成未翻译（标记消失）。
ChapterTranslationSource _chapterTranslationSourceStudioOnly(
  int studio,
  int legacy,
) => chapterTranslationSource(
  studioProductPages: studio,
  legacyStoredPages: 0,
);

/// 故障路径 C：**有绑定就算已翻译**（不数产物）。
/// 空工程（建完就走了）会混进「已翻译」页签，点进去看到的是原图。
ChapterTranslationSource _chapterTranslationSourceBindingIsEnough(
  int studio,
  int legacy,
) => chapterTranslationSource(
  studioProductPages: studio > 0 ? studio : 1,
  legacyStoredPages: legacy,
);

/// 产品版结论（绿路径应逐字等于这个字符串）。
const String _chapterStateTruth =
    'studioOnly(90,0)=studioOnly; (90,3)=both; (0,12)=legacyOnly; badge(0,12)=12; '
    '(0,0)=none; badge(0,0)=null; tab(-1,-1)=false';

/// 绿路径：产品版在四个场景上的结论。
String _chapterStateActual(_ChapterSource source) {
  final tabNeg = isTranslatedTab(studioProductPages: -1, legacyStoredPages: -1);
  return 'studioOnly(90,0)=${source(90, 0).name}; '
      '(90,3)=${source(90, 3).name}; '
      '(0,12)=${source(0, 12).name}; '
      'badge(0,12)='
      '${translatedPageCountForBadge(studioProductPages: 0, legacyStoredPages: 12)}; '
      '(0,0)=${source(0, 0).name}; '
      'badge(0,0)='
      '${translatedPageCountForBadge(studioProductPages: 0, legacyStoredPages: 0)}; '
      'tab(-1,-1)=$tabNeg';
}

typedef _BadgeCount = int? Function(int, int);

/// 产品版：徽标页数 = 两侧之和。
int? _badgeUnion(int studio, int legacy) =>
    translatedPageCountForBadge(
      studioProductPages: studio,
      legacyStoredPages: legacy,
    );

/// 故障路径：取 **max**。工作室翻了 90 页、旧缓存 3 页 ⇒ 显示 90，
/// 用户以为只翻了 90，实际 93 页有成品。
int? _badgeMax(int studio, int legacy) {
  if (_chapterTranslationSourceUnion(studio, legacy) ==
      ChapterTranslationSource.none) {
    return null;
  }
  return studio > legacy ? studio : legacy;
}

/// 产品版徽标结论（绿路径应逐字等于）。
const String _badgeTruth = 'badge(90,3)=93; badge(0,0)=null; tab(90,0)=true';

/// 绿路径：徽标取两侧之和，且徽标与页签归属**同源**
/// （徽标说有译文，页签就必须把它归到「已翻译」—— 分叉的症状与本文件要修的
/// 那个 bug 是同一个：半迁移）。
String _badgeActual(_BadgeCount badge) {
  final tabStudioOnly = isTranslatedTab(
    studioProductPages: 90,
    legacyStoredPages: 0,
  );
  return 'badge(90,3)=${badge(90, 3)}; '
      'badge(0,0)=${badge(0, 0)}; '
      'tab(90,0)=$tabStudioOnly';
}
