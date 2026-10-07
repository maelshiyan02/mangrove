# VeneraX × BallonsTranslator 融合开发战略规划与复盘分析

> **文档日期**：2026-09-27
> **文档性质**：复盘分析 + 中长期战略规划（本轮不修改代码）
> **编写原则**：所有技术判断基于已验证代码事实；未确定方案标记为"待决策"

---

## 第一部分：环境复盘与目录治理

### 1.1 三个环境前提是什么、是否需要你本地配置

| 前提 | 作用 | 使用场景 | 是否需要你主动学习 |
|---|---|---|---|
| **nuget.exe** | 恢复 `flutter_inappwebview_windows` 所需的 4 个 Windows C++ 包（WebView2/CppWinRT/WIL/nlohmann） | 仅 `flutter build windows` 时 | **不需要学**。放一个 exe 在 PATH 即可，零配置 |
| **Rust 工具链** | 编译 `rhttp` 插件的 Rust 原生代码（HTTP 客户端） | 仅 `flutter build windows` 时 | **不需要学**。cargo 全自动编译，你不需要写 Rust |
| **sqlite3 源码种子** | 绕过 sqlite.org 极慢下载，让 CMake 直接取用本地源码 | 仅首次/清理后构建时 | **不需要学**。是一次性环境准备 |

**结论**：这三个都是"构建时一次性依赖"，不是开发日常。你日常写代码/调 UI 时只需要 VSCode + Flutter 扩展 + F5 热重载，完全不需要关心它们。

**建议的取巧保留方式**：把 `D:\dev\tools`（nuget）和 `D:\dev\rust` 保留，但**不写入系统 PATH**。写一个 `build_venera.bat` 放在项目目录，只在打包时临时注入 PATH：

```bat
@echo off
set HTTP_PROXY=http://127.0.0.1:7890
set HTTPS_PROXY=http://127.0.0.1:7890
set NO_PROXY=localhost,127.0.0.1
set PATH=D:\dev\tools;D:\dev\rust\cargo\bin;%PATH%
flutter build windows --release
```

这样既不污染系统环境，又保留了一键打包能力。

### 1.2 工作区目录整理现状与建议

当前 `D:\Ballonstranslator_Windows` 根目录散落问题（Glob 实测）：

| 现状 | 问题 | 建议 |
|---|---|---|
| `probe_*.py` × 6、`test_*.py` × 4 | 一次性调试脚本散在根目录 | 移入 `tools/probes/` 或删除（已验证完毕） |
| `probe_out/`（html/json） | 漫画源取证产物 | 移入 `tools/probe_out/` 或归档后删除 |
| 两个 `.md` 开发日志散在根目录 | 文档未归类 | 移入 `docs/` |
| `venera-configs-main/`（30 个 JS 源） | 漫画源配置独立目录，本身合理 | 保留，但考虑更名为 `comic-sources/` |
| `VeneraX-master/VeneraX-master/` | 双层嵌套（见 1.3） | 内部目录才是工程，外层是空壳 |
| `flutter_sdk/`（3.6GB） | 已完成历史使命 | 按第 6 节顺序删除 |
| `VeneraX-portable/` | 旧成品，已被 C:\Program Files\venera 取代 | 验证新版可用后删除 |

**建议的目标布局**：

```
D:\Ballonstranslator_Windows\
├─ .trae/                         ← Trae IDE 配置（保留）
├─ .vscode/                       ← VSCode 配置（保留）
├─ docs/                          ← 开发日志统一归位
│   ├─ venera_comic_source_dev_log.md
│   ├─ venera_local_nmt_dev_log.md
│   └─ flutter_env_git_plan.md
├─ tools/                         ← 调试脚本、probe 工具
│   ├─ probes/
│   └─ probe_out/
├─ comic-sources/                 ← venera-configs-main 改名
├─ VeneraX/                       ← 源码（单层，去掉外层 master）
│   ├─ lib/ test/ assets/ ...
│   └─ pubspec.yaml
├─ BallonsTranslator/             ← BT 源码
│   └─ ballontranslator/ ...
├─ builds/                        ← 绿色成品输出（替代 C:\Program Files）
│   └─ venera/                    ← 自定义安装前缀
├─ ComicLibrary/                  ← 下载/翻译/导出（已规划）
│   ├─ downloads/
│   └─ translated/
└─ README.md
```

### 1.3 VeneraX-master 嵌套两层的原因

**100% 是解压操作导致的，不是编程产生的。**

GitHub 的源码 zip（如 `VeneraX-master.zip`）内部自带一层 `VeneraX-master/` 目录。如果你：
1. 先解压 zip 到某处，得到 `VeneraX-master/`（第一层）
2. 又把这个文件夹整个移动/复制到 `Ballonstranslator_Windows/` 下
3. 结果就变成 `Ballonstranslator_Windows/VeneraX-master/VeneraX-master/`

或者你用了某个解压工具设置了"解压到同名文件夹"，而 zip 本身已有同名外层，导致双层。

**真正需要 VSCode 打开的是内层**（有 `pubspec.yaml` 的那一层）。外层目录没有任何工程意义，可以直接删除，把内层 `VeneraX-master` 文件夹上移一层。

### 1.4 为什么成品在 `C:\Program Files\venera` 而不是项目目录

**这不是我们的决定，是上游原作者在 `windows/CMakeLists.txt` 里硬编码的。** 实测证据：构建生成的 `cmake_install.cmake` 第 5 行全部为 `set(CMAKE_INSTALL_PREFIX "C:/Program Files/venera")`。

上游这样写的目的是复刻传统 Windows 安装程序布局（类似 `C:\Program Files\AppName\`），配合 Inno Setup 打包成安装包（`windows/build.iss`）。但副作用是：
- 绿色成品在 C 盘，需要管理员权限才能写入
- 每次构建都会覆盖 C 盘文件
- 不方便和项目目录一起管理

**建议的改动方向**（后续实现）：修改 `windows/CMakeLists.txt`，把 `CMAKE_INSTALL_PREFIX` 指向项目内的 `builds/venera/`。这样：
- 成品和源码在一起，绿色版直接拷走
- 不需要管理员权限
- 多版本并行测试时互不覆盖

---

## 第二部分：中长期战略规划

### 2.1 整合方向：以 VeneraX 为框架，接纳 BT 翻译能力

你的判断完全正确：VeneraX 是"阅读器"，BT 是"翻译工作台"。整合不是把两个 UI 拼在一起，而是让 VeneraX 的阅读流程中**按需调用 BT 的翻译能力**。

**分层架构建议**：

```
┌─────────────────────────────────────────┐
│  VeneraX UI 层（Flutter）                │
│  - 漫画浏览/阅读/书架                     │
│  - 侧边栏/工具栏（参考 comix.to 设计）     │
│  - AI 辅助翻译交互（框选/实时/合并）        │
│  - 汉化成品阅读模式                       │
├─────────────────────────────────────────┤
│  翻译管线层（Dart + Python FFI/Isolate）  │
│  - OCR 检测（已有 ONNX）                  │
│  - 本地 NMT 翻译（NLLB/Marian，已接入）   │
│  - 渲染叠加（已有 page_renderer）         │
│  - 导出成品（cbz/pdf/epub/图片文件夹）     │
├─────────────────────────────────────────┤
│  BT 核心能力层（Python， Isolate/进程通信）│
│  - 气泡检测与分割（CV 模型）              │
│  - 精确抹字/修复（inpainting）            │
│  - 排版回填（字体/大小/颜色）             │
│  - 工程文件管理（json + mask + 底图）     │
├─────────────────────────────────────────┤
│  数据层                                  │
│  - ComicLibrary/downloads（生肉）        │
│  - ComicLibrary/translated/projects（工程）│
│  - ComicLibrary/translated/exports（成品）│
└─────────────────────────────────────────┘
```

**为什么不是反过来以 BT 为框架？**
- BT 是 Python + Qt，UI 框架老旧，跨平台成本高
- VeneraX 是 Flutter，天然支持 Windows + 未来可扩展
- BT 的核心价值是"翻译算法"（OCR/抹字/排版），不是"阅读体验"

**整合的里程碑**：
1. **阶段一**（近期）：VeneraX 内嵌"AI 辅助阅读"模式（在线漫画实时 OCR+翻译）
2. **阶段二**（中期）：VeneraX 打开本地 BT 工程文件，直接阅读已汉化成品
3. **阶段三**（远期）：VeneraX 内嵌简化版"翻译工作台"（框选→翻译→回填→保存工程）

### 2.2 AI 翻译体验优化（阅读辅助场景）

当前 VeneraX 实验性 AI 翻译的核心问题：**OCR 检测精度差**，漏框严重。这直接决定了辅助翻译的可用性。

**问题拆解与对应方案**：

| 问题 | 影响 | 技术方向 |
|---|---|---|
| 漏检对话气泡 | 用户看不到翻译 | ① 调低 ONNX 检测阈值 ② 支持用户手动框选补漏 ③ 引入 manga-ocr 专用模型（已接入但需优化参数） |
| 两个连续气泡被分割 | 断句翻译质量差 | ① 检测后处理：相邻气泡合并规则（IoU > 阈值或距离 < 阈值）② 排版阶段合并渲染 |
| 页眉页脚广告/网站水印 | 浪费翻译资源 | ① 区域过滤：排除页面边缘固定高度区域 ② 支持用户设置"不翻译区域"遮罩 |
| 竖排文字识别差 | 日漫常见 | manga-ocr 模型已支持竖排，但需确认当前参数是否启用 |

**参考 comix.to 阅读器设计**：
- comix.to 的网页阅读器采用**无边框全屏 + 底部悬浮工具栏 + 点击翻页/滑动滚动**的设计
- 侧边栏极简（仅章节列表、设置）
- 工具栏常驻但半透明，不遮挡画面
- **关键差异**：网页端不受桌面窗口管理限制，Flutter 桌面端需要 window_manager 配合实现类似效果

**VeneraX 可借鉴的具体改进**：
1. 阅读页全屏时隐藏系统标题栏，底部显示半透明悬浮工具栏（当前/总页、缩放、翻译开关）
2. 右键/长按弹出快捷菜单（框选翻译、添加书签、跳页）
3. 章节列表改为底部滑出抽屉（节省侧边空间）
4. 双页模式下支持跨页连续阅读（长画布模式的简化版）

### 2.3 BT 成品汉化融入 VeneraX

**前提理解**：BT 的"成品"是三件套——
- `mask/`：空白对话气泡底图（已抹字）
- `result/`：翻译后的最终图片（填字完成）
- `*.json`：气泡位置 + 原文 + 译文的结构化数据

**融入方案对比**：

| 方案 | 实现方式 | 优点 | 缺点 |
|---|---|---|---|
| A. 直接读取 result 图 | VeneraX 把 result 目录当普通章节打开 | 最简单，零改动 | result 是静态图，无法再编辑；无法区分"已翻译"和"原文" |
| B. 读取 mask + json 动态渲染 | 类似当前 AI 翻译的 renderTranslatedPage，但数据源是 BT 工程文件 | 保留编辑能力；可切换原文/译文/双语 | 需要实现 BT json 解析器；渲染性能需优化 |
| C. 导出为 VeneraX 原生格式 | BT 导出时直接生成 VeneraX 可读的 cbz/图片文件夹 | 最干净，不耦合 | 丢失编辑能力；导出步骤繁琐 |

**推荐路线**：**B 为主，C 为辅**
- 日常阅读用 B：VeneraX 直接打开 BT 工程目录，读取 json + mask，动态渲染译文
- 分享分发用 C：从 VeneraX 内一键导出为 cbz/图片文件夹（已有导出功能，只需适配 BT 工程输入）

**关键设计点**：
- VeneraX 的 `LocalManager` 需要识别 BT 工程目录（检测 `mask/`、`*.json` 存在）
- 渲染优先级：`result/` 存在 → 直接显示（成品）；`result/` 不存在但 `mask/`+`json` 存在 → 动态渲染（半成品）
- 译文存储：复用现有 `image_translation.db`，但 key 要包含工程路径

### 2.4 漫画文件存储方式设计

**你的"两大类"分类非常合理**：

```
ComicLibrary/
├─ downloads/              ← 生肉（网络下载的原始漫画）
│  └─ <漫画名>/
│     ├─ cover.webp
│     ├─ details.json
│     └─ <0,1,2>/          ← 章节目录，纯图片
│        └─ 1.webp, 2.webp...
│
├─ translated/
│  ├─ projects/            ← 翻译中（BT 工程）
│  │  └─ <漫画名>/
│  │     ├─ mask/          ← 空白底图
│  │     ├─ <章节>.json    ← 气泡数据
│  │     └─ result/        ← 填字成品图（可选）
│  │
│  └─ exports/             ← 成品（可独立阅读/分享）
│     └─ <漫画名>/
│        ├─ images/        ← 图片文件夹
│        ├─ <漫画>.cbz
│        ├─ <漫画>.pdf
│        └─ <漫画>.epub
```

**VeneraX 阅读器中的区分逻辑**：

| 目录类型 | 检测特征 | 阅读模式 |
|---|---|---|
| 生肉 downloads | 有 `details.json`，子目录纯图片 | 标准阅读 + AI 辅助翻译 |
| 翻译中 projects | 有 `mask/` 或 `*.json` | BT 工程阅读模式（动态渲染） |
| 成品 exports | 有 `.cbz`/`.pdf` 或图片文件夹 | 标准阅读（已汉化） |

---

## 第三部分：BT 未完善功能分析

### 3.1 UI 优化与抹字三步骤

你总结的"扣字、识字、填字"是 BT 翻译的核心管线：

```
原始图片 → [OCR 检测] → 气泡区域
         → [抹字] → mask（空白底图）
         → [翻译] → 译文文本
         → [回填] → result（成品图）
```

**当前 BT 的实现**：
- 扣字：YOLO/OCR 检测模型（`modules/ocr`）
- 抹字：inpainting 模型（`modules/inpaint`）
- 填字：Pillow 排版引擎（`utils/text_rendering.py`）

**用 Flutter 优化的切入点**：
- **抹字预览**：在 VeneraX 阅读器中实时显示抹字效果，而不是等 BT 跑完 batch
- **交互式框选**：用户拖拽修正 OCR 检测框（类似长画布的 G/B 模式）
- **字体/排版可视化**：Flutter 的 dart:ui 可以实现实时字体渲染预览

**保存格式建议**（适配可变性）：
- `mask/<页号>.png`：空白底图（固定，不随框位置变）
- `bubbles/<页号>.json`：气泡列表（位置、原文、译文、字体样式），可随时编辑
- `source/<页号>.png`：原始图备份（用于重新抹字）

这样即使气泡位置后期调整，只需要重渲染对应页，不需要重新 OCR 和抹字。

### 3.2 画质增强

**问题诊断**：OCR 漏检确实常和分辨率有关。漫画网站提供的 webp 往往经过压缩（宽度 800-1200px），而印刷级原图可达 2000px+。

**技术路线**：

| 方案 | 工具/模型 | 效果 | 成本 |
|---|---|---|---|
| 超分辨率重建 | Real-ESRGAN（动漫专用模型） | 2x-4x 放大，锐化线条 | 需 ONNX/GPU，单次处理较慢 |
| 去压缩 artifact | 轻量 CNN（waifu2x 风格） | 消除 webp 块效应 | 较快，可在阅读时实时处理 |
| 简单放大 | Flutter Image 的 filterQuality | 只有插值，无真正增强 | 零成本，效果有限 |

**建议**：在下载阶段就做预处理（下载后自动超分存到 `downloads/`），而不是阅读时实时处理。这样一次性投入，后续阅读零延迟。

### 3.3 AI 修复（去气泡/封面净化）

**去气泡（inpainting）**：
- BT 已有 inpainting 模型（lama/manga-inpaint），但**面向的是文本区域**，不是任意遮挡
- 想要"顺着线条补全"需要**结构感知 inpainting**（如 MAT/edge-connect），这超出了当前 BT 的能力范围
- **可行路径**：先用 BT 的抹字去掉气泡文字 → 再用 lama 填充背景色块 → 对简单色块场景效果尚可；对复杂背景（人物被遮挡）效果差

**封面净化（去标题/Logo）**：
- 漫画封面标题通常在固定位置（顶部/中央），可用**固定区域 mask + inpainting** 实现
- 比对话气泡更简单，因为不需要 OCR 检测，直接预设遮罩区域
- **实现建议**：在 VeneraX 中增加"封面编辑"模式，用户框选标题区域 → 调用 BT 的 inpainting API → 保存净化版封面

**现实评估**：
- 简单背景（纯色、渐变）的去气泡：✅ 当前技术可达
- 复杂背景（人物肢体、精细纹理）的去气泡：❌ 需要专业图像编辑软件（Photoshop），AI 暂无法 reliably 补全
- 封面净化：✅ 可行，限固定区域

---

## 第四部分：命名建议

**当前状态**：两个独立品牌（VeneraX / BallonsTranslator），合并后需要统一身份。

**命名方向对比**：

| 候选名 | 含义 | 优点 | 缺点 |
|---|---|---|---|
| **VeneraX**（保留） | 延续现有品牌 | 已有用户认知；GitHub 仓库/Star 继承 | BT 用户可能找不到 |
| **BallonsTranslator**（保留） | 延续 BT 品牌 | 翻译社区知名度高 | 与"漫画阅读器"定位不符 |
| **ComicTranslator** | 直白描述 | 一看就懂 | 太普通，无品牌感 |
| **MangaCraft** |  manga + craft（工艺） | 强调"精工制作"；国际友好 | 与现有品牌无继承关系 |
| **Venera Studio** | Venera + 工作室 | 保留 Venera 基因；暗示"创作+阅读"一体化 | 需要重新建立认知 |
| **双语/汉化相关** | 如 Hanhua, Bilingual | 中文市场直观 | 国际市场难推广 |

**建议**：**保留 "Venera" 作为主品牌**，因为：
1. 它是阅读器框架，用户打开首先看到的是它
2. Flutter 工程、GitHub 仓库、应用商店 identity 都以它为中心
3. BT 的能力作为"Venera Translation Engine"或"Venera Studio Mode"子品牌存在

**具体命名**：
- 软件名称：**Venera**（或 **Venera Studio** 如果强调创作属性）
- 翻译功能模块："Venera Translation" / "汉化工作室"
- 漫画源模块："Venera Sources"
- BT 的 Python 后端：作为内部模块名 "venera-translate-core"，不对外暴露

**改名时机**：
- 建议等到"Venera 内能打开 BT 工程文件并阅读"这一里程碑完成后，再统一更名
- 在此之前，两个仓库各自独立维护，避免中途改名导致 Git 历史混乱

---

## 附录：阶段实施优先级建议

| 阶段 | 目标 | 预估复杂度 | 依赖 |
|---|---|---|---|
| **P0** | 目录治理（1.2）、CMake 安装前缀改到项目内（1.4） | 低 | 无 |
| **P1** | VeneraX 读取 BT 工程文件（mask+json）动态渲染 | 中 | 需设计 json 解析适配层 |
| **P2** | AI 翻译框选精度优化（手动补框、相邻合并、边缘过滤） | 中 | 需调 ONNX 参数 + UI 交互 |
| **P3** | 参考 comix.to 优化阅读器 UI（悬浮工具栏、抽屉章节列表） | 中 | 纯 Flutter UI 改动 |
| **P4** | BT 核心能力 Python 模块封装为 Venera 可调用的服务 | 高 | 需设计 Dart↔Python 通信机制 |
| **P5** | 画质增强（下载时超分预处理） | 中 | 需集成 Real-ESRGAN ONNX |
| **P6** | 封面净化/AI 修复 | 低-中 | 复用现有 inpainting，加固定 mask |
| **P7** | 统一品牌更名 | 低 | 等 P1 完成后 |

> **下一步行动建议**：先执行 P0（目录治理 + 安装前缀修正），这是所有后续开发的基础；然后选择 P2 或 P3 作为第一个可见功能改进（用户能直接感知）。

---

## 第五部分：第二次融合 — comix.to 下载能力整合（2026-09-28 新增）

### 5.1 背景与动机

P1 阶段完成了 VeneraX 直读 BT 翻译工程（阅读侧）。在验收过程中发现，下载侧存在两个待整合的能力缺口：

1. **封面收录缺失**：VeneraX 从中文漫画源下载时已包含封面（`cover.jpg`），但从 comix.to 下载的漫画（经 BT 下载流程）没有封面文件，导致 BT 工程封面只能用第一张正文页图充当
2. **下载渠道分散**：VeneraX 的漫画源以中文网站为主（拷贝漫画、包子漫画等），仅 comick.js 覆盖外网（comick.art）；而 BT 从开发初期就针对 comix.to 构建了成熟的下载管线，经过多轮测试优化（超时重试、坏图校验、页面错乱修复）

**核心判断**：BT 的 comix.to 下载能力不应浪费，应当融入 VeneraX，作为 VeneraX 漫画源体系的补充。

### 5.2 两套系统的技术对比

| 维度 | VeneraX 漫画源系统 | BT comix.to 下载管线 |
|------|-------------------|---------------------|
| **源配置格式** | JavaScript 文件（`comick.js` 等），放在 `App.dataPath/comic_source/` | Python 模块（`comix_client.py`），硬编码在 BT 源码内 |
| **源注册机制** | `ComicSource` 基类 + `parser.dart` 动态解析 JS，`ComicSourceManager` 统一管理 | 无注册机制，直接在 `download_dialog.py` 中调用 |
| **反爬策略** | 依赖源 JS 中的 request 函数，一般用 Dio HTTP | 三级分工：GET 元数据 + WebEngine（Chromium）破解签名加密 + CDN 直取图片 |
| **章节数据模型** | `ComicChapters`（`Map<String, String>` 或 grouped），章节标题含汉化组信息但未结构化 | `ChapterInfo`（`title`, `number`, `group`, `url`），汉化组单独字段 |
| **下载目录命名** | `getChapterDirectoryName(章节标题)` — 只做非法字符替换 | `chapter_dir_name(ch, title, ts)` — `章节名 [汉化组] - 漫画名 - 时间戳` |
| **封面下载** | 下载开始时从 `comic.cover` 下载，保存为 `cover<ext>` | 无封面下载逻辑 |
| **图片校验** | 无坏图检测 | `validate_image_bytes()` — PIL 解码校验 + 尺寸检查 |
| **坏图修复** | 无 | `_source_urls.json` 源 URL 清单 + 单页重下 |
| **线程模型** | Dart Isolate / async | QThread 工作线程 + Qt 主线程 WebEngine 桥接 |

### 5.3 BT comix.to 下载管线架构

文件：`Ballonstranslator_win_minium/ballontranslator/utils/scraper/comix_client.py`

**三级数据获取策略**：

```
┌────────────────────────────────────────────────────────────────┐
│ 第一级：漫画元数据（标题/hid）                                   │
│ 方式：GET 详情页 HTML → 正则提取 <script id="initial-data"> JSON │
│ 函数：fetch_comic_meta() → parse_initial_data() → parse_comic_from_initial_data() │
│ 特点：无需浏览器，普通 HTTP 即可                                  │
├────────────────────────────────────────────────────────────────┤
│ 第二级：章节列表 & 每页图片 URL                                   │
│ 方式：WebEngineBrowser（隐藏 Chromium）渲染页面 → 站点 JS 完成签名/解密 → DOM/JSON.parse 钩子截获 │
│ 函数：fetch_chapter_list() / fetch_page_urls()                  │
│ 特点：站点对 API 请求加了混淆 token 签名 + 响应加密，普通 HTTP 无法还原 │
├────────────────────────────────────────────────────────────────┤
│ 第三级：图片字节下载                                              │
│ 方式：requests GET CDN URL（`*.wowpic*.store`），仅校验 Referer 头  │
│ 函数：download_image()                                           │
│ 特点：CDN URL 无扩展名，按文件头魔数推断 jpg/png/webp/gif           │
└────────────────────────────────────────────────────────────────┘
```

**数据模型**（`scraper/models.py`）：

```python
@dataclass
class ChapterInfo:
    title: str          # 显示标题，如 "Ch. 12 - Luna Toons"
    url: str             # 章节页面绝对 URL
    number: str          # 数字章节号，如 "12"
    group: str           # 汉化组名，如 "Luna Toons"（空字符串表示未知）

    @property
    def safe_dirname(self) -> str:
        return sanitize_name(self.title or self.number, 'chapter')
```

**目录命名**（`download_dialog.py:56-63`）：

```python
def chapter_dir_name(ch: ChapterInfo, comic_title: str, ts: str) -> str:
    """章节名 [汉化组] - 漫画名 - 时间戳"""
    parts = [ch.title or ch.number or 'chapter']
    if ch.group:
        parts.append(f'[{ch.group}]')
    parts.append(comic_title or 'comic')
    parts.append(ts)
    return sanitize_name(' - '.join(parts), 'chapter')
```

**图片校验**（`comix_client.py:177-200`）：

```python
def validate_image_bytes(data: bytes) -> Tuple[bool, Optional[Tuple[int, int]]]:
    """PIL 解码校验 + 尺寸检查（≥16px），拦截截断图/错误页/垃圾字节"""
```

### 5.4 两个融合任务

#### 任务一：创建 comix.to 漫画源配置文件

**目标**：在 VeneraX 的 comic_source 体系中新增一个 comix.to 源（JavaScript），使其与现有 `comick.js`（comick.art）并列。

**现状对比**：

| | comick.js（已有） | comix.to（待创建） |
|---|---|---|
| 域名 | comick.art | comix.to |
| API | 公开 GraphQL API，无需浏览器 | 有签名加密，需要 WebEngine 桥接 |
| 章节标题 | API 返回结构化数据 | DOM 采集，需要解析 |
| 汉化组 | 无独立字段 | `ChapterInfo.group`，需映射到 VeneraX |
| 下载 | 标准 VeneraX 下载流程 | 需复用 BT 的三级策略 |

**难点**：comix.to 的 API 有 token 签名 + 响应加密，VeneraX 的标准 JS 源（基于 Dio HTTP）无法直接破解。需要以下方案之一：

| 方案 | 说明 | 可行性 |
|------|------|--------|
| **A. Dart WebView 桥接** | VeneraX 用 `flutter_inappwebview` 渲染 comix.to 页面，注入 JS 截获解密后的数据 | 高 — VeneraX 已有 inappwebview 依赖 |
| **B. 调用 BT Python 管线** | VeneraX 通过进程通信调用 BT 的 `comix_client.py` | 中 — 需 Python 运行环境，但 BT 已打包 |
| **C. 逆向 comix.to 的签名算法** | 在 JS 源中直接实现签名/解密 | 低 — 算法可能随站点更新变化，维护成本高 |

**推荐方案**：**A + B 混合**
- 搜索/浏览/元数据用 A（Dart WebView 桥接，纯 VeneraX 侧）
- 下载图片用 B（调用 BT 的 `download_image()` + `validate_image_bytes()`，复用已验证的下载+校验逻辑）
- 或全用 B（如果 WebView 桥接复杂度过高）

#### 任务二：在 VeneraX 中融合 BT 的网络下载功能

**目标**：用户在 VeneraX 中可以直接搜索 comix.to 的漫画、浏览章节列表、选择章节下载，下载完成后自动创建 BT 工程结构。

**融合后的用户流程**：

```
用户在 VeneraX 搜索 "Error the Echo"
  → VeneraX 通过 comix.to 源搜索（方案 A/B）
  → 显示搜索结果（含封面、简介）
  → 用户点击漫画 → 显示详情页
  → 章节列表显示：第5话 [Luna Toons] / 第5话 [MistScene] ...
  → 用户选择章节并下载
  → 下载完成后：
    - 图片保存到 ComicLibrary/downloads/<漫画名>/<章节号>/
    - 封面保存到 ComicLibrary/downloads/<漫画名>/cover.jpg
    - 可选：自动打开 BT 进行翻译
```

**融合后的下载流程**（结合 P2 封面与章节拆分需求）：

```
下载开始
  ├─ 1. 获取漫画元数据（标题、封面 URL、章节列表）
  │   └─ 封面 URL 保存备用
  ├─ 2. 下载封面 → 保存为 <根目录>/cover.jpg          ← 新增（解决需求一）
  ├─ 3. 逐章下载图片
  │   ├─ 目录名 = 纯章节号（如 "5"）                   ← 改进（解决需求三）
  │   ├─ 汉化组信息存入 LocalComic metadata             ← 新增
  │   ├─ 图片校验（复用 BT 的 validate_image_bytes）    ← 融合
  │   └─ 写入 _source_urls.json                         ← 融合
  └─ 4. 下载完成
      ├─ 自动扫描 BT 工程                               ← 已有（BtProjectManager.scan）
      └─ 用户可直接阅读或打开 BT 翻译
```

### 5.5 涉及的关键代码位置

#### VeneraX 侧

| 文件 | 说明 |
|------|------|
| `lib/foundation/comic_source/comic_source.dart` | `ComicSourceManager` 源注册与管理 |
| `lib/foundation/comic_source/parser.dart:82-216` | JS 源解析器，`ComicSource` 基类校验 |
| `lib/foundation/comic_source/types.dart:1-15` | source 必须实现的核心接口 |
| `lib/foundation/comic_source/source_library.dart` | 远程 source catalog 配置 |
| `lib/network/download.dart:264-275` | 下载流程接入 source 的 `loadComicPages` |
| `lib/network/download.dart:355-362` | 章节目录命名（待改进） |
| `lib/network/download.dart:485-512` | 封面下载（已有，需适配 comix.to） |
| `lib/foundation/local.dart:1334-1353` | `getChapterDirectoryName` 目录名清理 |

#### BT 侧（可复用）

| 文件 | 说明 |
|------|------|
| `ballontranslator/utils/scraper/comix_client.py` | comix.to HTTP 客户端 + 三级策略 |
| `ballontranslator/utils/scraper/models.py` | `ComicInfo` / `ChapterInfo` 数据模型（含 `group` 字段） |
| `ballontranslator/utils/scraper/__init__.py` | scraper 模块入口 |
| `ballontranslator/ui/download_dialog.py` | Qt 下载对话框（`chapter_dir_name` 命名逻辑） |
| `ballontranslator/ui/webengine_browser.py` | Chromium WebEngine 桥接（签名/加密破解） |
| `tests/test_comix_scraper.py` | scraper 单元测试 |

#### 已有 comick.js 参考

| 文件 | 说明 |
|------|------|
| `venera-configs-main/comick.js` | comick.art 源配置，可作为 comix.to 源的模板 |

### 5.6 难点与风险

1. **comix.to 的反爬机制**：API 有 token 签名 + 响应加密，无法用简单 HTTP 还原。BT 用 WebEngine（Chromium）破解，VeneraX 需要用 `flutter_inappwebview` 复刻或调用 BT 的 Python 管线
2. **Dart↔Python 通信**：若方案 B（调用 BT Python），需要设计进程间通信。P4 阶段规划的"BT 核心能力 Python 模块封装为 Venera 可调用的服务"正是此需求的前置
3. **`flutter_inappwebview` 的 JS 注入能力**：方案 A 依赖 WebView 的 JS 注入和 DOM 截获。需验证 `flutter_inappwebview` 在 Windows 上的 `evaluateJavascript` / `JavaScriptChannel` 是否足够稳定
4. **下载目录命名统一**：BT 的 `chapter_dir_name` 生成 `章节名 [汉化组] - 漫画名 - 时间戳`，VeneraX 的 `getChapterDirectoryName` 只做字符清理。融合后需要统一为 P2 规划的精简命名（纯章节号 + 汉化组 metadata）
5. **封面下载时机**：BT 的下载流程没有封面下载步骤。融合时需在 VeneraX 侧补上（已有 `cover.jpg` 下载逻辑，只需确保 comix.to 源的 `comic.cover` 字段正确）
6. **图片校验复用**：BT 的 `validate_image_bytes` 用 PIL 解码校验。VeneraX 侧可用 Dart 的 `image` 包或 `flutter` 解码器替代，或直接调用 BT 的 Python 校验

### 5.7 与 P2 需求的关联

本次分析的两个融合任务与 [P2-封面与章节显示需求分析](file:///D:/Ballonstranslator_Windows/docs/P2-封面与章节显示需求分析-20260928.md) 密切关联：

| P2 需求 | 融合任务的支撑 |
|---------|--------------|
| **封面收录** | 任务一创建 comix.to 源时，`comic.cover` 字段携带封面 URL，下载时自动收录 |
| **章节名拆分** | BT 的 `ChapterInfo` 已有 `number` 和 `group` 独立字段，融合后直接映射到 VeneraX 的章节显示 |
| **多汉化组** | BT 的 `build_chapters_from_dom` 已支持同章节多汉化组采集，融合后可映射到 VeneraX 的 `ComicChapters` |
| **下载目录名精简** | 融合后统一用 `ChapterInfo.number` 作为目录名，汉化组存入 metadata |

### 5.8 建议的阶段规划更新

在原 P0-P7 规划基础上，新增以下阶段：

| 阶段 | 目标 | 预估复杂度 | 依赖 |
|---|---|---|---|
| **P8** | 创建 comix.to 漫画源配置文件（搜索 + 浏览 + 元数据） | 高 | 需解决反爬（WebView 桥接或 Python 调用） |
| **P9** | 融合 BT 的 comix.to 下载功能到 VeneraX（图片下载 + 校验 + 封面收录） | 高 | P8 + 可选依赖 P4（Dart↔Python 通信） |
| **P10** | 统一下载目录命名 + 章节名拆分显示 + 封面收录（P2 需求落地） | 中 | P8/P9 提供结构化章节数据 |

> **建议实施顺序**：P8 → P9 → P10。P8 和 P9 是融合的"下载侧"，P10 是"显示侧"，显示侧依赖下载侧提供的结构化数据（`ChapterInfo.number` / `ChapterInfo.group`）。
>
> 若 P4（Dart↔Python 通信）优先完成，则 P8/P9 可简化为"调用 BT Python 管线"，无需在 Dart/JS 侧重写反爬逻辑。
