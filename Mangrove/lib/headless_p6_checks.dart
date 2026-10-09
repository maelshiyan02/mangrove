// 「工作室术语表 UI 入口」（A08 §1.1 · C）的断言集。
//
// 覆盖三件事：
//
// * **`StoreGlossaryBackend`** —— 工作室那侧的后端到底有没有把读/写/封杀/解封
//   正确落到 `GlossaryStore` 上，以及它有没有偷偷缓存（`GlossaryStore` 刻意不做
//   进程内缓存，因为 `implicitData` 在导入备份时是**整体替换** —— 缓存住引用
//   会一直服务导入前的旧术语表）。
// * **解耦** —— 编辑器页面必须**不再**直接依赖 `ImageTranslationService`
//   （阅读器的旧引擎单例）。这是"工作室能用同一个编辑器"的前提，也是 S9.5-b
//   删掉旧引擎时它还能活下来的前提。
// * **接线与文案** —— 工作室确实有入口、确实经**绑定表反查**回来源身份
//   （不是拿 `comicId` 当 scope）、按钮 tooltip 确实是中文，且 `headless.dart`
//   的 i18n 扫描确实**覆盖到了**这个页面。
//
// ## 反向验证
//
// 与 P3 / P4 / P5 同源（见 `kb/methodology/M08`）：故障在**运行时**注入 ——
// 同一个判据跑两遍，正确输入必须 true、故意做错必须 false。静态扫描类断言
// 的"做错"尽量用**对照组**实现（拿一个确实含有该特征的**别的**文件跑同一条
// 判据），因为「拿一个不存在的字符串去搜」证明不了判据不是恒真。
//
// ## 这里测不到的
//
// 🔴 编辑器页面的**排版**（说明行会不会挤、列表在小窗口下的观感）需要 GUI 看。
// 本文件只能证明"数据通、解耦成立、接线与文案到位"。
library;

import 'dart:convert';
import 'dart:io';

import 'package:mangrove/foundation/translation_project/glossary_backend.dart';
import 'package:mangrove/foundation/translation_project/glossary_store.dart';
import 'package:mangrove/headless_p1_checks.dart' show CheckSink, tlLiteralKeys;

/// 一条断言：绿路径 + 故障路径 + 可诊断的 detail。
class _Probe {
  const _Probe(this.name, this.green, this.red, this.detail);

  final String name;
  final Future<bool> Function() green;
  final Future<bool> Function() red;
  final String Function() detail;
}

/// 一个干净的后端夹具。
///
/// 🔴 每条断言**自带一份**：共享一个 map 会让断言之间互相污染，从而让"顺序
/// 变了结果就变"这种最糟糕的假绿出现。
class _Fixture {
  _Fixture() {
    store = GlossaryStore(sink: () => map, persist: () => writes++);
    backend = StoreGlossaryBackend(store, scope);
  }

  final Map<String, Object?> map = <String, Object?>{};

  /// 工作室的 scope 现在是**来源漫画身份** `cid@sourceKey`（经绑定表反查），
  /// 不再是 `comicId`。夹具里的具体值不重要，重要的是它是**一个** scope。
  final String scope = 'cid1@comix.to';

  late final GlossaryStore store;
  late final StoreGlossaryBackend backend;

  /// 落盘次数。术语表每次写都必须立刻落盘（崩溃丢了只是重新学一遍）。
  int writes = 0;
}

const _editorPath = 'lib/pages/comic_details_page/glossary_editor.dart';
const _serviceBackendPath =
    'lib/foundation/image_translation/glossary_service_backend.dart';
const _storeBackendPath =
    'lib/foundation/translation_project/glossary_backend.dart';
const _studioPath = 'lib/pages/translation_studio/studio_page.dart';
const _comicPagePath = 'lib/pages/comic_details_page/comic_page.dart';
const _actionsPath = 'lib/pages/comic_details_page/actions.dart';
const _p1Path = 'lib/headless_p1_checks.dart';
const _p5Path = 'lib/headless_p5_checks.dart';
const _headlessPath = 'lib/headless.dart';

/// 工作室作用域的说明文案。既要在 `translation.json` 里登记，也要真的被页面
/// 用 `.tl` 调用 —— 登记了却不调用，用户照样看到英文。
///
/// 🔴 文案是 S9.5-b 之后的新真相：工作室与阅读器现在读的是**同一份**数据
/// （scope 都是 `cid@sourceKey`），差别只剩"翻译组那一层"。
///
/// 🔴 文案里**不能出现撇号 `'`**：`.tl` 扫描器的正则
/// （`(['"])((?:[^'"\\]|\\.)*?)\1`，唯一实现在 `headless_p1_checks.dart`）把两种
/// 引号都当定界符，双引号里的 `chapter's` 会把匹配截断 ⇒ 这条字面量**扫不到**，
/// 于是"已登记"断言看不出问题、而用户在界面上看到的是英文。第一版就是这么写的，
/// 当场被 `i18n.studio_scope_notice_is_actually_used` 抓住。
const _studioNoticeKey =
    'This list belongs to the source comic and is shared with the reader. Edits here apply to the translation group of this chapter.';

/// 阅读器作用域的说明文案。与上面成对：只说半边会让另一半的用户以为术语丢了。
const _readerNoticeKey =
    'Shared with the studio. Entries added here apply to every translation group of this comic.';

/// 跑完「工作室术语表 UI 入口」的全部断言。
Future<void> runP6Checks(
  CheckSink check, {
  required Directory packageRoot,
}) async {
  final probes = <_Probe>[];
  void probe(
    String name,
    Future<bool> Function() green,
    Future<bool> Function() red,
    String Function() detail,
  ) {
    probes.add(_Probe(name, green, red, detail));
  }

  // ── 1 · 后端（真实 GlossaryStore，落在假 sink 上） ────────────────────

  probe(
    'backend.scope_kind_is_studio',
    () async => _Fixture().backend.scopeKind == GlossaryScopeKind.studio,
    // 故障路径 = 同一个后端断言成 reader。两个枚举值不可能同时成立，
    // ⇒ 判据不是"恒 true"。
    () async => _Fixture().backend.scopeKind == GlossaryScopeKind.reader,
    () => '绿=StoreGlossaryBackend 报 studio / 故障=报成 reader',
  );

  probe(
    'backend.studio_never_inert',
    // 🔴 工作室走 `GlossaryBridge`（译前占位 → 译后还原），离线 NMT 与无 Key
    // 通道同样生效 —— 所以"当前引擎不用术语表"这句话在工作室里是**错的**，
    // 页面据此显示提示会让用户白换模型。
    () async => _Fixture().backend.glossaryInert == false,
    () async => _Fixture().backend.glossaryInert == true,
    () => '绿=工作室恒不 inert（任何引擎都生效）/ 故障=报 inert（会显示错误提示）',
  );

  probe(
    'backend.set_then_read_back',
    () async {
      final f = _Fixture();
      return f.backend.setEntry('路飞', '鲁夫') &&
          f.backend.entries()['路飞'] == '鲁夫';
    },
    // 故障路径：**同一条判据**施于非法词条（整句）。写入必须被拒 ⇒ 判据变红。
    () async {
      final f = _Fixture();
      return f.backend.setEntry('这是一句完整的话，不该进术语表', 'x') &&
          f.backend.entries()['这是一句完整的话，不该进术语表'] == 'x';
    },
    () => '绿=合法词条写入后可读回 / 故障=同判据施于整句（非法）⇒ 必须 false',
  );

  probe(
    'backend.writes_land_on_the_shared_keys',
    // 🔴 持久化**位置与键名**必须与旧引擎完全一致（`implicitData` 的
    // `imageTranslationComicGlossary`），否则 S9.5-b 之前两边会各写各的，
    // 术语表看起来"时有时无"。
    //
    // 形状是 v2：`{scope: {group: {原文: 译法}}}`。这个后端不带组 ⇒ 落共用层
    // `''`（与 v1 平表**语义**相同，只是多一层显式的"没有组"）。
    () async {
      final f = _Fixture();
      f.backend.setEntry('娜美', '奈美');
      final g = f.map[GlossaryStore.implicitKey];
      if (g is! Map) return false;
      final scoped = g[f.scope];
      if (scoped is! Map) return false;
      final shared = scoped[GlossaryStore.sharedGroup];
      if (shared is! Map) return false;
      return shared['娜美'] == '奈美' && f.writes > 0;
    },
    // 故障路径 = 用**新键名**去找同一份数据 ⇒ 找不到才是对的。
    () async {
      final f = _Fixture();
      f.backend.setEntry('娜美', '奈美');
      return f.map.containsKey('imageTranslationComicGlossaryV2');
    },
    () => '绿=写进 imageTranslationComicGlossary 的共用层 + 立刻落盘 / '
        '故障=写成 V2 新键（会与旧引擎分叉）',
  );

  probe(
    'backend.reads_through_no_cache',
    // 模拟"导入备份整体替换 implicitData"：直接换掉 sink 背后的内容。
    () async {
      final f = _Fixture();
      f.map[GlossaryStore.implicitKey] = {
        f.scope: {'甲': 'A'},
      };
      return f.backend.entries()['甲'] == 'A';
    },
    // 🔴 故障路径 = 换掉以后再整体删掉，然后**期望还能读到**旧值。
    // 没有缓存 ⇒ 读到 null ⇒ 判据 false（正确）。若实现偷偷缓存，这里会是
    // true，判据就把"导入后术语表不更新"这个 bug 放过去了。
    () async {
      final f = _Fixture();
      f.map[GlossaryStore.implicitKey] = {
        f.scope: {'甲': 'A'},
      };
      final first = f.backend.entries()['甲'];
      f.map.remove(GlossaryStore.implicitKey);
      return f.backend.entries()['甲'] == first && first != null;
    },
    () => '绿=读的是 sink 当前内容 / 故障=整体替换后仍读到旧值（说明有缓存）',
  );

  probe(
    'backend.remove_can_block',
    () async {
      final f = _Fixture();
      f.backend.setEntry('甲', 'A');
      f.backend.removeEntry('甲', block: true);
      return f.backend.entries().isEmpty && f.backend.blocked().contains('甲');
    },
    // 故障路径 = 同一次操作后断言"词条还在"（只删不生效 / 只删不封杀的实现）。
    () async {
      final f = _Fixture();
      f.backend.setEntry('甲', 'A');
      f.backend.removeEntry('甲', block: true);
      return f.backend.entries().containsKey('甲');
    },
    () => '绿=删除同时封杀（否则模型下一页又报回来）/ 故障=词条仍在',
  );

  probe(
    'backend.unblock_restores_learnability',
    () async {
      final f = _Fixture();
      f.backend.setEntry('甲', 'A');
      f.backend.removeEntry('甲', block: true);
      f.backend.unblockEntry('甲');
      return !f.backend.blocked().contains('甲');
    },
    () async {
      final f = _Fixture();
      f.backend.setEntry('甲', 'A');
      f.backend.removeEntry('甲', block: true);
      f.backend.unblockEntry('甲');
      return f.backend.blocked().contains('甲');
    },
    () => '绿=解除封杀后不再列出 / 故障=仍在封杀名单里',
  );

  probe(
    'backend.one_comic_one_scope_across_both_surfaces',
    // 🔴 S9.5-b 之前这条是**反**的：阅读器存 `cid@sourceKey`、工作室存
    // `comicId`，两份表互不相认。现在工作室经绑定表反查回来源 ⇒ **同一个
    // scope**：在阅读器里手填的名字，工作室跑整章时立刻用得上（④ 的承诺）。
    //
    // 但"不同漫画互不污染"这半句**永远成立** —— 写错 scope 会把一本书的译名
    // 串到另一本上，而那种错在界面上看不出来。
    () async {
      // 🔴 刻意让两个 store **共用同一张底层 map**：用两个独立 map 来"证明"
      // 隔离是假的，它证明的只是两个变量不相等。
      final shared = <String, Object?>{};
      final reader = GlossaryStore(sink: () => shared, persist: () {});
      final studio = GlossaryStore(sink: () => shared, persist: () {});
      final same = glossaryScopeOf(cid: 'cid1', sourceKey: 'comix.to');
      final otherSource = glossaryScopeOf(cid: 'cid1', sourceKey: 'comikey');
      reader.set(same, '甲', 'A');
      return studio.of(same)['甲'] == 'A' && studio.of(otherSource).isEmpty;
    },
    // 故障路径 = **只取 cid** 的 scope 推导（漏掉 sourceKey）：同一本漫画的不同
    // 来源落进同一个 scope ⇒ "互不污染"那半句不成立，同一条判据变红。
    () async {
      final shared = <String, Object?>{};
      final reader = GlossaryStore(sink: () => shared, persist: () {});
      String flawed(String cid, String? sourceKey) => cid;
      final a = flawed('cid1', 'comix.to');
      final b = flawed('cid1', 'comikey');
      reader.set(a, '甲', 'A');
      return a == b && reader.of(b).isEmpty;
    },
    () => '绿=同一漫画两界面共用一份、不同来源隔离 / '
        '故障=只按 cid 推 scope 时不同来源会串',
  );

  // ── 2 · 解耦（静态扫描，防"改回去了"） ────────────────────────────────

  /// 读文件并**先去注释**：断言"不依赖某符号"时，文档里提到它不算依赖
  /// （本文件的兄弟文件正好在注释里解释这件事）。
  bool codeHas(String relPath, String needle) {
    final file = File('${packageRoot.path}/$relPath');
    if (!file.existsSync()) return false;
    final source = file
        .readAsStringSync()
        .replaceAll(RegExp(r'//.*$', multiLine: true), '')
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    return source.contains(needle);
  }

  probe(
    'wiring.editor_has_no_engine_dependency',
    // 🔴 本项的核心：页面只认 `GlossaryBackend`，不认旧引擎单例。
    () async => !codeHas(_editorPath, 'ImageTranslationService'),
    // 故障路径 = **对照组**：适配器文件确实含 `ImageTranslationService`
    // （它生来就是干这个的）⇒ 同一条判据在它身上为 false。
    () async => !codeHas(_serviceBackendPath, 'ImageTranslationService'),
    () => '绿=编辑器不引用旧引擎 / 故障=对照组（适配器）确实含它 ⇒ 判据非恒真',
  );

  probe(
    'wiring.editor_takes_a_backend',
    () async => codeHas(_editorPath, 'required this.backend'),
    // 故障路径 = 旧签名（`cid` / `sourceKey`）已经删掉，搜不到才对。
    () async => codeHas(_editorPath, 'required this.sourceKey'),
    () => '绿=构造签名收 GlossaryBackend / 故障=旧签名还在（页面仍绑死在阅读器上）',
  );

  probe(
    'wiring.store_backend_lives_outside_flutter',
    // 后端抽象与工作室实现必须是**零 Flutter 依赖**的纯逻辑，否则本文件的
    // 第一组断言就得靠一个渲染表面才能跑。
    () async =>
        !codeHas(_storeBackendPath, 'package:flutter/') &&
        !codeHas(_storeBackendPath, 'translation_service.dart'),
    // 故障路径 = **对照组**：适配器文件确实 import 了旧引擎 ⇒ 同一条判据在它
    // 身上为 false。
    () async => !codeHas(_serviceBackendPath, 'translation_service.dart'),
    () => '绿=glossary_backend.dart 不 import Flutter、也不 import 旧引擎 / '
        '故障=对照组（适配器）确实 import 旧引擎 ⇒ 判据非恒真',
  );

  probe(
    'wiring.service_backend_inert_is_a_getter',
    // 用户随时可能换模型，页面下一次 build 必须拿到新的答案 —— 写成字段会
    // 把"换掉 Google 以后提示还在"永远留在界面上。
    () async => codeHas(_serviceBackendPath, 'bool get glossaryInert'),
    () async => codeHas(_serviceBackendPath, 'final bool glossaryInert'),
    () => '绿=inert 是 getter（每次求值）/ 故障=缓存成字段',
  );

  probe(
    'wiring.reader_callers_pass_the_service_backend',
    () async =>
        codeHas(_comicPagePath, 'ServiceGlossaryBackend(') &&
        codeHas(_actionsPath, 'ServiceGlossaryBackend('),
    // 故障路径 = 同一个 needle 在**别的**、确实不该有的文件里搜 ⇒ false，
    // 证明这条判据不是"到处都为 true"。
    () async => codeHas('lib/pages/settings/reader.dart', 'ServiceGlossaryBackend('),
    () => '绿=阅读器两个入口都换了写法 / 故障=对照文件（设置页）里没有它 ⇒ 判据非恒真',
  );

  probe(
    'wiring.studio_action_opens_the_editor',
    () async =>
        codeHas(_studioPath, 'GlossaryEditorPage(') &&
        codeHas(_studioPath, 'StoreGlossaryBackend(') &&
        codeHas(_studioPath, 'group: _glossaryGroup,') &&
        // 🔴 这两条才是"scope 来自哪儿"的判据：反查绑定表，而不是拿工程 id 顶替。
        codeHas(_studioPath, 'originForProject(') &&
        !codeHas(_studioPath, 'appGlossary.of(widget.comicId)') &&
        !codeHas(_studioPath, 'appGlossary.merge(widget.comicId'),
    // 故障路径 = **同一条判据**施于一段旧写法（scope = comicId，工作室与阅读器
    // 各读一份表，而那正是这次要消灭的分裂）。
    () async => _scopeComesFromBinding('''
      final glossary = appGlossary.of(widget.comicId);
      appGlossary.merge(widget.comicId, response.glossary);
      backend: StoreGlossaryBackend(appGlossary, widget.comicId),
    '''),
    () => '绿=编辑器后端拿反查来的 scope + group / '
        '故障=旧写法（拿 comicId 当 scope）不满足判据',
  );

  probe(
    'wiring.studio_run_uses_the_bound_scope',
    // 注入端（`StudioRunOptions.glossary`）与编辑器后端必须是**同一个**身份，
    // 否则用户在编辑器里改的词跑起来不生效 —— 而那看起来像"术语表没接上"。
    () async =>
        codeHas(_studioPath, 'glossary: _glossary,') &&
        !codeHas(_studioPath, 'glossary: appGlossary.of('),
    () async => _runScopeMatchesEditor('glossary: appGlossary.of(widget.comicId),'),
    () => '绿=整章跑的术语表走同一个 _glossary / 故障=注入端各拼一份 ⇒ 判据非恒真',
  );

  probe(
    'wiring.studio_button_tooltip_is_translated',
    // tooltip 走 `.tl` 才会显示中文；少一个 `.tl` 就是"新按钮莫名显示英文"。
    () async => codeHas(_studioPath, "tooltip: 'Glossary'.tl"),
    () async => codeHas(_studioPath, "tooltip: 'glossary'.tl"),
    () => '绿=按钮 tooltip 走 .tl / 故障=大小写错的 keys 搜不到 ⇒ 判据非恒真',
  );

  probe(
    'wiring.i18n_scan_covers_the_editor',
    // 🔴 编辑器在 `comic_details_page/` 下，不在 i18n 扫描的目录里 —— 所以
    // `headless.dart` 必须**显式**把它加进白名单，否则这个页面里所有字面量
    // 都是核对盲区（漏核对不报错，只显示英文）。
    () async => codeHas(_headlessPath, 'comic_details_page/glossary_editor.dart'),
    () async =>
        codeHas(_headlessPath, 'comic_details_page/__not_scanned__.dart'),
    () => '绿=headless.dart 把编辑器加进扫描白名单 / 故障=白名单查无此文件',
  );

  probe(
    'wiring.i18n_scan_has_one_implementation',
    // 🔴 那条正则曾经被复制成三份（headless.dart / p5 / p6），于是各自漂移过
    // 三回：锚在 `tooltip:` 上、漏 `tlParams`、只认单引号。现在它只在
    // `headless_p1_checks.dart` 里存在 —— 这条断言就是"别再复制回去"的锁。
    () async =>
        !codeHas(_p5Path, r'\.tl(?:Params)') &&
        !codeHas(_headlessPath, r'\.tl(?:Params)'),
    // 故障路径 = **对照组**：共享实现所在文件确实含有它 ⇒ 同一条判据为 false。
    () async => !codeHas(_p1Path, r'\.tl(?:Params)'),
    () => '绿=正则只在 p1 的共享实现里 / 故障=对照组（p1）确实含它 ⇒ 判据非恒真',
  );

  // ── 2.5 · 翻译组那一层（S9.5-b 的用户口径修正） ──────────────────────
  //
  // 用户的原话："术语表也仅仅需要在针对 comix.to 网站的时候做区分……只要给
  // 术语表中的不同原文译文对照设置专门的翻译组匹配，也就是增加 groupId 字段。"
  //
  // 落成代码就是：**scope 不含组，组是条目的属性**。下面五条把这条规则拆开钉死。

  probe(
    'group.read_merges_shared_and_group',
    // 组上下文里，**共用层 ∪ 本组**一起下发 —— 人工确认过的名字不可能因为
    // "换了个组"就消失（那会静默改变译文）。
    () async {
      final f = _Fixture();
      final asura = StoreGlossaryBackend(f.store, f.scope, group: 'Asura');
      f.backend.setEntry('路飞', '鲁夫'); // 落共用层
      asura.setEntry('娜美', '娜美'); // 落 Asura 桶
      final merged = asura.entries();
      return merged['路飞'] == '鲁夫' && merged['娜美'] == '娜美';
    },
    // 故障路径 = 同一个夹具换成**别的组**的后端 ⇒ 组桶那条查不到，判据变红。
    () async {
      final f = _Fixture();
      StoreGlossaryBackend(f.store, f.scope, group: 'Asura').setEntry('娜美', '娜美');
      f.backend.setEntry('路飞', '鲁夫');
      final merged =
          StoreGlossaryBackend(f.store, f.scope, group: 'DivaScans').entries();
      return merged['路飞'] == '鲁夫' && merged['娜美'] == '娜美';
    },
    () => '绿=组上下文里取到 共用层+本组 / 故障=换成别的组就查不到本组的条目',
  );

  probe(
    'group.same_source_can_differ_per_group',
    // 组存在的**唯一理由**：同一个原文，两个组各有一份译法，互不覆盖。
    () async {
      final f = _Fixture();
      f.store.set(f.scope, 'Ruffy', '鲁夫', group: 'Asura');
      f.store.set(f.scope, 'Ruffy', '路飛', group: 'DivaScans');
      return StoreGlossaryBackend(f.store, f.scope, group: 'Asura')
              .entries()['Ruffy'] ==
          '鲁夫' &&
          StoreGlossaryBackend(f.store, f.scope, group: 'DivaScans')
              .entries()['Ruffy'] ==
          '路飛';
    },
    // 故障路径 = **组拼进 scope** 的那种（被否掉的）写法：条目被埋进某一个组，
    // 共用层里查不到 ⇒ 同一条判据变红。这也顺手证明了"scope 里不该有组"。
    () async {
      final f = _Fixture();
      f.store.set('${f.scope}@Asura', 'Ruffy', '鲁夫');
      f.store.set('${f.scope}@DivaScans', 'Ruffy', '路飛');
      return StoreGlossaryBackend(f.store, f.scope, group: 'Asura')
              .entries()['Ruffy'] ==
          '鲁夫';
    },
    () => '绿=同一原文两组各一份、互不覆盖 / 故障=组拼进 scope 时组内的词在共用层查不到',
  );

  probe(
    'group.legacy_flat_table_is_lifted_on_read',
    // v1 的平表 `{scope: {原文: 译法}}` 读一次就升成 `{scope: {'': {...}}}`，
    // 并且**写回** —— 不写回的话每次读都要再升一次，而其中一次一定会漏。
    () async {
      final f = _Fixture();
      f.map[GlossaryStore.implicitKey] = {
        f.scope: {'路飞': '鲁夫'},
      };
      final read = f.store.of(f.scope);
      final written = (f.map[GlossaryStore.implicitKey] as Map)[f.scope] as Map;
      final shared = written[GlossaryStore.sharedGroup];
      return read['路飞'] == '鲁夫' &&
          shared is Map &&
          shared['路飞'] == '鲁夫';
    },
    // 故障路径 = "平表照读、不升格"的实现：按 v2 的形状取共用层会取到 null。
    () async {
      final f = _Fixture();
      f.map[GlossaryStore.implicitKey] = {
        f.scope: {'路飞': '鲁夫'},
      };
      final raw = (f.map[GlossaryStore.implicitKey] as Map)[f.scope] as Map;
      final shared = raw[GlossaryStore.sharedGroup];
      return shared is Map && shared['路飞'] == '鲁夫';
    },
    () => '绿=平表读时升格并写回 / 故障=不升格的话盘上仍是平表、按新形状取不到',
  );

  probe(
    'group.block_is_scoped_to_the_comic_not_the_group',
    // 🔴 阻断是 scope 级的："这个词永远别学"是对这本漫画说的。按组封杀的话，
    // 换到另一个组同一页又会把它学回来，用户会觉得"删不掉"。
    () async {
      final f = _Fixture();
      f.store.remove(f.scope, '路飞', group: 'Asura', block: true);
      return f.store.isBlocked(f.scope, '路飞') &&
          f.store.merge(f.scope, {'路飞': '鲁夫'}, group: 'DivaScans') == 0;
    },
    () async {
      final f = _Fixture();
      // 故障路径 = 按 (scope, group) 存阻断 ⇒ 另一个组重新学得回来。
      f.store.remove('${f.scope}@Asura', '路飞', block: true);
      return f.store.isBlocked(f.scope, '路飞');
    },
    () => '绿=封杀跨组生效（换组也学不回来）/ 故障=按组封杀时换组就学回来了',
  );

  probe(
    'group.same_group_never_duplicated_by_merge',
    // 学习是**按组**先到先得：同一个组内已有的译法不被后一页改写，但另一个组
    // 的桶不受影响（两者是独立的存储分区，不是同一张表的两种过滤）。
    () async {
      final f = _Fixture();
      f.store.merge(f.scope, {'Ruffy': '鲁夫'}, group: 'Asura');
      final again = f.store.merge(f.scope, {'Ruffy': '路飛'}, group: 'Asura');
      final other = f.store.merge(f.scope, {'Ruffy': '路飛'}, group: 'DivaScans');
      return again == 0 &&
          other == 1 &&
          f.store.of(f.scope, group: 'Asura')['Ruffy'] == '鲁夫' &&
          f.store.of(f.scope, group: 'DivaScans')['Ruffy'] == '路飛';
    },
    // 故障路径 = **完全不分桶**的那一版（"组"只是显示上的说法）：只有一张平表，
    // 所以第二个组不可能独立学一份 ⇒ 同一条判据变红。
    () async {
      final f = _Fixture();
      f.store.merge(f.scope, {'Ruffy': '鲁夫'});
      final again = f.store.merge(f.scope, {'Ruffy': '路飛'});
      final other = f.store.merge(f.scope, {'Ruffy': '路飛'});
      return again == 0 &&
          other == 1 &&
          f.store.of(f.scope, group: 'DivaScans')['Ruffy'] == '路飛';
    },
    () => '绿=组内先到先得、组间各学一份 / 故障=不分桶时第二个组学不进自己的那份',
  );

  // ── 3 · 文案（P9.3 的教训：漏登记不报错，只显示英文） ──────────────────

  /// 扫出 [relPath] 里**未登记**的 `.tl` / `.tlParams` 字面量。
  ///
  /// 正则来自 `headless_p1_checks.dart::tlLiteralKeys` —— 与 `headless.dart`
  /// 的目录扫描**同一份实现**。
  ///
  /// 🔴 双引号由那份共享实现覆盖：`glossary_editor.dart`（本项的主角）通篇是
  /// `"Add term".tl` 这种写法，而旧正则只认单引号 ⇒ 这一整页 15 条文案从来
  /// 没被任何扫描看过。这条断言第一次跑就是 FAIL —— 它抓到的是真的。
  List<String> unregistered(String relPath, Map<String, dynamic> zhCn) {
    final file = File('${packageRoot.path}/$relPath');
    if (!file.existsSync()) return const ['<file missing>'];
    final found = <String>[];
    for (final key in tlLiteralKeys(file.readAsStringSync())) {
      if (key.isEmpty || key.length <= 2) continue;
      if (!zhCn.containsKey(key) && !found.contains(key)) found.add(key);
    }
    return found;
  }

  List<String> tlLiterals(String relPath) {
    final file = File('${packageRoot.path}/$relPath');
    if (!file.existsSync()) return const [];
    return [
      for (final key in tlLiteralKeys(file.readAsStringSync()))
        if (key.isNotEmpty) key,
    ];
  }

  final tableFile = File('${packageRoot.path}/assets/translation.json');
  final zhCn = tableFile.existsSync()
      ? (jsonDecode(tableFile.readAsStringSync())
          as Map<String, dynamic>)['zh_CN'] as Map<String, dynamic>
      : <String, dynamic>{};

  probe(
    'i18n.editor_strings_registered',
    () async => unregistered(_editorPath, zhCn).isEmpty,
    // 故障路径 = 同一条判据施于**空表**。它必须变红 —— 这才证明判据真的在看
    // `translation.json`，而不是恒 true。
    () async => unregistered(_editorPath, <String, dynamic>{}).isEmpty,
    () => '绿=编辑器字面量全部有 zh_CN 条目 / 故障=空表下仍判"全登记" '
        '| 缺: ${unregistered(_editorPath, zhCn).join(", ")}',
  );

  probe(
    'i18n.scan_actually_sees_the_editor',
    // 🔴 空结果判 FAIL：正则改坏 / 文件挪走都会让上面那条**静默通过**
    // （"一个都没扫到"不是"全都登记了"）。
    () async => tlLiterals(_editorPath).length >= 8,
    () async => tlLiterals(_editorPath).isEmpty,
    () => '绿=扫描在编辑器里扫到 ${tlLiterals(_editorPath).length} 条字面量 / '
        '故障=0 条（说明扫描根本没看到这个文件）',
  );

  probe(
    'i18n.studio_scope_notice_registered',
    () async => zhCn.containsKey(_studioNoticeKey),
    () async => zhCn.containsKey('$_studioNoticeKey (unregistered)'),
    () => '绿=工作室作用域说明已登记 / 故障=同名变体查不到 ⇒ 判据非恒真',
  );

  probe(
    'i18n.studio_scope_notice_is_actually_used',
    // 登记了却不 `.tl` 调用，用户照样看到英文 —— 这是"登记全绿但界面是英文"的
    // 唯一原因，必须单独钉住。
    () async => tlLiterals(_editorPath).contains(_studioNoticeKey),
    () async => tlLiterals(_editorPath).contains(_studioNoticeKey.toUpperCase()),
    () => '绿=说明文案确实走了 .tl / 故障=同一个键的正确拼写才在列表里',
  );

  probe(
    'i18n.reader_scope_notice_registered',
    // 只说工作室那半边，会让另一边的用户以为自己加的术语丢了 —— 两条说明是
    // **成对**的，缺一条比都不写更糟（它让人以为另一份表不存在）。
    () async => zhCn.containsKey(_readerNoticeKey),
    () async => zhCn.containsKey('$_readerNoticeKey (unregistered)'),
    () => '绿=阅读器作用域说明已登记 / 故障=同名变体查不到 ⇒ 判据非恒真',
  );

  probe(
    'i18n.reader_scope_notice_is_actually_used',
    () async => tlLiterals(_editorPath).contains(_readerNoticeKey),
    () async => tlLiterals(_editorPath).contains(_readerNoticeKey.toUpperCase()),
    () => '绿=阅读器说明文案确实走了 .tl / 故障=大小写错的键搜不到',
  );

  probe(
    'i18n.studio_button_label_is_chinese',
    () async => zhCn['Glossary'] == '术语表',
    () async => zhCn['Glossary'] == 'Glossary',
    () => '绿=Glossary → 术语表 / 故障=表里存的是英文原文（等于没翻译）',
  );

  // ── 跑 ────────────────────────────────────────────────────────────────

  for (final item in probes) {
    bool green;
    bool red;
    String err = '';
    try {
      green = await item.green();
    } catch (e) {
      green = false;
      err = 'green threw: $e';
    }
    try {
      red = await item.red();
    } catch (e) {
      // 故障路径抛异常 ≠ 断言变红。异常只说明夹具炸了，不能算"验证通过"。
      red = true;
      err = '${err.isEmpty ? '' : '$err | '}red threw: $e';
    }
    final verdict = green && !red;
    check(
      'glossaryUi.${item.name}',
      verdict,
      '${item.detail()} | 绿路径=${green ? 'true' : 'FALSE'} '
      '故障路径=${red ? '仍绿(装饰品)' : '变红'}${err.isEmpty ? '' : ' | $err'}',
    );
  }
}

/// 工作室的术语表 scope 是否来自**绑定表反查**，而不是拿 `comicId` 顶替。
///
/// 抽成函数是为了让故障路径能跑**同一条判据**（见 "反向验证" 一节）：静态扫描
/// 类断言的"做错"必须是"同一条逻辑喂给一个真的做错的对象"，不能是"搜一个不
/// 存在的字符串"—— 后者证明不了判据不是恒真。
bool _scopeComesFromBinding(String source) =>
    source.contains('originForProject(') &&
    !source.contains('appGlossary.of(widget.comicId)') &&
    !source.contains('appGlossary.merge(widget.comicId');

/// 整章跑的注入端与编辑器后端是否用**同一个**身份（同一个 `_glossary*`）。
bool _runScopeMatchesEditor(String source) =>
    source.contains('glossary: _glossary,') &&
    !source.contains('glossary: appGlossary.of(');
