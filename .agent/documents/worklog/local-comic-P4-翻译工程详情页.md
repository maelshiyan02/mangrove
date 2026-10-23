# P4 · 翻译工程详情页（工程卡 → 工作室之间的过渡页）

> 日期：2026-10-23 ｜ 前序：P3 本地漫画详情页重构
> 关联：用户原始需求「新建翻译工程详情页，把同一本漫画不同章节的多个 bt_ 工程归类」

## 一、问题

- 现有流程里，一本漫画的**不同章节**会被拆成多个 `bt_<hash>` 工程卡：每章一个
  `imgtrans_*.json`，各自算出独立 hash id（`BtProjectManager.comicIdForJsonFile` =
  json 路径的 FNV-1a 哈希）。这些卡分散在本地库 / 主页「翻译工作室」/ 工程列表，
  只能用卡片上的彩色章节标签区分，没有"归到同一本漫画下"的视图。
- `bt_` 卡点击**直接** `TranslationStudioPage(comicId:)` 进画布，没有中间归类页。

## 二、根因（数据模型）

- `BtProjectManager._projects` 按 `bt_<hash>` id 作 key，**一个 json = 一个工程**，无"漫画"
  维度。归类所需的"漫画名"只能从记录派生：`_registerLocal` 把 `title=章节名(parent)`、
  `subtitle=漫画名(grandParent)`，即工程 json 所在文件夹的**祖父目录名**。
- 因此"同一本漫画" = 多张 `bt_` 卡的 `subtitle` 相同。分类键用 `subtitle`。

## 三、方案

1. **新建 `lib/pages/translation_studio/translation_project_detail_page.dart`**
   `TranslationProjectDetailPage({required String comicId})`：
   - `initState` 调 `BtProjectManager().scan()` 确保工程已登记；据 `comicId` 查自身
     `LocalComic`，取其 `subtitle`（漫画名）；
   - 列出所有 `subtitle == 漫画名` 的 `bt_` 工程（subtitle 为空时退化为只列自身），
     按章节名排序，逐条渲染 `_ProjectTile`（章节名 + 页数 + 点按进工作室）；
   - 提供静态 `openFor(context, comicId)`，入口只需传一个 bt_ id，页面自发现分组键——
     三处点击点不必各自取 subtitle。
2. **三处点击入口统一改接**（`local_comics_page` 工程段 onTap / `home_page` 工作室区
   / `translated_comics_page` 工程列表 + 右键菜单）：`TranslationStudioPage(...)` →
   `TranslationProjectDetailPage.openFor(context, comic.id)`。原 studio_page 的 import
   在不再被引用处移除（避免 unused_import）。

## 四、改动清单

- 新增 `lib/pages/translation_studio/translation_project_detail_page.dart`。
- `lib/pages/local_comics_page.dart`：加详情页 import；工程卡 onTap 改接详情页；
  移除不再使用的 `studio_page.dart` import。
- `lib/pages/home_page.dart`：加详情页 import；工作室区 onTap 改接详情页；
  移除 `studio_page.dart` import。
- `lib/pages/translated_comics_page.dart`：import 改指详情页；列表 onTap 与右键菜单
  `Open studio` 均改接详情页；移除 `studio_page.dart` import。

## 五、校验

- `flutter analyze`（4 文件）：**0 error**（仅 3 处 pre-existing `unnecessary_cast`
  warning，位于 local_comics_page，非本次引入）。
- ⚠️ 沙盒无 GUI，实机需用户在 GUI 会话回归：
  1. 本地库/主页/工程列表点一张 `bt_` 工程卡 → 应先进"翻译工程详情页"（标题为漫画名）；
  2. 同一本漫画的多个章节工程应在该页按章节列出；点单条才进工作室画布；
  3. 工作室画布功能不受影响（详情页只是加了中间归类层）。

## 六、命名坑点（永久归档）

- **坑 P4-1「bt_ 工程按 json 路径哈希 id，没有漫画维度」**：`comicIdForJsonFile` 把
  json 路径哈希成 id，每章独立 json ⇒ 每章一张卡。任何"按漫画归类"的功能都必须自己
  从 `subtitle`（= 工程文件夹祖父目录名 = 漫画名）反查，BT 侧不提供归属关系。
- **坑 P4-2「归类键依赖 subtitle 的文件夹约定」**：分组正确性建立在"每章工程放在
  `projects/<漫画名>/<章节名>/`"这一目录约定上（`_registerLocal` 的 subtitle 即由此算）。
  若某工程把 json 直接放 `projects/<漫画名>/`（subtitle="projects"），会退化成单工程一组，
  不影响功能但归类不优雅。后续若改工程新建逻辑（P5），应把"源漫画 id"显式写进工程
  json 元数据，替代基于文件夹的隐式归类。
- **坑 P4-3「openFor 自发现分组键，点击点不必取 subtitle」**：入口只传 `comicId`，
  详情页内部 `find(id)` 拿 subtitle，避免三处重复实现分组逻辑导致漂移（与 P-DL 系列
  "排除判据集中化"原则一致）。

## 七、后续

- Phase 5：翻译工程新建/绑定逻辑重构（显式记录源漫画 id，替代文件夹隐式归类；空文件夹
  也能建工程）。
- Phase 6：成品（ft_）详情与新建适配。
