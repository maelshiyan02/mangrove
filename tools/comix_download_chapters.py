#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""按**章节清单**从 comix.to 下载（英文版补章用）。

## 与 `tools/comix_to_download.py` 的差别

老工具是"从最新一话倒着点上一章"（`aria-label="Previous chapter"`）。这条路
有两个硬伤：

1. comix.to 的一话里混着 **Side Story**（番外）条目，它们的 `document.title` 是
   `Side Story 10` 而不是 `Ch.N` ⇒ 老工具的"话号对不上就停"会**在第一个番外
   处停下**，后面几十话全下不到。
2. 倒着走只能拿到一条链，某一环被墙就会断。

所以这里改成：**先从标题页把章节链接全抓出来**（`tools/comix_probe.py`，滚动
加载），再**按话号正序**逐章访问下载。

## 章节图怎么收

comix.to 的阅读器是**虚拟列表**：滚动只挂出当前屏一两张图。真正能一次点亮
全部的是进度条上的 `[aria-label="Go to page N"]` 按钮（点它 = 跳到第 N 页并
挂图）。所以注入 `MutationObserver` 收 `src` + 并行点遍所有页按钮，比滚轮快一
个数量级。

## 落盘

* 漫画根：`<ComicLibrary>/downloads/<漫画目录名>/`
* 章节目录：`<话号> [<站点标签>]`，站点标签 `comix.to`
* 页文件：`<顺序号>.webp`，从 0 开始（与 App 的本地漫画扫描器一致）

用法：
    python -u tools/comix_download_chapters.py \
        --list test-materials/runs/comix_probe_archduke.json \
        --title-dir "那個大公的華麗婚姻騙局 · 英文版" --from 70 --to 127 \
        [--apply] [--json test-materials/runs/comix_dl_archduke.json]
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

SITE_TAG = "comix.to"

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
        return await asyncio.wait_for(future, timeout=180)

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


async def wait_ready(cdp, seconds=60):
    deadline = time.time() + seconds
    while time.time() < deadline:
        await asyncio.sleep(1.2)
        info = await cdp.evaluate(
            "({len: (document.body && document.body.innerText || '').length,"
            " blocked: (document.body && document.body.innerText || '')"
            ".indexOf('Third-party') >= 0})"
        )
        if info and info.get("blocked"):
            raise RuntimeError("comix.to 判定本次会话为第三方应用（503），请等冷却或换出口")
        if info and info.get("len", 0) > 200:
            return
    raise RuntimeError("页面迟迟没有正文（WAF/网络问题）")


async def collect_images(cdp, chapter_url):
    await cdp.send("Page.navigate", {"url": chapter_url})
    await wait_ready(cdp, 60)
    counts = await cdp.evaluate(JS_IMAGES_SETUP)
    last, stable = -1, 0
    deadline = time.time() + 90
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
    try:
        urls = json.loads(raw or "[]")
    except (TypeError, ValueError):
        urls = []
    label = counts if isinstance(counts, dict) else {}
    return urls, label


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
        path = os.path.join(target_dir, "%d.webp" % index)
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


def pick_chapters(links, start, end):
    """每个话号取**第一条**（DOM 顺序 = 站点推荐序），且必须是正文话。

    🔴 番外（`Side Story N`）与正文**共用话号**，所以只认标题以 `Ch.` 开头的
    那些 —— 否则会把番外当成正文那一话（图片内容完全不是一回事）。
    """
    by_number = {}
    for item in links:
        number = item.get("number")
        if number is None:
            continue
        if number < start or number > end:
            continue
        text = (item.get("text") or "").strip()
        if not re.match(r"^Ch\.\s*\d+", text):
            continue
        by_number.setdefault(number, item)
    return [by_number[n] for n in sorted(by_number)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", default="", help="comix_probe.py 出来的 JSON")
    ap.add_argument(
        "--url-template",
        default="",
        help="章节 URL 模板：含 {id} 与 {n}，例如 "
        "https://comix.to/title/36d0-xxx/{id}-chapter-{n}",
    )
    ap.add_argument(
        "--id-base",
        type=int,
        default=0,
        help="基准话的章节 id（配合 --id-num 反推其余章的 id）",
    )
    ap.add_argument("--id-num", type=int, default=0, help="基准话的话号")
    ap.add_argument("--title-dir", required=True)
    ap.add_argument("--from", dest="start", type=int, default=1)
    ap.add_argument("--to", dest="end", type=int, default=99999)
    ap.add_argument("--port", type=int, default=9342)
    ap.add_argument("--proxy", default="http://127.0.0.1:7890")
    ap.add_argument(
        "--profile",
        default=os.path.join(os.environ.get("TEMP", "."), "comix_dl_chapters_profile"),
    )
    ap.add_argument(
        "--library",
        default=os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "ComicLibrary",
            "downloads",
        ),
    )
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--json", default="builds/comix_download_chapters.json")
    args = ap.parse_args()

    probe = {"title": "", "links": []}
    if args.list:
        with open(args.list, encoding="utf-8") as fh:
            probe = json.load(fh)
    chapters = pick_chapters(probe.get("links") or [], args.start, args.end)
    if args.url_template:
        # 🔴 章节 API 的 `_=` token **绑定完整 query**（改 limit 就 403），所以
        # 不能靠翻页 API 拿全部章节。但 comix.to 的**主分组**章节 id 是**连续
        # 序列**（127→…606、126→…605…），用基准话反推就能得到任意一章的 URL。
        chapters = []
        for number in range(args.start, args.end + 1):
            chapter_id = args.id_base - (args.id_num - number)
            chapters.append(
                {
                    "number": number,
                    "href": args.url_template.format(id=chapter_id, n=number),
                    "text": "Ch.%d" % number,
                }
            )
    print("选中 %d 话（%s - %s）" % (len(chapters), args.start, args.end), flush=True)
    if not chapters:
        raise SystemExit("没有选中任何章节")

    os.makedirs(args.profile, exist_ok=True)
    proc = start_chrome(args.port, args.proxy, args.profile)
    result = {
        "title": probe.get("title", ""),
        "titleDir": args.title_dir,
        "chapters": [],
        "totalImages": 0,
        "totalFailed": 0,
    }
    try:
        pages = wait_targets(args.port)
        asyncio.run(_run(args, pages[0]["webSocketDebuggerUrl"], chapters, result))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()

    os.makedirs(os.path.dirname(os.path.abspath(args.json)), exist_ok=True)
    with open(args.json, "w", encoding="utf-8") as fp:
        json.dump(result, fp, ensure_ascii=False, indent=1)
    print(
        "[汇总] 章节 %d / 图片 %d / 失败 %d → %s"
        % (
            len(result["chapters"]),
            result["totalImages"],
            result["totalFailed"],
            args.json,
        )
    )


async def _run(args, ws_url, chapters, result):
    import websockets

    async with websockets.connect(ws_url, max_size=256 * 1024 * 1024) as ws:
        cdp = Cdp(ws)
        reader_task = asyncio.create_task(cdp.reader())
        await cdp.send("Page.enable")
        await cdp.send("Runtime.enable")

        for item in chapters:
            number = item["number"]
            dir_name = "%d [%s]" % (number, SITE_TAG)
            entry = {"number": number, "url": item["href"], "dir": dir_name}
            try:
                urls, label = await collect_images(cdp, item["href"])
            except Exception as exc:  # noqa: BLE001
                entry["error"] = str(exc)
                result["chapters"].append(entry)
                print("  Ch.%d FAIL %s" % (number, exc), flush=True)
                continue
            entry["images"] = len(urls)
            entry["pageButtons"] = label.get("pageButtons")
            result["totalImages"] += len(urls)
            if args.apply:
                target = os.path.join(args.library, args.title_dir, dir_name)
                failures = download_images(urls, target)
                entry["failed"] = len(failures)
                result["totalFailed"] += len(failures)
                print(
                    "  Ch.%d → %d 张（失败 %d）" % (number, len(urls), len(failures)),
                    flush=True,
                )
            else:
                print("  Ch.%d → %d 张" % (number, len(urls)), flush=True)
            result["chapters"].append(entry)
        reader_task.cancel()


if __name__ == "__main__":
    sys.exit(main())
