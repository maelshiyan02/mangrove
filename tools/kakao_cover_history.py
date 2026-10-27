#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""KakaoPage 封面历史 → 季度封面（season 封面池）。

## 为什么要查 Wayback

KakaoPage 的封面 URL 里带一串**随机 token**（`kid=b8UccL/dJMcabjvgXG/...`），
**换封面就换 URL** —— 所以只要把该页面在 Wayback 里的历史快照逐个取出、抽
`og:image`，按"首次出现时间"排序，就能把每次换封面界定出来（与
`tools/naver_cover_history.py` 同一套论证，只是平台不同）。

这本《그 대공의 화려한 결혼은 사기》是 **Kakao 原创**（不在 Naver），所以它的
"季度封面"只能从 KakaoPage 的历史快照里还原。

## 落盘

`<漫画目录>/cover/[KR][cover]season(N).<ext>`，N 按首次出现顺序。
语言标签 `[KR]` = 韩文原版封面（中英两版共用同一张原版封面时，各存各的目录）。

用法：
    python -u tools/kakao_cover_history.py --content-id 61686760 \
        --target "ComicLibrary/downloads/那個大公的華麗婚姻騙局" \
        [--target "ComicLibrary/downloads/那個大公的華麗婚姻騙局 · 英文版"]
"""

import argparse
import json
import os
import re
import sys
import urllib.parse

import requests

PROXY = {"http": "http://127.0.0.1:7890", "https": "http://127.0.0.1:7890"}
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
)


def snapshots(content_id):
    url = (
        "https://web.archive.org/cdx/search/cdx"
        f"?url=page.kakao.com%2Fcontent%2F{content_id}"
        "&output=json&fl=timestamp,statuscode&filter=statuscode:200"
        "&collapse=digest&limit=200"
    )
    r = requests.get(url, proxies=PROXY, timeout=120)
    r.raise_for_status()
    rows = r.json()
    return [row[0] for row in rows[1:]]


def og_image_of(ts, content_id):
    target = (
        f"https://web.archive.org/web/{ts}id_/"
        f"https://page.kakao.com/content/{content_id}"
    )
    try:
        r = requests.get(target, proxies=PROXY, headers={"User-Agent": UA}, timeout=90)
        if r.status_code != 200:
            return ts, None, "http %s" % r.status_code
        m = re.search(r'<meta property="og:image" content="([^"]+)"', r.text)
        if not m:
            return ts, None, "no-og-image"
        url = m.group(1).replace("&amp;", "&")
        if url.startswith("//"):
            url = "https:" + url
        # 🔴 站点的**通用**占位封面（`/shared/ogImage.png`）不是这一部的封面 ——
        # 某一版页面丢了 og:image 时会回落到它。收进来等于凭空多一"季"。
        if "/shared/" in url or url.endswith("/ogImage.png"):
            return ts, None, "placeholder-og-image"
        return ts, url, None
    except Exception as exc:  # noqa: BLE001
        return ts, None, str(exc)


def cover_key(url):
    """封面"身份"：URL 里那串随机 token（换封面就换）。"""
    m = re.search(r"kid=([^&]+)", url)
    return m.group(1) if m else url


def download(url, target):
    r = requests.get(url, proxies=PROXY, headers={"User-Agent": UA}, timeout=120)
    r.raise_for_status()
    ctype = (r.headers.get("Content-Type") or "").lower()
    ext = ".png" if "png" in ctype else ".jpg"
    path = target + ext
    with open(path, "wb") as fh:
        fh.write(r.content)
    return path, len(r.content)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--content-id", required=True, help="KakaoPage content id")
    ap.add_argument("--target", action="append", required=True,
                    help="漫画目录（可多次给：中英两版各存一份）")
    ap.add_argument("--lang-tag", default="KR")
    ap.add_argument("--json", default="")
    args = ap.parse_args()

    stamps = snapshots(args.content_id)
    print("snapshots=%d" % len(stamps), flush=True)

    found = []
    for ts in stamps:
        ts, url, err = og_image_of(ts, args.content_id)
        print("  %s  %s" % (ts, (url or err)), flush=True)
        if url:
            found.append((ts, url))

    # 按"首次出现"折叠 ⇒ 每一张不同的封面 = 一个季度。
    ordered = []
    seen = set()
    for ts, url in found:
        key = cover_key(url)
        if key in seen:
            continue
        seen.add(key)
        ordered.append((ts, url, key))

    print("\n=== 季度封面 %d 张 ===" % len(ordered), flush=True)
    saved = []
    for index, (ts, url, key) in enumerate(ordered, start=1):
        name = "[%s][cover]season(%d)" % (args.lang_tag, index)
        for target in args.target:
            cover_dir = os.path.join(target, "cover")
            os.makedirs(cover_dir, exist_ok=True)
            try:
                path, size = download(url, os.path.join(cover_dir, name))
                print("  season(%d) -> %s (%d bytes)  [%s]" % (index, path, size, ts), flush=True)
                saved.append({"season": index, "ts": ts, "url": url, "path": path, "bytes": size})
            except Exception as exc:  # noqa: BLE001
                print("  season(%d) 下载失败: %s" % (index, exc), flush=True)

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({"snapshots": stamps, "covers": saved}, fh, ensure_ascii=False, indent=1)
    print("saved %d cover(s)" % len(saved), flush=True)
    return 0 if saved else 1


if __name__ == "__main__":
    sys.exit(main())
