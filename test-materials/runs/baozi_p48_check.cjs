/* P48 包子源修复验证桩 —— 真实加载 comic_source/baozi.js 并驱动三处新逻辑。
 * 不依赖浏览器/Flutter，仅用 Node 模拟最小框架 (ComicSource/Network/HtmlDocument)。
 * 三个 HTML 桩来自真实抓取:
 *   /tmp/v_150.html  = 镜像 151 章(正常, 50 图, 正确 slug)
 *   /tmp/v_151.html  = 镜像 152 章(残缺, 1 图, 错 slug)
 *   /tmp/v_app152.html = 官方 app 域 152 章(完整, 91 图, 正确 slug)
 */
const fs = require("fs");

const SRC = process.argv[2] ||
  "D:/AI Coding Project Management/Mangrove/comic_source/baozi.js";
const BROKEN = fs.readFileSync("/tmp/v_151.html", "utf8"); // 镜像 152 残缺
const GOOD = fs.readFileSync("/tmp/v_150.html", "utf8"); // 镜像 151 正常
const APP = fs.readFileSync("/tmp/v_app152.html", "utf8"); // 官方 152 完整

// ---- 最小框架桩 ----
class ComicSource {}
class Cookie { constructor(o) { Object.assign(this, o || {}); } }
const Network = {
  get: async (url) => {
    if (url.includes("appcn.baozimh.com")) return { status: 200, body: APP };
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
  console.log("\n========== 结果: " + pass + " 通过, " + fail + " 失败 ==========");
  process.exit(fail === 0 ? 0 : 1);
}).catch((e) => {
  console.error("harness error:", e);
  process.exit(2);
});
