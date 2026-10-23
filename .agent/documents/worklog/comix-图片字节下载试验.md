# comix 图片字节下载试验工作日志

> 主题：绕过 Cloudflare WAF（TLS 指纹拦截）抓取 comix.to 章节图片字节。
> 时间：2026-10 上中旬多轮（ consolidated 于 2026-10-17）。
> 结论已沉淀进 `A07-comix源.md §1`；本日志记录 AI 当时的分析路线。

## 1. 目标与假设

- **目标**：把 comix.to 的章节图片（CDN 域名轮换）原样下载到本地，用于漫画阅读/汉化。
- **初始假设**：直接用 `dart:io` 的 HttpClient / `curl` 带 cookie 即可下载。

## 2. 工具与方法（AI 分析路线）

1. 先用 `curl -x 127.0.0.1:7890` 直连图片 CDN → 期望 200，实际**必然 403**。
2. 抓包分析：CDN 前置 **Cloudflare WAF**，按 **TLS 指纹**识别非浏览器客户端（非按 cookie/域名）。
3. 切换思路：必须让请求**看起来来自真实浏览器** → 走 `_ComixImageWorker`：
   - **导航优先**（WebView 加载图片页）→ 在同源上下文里 `fetch` 并回读 **base64 字节**；
   - 不走 `dart:io` 下载，规避 TLS 指纹。
4. 并发策略：**3 通道并行**，单图**硬预算 30s**。

## 3. 观察与数据

- CDN 域名**轮换**（如 `447.joshuanotes.site` 等），相关 URL 是**单次签名、会过期**（见 A01 §2.2）。
- 防盗链靠 **Referer** 而非域名 cookie：原生懒加载（lazy-load）取字节时带对的首页 Referer 即可。
- `WebViewController.evaluateJavascript` **不 await Promise** → 一切异步求值必须走 `evalAsyncResult()`，
  否则拿到 `{}` / `null`（典型静默失败）。

## 4. 结论

- ✅ comix 图片**只能走 WebView 取字节**，任何原生 HTTP 客户端都会 403（WAF TLS 指纹）。
- ✅ Referer 防盗链 + 域名轮换 + 单次签名过期，三条共同决定"必须 WebView 同源 fetch"。

## 5. 反向验证（不虚报）

- 注入对照：用 `curl`/`dart:io` 拿同一 URL → 稳定 403（断言真的 FAIL）；
  改用 WebView fetch → 拿到 base64 字节（断言真的 PASS）。空字节/0 字节按 A02 判 FAIL。

## 6. 遗留 / 未决

- 域名轮换 + 签名过期对 headless 验证 deadline 的约束已记入 A01；图片下载的 GUI 表面验证需在用户会话复跑。
