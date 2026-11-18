// P65 · 评论排序 / 反向分页的纯策略层。
//
// 🔴 本文件零 Flutter 依赖：headless 自检可在 App 初始化前直接跑。
// 背景：拷贝漫画 App 端评论接口按「最新在前」返回，用户默认阅读习惯是
// 「旧 → 新」。这里把顺序决策与页码决策收敛成纯函数，UI 只负责落地。
library;

/// 评论展示顺序。默认从旧到新。
enum CommentOrder {
  oldestFirst,
  newestFirst,
}

/// 把评论时间串解析成可比较的整数键；解析不了返回 null。
///
/// `Comment.parseTime` 产出的是 `YYYY-MM-DD HH:MM:SS`，Unix 秒/毫秒也会在
/// 其它源里出现，两种都认。解析失败时调用方保持该条的原相对位置。
int? commentTimeKey(String? time) {
  if (time == null) return null;
  final s = time.trim();
  if (s.isEmpty) return null;
  final unix = int.tryParse(s);
  if (unix != null) {
    // 10 位 = 秒，13 位 = 毫秒（与 Comment.parseTime 同一判据）。
    return unix < 10000000000 ? unix * 1000000 : unix * 1000;
  }
  final iso = s.contains('T') ? s : s.replaceFirst(' ', 'T');
  return DateTime.tryParse(iso)?.microsecondsSinceEpoch;
}

/// 按时间给出 [times] 稳定排序后的下标。
///
/// 同键（含解析失败的）用原始下标兜底，避免 Dart `List.sort` 不稳定导致
/// 同秒评论每次刷新顺序都不同。未知时间沉到末尾，不伪造时间。
List<int> orderedCommentIndices(List<String?> times, CommentOrder order) {
  final indices = List<int>.generate(times.length, (i) => i);
  final keys = times.map(commentTimeKey).toList(growable: false);
  indices.sort((a, b) {
    final ka = keys[a];
    final kb = keys[b];
    if (ka == null && kb == null) return a.compareTo(b);
    if (ka == null) return 1;
    if (kb == null) return -1;
    final byTime = ka.compareTo(kb);
    return order == CommentOrder.oldestFirst ? byTime : -byTime;
  });
  return indices;
}

/// 按 [order] 重排评论。返回新列表，不改入参。
List<T> orderComments<T>(List<T> comments, CommentOrder order, String? Function(T) timeOf) {
  final indices = orderedCommentIndices(comments.map(timeOf).toList(), order);
  return indices.map((i) => comments[i]).toList(growable: false);
}

/// 首屏展示哪一页。
///
/// 拷贝接口 offset 0 = 最新一页；要按旧→新展示就得先拿总页数，再从最后一页
/// 开始显示。`maxPage` 为 null/1 时没有反向必要，仍取 1。
int commentFirstPage({required int? maxPage, required CommentOrder order}) {
  if (order == CommentOrder.oldestFirst && maxPage != null && maxPage > 1) {
    return maxPage!;
  }
  return 1;
}

/// 再加载一页时的页码；null 表示已经到头。
///
/// 旧→新：从最大的页往 1 递减（内容越来越新，追加到列表尾部）。
/// 新→旧：沿服务端原方向递增。
int? commentNextPage({
  required int page,
  required int? maxPage,
  required CommentOrder order,
}) {
  if (order == CommentOrder.oldestFirst) {
    return page > 1 ? page - 1 : null;
  }
  if (maxPage != null && page >= maxPage!) return null;
  return page + 1;
}

/// 右上角章节胶囊文案。抽成纯函数是为了让「章号变了文案必须变」可断言。
String readerChapterCaption(int current, int total) => 'Ch.$current / $total';
