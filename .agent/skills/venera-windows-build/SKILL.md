---
name: venera-windows-build
description: Build and verify the Venera Flutter Windows release. Use when asked to build/rebuild Venera, verify builds/venera artifacts, or fix flutter build windows failures in this workspace.
---

# Venera Windows 构建与验收

工作区根目录（**会改名/搬迁 ⇒ 勿写死绝对路径**），Flutter 工程在 `VeneraX\`，一键脚本是工作区根的 `build_venera.ps1`，绿色成品落 `builds\venera`。

## 环境事实（不在系统 PATH，勿重新安装）

- Flutter 3.47.5：`C:\Flutter\bin\flutter.bat`
- Rust（rhttp/cargokit 用）：`D:\dev\rust`，脚本内设置 `RUSTUP_HOME`/`CARGO_HOME`
  - ⚠️ 2026-09-30 起 rhttp 依赖已在 pubspec 注释（改走 dart:io），常规构建不再需要 Rust；恢复 rhttp 时才需要
- nuget：`D:\dev\tools\nuget.exe`；sqlite3 种子：`D:\dev\tools\sqlite3-src`
- 网络走 Clash 代理 `127.0.0.1:7890`（脚本已内置）
- PowerShell 用 5.1，命令链用 `;` 不用 `&&`
- ⚠️ 漫画源 JS（如 `assets/comix_to.js`）**不打进 flutter_assets**；运行时从 `%APPDATA%\io.github.kyosee\venera\comic_source\*.js` 加载。改了 JS 源必须手动同步到该目录
- 📁 **目录唯一真身 = `.agent/`**（2026-10-07 起）：`.workbuddy/{memory,documents,skills,specs}`、`.trae/{同}`、`docs/` 都是**指向 `.agent/` 的目录联接（junction）**。
  ⇒ **不要再做"两边同步"** —— 那是同一份文件；过去那句"任改一边后同步另一边"已作废。见 `.agent/kb/methodology/M07-多agent共享工作区.md`。

## WorkBuddy 会话内构建（2026-09-30 验证可用）

WorkBuddy 会话里直接跑 flutter 必失败（嵌套进程 CreateFile failed 231；WMI 建进程被安全策略拦）。**唯一验证可行的方式**：

1. 用现成脚本 `tools\build_venera_release.bat`（pub get → analyze --no-fatal-infos → build --release --no-pub → cmake --install 到 builds\venera，日志落 `builds\build.log`，结尾打印 `BUILD_OK`/`BUILD_FAIL`）。**脚本内部已用 `%~dp0` 推导项目根，不写死绝对路径。**
2. 通过计划任务在独立进程树执行：

```powershell
$root = '<项目根>'   # 或直接用 tools\run_build_task.py，它由自身位置推导
$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c \"$root\tools\build_venera_with_log.bat\""
Register-ScheduledTask -TaskName 'VeneraBuild' -Action $action -Force | Out-Null
Start-ScheduledTask -TaskName 'VeneraBuild'   # 需 dangerouslyDisableSandbox
```

3. 轮询 `builds\build.log` 尾部出现 `BUILD_OK` 即完成（增量约 2 分钟）。
   ⚠️ 更省事的方式：直接 `python tools/run_build_task.py`（内部就是上面这套，且会清空日志避免读到上一轮结果）。
4. 若改了 `assets/comix_to.js`，构建后同步：`cp VeneraX\assets\comix_to.js "$env:APPDATA\io.github.kyosee\venera\comic_source\"`

## 标准流程

### 1. 构建前闸门（代码有改动时）

在 `VeneraX\` 下：

- `C:\Flutter\bin\flutter.bat analyze` —— 0 error/0 warning；info 基线 **13 条 prefer_initializing_formals**，新增代码不要增加 info
- `C:\Flutter\bin\flutter.bat test --concurrency=4` —— 当前基线 **838 全过**。默认高并发下 `back_gesture_buried_route_test` 偶发超时，单跑或限并发可过，属已知抖动，不是回归

### 2. 预检脚本编码（必做）

`build_venera.ps1` 含中文注释，**必须是 UTF-8 with BOM**，否则 PowerShell 5.1 按 GBK 误读导致大括号/引号解析错误（典型报错：`Unexpected token ... 宸叉敞鍏?sqlite3`）。

检查与修复（无 BOM 时执行）：

```powershell
# 或直接跑：powershell -File .agent\skills\venera-windows-build\scripts\check_bom.ps1
$root = '<项目根>'                      # 见 §目录约定：勿写死
$p = Join-Path $root 'build_venera.ps1'
$b=[System.IO.File]::ReadAllBytes($p)
if (-not ($b[0]-eq0xEF -and $b[1]-eq0xBB -and $b[2]-eq0xBF)) {
  $c=Get-Content -Raw -Encoding UTF8 $p
  [System.IO.File]::WriteAllText($p,$c,(New-Object System.Text.UTF8Encoding($true)))
}
```

### 3. 在沙箱外启动构建（必须）

`flutter build windows` 会编译 rhttp 的 Rust 部分，rustup 要写 `D:\dev\rust\rustup\tmp`；沙箱内执行必报 `could not create temp file ... (os error 5)` 并附 `TRAE Sandbox Error: hit restricted`。用 Shell 工具时必须带 `dangerouslyDisableSandbox: true`，放后台：

```powershell
powershell -ExecutionPolicy Bypass -File .\build_venera.ps1
```

工作目录 = 项目根（**会改名，勿写死**）。全量 release（C++ + Rust + Dart AOT）约数分钟到十几分钟。

### 4. 验收产物（按此顺序，勿只信口头）

成功标志：日志末行 `√ Built build\windows\x64\runner\Release\venera.exe` + 脚本打印“构建完成”。然后运行验收脚本（沙箱内即可，只读产物+短暂启动 exe）：

```powershell
powershell -ExecutionPolicy Bypass -File .agent\skills\venera-windows-build\scripts\verify_build.ps1
```

脚本检查：68 文件/约 66 MB、`venera.exe`、`data\app.so`、`data\icudtl.dat`、`data\flutter_assets`、25 个 dll，并启动 exe 存活 8 秒冒烟。

关键判据：**构建新鲜度看 `data\app.so` 的时间戳，不看 venera.exe**——exe 是约 0.2 MB 的 runner 壳，不随 Dart 代码重编；app.so（约 17 MB）才是 AOT 产物。

### 5. 汇报与分发

- 汇报文件数、总大小、app.so 时间戳、冒烟结果
- 分发边界是**整个 `builds\venera` 文件夹**（exe + data + dll 缺一不可），绿色免安装、无注册表依赖
- 不要清理用户手动放入的 `resource` 类目录

## 失败速查

| 报错特征 | 原因 | 处理 |
|---|---|---|
| `Unexpected token` + 乱码中文，ParserError | 脚本无 BOM 被 GBK 误读 | 执行第 2 步转 BOM |
| `could not create temp file D:\dev\rust\rustup\tmp ... (os error 5)` + `TRAE Sandbox Error: hit restricted` | 沙箱拦截 rustup 写临时文件 | 沙箱外（disable sandbox）重跑 |
| sqlite3 FetchContent 慢/失败 | 全新构建缺 CMakeCache 种子 | 脚本会自动注入；检查 `D:\dev\tools\sqlite3-src\sqlite3.c` 存在 |
| CMake `CMP0177` dev warning | 策略提示，非错误 | 忽略 |
| `flutter pub get 失败` | 代理/网络 | 确认 Clash 在跑，脚本已设 HTTP(S)_PROXY |
