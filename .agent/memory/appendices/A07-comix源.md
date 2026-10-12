# A07 · comix.to 漫画源

> **触发时机**：碰 comix.to 源、图片抓取、WebView 取字节、Cloudflare/WAF 相关**之前**。
> 上级索引：`../MEMORY.md` ｜ 详细：`docs/P4-*`（见 `W00` 索引）

---

## 1. 🔴 图片必须走 WebView 取字节

- **原因**：CDN 前面有 **Cloudflare WAF**（1020 类），按 **TLS 指纹**拦截非浏览器客户端。
  `dart:io` 的 HttpClient / curl **必然 403**。
- **实现**：`_ComixImageWorker` —— **导航优先** → 在同源上下文里 `fetch` 并回读 **base64**。
- 并发：**3 通道并行**；**整图硬预算 30s**。
- 域名会**轮换**（如 `447.joshuanotes.site` 等）→ 相关 URL 是**单次签名**，**会过期**（见 `A01 §2.2`）。

## 2. 🔴 token 与分页

- **签名 token 的参数名是单下划线 `_`**。
  写成 `__` 会**静默降级**成 DOM 解析路径（不报错，只是拿不到数据）。
- **token 绑定「完整 query」** → **不能自己拼分页参数**；
  正确做法：**让 SPA 自己发请求，然后截获**。
- 部分响应是**加密的**：形如 `{"e": "..."}`（需要解密后再解析）。
- 详情页是 SSR，其余是 SPA；章节接口形如 `/api/v1/manga/{hid}/chapters`。

## 3. 🔥 `evaluateJavascript` 不 await Promise

- `WebViewController.evaluateJavascript` **不会等待 Promise**。
- ⇒ **一切异步求值必须走 `evalAsyncResult()`**（封装好的等待版本），否则拿到的是 `{}` 或 `null`。

## 4. cookie / 站点簇

- cookie 按**站点簇**复用（判定用 **eTLD+1**），不要按完整 host（域名轮换会失效）。
- 包子漫画（baozimh）的 **PoW 约需 2 分钟**，且难度已上调（`difficultyBits: 12` / `computeMs: 120000`）
  ⇒ **headless 验证的 deadline 必须 ≥ 200s**。

## 5. 🔴 WAF 按**出口 IP** 封禁，挑战页指纹与节点实测（P41/P43/P45，2026-10-12）

- 封禁形态：HTTP **200**，但页面是挑战页（不是 403）。两种指纹都要认：
  - **comix 自家滑块页**（P45 实锤，9,394 B）：URL 落 **`/@waf/challenge?return=`**、
    `<title>Security check</title>`、无 initial-data；
  - CF 硬封页：`attention required` / `blocked_why_headline` / `cf-error-details` /
    `challenge-platform/h/`（托管挑战路径）。
- 🔴 **CF jsd 探针 `/cdn-cgi/challenge-platform/scripts/jsd/main.js` 在真 SSR 页也全站注入**
  ⇒ **裸 `challenge-platform` 不能当判据**（会误判好页）；真页 >20KB、挑战页 <10KB。
- **名单按 IP 打地鼠、随时间漂移**（香港Y01 一天内 200→封；美国Y01 前后结论也翻过）
  ⇒ 任何"某节点可用"的结论必须带日期，症状复现时**当场实测**：
  `curl -x 127.0.0.1:7890 -sL "<标题页>" -o NUL -w "%{url_effective} %{http_code} %{size_download}"`
  落 `@waf/challenge` 或 <20KB = 被封。
- **2026-10-12 12:00 实测**（Clash for Windows，`127.0.0.1:7890`）：
  最快且通 = **🇭🇰香港 IEPL Y05/Y02/Y09/Y11（0.54~0.60s）**、日 Y01/Y03、新Y02、德/英/加；
  被封 = 法/澳/港Y01/日Y05·Y06「下载专用 x0.01」/韩/美/印（后两者为前几日结论）。
  **Clash 延迟测试判不了封禁**（挑战页也 200）；url-test/fallback 帮不上，只能人工轮换。
- 切节点 API：`PUT http://127.0.0.1:8445/proxies/%F0%9F%94%B0%20%E9%80%89%E6%8B%A9%E8%8A%82%E7%82%B9`
  body `{"name":"🇭🇰 香港Y05 | IEPL"}` —— 🔴 body 必须按 **UTF-8 字节**发，
  PowerShell 5 默认 Latin-1 会静默切换失败。
- App 侧行为（P45 起）：导航后 ~1s 双采样识别挑战页 → 抛 `COMIX_IP_BLOCKED`，
  搜索/章节/图片/下载**全链路直通双语切节点提示，不重试不空等**（旧路径最坏 ~90s）。

## 6. 相关文件

- 源脚本：`assets/comix_to.js` —— **不进 flutter_assets**；
  运行时读 `%APPDATA%\io.github.maelshiyan02\mangrove\comic_source\*.js` → **改后必须手动同步**。
- 调试工装：`tools/probe_copy_web*.py`、`tools/test_copy_v180.py`、`tools/copy_aes.js`。
- 分析文档：`docs/P4-comix-to漫画源配置分析-20260929.md`、
  `docs/P4-针对comix.to漫画源配置文件的设计与实施工程记录日志.md`、
  `docs/P4-agent-handoff-comix-to.md`。
