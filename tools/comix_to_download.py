# -*- coding: utf-8 -*-
"""从 comix.to 抓「单章图片列表 → 下载到漫画目录」。

## 为什么这样做

comix.to 的 `/api/v1/manga/{hid}/chapters` 要一个 SPA 现算的 `_=` token，
纯 HTTP 拿不到；页面首屏也只有壳。App 里的 `comix_to.js` 走的是「离开屏
WebView、用页内 fetch 复用 SPA 已发过的带 token URL」，本脚本把同一条路子
搬到 Python：开一个真 Chrome、在页面里 `fetch`，再把结果读回来。

## 关键机关（都是踩过坑才有的）

* **章节 API 的 token 从 `performance` 里捡**：SPA 自己发过一次带 `_=` 的
  请求，直接复用那个 URL 的 query，只改 `page`/`limit`。
* **图片是虚拟列表**，滚动只会挂出当前屏的一两张。真正能"一次点亮全部"的是
  进度条的 `.rpage-progress__seg` —— 点每一段就跳到那一页并挂图。所以
  「注入 MutationObserver 收 src + 并行 click 所有 seg」比滚轮快一个数量级。

## 用法

    python -u tools/comix_to_download.py --chapters 153-157 --dry-run
    python -u tools/comix_to_download.py --chapters 153-157 --apply
"""

import argparse
import asyncio
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

CHROME_CANDIDATES = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
]

HID = "ll82v"
TITLE_SLUG = "regressor-of-the-fallen-family"
CHAPTER_SLUG = "a-flame-reborn"

LIBRARY = r"D:\AI Coding Project Management\Mangrove\ComicLibrary\downloads"
TITLE_DIR = "灭门家族的重生者"
SITE_TAG = "comix.to"
LANGUAGE = "en"

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
)

# 抓章节列表：复用 SPA 已经发过的带 token URL，逐页翻完。
JS_CHAPTERS = r"""
(async function () {
  var hid = '__HID__';
  var entries = performance.getEntriesByType('resource').filter(function (e) {
    return e.name.indexOf('/api/v1/manga/' + hid + '/chapters') >= 0 &&
           e.name.indexOf('_=') >= 0;
  });
  var apiUrl = entries.length ? entries[entries.length - 1].name : null;
  if (!apiUrl) {
    // SPA 还没发过：点一次"章节" tab / 翻页器，逼它发
    var tab = document.querySelector('[class*="episode"], [class*="chapter"]');
    if (tab) { try { tab.click(); } catch (e) {} }
    await new Promise(function (r) { setTimeout(r, 2500); });
    entries = performance.getEntriesByType('resource').filter(function (e) {
      return e.name.indexOf('/api/v1/manga/' + hid + '/chapters') >= 0 &&
             e.name.indexOf('_=') >= 0;
    });
    apiUrl = entries.length ? entries[entries.length - 1].name : null;
  }
  if (!apiUrl) return JSON.stringify({ error: 'no token url', items: [] });

  var base = apiUrl.split('?')[0];
  var params = apiUrl.indexOf('?') >= 0 ? apiUrl.substring(apiUrl.indexOf('?') + 1).split('&') : [];
  var seen = new Set();
  var items = [];
  for (var page = 1; page <= 40; page++) {
    var next = [];
    var hasPage = false, hasLimit = false;
    for (var i = 0; i < params.length; i++) {
      var p = params[i];
      if (p.indexOf('page=') === 0) { next.push('page=' + page); hasPage = true; }
      else if (p.indexOf('limit=') === 0) { next.push('limit=100'); hasLimit = true; }
      else next.push(p);
    }
    if (!hasPage) next.push('page=' + page);
    if (!hasLimit) next.push('limit=100');
    var resp = await fetch(base + '?' + next.join('&'), { credentials: 'include' });
    var text = await resp.text();
    var data;
    try { data = JSON.parse(text); } catch (e) { break; }
    if (!data || !data.result) break;
    var batch = data.result.items || [];
    if (!batch.length) break;
    var dup = 0;
    batch.forEach(function (it) {
      var key = String(it.number) + '|' + (it.url || '');
      if (seen.has(key)) { dup++; return; }
      seen.add(key);
      items.push(it);
    });
    if (dup > 0) break;
    var meta = data.result.meta || data.result.pagination || {};
    if (meta.last_page && page >= meta.last_page) break;
    if (batch.length < 100) break;
  }
  return JSON.stringify({ items: items });
})()
"""

# 收章节图：注入 observer + 点遍"Go to page N"。
#
# 🔴 阅读器是虚拟列表，滚动只挂当前屏一两张；而进度条上每个页都有一个
# `aria-label="Go to page N"` 的按钮，点它等于"跳到第 N 页并按需挂图"。
# 一次性全点一遍，比滚轮快一个数量级（实测 110+ 页能在一分钟内收齐）。
JS_IMAGES_SETUP = r"""
(function () {
  var adSel = '[class*="ad-"],[class*="overlay"],[class*="modal"],[class*="popup"],[class*="interstitial"],[class*="shield"]';
  document.querySelectorAll(adSel).forEach(function (el) {
    if (el.style) el.style.display = 'none';
  });
  window.__comixImgUrls = new Set();
  document.querySelectorAll('.rpage-page__img').forEach(function (img) {
    if (img.src) window.__comixImgUrls.add(img.src);
  });
  if (!window.__comixImgObs) {
    window.__comixImgObs = new MutationObserver(function (muts) {
      muts.forEach(function (m) {
        m.addedNodes.forEach(function (n) {
          if (n.querySelectorAll) {
            n.querySelectorAll('.rpage-page__img').forEach(function (img) {
              if (img.src) window.__comixImgUrls.add(img.src);
            });
          }
          if (n.classList && n.classList.contains &&
              n.classList.contains('rpage-page__img') && n.src) {
            window.__comixImgUrls.add(n.src);
          }
        });
      });
    });
    window.__comixImgObs.observe(document.body,
      { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
  }
  var targets = document.querySelectorAll('[aria-label^="Go to page"]');
  var segs = document.querySelectorAll('.rpage-progress__seg');
  var total = 0;
  Array.prototype.forEach.call(targets, function (el, idx) {
    setTimeout(function () { el.click(); }, idx * 8);
    total++;
  });
  Array.prototype.forEach.call(segs, function (el, idx) {
    setTimeout(function () { el.click(); }, idx * 8);
    total++;
  });
  return { pageButtons: targets.length, segs: segs.length };
})()
"""

# 上一章按钮（章节页顶部 `‹ Ch.157 / 157 ›` 里那个）。
JS_PREV_CHAPTER = r"""
(function () {
  var btn = document.querySelector('[aria-label="Previous chapter"]');
  if (!btn) return false;
  btn.click();
  return true;
})()
"""


def find_chrome():
    for path in CHROME_CANDIDATES:
        if os.path.exists(path):
            return path
    raise SystemExit("找不到 Chrome / Edge")


def start_chrome(port, proxy, profile):
    args = [
        find_chrome(),
        f"--remote-debugging-port={port}",
        f"--user-data-dir={profile}",
        "--headless=new",
        "--disable-gpu",
        "--no-first-run",
        "--no-default-browser-check",
        "--window-size=1280,900",
    ]
    if proxy:
        args.append(f"--proxy-server={proxy}")
    args.append("about:blank")
    return subprocess.Popen(
        args,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )


def wait_targets(port, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/json", timeout=2
            ) as resp:
                targets = json.load(resp)
            pages = [t for t in targets if t.get("type") == "page"]
            if pages:
                return pages
        except Exception:
            pass
        time.sleep(0.5)
    raise SystemExit("CDP 端口没起来")


class Cdp:
    def __init__(self, ws):
        self.ws = ws
        self.counter = 0
        self.waiters = {}

    async def send(self, method, params=None):
        self.counter += 1
        message_id = self.counter
        future = asyncio.get_event_loop().create_future()
        self.waiters[message_id] = future
        await self.ws.send(
            json.dumps({"id": message_id, "method": method, "params": params or {}})
        )
        return await asyncio.wait_for(future, timeout=120)

    async def reader(self):
        async for raw in self.ws:
            msg = json.loads(raw)
            if "id" in msg and msg["id"] in self.waiters:
                future = self.waiters.pop(msg["id"])
                if not future.done():
                    future.set_result(msg.get("result", {}))

    async def evaluate(self, expression):
        result = await self.send(
            "Runtime.evaluate",
            {"expression": expression, "returnByValue": True, "awaitPromise": True},
        )
        return result.get("result", {}).get("value")


async def wait_ready(cdp, seconds=45):
    deadline = time.time() + seconds
    while time.time() < deadline:
        await asyncio.sleep(1.2)
        info = await cdp.evaluate(
            "({len: (document.body && document.body.innerText || '').length,"
            " blocked: (document.body && document.body.innerText || '')"
            ".indexOf('Third-party') >= 0})"
        )
        if info and info.get("blocked"):
            raise SystemExit("comix.to 判定本次会话为第三方应用（503），请等冷却或换出口")
        if info and info.get("len", 0) > 200:
            return
    raise SystemExit("页面迟迟没有正文（WAF/网络问题）")


async def chapter_number_on_page(cdp):
    """从 `document.title`（`A Flame Reborn · Ch.157`）读当前话号。"""
    title = await cdp.evaluate("document.title")
    match = re.search(r"Ch\.\s*(\d+)", title or "")
    return int(match.group(1)) if match else None


async def fetch_chapter_images(cdp, chapter_url):
    await cdp.send("Page.navigate", {"url": chapter_url})
    await wait_ready(cdp, 45)
    counts = await cdp.evaluate(JS_IMAGES_SETUP)
    last, stable = -1, 0
    deadline = time.time() + 70
    while time.time() < deadline:
        await asyncio.sleep(0.7)
        raw = await cdp.evaluate(
            "JSON.stringify(Array.from(window.__comixImgUrls || []))"
        )
        try:
            urls = json.loads(raw or "[]")
        except (TypeError, ValueError):
            urls = []
        if len(urls) == last:
            stable += 1
            if stable >= 8:
                break
        else:
            last = len(urls)
            stable = 0
    raw = await cdp.evaluate(
        "JSON.stringify(Array.from(window.__comixImgUrls || []))"
    )
    urls = json.loads(raw or "[]")
    label = counts if isinstance(counts, dict) else {}
    print(
        f"    页按钮 {label.get('pageButtons', '?')} / 分段 {label.get('segs', '?')}"
        f" → 收到 {len(urls)} 张"
    )
    return urls


async def goto_previous_chapter(cdp):
    before = await cdp.evaluate("location.href")
    clicked = await cdp.evaluate(JS_PREV_CHAPTER)
    if not clicked:
        return None
    for _ in range(40):
        await asyncio.sleep(0.5)
        now = await cdp.evaluate("location.href")
        if now and now != before:
            return now
    return None


def chapter_dir_name(number):
    """`[en] 152 [Asura Scans] [comix.to]`。

    数字用 **key（话号 - 1）**，与包子源那本对齐：包子 key `151` = 第 152 话，
    这里 key `152` = 第 153 话 —— 两个源的 key 落在同一套 0-based 坐标系里，
    并进同一份 `chapters` 时才不会撞也不会错位。
    """
    key = str(int(number) - 1)
    return f"[{LANGUAGE}] {key} [Asura Scans] [{SITE_TAG}]"


def download_images(urls, target_dir, workers=8):
    import concurrent.futures as cf
    import requests

    os.makedirs(target_dir, exist_ok=True)
    session = requests.Session()
    session.headers.update({"User-Agent": UA, "Accept": "image/webp,image/*,*/*"})
    adapter = requests.adapters.HTTPAdapter(
        pool_connections=workers, pool_maxsize=workers
    )
    session.mount("http://", adapter)
    session.mount("https://", adapter)
    failures = []

    def one(item):
        index, url = item
        path = os.path.join(target_dir, f"{index}.webp")
        if os.path.exists(path) and os.path.getsize(path) > 1024:
            return index, True
        for attempt in range(3):
            try:
                resp = session.get(url, timeout=45)
                if resp.status_code == 200 and len(resp.content) > 1024:
                    with open(path, "wb") as fp:
                        fp.write(resp.content)
                    return index, True
            except Exception:
                pass
            time.sleep(0.6 * (attempt + 1))
        return index, False

    with cf.ThreadPoolExecutor(max_workers=workers) as pool:
        for index, ok in pool.map(one, list(enumerate(urls))):
            if not ok:
                failures.append(index)
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--chapters", required=True, help="话号范围，如 153-157")
    parser.add_argument(
        "--start-url",
        default=f"https://comix.to/title/{HID}-{CHAPTER_SLUG}/11550660-chapter-157",
        help="最新一话的章节页（脚本从这里倒着走'上一章'）",
    )
    parser.add_argument("--port", type=int, default=9335)
    parser.add_argument("--proxy", default="http://127.0.0.1:7890")
    parser.add_argument(
        "--profile",
        default=os.path.join(os.environ.get("TEMP", "."), "comix_dl_profile"),
    )
    parser.add_argument("--json", default="builds/comix_download.json")
    parser.add_argument("--apply", action="store_true", help="真的下载（默认只列 URL）")
    args = parser.parse_args()

    if "-" in args.chapters:
        left, right = args.chapters.split("-", 1)
        wanted = list(range(int(left), int(right) + 1))
    else:
        wanted = [int(args.chapters)]

    profile = args.profile
    os.makedirs(profile, exist_ok=True)
    proc = start_chrome(args.port, args.proxy, profile)
    result = {"chapters": [], "totalImages": 0, "totalFailed": 0}
    try:
        pages = wait_targets(args.port)
        asyncio.run(_run(args, pages[0]["webSocketDebuggerUrl"], wanted, result))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()

    os.makedirs(os.path.dirname(args.json), exist_ok=True)
    with open(args.json, "w", encoding="utf-8") as fp:
        json.dump(result, fp, ensure_ascii=False, indent=2)
    print(
        f"[汇总] 章节 {len(result['chapters'])} / 图片 {result['totalImages']} "
        f"/ 失败 {result['totalFailed']} → {args.json}"
    )
    return 0


async def _run(args, ws_url, wanted, result):
    import websockets

    async with websockets.connect(ws_url, max_size=256 * 1024 * 1024) as ws:
        cdp = Cdp(ws)
        reader_task = asyncio.create_task(cdp.reader())
        await cdp.send("Page.enable")
        await cdp.send("Runtime.enable")

        # 章节列表 API 的响应是**加密**的（body 只有一个 `e` 字段），页面上
        # 每一话的 id 又不存在 DOM 里 —— 所以不走列表，直接"从最新一话倒着
        # 点上一章"。这条路只要一个已知入口 URL 就能把 N 话补齐。
        chapter_url = args.start_url
        print(f"[入口] {chapter_url}")
        await cdp.send("Page.navigate", {"url": chapter_url})
        await wait_ready(cdp, 50)

        for number in sorted(wanted, reverse=True):
            actual = await chapter_number_on_page(cdp)
            if actual != number:
                print(f"  ⚠️ 期望第 {number} 话，页面是第 {actual} 话 —— 停止（不硬凑）")
                break
            entry = {
                "number": number,
                "url": await cdp.evaluate("location.href"),
                "dir": chapter_dir_name(number),
                "images": 0,
                "failed": 0,
            }
            print(f"  Ch.{number} → {entry['dir']}")
            if not args.apply:
                urls = await fetch_chapter_images(cdp, entry["url"])
                entry["images"] = len(urls)
                entry["sample"] = urls[0] if urls else ""
            else:
                urls = await fetch_chapter_images(cdp, entry["url"])
                entry["images"] = len(urls)
                result["totalImages"] += len(urls)
                target = os.path.join(LIBRARY, TITLE_DIR, entry["dir"])
                failures = download_images(urls, target)
                entry["failed"] = len(failures)
                result["totalFailed"] += len(failures)
                print(f"    → 落盘 {len(urls) - len(failures)}/{len(urls)} 张")
            result["chapters"].append(entry)

            if number == min(wanted):
                break
            previous = await goto_previous_chapter(cdp)
            if not previous:
                print("  ⚠️ 找不到'上一章'按钮，停止")
                break
            chapter_url = previous
        reader_task.cancel()


if __name__ == "__main__":
    sys.exit(main())
