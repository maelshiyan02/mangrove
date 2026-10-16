# P-DL6.1 漫画管理三处 GUI 修复（2026-10-16）

> 接续《P-DL6 漫画管理重构与网络本地显示模式-20261016.md》。P-DL6 受控构建
> BUILD_OK 后用户人工验证，发现 3 处错误，本场逐一修复（代号 P-DL6.1）。

## 一、错误 1：系统设置「漫画管理」点击卡死并崩溃（严重）

**现象**：在设置左侧点「漫画管理」栏目 → 软件卡死 → 随后崩溃。

**根因**：`lib/pages/settings/comic_management.dart`（P-DL6 重写）把
`_SettingsExpansionTile`（内部是 `ExpansionTile`，一个 **box 控件**）**直接**
放进 `SmoothCustomScrollView` 的 `slivers: [...]` 列表，**缺少 `.toSliver()`
包裹**。`CustomScrollView.slivers` 只能接收 sliver 控件，收到非 sliver 的
box 控件会在布局阶段触发断言 → 渲染失败 → 卡死后崩溃。

**对照**：同工程的 `reader.dart`（阅读设置等）在 `slivers` 里的每个 box 控件
（`_SettingsExpansionTile`、`_SwitchSetting`、`Divider`…）都包了 `.toSliver()`
（reader.dart:417/430/431/446/460/461/805/914/953/1048…）。P-DL5 的旧版
`comic_management.dart` 用的是普通 `ListView`（天然没有 sliver 约束），所以
之前不崩；P-DL6 改用 `SmoothCustomScrollView` 却漏了 `.toSliver()`。

**修复**：给该 `_SettingsExpansionTile(...)` 补 `.toSliver()`，与 ReaderSettings
同款结构一致。

## 二、错误 2：详情页缺页修复按钮被隐藏（应为常驻 + 绿/红）

**现象（用户要求）**：详情页不要把缺页修复按钮隐藏，要常驻；无缺页显示绿色，
有缺页显示红色。

**修复**（`lib/pages/comic_details_page/comic_page.dart` AppBar actions）：
- 移除 P-DL6 的 `if (_localComic != null && missingCount > 0)` 隐藏条件；
- 改为 `_localComic != null` 时**始终显示**修复 `IconButton` 与
  `RepairModeDropdown`（下拉绑定 `autoRepairMissingPages`，与修复弹窗/设置同键）；
- 按钮颜色：`MissingPages.missingCount(baseDir) > 0 ? Colors.red : Colors.green`。

## 三、错误 3：主页下载管理分区显示问题

**现象（用户要求）**：① 主页不要显示「下载了几本书」；② 缺页修复按钮不要灰色，
无缺页绿色 / 有缺页红色；③ 缺页统计按钮同理。

**修复**（`lib/pages/home_page.dart` 下载管理常驻分区）：
- 删除 `if (_current.isEmpty && problemCount == 0)` 分支里的
  `'@a downloaded'.tlParams({'a': _historyCount})` 文案；同步删除已无用的
  `int _historyCount` 字段与 `_update()` 中的 `_historyCount = ...count` 赋值。
- 新增 `missingStyle`：`problemCount > 0` → 红（`errorContainer`/`onErrorContainer`），
  否则 → 绿（`Colors.green`/`Colors.white`）。
- 「缺页统计」(`showMissingStatsDialog`) 与「缺页修复」(`showMissingRepairDialog`)
  两个 `FilledButton` 都改用 `missingStyle` 且**始终 `onPressed` 可用**（不再
  `problemCount == 0 ? null : ...` 灰色 disabled）。

## 四、改动清单（3 文件）

| 文件 | 改动 |
|---|---|
| `lib/pages/settings/comic_management.dart` | `_SettingsExpansionTile(...)` 末尾加 `.toSliver()`（治本崩溃） |
| `lib/pages/comic_details_page/comic_page.dart` | AppBar 修复按钮：移除隐藏条件、常驻、绿/红配色 |
| `lib/pages/home_page.dart` | 删"下载 N 本"文案 + `_historyCount` 字段/赋值；两按钮绿/红且始终可用 |
| `.agent/documents/worklog/P-DL6.1-…md`（本文件） | 工作日志 |
| `.agent/memory/appendices/W00-工作日志索引.md` | 索引追加 P-DL6.1 一行 |

## 五、验收对照

| # | 验收点 | 结果 |
|---|---|---|
| 1 | 设置点「漫画管理」不再卡死/崩溃 | ✅ `.toSliver()` 修复，结构同 ReaderSettings |
| 2 | 详情页缺页修复按钮常驻；无缺页绿、有缺页红 | ✅ 见二 |
| 3 | 主页下载管理不显示"下载 N 本"；两按钮绿/红且非灰 | ✅ 见三 |

- **受控构建**：`python tools/run_build_task.py` → `BUILD_OK`
  （analyze rc=0 / build windows rc=0 / cmake rc=0）。
- **analyze**：0 error。
- 铁律延续：构建只走 `run_build_task.py`；i18n 本轮未新增键；push 只进本地、
  攒批不主动 push。

## 六、后续

- 用户 GUI 复验 3 点（设置不崩 / 详情页按钮常驻绿红 / 主页无"下载 N 本"且按钮绿红）。
- push 时机由用户拍板（当前 main ahead origin/main，提交后 +1，仍不主动 push）。
