/* P48 包子源修复验证桩 —— 真实加载 comic_source/baozi.js 并驱动三处新逻辑。
 * 不依赖浏览器/Flutter，仅用 Node 模拟最小框架 (ComicSource/Network/HtmlDocument)。
 *
 * 用法: node baozi_p48_check.cjs [源文件] [--samples <样本目录>]
 *   源文件默认 comic_source/baozi.js；样本目录默认 <本脚本目录>/baozi_p48_samples，
 *   依次回退 /tmp、D:/tmp（旧路径兼容）。
 *
 * 三个 HTML 样本均为 2026-10-27 现场真实抓取（第三方版权页，不入 git，见 .gitignore）:
 *   v_150.html    = 镜像 151 章(正常, 50 图, 正确 slug)
 *   v_151.html    = 镜像 152 章(残缺, 1 图, 错 slug)
 *   v_app152.html = 官方 app 域 152 章(完整, 91 图节点, 去重 86)
 */
const fs = require("fs");
const path = require("path");

const argv = process.argv.slice(2);
let SRC = null, samplesDir = null;
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--samples") samplesDir = argv[++i];
  else if (!SRC) SRC = argv[i];
}
SRC = SRC || "D:/AI Coding Project Management/Mangrove/comic_source/baozi.js";

const loadSample = (f) => {
  const cands = [samplesDir, path.join(__dirname, "baozi_p48_samples"), "/tmp", "D:/tmp"]
    .filter(Boolean);
  for (const d of cands) {
    const p = path.join(d, f);
    if (fs.existsSync(p)) return fs.readFileSync(p, "utf8");
  }
  console.error("找不到样本 " + f + "，已尝试: " + cands.join(" , "));
  process.exit(3);
};
const BROKEN = loadSample("v_151.html"); // 镜像 152 残缺
const GOOD = loadSample("v_150.html"); // 镜像 151 正常
const APP = loadSample("v_app152.html"); // 官方 152 完整

// ---- 最小框架桩 ----
class ComicSource {}
class Cookie { constructor(o) { Object.assign(this, o || {}); } }
let appcnHeaders = null; // 记录回落请求实际发出的头
let appcnForbidden = false; // 故障注入开关: 模拟官方域 CF 挑战
const Network = {
  get: async (url, headers) => {
    if (url.includes("appcn.baozimh.com")) {
      appcnHeaders = headers || null;
      // 真实链路: Dio 识别 403 + cf-mitigated:challenge 后**抛**
      // CloudflareException(不是返回 403), UI 靠这条消息自动跑离屏验证。
      if (appcnForbidden) throw new Error("CloudflareException: " + url);
      return { status: 200, body: APP };
    }
    if (url.includes("0_151")) return { status: 200, body: BROKEN }; // 残缺 152
    if (url.includes("0_150")) return { status: 200, body: GOOD }; // 正常 151
    return { status: 200, body: GOOD };
  },
  post: async () => ({ status: 200, body: "{}" }),
  setCookies: () => {}, deleteCookies: () => {},
};
class HtmlDocument {
  constructor(body) { this.body = body; }
  querySelector() { return null; }
  querySelectorAll(sel) {
    if (sel.indexOf("comic-contain__item") >= 0) {
      const nodes = [];
      const re = /<[a-zA-Z0-9]+[^>]*class="[^"]*comic-contain__item[^"]*"[^>]*>/g;
      let m;
      while ((m = re.exec(this.body))) {
        const tag = m[0];
        const ds = /data-src="([^"]+)"/.exec(tag);
        const src = /src="([^"]+)"/.exec(tag);
        const url = (ds && ds[1]) || (src && src[1]) || null;
        if (url) nodes.push({ attributes: { "data-src": url, src: url } });
      }
      return nodes;
    }
    return [];
  }
}

// ---- 加载真实 baozi.js ----
const raw = fs.readFileSync(SRC, "utf8");
const Baozi = new Function(
  "ComicSource", "Network", "HtmlDocument", "Cookie",
  raw + "\n;return Baozi;"
)(ComicSource, Network, HtmlDocument, Cookie);

const b = new Baozi();
b.loadSetting = (k) => {
  const s = b.settings[k];
  return s && s.default !== undefined ? s.default : null;
};
b.loadData = () => null;
b.saveData = () => {};
b._goodDomain = null;
b.autoFailover = true;

const COMIC_ID = "miemenjiazudezhongshengzhe-yangpyungpainkillersaintnine";

let pass = 0, fail = 0;
const assert = (cond, msg) => {
  if (cond) { pass++; console.log("  OK " + msg); }
  else { fail++; console.log("  FAIL " + msg); }
};

console.log("\n=== 测试1: _cdnAlternativesFor 候选正确性 ===");
{
  const url = "https://s1.bzcdn.net/scomic/foo/0/1/1.jpg";
  const alts = b._cdnAlternativesFor(url);
  assert(alts.length === b.cdnCandidates.length - 1,
    "候选数 = " + alts.length + " (排除当前域, 应是 " + (b.cdnCandidates.length - 1) + ")");
  assert(!alts.some((u) => u.includes("s1.bzcdn.net")),
    "排除了当前域 s1.bzcdn.net");
  assert(alts.some((u) => u.includes("s2.baozicdn.com")),
    "含新增 s2.baozicdn.com");
  assert(alts.some((u) => u.includes("s.baozicdn.com")),
    "含新增 s.baozicdn.com");
  assert(alts.every((u) => u.endsWith("/scomic/foo/0/1/1.jpg")),
    "所有候选路径与原 URL 一致(只换了 host)");
}

console.log("\n=== 测试2: onImageLoad 链式穷举 + 闭包独立 ===");
{
  const url = "https://s1.bzcdn.net/scomic/foo/0/1/1.jpg";
  const cfg = b.comic.onImageLoad(url, COMIC_ID, "151");
  const alts = b._cdnAlternativesFor(url);
  assert(cfg.retryLimit === alts.length + 1,
    "retryLimit = " + cfg.retryLimit + " (应为 " + (alts.length + 1) + ")");
  const hops = [];
  let of = cfg.onLoadFailed;
  const seenFns = new Set();
  let guard = 0;
  while (of && guard < 50) {
    seenFns.add(of);
    const res = of();
    guard++;
    if (!res) { break; }
    hops.push(res.url);
    of = res.onLoadFailed;
  }
  assert(hops.length === alts.length,
    "穷举了全部 " + alts.length + " 个候选 (实际 " + hops.length + " 跳)");
  assert(hops.every((u, i) => u.includes(alts[i].split("/")[2])),
    "跳序与候选顺序一致");
  assert(seenFns.size === alts.length,
    "每个 onLoadFailed 是独立闭包 (distinct=" + seenFns.size + " == 候选数 " + alts.length + "，无重复引用=无 use-after-free)");
  assert(!hops.includes(url), "不重复跳回原始 host");
}

console.log("\n=== 测试3a: 残缺 152 章 → 回落官方域拿到完整 91 图 ===");
(async () => {
  let result;
  try {
    result = await b.comic.loadEp(COMIC_ID, "151"); // epId=151 = 第152章
  } catch (e) {
    console.log("  loadEp 抛错:", String((e && e.message) || e));
    result = { images: [] };
  }
  assert(result && Array.isArray(result.images), "loadEp 返回 {images}");
  assert(result.images.length >= 80,
    "拿到完整章 (实际 " + result.images.length + " 张，若只 1 张说明没回落；86 系去重后值，原始节点 91)");
  assert(result.images.every((u) => u.includes(COMIC_ID)),
    "所有图都含本书正确 slug (不是错 slug 的 1 张)");
  assert(result.images.every((u) => u.includes("baozicdn.com")),
    "图来自官方域 baozicdn.com");
})().then(() => {
  console.log("\n=== 测试3b: 正常 151 章 → 不误伤，拿 50 图 ===");
  return (async () => {
    let result;
    try {
      result = await b.comic.loadEp(COMIC_ID, "150"); // epId=150 = 第151章
    } catch (e) {
      console.log("  loadEp 抛错:", String((e && e.message) || e));
      result = { images: [] };
    }
    assert(result && Array.isArray(result.images), "loadEp 返回 {images}");
    assert(result.images.length === 50,
      "正常章拿到 50 张 (实际 " + result.images.length + ")");
    assert(result.images.every((u) => u.includes(COMIC_ID)),
      "所有图含正确 slug");
  })();
}).then(() => {
  console.log("\n=== 测试4a: 回落请求不得覆盖 UA（交由引擎注入 webUA）===");
  // appcnHeaders 由测试3a 的回落请求记录而来
  const ua = appcnHeaders && (appcnHeaders["User-Agent"] || appcnHeaders["user-agent"]);
  assert(!ua, "源层没有塞 User-Agent（实际: " + ua + "）；引擎 _http 会补 consts.webUA，写死版本号会随浏览器更新过期");

  console.log("\n=== 测试4b: 故障注入 — CloudflareException 必须原样透传 ===");
  // 真实链路: Dio 抛 CloudflareException → UI(loading.dart) 靠该消息自动跑离屏
  // WebView 验证再 retry。源若把它包装成别的字符串，自动验证入口即失效。
  appcnForbidden = true;
  return (async () => {
    let err = null;
    try {
      await b.comic.loadEp(COMIC_ID, "151");
    } catch (e) {
      err = e;
    }
    const msg = String((err && err.message) || err || "");
    assert(!!err, "挑战时确实抛错(没静默返回空章)");
    assert(/CloudflareException/.test(msg), "消息保留 CloudflareException 前缀(自动验证入口仍可识别) (实际: " + msg + ")");
    assert(!/DomainChallenge/.test(msg), "没有被源改写成 DomainChallenge 之类的自造错误");
    appcnForbidden = false;
  })();
}).then(() => {
  console.log("\n========== 结果: " + pass + " 通过, " + fail + " 失败 ==========");
  process.exit(fail === 0 ? 0 : 1);
}).catch((e) => {
  console.error("harness error:", e);
  process.exit(2);
});
