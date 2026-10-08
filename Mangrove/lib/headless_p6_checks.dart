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
// * **接线与文案** —— 工作室确实有入口、确实传的是 `comicId`、按钮 tooltip
//   确实是中文，且 `headless.dart` 的 i18n 扫描确实**覆盖到了**这个页面。
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

  /// 工作室的 scope 就是 `comicId`（工程没有 `sourceKey`）。
  final String scope = 'MDGH-ch1';

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
const _studioNoticeKey =
    'These terms belong to this studio project. The reader keeps a separate list per source.';

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
    // 🔴 持久化位置与形状必须与旧引擎完全一致（`implicitData` 的两个老键），
    // 否则 S9.5-b 之前两边会各写各的，术语表看起来"时有时无"。
    () async {
      final f = _Fixture();
      f.backend.setEntry('娜美', '奈美');
      final g = f.map[GlossaryStore.implicitKey];
      if (g is! Map) return false;
      final scoped = g[f.scope];
      if (scoped is! Map) return false;
      return scoped['娜美'] == '奈美' && f.writes > 0;
    },
    // 故障路径 = 用**新键名**去找同一份数据 ⇒ 找不到才是对的。
    () async {
      final f = _Fixture();
      f.backend.setEntry('娜美', '奈美');
      return f.map.containsKey('imageTranslationComicGlossaryV2');
    },
    () => '绿=写进 imageTranslationComicGlossary + 立刻落盘 / '
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
    'backend.scopes_are_isolated',
    // 阅读器按 `cid@sourceKey` 存、工作室按 `comicId` 存，两者在同一个 map 里
    // 并存。写错 scope 会把一本书的译名串到另一本上。
    () async {
      // 🔴 刻意让两个 store **共用同一张底层 map**：用两个独立 map 来"证明"
      // 隔离是假的，它证明的是两个变量不相等。
      final shared = <String, Object?>{};
      final reader = GlossaryStore(sink: () => shared, persist: () {});
      final studio = GlossaryStore(sink: () => shared, persist: () {});
      reader.set('cid@comikey', '甲', 'A');
      return studio.of('MDGH-ch1').isEmpty;
    },
    () async {
      final shared = <String, Object?>{};
      final reader = GlossaryStore(sink: () => shared, persist: () {});
      final studio = GlossaryStore(sink: () => shared, persist: () {});
      reader.set('cid@comikey', '甲', 'A');
      return studio.of('MDGH-ch1').isNotEmpty;
    },
    () => '绿=阅读器 scope 不污染工作室 scope / 故障=串到另一边（scope 写错）',
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
        codeHas(_studioPath, 'StoreGlossaryBackend(appGlossary, widget.comicId)'),
    () async =>
        codeHas(_studioPath, 'StoreGlossaryBackend(appGlossary, widget.sourceKey)'),
    () => '绿=工作室传 Scope=comicId 的后端 / 故障=传了阅读器才有的 sourceKey',
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
