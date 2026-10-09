// 术语表（glossary）：原文专名 → 约定译法。
//
// ## 为什么要有这个文件
//
// 术语表原本只活在旧引擎 `ImageTranslationService` 的静态状态里
// （`_glossaries` / `_blockedTerms` 两个懒加载缓存 + 一堆私有方法）。工作室
// 一次都没 import 过它 —— 因为**它挂在旧引擎上**，而 S9.5-b 要下线旧引擎，
// 不抽出来就是静默丢能力（P6 §4.10 的排序红线：术语表迁移必须早于"删"）。
//
// 抽出来的规则是三条：
//
// 1. **持久化位置不变**：仍然写 `appdata.implicitData` 的
//    `imageTranslationComicGlossary` / `imageTranslationBlockedTerms`。
//    ⇒ 旧引擎与工作室**共用同一份数据**，S9.5-b 删掉旧引擎时数据自然留在
//    implicitData 里。
// 2. **零 Flutter 依赖**：本文件不 import 任何 `package:flutter/*`，也不
//    import `appdata`。存储后端通过回调注入（`sink` / `persist`），
//    ⇒ headless 断言可以直接拿一个假 map 跑真实逻辑。
// 3. **不做进程内缓存**：每次读都从 `sink()` 重新取。
//    `appdata.implicitData` 在导入备份时是**整体替换**（`implicitData = jsonDecode(...)`），
//    不是就地修改 —— 缓存住引用会一直服务导入前的旧术语表。代价只是每页多
//    遍历一次（上限见 [cap]），换掉的是一整类"导入后术语表不更新"的假象。
//
// ## 持久化形状（v2 · 带翻译组）
//
// ```jsonc
// "imageTranslationComicGlossary": {
//   "<scope>": {                    // scope = `cid@sourceKey`，见 glossary_scope.dart
//     "":     { "<原文>": "<译法>" },   // 共用层：不属于任何翻译组
//     "<组>": { "<原文>": "<译法>" }    // 某翻译组独有（comix.to 这类版本化源）
//   }
// }
// ```
//
// 🔴 **v1（平表 `{scope: {原文: 译法}}`）在读的时候就地升格**为
// `{scope: {"": {...}}}` —— 不写迁移脚本、不动用户的一次点击。判据是"值是不是
// Map"：整个 scope 的值全是字符串 ⇒ 是 v1。混合形状（不可能由本类的写路径
// 产生）也会被读顺，并把共用层喂进去。
//
// 🔴 **为什么要这一层**：`GlossaryScope` 那条注释里的第 2 条 —— 组不能拼进
// scope，否则同一本漫画的组 A 与组 B 会各拿一份完全独立的表。
//
// ## 读的时候合并、组覆盖共用
//
// [of] 返回的是 `共用层 ∪ 该组`（该组同名条目覆盖共用层）。写只落**一个**桶：
// 人工在某个组的上下文里改一条，是"给这一组定一个说法"，不是"改掉所有组"。

import '../image_translation/glossary_term.dart';
import 'glossary_scope.dart';

export '../image_translation/glossary_term.dart';
export 'glossary_scope.dart';

/// 取值回调：每次调用都重新取，所以导入替换整个 implicitData 后不会拿到旧引用。
typedef GlossarySink = Map<String, Object?> Function();

/// 一个作用域下的术语表 + 阻断词。
///
/// 所有写操作都立刻落盘（回调 [persist]），因为术语表是"学到的东西"：
/// 崩溃丢掉它只是让用户下次重新学一遍，不值得为此做延迟写。
class GlossaryStore {
  GlossaryStore({
    required GlossarySink sink,
    required void Function() persist,
    int cap = defaultCap,
  })  : _sink = sink,
        _persist = persist,
        cap = cap;

  static const int defaultCap = 80;

  /// 与旧引擎共用的 implicitData 键 —— 改这里等于做一次数据迁移，不要改。
  static const String implicitKey = 'imageTranslationComicGlossary';
  static const String blockedKey = 'imageTranslationBlockedTerms';

  /// 共用层的组名。非版本化源永远落在这里。
  static const String sharedGroup = glossarySharedGroup;

  final GlossarySink _sink;
  final void Function() _persist;

  /// **单个 (scope, group) 桶**的条目上限。
  ///
  /// 满了以后**新增**会被拒绝（不是挤掉旧的）：已有的译法是人工确认过的，
  /// 不能被新学的顶掉。
  ///
  /// 🔴 上限按**桶**算而不是按 scope 算：一本漫画开两个组时，若共用 80 条的
  /// 上限，第 81 条会挤掉一个组的人工条目 —— 而那两个组本来就该各算各的。
  /// 一次请求实际发出的量是"共用 + 该组" ≤ 2×[cap]，仍有界。
  final int cap;

  // ------------------------------------------------------------------
  // 读
  // ------------------------------------------------------------------

  /// [scope] 下发给 [group] 用的术语表 = **共用层 ∪ 该组**（该组覆盖共用层）。
  ///
  /// 返回不可修改的副本。
  Map<String, String> of(String scope, {String group = sharedGroup}) {
    final buckets = _read()[scope];
    if (buckets == null || buckets.isEmpty) return const {};
    final g = glossaryGroupOf(group);
    final shared = buckets[sharedGroup];
    if (g == sharedGroup) {
      return shared == null || shared.isEmpty
          ? const {}
          : Map.unmodifiable(shared);
    }
    final merged = <String, String>{...?shared, ...?buckets[g]};
    return merged.isEmpty ? const {} : Map.unmodifiable(merged);
  }

  /// [scope] 下**某一个组自己**的桶（不含共用层）。
  ///
  /// 编辑器要用它区分"这一组独有的"与"共用的" —— 合并视图里分不出这两者，
  /// 而用户删掉一条时两者的后果不同。
  Map<String, String> bucketOf(String scope, {String group = sharedGroup}) {
    final bucket = _read()[scope]?[glossaryGroupOf(group)];
    return bucket == null || bucket.isEmpty
        ? const {}
        : Map.unmodifiable(bucket);
  }

  /// [scope] 下出现过的组名（可能含 [sharedGroup]）。
  Set<String> groupsOf(String scope) =>
      _read()[scope]?.keys.toSet() ?? const <String>{};

  /// [scope] 被用户封杀的原文词。
  ///
  /// 🔴 **阻断是 scope 级的，不分组**："这个词永远别学"是对这本漫画说的；
  /// 若按组封杀，换到另一个组同一页又会把它学回来，用户会觉得"删不掉"。
  List<String> blockedOf(String scope) {
    return _readBlocked()[scope]?.toList() ?? const [];
  }

  bool isBlocked(String scope, String source) {
    return _readBlocked()[scope]?.contains(source) ?? false;
  }

  /// 全部作用域（诊断 / 将来的导入导出用）。
  Map<String, Map<String, Map<String, String>>> get all => _read();

  // ------------------------------------------------------------------
  // 写
  // ------------------------------------------------------------------

  /// 人工写入或修改一条。返回 false 表示被拒（词条不合法 / 新增时该桶已达上限）。
  ///
  /// 人工写入意味着"用户就是要它"，所以会顺带解除该词的封杀 ——
  /// 否则删掉又加回来会因为仍在阻断名单里而看似无效。
  bool set(
    String scope,
    String source,
    String translation, {
    String group = sharedGroup,
  }) {
    source = source.trim();
    translation = translation.trim();
    if (!GlossaryTerm.isValid(source, translation)) return false;
    final g = glossaryGroupOf(group);
    final all = _read();
    final buckets = all.putIfAbsent(scope, () => <String, Map<String, String>>{});
    final bucket = buckets.putIfAbsent(g, () => <String, String>{});
    if (!bucket.containsKey(source) && bucket.length >= cap) {
      return false;
    }
    bucket[source] = translation;
    _write(all);
    if (isBlocked(scope, source)) {
      unblock(scope, source);
    }
    return true;
  }

  /// 删除一条。
  ///
  /// 🔴 [block] 为 true 时同时把原文词加进封杀名单 —— 光删除的话，模型下一页
  /// 还会把它再报上来，用户会觉得"删不掉"。
  ///
  /// 🔴 编辑器显示的是**合并视图**，所以从合并视图里删就必须连共用层一起删：
  /// 用户看见的那一行如果只从组桶里消失，刷新一下共用层的那条又浮上来
  /// —— 那是本仓库最忌的"删了又回来"。
  /// 返回是否真的删掉了（原本就没有则 false）。
  bool remove(
    String scope,
    String source, {
    String group = sharedGroup,
    bool block = false,
  }) {
    final g = glossaryGroupOf(group);
    final all = _read();
    final buckets = all[scope];
    var removed = false;
    if (buckets != null) {
      if (buckets[g]?.remove(source) != null) removed = true;
      if (g != sharedGroup && buckets[sharedGroup]?.remove(source) != null) {
        removed = true;
      }
      if (removed) _write(all);
    }
    if (block) {
      final blocked = _readBlocked();
      final set = blocked.putIfAbsent(scope, () => <String>{});
      final added = set.add(source);
      if (added) _writeBlocked(blocked);
      return removed || added;
    }
    return removed;
  }

  /// 把模型回报的专名合并进 [group] 桶，返回**新增**的条数。
  ///
  /// 三条纪律：
  /// * **先到先得**：已有译法不被后一页的改写覆盖 —— 一致性靠的就是这个。
  /// * 仍然校验：解析时的过滤是主闸门，但调用方不该能绕过它塞垃圾进来。
  /// * **封杀词永不重新学**，哪怕模型一直报。
  int merge(
    String scope,
    Map<String, String> discovered, {
    String group = sharedGroup,
  }) {
    if (discovered.isEmpty) return 0;
    final g = glossaryGroupOf(group);
    final all = _read();
    final buckets = all.putIfAbsent(scope, () => <String, Map<String, String>>{});
    final bucket = buckets.putIfAbsent(g, () => <String, String>{});
    final blocked = _readBlocked()[scope];
    var added = 0;
    discovered.forEach((source, translation) {
      if (!GlossaryTerm.isValid(source, translation)) return;
      if (blocked != null && blocked.contains(source)) return;
      if (!bucket.containsKey(source)) {
        bucket[source] = translation;
        added++;
      }
    });
    if (added == 0) return 0;
    // 只有新增才可能超限（人工 `set` 自己会挡），所以这里只需兜住上限。
    while (bucket.length > cap) {
      bucket.remove(bucket.keys.first);
    }
    _write(all);
    return added;
  }

  /// 清空。[group] 为 null 时清掉整个作用域（所有组），否则只清一个桶。
  ///
  /// 重新翻译整本时用：早先跑错的人名如果不清掉，会被一直喂回模型并自我强化。
  void clear(String scope, {String? group}) {
    final all = _read();
    if (group == null) {
      if (all.remove(scope) == null) return;
    } else {
      final buckets = all[scope];
      if (buckets == null || buckets.remove(glossaryGroupOf(group)) == null) {
        return;
      }
      if (buckets.isEmpty) all.remove(scope);
    }
    _write(all);
  }

  /// 解除封杀，返回是否原本处于封杀状态。
  bool unblock(String scope, String source) {
    final blocked = _readBlocked();
    final set = blocked[scope];
    if (set == null || !set.remove(source)) return false;
    _writeBlocked(blocked);
    return true;
  }

  // ------------------------------------------------------------------
  // 内部：读写 implicitData
  // ------------------------------------------------------------------

  /// 读全表，并**顺手清洗**：丢掉旧版本存下来的非法条目、把超限的表截短、
  /// 把 v1 的平表升格成 v2 的 `{"": {...}}`。
  ///
  /// 清洗只在真的改动了什么时才写回一次 —— 否则每次读都要写一次盘。
  Map<String, Map<String, Map<String, String>>> _read() {
    final stored = _sink()[implicitKey];
    final result = <String, Map<String, Map<String, String>>>{};
    var cleaned = false;
    if (stored is Map) {
      // 🔴 只**读** `stored`、只**写** `result`：坏掉的 scope 不放进 `result`，
      // 于是 `_write(result)` 自然把它丢掉。绝不边遍历 `stored` 边删它的元素
      // （`stored` 就是 `implicitData` 里那份 map 的引用，删了会抛
      // ConcurrentModificationError）—— 而这条路径只在数据坏掉时才走到，
      // 是最容易漏测的一条。
      stored.forEach((scopeKey, scopeValue) {
        final read = _readScope(scopeValue);
        if (read == null || read.buckets.isEmpty) {
          cleaned = true;
          return;
        }
        if (read.cleaned) cleaned = true;
        result[scopeKey.toString()] = read.buckets;
      });
    }
    if (cleaned) _write(result);
    return result;
  }

  /// 读一个 scope 的值，兼容 v1 平表与 v2 分桶。形状彻底坏掉时返回 null。
  _ScopeRead? _readScope(Object? value) {
    if (value is! Map) return null;
    final buckets = <String, Map<String, String>>{};
    final legacyFlat = <String, String>{};
    var sawFlat = false;
    var cleaned = false;

    value.forEach((key, entry) {
      if (entry is Map) {
        final read = _cleanBucket(entry);
        if (read.cleaned) cleaned = true;
        if (read.entries.isNotEmpty) buckets[key.toString()] = read.entries;
      } else {
        // v1 平表：`{原文: 译法}`。
        sawFlat = true;
        final source = key.toString();
        final translation = entry.toString();
        if (GlossaryTerm.isValid(source, translation)) {
          legacyFlat[source] = translation;
        } else {
          cleaned = true;
        }
      }
    });

    if (sawFlat) {
      // 🔴 升格本身**就是**一次改动，必须置 `cleaned` 让 `_read()` 写回 ——
      // 否则内存里是 v2、盘上还是 v1，而"读的时候顺手升格"这句话就只对了
      // 一半：下一次读还要再升一次，其中一次一定会漏（比如某条读路径没走
      // `_read`）。`headless_p6_checks` 的
      // `group.legacy_flat_table_is_lifted_on_read` 就是钉这一条的。
      cleaned = true;
      // 混合形状不可能由本类的写路径产生；真出现了就按"平表进共用层"顺掉。
      final shared = buckets.putIfAbsent(sharedGroup, () => <String, String>{});
      legacyFlat.forEach((k, v) => shared.putIfAbsent(k, () => v));
      if (_trim(shared)) cleaned = true;
      if (shared.isEmpty) buckets.remove(sharedGroup);
    }
    return _ScopeRead(buckets, cleaned);
  }

  /// 清一个桶：丢掉非法条目、超限截短。
  _BucketRead _cleanBucket(Map<Object?, Object?> raw) {
    final entries = <String, String>{};
    var cleaned = false;
    raw.forEach((key, value) {
      final source = key.toString();
      final translation = value.toString();
      if (GlossaryTerm.isValid(source, translation)) {
        entries[source] = translation;
      } else {
        cleaned = true;
      }
    });
    if (_trim(entries)) cleaned = true;
    return _BucketRead(entries, cleaned);
  }

  /// 超限时截短，返回是否截过。
  bool _trim(Map<String, String> bucket) {
    if (bucket.length <= cap) return false;
    // 🔴 必须 `.toList()`：`take()` 是惰性的，直接遍历 `bucket.keys` 并在循环里
    // 删元素会抛 ConcurrentModificationError。
    for (final key in bucket.keys.take(bucket.length - cap).toList()) {
      bucket.remove(key);
    }
    return true;
  }

  void _write(Map<String, Map<String, Map<String, String>>> all) {
    final encoded = <String, Object?>{};
    all.forEach((scope, buckets) {
      final out = <String, Object?>{};
      buckets.forEach((group, bucket) {
        if (bucket.isNotEmpty) out[group] = Map<String, String>.from(bucket);
      });
      if (out.isNotEmpty) encoded[scope] = out;
    });
    _sink()[implicitKey] = encoded;
    _persist();
  }

  Map<String, Set<String>> _readBlocked() {
    final stored = _sink()[blockedKey];
    final result = <String, Set<String>>{};
    if (stored is Map) {
      stored.forEach((k, v) {
        if (v is List) {
          result[k.toString()] = v.map((e) => e.toString()).toSet();
        }
      });
    }
    return result;
  }

  void _writeBlocked(Map<String, Set<String>> all) {
    _sink()[blockedKey] = all.map((k, v) => MapEntry(k, v.toList()));
    _persist();
  }
}

/// [_readScope] 的产物。
class _ScopeRead {
  const _ScopeRead(this.buckets, this.cleaned);

  final Map<String, Map<String, String>> buckets;
  final bool cleaned;
}

/// [_cleanBucket] 的产物。
class _BucketRead {
  const _BucketRead(this.entries, this.cleaned);

  final Map<String, String> entries;
  final bool cleaned;
}
