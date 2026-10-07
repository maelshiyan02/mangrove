# Flutter 桌面开发环境与 Git 仓库规划分析日志

> **文档日期**：2026-09-27
> **分析范围**：本机 Flutter/VS/Git 环境对 VeneraX（Windows 桌面端）后续开发的影响、VeneraX 源码目录与 portable 成品目录的关系、GitHub 远程仓库的文件取舍
> **文档性质**：环境核查与决策参考（本轮**未修改任何代码**，所有结论均来自实测命令输出）
> **编写原则**：只记录实测事实；版本号、目录体积、工具链探测结果均可复现

---

## 1. 背景与目标

- VeneraX 后续开发专注 **Windows 桌面端**，暂不考虑手机端（Android/iOS）。
- 用户已自行安装 Git、配置 Flutter、安装 Visual Studio Community 2022、在 VSCode 安装 Flutter 扩展，并注册 GitHub 账号准备建仓。
- 待决问题：
  1. 现有环境是否足够？是否还需补装 Android Studio / Visual Studio？
  2. 决定走"路 B"：放宽 pubspec 的 Flutter 精确版本锁，使用本机新 Flutter（不锁版本）。
  3. `VeneraX-master\VeneraX-master`（源码）与 `VeneraX-portable`（成品）是否重复、能否清理。
  4. 哪些文件应上传 GitHub，旧 `flutter_sdk` 能否删除。

---

## 2. 环境实测结果（2026-09-27）

### 2.1 工具链清单

| 组件 | 实测状态 | 证据 |
|---|---|---|
| Flutter | **3.47.5** stable（用户自行安装，MINGW64 终端 `flutter doctor` 输出） | 截图；locale zh-CN，走 `storage.flutter-io.cn` 国内镜像 |
| Dart | 随 Flutter 3.47.5 自带（满足 `>=3.12.0 <4.0.0`） | 无需单独安装 |
| Git | 用户已安装并可在 MINGW64 使用 | `flutter doctor` 全部基础检查通过 |
| Visual Studio | **Visual Studio Community 2022，17.14.37710.0**，`VC.Tools.x86.x64`（C++ 桌面编译器）**已就位** | vswhere 探测：`-requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64` 命中 |
| Android Studio / Android SDK | **未安装，且永远不需要** | 仅 Android 开发需要；本项目只做 Windows 桌面端 |
| Chrome | doctor 显示可用 | 仅 web 调试用；window_manager 等桌面插件在 web 不生效，价值有限 |
| VSCode Flutter 扩展 | 已安装，可创建 Dart 文件 | 用户确认 |

> `flutter doctor` 中 Android toolchain 与 Visual Studio 两个红叉：前者忽略；后者在安装 VS2022 后**重开终端**即变绿（doctor 靠 vswhere 自动探测默认安装路径）。

### 2.2 关键矛盾：Flutter 版本与项目锁不匹配

[pubspec.yaml](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/pubspec.yaml) L7-L9：

```yaml
environment:
  sdk: '>=3.12.0 <4.0.0'
  flutter: 3.44.3      # 注意：无 >= 前缀，是"精确锁"，必须恰好等于
```

- 本机 Flutter **3.47.5 ≠ 3.44.3**，精确锁下 `flutter pub get` 会直接 version solving failed。
- 用户决定走**路 B（放宽锁，改代码）**，替代路 A（保留/搬迁旧的 3.44.3 SDK）。

### 2.3 旧 flutter_sdk（项目目录内，上一轮 AI 安装）

路径 `D:\Ballonstranslator_Windows\flutter_sdk\`：

| 子项 | 内容 | 约体积 | 路 B 走通后的处置 |
|---|---|---|---|
| `flutter\` | Flutter 3.44.3 完整 SDK（自带 dart-sdk、mingit、已下好的引擎缓存） | 3.18 GB | 可删 |
| `pub_cache\` | 旧 PUB_CACHE（依赖包缓存） | 0.34 GB | 可删 |
| `gh_mirror\` | 10 个 GitHub 依赖的本地裸仓镜像（flutter_qjs/photo_view/flutter.widgets 等），用于断网/代理不稳时 pub get 兜底 | 0.07 GB | **最后删**（见 5.2） |
| `appdata_roaming\`、`gitconfig` | 上一轮沙箱重定向的临时配置 | 极小 | 可删 |

已核实无残留引用：用户级/系统级环境变量 `PUB_CACHE`、`FLUTTER_ROOT`、`FLUTTER_STORAGE_BASE_URL` 均为空；全局 `C:\Users\Administrator\.gitconfig` 仅有 `safe.directory=*`，无旧代理配置。

---

## 3. 路 B 实施要点（待执行，本轮未改代码）

### 3.1 必改项（仅一处源码）

`pubspec.yaml` L9：

```yaml
# 改前
  flutter: 3.44.3
# 改后（范围约束，允许 3.47.5）
  flutter: ">=3.44.3 <4.0.0"
```

### 3.2 风险与验证闸门

| 步骤 | 命令（在 `VeneraX-master\VeneraX-master` 内） | 通过标准 |
|---|---|---|
| 1. 重建工程绑定 | `flutter pub get` | 成功；`.dart_tool` 重新绑定 3.47.5（旧绑定指向 flutter_sdk） |
| 2. 静态检查 | `flutter analyze` | 维持 **0 error / 0 warning** 基线（既有 13 条 info 为项目风格基线） |
| 3. 全量单测 | `flutter test` | **832/832 全过**（覆盖翻译引擎、tokenizer、导出任务、同步分类等） |
| 4. 桌面编译 | `flutter build windows` | 产出 `build\windows\x64\Release`（该文件夹即绿色版） |

主要风险不在那行改动，而在 **pubspec.lock 重新求解**：3.44→3.47 跨三个 stable，传递依赖可能借机升级，插件 API 漂移由第 2、3 步捕获。四步全绿才算路 B 走通。

### 3.3 能力分级

- 不装 VS 也能做：写代码、`flutter analyze`、`flutter test`、`flutter run -d chrome` 粗看界面。
- 装好 VS2022 后才能做：`flutter run -d windows` 热重载调 UI（保存即生效）、`flutter build windows` 出绿色成品。**当前 VS 已装好，能力已齐。**

---

## 4. 两个 VeneraX 目录的关系：不是重复，是"源码"与"成品"

| 目录 | 性质 | 内容实测 |
|---|---|---|
| `VeneraX-master\VeneraX-master\` | **源代码工程**（GitHub zip 双层解压所致，内层才有 pubspec.yaml） | `lib/`、`test/`、`assets/`、各平台目录、pubspec.yaml；本地 NMT 引擎、译文导出等全部改动在此 |
| `VeneraX-portable\` | **第三方编译好的旧版成品** | venera.exe、venera_updater.exe、约 20 个插件 dll、flutter_windows.dll、onnxruntime.dll、data\flutter_assets、app.so(AOT)、icudtl.dat |

关键事实：

1. 两者**无共享文件**：portable 是 AOT 编译产物（app.so 不可逆向对应源码），不是源码的副本。
2. portable **不含本轮任何修改**（本地翻译引擎、ComicLibrary 治理、译文导出都在源码里，尚未重新编译）。
3. `VeneraX-portable\data\` 实测**只有程序文件、无用户数据**；用户设置/本地库路径/译文数据库均在 `%APPDATA%\io.github.kyosee\`，删除 portable 不丢个人数据。

**处置建议**：自己 `flutter build windows` 出新版成功前，保留 portable 作为"已知可运行的对照基准"（便于区分环境问题还是代码问题）；新 Release 验证通过后整个 portable 目录可删。

源码目录体积实测：纯源码树（排除 build/.dart_tool）仅 **13.7 MB**，无 >10MB 大文件；`build/` 94.2 MB、`.dart_tool/` 10.3 MB 均为生成物。

---

## 5. Git / GitHub 仓库规划

### 5.1 现状核查

- `Ballonstranslator_win_minium\` **已经是 git 仓库**：分支 main，**未配远程**；A 阶段路径治理等改动大量未提交（launch.py、mainwindow.py、configpanel.py、workspace.py 等）。
- `VeneraX-master\VeneraX-master\` **还不是 git 仓库**（无 .git）。
- `flutter_sdk\flutter\.git` 是 Flutter SDK 自身的仓库，与用户项目无关。
- **git 提交身份未配置**（`user.name`、`user.email` 全局均为空），首次 commit 前必须先设。

### 5.2 分仓建议（不要把工作区根目录传成一个仓库）

工作区根目录含 Flutter SDK（3.6GB，撞 GitHub 单文件 100MB 限制）、漫画图片（版权）、编译二进制、临时调试脚本，必须按项目分仓：

| 建议仓库 | 位置 | 说明 |
|---|---|---|
| VeneraX 源码仓 | `VeneraX-master\VeneraX-master\`（内层 `git init`） | 纯源码 13.7MB |
| BT 仓 | `Ballonstranslator_win_minium\`（已 init，加 remote 即可） | 提交前逐个核对 modified/untracked |
| 漫画源仓（可选） | `venera-configs-main\` | 30 个漫画源 JS，独立成仓便于单独维护 |

### 5.3 VeneraX 源码仓上传清单

**上传**：

- `lib/`、`test/`、`assets/`、`patch/`、`doc/`
- 平台目录 `windows/ linux/ macos/ ios/ android/`（手机端目录体积小，是工程标准组成，保留也便于以后合并上游更新；不装 Android SDK 不影响它们入库）
- `pubspec.yaml` **与 `pubspec.lock`**（应用项目传 lock 保证构建可复现）
- `analysis_options.yaml`、`.metadata`、README、LICENSE、各平台 .gitignore

**不传**（现有 [.gitignore](file:///d:/Ballonstranslator_Windows/VeneraX-master/VeneraX-master/.gitignore) 已覆盖，无需改动）：

- `build/`（94.2MB）、`.dart_tool/`（10.3MB）、`.idea/`、`.vscode/`
- `*.log`、`*.iml`、app 符号表、`data.venera`、`docs/`（注意：上游 gitignore 主动忽略了 docs/）
- `.flutter-plugins*`、`.pub-cache/`、`.serena/`、`.icon_work/` 等工具临时目录

**工作区根目录散落文件不进任何仓库**：`probe_*.py`、`dbg_comick.py`、`test_async_interop.py`、`test_comick_fix.py`、`test_copy_*.py`、`copy_aes.js`、`probe_out/`（一次性取证/调试产物）。两份开发日志 .md 属个人文档，要留档可放进对应项目仓。

### 5.4 建仓操作顺序备忘

1. `git config --global user.name "..."` / `user.email "..."`（用 GitHub 账号邮箱）。
2. VeneraX 内层目录 `git init` → 按 5.3 `git add` 后核对 `git status` 与 `.gitignore` 生效情况 → commit。
3. GitHub 建空仓（**不要**勾选自动生成 README/LICENSE，避免首次推送冲突）→ 按提示加 remote 推送。
4. BT 仓：先完整 `git status` 核对（workspace.py 等新增文件为 untracked，确认无 `__pycache__`/日志/模型混入）→ commit → 加 remote 推送。

### 5.5 合规与隐私

- 仓库若设为 **public**，推送前确认无漫画图片、ONNX 模型、Cookie/密钥配置（`copy_manga*.js` 等自定义源若含 Cookie 需先清理）。
- 两软件均带原项目 LICENSE：保留 LICENSE，README 注明上游出处；条件允许时优先用 GitHub fork 机制承接改动。

---

## 6. 删除/清理顺序（重要：有先后依赖）

1. 完成路 B 第 3.2 节四步验证（pub get / analyze / 832 测试 / build windows 全绿）。
2. 新 Release 在本机实际运行通过（能启动、能浏览本地库）。
3. 此时删 `VeneraX-portable\`（旧成品，已被新构建取代）。
4. 第一次用新环境 `pub get` 成功拉取全部 git 依赖后，再删 `flutter_sdk\gh_mirror\`（离线兜底完成使命）。
5. 最后删 `flutter_sdk\flutter\` 与 `flutter_sdk\pub_cache\`，项目目录共减负约 3.6GB。
6. `probe_out\` 与根目录散落调试脚本确认无用后随时可删（与上述步骤无依赖）。

---

## 7. 结论摘要

- **环境已齐备**：Git + Flutter 3.47.5 + VS Community 2022(C++) + VSCode Flutter 扩展；Android Studio 不需要。
- **唯一代码动作**：pubspec.yaml 放宽 Flutter 版本约束，随后必须过 analyze + 832 测试 + Windows 构建三道闸。
- **两个 VeneraX 目录不重复**：一个是源码（留、且是开发主体），一个是旧成品（新版构建验证后可删）。
- **GitHub 按项目分三仓**，生成物/SDK/漫画/调试脚本均不传；BT 仓已存在只需加远程，VeneraX 需在内层目录 init；提交前先配 git 身份。
- **flutter_sdk 总计约 3.6GB 可回收**，但须在路 B 验证通过、新构建可运行后按第 6 节顺序删除。

---

## 8. 路 B 执行实测记录（2026-09-27 完成）

### 8.1 四道闸门结果

| 闸门 | 结果 |
|---|---|
| `flutter pub get`（C:\Flutter，3.47.5） | 通过，148 个依赖 |
| `flutter analyze` | 0 error / 0 warning；13 info 为既有基线 |
| `flutter test` | 832/832（首轮并发 tearDownAll 偶发失败，单跑与重跑全绿，判定为 Windows 临时目录清理抖动） |
| `flutter build windows --release` | 通过（约 12.5 分钟）；venera.exe 启动冒烟存活正常 |

### 8.2 实际改动文件（7 个，建仓提交清单）

- `pubspec.yaml`：`flutter: '>=3.44.3 <4.0.0'`
- `pubspec.lock`：3.47.5 下重新求解（随 pubspec 一起提交）
- `analysis_options.yaml`：flutter 工具自动升级（排除 build/平台目录）
- `lib/foundation/image_provider/cached_image.dart` L48：`return await file.readAsBytes();`
- `lib/network/app_dio.dart` L204：`return await super.request<T>(...)`
- `lib/utils/data_sync.dart` L1151/1154/1156：3 处 `return await`（uploadData/downloadData）
- `lib/network/file_downloader.dart` L262：onError 回调 `return false;`（onValue 返回 bool，返回类型须一致）

后 5 处是 3.47 新 linter 规则（`unawaited_return_in_try_block`、`return_without_value`）抓到的真实隐患：try 块内不 await 返回的 Future，catch 将捕获不到其异步错误。

### 8.3 构建时补齐的三个环境前提（与代码无关）

1. **sqlite3 源码拉取**：sqlite3_flutter_libs 0.5.42 在 CMake 配置期 FetchContent 下载 `https://sqlite.org/2026/sqlite-autoconf-3520000.tar.gz`（3.26MB，经代理仅 ~25KB/s，两次中断）。解决：手动下载解压到 `build/windows/x64/_deps/sqlite3-src`（扁平布局，sqlite3.c/h 在根），在 `build/windows/x64/CMakeCache.txt` 设 `FETCHCONTENT_SOURCE_DIR_SQLITE3:PATH=<该目录>`。**注意：编辑 CMakeCache 必须无 BOM 保存**（PowerShell Set-Content 易引入 BOM 导致 CMake "Parse error line 1"）。
2. **nuget.exe**：flutter_inappwebview_windows 配置期需要（恢复 WIL/CppWinRT/WebView2/nlohmann 4 个包到 `build/windows/x64/packages`）。置于 `D:\dev\tools\nuget.exe`（NuGet 7.9.0），构建时 PATH 带上。
3. **Rust（MSVC）**：rhttp 经 cargokit 编译 Rust 原生库。rustup minimal profile + stable-x86_64-pc-windows-msvc（rustc 1.98.1）绿色安装于 `RUSTUP_HOME=D:\dev\rust\rustup`、`CARGO_HOME=D:\dev\rust\cargo`（`--no-modify-path`）。构建时 PATH 加 `D:\dev\rust\cargo\bin`。VSCode F5 调试不需要 Rust，仅 release 打包需要。

### 8.4 网络与构建环境变量

- 本机 Clash 代理 `127.0.0.1:7890`：github.com 正常（~1.5s）；pub.dev 偶发超时但 pub 实际拉取成功；sqlite.org 极慢需绕行。构建命令统一带 `HTTP_PROXY/HTTPS_PROXY=http://127.0.0.1:7890`、`NO_PROXY=localhost,127.0.0.1`。
- 插件符号链接（`windows/flutter/ephemeral/.plugin_symlinks`，23 个）必须在**沙箱外/提升权限**终端跑 `flutter pub get` 才能生成；analyze/test 不需要。

### 8.5 成品位置

- 工程自定义 CMAKE_INSTALL_PREFIX 为 **`C:\Program Files\venera`**：绿色成品在此（67 文件、66.1MB，venera.exe 2.3.4+247，data/app.so + flutter_assets + icudtl.dat + 全部插件 DLL），整目录拷走即用。
- `build/windows/x64/runner/Release/` 只有 venera.exe + Webview2Loader.dll 是正常现象（bundle 走 install 目标到 Program Files），不要误判为打包失败。
- zip_flutter 编译告警（C4101 未引用变量、LNK4044 忽略 `/Wl,--build-id=none`）来自第三方源码，无害。
