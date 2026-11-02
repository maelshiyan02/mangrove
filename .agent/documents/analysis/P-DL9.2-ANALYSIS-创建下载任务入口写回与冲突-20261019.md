# comix.to 创建下载任务入口写回 + 与其他源冲突分析

> 阶段：P4 / 落地节奏阶段 0（URL 驱动 + 人机协作过 CF）
> 时间：2026-10-19（本轮写回）
> 关联：`A07-comix源.md` / `A07b-comix章节列表采集与分组.md` / `P-DL9.1-ANALYSIS-comix采集架构与创建下载任务可行性-20261019.md`

## 一、本轮写回的代码（阶段 0）

### 改动文件
`lib/pages/download_manager_page.dart`

1. **补 import**：`package:mangrove/network/comix_client.dart`（用于触发 `verifyCloudflare` 人机协作过 CF）。
2. **菜单入口**（L232-234，`downloadManager` 分区的 `+` 菜单 `add_link` 项）：
   - 原占位符 `_showCreateTaskPlaceholder`（只弹"Hint"说明）替换为 `_showCreateComixTaskDialog`。
3. **新增对话框组件** `_CreateComixTaskDialog`（L839-1086）：
   - 输入框粘贴 comix.to 链接，正则 `comix\.to/title/([A-Za-z0-9]+)(?:-([^/?#]+))?` 解析 `hid//slug` 作为 comicId。
   - 「Resolve」→ `source.loadComicInfo!(comicId)` 采集章节；CF 拦截时捕获异常 → `ComixClient().verifyCloudflare(url:)` 弹真实浏览器窗口让用户过一次验证 → 重试。
   - 章节列表按 `ComicChapters.allVersions` 的 `scanlationGroup` 分节、CheckboxListTile 勾选，按 `chapterKey` 各自建 `ImagesDownloadTask`。
   - 空组名兜底 `'Unknown group'.tl`（暂未取 uploader 真组名，见 A07b 待办）。
   - 建任务：`LocalManager().findValidDirectory` 取目录 → `LocalManager().addTasks([ImagesDownloadTask(...)])`。

### 复用既有能力（未重写）
- **章节采集**：`comix_to.js :: comix_fetch_chapters` → Dart 桥 `ComixClient.fetchChapters`（CDP/WebView2/headless 三级回落）。
- **图片字节下载**：`ImagesDownloadTask` 通用任务 + comix 源的 `onImageLoad`（经 WebView/Worker 取字节，Referer 防盗链）。
- **选章/建任务模型**：`ComicDetails` / `ComicChapters.allVersions` / `ImagesDownloadTask` 公开 API。

### 静态校验
- `flutter analyze lib/pages/download_manager_page.dart` → **No issues found**。
- 全工程 analyze 余 82 条均为既有 warnings/infos（studio_page / webview / test 文件），**0 error**，本次改动无跨文件副作用。
- ⚠️ 本沙箱 `flutter test` 不可用、GUI 渲染表面缺失；**真机/用户 GUI 会话跑一次构建与手测**仍需走 `tools/run_build_task.py`（A02 纪律）。

## 二、是否会与其他漫画源冲突？是否需要额外隔离？

**结论：comix 在架构上已被 `ComicSource` 键天然隔离，不需要、也不应该再单独隔离；与包子漫画等既有源零冲突。**

### 隔离边界证据（代码事实）
1. **源加载器互不可达**：`ComicSource.find('comix_to')` 只加载 `assets/comix_to.js`，其 `loadInfo/loadEp/onImageLoad` 只调 comix 专属 Dart 桥（`comix_fetch_html/chapters/pages`）。包子（cn.cnbzmg 等）各有独立 JS 加载器，**永远不会调用 comix 桥**。
2. **下载任务通用但按源分流**：`ImagesDownloadTask(source, comicId)` 是统一队列，但执行时回调各自 source 的 `loadChapters`/`loadPages`；comix 的图片字节走 `onImageLoad`（WebView 取字节），其他源走 Dio——**两条取字节路径互不干涉**。
3. **唯一全局副作用已收敛**：
   - `applyProxySetting()` 用 WebView2 全局 `ProxyController`，只在 comix 流程内生效；
   - `HttpOverrides.global`（CDP 段，comix_client.dart:4041）注释已声明"连完恢复"，用完即复原。
   - 二者都不跨出 comix 流程、且已设计成可恢复，不会污染其他源的 HTTP 客户端。

### 为什么"再隔离"反而有害
- 若把 comix 下载单独抽一条"隔离"路径，会**绕开通用的 `ImagesDownloadTask` 队列与 `LocalManager` 目录管理**，破坏下载管理分区的统一统计/修复/缺页能力；
- 既有的"源键隔离"已是**最小正确隔离粒度**——隔离到源模块级别，既防跨源污染，又保留共享队列。

### 建议
- **保持现状**：comix 只在 `comix_to` 源模块内活动；"创建下载任务"对话框只认 comix.to 链接、只调 `loadComicInfo`，对其他源零侵入。
- **保留搜索→详情页下载**作为其他源（包子等非 CF 强拦截站）的默认路径，不改动。
- 后续若 CF 升级导致 comix 采集彻底失效，只需改 `comix_to.js` + `comix_client.dart`，**不影响任何其他源**。

## 三、待办（阶段 1+，用户已拍板方向，尚未实施）
- 阶段 1：App 自动拉起本机专用 Chrome（`--remote-debugging-port` + 专用 `user-data-dir` + `--disable-blink-features=AutomationControlled`），无 Chrome 时回落 Chrome for Testing（~200MB 真 Chrome 指纹）；采集走 CDP。
- 阶段 2：会话持久化（profile + cf_clearance 复用）；修 A07b 的**同组重复 bug**（`mergedWith` 仅按 chapterKey 去重 → 面板计数虚高）。
- 阶段 3：若 CDP 仍被检测，再评估 CEF / 内置 CfT 深度定制。
- 次要：对话框"未分组"应改为取 uploader 真组名（NUVIATOON 之类），需 comix 源补 `uploader` 字段透传。
