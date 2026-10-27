#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""comix.to 标题页探针：拿到一本书的**全部章节链接**与最新一话 URL。

## 为什么不用章节列表 API

`/api/v1/manga/{hid}/chapters` 的响应体是**加密**的（只有一个 `e` 字段），
纯 HTTP 拿不到明文。既有下载器（`tools/comix_to_download.py`）的做法是"从最新
一话倒着点上一章"，但那需要**已知**最新一话的 URL —— 所以先要一个探针把标题页
上的章节链接抠出来。

标题页的 SPA 会把章节列表渲染成 DOM 里的 `<a href*="chapter-">`，所以直接读
DOM 就行（不需要解密 API）。

用法：
    python -u tools/comix_probe.py --title 36d0-the-archdukes-fabulous-fake-marriage \
        [--json builds/comix_probe.json]
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

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
)

JS_CHAPTER_LINKS = r"""
(function () {
  var out = [];
  document.querySelectorAll('a[href*="chapter-"]').forEach(function (a) {
    var m = /chapter-(\d+)/.exec(a.getAttribute('href') || '');
    if (!m) return;
    out.push({ number: parseInt(m[1], 10), href: a.href, text: (a.innerText || '').trim() });
  });
  return JSON.stringify(out);
})()
"""


JS_API_CHAPTERS = r"""
(async function () {
  // 章节 API 的 `_=` token 是 SPA 现算的 ⇒ 复用页面上**已经发过**的那个请求 URL。
  var entries = performance.getEntriesByType('resource').filter(function (e) {
    return e.name.indexOf('/chapters') >= 0 && e.name.indexOf('_=') >= 0;
  });
  var apiUrl = entries.length ? entries[entries.length - 1].name : null;
  if (!apiUrl) {
    var tab = document.querySelector('[class*="episode"], [class*="chapter"], .mchap-list');
    if (tab) { try { tab.click(); } catch (e) {} }
    await new Promise(function (r) { setTimeout(r, 2500); });
    entries = performance.getEntriesByType('resource').filter(function (e) {
      return e.name.indexOf('/chapters') >= 0 && e.name.indexOf('_=') >= 0;
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

JS_TITLE_INFO = r"""
(function () {
  var t = document.querySelector('h1');
  var tags = Array.prototype.map.call(
    document.querySelectorAll('a[href*="/tag/"]'), function (a) {
      return (a.innerText || '').trim();
    });
  var auth = Array.prototype.map.call(
    document.querySelectorAll('a[href*="/author/"]'), function (a) {
      return (a.innerText || '').trim();
    });
  return JSON.stringify({
    title: t ? (t.innerText || '').trim() : '',
    tags: tags,
    authors: auth,
    body: (document.body ? document.body.innerText : '').slice(0, 4000)
  });
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
        "--window-size=1400,1000",
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
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=2) as resp:
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


JS_SCROLL = r"""
(function () {
  window.scrollTo(0, document.body.scrollHeight);
  // 有些站的章节列表在**内部滚动容器**里，滚 window 不动 ⇒ 全部可滚动容器也滚一遍。
  var moved = 0;
  document.querySelectorAll('*').forEach(function (el) {
    if (el.scrollHeight > el.clientHeight + 200 && el.clientHeight > 200) {
      el.scrollTop = el.scrollHeight;
      moved++;
    }
  });
  return { height: document.body.scrollHeight, containers: moved };
})
"""


async def probe(ws_url, url, settle, scroll_rounds=0):
    import websockets

    async with websockets.connect(ws_url, max_size=256 * 1024 * 1024) as ws:
        cdp = Cdp(ws)
        reader_task = asyncio.create_task(cdp.reader())
        await cdp.send("Page.enable")
        await cdp.send("Runtime.enable")
        await cdp.send("Page.navigate", {"url": url})
        deadline = time.time() + settle
        links = []
        info = {}
        while time.time() < deadline:
            await asyncio.sleep(2.0)
            raw = await cdp.evaluate(JS_CHAPTER_LINKS)
            try:
                links = json.loads(raw or "[]")
            except (TypeError, ValueError):
                links = []
            if links:
                break
        # 章节列表在 DOM 里是**分页**的（首屏只挂最新几话）⇒ 走页面内 fetch
        # 复用 SPA 的章节 API（带它现算的 `_=` token），一次把全部页翻完。
        if scroll_rounds:
            try:
                raw = await cdp.evaluate(JS_API_CHAPTERS)
                payload = json.loads(raw or "{}")
            except (TypeError, ValueError):
                payload = {}
            items = payload.get("items") or []
            if items:
                links = []
                for it in items:
                    url = it.get("url") or ""
                    m = re.search(r"chapter-(\d+)", url)
                    if not m:
                        continue
                    links.append(
                        {
                            "number": int(m.group(1)),
                            "href": url if url.startswith("http") else "https://comix.to" + url,
                            "text": "Ch.%s" % m.group(1),
                            "group": it.get("groups") or it.get("group") or "",
                        }
                    )
                print("  API 取到 %d 条章节" % len(links), flush=True)
        # 章节列表是**懒加载**的：首屏只有最新几话，滚动才把更早的挂上来。
        seen = {item["href"] for item in links}
        for _ in range(scroll_rounds):
            await cdp.evaluate(JS_SCROLL)
            await asyncio.sleep(1.4)
            raw = await cdp.evaluate(JS_CHAPTER_LINKS)
            try:
                fresh = json.loads(raw or "[]")
            except (TypeError, ValueError):
                fresh = []
            added = [item for item in fresh if item["href"] not in seen]
            if not added:
                break
            for item in added:
                seen.add(item["href"])
            links.extend(added)
            print("  +%d links (total %d)" % (len(added), len(links)), flush=True)
        raw = await cdp.evaluate(JS_TITLE_INFO)
        try:
            info = json.loads(raw or "{}")
        except (TypeError, ValueError):
            info = {}
        reader_task.cancel()
        return links, info


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--title", required=True, help="标题 slug，如 36d0-the-archdukes-fabulous-fake-marriage")
    ap.add_argument("--port", type=int, default=9341)
    ap.add_argument("--proxy", default="http://127.0.0.1:7890")
    ap.add_argument("--settle", type=int, default=60)
    ap.add_argument(
        "--scroll",
        type=int,
        default=0,
        help="额外滚动多少轮来加载懒加载的章节列表（0 = 只取首屏）",
    )
    ap.add_argument(
        "--profile",
        default=os.path.join(os.environ.get("TEMP", "."), "comix_probe_profile"),
    )
    ap.add_argument("--json", default="builds/comix_probe.json")
    args = ap.parse_args()

    url = "https://comix.to/title/%s" % args.title
    os.makedirs(args.profile, exist_ok=True)
    proc = start_chrome(args.port, args.proxy, args.profile)
    try:
        pages = wait_targets(args.port)
        links, info = asyncio.run(
            probe(
                pages[0]["webSocketDebuggerUrl"],
                url,
                args.settle,
                args.scroll,
            )
        )
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()

    numbers = sorted({item["number"] for item in links})
    result = {
        "url": url,
        "title": info.get("title", ""),
        "tags": info.get("tags", []),
        "authors": info.get("authors", []),
        "chapterCount": len(links),
        "numbers": numbers,
        "latest": links[-1] if links else None,
        "links": links,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.json)), exist_ok=True)
    with open(args.json, "w", encoding="utf-8") as fh:
        json.dump(result, fh, ensure_ascii=False, indent=1)
    print("title    :", result["title"])
    print("tags     :", ", ".join(result["tags"]))
    print("authors  :", ", ".join(result["authors"]))
    print("chapters :", len(links), "links; numbers", numbers[:5], "...", numbers[-5:] if numbers else [])
    if links:
        print("latest   :", links[-1]["href"])
    print("->", args.json)


if __name__ == "__main__":
    sys.exit(main())
