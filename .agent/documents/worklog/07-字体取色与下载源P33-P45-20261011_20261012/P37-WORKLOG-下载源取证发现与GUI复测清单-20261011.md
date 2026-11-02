# P37 · ⑧ 下载源取证发现（拷贝漫画 / comix.to）与 GUI 复测清单 · 2026-10-11

> 阶段：⑧「下载源针对性加强」第一步 = **取证**（只采集证据，不改任何生产代码）。
> 取证 runner：`tools/forensics_download_sources.py`（子命令 `sig` / `copy` / `comix` / `all`）。
> 本会话**没有渲染表面、也没有稳定联网** ⇒ 真实网络取证必须在**用户联网 GUI 会话**里跑；
> 本文件沉淀「离线已证事实 + GUI 复测清单 + 已知未知数」，作为 ⑧ 进入「适配 → 回归」的依据。

---

## 0. 分工与红线

- **取证（本文件 + `forensics_download_sources.py`）**：回答「引导域是否还活着 / 自愈接口还返不返数据 / 签名算法是否完好 / WAF 锚点是否可达」—— 这些是 ⑧ 当前最大未知数。
- **适配（改生产代码）**：等取证结论出来再做，属于下一阶段。
- **回归（headless）**：`edit-check` / `download-check` / `comix-spike`。
- 🔴 **A09 红线**：若 Cloudflare 无法在无人值守下通过（WebView 也过不了），**停下来给用户选项**，不要硬闯。

---

## 1. 拷贝漫画（copy_manga）取证发现（离线已证）

源文件：`venera-configs-main/copy_manga(6).js`（**v1.8.0**）。
下列数据由 `forensics_download_sources.py sig` 从 JS **动态解析**（反 `mangrove-/venera-` 路径漂移，单一事实源），2026-10-11 离线实测：

| 项 | 值 |
|---|---|
| `version` | `1.8.0` |
| `defaultApiUrl` | `api.copy2000.online` |
| **API 引导域（5）** | `api.copy-manga.com` · `api.copy2000.online` · `api.copy4000.com` · `api.copy5000.com` · `api.copy202601.com` |
| **网页引导域（3）** | `www.copy5000.com` · `www.copy4000.com` · `www.copy20.com` |
| 签名密钥 | `secret` base64 串长 **44** ⇒ 解码 **32 字节 = SHA256 密钥** |
| 签名头部 | **15 个键**（含 `x-auth-timestamp` + `x-auth-signature`），顺序固定 |

**已离线验证：**
1. **本地签名算法校验 = PASS**（无需网络）：用 Python 标准库同构重算 `HMAC-SHA256(secret_bytes, ts)`，并校验 15 键头部形状（键集合完整、顺序符合 JS `get headers`）。证明签名**构造逻辑**完好、服务端若仍接受同款签名即可用。
2. **配置解析器自洽**：正则从 JS 抽出的引导域 / 版本 / 密钥长度与脚本内部一致，无路径漂移。

**待联网确认（最大未知数）：**
- 5 个 API + 3 个网页引导域**当前是否还活着**（逐个探活）。
- `/api/v3/system/network2` 域名自动发现接口是否还返数据（站方自愈机制）。
- 「服务端是否仍接受这套签名头」的**权威验证**由 `tools/test_copy_v180.py`（QuickJS 真实对站）完成 —— 二者互补，不重复。

---

## 2. comix.to 取证发现（离线已证 + 已知）

- **取字节策略诊断基线已就绪**：`mangrove.exe --headless comix-spike`（`comix_client.dart` 走 WebView 过 WAF）。
- **WAF 检测关键字已与 App 端对齐**：`forensics_download_sources.py::WAF_KEYWORDS` 现与 `cloudflare.dart::_isCloudflareChallengePage`（行 359–385）同源，涵盖
  `challenge-platform` / `/cdn-cgi/challenge-platform/` / `window._cf_chl_opt` / `__cf_chl_opt` / `cf_chl_` /
  `cf-browser-verification` / `cf-challenge` / `cf-turnstile` / `verify you are human` /
  `checking your browser before accessing` / `just a moment` / `__gatekeeper_challenge` / `正在验证浏览器` 等。
- **稳定锚点**（取证脚本探活）：`comix.to` / `static.comix.to`（DNS / TLS / 非浏览器 GET / WAF 关键字）。
- 🔴 **关键已知**：baozimh 系 **gatekeeper 挑战页自身 JS 就引用 `__gatekeeper_challenge`**，标记**永不消失**；
  App 端已改用「**票据 cookie 到手**」（`cf_clearance` / `gk_browser`）判定通过，而非看标记消失。
  ⇒ 本取证脚本只证「锚点是否还挂着挑战页」的**可达性**，不替代通过判定。
- 🔴 **轮换域陷阱**：图片 CDN 轮换域 `*.site` 的 URL 是**单次签名、会过期**。用日志里捞的旧 URL 测必然 404。
  `comix-spike` 已支持 `--comic <id>` **现场取新鲜 URL**，必须用这条路径测，不能手填旧 URL。

---

## 3. GUI 复测清单（用户联网 GUI 会话执行）

> 前置：GUI 会话已开 Clash 代理 `127.0.0.1:7890`（A09）；`requests` 已装在跑 `copy`/`comix` 取证的 python 里。
> 报告统一落 `tools/forensics_out/<sub>_<date>.json`，绝不假绿（无网/无模块自动 SKIP）。

### 3.1 拷贝漫画（引导域存活 + 自愈 + 真实签名）
```bat
REM ① 引导域探活 + network2 自动发现（需 requests + 代理）
python tools/forensics_download_sources.py copy

REM ② 服务端是否仍接受签名头（QuickJS 真实对站，权威）
python tools/test_copy_v180.py
```
判读：`copy` 报告里 `alive` 列表非空 = 引导域存活；`discovery` 段 `status`/`jsonKeys` 看 network2 是否返数据；`test_copy_v180` 全绿 = 签名仍被接受。

### 3.2 comix.to（轮换域 403 哪条策略能过）
```bat
REM ① 取字节策略诊断：必须用 --comic 现场取新鲜 URL（轮换域单次签名会过期）
mangrove.exe --headless comix-spike --comic <comicId> --source comix_to ^
             --sample 2 --timeout 40 ^
             --json tools/forensics_out/comix_spike.json

REM ② 走真实下载链路跑一章（多轮渐进超时 5→10→15→30s）
REM    ⚠ --group 必须指定用 *.site 轮换域的翻译组（如 DivaScans）；
REM      省略会取第一个版本（通常 Asura，正常，测不出轮换域封锁）
mangrove.exe --headless download-check <comicId> --source comix_to ^
             --group <DivaScans或其他用*.site的组> --clean ^
             --json tools/forensics_out/download_check.json
```
判读：`comix_spike.json` 里 `byStrategy` / `winners` 看**哪条策略拿到字节**（重点 `canvas-read` / `warmup-dynamic-img`）；`download_check.json` 看成功/缺页数、是否疑似主机封锁。
⇒ 任一策略/章节能拿到字节 = 轮换域封锁**可绕**，进入适配阶段。

---

## 4. 已知未知数与下一步（⑧ 推进顺序）

| 源 | 现状 | 若取证结论为「不通」的应对 |
|---|---|---|
| **包子漫画** | ✅ P35 适配完成（删失效镜像/图床，主路径走网页镜像 + 旧式章节 URL，实测 200 且无 CF 交互挑战） | 待用户同步 `baozi.js` 到 `%APPDATA%\io.github.maelshiyan02\mangrove\comic_source\` 并 GUI 验证 |
| **拷贝漫画** | 🟠 取证中：签名算法离线 PASS、引导域存活待联网 | 若引导域全死 → 适配需换引导域或上 WebView，给用户选项（A09） |
| **comix.to** | 🟠 待回归：WebView 过 WAF 基线已就绪 | 若 `comix-spike` 全策略 0 字节 → 停下来给用户选项（A09 红线） |

**推进顺序（用户已拍板）**：⑦a 字体 ✅ → ⑦b 取色 ✅ → ⑧ 下载源（取证 → 适配 → 回归）。
当前在 ⑧ 的**取证**子阶段；取证结论齐了再动生产代码（适配），最后 `edit-check` / `download-check` 回归。

---

## 5b. 纯 GUI 操作实录（用户无需敲任何命令）

> ⚠️ 上面 §3 的 `python …` / `mangrove.exe --headless …` 是**开发者无头测试命令**，要在我的沙盒里跑，**你的普通 GUI 会话用不上、也不必用**。
> 对「验证拷贝漫画 / comix.to 能不能搜、能不能下」，**直接用 Mangrove 软件本身的正常操作就是测试**。下面按界面按钮一步步走。

### 前置：确认这两个源已启用
- 打开 Mangrove → 底部导航「**漫画源**」（或侧栏 Comic Source）。
- 在列表里看有没有 **拷贝漫画**（copy_manga）和 **comix.to**。
  - **comix.to** 是内置源，应该直接在列表里。
  - **拷贝漫画** 若是自定义 JS 源、列表里没有：在「漫画源」页点「**Add comic source** / 添加漫画源」→ 选「**Use a config file**」导入你的 `copy_manga(6).js`，或粘贴源地址。装好后它会**自动加入搜索源**（无需手动开开关）。
- 之后去「**搜索**」页，点搜索框下方的「**Search in**」一行里的源 chip，确认 拷贝漫画 / comix.to 出现在可选列表；或直接勾「**Aggregated Search**」一次把全部源都搜一遍。

### 八步实测（对应上面的流程图）
1. **打开 Mangrove**（桌面双击图标，等主界面出来）。
2. 底部导航点「**搜索**」（放大镜图标）。
3. 顶部搜索框输入一个你确定的漫画名（例：`One Piece` 或 `海贼王`）；下方「**Search in**」选 **拷贝漫画** 或 **comix.to**（想一次测俩就勾 **Aggregated Search**）。
4. 按 **回车** → 进搜索结果页。
5. **看结果判通过/失败**：
   - 出现封面缩略图 + 标题 = **通过**（源在线、能搜）。
   - 整块显示红字报错 / “No search results” / “Network error” = **失败**，把红字记下来。
6. 点进任意一本漫画 → 进**漫画详情页 → 章节列表**。
7. 点页面上的「**下载**」按钮 → 弹窗**选章节** → 确认 → 提示 **“Download started”**。
8. 去「**任务**」（下载管理）页看进度条到 100%、显示完成；然后点进已下载章节，**看漫画图片是否一张张加载出来**。

### comix.to 专属：遇到 Cloudflare 验证页
- 搜 comix.to 或下它的图时，软件可能**自动弹出一个内置浏览器窗口**（Cloudflare 验证）。
- 多数情况 **30–60 秒内自动过**；若窗口里出现「**verify you are human**」勾选框，**手动用鼠标勾一下**即可继续。
- 验证通过后，搜索和图片下载就能正常进行。若一直卡在验证页不动（几分钟都过不去），那就是 §4 里说的「WebView 也过不了」红线情形，停下来告诉我，不要硬等。

### 你要回报给我什么
做完上面八步，把**现象**用大白话告诉我即可，例如：
- “拷贝漫画搜 `One Piece` 出了 20 个结果，下载第 3 话图片都能看” → 通过。
- “comix.to 一搜就弹验证页，勾了还是卡住” → 卡 CF。
- “拷贝漫画直接报 Network error” → 引导域可能挂了。
我不要求你跑任何命令、也不要求你读日志；你只描述**界面上看到了什么**就够我判断下一步。

---

## 5. 门禁与状态

- 取证脚本：`sig` = **PASS（离线）**；`copy` / `comix` 在 GUI 联网后诚实 **PASS / SKIP / FAIL**（空结果判 FAIL，绝不假绿）。
- 报告落盘：`tools/forensics_out/<sub>_<date>.json` + 人类可读摘要。
- 配套脚本（已修路径漂移）：`tools/test_copy_v180.py`、`tools/test_comick_fix.py`。
- 🔴 本文件**不替代** GUI 实测：联网探活 / 真实签名接受度 / 轮换域 403 绕过，只能在用户 GUI 会话验证。
