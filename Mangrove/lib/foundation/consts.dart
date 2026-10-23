/// If window width is less than this value, it is considered as mobile.
const changePoint = 600;

/// If window width is less than this value, it is considered as tablet.
///
/// If it is more than this value, it is considered as desktop.
const changePoint2 = 1300;

/// Default user agent for http requests + WebView2.
/// P-DL9 (2026-10-17): 必须与用户系统 Chrome 版本一致（当前 155.0.8059.80），
/// 否则 Cloudflare 会识别 WebView2 默认 UA（含 Edg/WebView）为非真实浏览器 →
/// 强制 Turnstile challenge → 阻塞整个 JS 引擎 → 所有 evaluateJavascript 超时。
const webUA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36";

/// Pages for all comics is started from this value.
const firstPage = 1;

/// Chapters for all comics is started from this value.
const firstChapter = 1;