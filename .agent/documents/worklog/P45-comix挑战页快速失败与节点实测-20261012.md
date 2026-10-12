# P45 · comix 挑战页快速失败（治「卡死获取图片列表」）+ 节点 WAF 实测 + 代理/网卡排查

> 时间：2026-10-12（中午，GMT+8）
> 承接：`P44`（fiber 字段漂移 `bZ`→`B0`，用户 GUI 实测**页码已正确（Ch.1 : 1/90）但图片大量转圈 30~60s**、
> 下载漫画「长时间卡死在获取图片列表」）。
> 用户诉求：判定连接 vs 加载；检查优化下载；给 VPN 代理优化建议；查本机网卡是否影响代理网速。
> 包子 / 拷贝本轮**未动**；**未 git commit**。

---

## 0. 结论速览

| 问题 | 判定 | 证据 |
|---|---|---|
| 页码对、图片不显示/极慢；下载卡死在「获取图片列表」 | **主因 = 出口节点又被 WAF 封**（非代码 bug）：用户当时节点 🇫🇷法国Y01，标题页 200 但被**重定向到 comix 自家挑战页** `/@waf/challenge`（9,394 B "Security check" 滑块页）。worker 落挑战页后旧代码**无任何挑战检测**，fiber 轮询 20s + `<img>` 探针 25s，P38 的空结果重启再翻倍 ⇒ 30~90s 干等 | curl 经代理：法国 9,394 B 落 `@waf/challenge`；logs.txt 10:22 `status=200 len=9386` + `no initial-data in page`×N；`fetchImageUrls ... navigate` 后日志断流 |
| 放大问题的**代码缺陷 ×3**（本轮修） | ① 阅读/章节/搜索 6 条 worker 导航路径**只轮询不识别挑战页**；② `looksLikeChallengePage` 只认**裸 `challenge-platform`**——但 CF jsd 探针**全站注入**（真页也有 ⇒ 该判据既漏 comix 自定义页、又会误判好页）；③ JS 源运行时副本停留在 **10/6 v0.6.x 旧版**（P41 双语提示从未同步进 appdata），且 JS 侧封禁正则不认新挑战页 | 真 SSR 页（27,513 B）实测含 `challenge-platform`（offset 26834）；appdata `comix_to.js` 19,359 B 无 `COMIX_IP_BLOCKED` |
| 网卡是否拖累代理 | **无瓶颈证据**：好节点（香港Y05）经代理下载 195 KB bundle **~530~640 KB/s**、TTFB 0.15s；8 并发同测各 ~0.37s（无并发惩罚）。本机走 WLAN（MTU 1500 正常、TCP autotuning=normal、ECN off、非 TUN）；Wi-Fi 链路速率因系统位置权限关闭读不到，需用户在任务管理器自查 | curl 实测；`netsh interface ipv4 show subinterfaces` |
| 好节点还慢吗 | 不慢：香港 IEPL 节点 TTFB 0.15~0.17s、单图 50~68KB 封面 ~1.5s（日志 ImageLane），3 通道并行下整章可在数十秒级完成；**慢/卡死全部出在被封节点上** | 同上 |

---

## 1. 节点 WAF 实测（2026-10-12 ~11:00-12:00，Clash API `127.0.0.1:8445` 逐一切换 + curl 标题页）

> 方法：PUT `http://127.0.0.1:8445/proxies/🔰 选择节点`（**body 必须 UTF-8 字节**，PS5 默认 Latin-1 会切节点失败），
> 每节点 `curl -x 127.0.0.1:7890 -sL <标题页> --max-time 15`，落 `@waf/challenge` 或 <20KB 判 BLOCKED。

| 节点 | 结果 | 耗时 |
|---|---|---|
| 🇭🇰 香港Y05/Y02/Y09/Y11 IEPL | **OK（28,014 B 真页）** | **0.54~0.60s（最快梯队）** |
| 🇭🇰 香港Y03 IEPL | OK | 0.66s |
| 🇯🇵 日本Y01/Y03 IEPL | OK | 0.69~0.73s |
| 🇸🇬 新加坡Y02 | OK | 0.83s |
| 🇩🇪德国 / 🇬🇧英国 / 🇨🇦加拿大 | OK | 1.20~1.32s |
| 🇨🇳 台湾Y01 / 🇺🇲美国Y01 / 🇸🇬新加坡Y01 | OK 但慢 | 3.49 / 4.03 / 6.60s |
| 🔴 🇫🇷法国Y01（用户当时节点） | **BLOCKED**（9,394 挑战页） | 1.58s |
| 🔴 🇭🇰 香港Y01（早上还是好的！） | **BLOCKED** | 0.67s |
| 🔴 🇦🇺澳大利亚Y01 | BLOCKED | 2.35s |
| 🔴 🇯🇵 日本Y05/Y06「下载专用 x0.01」 | 403 / 000 | — |
| 🔴 🇺🇲美国Y02 / 🇮🇳印度 / 🇰🇷韩国 | 前两轮已证封/连不上 | — |

**关键结论**：
1. WAF 名单**按 IP 打地鼠、随时间漂移**（香港Y01 早上 200、中午被封），固定节点不可靠；
2. **延迟与被封无关**——法国 1.0s 很快但被封；快且通的是**香港 IEPL 梯队**；
3. 标「下载专用 x0.01」的日本节点对 comix **403**，不要用来下 comix；
4. Clash 内置延迟测试 URL 返回 200 就算活——**挑战页也是 200**，所以 URL-test / fallback **无法自动识别被封**，只能测延迟。

已把 `🔰 选择节点` 切到 **🇭🇰 香港Y05（实测最快且通）**。

---

## 2. comix 自家挑战页指纹（与 CF 标准页不同）

`curl` 落盘 9,394 B：`<title>Security check</title>`、`noindex,nofollow`、
正文为**滑块验证**（`captchaId`/`dragLayer`/`loadChallenge`），
URL 重定向 `/@waf/challenge?return=<原路径>`，尾部仍带 CF jsd 探针
`/cdn-cgi/challenge-platform/scripts/jsd/main.js`。

🔴 **假阴性/假阳性双重教训**：
- 旧 `looksLikeChallengePage` 不含 `@waf/challenge`/`security check` ⇒ **漏判**（新挑战页放行）；
- 它含**裸 `challenge-platform`** ⇒ 会**误判**：CF jsd 探针在**正常 SSR 页**也注入
  （真页 offset 26834 实测命中）。本轮收紧为 `challenge-platform/h/`（仅托管挑战路径）。

---

## 3. 修复

### 3.1 `Mangrove/lib/network/comix_client.dart`

1. **`looksLikeChallengePage` 修正**：删裸 `challenge-platform` → 改 `challenge-platform/h/`；
   新增 `@waf/challenge`、`<title>security check`。
2. **`_navigate` 咽喉守卫 `_throwIfOnChallenge`**（6 条采集路径全部经过 `_navigate`：
   章节 API/DOM、图片 API/DOM、browse ×2）：导航后采两个样本（~700ms / 1600ms），
   读 `location.href` + `outerHTML`：命中挑战 → 立刻抛 `COMIX_IP_BLOCKED`；
   正文 >20KB（真页）提前返回；其余交回既有轮询。
3. **block 标记一路透传、禁止重试**：`_isIpBlocked(e)` 判据，
   `fetchImageUrls`/`fetchChapters` 的 API/DOM 两个 catch 与 `_route`（搜索/发现/分类）
   命中即 rethrow；公开方法的「空结果重建 worker 重试」对 block **短路**
   （旧路径最坏 ~90s（90s API + 120s DOM 预算）→ **现在 ~1s 出双语提示**）。

### 3.2 `Mangrove/assets/comix_to.js` v0.6.4 → **v0.6.5**

1. 模块级 `_comixBlockedHint`（中英双语，给出当天实测可用节点）+ `_comixIsBlocked(e)`；
2. `loadInfo` 封禁正则补 `@waf/challenge`、`<title>security check`、`challenge-platform/h/`
   （dio 200 返回挑战页不再报误导性的 `no initial-data in page`，直接双语提示）；
3. `loadEp` 包 try/catch：桥抛 `COMIX_IP_BLOCKED` → 双语提示（治下载卡死的用户侧表现）；
4. 新增 `_comixBrowse(query,page)` 收口搜索/发现/分类三处桥接，被封同样双语提示。
5. 🔴 **运行时同步**：appdata `comic_source/` 副本停留在 10/6 旧版（P41 改动从未生效），
   已备份 `comix_to.js.bak_20261012_P45` 后同步新版，**SHA256 与仓库一致**（22,226 B）。

---

## 4. 验证

### 4.1 Node 逻辑层（真实常量 + 两份现场 HTML，工装 `%TEMP%\comix_p45_test.js`，不进仓库）

从 `comix_to.js` 正则抽出**真实**挑战正则 / `_comixIsBlocked` / `_comixBrowse`，
对 `%TEMP%\comix_title_fr.html`（法国节点真挑战页 9,394 B）与
`%TEMP%\title_hk05.html`（香港Y05 真 SSR 页 28,014 B）断言：

| 用例 | 期望 | 实测 |
|---|---|---|
| A 真挑战页 | 识别 | ✓ |
| B 真 SSR 页 | **不误判**（jsd 探针守卫） | ✓ |
| C **故障**：抹掉全部专属标记 | 识别不到（证 A 非恒真） | ✓ |
| D **故障**：真页注入 `@waf/challenge` | 识别（证标记有效） | ✓ |
| E 仅含裸 jsd 探针片段 | 不误判 | ✓ |
| F `challenge-platform/h/` 托管挑战 | 识别 | ✓ |
| G/H `_comixIsBlocked` | block=true / other=false | ✓ |
| I browse 成功透传 | items 原样返回 | ✓ |
| J **故障映射**：桥抛 block | 翻成双语切节点提示 | ✓ |
| K 非 block 异常 | 原样抛 | ✓ |

**12 pass / 0 fail**；`node --check` rc=0。

### 4.2 构建与门禁

`run_build_task.py` → **BUILD_OK**（analyze rc=0）。
门禁全绿**持平**（本轮无新增断言）：block-ops **108** / run-plan **31** /
bootstrap **34** / glossary **26** / glossary-ui **30** / edit-check **216**（0 fail，FT 夹具口径同 P43/P44）。

新代码进产物：`app.so`（20,693,896 B）mtime 12:11:37 > 源码 10:48:02；
Latin-1 命中 `@waf/challenge` / `COMIX_IP_BLOCKED` / `WAF challenge page after navigating to` /
`exit IP banned`。

---

## 5. 给用户的代理 / 网卡优化建议（要点）

1. **节点选择**：用香港 **IEPL** 梯队（Y05/Y02/Y09/Y11，实测 ~0.54s）或日本 IEPL Y01/Y03；
   **避开**：美/印/法/澳、已被封的香港Y01、标「下载专用 x0.01」的日本节点（comix 403）、免费节点。
2. **被封是常态不是故障**：名单随时间漂移（香港Y01 一天内翻转）。症状（搜索失败/章节不全/
   阅读只转圈/下载卡图片列表）出现时**先换节点**，新版会在 ~1s 内弹中英双语提示，不必再干等。
3. **Clash 自动组帮不上 WAF**：延迟测试对挑战页也返回 200，URL-test/fallback 判不了封禁；
   想要半自动可在配置里为 comix 单独建一个**只含港/日 IEPL 节点的小选择组**，
   加规则 `DOMAIN-SUFFIX,comix.to → 该组`，被封时在小组内手动轮换（3~5 个候选够打地鼠）。
4. **网卡**：链路无瓶颈（好节点 500KB/s+、8 并发无损）。本机用 **WLAN**；若想更稳可插网线，
   或在任务管理器看 WLAN 速率/信号（`netsh wlan show interfaces` 需开 Windows 位置权限）。
   MTU 1500、TCP autotuning normal 均正常，无需改注册表/MTU。
5. **代理模式**：当前 rule 模式 + 系统代理（非 TUN）即可，App 与离屏 WebView 都已跟随
   `127.0.0.1:7890`（日志 `webview proxy: ... bypass=<local>`），无需开 TUN。

---

## 6. GUI 人工复测（无渲染表面，交用户；见 P29 脚本尾部 AA 组）

完全退出 App（含托盘）重启后：被封节点 → 搜索/详情/阅读/下载均应在 **~1~2s 内**弹
中英双语切节点提示（不再 30~90s 卡死）；香港 Y05 下 → 搜索出结果、章节翻全、
阅读页图片远超 3 张、下载顺利过「获取图片列表」。

## 7. 改动文件（均未提交）

| 文件 | 改动 |
|---|---|
| `Mangrove/lib/network/comix_client.dart` | 挑战识别修正（去裸 `challenge-platform`、加 `@waf/challenge`/`<title>security check`）；`_navigate` 守卫 `_throwIfOnChallenge`；`_isIpBlocked` + 四处 rethrow 短路；`_route` block 透传 |
| `Mangrove/assets/comix_to.js` | v0.6.5：模块级双语提示 + 3 处桥接收口；loadInfo 新挑战正则；loadEp block 提示 |
| `%APPDATA%/…/comic_source/comix_to.js`（仓库外运行时） | 同步 v0.6.5（旧版备份 `*.bak_20261012_P45`） |

遗留：任务 C（加密 API `{"e":"..."}` 真解密 / SSR `no chapters`）仍未推进。