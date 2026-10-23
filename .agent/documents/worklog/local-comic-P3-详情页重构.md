# P3 · 本地漫画详情页重构（仅本地模式 + 空状态友好）

> 日期：2026-10-23 ｜ 前序：P2 刷新扫描注册 + P2-回归（重复修复）
> 关联：用户原始需求「本地漫画详情页默认只有本地模式」「空漫画不应被当不可用」

## 一、问题

- 本地漫画（sourceKey='local'，无网络源）在详情页 AppBar 仍显示「网络/本地显示模式」切换
  （图标 wifi / 飞行模式，tooltip "Switch to Network/Local Mode"）。但本地漫画**根本没有
  网络模式可言**——所有章节都是本地的，切了也只藏"未下载白章"，而本地漫画没有白章，
  切换毫无意义且误导用户以为还有"联网"能力。
- 空本地漫画（chapters=null、cover=''）进详情页后，章节区直接 `return SliverPadding.zero`
  一片空白，没有任何引导，用户不知道该去"添加章节 / 换封面"。

## 二、方案

1. **隐藏网络/本地模式切换（本地漫画）**：`comic_page.dart` AppBar 的该 `IconButton` 包进
   `if (comicSource != null)`。本地漫画 `comicSource==null`（无源），不显示；有网络源的
   网络漫画照常显示。语义上即"本地漫画默认只有本地模式"。
2. **空本地漫画友好空状态**：`buildChapters` 在 `comic.chapters == null` 分支、且
   `_localComic?.comicType == ComicType.local` 时，渲染一张引导卡：
   - 标题「这本本地漫画还没有任何章节」+ 说明「导入图片即可作为章节阅读，也可以先设置封面」；
   - 两个动作按钮：「添加章节」(`showAddChapterDialog`) / 「管理章节」(`showManageChaptersDialog`)，
     完成后 `update()` 刷新整页。
   - 网络漫画走到 `chapters==null` 通常是异步加载未完，不插这条引导（保持原行为）。

## 三、改动清单

- `lib/pages/comic_details_page/comic_page.dart`
  - 补 `import 'package:mangrove/pages/local_comic_edit_dialogs.dart';`（`showAddChapterDialog` /
    `showManageChaptersDialog`）。
  - AppBar 网络/本地模式切换 `IconButton` 加 `if (comicSource != null)` 守卫（本地漫画不显示）。
  - `buildChapters` 的 `chapters==null` 分支新增本地空漫画引导卡（见上）。

## 四、校验

- `flutter analyze lib/pages/comic_details_page/comic_page.dart`：**0 error**
  （仅 2 处 pre-existing `unused_element_parameter` warning，位于 2480/2482，非本次引入）。
- ⚠️ 沙盒无 GUI，实机需用户在 GUI 会话回归：
  1. 新建空本地漫画 → 进详情页应看到「添加章节/管理章节」引导卡，而非空白；
  2. 打开任一网络下载漫画 → AppBar 仍有 wifi/飞行模式切换；
  3. 打开任一本地漫画（已有章节）→ AppBar **不再**出现该切换。

## 五、命名坑点（永久归档）

- **坑 P3-1「本地漫画详情页不得出现网络/本地模式切换」**：该切换（`comicDisplayLocalMode`）
  语义是"隐藏未下载白章"，只对**有网络源**的漫画有意义。本地漫画无白章、无网络源，显示它纯属
  误导。判定式统一为 `if (comicSource != null)`（而非 `comicType == local`），覆盖更准：
  凡没有源对象的漫画（包括纯本地导入）都不显示。主记忆「本地漫画」段已记"本地漫画不与源站关联、
  无本地/网络模式区分"。
- **坑 P3-2「chapters==null 对本地漫画是持久空状态、对网络漫画是加载中」**：不能在
  `chapters==null` 时一律插引导——网络漫画的章节是异步拉取的，那时也是 null。引导必须叠加
  `_localComic?.comicType == ComicType.local` 判定，只对"本地且确实空"的漫画生效。

## 六、后续

- Phase 4：翻译工程详情页（全新页，归类同一本漫画不同章节的多个 bt_ 工程）。
- Phase 5/6：工程新建逻辑重构、成品适配（本轮用户只点名 P3+P4）。
