#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""包子漫画「官方 App 接口」批量下载器（P48，2026-10-27）。

## 为什么需要它

`loadEp` 的回落分支走 `appcn.baozimh.com/baozimhapp`，该域对 **Dart/BoringSSL**
下发 Cloudflare 挑战（`CloudflareException`），GUI 侧靠离屏 WebView 自愈，
但 **headless / 命令行侧拿不到 WebView 的 cf_clearance**，因此 `download-check`
永远卡在第一步（2026-10-27 实测 3 次重试后 TIMEOUT）。

同一页面用 **curl + 浏览器 UA** 直接 200（App 域按 TLS 指纹判定，不认 UA 版本）。
于是下载改由本脚本承担：抓 HTML → 抽图 → 下载 → 按 App 的目录约定落盘。

## 目录约定（必须与 lib/foundation/chapter_directory.dart 一致）

- 章节目录：`<话号 key> [<siteTag>]`，包子源 siteTag = `baozimh`（`_sourceSiteTags`）
- 页文件：`<顺序号>.<ext>`，从 0 开始；`.dl`/`.tmp` 视为未完成
- 漫画根目录：`<libraryRoot>/<漫画目录名>/`

## 幂等 / 断点续传

已存在且非 0 字节的页直接跳过（与 `_existingPageIndexes` 同判据），
所以中断后重跑同一条命令即可续传。

用法：
  python tools/baozi_app_download.py --comic-id <cid> --title-dir "灭门家族的重生者" \
      --from 0 --to 151 --json builds/baozi_app_download.json
"""

import argparse
import json
import os
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import requests
from requests.adapters import HTTPAdapter

APP_BASE = "https://appcn.baozimh.com/baozimhapp"
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0"
)
REFERER = "https://appcn.baozimh.com/"

# 与 lib/foundation/chapter_directory.dart::_sourceSiteTags 对齐
SITE_TAG = "baozimh"
# P49（2026-10-27）：目录名最前面加语言段，与 Dart 侧
# chapterDirectoryName(languageTag:) 的输出逐字节一致：
#   [zh-Hans] 120 [baozimh]
LANG_TAG = "zh-Hans"

_print_lock = threading.Lock()
_local = threading.local()


def log(*parts):
    with _print_lock:
        print(*parts, flush=True)


def _session():
    """每线程一个 Session：复用 TLS/keep-alive。

    单图 1.9s 里大部分是握手；复用后实测降到 ~0.2-0.4s（2026-10-27）。
    """
    sess = getattr(_local, "sess", None)
    if sess is None:
        sess = requests.Session()
        adapter = HTTPAdapter(pool_connections=4, pool_maxsize=8, max_retries=0)
        sess.mount("https://", adapter)
        sess.mount("http://", adapter)
        sess.headers.update(
            {
                "User-Agent": UA,
                "Referer": REFERER,
                "Accept-Language": "zh-CN,zh;q=0.9",
            }
        )
        _local.sess = sess
    return sess


def http_get(url, timeout=40, binary=False):
    headers = {"Accept": "*/*" if binary else "text/html,application/xhtml+xml"}
    resp = _session().get(url, headers=headers, timeout=timeout)
    return resp.status_code, resp.content


_ITEM_RE = re.compile(
    r'<[a-zA-Z0-9]+[^>]*class="[^"]*comic-contain__item[^"]*"[^>]*>', re.S
)
_SRC_RE = re.compile(r'data-src="([^"]+)"')


def chapter_image_urls(comic_id, ep_key, retries=3):
    """抓一章（含分页）的全部图片 URL，去重保序，仅保留本书 slug。"""
    images = []
    seen = set()
    page = 1
    total_pages = None
    while page <= 50:
        path = f"0_{ep_key}.html" if page == 1 else f"0_{ep_key}_{page}.html"
        url = f"{APP_BASE}/comic/chapter/{comic_id}/{path}"
        body = None
        for attempt in range(retries):
            try:
                status, raw = http_get(url)
                if status == 200:
                    body = raw.decode("utf-8", "replace")
                    break
            except Exception as exc:  # noqa: BLE001
                if attempt == retries - 1:
                    raise RuntimeError(f"GET {url} failed: {exc}") from exc
                time.sleep(1.5 * (attempt + 1))
        if body is None:
            if page == 1:
                raise RuntimeError(f"chapter page unavailable: {url}")
            break

        if total_pages is None:
            m = re.search(r"[（(](\d+)\s*/\s*(\d+)[）)]", body)
            if m:
                total_pages = int(m.group(2))

        added = 0
        # 只取容器内节点的 data-src；再按 /scomic/<comicId>/ 过滤掉推荐位/广告图
        for node in _ITEM_RE.findall(body):
            m = _SRC_RE.search(node)
            if not m:
                continue
            img = m.group(1).strip()
            if not img or f"/scomic/{comic_id}/" not in img:
                continue
            if img in seen:
                continue
            seen.add(img)
            images.append(img)
            added += 1

        if page == 1 and not images:
            raise RuntimeError(f"no images parsed from {url}")
        if total_pages is not None:
            if page >= total_pages:
                break
        elif added == 0 and page > 1:
            break
        page += 1
    return images


def ext_of(url, data):
    """按 magic bytes 定扩展名，退化为 URL 后缀。"""
    if data[:3] == b"\xff\xd8\xff":
        return "jpg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "gif"
    tail = url.split("?")[0].rsplit(".", 1)
    return tail[1].lower() if len(tail) == 2 and len(tail[1]) <= 4 else "jpg"


def existing_page_indexes(dir_path):
    found = set()
    if not os.path.isdir(dir_path):
        return found
    for name in os.listdir(dir_path):
        lower = name.lower()
        if lower.endswith(".dl") or lower.endswith(".tmp"):
            continue
        full = os.path.join(dir_path, name)
        if not os.path.isfile(full) or os.path.getsize(full) == 0:
            continue
        dot = name.find(".")
        if dot <= 0:
            continue
        try:
            found.add(int(name[:dot]))
        except ValueError:
            continue
    return found


def chapter_dir_name(ep_key):
    """章节目录名：`[<lang>] <key> [<site>]`（P49 四件套，语言在最前）。"""
    return f"[{LANG_TAG}] {ep_key} [{SITE_TAG}]"


def _adopt_legacy_dir(comic_dir, ep_key, new_dir):
    """把老命名的目录 `120 [baozimh]` 就地改名成新四件套。

    断点续传的命门：不改名就会把老目录当"没下过"，整车重下（2026-10-27 教训）。
    只做 os.rename（同盘瞬时），失败就算了，退回重下。
    """
    legacy = os.path.join(comic_dir, f"{ep_key} [{SITE_TAG}]")
    if os.path.isdir(new_dir) or not os.path.isdir(legacy):
        return
    try:
        os.rename(legacy, new_dir)
        log(f"[adopt] {os.path.basename(legacy)} -> {os.path.basename(new_dir)}")
    except OSError as exc:  # noqa: BLE001
        log(f"[adopt] skip {ep_key}: {exc}")


def download_chapter(comic_id, ep_key, comic_dir, concurrency, retries=3):
    urls = chapter_image_urls(comic_id, ep_key)
    ch_dir = os.path.join(comic_dir, chapter_dir_name(ep_key))
    _adopt_legacy_dir(comic_dir, ep_key, ch_dir)
    os.makedirs(ch_dir, exist_ok=True)
    have = existing_page_indexes(ch_dir)

    todo = [(i, u) for i, u in enumerate(urls) if i not in have]
    failed = []
    done = len(have & set(range(len(urls))))

    def fetch(item):
        idx, url = item
        for attempt in range(retries):
            try:
                status, data = http_get(url, timeout=45, binary=True)
                if status == 200 and data:
                    return idx, url, data, None
                raise RuntimeError(f"status {status}")
            except Exception as exc:  # noqa: BLE001
                if attempt == retries - 1:
                    return idx, url, None, str(exc)
                time.sleep(1.2 * (attempt + 1))
        return idx, url, None, "unknown"

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(fetch, it) for it in todo]
        for fut in as_completed(futures):
            idx, url, data, err = fut.result()
            if err or not data:
                failed.append({"index": idx, "url": url, "error": err})
                continue
            ext = ext_of(url, data)
            final = os.path.join(ch_dir, f"{idx}.{ext}")
            tmp = final + ".dl"
            with open(tmp, "wb") as fh:
                fh.write(data)
            os.replace(tmp, final)

    return {
        "chapterKey": ep_key,
        "directory": os.path.basename(ch_dir),
        "images": len(urls),
        "alreadyHad": len(have),
        "downloaded": len(todo) - len(failed),
        "failed": len(failed),
        "failures": failed[:10],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--comic-id", required=True)
    ap.add_argument("--title-dir", required=True, help="漫画根目录名（ComicLibrary/downloads 下）")
    ap.add_argument("--library-root", default=None)
    ap.add_argument("--from", dest="ep_from", type=int, default=0)
    ap.add_argument("--to", dest="ep_to", type=int, required=True)
    ap.add_argument("--concurrency", type=int, default=8)
    ap.add_argument("--json", default=None)
    ap.add_argument("--only", default=None, help="只下这些 key，逗号分隔（调试用）")
    args = ap.parse_args()

    root = args.library_root
    if not root:
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        root = os.path.join(here, "ComicLibrary", "downloads")
    comic_dir = os.path.join(root, args.title_dir)
    os.makedirs(comic_dir, exist_ok=True)

    if args.only:
        keys = [k.strip() for k in args.only.split(",") if k.strip()]
    else:
        keys = [str(k) for k in range(args.ep_from, args.ep_to + 1)]

    started = time.time()
    report = {
        "comicId": args.comic_id,
        "comicDir": comic_dir,
        "chapters": [],
        "totalImages": 0,
        "totalDownloaded": 0,
        "totalFailed": 0,
    }
    log(f"[start] {len(keys)} chapter(s) -> {comic_dir}")

    for i, key in enumerate(keys, 1):
        t0 = time.time()
        try:
            res = download_chapter(
                args.comic_id, key, comic_dir, args.concurrency
            )
        except Exception as exc:  # noqa: BLE001
            log(f"[{i}/{len(keys)}] key={key} ERROR {exc}")
            report["chapters"].append({"chapterKey": key, "error": str(exc)})
            continue
        report["chapters"].append(res)
        report["totalImages"] += res["images"]
        report["totalDownloaded"] += res["downloaded"]
        report["totalFailed"] += res["failed"]
        log(
            f"[{i}/{len(keys)}] key={key} imgs={res['images']} "
            f"new={res['downloaded']} had={res['alreadyHad']} "
            f"fail={res['failed']} {time.time() - t0:.1f}s"
        )
        if args.json:
            report["elapsedSeconds"] = round(time.time() - started, 1)
            with open(args.json, "w", encoding="utf-8") as fh:
                json.dump(report, fh, ensure_ascii=False, indent=1)

    report["elapsedSeconds"] = round(time.time() - started, 1)
    report["chaptersDone"] = sum(1 for c in report["chapters"] if not c.get("error"))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(report, fh, ensure_ascii=False, indent=1)
    log(
        f"[done] chapters={report['chaptersDone']}/{len(keys)} "
        f"images={report['totalImages']} new={report['totalDownloaded']} "
        f"fail={report['totalFailed']} {report['elapsedSeconds']}s"
    )
    return 0 if report["totalFailed"] == 0 else 3


if __name__ == "__main__":
    sys.exit(main())
