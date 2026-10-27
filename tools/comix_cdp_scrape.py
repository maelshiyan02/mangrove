# -*- coding: utf-8 -*-
"""用真 Chrome（CDP）+ 滚动加载，抓 comix.to 的章节链接与章节图片 URL。

## 为什么不是纯 HTTP

comix.to 是 SPA：首屏 HTML 只有壳，章节列表/图片都是渲染后才挂到 DOM 上的，
而且图片是**懒加载**（滚动一屏挂一屏）。纯 HTTP 只能拿到 `<title>`。
站内 WAF 也认浏览器指纹。所以用 `--dump-dom` 那类一次性渲染不够，必须
让页面滚到底、再把 DOM 读出来。

## 用法

    # 标题页 → 全部章节链接（含 153-157）
    python -u tools/comix_cdp_scrape.py --mode links \\
        --url "https://comix.to/title/ll82v-regressor-of-the-fallen-family" \\
        --out builds/comix_links.json

    # 章节页 → 全部图片 URL（按页码升序）
    python -u tools/comix_cdp_scrape.py --mode images \\
        --url "https://comix.to/title/ll82v-a-flame-reborn/11550660-chapter-157" \\
        --out builds/comix_ch157.json
"""

import argparse
import asyncio
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

CHROME_CANDIDATES = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
]

# 在页面里跑：把懒加载图与章节链接一次性收集齐。
JS_COLLECT = r"""
(function () {
  var images = [];
  document.querySelectorAll('img').forEach(function (img) {
    var src = img.getAttribute('src') || img.getAttribute('data-src') || '';
    src = (src || '').trim();
    if (!src || src.indexOf('data:') === 0) return;
    // 🔴 正文图 URL **没有扩展名**（如 https://1xx.ericlog.site/hi/<token>）。
    // 靠 `.jpg|.webp` 判一张都留不下 —— 用 alt（`Page N`）+ class 判。
    var cls = img.className || '';
    var alt = img.getAttribute('alt') || '';
    var m = /(\d+)/.exec(alt);
    var isPage = cls.indexOf('rpage') >= 0 || /^Page\s+\d+/i.test(alt);
    if (!isPage) return;
    images.push({ src: src, alt: alt, page: m ? parseInt(m[1], 10) : null,
                  cls: cls });
  });
  var links = [];
  document.querySelectorAll('a[href*="/chapter-"]').forEach(function (a) {
    var m = /\/title\/([^/]+)\/(\d+)-chapter-([0-9.]+)/.exec(a.getAttribute('href') || '');
    if (!m) return;
    links.push({ hid: m[1], chapterId: m[2], number: m[3],
                 url: a.href, text: (a.textContent || '').trim().slice(0, 60) });
  });
  var all = document.querySelectorAll('img');
  return JSON.stringify({
    title: document.title,
    url: location.href,
    scrollHeight: document.documentElement.scrollHeight,
    totalImg: all.length,
    firstImg: all.length ? (all[0].outerHTML || '').slice(0, 300) : '',
    bodyLen: (document.body && document.body.innerText || '').length,
    images: images,
    links: links,
  });
})()
"""


def find_chrome():
    for path in CHROME_CANDIDATES:
        if os.path.exists(path):
            return path
    raise SystemExit("找不到 Chrome / Edge 可执行文件")


def start_chrome(port, proxy, profile, headless=True):
    args = [
        find_chrome(),
        f"--remote-debugging-port={port}",
        f"--user-data-dir={profile}",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-features=Translate,MediaRouter",
        "--window-size=1280,900",
    ]
    if headless:
        args.append("--headless=new")
        args.append("--disable-gpu")
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
        self.events = []

    async def send(self, method, params=None):
        self.counter += 1
        message_id = self.counter
        future = asyncio.get_event_loop().create_future()
        self.waiters[message_id] = future
        await self.ws.send(
            json.dumps({"id": message_id, "method": method, "params": params or {}})
        )
        return await asyncio.wait_for(future, timeout=60)

    async def reader(self):
        async for raw in self.ws:
            msg = json.loads(raw)
            if "id" in msg and msg["id"] in self.waiters:
                future = self.waiters.pop(msg["id"])
                if not future.done():
                    future.set_result(msg.get("result", {}))
            elif "method" in msg:
                self.events.append(msg)

    async def evaluate(self, expression):
        result = await self.send(
            "Runtime.evaluate",
            {"expression": expression, "returnByValue": True, "awaitPromise": True},
        )
        return result.get("result", {}).get("value")


async def scrape(ws_url, url, scroll_rounds, out_path, settle, screenshot=None, mode="links"):
    import websockets

    async with websockets.connect(ws_url, max_size=128 * 1024 * 1024) as ws:
        cdp = Cdp(ws)
        reader_task = asyncio.create_task(cdp.reader())
        await cdp.send("Page.enable")
        await cdp.send("Runtime.enable")
        await cdp.send("Page.navigate", {"url": url})
        # 站内 WAF 的挑战不一定是 403：常常先给一个空壳，JS 跑完才换真页。
        # 固定睡 N 秒会踩在空壳上（实测 6s 时 img=0、正文 0 字），所以轮询
        # 到"正文有内容"为止。
        deadline = time.time() + settle
        while time.time() < deadline:
            await asyncio.sleep(1.5)
            loaded = await cdp.evaluate(
                "({len: (document.body && document.body.innerText || '').length,"
                " imgs: document.querySelectorAll('img').length})"
            )
            if loaded and loaded.get("len", 0) > 80 and loaded.get("imgs", 0) > 0:
                break
        await asyncio.sleep(1.0)

        # 🔴 阅读器用的是**内部滚动容器**，不是 window：`documentElement.
        # scrollHeight` 恒等于视口高（实测 804），滚 window 一屏都动不了，
        # 懒加载自然只挂出前 2-3 张。这里每次找"当前最能滚的元素"往里推。
        scroll_js = r"""(() => {
          function pick() {
            let best = null;
            document.querySelectorAll('div,main,section').forEach((el) => {
              if (el.scrollHeight > el.clientHeight + 80 && el.clientHeight > 200) {
                if (!best || el.scrollHeight - el.clientHeight >
                    best.scrollHeight - best.clientHeight) {
                  best = el;
                }
              }
            });
            return best;
          }
          const el = pick();
          if (el) {
            el.scrollTop += Math.max(600, el.clientHeight * 0.9);
            return { top: el.scrollTop, height: el.scrollHeight,
                     client: el.clientHeight, atEnd:
                     el.scrollTop + el.clientHeight >= el.scrollHeight - 8 };
          }
          window.scrollBy(0, Math.max(600, window.innerHeight * 0.9));
          return { top: window.scrollY, height: document.documentElement.scrollHeight,
                   client: window.innerHeight,
                   atEnd: window.scrollY + window.innerHeight >=
                          document.documentElement.scrollHeight - 8 };
        })()"""
        if mode == "pages":
            # 🔴 comix.to 的阅读器默认是**单页模式**（一次只挂 1-3 张图，右侧浮着
            # 工具栏），长条滚动滚不出后面的页，只能一页页翻。
            #
            # 判"是否翻过去了"**不能看 alt**：翻页后 alt 会复用/缺失，靠它计数
            # 会卡在第 3 页就以为到底了（实测：只收到 3 张就退出）。改成累加
            # **当前挂着的所有 src**（全局去重、按首次出现顺序），连续多拍
            # 没有新增才收工。
            ordered_srcs = []
            seen_srcs = set()
            stale = 0
            await cdp.send("Page.bringToFront")
            for _ in range(max(80, scroll_rounds * 6)):
                batch = await cdp.evaluate(
                    "Array.from(document.querySelectorAll('img'))"
                    ".filter(i => (i.className||'').indexOf('rpage') >= 0)"
                    ".map(i => i.getAttribute('src')||'')"
                    ".filter(s => s && s.indexOf('data:') !== 0)"
                )
                added = 0
                for src in batch or []:
                    if src not in seen_srcs:
                        seen_srcs.add(src)
                        ordered_srcs.append(src)
                        added += 1
                if added:
                    stale = 0
                else:
                    stale += 1
                if stale >= 8:
                    break
                await cdp.send(
                    "Input.dispatchKeyEvent",
                    {
                        "type": "keyDown",
                        "key": "ArrowRight",
                        "code": "ArrowRight",
                        "windowsVirtualKeyCode": 39,
                        "nativeVirtualKeyCode": 39,
                    },
                )
                await cdp.send(
                    "Input.dispatchKeyEvent",
                    {
                        "type": "keyUp",
                        "key": "ArrowRight",
                        "code": "ArrowRight",
                        "windowsVirtualKeyCode": 39,
                        "nativeVirtualKeyCode": 39,
                    },
                )
                await asyncio.sleep(0.75)
            page_images = [
                {"src": src, "alt": f"Page {i + 1}", "page": i + 1}
                for i, src in enumerate(ordered_srcs)
            ]
        else:
            # 长条 / 虚拟列表模式：滚到底会**再加载一批**并撑高容器，所以
            # "atEnd 为真"不等于到底了。用「(容器高度, 已挂图片数) 连续多拍
            # 都不变」判收工，别用一拍就退。
            fingerprint = None
            frozen = 0
            for _ in range(max(60, scroll_rounds * 5)):
                state = await cdp.evaluate(scroll_js)
                await asyncio.sleep(0.7)
                gauge = await cdp.evaluate(
                    "[document.documentElement.scrollHeight,"
                    " document.querySelectorAll('img').length,"
                    " (document.body && document.body.innerText || '').length]"
                )
                current = tuple(gauge or [])
                if current == fingerprint:
                    frozen += 1
                else:
                    frozen = 0
                    fingerprint = current
                if frozen >= 10:
                    break
            page_images = None

        payload = await cdp.evaluate(JS_COLLECT)
        if mode == "pages":
            data_override = json.loads(payload)
            data_override["images"] = page_images or []
            payload = json.dumps(data_override, ensure_ascii=False)
        if screenshot:
            shot = await cdp.send("Page.captureScreenshot", {"format": "png"})
            import base64

            with open(screenshot, "wb") as fp:
                fp.write(base64.b64decode(shot["data"]))
            print(f"  截图 → {screenshot}")
        reader_task.cancel()

    if not payload:
        raise SystemExit("页面取值为空")
    data = json.loads(payload)
    images = data.get("images") or []
    # 图片：优先带页码的（正文页），按页码升序，去重
    pages = [i for i in images if i.get("page")]
    pages.sort(key=lambda i: i["page"])
    seen, ordered = set(), []
    for item in pages:
        if item["src"] in seen:
            continue
        seen.add(item["src"])
        ordered.append(item["src"])
    if not ordered:
        ordered = [i["src"] for i in images]

    links = {}
    for link in data.get("links") or []:
        links[link["number"]] = link
    ordered_links = [links[k] for k in sorted(links, key=lambda x: float(x))]

    result = {
        "source_url": data.get("url"),
        "title": data.get("title"),
        "image_count": len(ordered),
        "images": ordered,
        "chapter_count": len(ordered_links),
        "chapters": ordered_links,
    }
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fp:
        json.dump(result, fp, ensure_ascii=False, indent=2)
    print(f"[{data.get('title')}] 图片 {len(ordered)} 张 / 章节 {len(ordered_links)} 话")
    print(
        f"  [debug] img 标签 {data.get('totalImg')} 个 / 正文 {data.get('bodyLen')} 字 / "
        f"scrollHeight {data.get('scrollHeight')}"
    )
    if data.get("firstImg"):
        print(f"  [debug] 首个 img: {data['firstImg'][:200]}")
    if ordered:
        print("  首图", ordered[0][:110])
    if ordered_links:
        print("  首章", ordered_links[0]["number"], "末章", ordered_links[-1]["number"])
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        choices=["links", "images", "pages"],
        required=True,
        help="links=标题页章节链接；images=长条页滚动；pages=单页阅读器翻页",
    )
    parser.add_argument("--url", required=True)
    parser.add_argument("--port", type=int, default=9334)
    parser.add_argument("--proxy", default="http://127.0.0.1:7890")
    parser.add_argument("--rounds", type=int, default=40)
    parser.add_argument("--settle", type=float, default=40, help="等待正文出现的最长秒数")
    parser.add_argument(
        "--profile",
        default=os.path.join(os.environ.get("TEMP", "."), "comix_scrape_profile"),
        help="持久 Chrome profile（复用 Cookie，别每次从零过 WAF）",
    )
    parser.add_argument("--out", required=True)
    parser.add_argument("--screenshot", help="额外存一张 PNG，排查渲染问题用")
    args = parser.parse_args()

    # links 模式要滚很多屏（157 话分页加载），images 模式滚到章节末即可
    rounds = args.rounds if args.mode == "links" else max(12, args.rounds // 2)
    profile = args.profile
    os.makedirs(profile, exist_ok=True)
    proc = start_chrome(args.port, args.proxy, profile)
    try:
        pages = wait_targets(args.port)
        asyncio.run(
            scrape(
                pages[0]["webSocketDebuggerUrl"],
                args.url,
                rounds,
                args.out,
                args.settle,
                args.screenshot,
                args.mode,
            )
        )
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()
        # profile 故意保留：Cookie / 已过挑战的凭证要复用，否则每章都要重过一次 WAF。
    return 0


if __name__ == "__main__":
    sys.exit(main())
