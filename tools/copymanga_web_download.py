#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""拷贝漫画 **web 通道**下载器（App 通道被 210 风控时的备份路）。

## 为什么要 web 通道

拷贝漫画的 App API（`api.copyXXXX.com`）对匿名访问很敏感：软风控（200 但
`results` 为空）、硬风控（210「访问过于频繁」）都很常见。web 通道
（`www.copyXXXX.com`）走的是网页版，响应体是 **AES-128-CBC 加密**的，但密钥
就写在网页里 ⇒ 抓得到、解得开。

## 协议（照抄 App 的 `copy_manga` 源 JS）

1. `GET /comic/{slug}` → 网页里有 `id="dnt" value="..."`（请求头要用）与
   `var ccz = '...'`（章节表密文密钥）。
2. `GET /comicdetail/{slug}/chapters`，头带 `dnts: <dnt>` +
   `X-Requested-With: XMLHttpRequest` → 密文 ⇒ 用 `ccz` 解 ⇒ 章节表。
3. `GET /comic/{slug}/chapter/{epId}` → 网页里有 `var cct = '...'` 与
   `contentKey = '...'` ⇒ 用 `cct` 解 `contentKey` ⇒ 图片 URL 数组。

解密：密钥 = 16 字节 ASCII（`ccz`/`cct`），IV = 密文**前 16 个字符**的
ASCII，密文余下部分按 hex 解码，PKCS#7 去填充（= `tools/copy_aes.js` 的
`decryptPayload`）。

用法：
    python -u tools/copymanga_web_download.py --slug ngdgdhlhypj \
        --title-dir "那個大公的華麗婚姻騙局" --from 1 --to 69 [--apply]
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.request

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB_HOSTS = ["www.copy5000.com", "www.copy4000.com", "www.copy-manga.com"]
SITE_TAG = "copymanga"
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0"
)


def decrypt_payload(key_str, payload):
    """AES-128-CBC 解密（= `tools/copy_aes.js` 的 decryptPayload）。"""
    iv = bytes(ord(c) & 0xFF for c in payload[:16])
    ct = bytes.fromhex(payload[16:])
    key = key_str.encode("utf-8")[:16].ljust(16, b"\0")
    dec = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    plain = dec.update(ct) + dec.finalize()
    if plain:
        pad = plain[-1]
        if 1 <= pad <= 16 and plain[-pad:] == bytes([pad]) * pad:
            plain = plain[:-pad]
    return plain.decode("utf-8", "replace")


def web_get(url, headers=None, timeout=40, tries=3):
    last = None
    for attempt in range(tries):
        try:
            h = {
                "User-Agent": UA,
                "Accept": "text/html,application/json;q=0.9,*/*;q=0.8",
                "Accept-Language": "zh-CN,zh;q=0.9,zh-TW;q=0.8",
            }
            h.update(headers or {})
            req = urllib.request.Request(url, headers=h)
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            last = "HTTP %s" % exc.code
        except Exception as exc:  # noqa: BLE001
            last = str(exc)
        time.sleep(1.5 + attempt)
    return 0, str(last)


def comic_page(slug):
    """取漫画页：拿到 dnt / ccz / 章节 uuid 列表。"""
    last = None
    for host in WEB_HOSTS:
        status, body = web_get("https://%s/comic/%s" % (host, slug))
        if status == 200:
            dnt = re.search(r'id="dnt"[^>]*value="([^"]*)"', body)
            ccz = re.search(r"var\s+ccz\s*=\s*'([^']*)'", body)
            uuids = []
            for m in re.finditer(
                r"/comic/" + re.escape(slug) + r"/chapter/([0-9a-fA-F-]{36})", body
            ):
                if m.group(1) not in uuids:
                    uuids.append(m.group(1))
            title = re.search(r"<h1[^>]*>([^<]+)</h1>", body)
            return {
                "host": host,
                "dnt": dnt.group(1) if dnt else None,
                "ccz": ccz.group(1) if ccz else None,
                "uuids": uuids,
                "title": title.group(1).strip() if title else "",
                "body": body,
            }
        last = "%s -> %s" % (host, body[:80])
    raise RuntimeError("漫画页取不到：%s" % last)


def chapter_table(slug, dnt, ccz, host):
    """章节表（uuid → 话名），走 web 通道的 `/comicdetail/{slug}/chapters`。"""
    status, body = web_get(
        "https://%s/comicdetail/%s/chapters" % (host, slug),
        {
            "dnts": dnt or "3",
            "X-Requested-With": "XMLHttpRequest",
            "Referer": "https://%s/comic/%s" % (host, slug),
        },
    )
    if status != 200:
        raise RuntimeError("章节表 HTTP %s" % status)
    payload = json.loads(body)
    results = payload.get("results")
    if isinstance(results, str):
        plain = decrypt_payload(ccz, results)
        results = json.loads(plain)
    groups = (results or {}).get("groups") or {}
    out = []
    for name, group in groups.items():
        # 组的章节有两种形态：**列表**（`[{type,name,id}]`，web 通道的真实形态）
        # 与**字典**（`{uuid: title}`，App 通道的形态）⇒ 两种都要认。
        items = group.get("chapters") if isinstance(group, dict) else group
        if isinstance(items, dict):
            for uuid, title in items.items():
                out.append({"uuid": uuid, "title": str(title), "group": name})
        elif isinstance(items, list):
            for entry in items:
                if not isinstance(entry, dict):
                    continue
                uuid = entry.get("id") or entry.get("uuid") or ""
                title = entry.get("name") or entry.get("title") or ""
                if not uuid:
                    continue
                out.append({"uuid": uuid, "title": str(title), "group": name})
    return out


def chapter_images(slug, ep_id, host):
    """一章的图片 URL 列表。"""
    status, body = web_get(
        "https://%s/comic/%s/chapter/%s" % (host, slug, ep_id),
        {"Referer": "https://%s/comic/%s" % (host, slug)},
    )
    if status != 200:
        raise RuntimeError("章节页 HTTP %s" % status)
    cct = re.search(r"var\s+cct\s*=\s*'([^']*)'", body)
    key = re.search(r"contentKey\s*=\s*'([^']*)'", body)
    if not cct or not key:
        raise RuntimeError("章节页缺密文")
    plain = decrypt_payload(cct.group(1), key.group(1))
    arr = json.loads(plain)
    urls = []
    for item in arr:
        url = item.get("url") if isinstance(item, dict) else item
        if url:
            urls.append(url)
    return urls


def chapter_number(title, index):
    m = re.search(r"(\d+(?:\.\d+)?)", title or "")
    if m:
        try:
            return float(m.group(1))
        except ValueError:
            pass
    return float(index + 1)


def existing_pages(directory):
    done = set()
    if not os.path.isdir(directory):
        return done
    for name in os.listdir(directory):
        if name.endswith(".dl") or name.endswith(".tmp"):
            continue
        stem, ext = os.path.splitext(name)
        if not stem.isdigit():
            continue
        if ext.lower() not in (".jpg", ".jpeg", ".png", ".webp", ".gif"):
            continue
        try:
            if os.path.getsize(os.path.join(directory, name)) > 0:
                done.add(int(stem))
        except OSError:
            pass
    return done


def ext_of(url):
    m = re.search(r"\.(jpe?g|png|webp|gif)(?:\?|$)", url, re.I)
    return "." + (m.group(1).lower() if m else "jpg")


def download_image(url, target, referer):
    req = urllib.request.Request(
        url, headers={"User-Agent": UA, "Referer": referer, "Accept": "image/*,*/*"}
    )
    with urllib.request.urlopen(req, timeout=90) as resp:
        data = resp.read()
    if not data:
        raise RuntimeError("空响应")
    tmp = target + ".dl"
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, target)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--slug", required=True, help="源站的 path_word")
    ap.add_argument("--title-dir", required=True)
    ap.add_argument("--from", dest="start", type=int, default=1)
    ap.add_argument("--to", dest="end", type=int, default=9999)
    ap.add_argument("--site-tag", default=SITE_TAG)
    ap.add_argument(
        "--library",
        default=os.path.join(REPO, "ComicLibrary", "downloads"),
    )
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--json", default="")
    args = ap.parse_args()

    page = comic_page(args.slug)
    print(
        "host=%s dnt=%s ccz=%s uuid=%d title=%s"
        % (page["host"], page["dnt"], (page["ccz"] or "")[:8], len(page["uuids"]), page["title"]),
        flush=True,
    )
    chapters = chapter_table(args.slug, page["dnt"], page["ccz"], page["host"])
    print("章节表 %d 条" % len(chapters), flush=True)

    root = os.path.join(args.library, args.title_dir)
    report = {"slug": args.slug, "root": root, "chapters": [], "failed": 0}
    for index, item in enumerate(chapters):
        number = chapter_number(item["title"], index)
        if number < args.start or number > args.end:
            continue
        name = "%d [%s]" % (int(number) if float(number).is_integer() else number, args.site_tag)
        directory = os.path.join(root, name)
        done = existing_pages(directory)
        record = dict(item)
        record["dir"] = name
        record["existing"] = len(done)
        if not args.apply:
            record["action"] = "would-download"
            report["chapters"].append(record)
            print("  plan %-10s %s (existing %d)" % (item["title"][:10], name, len(done)), flush=True)
            continue
        try:
            urls = chapter_images(args.slug, item["uuid"], page["host"])
        except Exception as exc:  # noqa: BLE001
            record["action"] = "failed"
            record["error"] = str(exc)
            report["failed"] += 1
            report["chapters"].append(record)
            print("  FAIL %-10s %s" % (item["title"][:10], exc), flush=True)
            continue
        record["pages"] = len(urls)
        written = 0
        os.makedirs(directory, exist_ok=True)
        # 图片走 CDN（不是 API）⇒ 可以并发；API 调用保持串行，别把站点打疼。
        import concurrent.futures as cf

        def one(item):
            index2, url = item
            if index2 in done:
                return index2, True, None
            target = os.path.join(directory, "%d%s" % (index2, ext_of(url)))
            for attempt in range(3):
                try:
                    download_image(url, target, "https://%s/" % page["host"])
                    return index2, True, None
                except Exception as exc:  # noqa: BLE001
                    last = exc
                time.sleep(0.5 * (attempt + 1))
            return index2, False, str(last)

        with cf.ThreadPoolExecutor(max_workers=8) as pool:
            for index2, ok, err in pool.map(
                one, [(i, u) for i, u in enumerate(urls)]
            ):
                if ok:
                    if index2 not in done:
                        written += 1
                else:
                    record.setdefault("errors", []).append("%d: %s" % (index2, err))
        record["written"] = written
        record["action"] = "downloaded"
        report["chapters"].append(record)
        print("  OK   %-10s pages=%d new=%d" % (item["title"][:10], len(urls), written), flush=True)
        time.sleep(random.uniform(0.8, 1.6))

    if args.json:
        os.makedirs(os.path.dirname(os.path.abspath(args.json)), exist_ok=True)
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(report, fh, ensure_ascii=False, indent=1)
    print("failed=%d" % report["failed"], flush=True)


if __name__ == "__main__":
    sys.exit(main())
