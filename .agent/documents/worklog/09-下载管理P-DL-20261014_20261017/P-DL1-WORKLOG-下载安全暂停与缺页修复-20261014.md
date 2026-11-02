# 下载缺页根因修复 + 关闭软件安全暂停保护

日期：2026-10-14
模块：`lib/network/download.dart`、`lib/network/repair_download.dart`、`lib/foundation/local.dart`、`lib/foundation/tray.dart`

## 1. 问题现象

用户反馈：一本漫画大量章节下载「缺页」。怀疑是「下载任务运行时关闭软件」导致的连锁反应。

## 2. 根因（已核实）

关窗路径 `TrayController._quitThroughGuards()` 在 `_enabled`（最小化到托盘）为 false 时，
直接 `exit(0)`，**完全没碰下载任务**。杀进程时：

1. 在途图片走 `_ImageDownloadWrapper` 的 `saveTo.joinFile(...).writeAsBytes(p.imageBytes!)`
   —— **直接写最终文件名、非原子**。进程被杀时这张图只写了一半，落下一个**半截的最终文件**。
2. 重启后 `restoreDownloadingTasks()` + `_autoResumeDownloads()` 自动续传该任务。
3. 续传用 `_existingPageIndexes()` 判定某页「已完成」——它**只按 `NNN.ext` 文件名前缀判断存在，
   不校验文件完整性**。半截文件「存在」即被当成已完成 → 该页永不再拉取 → **缺页被永久固化**。
4. 因为进程是被杀的，中断那一章的 `_flushMissing()`（写 `missing_pages.json`）根本没机会执行，
   连「修复下载」都找不到这些页（修复只重拉 `missing_pages.json` 里登记的页）。

所以：每次在下载中途关软件 → 当次在途的几张图变半截文件 → 下次续传把它们当完成 → 多章累积 = 大量缺页。
这就是用户看到的「连锁反应」。

## 3. 修复

### 3.1 原子写（根治未来截断）`download.dart` / `repair_download.dart`
每页先写 `$index$ext.dl` 临时文件，再 `rename` 成最终文件；rename 失败（个别平台/目录不支持）
退化成直接写最终文件。这样即便写盘瞬间被杀，**落盘的是未完成的 `.dl` 临时文件，
绝不会留下半截的最终文件**。

### 3.2 已完成判定排除临时/空壳文件 `_existingPageIndexes()`
- 跳过 `.dl` / `.tmp` 临时文件（避免被算成已完成）。
- 跳过 **0 字节文件**（「写盘被中途打断」最常见残骸，存在但非有效页）。
旧版不区分，半截文件一律算完成。

### 3.3 关闭软件安全暂停保护 `tray.dart` + `local.dart`
- `LocalManager` 新增 `hasRunningDownloads` 与 `suspendAllRunningDownloads()`。
- 每个 `DownloadTask` 子类（`Images` / `Archive` / `Repair`）新增 `suspendForShutdown()`：
  干净停掉在途写入（在途页变 `.dl` 临时文件被忽略），并把 `wasRunning` 持久化为 `true`
  （下次启动 `_autoResumeDownloads` 自动续传）。
- `TrayController._quitThroughGuards()`：在 `exit(0)` 前，若有下载在跑，弹确认框
  「下载进行中 → 暂停并退出 / 取消」。确认则 `suspendAllRunningDownloads()` 再退出；
  取消则中止退出（窗口保持）。最小化到托盘场景本来就不退出，不受影响。

#### ⚠️ 时序坑（已修）
最初实现是 `suspendShutdown=true → save → 立刻置回 false`。但 `save` 是异步的，
单飞写入器（single-flight `_flushDownloadingTasks`）可能在置回 false 之后才读该字段 →
偶发把 `wasRunning` 写成 false，安全暂停失效。改为：**置 true 后 `await` 保存，不立刻复位，
改在 `resume()` 里复位**。这样保存窗口内字段恒为 true，且正常暂停/完成时不会被误带 `wasRunning=true`。

## 4. 验证

- ✅ `BUILD_OK`（`flutter analyze` rc=0 / `build windows` rc=0 / `cmake install` rc=0）。
- ✅ i18n 审计 `TOTAL MISSING = 0`（对话框 4 个中文串走 `.tl` 回退，未新增翻译键）。
- ✅ 新增测试 `test/download_suspend_shutdown_test.dart`：锁定关键不变量
  `suspendForShutdown` 后 `toJson()['wasRunning'] == true`（三类型均覆盖）、
  未 suspend 时跟随 `_isRunning`（false）、`hasRunningDownloads` / `suspendAllRunningDownloads` 空表安全。
  （按项目纪律与 R 系列一致：测试先写、统一跑。）

## 5. 既有漫画如何救回（用户这本已缺页的）

原子写 + 0 字节排除**只防未来**，不会自动修复已存在的半截文件（它们非 0 字节、有合法文件头，
仍会被当成已完成）。可靠的恢复步骤：

1. 打开该漫画 → 确认哪些章节缺页（对比章节页数与实际文件数）。
2. **删除缺页章节的本地文件夹**（或整本漫画的本地目录），再重新加入下载队列。
   —— 配合新原子写，这次重下一定是干净完整的。
3. 若只想补洞且 `missing_pages.json` 已有登记，用「修复下载」即可；否则走步骤 2。

> 注：我没有自动重写「扫描并删除半截图片」的工具。若你想要一键式「校验并重下缺页」按钮，
> 可以在下载/修复面板加一个入口（重跑时对每页做完整性校验后重拉），可作为后续小需求。

## 6. 改动文件清单

- `lib/network/download.dart`：原子写、`_existingPageIndexes` 排除 `.dl`/`.tmp`/0 字节、
  基类加 `suspendShutdown` 字段与 `suspendForShutdown()` 抽象声明、三处 `toJson` 写 `wasRunning ||
  suspendShutdown`、三处 `suspendForShutdown()` 实现与 `resume()` 复位。
- `lib/network/repair_download.dart`：原子写、`suspendForShutdown()` 实现、toJson、resume 复位。
- `lib/foundation/local.dart`：`hasRunningDownloads` / `suspendAllRunningDownloads()`。
- `lib/foundation/tray.dart`：`_quitThroughGuards` 关窗安全暂停确认框。
- `test/download_suspend_shutdown_test.dart`：新增契约测试。

## 7. 状态

未提交（按用户惯例：改动只进本地 git，统一批次再 push）。
