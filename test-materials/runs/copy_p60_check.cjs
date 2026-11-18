/* P60 Copy 源 A 方案(借鉴 Scrapling 自适应退避)验证桩 —— 真实加载
 * comic_source/copy_manga(5).js 并驱动自适应退避纯函数 + 接入点断言。
 * 不依赖浏览器/Flutter，仅用 Node 模拟最小框架。
 *
 * 用法: node copy_p60_check.cjs [源文件]
 *   源文件默认 comic_source/copy_manga(5).js
 *
 * 判据(对应 P58 §2.2 Scrapling spiders/throttle.py 的克制机制):
 *   ① 封禁翻倍: newDelay = max(current×2, retryAfterMs, current) 并 clamp 到 max
 *   ② 遵守 Retry-After(秒/HTTP-date 由调用方转成毫秒后传入)
 *   ③ 成功衰减: delay 缓慢下降但不低于 floor(封禁永不加速的对称面)
 *   ④ 按域名隔离(此处退避值由外部 state 对象按域名存, 纯函数不混域)
 *   ⑤ 接线: throttle() 与 210/429 退避都调用同一个策略(不能各写一套)
 */
const fs = require("fs");

const argv = process.argv.slice(2);
const SRC = argv[0] || "D:/AI Coding Project Management/Mangrove/comic_source/copy_manga(5).js";
const raw = fs.readFileSync(SRC, "utf8");

// ---- 最小框架桩 ----
class ComicSource {}
const Convert = {
  hmacString: () => "stub-sig",
  decodeBase64: (s) => s,
  encodeUtf8: (s) => s,
};
const Network = { get: async () => ({ status: 200, body: "{}" }), post: async () => ({ status: 200, body: "{}" }) };

// 加载真实 copy 源。文件尾部是 `}`(class 结束), 未导出; 用 Function 追加 return。
let CopyManga;
try {
  CopyManga = new Function(
    "ComicSource", "Convert", "Network", "console", "setTimeout",
    raw + "\n;return CopyManga;"
  )(ComicSource, Convert, Network, { log: () => {} }, (fn) => fn());
} catch (e) {
  console.error("加载 copy 源失败:", String((e && e.message) || e));
  process.exit(2);
}

let pass = 0, fail = 0;
const assert = (cond, msg) => {
  if (cond) { pass++; console.log("  OK " + msg); }
  else { fail++; console.log("  FAIL " + msg); }
};
const near = (a, b, tol = 1) => Math.abs(a - b) <= tol;

console.log("\n=== 测试1: adaptiveBackoff 封禁翻倍 + Retry-After + clamp ===");
{
  const f = CopyManga && CopyManga.adaptiveBackoff;
  assert(typeof f === "function", "CopyManga.adaptiveBackoff 是函数(A方案新增纯函数)");
  if (typeof f === "function") {
    // 翻倍: 当前 1000ms, 无 retryAfter → 2000ms
    assert(near(f(1000, { retryAfterMs: 0 }), 2000),
      "封禁翻倍: 1000→2000 (实际 " + f(1000, { retryAfterMs: 0 }) + ")");
    // Retry-After 更强: 当前 1000, retryAfter 9000 → 取 9000
    assert(near(f(1000, { retryAfterMs: 9000 }), 9000),
      "遵守 Retry-After: 1000/RA9s→9000 (实际 " + f(1000, { retryAfterMs: 9000 }) + ")");
    // 翻倍比 RA 更强时取翻倍: 当前 30000, RA 1000 → 60000
    assert(near(f(30000, { retryAfterMs: 1000 }), 60000),
      "封禁永不加速: 取 max(翻倍,RA,current)=60000 (实际 " + f(30000, { retryAfterMs: 1000 }) + ")");
    // clamp: 当前 60000, 无 RA → 不超过 maxDelay(60000)
    assert(f(60000, { retryAfterMs: 0 }) <= 60000,
      "clamp 到 maxDelay=60000 (实际 " + f(60000, { retryAfterMs: 0 }) + ")");
    // floor: 异常小值不低于 floor
    assert(f(0, { retryAfterMs: 0 }) >= 600,
      "不低于 floor=600ms (实际 " + f(0, { retryAfterMs: 0 }) + ")");
    // 自定义 max
    assert(f(5000, { retryAfterMs: 0, maxDelay: 8000 }) === 8000,
      "遵守自定义 maxDelay=8000");
  }
}

console.log("\n=== 测试2: adaptiveRelax 成功衰减但不低于 floor ===");
{
  const f = CopyManga && CopyManga.adaptiveRelax;
  assert(typeof f === "function", "CopyManga.adaptiveRelax 是函数(A方案新增纯函数)");
  if (typeof f === "function") {
    // 衰减: 20000 × 0.85 = 17000
    assert(near(f(20000), 17000), "成功衰减 20000→17000 (实际 " + f(20000) + ")");
    // floor: 600 × 0.85 < 600 → 钳到 600
    assert(f(600) >= 600, "衰减不低于 floor=600 (实际 " + f(600) + ")");
  }
}

console.log("\n=== 测试3: 接线 — throttle 与 210/429 退避调用同一策略 ===");
{
  const src = raw;
  // 源码里 adaptiveBackoff 至少要被 throttle 外的风控退避路径调用到两次以上
  // (loadInfo 的 210/软风控, loadEp 的 210/软风控, 以及统一退避 helper)
  const callCount = (src.match(/adaptiveBackoff\s*\(/g) || []).length;
  assert(callCount >= 2, "adaptiveBackoff 在源码中被调用 >=2 次(风控退避接线) (实际 " + callCount + ")");
  const relaxCount = (src.match(/adaptiveRelax\s*\(/g) || []).length;
  assert(relaxCount >= 1, "adaptiveRelax 在源码中被调用 >=1 次(成功后衰减) (实际 " + relaxCount + ")");
  // Retry-After 解析函数必须存在(解析秒数)
  assert(/parseRetryAfter\s*\(/.test(src), "存在 parseRetryAfter 解析(秒/字符串)");
}

console.log("\n========== 结果: " + pass + " 通过, " + fail + " 失败 ==========");
process.exit(fail === 0 ? 0 : 1);
