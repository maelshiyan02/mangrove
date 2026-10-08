// 术语表（S11 第 1/4 块 · P6 §4.10 序 3）的断言集。
//
// 覆盖两件事：
//
// * **`GlossaryStore`** —— 术语表从旧引擎的静态状态里抽出来以后的读写/过滤/
//   上限/封杀/作用域隔离/持久化；
// * **`GlossaryBridge`** —— 给"不吃术语表"的引擎（免 Key 公共端点、本地 NMT）
//   做的"译前占位 → 译后还原"。
//
// 外加一组**接线断言**：工作室那两处传参/回写是纯文本层面的接线，跑不了模型，
// 但可以断言"代码里确实有这一行"（照 P1 `studio_does_not_use_legacy_engine`
// 的先例：先剥注释再扫，否则文件会因为注释里提到了名字而被自己点亮）。
//
// ## 反向验证
//
// 与 P3 同源（见 `kb/methodology/M08`）：故障在**运行时**注入 —— 同一个判据
// 跑两遍，正确输入必须 true、故意做错必须 false。一次构建验完全部断言。
//
// ## 这里测不到的
//
// 🔴 "术语真的进了 prompt"与"哨兵真的穿过了 NMT 分词器"都是**活体引擎行为**，
// 本会话无法验证（无网络调用、无渲染表面）。`GlossaryBridge` 的 `lost` /
// `residue` 计数就是为了把这类失败**暴露**出来而设计的，GUI 验收时要看日志里
// 有没有 `Glossary Bridge` 警告行。
library;

import 'dart:io';

import 'package:mangrove/foundation/translation_project/glossary_bridge.dart';
import 'package:mangrove/foundation/translation_project/glossary_store.dart';
import 'package:mangrove/headless_p1_checks.dart' show CheckSink;

/// 一条断言：绿路径 + 故障路径 + 可诊断的 detail。
class _Probe {
  const _Probe(this.name, this.green, this.red, this.detail);

  final String name;
  final Future<bool> Function() green;
  final Future<bool> Function() red;
  final String Function() detail;
}

/// 一个假后端：不碰 `appdata`，所以整批断言可以脱离真实用户数据跑。
///
/// [sink] 刻意**不是** final —— 「导入备份后 implicitData 被整体替换」这条
/// 性质只有换掉整个 map 才能测出来。
class _Harness {
  _Harness({this.cap = GlossaryStore.defaultCap, Map<String, Object?>? seed})
      : sink = <String, Object?>{...?seed};

  final int cap;
  Map<String, Object?> sink;
  int persists = 0;

  GlossaryStore get store => GlossaryStore(
        sink: () => sink,
        persist: () => persists++,
        cap: cap,
      );
}

/// 跑完术语表的全部断言。
Future<void> runP4Checks(
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

  // ── 1 · 写入与过滤 ────────────────────────────────────────────────────

  bool setRoundTrip(Map<String, String> entry) {
    final h = _Harness();
    final ok = h.store.set('c', entry.keys.first, entry.values.first);
    return ok && h.store.of('c').containsKey(entry.keys.first);
  }

  probe(
    'store.set_accepts_short_proper_noun',
    () async => setRoundTrip({'ルフィ': '路飞'}),
    () async => setRoundTrip({'これはとても長い文章です。': '这是一句很长的话'}),
    () => '绿=短专名入库 / 故障=整句被拒（术语表只收短专名）',
  );

  bool rejects(String source, String translation) {
    final h = _Harness();
    return !h.store.set('c', source, translation);
  }

  probe(
    'store.set_rejects_url_like',
    () async => rejects('x.co', '某站'),
    () async => rejects('ルフィ', '路飞'),
    () => '绿=URL 样被拒 / 故障=正常专名不该被拒',
  );

  bool capRespected(int cap) {
    final h = _Harness(cap: cap);
    h.store.set('c', 'A', '一');
    h.store.set('c', 'B', '二');
    return !h.store.set('c', 'C', '三');
  }

  probe(
    'store.cap_blocks_new_entries',
    () async => capRespected(2),
    () async => capRespected(10),
    () => '绿=cap=2 时第三条被拒 / 故障=cap=10 时不该被拒',
  );

  // 🔴 故障路径是"拿**未 trim** 的 key 去查"：存储里根本没有那个 key，
  // 所以判据必须变红。不能用 `&& false` 之类凑出来的红 —— 那等于没验证。
  // 🔴 这条专门盯 `_read()` 里"清洗时截短超限表"的那一行：它在遍历 map 的
  // 同时删元素，惰性迭代会直接抛 ConcurrentModificationError —— 而这条路径
  // 只有读到超限的旧数据时才走到，平时跑不到。
  bool truncatesStored(int cap) {
    final h = _Harness(
      cap: cap,
      seed: {
        GlossaryStore.implicitKey: {
          'c': {'A': '一', 'B': '二', 'C': '三'},
        },
      },
    );
    return h.store.of('c').length == 2;
  }

  probe(
    'store.read_truncates_oversized',
    () async => truncatesStored(2),
    () async => truncatesStored(3),
    () => '绿=cap=2 时读到 2 条 / 故障=cap=3 时是 3 条',
  );

  bool trimmed(String lookupKey) {
    final h = _Harness();
    h.store.set('c', ' ルフィ ', '路飞');
    return h.store.of('c').containsKey(lookupKey);
  }

  probe(
    'store.set_trims_whitespace',
    () async => trimmed('ルフィ'),
    () async => trimmed(' ルフィ '),
    () => '绿=带空格的原文按 trim 后的形式入库 / 故障=未 trim 的 key 查不到',
  );

  // ── 2 · 合并（模型回报） ───────────────────────────────────────────────

  bool firstWins(String first, String second) {
    final h = _Harness();
    h.store.merge('c', {'ルフィ': first});
    h.store.merge('c', {'ルフィ': second});
    return h.store.of('c')['ルフィ'] == '路飞';
  }

  probe(
    'store.merge_first_agreed_wins',
    () async => firstWins('路飞', '鲁夫'),
    () async => firstWins('鲁夫', '路飞'),
    () => '绿=先到译法不被后一页改写覆盖 / 故障=被覆盖（一致性就没了）',
  );

  bool blockSticks(bool block) {
    final h = _Harness();
    h.store.merge('c', {'ルフィ': '路飞'});
    h.store.remove('c', 'ルフィ', block: block);
    h.store.merge('c', {'ルフィ': '路飞'});
    return h.store.of('c').isEmpty;
  }

  probe(
    'store.merge_skips_blocked_terms',
    () async => blockSticks(true),
    () async => blockSticks(false),
    () => '绿=封杀后不再重新学 / 故障=删了又回来（用户会觉得"删不掉"）',
  );

  bool blockedListed(bool block) {
    final h = _Harness();
    h.store.merge('c', {'ルフィ': '路飞'});
    h.store.remove('c', 'ルフィ', block: block);
    return h.store.blockedOf('c').contains('ルフィ');
  }

  probe(
    'store.remove_can_block',
    () async => blockedListed(true),
    () async => blockedListed(false),
    () => '绿=block=true 进封杀名单 / 故障=block=false 时名单为空',
  );

  bool unblocked(String which) {
    final h = _Harness();
    h.store.remove('c', 'ルフィ', block: true);
    h.store.unblock('c', which);
    return h.store.blockedOf('c').isEmpty;
  }

  probe(
    'store.unblock_lifts_ban',
    () async => unblocked('ルフィ'),
    () async => unblocked('ナミ'),
    () => '绿=解除该词 / 故障=解的是另一个词，原词仍在名单里',
  );

  // ── 3 · 作用域、持久化、清洗 ────────────────────────────────────────────

  bool isolated(bool sameScope) {
    final h = _Harness();
    h.store.set('c', 'ルフィ', '路飞');
    return h.store.of(sameScope ? 'c' : 'd').isEmpty;
  }

  probe(
    'store.scopes_are_isolated',
    () async => isolated(false),
    () async => isolated(true),
    () => '绿=另一个 scope 看不到 / 故障=同 scope 看得到',
  );

  bool cleared(String scope) {
    final h = _Harness();
    h.store.merge('c', {'ルフィ': '路飞'});
    h.store.clear(scope);
    return h.store.of('c').isEmpty;
  }

  probe(
    'store.clear_drops_scope',
    () async => cleared('c'),
    () async => cleared('other'),
    () => '绿=重译整本时清空 / 故障=清错 scope（错的人名会被一直喂回模型）',
  );

  bool persistCalled(bool write) {
    final h = _Harness();
    if (write) {
      h.store.set('c', 'ルフィ', '路飞');
    } else {
      h.store.of('c');
    }
    return h.persists > 0;
  }

  probe(
    'store.persists_on_write',
    () async => persistCalled(true),
    () async => persistCalled(false),
    () => '绿=写入触发落盘 / 故障=只读不该写盘',
  );

  bool sanitized(String badKey) {
    final h = _Harness(
      seed: {
        GlossaryStore.implicitKey: {
          'c': {badKey: '译文'},
        },
      },
    );
    return !h.store.of('c').containsKey(badKey);
  }

  probe(
    'store.sanitizes_legacy_entries',
    () async => sanitized('これはとても長い文章です。'),
    () async => sanitized('ルフィ'),
    () => '绿=旧版本存下的整句被清掉 / 故障=正常专名不该被清',
  );

  bool sinkReRead(bool swap) {
    final h = _Harness();
    h.store.set('c', 'ルフィ', '路飞');
    if (swap) {
      // 模拟导入备份：`implicitData` 是**整体替换**，不是就地修改。
      h.sink = {
        GlossaryStore.implicitKey: {
          'c': {'ナミ': '娜美'},
        },
      };
    }
    return h.store.of('c').containsKey('ナミ');
  }

  probe(
    'store.re_reads_sink_no_stale_cache',
    () async => sinkReRead(true),
    () async => sinkReRead(false),
    () => '绿=换掉整个 map 后读到新数据 / 故障=不换就读不到（缓存是新的意义）',
  );

  // ── 4 · 桥接（免 Key / 本地 NMT 的术语表通路） ──────────────────────────

  bool protected(String text) {
    final plan = GlossaryBridge.protect([text], {'ルフィ': '路飞'});
    return plan.texts.first.contains('XQZ0ZQX');
  }

  probe(
    'bridge.protect_inserts_sentinel',
    () async => protected('ルフィは海賊だ'),
    () async => protected('ナミは航海士だ'),
    () => '绿=命中术语→插哨兵 / 故障=文本里没有该术语时不该插',
  );

  bool noop(String text) {
    final plan = GlossaryBridge.protect([text], {'ルフィ': '路飞'});
    return plan.isUnused && plan.texts.first == text;
  }

  probe(
    'bridge.no_hit_is_identity',
    () async => noop('ナミは航海士だ'),
    () async => noop('ルフィは海賊だ'),
    () => '绿=没命中时原文不动 / 故障=命中了就不是 no-op',
  );

  bool roundTrip(List<String> Function(List<String>) engine) {
    const texts = ['ルフィは海賊だ'];
    final plan = GlossaryBridge.protect(texts, {'ルフィ': '路飞'});
    final r = GlossaryBridge.restore(engine(plan.texts), plan);
    return r.texts.first.contains('路飞') && !r.texts.first.contains('ZQX');
  }

  probe(
    'bridge.restore_roundtrip',
    () async => roundTrip((t) => t),
    () async => roundTrip((t) => ['???']),
    () => '绿=引擎原样吐回→还原成约定译法 / 故障=引擎把哨兵吞了',
  );

  bool longestFirst(bool includeLong) {
    final glossary = <String, String>{
      'AB': '短',
      if (includeLong) 'ABC': '长',
    };
    final plan = GlossaryBridge.protect(['ABC'], glossary);
    return GlossaryBridge.restore(plan.texts, plan).texts.first == '长';
  }

  probe(
    'bridge.longest_term_wins',
    () async => longestFirst(true),
    () async => longestFirst(false),
    () => '绿=ABC 优先于 AB / 故障=表里没有 ABC 时只能匹配到 AB',
  );

  bool lenient(List<String> Function(List<String>) engine) {
    final plan = GlossaryBridge.protect(['ルフィは海賊だ'], {'ルフィ': '路飞'});
    final r = GlossaryBridge.restore(engine(plan.texts), plan);
    return r.restored == 1 && r.texts.first.contains('路飞');
  }

  probe(
    'bridge.restore_tolerates_spaces',
    () async =>
        lenient((t) => [t.first.replaceAll('XQZ0ZQX', 'XQZ 0 ZQX')]),
    () async => lenient((t) => ['???']),
    () => '绿=分词器在哨兵里插了空格也能还原 / 故障=哨兵彻底丢失',
  );

  bool swept(List<String> Function(List<String>) engine) {
    final plan = GlossaryBridge.protect(['ルフィは海賊だ'], {'ルフィ': '路飞'});
    final r = GlossaryBridge.restore(engine(plan.texts), plan);
    return r.residue == 1 && !r.texts.first.contains('ZQX');
  }

  probe(
    'bridge.sweeps_unrecognised_residue',
    () async => swept((t) => ['XQZ9ZQX']),
    () async => swept((t) => t),
    () => '绿=认不出的哨兵碎片被清掉并计数 / 故障=正常哨兵会被还原而不是被清',
  );

  bool distinctIds(String text) {
    final plan =
        GlossaryBridge.protect([text], {'ルフィ': '路飞', 'ナミ': '娜美'});
    return plan.texts.first.contains('XQZ0ZQX') &&
        plan.texts.first.contains('XQZ1ZQX');
  }

  probe(
    'bridge.distinct_ids_per_term',
    () async => distinctIds('ルフィとナミ'),
    () async => distinctIds('ルフィだけ'),
    () => '绿=两条术语两个编号 / 故障=只出现一条时不会有第二个编号',
  );

  // ── 5 · 接线（静态扫描，防"改回去了"） ──────────────────────────────────

  bool codeHas(String relPath, String needle) {
    final file = File('${packageRoot.path}/$relPath');
    if (!file.existsSync()) return false;
    final source = file
        .readAsStringSync()
        .replaceAll(RegExp(r'//.*$', multiLine: true), '')
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    return source.contains(needle);
  }

  bool studioHas(String needle) =>
      codeHas('lib/pages/translation_studio/studio_page.dart', needle);

  probe(
    'wiring.studio_injects_glossary',
    () async => studioHas('glossary: appGlossary.of('),
    () async => studioHas('glossary: __never_wired__('),
    () => '工作室构造 StudioRunOptions 时必须传 glossary（此前是空的）',
  );

  probe(
    'wiring.studio_merges_reported_terms',
    () async => studioHas('appGlossary.merge('),
    () async => studioHas('__never_merged__('),
    () => '模型回报的专名必须回写（此前直接丢弃）',
  );

  probe(
    'wiring.page_run_carries_glossary',
    () async => codeHas(
      'lib/foundation/translation_project/studio_pipeline.dart',
      'glossary: outcome.glossary',
    ),
    () async => codeHas(
      'lib/foundation/translation_project/studio_pipeline.dart',
      'glossary: __never_carried__',
    ),
    () => 'StudioPageRun 必须把本页回报的专名带出去',
  );

  probe(
    'wiring.dispatcher_bridges_glossary',
    () async => codeHas(
      'lib/foundation/image_translation/translation_dispatcher.dart',
      'GlossaryBridge.protect',
    ),
    () async => codeHas(
      'lib/foundation/image_translation/translation_dispatcher.dart',
      'GlossaryBridge.__never__',
    ),
    () => '不吃术语表的引擎必须走桥接',
  );

  probe(
    'wiring.dispatcher_routes_public_free',
    () async => codeHas(
      'lib/foundation/image_translation/translation_dispatcher.dart',
      'activeIsPublicFree',
    ),
    () async => codeHas(
      'lib/foundation/image_translation/translation_dispatcher.dart',
      '__never_checked_public__',
    ),
    () => '免 Key 公共端点同样没有术语表通道，必须和本地 NMT 一起走桥接',
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
      'glossary.${item.name}',
      verdict,
      '${item.detail()} | 绿路径=${green ? 'true' : 'FALSE'} '
      '故障路径=${red ? '仍绿(装饰品)' : '变红'}${err.isEmpty ? '' : ' | $err'}',
    );
  }
}
