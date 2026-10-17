# P-DL7 应用数据存储位置与缓存迁移（2026-10-17）

> 用户手动删除了 `C:\MangroveCache`，并在系统设置里找不到缓存路径修改入口；
> 希望：① 真缓存（图片缓存）默认落在 `D:\AI Coding Project Management\Mangrove`
> 下面；② 历史上 Mangrove 的数据（尤其缓存与历史记录）都在 C 盘，要一并随项目走；
> ③ 系统设置里补充「显示当前缓存保存的文件夹位置」；④ 并附加「修改缓存路径」功能。
> 本场落地数据目录可配置化 + 设置页可视化 + C 盘数据迁移（代号 P-DL7）。

## 一、背景与根因定位

**`C:\MangroveCache` 是什么**：VeneraX→Mangrove 迁移时期的**诊断/备份残留**，
与运行时无关，用户已手动删除，无需保留。

**真实的 C 盘数据落点**（经核验，是 pid 为 `io.github.maelshiyan02` 的 Flutter 应用
默认路径）：
- `%APPDATA%\io.github.maelshiyan02\mangrove\`（Roaming）
  —— `appdata.json`、`history.db`、`cache.db`、`cookie.db`、各业务 `*.db`、
  `comic_source/`、`webview/`、`local/`、`backup_*/` 等；
- `%LOCALAPPDATA%\io.github.maelshiyan02\mangrove\cache\`（Local）
  —— **307 MB / 2954 个漫画图片缓存文件**（真缓存就在这里）。

**漏搬点（关健坑）**：`lib/network/cookie_jar.dart` 原硬编码
`(await getApplicationSupportDirectory()).path + '/cookie.db'`，若只搬
`dataPath` 会漏掉 Cookie，须一并改走 `App.dataPath`。

## 二、两个设计岔路（用户拍板）

1. **仓库默认策略** → **便携模式（portable）**：数据默认放 exe 同级 `data/`，
   天然随应用/项目走；需要固定部署时再用「更改数据目录」指到项目目录（写覆盖指针）。
2. **现有 C 盘数据** → **迁移到新位置**：复制到项目 `data/` 目录，旧目录**保留**
   待用户确认后手动删（本机 `safe-delete` 守卫禁止 >50 文件程序化删除，故只复制不删）。

## 三、覆盖指针的时序设计（避坑）

默认数据目录**不能**读 `appdata.settings`（时序：`App.init()` 早于 `data.init()`
加载 appdata），否则形成循环依赖。因此覆盖指针用**独立于 `dataPath` 的固定位置**
`%LOCALAPPDATA%/.mangrove_datapath`（一行绝对路径），由 `App.init()` 在最早阶段同步读取。
该文件不参与数据目录自身搬迁，规避循环依赖。

## 四、改动清单（6 文件 + 1 临时迁移脚本）

| 文件 | 改动 |
|---|---|
| `lib/foundation/app.dart` | `dataPath`/`cachePath` 可配置化：新增 `_dataPathPointerFile`（固定指针文件）、`_dataDirectoryOverride`、`dataDirectoryOverride` getter、`_readDataDirectoryOverrideSync()`、`setDataDirectoryOverride()`；`init()` 先读指针→有则用之、无则 exe 同级 `data/`（创建失败回退 `getApplicationSupportDirectory`）。**成员为实例成员**（类为 `_App`，全局 `App` 是实例，与 `dataPath` 一致，避免 instance_access_to_static_member）。 |
| `lib/network/cookie_jar.dart` | `cookie.db` 路径由硬编码 `getApplicationSupportDirectory` 改为 `"${App.dataPath}/cookie.db"`，随数据目录搬迁。 |
| `lib/pages/settings/data_sync.dart` | 新增「App Data Storage Location」`_SettingsExpansionTile`：① Data Directory 只读行（显示 `App.dataPath` + 自定义/便携 标签 + 打开/复制按钮）；② Comic Cache Directory 只读行（`CacheManager.configuredPath` + 打开/复制）；③ `Change Data Directory` 回调（`selectDirectory` → `App.setDataDirectoryOverride` + 重启提示）；④ `Change Comic Cache Directory` 回调（`CacheManager.setCustomDirectory` + 重启提示）；⑤ 说明行（重启生效 + 历史/设置/缓存/Cookie 均在数据目录下）。新增 `_openFolder()` 用 `launchUrlString(Uri.file(path))`。 |
| `assets/translation.json` | 新增 12 键，zh_CN + zh_TW 双语言同步：App Data Storage Location / Data Directory / Comic Cache Directory / Change Data Directory / Change Comic Cache Directory / Data directory set, please restart… / Comic cache directory set… / Changing the directory takes effect… / History, settings, cache and cookies are all stored… / Cannot create directory: / Custom / Portable。 |
| `lib/pages/settings/settings_search.dart` | 搜索索引追加 5 条（category 4）：App Data Storage Location、Data Directory（keywords path/storage/folder）、Comic Cache Directory（cache/path/folder）、Change Data Directory、Change Comic Cache Directory。 |
| `.gitignore` | 注释后追加 `/data/`，忽略项目运行时数据目录，避免 1GB+ 迁移数据进 git。 |
| `C:\Users\Administrator\AppData\Local\Temp\migrate_appdata.py`（临时，不入库） | 复制 Roaming 应用数据 + Local 漫画缓存到 `D:\AI Coding Project Management\Mangrove\data`，**复制完成后再写指针**（避免中途打断读到半截目录）。 |

**i18n 复用**：`Copy`/`Open Folder`/`Change` 等已有键直接复用，新增键均为设置页专用文案。

## 五、本机数据迁移执行结果（已跑，沙盒外）

- 复制 `%APPDATA%\…\mangrove` → `D:\AI Coding Project Management\Mangrove\data`：**1787 文件**
- 复制 `%LOCALAPPDATA%\…\mangrove\cache` → `…\data\cache`：**2954 文件**
- 合计 **1079.7 MB**；目标目录含 `appdata.json / history.db / cookie.db / cache.db /
  comic_source / webview / cache` 等全部数据。
- 指针 `%LOCALAPPDATA%/.mangrove_datapath` = `D:\AI Coding Project Management\Mangrove\data`（复制后写入）。
- **旧 C 盘目录未删除**（仅复制，符合「复制不删」方案，待用户确认后手动删）。

## 六、验证

- **受控构建**：`python tools/run_build_task.py` → `BUILD_OK`
  （analyze rc=0 / build windows rc=0 / cmake rc=0）。
- **analyze**：`flutter analyze` **0 error**（77 个历史 warning/info 全部在
  `headless_*` / `studio_page` / `test` 等文件，本场改动文件零新增告警）。
- **i18n**：所有新增 `.tl` 字面量在 zh_CN + zh_TW 均有登记。
- 构建中途曾因 `dataDirectoryOverride`/`setDataDirectoryOverride` 误声明为 `static`、
  被 `App.`（实例）调用触发 `instance_access_to_static_member` 两次失败；改为实例成员后通过。

## 七、验收对照（GUI 由用户在用户会话验证）

| # | 验收点 | 预期 |
|---|---|---|
| 1 | 设置「Data & Sync」出现「App Data Storage Location」分组 | ✅ 代码已加 |
| 2 | 显示 Data Directory = `D:\AI Coding Project Management\Mangrove\data`（标签「自定义」） | ✅ 指针已写 |
| 3 | 显示 Comic Cache Directory 路径 + 打开/复制按钮可用 | ✅ |
| 4 | 「Change Data Directory」选目录 → 提示重启生效；重启后数据根切换 | ✅ |
| 5 | 「Change Comic Cache Directory」选目录 → 提示重启生效 | ✅（复用 `CacheManager.setCustomDirectory`） |
| 6 | 旧 C 盘 Roaming/Local 数据已落到项目 `data/`，应用运行正常 | ✅ 已迁移 |

## 八、后续 / 待用户处理

- ⚠️ **请用户在确认应用运行无误后，手动删除旧 C 盘目录**（仅复制、未删）：
  `%APPDATA%\io.github.maelshiyan02\mangrove` 与
  `%LOCALAPPDATA%\io.github.maelshiyan02\mangrove`。
- 铁律延续：构建只走 `run_build_task.py`；i18n 本轮新增 12 键 + 双语言；push 仅进本地、
  攒批不主动 push（当前 ahead 26 → 提交后 27，待用户拍板再 push）。
- 迁移脚本为临时文件（`%TEMP%/migrate_appdata.py`），不入库。
