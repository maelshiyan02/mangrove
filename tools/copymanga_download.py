#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""拷贝漫画（copy_manga / mangacopy）批量下载器。

## 为什么自己写，而不用 App 自带的下载器

App 的 `ImagesDownloadTask` 用**源给的章节 key**算目录名，而拷贝漫画的章节 key
是 **UUID**（`230c97f8-632e-11ee-9733-d3d228a76de6`）⇒ 落盘目录是一串 UUID，
本地漫画的章节列表也得靠覆盖表才看得出话号。这次要做的是**本地漫画**（跳网络
阶段直接落地），目录名由我们自己定，于是走 Python：目录名干净、可断点续传、
也不受 App 下载队列的并发/风控策略影响。

## 接口与签名（照抄 App 的 `copy_manga` 源 JS）

* 章节列表：`GET /api/v3/comic/{id}/group/{group}/chapters?limit=100&offset=N`
* 章节图片：`GET /api/v3/comic/{id}/chapter2/{epId}`
* 请求头：`x-auth-timestamp` + `x-auth-signature`（HMAC-SHA256，密钥是源 JS 里的
  base64 串），外加 `deviceinfo`/`device`/`pseudoid` 三件设备指纹。

## 风控（踩过的坑）

* **软风控**：HTTP 200 但 `results` 里没有 `list`/`chapter` ⇒ 必须换设备指纹重试，
  重试还失败就换 API 域（源 JS 的 `withApiFailover` 就是干这个的）。
* **硬风控 210**：访问过于频繁 ⇒ 退避 10s 起阶梯加长。
* 两次请求之间要 **600–1200ms** 的随机间隔（源 JS 的 `throttle`），否则会被判
  成自动化。

## 落盘约定（与 App 的本地漫画扫描器一致）

* 漫画根：`<ComicLibrary>/downloads/<漫画目录名>/`
* 章节目录：`<话号> [<站点标签>]`，站点标签 `copymanga`
* 页文件：`<顺序号>.<ext>`，从 0 开始（`chapter_download_status.dart` 的判据）

用法：
    python -u tools/copymanga_download.py --comic-id ngdgdhlhypj \
        --title-dir "那個大公的華麗婚姻騙局" --from 1 --to 69 \
        [--apply] [--json builds/copymanga_dl.json]
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
import urllib.parse
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIR = os.path.join(REPO, "data", "comic_source")
# 源 JS 里的 API 域候选（与 App 的 withApiFailover 同源）。
API_HOSTS = ["api.copy202601.com", "api.copy5000.com", "api.copy-manga.com"]
# HMAC 密钥（源 JS `get headers()` 里的 base64 串）。
HMAC_SECRET = base64.b64decode("M2FmMDg1OTAzMTEwMzJlZmUwNjYwNTUwYTA1NjNhNTM=")
SITE_TAG = "copymanga"
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0"
)

_print_lock = __import__("threading").Lock()
_state = {}


def log(*args):
    with _print_lock:
        print(*args, flush=True)


def device_pool():
    """从 App 的源 JS 里取设备指纹池（源 JS 更新了这里也跟着更新）。"""
    pool = []
    try:
        names = [n for n in os.listdir(SOURCE_DIR) if n.startswith("copy_manga")]
        names.sort()
        for name in names:
            if not name.endswith(".js"):
                continue
            text = open(os.path.join(SOURCE_DIR, name), encoding="utf-8").read()
            for m in re.finditer(
                r'\{\s*deviceinfo:\s*"([^"]+)"\s*,\s*device:\s*"([^"]+)"\s*\}', text
            ):
                pool.append({"deviceinfo": m.group(1), "device": m.group(2)})
            if pool:
                break
    except OSError:
        pass
    if not pool:
        pool = [{"deviceinfo": "3267710V-9475", "device": "GX7A4.204516.772"}]
    return pool


def current_identity():
    """App 已保存的登录 token（拷贝漫画的 token 是账号级，能省很多风控）。"""
    path = os.path.join(SOURCE_DIR, "copy_manga.data")
    try:
        data = json.load(open(path, encoding="utf-8"))
        return data.get("token") or "", data
    except (OSError, ValueError):
        return "", {}


TOKEN, _source_data = current_identity()
POOL = device_pool()
_fingerprint = dict(POOL[0])


def rotate_fingerprint():
    """换一台"设备"（源 JS 的 autoResetDeviceFingerprint）。"""
    global _fingerprint
    _fingerprint = dict(random.choice(POOL))
    return _fingerprint


def headers():
    ts = str(int(time.time()))
    sig = hmac.new(HMAC_SECRET, ts.encode("utf-8"), hashlib.sha256).hexdigest()
    return {
        "User-Agent": "COPY/3.0.9",
        "source": "copyApp",
        "deviceinfo": _fingerprint["deviceinfo"],
        "dt": time.strftime("%Y.%m.%d"),
        "platform": "3",
        "referer": "com.copymanga.app-3.0.9",
        "version": "3.0.9",
        "device": _fingerprint["device"],
        "pseudoid": "tdBuTdjCPMW5u0pY",
        "Accept": "application/json",
        "region": "0",
        "authorization": "Token " + TOKEN,
        "umstring": "b4c89ca4104ea9a97750314d791520ac",
        "x-auth-timestamp": ts,
        "x-auth-signature": sig,
    }


def api_get(path, tries=4, timeout=45):
    """GET 一个 API 路径。返回解析后的 json；软/硬风控都自动退避重试。"""
    last = "unknown"
    for attempt in range(tries):
        host = API_HOSTS[attempt % len(API_HOSTS)]
        url = "https://%s%s" % (host, path)
        try:
            req = urllib.request.Request(url, headers=headers())
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read().decode("utf-8", "replace")
            if resp.status == 210:
                wait = 10 + attempt * 5
                log("  210 风控，等待 %ss 后重试 (%d/%d)" % (wait, attempt + 1, tries))
                time.sleep(wait)
                rotate_fingerprint()
                continue
            data = json.loads(body)
            results = data.get("results")
            if not results:
                # 软风控：200 但内容为空 ⇒ 换指纹重试。
                log("  软风控（results 为空），换指纹重试 (%d/%d)" % (attempt + 1, tries))
                rotate_fingerprint()
                time.sleep(3 + attempt * 2)
                continue
            return results
        except urllib.error.HTTPError as exc:
            last = "HTTP %s" % exc.code
        except Exception as exc:  # noqa: BLE001
            last = str(exc)
        time.sleep(2 + attempt * 2)
    raise RuntimeError("API failed: %s (%s)" % (path, last))


def throttle():
    """请求之间的随机间隔（源 JS 的 throttle：600–1200ms）。"""
    time.sleep(random.uniform(0.6, 1.2))


def chapter_number(name, index):
    """从章节名里读话号：`第69话` → 69；读不出就按序号。"""
    m = re.search(r"(\d+(?:\.\d+)?)", name or "")
    if m:
        try:
            return float(m.group(1))
        except ValueError:
            pass
    return float(index + 1)


def fetch_chapters(comic_id, group="default"):
    chapters = []
    offset = 0
    while True:
        throttle()
        path = (
            "/api/v3/comic/%s/group/%s/chapters?limit=100&offset=%d"
            "&in_mainland=true&request_id=" % (comic_id, group, offset)
        )
        results = api_get(path)
        items = results.get("list") or []
        chapters.extend(items)
        total = results.get("total") or 0
        offset += 100
        if not items or offset >= total:
            break
    return chapters


def fetch_images(comic_id, ep_id):
    throttle()
    path = "/api/v3/comic/%s/chapter2/%s?in_mainland=true&request_id=" % (comic_id, ep_id)
    results = api_get(path)
    chapter = results.get("chapter") or {}
    contents = chapter.get("contents") or []
    urls = []
    for item in contents:
        url = item.get("url") if isinstance(item, dict) else item
        if url:
            urls.append(url)
    return urls


def existing_pages(directory):
    """目录里已经下好的页（≥1 字节才算完成，与 App 的判据一致）。"""
    done = set()
    if not os.path.isdir(directory):
        return done
    for name in os.listdir(directory):
        if name.endswith(".dl") or name.endswith(".tmp"):
            continue
        stem, ext = os.path.splitext(name)
        if not stem.isdigit() or ext.lower() not in (".jpg", ".jpeg", ".png", ".webp", ".gif"):
            continue
        try:
            if os.path.getsize(os.path.join(directory, name)) > 0:
                done.add(int(stem))
        except OSError:
            pass
    return done


def download_image(url, target):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://www.copy5000.com/"})
    with urllib.request.urlopen(req, timeout=90) as resp:
        data = resp.read()
    if len(data) == 0:
        raise RuntimeError("empty body")
    tmp = target + ".dl"
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, target)


def ext_of(url):
    m = re.search(r"\.(jpe?g|png|webp|gif)(?:\?|$)", url, re.I)
    return "." + (m.group(1).lower() if m else "jpg")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--comic-id", required=True)
    ap.add_argument("--title-dir", required=True, help="漫画目录名（downloads/ 下面那个）")
    ap.add_argument("--from", dest="start", type=int, default=1)
    ap.add_argument("--to", dest="end", type=int, default=9999)
    ap.add_argument("--group", default="default")
    ap.add_argument("--site-tag", default=SITE_TAG)
    ap.add_argument("--library", default=os.path.join(REPO, "ComicLibrary", "downloads"))
    ap.add_argument("--apply", action="store_true", help="真下载；默认只报计划")
    ap.add_argument("--json", default="")
    args = ap.parse_args()

    root = os.path.join(args.library, args.title_dir)
    chapters = fetch_chapters(args.comic_id, args.group)
    log("chapters total = %d" % len(chapters))

    plan = []
    for index, item in enumerate(chapters):
        number = chapter_number(item.get("name", ""), index)
        if number < args.start or number > args.end:
            continue
        name = "%s [%s]" % (_fmt(number), args.site_tag)
        plan.append(
            {
                "number": number,
                "title": item.get("name", ""),
                "uuid": item.get("uuid"),
                "dir": os.path.join(root, name),
            }
        )
    log("selected %d chapter(s) in [%d, %d]" % (len(plan), args.start, args.end))

    report = {"comicId": args.comic_id, "root": root, "chapters": [], "done": 0, "failed": 0}
    for entry in plan:
        directory = entry["dir"]
        os.makedirs(directory, exist_ok=True)
        done = existing_pages(directory)
        record = dict(entry)
        record["existing"] = len(done)
        if not args.apply:
            record["action"] = "would-download"
            report["chapters"].append(record)
            log("  plan  %-10s %-24s existing=%d" % (entry["title"][:10], os.path.basename(directory), len(done)))
            continue
        try:
            urls = fetch_images(args.comic_id, entry["uuid"])
        except Exception as exc:  # noqa: BLE001
            record["action"] = "image-list-failed"
            record["error"] = str(exc)
            report["failed"] += 1
            report["chapters"].append(record)
            log("  FAIL  %-10s %s" % (entry["title"][:10], exc))
            continue
        record["pages"] = len(urls)
        written = 0
        for index, url in enumerate(urls):
            if index in done:
                continue
            target = os.path.join(directory, "%d%s" % (index, ext_of(url)))
            try:
                download_image(url, target)
                written += 1
            except Exception as exc:  # noqa: BLE001
                record.setdefault("errors", []).append("%d: %s" % (index, exc))
        record["written"] = written
        record["action"] = "downloaded"
        report["done"] += 1
        report["chapters"].append(record)
        log("  OK    %-10s pages=%d new=%d" % (entry["title"][:10], len(urls), written))

    if args.json:
        path = args.json
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(report, fh, ensure_ascii=False, indent=1)
        log("report -> %s" % path)
    log("done=%d failed=%d" % (report["done"], report["failed"]))
    return 0 if report["failed"] == 0 else 1


def _fmt(number):
    """话号 → 目录名里的整数形态（1 而不是 1.0）。"""
    if float(number).is_integer():
        return str(int(number))
    return ("%g" % number)


if __name__ == "__main__":
    sys.exit(main())
