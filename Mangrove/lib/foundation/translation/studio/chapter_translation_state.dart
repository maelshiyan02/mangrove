// 章节「已翻译」判据 —— 纯逻辑层。
//
// ## 判据为什么只认工作室
//
// S9.5-b 之后**产出**只在工作室管线里：成品落在工程的 `result/`，绑定落在
// `studioReaderBindings`。旧引擎的 `TranslationStore`（`image_translation.db`）
// 与阅读器即时缓存已随旧链路整体删除，没有任何代码再往里写，所以它不再是
// 「已翻译」的来源 —— 继续把它算进来只会让一批评据显示一堆翻开却是原图的空章。
//
// 判据因此只有**一条**来源：该章工程里成品页数 > 0。
//
// ## 为什么必须是纯逻辑（且与 Flutter 无关）
//
// `A02` 的硬规矩：任何「已完成 ✅」都要有反向验证；而本会话**没有渲染表面**
// （`A01 §3`），像素级只能人工验。"这一章算不算已翻译"是纯判断，可以在
// headless 里被注入故障打红 —— 所以参数全部走注入（`studioProductPages`），
// 不碰 implicitData、不碰磁盘。
library;

/// 一章的译文来源。
enum ChapterTranslationSource {
  /// 工作室工程里没有成品。
  none,

  /// 工作室工程里有成品（`result/` 位图或带译文的块）。
  studioOnly,
}

/// 这一章有没有成品可展示 / 可清理。
///
/// 🔴 **判据是「> 0」而不是「绑定存在」**：绑定了工程但一页都没跑出来的章
/// （用户建完工程就走了）不该显示成已翻译 —— 那会让"已翻译"页签里出现一批
/// 空章，而用户点进去看到的是原图。同理，绑定在但 json 已不在盘上（工程被删）
/// 时 `studioProductPages` 会是 0，仍然判未翻译。
bool chapterHasTranslation({
  required ChapterTranslationSource source,
}) => source != ChapterTranslationSource.none;

/// 章节翻译态判据本体。
///
/// [studioProductPages] = 该章工程里**至少有一页**带译文块或带 `result/` 位图。
/// 0 ⇒ [ChapterTranslationSource.none]。
ChapterTranslationSource chapterTranslationSource({
  required int studioProductPages,
}) {
  // 🔴 负数当作 0：这个计数来自磁盘工程，一旦某侧算错返回负数，"未翻译"
  // 这一支就会被绕过 —— 而绕过它的后果是给用户显示一个空的「已翻译」章。
  return studioProductPages > 0
      ? ChapterTranslationSource.studioOnly
      : ChapterTranslationSource.none;
}

/// 一章在「已翻译 / 未翻译」两个页签里归哪一边。
///
/// 给筛选用。与 [chapterHasTranslation] 同源，避免"页签分组"与"菜单出现条件"
/// 各写一份判据而某天分叉（分叉的症状是：章在「未翻译」页签里，却长着
/// 「删除译文」菜单）。
bool isTranslatedTab({required int studioProductPages}) => chapterHasTranslation(
  source: chapterTranslationSource(studioProductPages: studioProductPages),
);

/// 详情页该在这一章旁边显示什么。null = 什么都不显示（未翻译且无任务记录）。
///
/// 单独抽出来是因为「显示已翻译标记」和「筛选分组」虽是同一判据，但**输出形状**
/// 不同（一个是 bool、一个是页签归属），三处各写一遍就会出现"标记显示了但菜单
/// 不出现"这种半迁移症状。
int? translatedPageCountForBadge({required int studioProductPages}) {
  final source = chapterTranslationSource(
    studioProductPages: studioProductPages,
  );
  if (!chapterHasTranslation(source: source)) return null;
  return studioProductPages < 0 ? 0 : studioProductPages;
}
