"""comix.to 浏览器采集 / 批量下载工具（CDP 驱动真实 Chrome）。

为什么要有这个工具
------------------
1. 章节列表走 `/api/v1/...`，必须带签名 token（缺 token = `missing_token` 403）；
   且 token **绑定完整 query**（改任一参数 = `invalid_token`），响应体还是加密的
   `{"e":"..."}` ⇒ 不能自己拼 URL 拉数据、也不能重放。
   👉 唯一稳的路子：让站点自己的 SPA 发请求、把**渲染出来的 DOM** 读出来。
2. 图片 CDN（`static.comix.to`）**裸 HTTP 就放行**（UA + Referer，无需 cookie），
   所以拿到图片 URL 后可以脱离浏览器高并发拉取。

反爬红线（见 `.agent/memory/appendices/A07c`）
--------------------------------------------
* 一次会话只做**一次**首页/详情页文档导航，之后站内翻页只点按钮（页内路由）；
* 每章阅读页必须一次文档导航（无法避免），失败**不重试、不重载**；
* 命中 `Third-party apps` / `Just a moment` 立刻停手，别硬刷。

透明广告页
----------
阅读器会注入透明广告页（`.rpage-page` 里 canvas 极小 / img 是 1x1）：
判据 = canvas.toDataURL 长度 < AD_CANVAS_MAX_CHARS 或 naturalWidth <= 10 → 跳过。

运行环境（🔴 别用错解释器）
--------------------------
本机 `python` 默认指向 WorkBuddy 自带的 3.13（裸环境，**没有 requests**），
装了 `requests` + `websockets` 的是 **Python 3.12**：
     py -3.12 tools/comix_browser_dl.py download ...
用错解释器会直接 `ModuleNotFoundError: No module named 'requests'`。

子命令
------
  chapters <hid>                  列出全部章节（DOM 翻页聚合）→ chapters.json
  probe    <hid> <cid> <num>      探测单章页数与取图方式
  download <hid> [--numbers ...]  下载章节到 --out 目录
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
import random
import re
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import urlparse

import requests

CHROME_CANDIDATES = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "builds", "mangrove", "chrome-win64", "chrome.exe",
    ),
]

PROXY = os.environ.get("COMIX_PROXY", "127.0.0.1:7890")
PORT = int(os.environ.get("COMIX_CDP_PORT", "9333"))
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)
IMG_HEADERS = {"User-Agent": UA, "Referer": "https://comix.to/"}
AD_CANVAS_MAX_CHARS = 20000


def log(msg: str) -> None:
    print(f"[comix] {msg}", flush=True)


# ---------------------------------------------------------------------------
# 极简 CDP 客户端
# ---------------------------------------------------------------------------


class CDP:
    """带**独立读循环**的极简 CDP 客户端。

    🔴 为什么不能"发一条 → 就地 recv 等结果"：那种写法一旦某次 `recv` 超时被
    `asyncio.wait_for` 取消，websocket 的分帧就乱了，之后所有 `recv` **永久挂住**
    （实测表现为"导航成功后就再没有任何输出，进程被 timeout 杀掉"）。
    改成单一读循环 + Future 派发后，取消只作用于 Future，连接不再被破坏。
    """

    def __init__(self, ws):
        self.ws = ws
        self._id = 0
        self._pending: dict[int, asyncio.Future] = {}
        self.events: list[dict] = []
        self._reader: asyncio.Task | None = None
        self._closed = False

    def start(self):
        self._reader = asyncio.create_task(self._read_loop())

    async def _read_loop(self):
        try:
            async for raw in self.ws:
                msg = json.loads(raw)
                mid = msg.get("id")
                if mid is not None and mid in self._pending:
                    fut = self._pending.pop(mid)
                    if not fut.done():
                        fut.set_result(msg)
                else:
                    self.events.append(msg)
        except Exception:
            pass
        finally:
            self._closed = True
            for fut in self._pending.values():
                if not fut.done():
                    fut.set_exception(RuntimeError("CDP 连接已断开"))
            self._pending.clear()

    async def send(self, method: str, params: dict | None = None,
                   session: str | None = None, timeout: float = 60):
        if self._closed:
            raise RuntimeError("CDP 连接已断开")
        self._id += 1
        mid = self._id
        msg = {"id": mid, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        fut = asyncio.get_running_loop().create_future()
        self._pending[mid] = fut
        await self.ws.send(json.dumps(msg))
        resp = await asyncio.wait_for(asyncio.shield(fut), timeout=timeout)
        if "error" in resp:
            raise RuntimeError(f"{method}: {resp['error']}")
        return resp.get("result", {})

    async def wait_event(self, method: str, timeout: float = 30) -> dict | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for ev in self.events:
                if ev.get("method") == method:
                    self.events.remove(ev)
                    return ev
            await asyncio.sleep(0.15)
        return None

    async def eval(self, expression: str, session: str, await_promise: bool = False,
                   timeout: float = 30):
        res = await self.send(
            "Runtime.evaluate",
            {
                "expression": expression,
                "returnByValue": True,
                "awaitPromise": await_promise,
                "userGesture": True,
            },
            session=session,
            timeout=timeout,
        )
        if res.get("exceptionDetails"):
            det = res["exceptionDetails"]
            raise RuntimeError(
                f"JS exception: {det.get('text')} "
                f"{det.get('exception', {}).get('description', '')}"
            )
        return res.get("result", {}).get("value")


class Browser:
    def __init__(self, headless: bool = True, profile: str | None = None):
        self.headless = headless
        # 每次运行用**全新** profile：复用旧 profile 会把阅读器拖进"导航后不出页"
        # 的坏状态（实测同一 profile 第二次跑就 120s 白等，换新 profile 立刻 4s 就绪）。
        self.profile = profile or os.path.join(
            tempfile.gettempdir(), f"comix_prof_{int(time.time())}_{os.getpid()}"
        )
        self.proc: subprocess.Popen | None = None
        self.cdp: CDP | None = None
        self.session: str | None = None
        self._ws = None

    def _chrome(self) -> str:
        for c in CHROME_CANDIDATES:
            if c and os.path.isfile(c):
                return c
        raise SystemExit("找不到 chrome.exe")

    async def __aenter__(self):
        Path(self.profile).mkdir(parents=True, exist_ok=True)
        args = [
            self._chrome(),
            f"--remote-debugging-port={PORT}",
            f"--user-data-dir={self.profile}",
            f"--proxy-server={PROXY}",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-blink-features=AutomationControlled",
            "--window-size=1280,960",
            "about:blank",
        ]
        if self.headless:
            args.insert(1, "--headless=new")
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        ws_url = None
        for _ in range(80):
            try:
                r = requests.get(f"http://127.0.0.1:{PORT}/json/version", timeout=1)
                ws_url = r.json().get("webSocketDebuggerUrl")
                if ws_url:
                    break
            except Exception:
                pass
            await asyncio.sleep(0.4)
        if not ws_url:
            raise SystemExit("Chrome CDP 端口未就绪")

        import websockets

        self._ws = await websockets.connect(ws_url, max_size=96 * 1024 * 1024)
        self.cdp = CDP(self._ws)
        self.cdp.start()
        target = await self.cdp.send("Target.createTarget", {"url": "about:blank"})
        attached = await self.cdp.send(
            "Target.attachToTarget", {"targetId": target["targetId"], "flatten": True}
        )
        self.session = attached["sessionId"]
        await self.cdp.send("Page.enable", session=self.session)
        await self.cdp.send("Runtime.enable", session=self.session)
        # 文档级补丁：拦 img.src setter，把失败加载的页 URL 也留下来
        await self.cdp.send(
            "Page.addScriptToEvaluateOnNewDocument",
            {"source": SRC_PATCH_JS, "runImmediately": True},
            session=self.session,
        )
        # ⚠️ 这里**故意不注入** `reader.default.preload='all'`：实测预加载全章会把
        # 阅读器主线程拖住（导航后 120s 都不出 `.rpage-page`）。按视口懒加载 +
        # 我们自己的滚动收集，95 页只要 ~5s。
        return self

    async def __aexit__(self, *exc):
        try:
            if self.cdp:
                await self.cdp.send("Browser.close")
        except Exception:
            pass
        try:
            if self._ws:
                await self._ws.close()
        except Exception:
            pass
        if self.proc:
            try:
                self.proc.wait(timeout=8)
            except Exception:
                self.proc.kill()

    async def goto(self, url: str, ready_js: str, timeout: float = 90.0, label: str = ""):
        try:
            await self.cdp.send("Page.navigate", {"url": url}, session=self.session,
                                timeout=30)
        except Exception as e:
            raise RuntimeError(f"{label or url} 导航失败 {type(e).__name__}") from e
        # 等 load 事件（有就读掉，没有也不阻塞太久）
        await self.cdp.wait_event("Page.loadEventFired", timeout=20)
        deadline = time.monotonic() + timeout
        last = ""
        while time.monotonic() < deadline:
            try:
                title = await self.cdp.eval("document.title", self.session, timeout=20)
                if title and "just a moment" in str(title).lower():
                    raise RuntimeError("命中 Cloudflare 挑战页（不要重载，等会话）")
                if title and "Third-party" in str(title):
                    raise RuntimeError("命中 comix Third-party 拦截（会话被标记）")
                ready = await self.cdp.eval(ready_js, self.session, timeout=20)
                if ready:
                    return True
                last = f"not-ready({ready})"
            except RuntimeError:
                raise
            except Exception as e:
                last = f"{type(e).__name__}"
            await asyncio.sleep(0.5)
        raise RuntimeError(f"{label or url} 未就绪（{last}）")

    async def initial_data(self, hid: str) -> dict:
        """读详情页 `#initial-data`：节点存在 ≠ 内容完整（脚本渐进写入）。"""
        slug = hid
        await self.goto(
            f"https://comix.to/title/{slug}",
            "Boolean(document.getElementById('initial-data'))",
            label=slug,
        )
        deadline = time.monotonic() + 40
        last = ""
        while time.monotonic() < deadline:
            raw = await self.cdp.eval(
                "document.getElementById('initial-data') ? "
                "document.getElementById('initial-data').textContent : null",
                self.session,
            )
            if raw:
                try:
                    data = json.loads(raw)
                except Exception as e:
                    last = f"{type(e).__name__}@{len(raw)}B"
                else:
                    if isinstance(data, dict) and isinstance(data.get("queries"), dict):
                        return data
                    last = "no queries"
            await asyncio.sleep(0.4)
        raise RuntimeError(f"initial-data 未完整（{last}）")


# ---------------------------------------------------------------------------
# DOM 脚本
# ---------------------------------------------------------------------------

SCRAPE_ROWS_JS = r"""
(() => {
  const rows = Array.from(document.querySelectorAll('.mchap-item')).map(li => {
    const a = li.querySelector('.mchap-row__primary');
    const ch = li.querySelector('.mchap-row__ch');
    const ti = li.querySelector('.mchap-row__title');
    const gp = li.querySelector('.mchap-row__group span');
    return {
      href: a ? a.getAttribute('href') : null,
      label: ch ? ch.textContent.trim() : null,
      title: ti ? ti.textContent.trim() : '',
      group: gp ? gp.textContent.trim() : ''
    };
  });
  return JSON.stringify(rows);
})()
"""


def parse_row(row: dict) -> dict | None:
    href = row.get("href") or ""
    m = re.search(r"/(\d+)-chapter-(.+?)/?$", href)
    if not m:
        return None
    return {
        "chapter_id": int(m.group(1)),
        "number": m.group(2),
        "label": row.get("label") or f"Ch.{m.group(2)}",
        "title": row.get("title") or "",
        "group": (row.get("group") or "").strip() or "Unknown",
        "href": href,
    }


async def scrape_all_rows(br: "Browser", per_page_wait: float = 1.4) -> list[dict]:
    """在详情页内点 `.npager__nav`（下一页）把章节行读全 —— 只做页内点击，不发起文档导航。

    站点章节列表是 `20 条/页` 的客户端分页（`mchap-foot` 会写 "Showing 1 to 20 of 476 items"）。
    476 = **所有翻译组版本的条目总数**，同一话号会有多条。
    """
    seen: dict[int, dict] = {}
    total_expected = await br.cdp.eval(
        "(() => {const f = document.querySelector('.mchap-foot');"
        "const m = f ? f.textContent.match(/of\\s+(\\d+)/) : null;"
        "return m ? Number(m[1]) : 0;})()",
        br.session,
    )
    log(f"站点声明条目总数：{total_expected}")

    async def grab() -> list[dict]:
        return json.loads(await br.cdp.eval(SCRAPE_ROWS_JS, br.session) or "[]")

    async def active_page() -> int:
        v = await br.cdp.eval(
            "(() => {const a = document.querySelector('.npager__num.is-active');"
            "return a ? Number(a.textContent.trim()) : 0;})()",
            br.session,
        )
        return int(v or 0)

    # 章节列表是 SPA 水合后才渲染的：必须等行出现（必要时滚一下促发懒加载）
    deadline = time.monotonic() + 45
    rows: list[dict] = []
    while time.monotonic() < deadline:
        rows = await grab()
        if rows:
            break
        await br.cdp.eval("window.scrollBy(0, 900)", br.session)
        await asyncio.sleep(1.0)
    if not rows:
        raise RuntimeError("章节列表始终为空（SPA 未渲染 .mchap-item）")

    async def scrape_current(rows: list[dict]) -> int:
        added = 0
        for r in rows:
            parsed = parse_row(r)
            if parsed and parsed["chapter_id"] not in seen:
                seen[parsed["chapter_id"]] = parsed
                added += 1
        return added

    # 分页器是「8 个数字 + 前后导航」的滑窗。按**目标页号**驱动，每步校验 is-active，
    # 而不是盲点"下一页"——盲点会让窗口滑回去、相邻页反复抓同一批行（实测死循环）。
    target = 1
    stalls = 0
    for _ in range(60):
        cur = await active_page()
        if cur != target:
            clicked = await br.cdp.eval(
                "(() => {const want = %d;"
                "const num = Array.from(document.querySelectorAll('.npager__num'))"
                ".find(b => Number(b.textContent.trim()) === want);"
                "if (num) { num.click(); return 'num'; }"
                "const navs = Array.from(document.querySelectorAll('.npager__nav'));"
                "if (!navs.length) return '';"
                "const next = navs[navs.length - 1];"
                "if (next.disabled) return '';"
                "next.click(); return 'nav';})()" % target,
                br.session,
            )
            if not clicked:
                log(f"  目标页 {target} 不可达，停止")
                break
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                await asyncio.sleep(0.35)
                if await active_page() == target:
                    break
            else:
                await asyncio.sleep(0.6)

        rows = await grab()
        added = await scrape_current(rows)
        log(f"  page {await active_page()}: {len(rows)} 行，新增 {added}，累计 {len(seen)}")
        if total_expected and len(seen) >= total_expected:
            break
        if added == 0:
            stalls += 1
            if stalls >= 3:
                log("  连续 3 页无新增，判定已到末尾")
                break
        else:
            stalls = 0
        target = max(target, await active_page()) + 1

    return sorted(
        seen.values(),
        key=lambda x: (chapter_number_value(x["number"]), x["group"]),
    )


# ---------------------------------------------------------------------------
# 阅读器取页
# ---------------------------------------------------------------------------

PAGE_COUNT_JS = "document.querySelectorAll('.rpage-page').length > 0"

# 🔴 文档级补丁（必须 `Page.addScriptToEvaluateOnNewDocument` 注入，早于页面脚本）。
# 阅读器把图片真实地址直接写进 `img.src`：**加载失败时 `src` 属性会被清空、
# `naturalWidth` 归零**，但 setter 明明被调用过。所以拦 `src` setter，把每次赋的
# 值记到元素私有字段 `__srcVal` 上 ⇒ 无论这张图最终成功还是
# `net::ERR_HTTP2_PROTOCOL_ERROR` 失败，我们都能把该页 URL 收回来、
# 交给 python 侧自己重试下载。
SRC_PATCH_JS = r"""
(() => {
  try {
    const d = Object.getOwnPropertyDescriptor(HTMLImageElement.prototype, 'src');
    if (!d || !d.set) return;
    Object.defineProperty(HTMLImageElement.prototype, 'src', {
      configurable: true,
      enumerable: d.enumerable,
      get() { return d.get.call(this); },
      set(v) {
        try {
          const s = String(v);
          if (s && !s.startsWith('data:')) { this.__srcVal = s; (window.__imgLog = window.__imgLog || []).push(s); }
        } catch (e) {}
        return d.set.call(this, v);
      },
    });
  } catch (e) {}
})();
"""

PROBE_JS = r"""
(() => {
  const nodes = Array.from(document.querySelectorAll('.rpage-page'));
  return JSON.stringify({
    count: nodes.length,
    rows: nodes.map((el, i) => {
      const c = el.querySelector('canvas');
      const img = el.querySelector('img');
      let kind = 'none';
      if (c && c.width > 10 && c.height > 10) kind = 'canvas';
      else if (img && img.src) kind = 'img';
      return {
        i, page: el.getAttribute('data-page'), kind,
        loading: el.classList.contains('is-loading'),
        w: c ? c.width : (img ? img.naturalWidth : 0),
        h: c ? c.height : (img ? img.naturalHeight : 0),
        src: img && img.src ? img.src.slice(0, 120) : null
      };
    })
  });
})()
"""

EXTRACT_PAGE_JS = r"""
(async (idx) => {
  const el = document.querySelectorAll('.rpage-page')[idx];
  if (!el) return JSON.stringify({ok: false, reason: 'no-node'});
  el.scrollIntoView({behavior: 'instant', block: 'center'});
  const loading = () => el.classList.contains('is-loading');
  const deadline = Date.now() + 25000;
  while (Date.now() < deadline) {
    const c = el.querySelector('canvas');
    if (c && c.width > 10 && c.height > 10 && !loading()) {
      const data = c.toDataURL('image/webp', 0.95);
      if (data.length < __AD__) return JSON.stringify({ok: false, reason: 'ad'});
      return JSON.stringify({ok: true, kind: 'canvas', data});
    }
    const img = el.querySelector('img');
    if (img && img.complete && img.naturalWidth > 10) {
      const src = img.src;
      if (src.startsWith('data:')) {
        if (src.length < __AD__) return JSON.stringify({ok: false, reason: 'ad'});
        return JSON.stringify({ok: true, kind: 'canvas', data: src});
      }
      return JSON.stringify({ok: true, kind: 'img', src});
    }
    if (img && img.complete && img.naturalWidth > 0 && img.naturalWidth <= 10) {
      return JSON.stringify({ok: false, reason: 'ad'});
    }
    await new Promise(r => setTimeout(r, 250));
  }
  return JSON.stringify({ok: false, reason: 'timeout'});
})
"""

# 一次性把整章的图片 URL 收全：快速滚一遍促发懒加载 → 等所有节点就位 → 只回 URL。
# 只回 URL（不回 base64）是关键：95 页 × 200KB 的 base64 走 CDP 会把消息撑爆、
# 而且远比 python 侧并发 HTTP 慢。
COLLECT_URLS_JS = r"""
(async () => {
  const sleep = (ms) => new Promise(r => setTimeout(r, ms));
  const nodes = () => Array.from(document.querySelectorAll('.rpage-page'));
  const total = nodes().length;
  // 预加载：分段滚到文档底部，每段停留一下
  const step = Math.max(400, Math.floor(window.innerHeight * 0.9));
  for (let y = 0; y < document.body.scrollHeight + step; y += step) {
    window.scrollTo(0, y);
    await sleep(120);
  }
  // 反复扫：把所有还没出图的节点滚到视口里
  const deadline = Date.now() + 70000;
  while (Date.now() < deadline) {
    let pending = 0;
    for (const el of nodes()) {
      const img = el.querySelector('img');
      const c = el.querySelector('canvas');
      const okImg = img && img.complete && img.naturalWidth > 10;
      const okCanvas = c && c.width > 10 && c.height > 10;
      if (!okImg && !okCanvas) {
        pending += 1;
        el.scrollIntoView({behavior: 'instant', block: 'center'});
        await sleep(90);
      }
    }
    if (pending === 0) break;
    await sleep(250);
  }
  const rows = nodes().map((el, i) => {
    const img = el.querySelector('img');
    const c = el.querySelector('canvas');
    const pic = el.querySelector('picture source');
    const hasImg = img && img.complete && img.naturalWidth > 10;
    return {
      i,
      page: el.getAttribute('data-page'),
      src: hasImg ? (img.currentSrc || img.src) : null,
      w: hasImg ? img.naturalWidth : 0,
      h: hasImg ? img.naturalHeight : 0,
      canvas: (c && c.width > 10) ? [c.width, c.height] : null,
      blank: Boolean(img && img.complete && img.naturalWidth > 0 && img.naturalWidth <= 10),
      // 懒加载未触发的节点：把能拿到的「潜在真图地址」一并回传，供二轮补救
      loading: el.classList.contains('is-loading'),
      errored: el.classList.contains('is-errored'),
      srcVal: img ? (img.__srcVal || img.getAttribute('src') || null) : null,
      dataSrc: img ? (img.getAttribute('data-src') || img.getAttribute('data-original') || null) : null,
      srcset: (pic && pic.getAttribute('srcset')) || (img && img.getAttribute('srcset')) || null,
    };
  });
  return JSON.stringify({ total, rows });
})()
"""


# 🔴 二轮补救：首轮 COLLECT_URLS_JS 之后仍为 `is-loading` / naturalWidth==0 的节点，
# 不能当广告页丢弃——实测它们有正常尺寸的 `<img width=800 height=1476>`，只是懒加载
# 观察者没触发（首轮滚动步长太粗、或节点集中在中后段）。这里对这批索引做
# 「逐个滚进视口 + 广播 scroll + 改 lazy→eager + 用 data-src 主动赋值」，
# 再统一等一轮；仍未出图的，退而取 `data-src` / `srcset` 里最后的地址直接 HTTP 拉。
REPAIR_MISS_JS = r"""
(async (idxs) => {
  const sleep = (ms) => new Promise(r => setTimeout(r, ms));
  const nodes = () => Array.from(document.querySelectorAll('.rpage-page'));
  const all = nodes();
  const want = new Map();
  for (const i of idxs) want.set(i, all[i] || null);

  const isOk = (el) => {
    if (!el) return true;
    const img = el.querySelector('img');
    if (img && img.complete && img.naturalWidth > 10) return true;
    const c = el.querySelector('canvas');
    return Boolean(c && c.width > 10 && c.height > 10);
  };

  // 1) 逐个促发（快）：滚进视口 + 所有祖先广播 scroll + 懒加载降级为立即加载
  for (const [i, el] of want) {
    if (!el) continue;
    el.scrollIntoView({behavior: 'instant', block: 'center'});
    let p = el.parentElement;
    while (p) { try { p.dispatchEvent(new Event('scroll')); } catch (e) {} p = p.parentElement; }
    try { window.dispatchEvent(new Event('scroll')); } catch (e) {}
    const img = el.querySelector('img');
    if (img) {
      try { img.loading = 'eager'; } catch (e) {}
      try { img.removeAttribute('loading'); } catch (e) {}
      const ds = img.getAttribute('data-src') || img.getAttribute('data-original');
      if (ds && !img.getAttribute('src')) { try { img.src = ds; } catch (e) {} }
    }
    await sleep(70);
  }

  // 2) 统一等一轮（上限 25s），让被唤醒的请求落地
  const deadline = Date.now() + 25000;
  while (Date.now() < deadline) {
    let pending = 0;
    for (const el of want.values()) if (!isOk(el)) pending += 1;
    if (pending === 0) break;
    await sleep(300);
  }

  // 3) 汇总：出图的回真实地址，没出图的回 data-src / srcset 兜底
  const rows = [];
  for (const [i, el] of want) {
    if (!el) { rows.push({i, src: null, how: 'no-node'}); continue; }
    const img = el.querySelector('img');
    const c = el.querySelector('canvas');
    let src = null, how = 'live';
    if (img && img.complete && img.naturalWidth > 10) src = img.currentSrc || img.src;
    else if (c && c.width > 10 && c.height > 10) how = 'canvas';
    if (!src && how !== 'canvas') {
      // 优先用 setter 补丁留下的地址：加载失败也有效，python 侧可自行重试
      const sv = img && (img.__srcVal || img.getAttribute('src'));
      const ds = img && (img.getAttribute('data-src') || img.getAttribute('data-original'));
      const pic = el.querySelector('picture source');
      const ss = (pic && pic.getAttribute('srcset')) || (img && img.getAttribute('srcset'));
      if (sv) { src = sv; how = 'src-attr'; }
      else if (ds) { src = ds; how = 'data-src'; }
      else if (ss) {
        const parts = ss.split(',').map(s => s.trim().split(/\s+/)[0]).filter(Boolean);
        if (parts.length) { src = parts[parts.length - 1]; how = 'srcset'; }
      }
    }
    rows.push({
      i, src, how,
      cls: el.className,
      html: src ? null : (el.innerHTML || '').replace(/\s+/g, ' ').slice(0, 200),
    });
  }
  return JSON.stringify({rows});
})
"""


def _abs_url(u: str | None) -> str | None:
    if not u:
        return None
    u = u.strip()
    if u.startswith("//"):
        return "https:" + u
    if u.startswith("/"):
        return "https://comix.to" + u
    return u


# 阅读器预加载策略：站点把 `reader.default.preload` 存在 localStorage，
# 设成 'all' 后整章一次性拉图（否则按视口懒加载，一页一页等）。
PRELOAD_JS = r"""
try {
  const k = 'reader.default';
  const cur = JSON.parse(localStorage.getItem(k) || '{}');
  cur.preload = 'all';
  localStorage.setItem(k, JSON.stringify(cur));
} catch (e) {}
"""


# ---------------------------------------------------------------------------
# 图片落盘
# ---------------------------------------------------------------------------


_tls = threading.local()


def _session() -> requests.Session:
    """每个线程复用一条 Session。

    🔴 每张图都 `requests.get` 新建连接 = 每次重做 TCP+TLS 握手；经代理时这一项
    就能吃掉一半时间（实测 95 页 200s）。复用后同一章降到几十秒。
    """
    s = getattr(_tls, "s", None)
    if s is None:
        s = requests.Session()
        s.headers.update(IMG_HEADERS)
        _tls.s = s
    return s


def download_image(url: str, dest: Path, hosts: list[str] | None = None, retries: int = 3) -> int:
    """从图片 CDN 取一张图。

    🔴 comix 的图片 CDN 是**多域名轮换**的，而且 DOM 里给出的域名有相当一部分
    （形如 `447.xxxx.site`）对普通 HTTP 客户端直接 **403**（响应体 ~4.5KB）。
    实测**路径与域名无关**：把同一段 path 挂到该章里另一个可用域名
    （如 `c127.kkplayer.wtf`）上就能拿到**同一张图、字节数完全一致**。
    ⇒ 先打「本章主域名」，失败再回落到该图自己的域名与其它候选域名。
    """
    parsed = urlparse(url)
    path_q = url[len(f"{parsed.scheme}://{parsed.netloc}"):]
    candidates: list[str] = []
    for h in (hosts or []):
        candidates.append(f"https://{h}{path_q}")
    if url not in candidates:
        candidates.append(url)

    last = ""
    for attempt in range(retries):
        for cand in candidates:
            try:
                r = _session().get(cand, timeout=30)
                if r.status_code == 200 and len(r.content) > 1024:
                    dest.write_bytes(r.content)
                    return len(r.content)
                last = f"HTTP {r.status_code}/{len(r.content)}B @{urlparse(cand).netloc}"
            except Exception as e:
                last = f"{type(e).__name__} @{urlparse(cand).netloc}"
        if attempt < retries - 1:
            time.sleep(1.0 + attempt)
    raise RuntimeError(last or "unknown")


def save_payload(payload: dict, dest_stem: Path) -> tuple[int, str]:
    """把一页落盘，返回 (字节数, 扩展名)。"""
    if payload["kind"] == "img":
        url = payload["src"]
        for attempt in range(3):
            try:
                r = requests.get(url, headers=IMG_HEADERS, timeout=45)
                if r.status_code == 200 and len(r.content) > 1024:
                    ext = "webp" if ".webp" in url else ("png" if ".png" in url else "jpg")
                    path = dest_stem.with_suffix(f".{ext}")
                    path.write_bytes(r.content)
                    return len(r.content), ext
                raise RuntimeError(f"HTTP {r.status_code}/{len(r.content)}B")
            except Exception:
                if attempt == 2:
                    raise
                time.sleep(1.2 * (attempt + 1))
    data_url = payload["data"]
    header, _, b64 = data_url.partition(",")
    ext = "webp" if "webp" in header else "png"
    raw = base64.b64decode(b64)
    dest_stem.with_suffix(f".{ext}").write_bytes(raw)
    return len(raw), ext


def safe_dir_name(text: str) -> str:
    return re.sub(r'[\\/:*?"<>|]+', "_", text).strip()


def chapter_dir_name(ch: dict, site_tag: str = "comix.to") -> str:
    """章节文件夹命名：`<话号> [<翻译组>] [<来源站点>]`。

    为什么要带**翻译组 + 来源站点**：同一话号在 comix 上会有多个组的不同版本
    （本书 13 个组，Rokari 到 49 话、第 50 话只有 Lux Manga），只写话号会撞名，
    只写组名又分不清来源站。现有图书馆里 `116 [comix.to]` / `1 [Lua Comic]`
    两种旧写法，本函数兼容：无组名时退化为 `[来源站点]` 单标签。
    """
    num = str(ch.get("number", "")).strip()
    group = (ch.get("group") or "").strip()
    tags = [group] if group else []
    if site_tag:
        tags.append(site_tag)
    suffix = "".join(f" [{t}]" for t in tags)
    return safe_dir_name(f"{num}{suffix}")


NUM_RE = re.compile(r"(\d+(?:\.\d+)?)")


def chapter_number_value(number: str) -> float:
    m = NUM_RE.search(number or "")
    return float(m.group(1)) if m else 0.0


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


async def run(args) -> int:
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    # 🔴 下载路径**绝不要先开详情页**：实测「详情页 → 阅读页」两次文档导航会让阅读器
    # 停在 `readyState=interactive`、`.rpage-page` 永不出现（120s 白等）；而全新
    # 浏览器**直接**导航到阅读页 4s 就绪，且阅读页 → 阅读页连跳也正常。
    # 所以章节清单从 chapters.json 的 href 里反推 base path，不再读详情页。
    ch_file = Path(args.chapters_file) if args.chapters_file else (out_dir / "chapters.json")
    if args.cmd == "download":
        if not ch_file.exists():
            raise SystemExit(f"找不到章节清单 {ch_file}（先跑 chapters）")
        chapters = json.loads(ch_file.read_text(encoding="utf-8"))
        if not chapters:
            raise SystemExit("章节清单为空")
        sample = chapters[0].get("href") or ""
        base_path = sample.rsplit("/", 1)[0] if sample.startswith("/title/") else f"/title/{args.hid}"
        if args.restart_each:
            await _download_seq(args, out_dir, chapters, base_path)
        else:
            await download_chapters(args, out_dir, chapters, base_path)
        return 0

    async with Browser(headless=not args.headful) as br:
        info = await br.initial_data(args.hid)
        detail = None
        for k, v in info.get("queries", {}).items():
            if "detail" in k and isinstance(v, dict) and v.get("hid"):
                detail = v
                break
        if detail:
            (out_dir / "detail.json").write_text(
                json.dumps(detail, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            log(f"detail: {detail.get('title')} / latest={detail.get('latestChapter')} "
                f"/ status={detail.get('status')}")
            groups = info.get("queries", {}).get(f'["manga","groups","{args.hid}"]')
            if groups:
                (out_dir / "groups.json").write_text(
                    json.dumps(groups, ensure_ascii=False, indent=2), encoding="utf-8"
                )

        if args.cmd == "chapters":
            rows = await scrape_all_rows(br)
            (out_dir / "chapters.json").write_text(
                json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            log(f"章节总数 {len(rows)} → {out_dir / 'chapters.json'}")
            for r in rows[:3] + rows[-3:]:
                log(f"  Ch.{r['number']} [{r['group']}] id={r['chapter_id']}")
            return 0

        # 🔴 阅读页 URL 必须带**完整 slug**（`/title/<hid>-<name>/<cid>-chapter-<num>`）。
        # 只写 `/title/<hid>/...` 直接 404：站点路由按整段路径匹配，hid 本身不是路由。
        base_path = (detail or {}).get("url") or f"/title/{args.hid}"

        if args.cmd == "probe":
            url = f"https://comix.to{base_path}/{args.chapter_id}-chapter-{args.number}"
            log(f"probe {url}")
            await br.goto(url, PAGE_COUNT_JS, timeout=150, label="reader")
            raw = await br.cdp.eval(PROBE_JS, br.session)
            data = json.loads(raw)
            log(f"rpage-page={data['count']}")
            kinds = {}
            for r in data["rows"]:
                kinds[r["kind"]] = kinds.get(r["kind"], 0) + 1
            log(f"取图方式统计 {kinds}")
            print(json.dumps(data["rows"][:8], ensure_ascii=False, indent=2))
            return 0

        # download（已在上面走独立会话的 download_chapters）
        raise SystemExit("unreachable")


def _filter_chapters(args, chapters: list[dict]) -> list[dict]:
    """按 --group / --numbers / --limit 过滤章节清单。"""
    if args.group:
        chapters = [c for c in chapters if c["group"] == args.group]
    if args.numbers:
        want = {float(x) for x in args.numbers.split(",")}
        chapters = [c for c in chapters if chapter_number_value(c["number"]) in want]
    if args.limit:
        chapters = chapters[: args.limit]
    return chapters


async def download_chapters(args, out_dir: Path, chapters: list[dict], base_path: str) -> dict:
    """一次会话内连续下若干章（批量模式）。返回统计 dict。"""
    chapters = _filter_chapters(args, chapters)

    log(f"待下载 {len(chapters)} 章（group={args.group or '全部'}）")
    manifest_path = out_dir / "_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else {}
    done = 0

    async with Browser(headless=not args.headful) as br:
        log(f"浏览器就绪（profile={Path(br.profile).name}）")
        for n, ch in enumerate(chapters, 1):
            dir_name = chapter_dir_name(ch, getattr(args, "site_tag", "comix.to"))
            ch_dir = out_dir / dir_name
            ch_dir.mkdir(parents=True, exist_ok=True)
            existing = sorted(
                p for p in ch_dir.iterdir()
                if p.suffix.lower() in {".webp", ".jpg", ".png", ".jpeg"}
            )
            if existing and not args.force:
                log(f"[{n}/{len(chapters)}] 跳过 Ch.{ch['number']} [{ch['group']}]（已有 {len(existing)} 页）")
                done += 1
                continue

            url = f"https://comix.to{base_path}/{ch['chapter_id']}-chapter-{ch['number']}"
            t0 = time.monotonic()
            log(f"[{n}/{len(chapters)}] 打开 {url}")
            try:
                await br.goto(url, PAGE_COUNT_JS, timeout=90, label=f"Ch.{ch['number']}")
            except Exception as e:
                log(f"!! [{n}/{len(chapters)}] Ch.{ch['number']} 打开失败：{e}")
                if "Third-party" in str(e) or "Cloudflare" in str(e):
                    raise SystemExit("命中反爬，停止（不要硬刷）")
                continue

            data = json.loads(await br.cdp.eval(COLLECT_URLS_JS, br.session, True, timeout=150))
            rows = data["rows"]

            # 🔴 先把「加载失败但 setter 记下了地址」的节点救回来：这类节点
            # （`is-errored` / `net::ERR_HTTP2_PROTOCOL_ERROR`）在浏览器里废了，
            # 但 URL 有效，python 侧用独立连接重试即可拿到图（ch49 已验证 95/95）。
            rescued = 0
            for r in rows:
                if not r.get("src") and r.get("srcVal"):
                    r["src"] = _abs_url(r["srcVal"])
                    r["how"] = "src-attr"
                    rescued += 1
            if rescued:
                log(f"    失败节点救回 {rescued} 个（用 src setter 记录的真实地址）")

            # 二轮补救：既没图也没地址的节点，靠滚动唤懒加载
            # 最多补两轮（每轮 ~25s），仍失败才计入 pending，写进 manifest 待补抓。
            miss_idx = [r["i"] for r in rows if not r.get("src") and not r.get("canvas")]
            if miss_idx:
                log(f"    首轮未出图 {len(miss_idx)} 个节点，开始二轮补救……")
            for rd in range(2):
                if not miss_idx:
                    break
                try:
                    rep = json.loads(
                        await br.cdp.eval(
                            REPAIR_MISS_JS + f"({json.dumps(miss_idx)})",
                            br.session,
                            True,
                            timeout=120,
                        )
                    )
                except Exception as e:
                    log(f"    补救轮 {rd + 1} 失败：{str(e)[:80]}")
                    break
                fixed = 0
                by_i = {r["i"]: r for r in rows}
                for item in rep.get("rows", []):
                    src = _abs_url(item.get("src"))
                    if src:
                        by_i[item["i"]]["src"] = src
                        by_i[item["i"]]["how"] = item.get("how")
                        fixed += 1
                    elif rd == 1:
                        log(
                            f"    节点 {item['i']} 仍无地址 cls={item.get('cls')} "
                            f"html={str(item.get('html'))[:120]}"
                        )
                log(f"    补救轮 {rd + 1}：补回 {fixed}/{len(miss_idx)}")
                miss_idx = [i for i in miss_idx if not by_i[i].get("src")]
                if fixed == 0:
                    break

            t_collect = time.monotonic()
            canvas_rows = [r for r in rows if not r.get("src") and r.get("canvas")]
            dropped = [r for r in rows if not r.get("src") and not r.get("canvas")]
            pending = [r["i"] for r in dropped]

            # 并行拉图：先打本章出现次数最多的域名（实测轮换域名里主域名最稳）
            host_counts = Counter(urlparse(r["src"]).netloc for r in rows if r.get("src"))
            hosts = [h for h, _ in host_counts.most_common()]
            ordered = []
            for r in rows:
                src = r.get("src")
                if not src:
                    continue
                ext = "webp" if ".webp" in src else ("png" if ".png" in src else "jpg")
                ordered.append((r["i"], src, ext))

            saved = 0
            failures = []
            with ThreadPoolExecutor(max_workers=args.workers) as pool:
                futures = []
                for seq, (idx, src, ext) in enumerate(ordered, start=1):
                    dest = ch_dir / f"{seq:03d}.{ext}"
                    futures.append(
                        (idx, dest, pool.submit(download_image, src, dest, hosts))
                    )
                for done_n, (idx, dest, fut) in enumerate(futures, 1):
                    try:
                        fut.result()
                        saved += 1
                    except Exception as e:
                        failures.append((idx, str(e)[:80]))
                    if done_n % 25 == 0:
                        log(f"    下载进度 {done_n}/{len(futures)}（成功 {saved}）")

            # canvas / dataURL 兜底（少数章节会把图绘到 canvas 上）
            for r in canvas_rows:
                try:
                    res = await br.cdp.eval(
                        EXTRACT_PAGE_JS.replace("__AD__", str(AD_CANVAS_MAX_CHARS)) + f"({r['i']})",
                        br.session,
                        True,
                    )
                    payload = json.loads(res)
                    if payload.get("ok"):
                        save_payload(payload, ch_dir / f"{saved + 1:03d}")
                        saved += 1
                except Exception:
                    failures.append((r["i"], "canvas"))

            elapsed = time.monotonic() - t0
            log(
                f"[{n}/{len(chapters)}] Ch.{ch['number']} [{ch['group']}] "
                f"节点 {len(rows)} → 落盘 {saved} 页，空/广告节点 {len(dropped)}，"
                f"canvas {len(canvas_rows)}，失败 {len(failures)}｜"
                f"取链 {t_collect - t0:.0f}s / 总计 {elapsed:.0f}s"
            )
            if pending:
                log(f"    ⚠ 待补抓节点 {len(pending)} 个（已记入 manifest.pending）：{pending}")
            manifest[dir_name] = {
                "chapter_id": ch["chapter_id"],
                "number": ch["number"],
                "group": ch["group"],
                "nodes": len(rows),
                "saved": saved,
                "dropped": len(dropped),
                "pending": pending,
                "failures": failures,
                "seconds": round(elapsed, 1),
            }
            manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
            if saved:
                done += 1
        log(f"全部结束：{done}/{len(chapters)} 章")
        return {"requested": len(chapters), "done": done}


def _parse_gap(text: str) -> tuple[float, float]:
    """解析 --gap：`45,100` / `45~100` / `60` → (lo, hi)。默认 45~100s。"""
    try:
        parts = [float(x) for x in re.split(r"[,~]", str(text)) if x.strip()]
    except ValueError:
        parts = []
    if len(parts) >= 2:
        return min(parts[0], parts[1]), max(parts[0], parts[1])
    if len(parts) == 1:
        return 0.0, parts[0]
    return 45.0, 100.0


async def _download_seq(args, out_dir: Path, chapters: list[dict], base_path: str) -> dict:
    """逐章独立会话模式。

    为什么这么做：comix.to 的封禁判据是**访问节奏**（见 A07c §11.3），同一个浏览器
    会话里连开几十个阅读页就是标准爬虫特征。每章都新建一套浏览器（全新 profile，
    等于每次都是「首访新访客」）+ 章间随机冷却，把流量摊平成人工阅读的样子。

    代价是每章多约 10s 冷启动，但换来的是不封号。
    """
    chapters = _filter_chapters(args, chapters)
    total = len(chapters)
    log(f"逐章独立会话模式：待下载 {total} 章（group={args.group or '全部'}）")

    gap_lo, gap_hi = _parse_gap(args.gap)
    manifest_path = out_dir / "_manifest.json"
    img_ext = {".webp", ".jpg", ".png", ".jpeg"}
    ok: list = []
    skipped: list = []
    bad: list = []
    consec_fail = 0

    for n, ch in enumerate(chapters, 1):
        tag = f"[{n}/{total}] Ch.{ch['number']} [{ch['group']}]"
        dir_name = chapter_dir_name(ch, getattr(args, "site_tag", "comix.to"))
        ch_dir = out_dir / dir_name

        # 跳过判据必须看**完整性**，不能只看"目录里有没有图"。
        # 上一版只要目录非空就跳过，于是被中断留下的半章（Ch.2 只有 12 页）
        # 被当成"已完成"永远不再补——静默缺页比报错更难发现。
        try:
            prev = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else {}
        except Exception:
            prev = {}
        prev_rec = prev.get(dir_name) or {}
        if ch_dir.is_dir() and not args.force:
            have = [p for p in ch_dir.iterdir() if p.suffix.lower() in img_ext]
            prev_nodes = prev_rec.get("nodes") or 0
            complete = (
                bool(have)
                and not prev_rec.get("pending")
                and not prev_rec.get("failures")
                and (prev_nodes == 0 or len(have) >= prev_nodes)
            )
            if complete:
                log(f"{tag} 跳过（已有 {len(have)}/{prev_nodes or '?'} 页，记录完整）")
                skipped.append(ch["number"])
                consec_fail = 0
                continue
            if have:
                log(
                    f"{tag} 检测到残留（{len(have)}/{prev_nodes or '?'} 页，"
                    f"待补 {len(prev_rec.get('pending') or [])}，"
                    f"失败 {len(prev_rec.get('failures') or [])}）→ 重下本章"
                )
                for stale in have:
                    try:
                        stale.unlink()
                    except OSError:
                        pass

        if n > 1:
            wait = random.uniform(gap_lo, gap_hi)
            log(f"    冷却 {wait:.0f}s 再开下一章（模拟人工翻页节奏）")
            await asyncio.sleep(wait)

        # 单章调 download_chapters：内部自己 `async with Browser(...)`，
        # 所以每次都是全新浏览器进程 + 全新 profile。
        chapter_args = argparse.Namespace(**vars(args))
        chapter_args.group = ""
        chapter_args.numbers = ""
        chapter_args.limit = 0

        status = "fail"
        for attempt in (1, 2):
            try:
                log(f"    尝试 {attempt}/2：新建独立会话")
                await download_chapters(chapter_args, out_dir, [ch], base_path)
                status = "ok"
                break
            except SystemExit as e:
                msg = str(e)
                log(f"!! {tag} 中断：{msg}")
                if any(k in msg for k in ("反爬", "Third-party", "Cloudflare", "503")):
                    if attempt == 1:
                        log(f"    命中拦截 → 熔断 {args.cool}s 后原样重试一次")
                        await asyncio.sleep(args.cool)
                        continue
                    status = "blocked"
                break
            except Exception as e:
                log(f"!! {tag} 会话异常：{str(e)[:120]}")
                if attempt == 1:
                    await asyncio.sleep(60)
                    continue
                break

        pages = (
            [p for p in ch_dir.iterdir() if p.suffix.lower() in img_ext]
            if ch_dir.is_dir()
            else []
        )
        try:
            man = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else {}
        except Exception:
            man = {}
        rec = man.get(dir_name) or {}
        pend = rec.get("pending") or []
        # 🔴 只判 pending 是不够的：`failures` 是"URL 拿到了但下载失败"，
        # 它不会进 pending（pending 专指"连 URL 都没拿到"），却同样是缺页。
        # 上一版漏判 `failures`，导致 Ch.3 落盘 64/65 被记成"✓ 无待补"。
        failed_pages = rec.get("failures") or []
        nodes = rec.get("nodes") or 0

        if pages and not pend and not failed_pages:
            log(f"{tag} ✓ 落盘 {len(pages)} 页，无待补")
            ok.append(ch["number"])
            consec_fail = 0
        elif pages:
            detail = []
            if pend:
                detail.append(f"待补节点 {len(pend)} 个 {pend}")
            if failed_pages:
                detail.append(f"下载失败 {len(failed_pages)} 页")
            log(f"{tag} ⚠ 落盘 {len(pages)}/{nodes} 页，{'；'.join(detail)}")
            bad.append({
                "number": ch["number"],
                "pages": len(pages),
                "nodes": nodes,
                "pending": pend,
                "failed": len(failed_pages),
            })
            consec_fail = 0
        else:
            log(f"{tag} ✗ 零落盘")
            bad.append({"number": ch["number"], "pages": 0, "pending": pend})
            consec_fail += 1

        if status == "blocked" or consec_fail >= args.max_fail:
            log(f"🔴 已确认被拦或连续 {consec_fail} 章失败 → 停手，长冷却后退出")
            await asyncio.sleep(min(args.cool * 3, 600))
            break

    log(f"逐章模式结束：成功 {len(ok)}，跳过 {len(skipped)}，待处理 {len(bad)}")
    if bad:
        log(f"待处理明细：{bad}")
    return {"ok": ok, "skipped": skipped, "bad": bad}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["chapters", "probe", "download"])
    ap.add_argument("hid")
    ap.add_argument("chapter_id", nargs="?")
    ap.add_argument("number", nargs="?")
    ap.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "comix_out"))
    ap.add_argument("--headful", action="store_true")
    ap.add_argument("--numbers", default="")
    ap.add_argument("--group", default="", help="只下某个翻译组")
    ap.add_argument("--workers", type=int, default=8, help="图片并发数")
    ap.add_argument("--chapters-file", default="", help="章节清单路径（默认 <out>/chapters.json）")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--force", action="store_true")
    ap.add_argument(
        "--restart-each",
        action="store_true",
        help="逐章独立会话：每章新建浏览器（全新 profile）+ 章间随机冷却，抗封",
    )
    ap.add_argument("--gap", default="45,100", help="章间随机冷却秒数，如 45,100（默认）")
    ap.add_argument("--cool", type=int, default=300, help="命中拦截后的熔断秒数（默认 300）")
    ap.add_argument("--max-fail", type=int, default=3, help="连续失败多少章后停手（默认 3）")
    ap.add_argument(
        "--site-tag",
        default="comix.to",
        help="来源站点标签，写进章节文件夹名（默认 comix.to；置空则只留翻译组）",
    )
    args = ap.parse_args()
    asyncio.run(run(args))
    return 0


if __name__ == "__main__":
    sys.exit(main())
