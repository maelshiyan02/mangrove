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

## 5. 相关文件

- 源脚本：`assets/comix_to.js` —— **不进 flutter_assets**；
  运行时读 `%APPDATA%\io.github.kyosee\venera\comic_source\*.js` → **改后必须手动同步**。
- 调试工装：`tools/probe_copy_web*.py`、`tools/test_copy_v180.py`、`tools/copy_aes.js`。
- 分析文档：`docs/P4-comix-to漫画源配置分析-20260929.md`、
  `docs/P4-针对comix.to漫画源配置文件的设计与实施工程记录日志.md`、
  `docs/P4-agent-handoff-comix-to.md`。
