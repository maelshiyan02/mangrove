# P8 · 新建入口常驻化 + 工具栏卡片化（用户验收反馈修复）

日期：2026-10-23 ｜ 版本：`2.8.12+256` ｜ 构建：`BUILD_OK`

## 一、背景（用户人工验收后提出的两个缺失）

1. **详情页「添加章节」入口消失**：空本地漫画加过一次章节后，详情页再没有任何「添加章节」按钮，无法继续加章。
2. **翻译工程「再建入口」消失 + 工具栏按钮不适配**：翻译工程建完一个后，工程段不再有任何新建入口；且本地库右上角「新建漫画」工具栏按钮与工程/成品段的卡片式新建按钮风格不一致，有项目时文案还是 "No ... yet" 这种不适配台词。

用户要求：
- 把右上角「新建漫画」按钮改成**和工程/成品一样的卡片式新建按钮**，且**常驻**（不只空段出现）。
- 卡片文案回归**动作型**（新建漫画 / 新建翻译工程 / 导出成品），不要 "当前没有…" 否定句。

## 二、Gap #1 — 详情页章节区常驻「添加章节」

- **根因**：P3 只在 `comic.chapters == null`（空漫画）时由 `buildChapters` 空状态引导提供「添加章节 / 管理章节」按钮；一旦加了章节，`chapters` 非空 → 走常规 `_ComicChapters` 列表，详情页再无「添加章节」入口。
- **修复**：`lib/pages/comic_details_page/chapters.dart` 的 `buildNormalTitle`（章节标题行 trailing，普通/分组两种章节视图共用）里，对 `pageState.comic.comicType == ComicType.local` 的本地漫画，trailing 行常驻追加一个「添加章节」`IconButton`，点击调 `showAddChapterDialog(context, pageState.comic as LocalComic)`，成功即 `pageState.update()`。
- **注意**：`chapters.dart` 是 `comic_page.dart` 的 `part`，共享其 import，因此 `showAddChapterDialog` / `LocalComic` / `ComicType` 均已在作用域内，无需新增 import。

## 三、Gap #2 + 工具栏改造 — 三段时间卡片式新建按钮常驻

- **根因**：工程/成品段仅 `comics.isEmpty` 时渲染 `_buildEmptySegmentSliver` 占位卡（"No translation projects yet" 等），建完一个工程后占位卡消失 → 找不到再建入口；「新建漫画」只在工具栏右上角 `IconButton`，与工程/成品段的卡片式风格不一致。
- **修复**（`lib/pages/local_comics_page.dart`）：
  1. 移除工具栏 `normalActions` 里的「新建漫画」`IconButton`（保留 刷新 / 搜索 / 排序 / 下载 / 导入导出菜单）。
  2. 用 `_buildCreateCard(kind)` 替换 `_buildEmptySegmentSliver`：网格末尾**常驻**渲染一张「新建」卡片（实线边框 + 加号 + 动作文案），按 `kindFilter` 分三种：
     - 素材 → **新建漫画**（`showCreateLocalComicDialog`）；
     - 工程 → **新建翻译工程**（`createStudioProject` + `BtProjectManager().scan()`）；
     - 成品 → **导出成品**（`_pickProjectAndPublish`）。
  3. 卡片用独立 `SliverGrid(SliverGridDelegateWithComics())` 承载，与上方 `SliverGridComics` **同列对齐**；仅在 `!searchMode && !multiSelectMode` 时显示。
  4. 文案统一为**动作型**，不再用 "No ... yet"。

## 四、命名坑点（沉淀到主记忆 `MEMORY.md`）

- **P8-1「建完即失入口」反模式**：占位卡用 `if (list.isEmpty) 显示` 的思路，会在有内容后消失，导致「再建一个」入口丢失。凡「新建」类入口应**常驻**，不要只在空态出现。
- **P8-2 网格末尾追加卡片对齐**：要让附加卡片与 `SliverGridComics` 同列，须用独立 `SliverGrid` + 相同 `SliverGridDelegateWithComics()` 委托，不能用 `SliverToBoxAdapter` 居中（会错位成单列）。
- **P8-3 卡片文案动作型**：新建/导出类卡片文案应是「新建漫画 / 新建翻译工程 / 导出成品」这种**动作短语**，不要用 "No ... yet" 否定句（不适配、像报错）。
- **P8-4 委托非 const**：`SliverGridDelegateWithComics()` 不是 const 构造，包 `const` 会 `const_with_non_const` 编译错误。
- **P8-5 详情页加章入口位置**：挂在章节标题行 `trailing`（`_ComicSectionHeader`）比放 AppBar 更语境化；`chapters.dart` 是 `comic_page.dart` 的 part，共享 import。

## 五、校验

- `flutter analyze`（local_comics_page / chapters / comic_page）：**0 error**。
  - 残留 3×`unnecessary_cast`（local_comics_page 菜单 builder 内 `c as LocalComic`，改动前既有）、2×`unused_element_parameter` + 1×`library_private_types_in_public_api`（comic_page/chapters 既有 info/warning），均非本次引入、不阻断构建。
- Windows release 构建（pywin32 venv + S4U 沙盒）：`builds/build.log` 全绿 `BUILD_OK`，版本 `2.8.12+256`。

## 六、后续

- P5：翻译工程新建 / 绑定逻辑重构（显式 `comicId` 归属，替代 subtitle 隐式归类；空文件夹也能建工程）。
- P6：成品（`ft_`）详情与新建适配。
