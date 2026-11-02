# P-DL6 漫画管理重构与网络/本地显示模式（2026-10-16）

> 接续《P-DL5 漫画信息自动更新模式-20261016.md》。P-DL5 落地后用户提出 6 点
> 修改意见，本场对 P-DL5 设计做彻底重构（代号 P-DL6）：取消网络/本地漫画区分、
> 删除常驻错误的模式下拉、新增网络/本地显示模式（含待命章浅绿），并把章节
> 状态判定统一收敛到 foundation 层。

## 一、用户 6 点修改意见与落地结论

| # | 用户意见 | 落地方案 |
|---|---|---|
| 1 | AppBar 的「手动/自动」模式下拉实际是缺页修复，且常驻显示错误 | 删除 `ComicInfoModeDropdown`；缺页修复下拉（`RepairModeDropdown`）改为 **仅当 `MissingPages.missingCount > 0` 时显示**，跟随原缺页修复按钮可见性；无缺页一律隐藏 |
| 2 | 不区分网络/本地漫画；增强详情页 ↻ 手动刷新，把本地落后记录更新到最新（更新时间 + 章节数） | 取消 `isLocalLibrary` 来源判定；`_persistEnrichedChapters` 收 `online` 参数，`enrichComicChapters`/`enrichComicUpdateTime` 泛化，刷新即把在线最新元数据（网络缓存更新时间 + 章节矩阵）写回本地；系统设置仍可开关自动刷新 |
| 3 | 设置「漫画管理」下只剩自动更新开关，移除网络/本地双规则区分 | 删除 `_DisabledRuleTile` 与双规则占位；`comic_management.dart` 仅留 `Auto Update Comic Info` 开关 |
| 4 | 设置抬头不顶格（距顶空一行），「漫画管理」四字大一号 | 改用 `SmoothCustomScrollView` + `SliverAppbar` 结构（与 reader 等页一致）；大字号由 `_SettingsExpansionTile` 的 `ts.bold.s18` 天然满足 |
| 5 | 设置+详情页新增网络/本地显示模式切换（wlan / 飞行模式图标），只切换章节列表显示，且阅读器同步、不焊死 | 新增 `comicDisplayLocalMode`（默认 false）；详情页 `IconButton` 切换（`Icons.wifi`/`Icons.airplanemode_active`）；本地模式隐藏"纯白"未下载章，保留蓝/黄/红/浅绿；阅读器章节列表同步过滤 + `LocalManager` listener 动态刷新 |
| 6 | 待命下载队列的异类章节（已建任务、非黄非红非白）赋予浅绿色，且计入本地模式 | `chapterDownloadStatusFor` 新增 `standby` 态；五态配色 白/浅绿/黄/蓝/红；浅绿章在本地模式保留 |

## 二、改动清单（13 修改 + 1 新建 + i18n）

| 文件 | 改动 |
|---|---|
| `lib/foundation/appdata.dart` | 默认表加 `'comicDisplayLocalMode': false`（注释：只影响章节列表显示、与联网无关），置于 `comicInfoAutoUpdate` 之后 |
| `lib/foundation/download_manager_store.dart` | 加 `comicDisplayLocalMode` getter + `setComicDisplayLocalMode`（仿 `comicInfoAutoUpdate`） |
| `lib/foundation/chapter_download_status.dart` | **新建**：`ChapterDownloadStatus` 枚举 + `chapterDownloadStatusFor(comicId, comicType, chapters, chapterKey)`，五态统一判定（缺页/出错→红 > 下载中→黄 > 待命→浅绿 > 已下载→蓝 > 未下载→白），详情页与阅读器共用 |
| `lib/foundation/comic_source/models.dart` | `ComicChapters` 新增通用 `entryCount`（扁平/分组/版本化分别统计）；`mergedWith` 泛化：除版本化并集外新增分组式（按组名并、组内 key 只增不减）与扁平式并集分支，模式不同返回 `this` |
| `lib/foundation/local.dart` | `_writeComic` 加可选 `tags` 参数；`enrichComicChapters` 去掉 `!online.isVersioned` 限制、改用 `merged.entryCount <= before` 判据（`before = old.chapters?.entryCount ?? 0`）；新增 `enrichComicUpdateTime(id, type, updateTime)` 回写 tags 的「更新/最后更新/update」命名空间条目（无则追加 `更新:$updateTime`） |
| `lib/pages/comic_details_page/comic_page.dart` | 移除 `isLocalLibrary` 参数，`_autoRefreshComicInfoOnOpen() => comicInfoAutoUpdate`；两处 `loadData()` 不带参；AppBar actions：缺页时才显示修复按钮 + `RepairModeDropdown(dense:true)`，新增网络/本地模式 `IconButton`；`_persistEnrichedChapters` 收 `online` 参数（更新时间取 `online ?? merged` 原始在线响应），`_fetchNetworkDetails` 传 `online: res.data`；移 `chapter_directory.dart` import，加 `chapter_download_status.dart` |
| `lib/pages/comic_details_page/chapters.dart` | 删除内联 `chapterChipColorFor`、改调 `chapterDownloadStatusFor`（五态配色：待命浅绿 dark `0xFF1B3A24`/`0xFF81C784`、light `0xFFC8E6C9`/`0xFF1B5E20`）；新增 `chapterKeptInLocalMode`；两个 `_computeVisible` 加本地模式过滤（隐藏纯白未下载章） |
| `lib/pages/download_manager_dialogs.dart` | 删除已无使用方的 `ComicInfoModeDropdown` 类及其 state |
| `lib/pages/reader/reader.dart` | 加 import `chapter_download_status.dart`、`download_manager_store.dart` |
| `lib/pages/reader/chapters.dart` | 扁平视图 `_ChaptersViewState` / 分组视图 `_GroupedChaptersViewState` 各加 `_keptInLocalMode` + 本地模式过滤（当前章始终保留）+ `initState`/`dispose` 挂 `LocalManager().addListener(_onLocalChange)` 动态刷新 |
| `lib/pages/settings/comic_management.dart` | **重写**：改 `SmoothCustomScrollView` + `SliverAppbar(title: Text("Comic Management".tl))` + `_SettingsExpansionTile` 结构；仅两个 `SwitchListTile`：`Auto Update Comic Info` / `Local Mode`；删除 `_DisabledRuleTile` 与双规则占位 |
| `lib/pages/settings/settings_search.dart` | category 2「Comic Management」下两条废弃键替换为 `"Local Mode"`（keywords: comic/chapter/local/network/mode/display） |
| `assets/translation.json` | 删 5 键（双规则占位 + 旧 Auto Update 描述）；新增 5 键（zh_CN+zh_TW 同步）：`Local Mode` / `Local mode shows only downloaded…` / `Switch to Network Mode` / `Switch to Local Mode` / 更新版 `Auto Update Comic Info` 描述 |
| `.agent/documents/worklog/P-DL6-…md`（本文件） | 工作日志 |
| `.agent/memory/appendices/W00-工作日志索引.md` | 索引追加 P-DL6 一行 |

## 三、关键技术点

### 1. 取消来源区分（第 2、3 点）
- P-DL5 用 `isLocalLibrary` 区分网络/本地漫画只为"避免重复更新"，P-DL6 全部取消：
  打开时一律按 `comicInfoAutoUpdate` 总开关判定是否自动刷新，**不再**按来源走
  本地只读 / 网络刷新两条分支。
- ↻ 手动刷新在本地库（`localComic != null`）也能拉取在线元数据并**写回**——
  这是「少一话」第一成因的治本：本地落后记录（更新时间 + 章节矩阵）被补到最新。
- `enrichComicChapters` 泛化后，合并判据从"是否版本化"改为
  `merged.entryCount <= before`（条目数不增则不写回），覆盖扁平/分组/版本化三模式。

### 2. 更新时间取旧值缺陷修复（时序）
- P-DL5 本地打开时 `_mergeOnlineMetadata` 把本地旧「更新:09-30」与在线新
  「更新:10-11」并入同一命名空间列表，`findUpdateTime()→first` 拿旧值 ⇒ 显示
  过期日期。P-DL6 改为 `_persistEnrichedChapters` 一律取原始在线响应
  `online ?? merged` 的更新时间，经 `enrichComicUpdateTime` 回写 tags。

### 3. 章节状态统一判定（第 5、6 点）
- 新建 `chapter_downloadStatusFor` 落在 foundation 层，详情页 chips 配色与
  「本地模式」过滤、阅读器过滤**共用同一判据**，避免逻辑分叉。
- 优先级：缺页(红) > 任务出错(红) > 下载中(黄) > 待命(浅绿) > 已下载(蓝) > 未下载(白)。
- 待命（standby）来自 `classifyDownloadTask == DownloadTaskBucket.standby`
  （已建任务、从未启动），排进本地模式范围 ⇒ 用户图4《渣男》等重复章节场景下，
  阅读时不会从已下载本地章跳到纯白未下载章。

### 4. 设置页结构（第 4 点）
- 抬头不顶格由 `SliverAppbar` 的默认间距（与其他设置页 `context.padding.top+56`
  一致）满足；「漫画管理」四字字号 = `_SettingsExpansionTile` 的 `ts.bold.s18`，
  天然比正文大一号，无需额外样式。

## 四、验收对照

| # | 验收点 | 结果 |
|---|---|---|
| 1 | 无缺页时详情页不显示修复下拉；有缺页才显示 | ✅ `MissingPages.missingCount > 0` 守卫，`RepairModeDropdown` 跟随缺页修复按钮 |
| 2 | ↻ 手动刷新把本地落后记录（更新时间+章节数）补到最新；设置可开关自动刷新 | ✅ `_persistEnrichedChapters(online)` + `enrichComicUpdateTime` 回写 |
| 3 | 设置「漫画管理」只剩自动更新开关，无双规则 | ✅ `comic_management.dart` 仅两开关 |
| 4 | 设置抬头不顶格、四字大一号 | ✅ `SliverAppbar` + `ts.bold.s18` |
| 5 | 网络/本地模式切换按钮（wlan/飞行图标）+ 阅读器同步 + 不焊死 | ✅ `comicDisplayLocalMode` + 双端过滤 + `LocalManager` listener |
| 6 | 待命章浅绿且计入本地模式 | ✅ `standby` 态 + 五态配色 |

- **i18n**：全 lib 正则扫描（`.tl`/`.tlParams`），本轮新键均在 zh_CN/zh_TW，
  **TOTAL MISSING = 0**。`tools/tl_key_audit.py` 仍只扫 translation_studio，
  故坚持全 lib 扫描。历史缺失（约 60 条）均为旧债，非本轮引入。
- **受控构建**：`python tools/run_build_task.py`（venv 带 pywin32）→ `BUILD_OK`
  （analyze rc=0 / build windows rc=0 / cmake rc=0）。
- **analyze**：0 error；本轮引入项清零，回到 77 历史 issue 基线（`models.dart:739`
  `unnecessary_non_null_assertion` 与 `chapters.dart:1170`
  `library_private_types_in_public_api` 为既有 lint，非本轮引入）。

## 五、注意事项 / 后续

- **铁律延续**：构建只走 `run_build_task.py`（出 BUILD_OK）；禁直接 flutter/dart；
  i18n 新键同步 zh_CN+zh_TW 且全 lib 0 缺失；push 只进本地 git、攒批不主动 push。
- 本场未改下载任务本身的队列语义（standby/past 归类沿用 P-DL2 的
  `classifyDownloadTask`），仅新增"浅绿"视觉与本地模式入域。
- 「本地模式」仅影响章节列表显示，与是否联网无关（注释已写入 appdata 默认键）。
- 用户 GUI 验收要点：详情页缺页时才显修复下拉；↻ 刷新能把本地记录补到最新；
  设置抬头不顶格+大字号；网络/本地按钮 wlan/飞行图标且阅读器同步；浅绿待命章。
- push 时机由用户拍板（当前 main ahead origin/main，提交后 +1，仍不主动 push）。
