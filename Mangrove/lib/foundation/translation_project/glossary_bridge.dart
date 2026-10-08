// 术语桥接：给**不吃术语表**的引擎用的「占位 → 还原」机制。
//
// ## 问题
//
// 术语表原本只有一条投递通路：塞进 LLM 的 prompt（`LlmTranslator`）。
// 但另外两类引擎根本没有"术语表"这个概念：
//
// * **免 Key 公共端点**（`PublicTranslator`，谷歌翻译）—— 一行一个请求，
//   没有 prompt 可塞；
// * **本地 NMT**（NLLB / Opus-MT）—— 就是个 seq2seq，没有术语表通道。
//
// 于是"用谷歌免 Key 跑整章"时术语表**完全不生效**，而用户看不出区别：
// 译文照常出来，只是人名一页一个样。这正是最难发现的一类静默失效。
//
// ## 做法：译前占位 + 译后还原
//
// 1. `protect`：把原文里出现过的术语替换成一个**哨兵**（`XQZ0ZQX` 这种
//    纯大写 ASCII + 数字）；
// 2. 把加了哨兵的文本交给引擎；
// 3. `restore`：把译文里的哨兵换回约定译法。
//
// 哨兵之所以用纯大写 ASCII：NMT 的词表覆盖拉丁字母与数字，遇到未见过的
// 词通常**原样拷贝**（人名能穿过 NMT 靠的就是同一条性质）。
//
// 🔴 **失败模式必须是可观测的，不能是静默的。**哨兵有可能被分词器切碎、被
// 音译、被吞掉 —— 本会话无法实机跑 NMT 验证这一点。所以 `restore` 会数出
// 成功了几个、丢了几个，并把残留的哨兵碎片**清掉**（宁可少一个词，也不能
// 让 `XQZ0ZQX` 出现在气泡里）。调用方负责把 `lost > 0` 报出来。
class GlossaryBridge {
  GlossaryBridge._();

  /// 哨兵格式。`XQZ<i>ZQX` —— 全大写 + 数字，尽量穿过分词器。
  static String sentinel(int index) => 'XQZ${index}ZQX';

  static final RegExp _strict = RegExp(r'XQZ(\d+)ZQX');

  /// 宽松匹配：分词器可能在哨兵中间插空格、也可能把它小写化。
  static final RegExp _lenient = RegExp(r'XQZ\s*(\d+)\s*ZQX', caseSensitive: false);

  /// 译前：把 [texts] 里出现过的术语换成哨兵。
  ///
  /// 返回的 [GlossaryBridgePlan.texts] 与入参等长、等序。
  /// 一条术语都没命中时返回 [GlossaryBridgePlan.unused]（不产生任何改动），
  /// 调用方据此判断"这次根本不需要桥接"。
  static GlossaryBridgePlan protect(
    List<String> texts,
    Map<String, String> glossary,
  ) {
    final entries = [
      for (final entry in glossary.entries)
        // 空 key 会让正则匹配到每个字符之间 —— 必须挡掉。
        if (entry.key.isNotEmpty) entry,
    ];
    if (entries.isEmpty) return GlossaryBridgePlan.unused(texts);
    // 长词优先：`ABC` 与 `AB` 同时在表里时，先替 `ABC` 才不会被 `AB` 吃掉。
    entries.sort((a, b) => b.key.length.compareTo(a.key.length));
    final pattern = RegExp(
      entries.map((e) => RegExp.escape(e.key)).join('|'),
    );

    final targets = <String>[];
    final indexOf = <String, int>{};
    final out = <String>[];
    var hit = false;
    for (final text in texts) {
      if (!pattern.hasMatch(text)) {
        out.add(text);
        continue;
      }
      hit = true;
      out.add(text.replaceAllMapped(pattern, (m) {
        final source = m.group(0)!;
        final index = indexOf.putIfAbsent(source, () {
          targets.add(glossary[source]!);
          return targets.length - 1;
        });
        return sentinel(index);
      }));
    }
    if (!hit) return GlossaryBridgePlan.unused(texts);
    return GlossaryBridgePlan(out, targets);
  }

  /// 译后：把 [texts] 里的哨兵换回约定译法。
  ///
  /// [restored] / [lost] 是**术语个数**（不是出现次数）：一条术语在 5 行里
  /// 都成功落地也算 1。这样"20 条术语里只落地了 3 条"读起来是直觉的。
  static GlossaryBridgeResult restore(
    List<String> texts,
    GlossaryBridgePlan plan,
  ) {
    final total = plan.placeholders;
    if (total == 0) {
      return GlossaryBridgeResult(List<String>.unmodifiable(texts), 0, 0, 0);
    }
    final survived = <int>{};
    var residue = 0;
    final out = <String>[];
    for (final text in texts) {
      var current = text;
      if (_strict.hasMatch(current)) {
        current = current.replaceAllMapped(_strict, (m) {
          final index = int.tryParse(m.group(1)!);
          if (index == null || index >= total) return m.group(0)!;
          survived.add(index);
          return plan.targets[index];
        });
      }
      if (_lenient.hasMatch(current)) {
        current = current.replaceAllMapped(_lenient, (m) {
          final index = int.tryParse(m.group(1)!);
          if (index == null || index >= total) return m.group(0)!;
          survived.add(index);
          return plan.targets[index];
        });
      }
      // 两轮之后还有哨兵碎片，说明引擎把它切得认不出来了。
      // 宁可丢一个词，也不能让 `XQZ0ZQX` 印在气泡里 —— 清掉并计数。
      final swept = _sweep(current);
      if (!identical(swept, current)) residue++;
      out.add(swept);
    }
    final restored = survived.length;
    return GlossaryBridgeResult(
      List<String>.unmodifiable(out),
      restored,
      total - restored,
      residue,
    );
  }

  /// 清掉残留的哨兵碎片（含大小写/空格变体），返回清理后的文本。
  ///
  /// 没有碎片时返回**原对象**（`identical` 成立），调用方据此计数。
  static String _sweep(String text) {
    if (!_lenient.hasMatch(text)) return text;
    return text.replaceAll(_lenient, '');
  }
}

/// [GlossaryBridge.protect] 的产物：待翻译文本 + 每个哨兵对应的约定译法。
class GlossaryBridgePlan {
  const GlossaryBridgePlan(this.texts, this.targets);

  /// 一条术语都没命中时返回"文本原样 + 无哨兵"的计划。
  ///
  /// 🔴 刻意保留原文本（而不是给一个空列表）：调用方一律用 `plan.texts`
  /// 往下走，就不用再判一次"到底有没有桥接"，少一处可以写错的分叉。
  static GlossaryBridgePlan unused(List<String> texts) =>
      GlossaryBridgePlan(List<String>.unmodifiable(texts), const <String>[]);

  final List<String> texts;

  /// 下标 = 哨兵编号，值 = 约定译法。
  final List<String> targets;

  /// 用上的术语条数（= 实际插入的哨兵种类数）。
  int get placeholders => targets.length;

  bool get isUnused => targets.isEmpty;
}

/// [GlossaryBridge.restore] 的产物。
class GlossaryBridgeResult {
  const GlossaryBridgeResult(this.texts, this.restored, this.lost, this.residue);

  final List<String> texts;

  /// 成功落地的术语条数。
  final int restored;

  /// 没能落地的术语条数（引擎把哨兵切碎/吞掉了）。
  final int lost;

  /// 有多少行里残留了认不出来的哨兵碎片并被清掉。
  final int residue;
}
