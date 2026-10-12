// P30 · 长画布「按页隐藏」的纯逻辑。
//
// 用户诉求：横版宣传首页（或任何不适合上下拼接的页）在**连续长画布**里会打乱
// 拼接/估高/解码窗口，需要能把指定页在长画布中暂时隐藏，并且**下次打开同一工程
// 仍然隐藏**；单页模式不受影响（横版图照常查看）。
//
// 存储沿用跨页字段的纪律：
//   * 工程级可选键 `_strip_hidden`，下划线前缀 ⇒ FT 零字节 diff；
//   * 值是 `{ "<pageKey>": true }` 的映射（不是数组 —— 复用
//     [SeamReviewEditCommand] 的 map 快照就能把切换做成一个撤销步）；
//   * 空表**删键**（不存在即 nil）；
//   * 未知键原样保留，本文件只碰这一个键。
//
// 零 Flutter 依赖：读/写/切换/可见序压缩都能在 headless 直接断言。
library;

import 'text_block.dart' show asObjectMap;

/// 工程级隐藏页键。
const String stripHiddenKey = '_strip_hidden';

/// 读出被隐藏的页键集合。坏数据（非 map / 值非 bool）一律忽略，绝不抛。
Set<String> readHiddenPages(Map<String, Object?> raw) {
  final stored = asObjectMap(raw[stripHiddenKey]);
  if (stored == null) return <String>{};
  final out = <String>{};
  stored.forEach((key, value) {
    if (value == true) out.add(key);
  });
  return out;
}

/// 把隐藏集合写回 [raw]。空集 ⇒ **删除**该键。
void writeHiddenPages(Map<String, Object?> raw, Set<String> hidden) {
  if (hidden.isEmpty) {
    raw.remove(stripHiddenKey);
    return;
  }
  raw[stripHiddenKey] = <String, Object?>{
    for (final key in hidden) key: true,
  };
}

/// 返回切换 [pageKey] 隐藏状态后的**新集合**（不修改入参）。
Set<String> toggleHiddenPage(Set<String> hidden, String pageKey) {
  final next = <String>{...hidden};
  if (!next.remove(pageKey)) next.add(pageKey);
  return next;
}

/// 全量页序 [pageKeys] 去掉隐藏页后的**原始下标**（升序）。
///
/// 🔴 与 `thumbRailVisibleIndices` 同一条理由：返回**原始下标**而不是压缩后的
/// 位置 —— 调用方要拿它回查工程页键/块列表，压缩序号会在隐藏首页后整体错位。
List<int> visiblePageIndices({
  required List<String> pageKeys,
  required Set<String> hidden,
}) {
  final out = <int>[];
  for (var i = 0; i < pageKeys.length; i++) {
    if (hidden.contains(pageKeys[i])) continue;
    out.add(i);
  }
  return out;
}

/// 隐藏当前页后，长画布应该选中哪一页：
///
/// * 后面还有可见页 ⇒ 下一张可见页；
/// * 否则取前一张可见页；
/// * 全都被隐藏了 ⇒ null（调用方保持现状）。
///
/// [current] 是被隐藏页的原始下标；[visible] 由 [visiblePageIndices] 得到。
int? nextVisibleAfterHide({
  required int current,
  required List<int> visible,
}) {
  if (visible.isEmpty) return null;
  for (final index in visible) {
    if (index > current) return index;
  }
  for (var i = visible.length - 1; i >= 0; i--) {
    if (visible[i] < current) return visible[i];
  }
  return null;
}
