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
// 1. **持久化位置与形状不变**：仍然写 `appdata.implicitData` 的
//    `imageTranslationComicGlossary` / `imageTranslationBlockedTerms`，形状仍是
//    `{scope: {source: translation}}` / `{scope: [source]}`。
//    ⇒ 旧引擎与工作室**共用同一份数据**，谁都不要做迁移；S9.5-b 删掉旧引擎时
//    数据自然留在 implicitData 里。
// 2. **零 Flutter 依赖**：本文件不 import 任何 `package:flutter/*`，也不
//    import `appdata`。存储后端通过回调注入（`sink` / `persist`），
//    ⇒ headless 断言可以直接拿一个假 map 跑真实逻辑。
// 3. **不做进程内缓存**：每次读都从 `sink()` 重新取。
//    `appdata.implicitData` 在导入备份时是**整体替换**（`implicitData = jsonDecode(...)`），
//    不是就地修改 —— 缓存住引用会一直服务导入前的旧术语表。代价只是每页多
//    遍历一次（上限 80 条），换掉的是一整类"导入后术语表不更新"的假象。
//
// ## scope（作用域）
//
// 旧引擎的 key 是 `cid@sourceKey`（一本漫画的不同来源各一份）。工作室工程手里
// 没有 sourceKey，所以它的 scope 直接就是 `comicId`。两者在同一个 map 里并存，
// 互不干扰；将来真要合并只是改一行。

import '../image_translation/glossary_term.dart';

export '../image_translation/glossary_term.dart';

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

  final GlossarySink _sink;
  final void Function() _persist;

  /// 单个作用域的条目上限。满了以后**新增**会被拒绝（不是挤掉旧的）：
  /// 已有的译法是人工确认过的，不能被新学的顶掉。
  final int cap;

  // ------------------------------------------------------------------
  // 读
  // ------------------------------------------------------------------

  /// [scope] 的术语表，返回不可修改的副本。
  Map<String, String> of(String scope) {
    final all = _read();
    final glossary = all[scope];
    if (glossary == null || glossary.isEmpty) return const {};
    return Map.unmodifiable(glossary);
  }

  /// [scope] 被用户封杀的原文词。
  List<String> blockedOf(String scope) {
    return _readBlocked()[scope]?.toList() ?? const [];
  }

  bool isBlocked(String scope, String source) {
    return _readBlocked()[scope]?.contains(source) ?? false;
  }

  /// 全部作用域（诊断 / 将来的导入导出用）。
  Map<String, Map<String, String>> get all => _read();

  // ------------------------------------------------------------------
  // 写
  // ------------------------------------------------------------------

  /// 人工写入或修改一条。返回 false 表示被拒（词条不合法 / 新增时已达上限）。
  ///
  /// 人工写入意味着"用户就是要它"，所以会顺带解除该词的封杀 ——
  /// 否则删掉又加回来会因为仍在阻断名单里而看似无效。
  bool set(String scope, String source, String translation) {
    source = source.trim();
    translation = translation.trim();
    if (!GlossaryTerm.isValid(source, translation)) return false;
    final all = _read();
    final glossary = all.putIfAbsent(scope, () => <String, String>{});
    if (!glossary.containsKey(source) && glossary.length >= cap) {
      return false;
    }
    glossary[source] = translation;
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
  /// 返回是否真的删掉了（原本就没有则 false）。
  bool remove(String scope, String source, {bool block = false}) {
    final all = _read();
    final glossary = all[scope];
    final removed = glossary != null && glossary.remove(source) != null;
    if (removed) _write(all);
    if (block) {
      final blocked = _readBlocked();
      final set = blocked.putIfAbsent(scope, () => <String>{});
      final added = set.add(source);
      if (added) _writeBlocked(blocked);
      return removed || added;
    }
    return removed;
  }

  /// 把模型回报的专名合并进来，返回**新增**的条数。
  ///
  /// 三条纪律：
  /// * **先到先得**：已有译法不被后一页的改写覆盖 —— 一致性靠的就是这个。
  /// * 仍然校验：解析时的过滤是主闸门，但调用方不该能绕过它塞垃圾进来。
  /// * **封杀词永不重新学**，哪怕模型一直报。
  int merge(String scope, Map<String, String> discovered) {
    if (discovered.isEmpty) return 0;
    final all = _read();
    final glossary = all.putIfAbsent(scope, () => <String, String>{});
    final blocked = _readBlocked()[scope];
    var added = 0;
    discovered.forEach((source, translation) {
      if (!GlossaryTerm.isValid(source, translation)) return;
      if (blocked != null && blocked.contains(source)) return;
      if (!glossary.containsKey(source)) {
        glossary[source] = translation;
        added++;
      }
    });
    if (added == 0) return 0;
    // 只有新增才可能超限（人工 `set` 自己会挡），所以这里只需兜住上限。
    while (glossary.length > cap) {
      glossary.remove(glossary.keys.first);
    }
    _write(all);
    return added;
  }

  /// 清空一个作用域。重新翻译整本时用：早先跑错的人名如果不清掉，会被一直
  /// 喂回模型并自我强化。
  void clear(String scope) {
    final all = _read();
    if (all.remove(scope) == null) return;
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

  /// 读全表，并**顺手清洗**：丢掉旧版本存下来的非法条目、把超限的表截短。
  ///
  /// 清洗只在真的丢东西时才写回一次 —— 否则每次读都要写一次盘。
  Map<String, Map<String, String>> _read() {
    final sink = _sink();
    final stored = sink[implicitKey];
    final result = <String, Map<String, String>>{};
    var cleaned = false;
    if (stored is Map) {
      stored.forEach((k, v) {
        if (v is! Map) {
          cleaned = true;
          return;
        }
        final glossary = <String, String>{};
        v.forEach((ik, iv) {
          final source = ik.toString();
          final translation = iv.toString();
          if (GlossaryTerm.isValid(source, translation)) {
            glossary[source] = translation;
          } else {
            cleaned = true;
          }
        });
        if (glossary.length > cap) {
          // 🔴 必须 `.toList()`：`take()` 是惰性的，直接遍历 `glossary.keys`
          // 并在循环里删元素会抛 ConcurrentModificationError（而这行只在
          // 清理旧数据时才走到 —— 是最容易漏测的一条路径）。
          final excess = glossary.keys.take(glossary.length - cap).toList();
          for (var key in excess) {
            glossary.remove(key);
          }
          cleaned = true;
        }
        result[k.toString()] = glossary;
      });
    }
    if (cleaned) _write(result);
    return result;
  }

  void _write(Map<String, Map<String, String>> all) {
    _sink()[implicitKey] = all;
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
