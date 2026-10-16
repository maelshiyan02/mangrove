# 下载管理分区（主页常驻）+ 四队列管理页 + 统计/修复二级弹窗

日期：2026-10-14
模块：`lib/foundation/download_manager_store.dart`（新）、`lib/pages/download_manager_page.dart`（新）、
`lib/pages/download_manager_dialogs.dart`（新）、`lib/components/download_wave_progress.dart`（新）、
`lib/pages/home_page.dart`、`lib/foundation/home_layout.dart`、`lib/pages/downloading_page.dart`、
`lib/foundation/local.dart`、`lib/network/repair_download.dart`、`assets/translation.json`、
`test/download_manager_store_test.dart`（新）

## 1. 背景与需求（用户 11 点，2026-10-14）

用户在 GUI 实测发现：漫画页右上角「下载修复」按钮**修不动已缺页的漫画**。两点根因判断：
① 下载本身已完成、无失败项，是「半截文件存在」的连锁反应导致识别失败；
② 超百章同时缺页，单个修复任务嵌套超百章补页子任务，覆盖过大、响应慢。
佐证：单章「修复本章」按钮能成功创建单章修复任务并把红章修成蓝章。

结论：把「一键校验并重下缺页」与「修复下载」整体迭代；由于「下载中」弹窗无法主动显示
（须先建任务才弹出，不便），改为在**编辑主页新增「下载管理」常驻分区**（与本地库同级），
作为下载中弹窗的大幅拓展。逐条需求见下（#11「创建下载任务多步流程」用户明确**延后**）。

## 2. 实现

### 2.1 数据层 `download_manager_store.dart`（新）
三个互不依赖部件：
- `classifyDownloadTask(DownloadTask)`：纯函数，四队列归类。判据顺序——
  报错→problem；在跑→current；暂停但有进度→current（下到一半的活任务，**不**因 `userPaused`
  划到待命）；其余（从未启动）→standby。
- `DownloadHistoryStore`（单例 ChangeNotifier）：`completeTask` 与 repair `_finalize`
  各记一条；持久化 `App.dataPath/download_history.json`，tmp+rename 原子写，fire-and-forget，
  惰性加载，上限 300 条。
- `DownloadProblemScanner`（单例）：`quickScan()`（只读各素材漫画 `missing_pages.json`，毫秒级）
  与 `deepScan()`（逐本 `reconcileDiskState` 磁盘对账，补记「半截目录+磁盘空洞」，带进度、可取消）。
  跳过工程/成品派生卡、本地导入、下载中漫画。`refreshComic()` 供修复完成后刷新快照。

### 2.2 主页常驻分区 `home_page.dart` + `home_layout.dart`
- `kHomeSections` 新增 `HomeSectionMeta('downloadManager','Download Manager',…)`，插在 `local` 之后；
  `normalizeHomeLayout` 的前向迁移会自动把它追加为可见。
- `_sectionWidget` 加 `'downloadManager'` 分支 → `_DownloadManagerSection`：
  标题行（点击进 `DownloadManagerPage`）+ 问题数徽标 + 最多 2 行当前任务迷你预览
  （标题+波浪+暂停/继续）+ 「统计缺页 / 修复缺页」两个直达按钮。进主页即 `quickScan()`。
- 卸载/切页时移除三处 listener，避免泄漏。

### 2.3 四队列管理页 `download_manager_page.dart`（新）
`TabController` 四 Tab：当前 / 过往 / 问题 / 待命。
- 当前/待命/问题任务卡：封面 + 标题 + `subtitle`（来源完整名·翻译组·章节，与下载中弹窗同源）
  + 状态行（含 ETA）+ 波浪进度；动作按队列切换（重试/立即开始/暂停/继续，菜单：置顶/取消）。
- 问题队列 = 报错任务卡 + 缺页漫画卡（`ComicMissingReport`，显示「缺 @a 章 · @b 页」+ 单本修复入口）。
- 过往队列：历史卡，`Download`/`Repair` 徽标区分，修复类显示「修复 @a / 仍缺 @b」。
- 顶部：统计缺页 / 修复缺页 IconButton + 菜单（创建下载任务占位说明 / 清空过往记录）。

### 2.4 二级弹窗 `download_manager_dialogs.dart`（新）
- `showMissingStatsDialog`：进窗即 `deepScan()`，显示「@a 本 · 缺 @b 章 · @c 页」，
  逐本 `ExpansionTile` 展开章节缺页明细；带扫描进度与「取消扫描」。
- `showMissingRepairDialog`：按漫画/章节**勾选**（默认全不选，#10 不一口气全修），
  批量创建 `RepairDownloadTask`（与 `enqueue` 同构造，但结果统一在弹窗反馈，不逐单 toast），
  完成后显示「已为 @b 章、@c 页创建 @a 个修复任务」（#7 结果反馈）。

### 2.5 波浪动效 `download_wave_progress.dart`（新，用户需求 #4）
- **暂停即静止**：`running==false` 时 `controller.stop()` 保留相位，一根线都不动。
- 启动阶段（`progress==null`）波形缓慢横移给「活着」信号；正常传输阶段 3.2s 周期、~2px 振幅，
  只提供质感不频闪（替换旧 `LinearProgressIndicator` 不确定态）。已完成（progress==1）满条纯色不画波。
- 下载中弹窗 `_DownloadTaskTile` 与下载管理页/主页分区共用同一组件。

## 3. 关键坑（已修）

- **`ts`/`paddingHorizontal` 来源**：二者在 `lib/foundation/widget_utils.dart`，经 `app.dart`
  `export` 暴露；`components.dart` 并不转发。新文件须显式 `import app.dart`（否则 undefined）。
- **`ts.s13` 不存在**：`TextStyles` 只有 s8/s10/s12/s14/… ；已全部改 `s12`。
- **`MissingPagesTable` 无 `isNotEmpty`**：只有 `isEmpty`；已改 `!table.isEmpty`。
- **store 相对 import 写错**：`network/download.dart`/`utils/io.dart` 在 `lib/` 下，须用
  `package:mangrove/…` 绝对 import（相对路径解析不到）。
- **自研 `Button.filled/text` 的 `onPressed` 非空**：无 disabled 态。禁用场景改为
  「onPressed 内守卫 / 条件渲染」，而非传 null。
- **`tlParams` 值类型**：`Map<String,Object>` 不接受 `int?`；`entry.failed/chapters`、`counts[cid]`
  等已 `?? 0` / `!` 收口。
- **循环 import**：dialogs 不 import page；二者分别被 home_page 引用。

## 4. 验证

- ✅ `flutter analyze`：本批新增/改动文件 **0 issue**（error/warning/info 全清）。
- ✅ 受控构建 `python tools/run_build_task.py`：`pubget rc=0 / analyze rc=0 / build windows rc=0 /
  cmake install rc=0`，`mangrove.exe` 产出，**BUILD_OK**。
- ✅ i18n：新增 25 个键全部登记 `zh_CN`/`zh_TW`（两语言各 1801 键），`TOTAL MISSING = 0`，JSON 合法。
- ⚠️ `flutter test`：**沙盒内无法运行**——`flutter_tester` 进程 WebSocket 握手失败
  （`Invalid WebSocket upgrade request`），**全部 120 个测试文件**（含既有用例）均在 loading 阶段
  报同一错、`+0`（0 个真跑）。属环境限制（A02：渲染/表面相关只能在 GUI 会话），非代码缺陷。
  新增 `test/download_manager_store_test.dart`（归类四象限、历史 JSON 往返 + 畸形拒绝、
  缺页表聚合、peek 空目录）已过 analyze 类型校验，逻辑待 GUI 会话/CI 复跑。

## 5. 延后 / 待用户确认

- **#11 创建下载任务多步流程**（搜索→选章→下载，含输网址/BT 网络下载）：用户明确**延后**；
  当前仅给入口与「敬请期待」占位弹窗。
- **「本地素材分类标准改变」**（用户图 4 提及但未列入 11 点明细）：需用户确认是否本批做、
  以及要改成什么维度。

## 6. 改动文件清单

- `lib/foundation/download_manager_store.dart`：新增（归类/历史/扫描三部件）。
- `lib/pages/download_manager_page.dart`：新增（四队列页）。
- `lib/pages/download_manager_dialogs.dart`：新增（统计/修复二级弹窗）。
- `lib/components/download_wave_progress.dart`：新增（波浪进度组件）。
- `lib/pages/downloading_page.dart`：进度条换 `DownloadWaveProgress`。
- `lib/pages/home_page.dart`：`_DownloadManagerSection` + `_DownloadManagerMiniRow` + import + 分支。
- `lib/foundation/home_layout.dart`：`kHomeSections` 增 `downloadManager`。
- `lib/foundation/local.dart`：`completeTask` 记历史。
- `lib/network/repair_download.dart`：`_finalize` 记历史。
- `assets/translation.json`：新增 25 键（zh_CN/zh_TW）。
- `test/download_manager_store_test.dart`：新增纯逻辑契约测试。

## 7. 状态

未提交（按用户惯例：改动只进本地 git，统一批次再 push）。
