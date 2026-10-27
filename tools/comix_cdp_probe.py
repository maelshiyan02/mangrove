# -*- coding: utf-8 -*-
"""用真实 Chrome + CDP 抓 comix.to 的站内 JSON（探测用）。

## 为什么必须用真浏览器

comix.to 的 `/api/v1/*` 要求一个由 SPA 自己算出来的签名 token，纯 HTTP 客户端
（requests / Dart 的 dio）拿不到；页面 HTML 是空壳，真正的数据在
`<script type="application/json" id="initial-data">` 里，而那一段同样要
JS 跑起来、过掉站内 WAF 才会有。所以只能开一个真 Chrome，让它自己发请求，
我们在 CDP 上旁听。

## 用法

    python -u tools/comix_cdp_probe.py \\
        --url "https://comix.to/title/ll82v-regressor-of-the-fallen-family" \\
        --out builds/comix_probe.json

输出：抓到的每条 `api/v1` 响应的 url + JSON 顶层键（不落全量，避免又爆仓）。
"""

import argparse
import asyncio
import json
import os
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


def find_chrome():
    for path in CHROME_CANDIDATES:
        if os.path.exists(path):
            return path
    raise SystemExit("找不到 Chrome / Edge 可执行文件")


def start_chrome(port, proxy, profile):
    args = [
        find_chrome(),
        f"--remote-debugging-port={port}",
        f"--user-data-dir={profile}",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-features=Translate,MediaRouter",
        "--headless=new",
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


def wait_targets(port, timeout=25):
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


async def probe(ws_url, url, seconds, out_path):
    import websockets

    captured = []  # [(url, body)]
    urls = {}
    pending = set()
    body_requests = {}  # 命令 id → (url, requestId)

    async with websockets.connect(ws_url, max_size=64 * 1024 * 1024) as ws:
        counter = 0

        async def send(method, params=None):
            nonlocal counter
            counter += 1
            await ws.send(
                json.dumps({"id": counter, "method": method, "params": params or {}})
            )
            return counter

        async def reader():
            async for raw in ws:
                msg = json.loads(raw)
                method = msg.get("method")
                if method == "Network.responseReceived":
                    params = msg["params"]
                    resp = params["response"]
                    request_url = resp.get("url", "")
                    mime = (resp.get("mimeType") or "").lower()
                    if "/api/" in request_url or "json" in mime:
                        pending.add(params["requestId"])
                        urls[params["requestId"]] = request_url
                elif method == "Network.loadingFinished":
                    request_id = msg["params"]["requestId"]
                    if request_id in pending:
                        pending.discard(request_id)
                        command_id = await send(
                            "Network.getResponseBody", {"requestId": request_id}
                        )
                        body_requests[command_id] = urls.get(request_id, "")
                if "id" in msg and "result" in msg:
                    entry = body_requests.pop(msg["id"], None)
                    if entry is None:
                        continue
                    body = msg["result"].get("body")
                    if body:
                        captured.append((entry, body))

        reader_task = asyncio.create_task(reader())
        await send("Network.enable", {"maxTotalBufferSize": 64 * 1024 * 1024})
        await send("Page.enable")
        await send("Page.navigate", {"url": url})
        await asyncio.sleep(seconds)
        reader_task.cancel()

    # 落盘精简摘要：每条 body 的顶层结构 + 长度
    summary = []
    for request_url, body in captured:
        try:
            data = json.loads(body)
        except (TypeError, ValueError):
            summary.append(
                {"url": request_url, "type": "text", "len": len(body), "head": body[:200]}
            )
            continue
        entry = {"url": request_url, "type": type(data).__name__, "len": len(body)}
        if isinstance(data, dict):
            entry["keys"] = list(data.keys())[:12]
            result = data.get("result")
            if isinstance(result, dict):
                entry["result_keys"] = list(result.keys())[:20]
                items = result.get("items")
                if isinstance(items, list):
                    entry["items"] = len(items)
                    if items and isinstance(items[0], dict):
                        entry["item_keys"] = list(items[0].keys())[:25]
        elif isinstance(data, list):
            entry["items"] = len(data)
            if data and isinstance(data[0], dict):
                entry["item_keys"] = list(data[0].keys())[:25]
        summary.append(entry)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fp:
        json.dump(summary, fp, ensure_ascii=False, indent=2)
    print(f"捕获 {len(summary)} 条 api 响应 → {out_path}")
    for entry in summary[:10]:
        print(" ", json.dumps(entry, ensure_ascii=False)[:280])
    return summary


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--port", type=int, default=9333)
    parser.add_argument("--proxy", default="http://127.0.0.1:7890")
    parser.add_argument("--seconds", type=float, default=18)
    parser.add_argument("--out", default="builds/comix_probe.json")
    parser.add_argument("--keep-profile", action="store_true")
    args = parser.parse_args()

    profile = tempfile.mkdtemp(prefix="comix_cdp_")
    proc = start_chrome(args.port, args.proxy, profile)
    try:
        pages = wait_targets(args.port)
        ws_url = pages[0]["webSocketDebuggerUrl"]
        asyncio.run(probe(ws_url, args.url, args.seconds, args.out))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()
        if not args.keep_profile:
            shutil.rmtree(profile, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
