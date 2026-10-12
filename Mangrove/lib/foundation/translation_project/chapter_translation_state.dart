// S9.5-b 追补 · 章节「已翻译」判据 —— 纯逻辑层。
//
// ## 为什么需要这个文件（这是半迁移留下的一个真缺口）
//
// S9.5-b 把**产出**搬进了工作室管线：成品落在工程的 `result/`，绑定落在
// `studioReaderBindings`。但详情页**读**那一侧有四处没跟着搬，仍在读旧引擎的
// `TranslationStore`（`image_translation.db`）：
//
// 1. `_buildChapterStatus` —— 章节右侧的「已翻译 ✓ / N 页」；
// 2. `_chapterHasIdleTranslation` —— 「重译 / 删除译文」菜单的出现条件；
// 3. `_translatedChapterIds` —— 「已翻译 / 未翻译」两个状态页签的分组；
// 4. `_deleteChapterTranslation` / `_reTranslateChapter` —— 实际清理的对象。
//
// 而工作室管线**一行都不写** `TranslationStore`（`studio_chapter_runner.dart`
// 只写工程 json 与 `result/`）。于是用户用工作室翻完一整章之后：
//
// - 章节列表**看不到**已翻译标记；
// - 长按菜单里**没有**「重译 / 删除译文」；
// - 「已翻译」页签**筛不出**这一章。
//
// 症状与「翻译没生效」几乎一样，但译文其实就在 `result/` 里躺着。
//
// ## 判据为什么必须是「并集」而不是「换成工程」
//
// 旧 `TranslationStore` 里有**真实存在**的历史数据（WebDAV 同步过来的、
// S9.5-b 之前翻的章）。直接改成只认工程 ⇒ 那些章的标记、菜单、页签**全部消失**
// （从"能看见"变成"看不见"，是更糟的回归）。
//
// 所以判据取**并集**：任一侧有这一章的成品就算已翻译。
//
// ## 为什么必须是纯逻辑（且与 Flutter 无关）
//
// `A02` 的硬规矩：任何「已完成 ✅」都要有反向验证；而本会话**没有渲染表面**
// （`A01 §3`），像素级只能人工验。"这一章算不算已翻译"是纯判断，可以在
// headless 里被注入故障打红 —— 所以参数全部走注入（`boundEids` /
// `legacyStoredPages` / `studioProductPages`），不碰 implicitData、不碰磁盘。
library;

/// 一章的译文来源。两个来源**互不排斥**（见文件头「为什么取并集」）。
enum ChapterTranslationSource {
  /// 两侧都没有成品。
  none,

  /// 只有旧引擎的 `TranslationStore` 里有（S9.5-b 之前翻的、或别处同步来的）。
  legacyOnly,

  /// 工作室工程里有成品（`result/` 位图或带译文的块）。
  studioOnly,

  /// 两侧都有。
  both,
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
/// [studioProductPages] = 该章工程里**至少有一页**带译文块或带 `result/` 位图；
/// [legacyStoredPages] = 旧 `TranslationStore` 里该章的成品页数。
/// 两侧都为 0 ⇒ [ChapterTranslationSource.none]。
ChapterTranslationSource chapterTranslationSource({
  required int studioProductPages,
  required int legacyStoredPages,
}) {
  // 🔴 负数当作 0：这两个计数来自两套独立的存储（磁盘工程 / SQLite），
  // 一旦某侧算错返回负数，"未翻译"这一支就会被绕过 —— 而绕过它的后果是
  // 给用户显示一个空的「已翻译」章。夹负数比夹 null 便宜，且不会静默改语义。
  final studio = studioProductPages < 0 ? 0 : studioProductPages;
  final legacy = legacyStoredPages < 0 ? 0 : legacyStoredPages;
  if (studio > 0 && legacy > 0) return ChapterTranslationSource.both;
  if (studio > 0) return ChapterTranslationSource.studioOnly;
  if (legacy > 0) return ChapterTranslationSource.legacyOnly;
  return ChapterTranslationSource.none;
}

/// 一章在「已翻译 / 未翻译」两个页签里归哪一边。
///
/// 给筛选用。与 [chapterHasTranslation] 同源，避免"页签分组"与"菜单出现条件"
/// 各写一份判据而某天分叉（分叉的症状是：章在「未翻译」页签里，却长着
/// 「删除译文」菜单）。
bool isTranslatedTab({
  required int studioProductPages,
  required int legacyStoredPages,
}) =>
    chapterHasTranslation(
      source: chapterTranslationSource(
        studioProductPages: studioProductPages,
        legacyStoredPages: legacyStoredPages,
      ),
    );

/// 详情页该在这一章旁边显示什么。null = 什么都不显示（未翻译且无任务记录）。
///
/// 单独抽出来是因为「显示已翻译标记」和「筛选分组」虽是同一判据，但**输出形状**
/// 不同（一个是 bool、一个是枚举 + 一个是页签归属），三处各写一遍就会出现
/// "标记显示了但菜单不出现"这种半迁移症状 —— 那正是本文件要修的那个 bug 的
/// 另一种表现。
int? translatedPageCountForBadge({
  required int studioProductPages,
  required int legacyStoredPages,
}) {
  final source = chapterTranslationSource(
    studioProductPages: studioProductPages,
    legacyStoredPages: legacyStoredPages,
  );
  if (!chapterHasTranslation(source: source)) return null;
  // 页数取**两侧之和**：工作室的 `result/` 与旧缓存的页是**不同的页集合**
  // （工作室是工程页键，旧缓存是 `cacheKey`），相加不会重复计数；而取
  // max 会让"工作室翻了 90 页、旧缓存有 3 页"显示成 90 —— 用户以为只翻了 90，
  // 实际是 93 页有成品。
  return (studioProductPages < 0 ? 0 : studioProductPages) +
      (legacyStoredPages < 0 ? 0 : legacyStoredPages);
}