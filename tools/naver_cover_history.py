#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""从 Wayback 的 Naver 作品页快照里还原「当时挂的是哪张封面」。

论证方式：Naver 封面 URL 带随机 UUID，**换封面即换 URL**。所以只要逐个快照
抽取页面里的 `thumbnail_IMAG21_*`（480×623 主视觉），按时间排列，就能把每次
更换界定在「上一个快照」与「本快照」之间。

用发 7890 代理（本机代理对 pstatic / archive.org 有效；1393 会 502）。
"""
import json
import re
import sys
from concurrent.futures import ThreadPoolExecutor

import requests

PROXY = "http://127.0.0.1:7890"
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
)
THUMB_RE = re.compile(
    r"thumbnail_IMAG21_([0-9a-f-]{36})\.(?:jpg|png)"
)
TITLE_ID = "819946"


def snapshots():
    url = (
        "https://web.archive.org/cdx/search/cdx"
        f"?url=comic.naver.com%2Fwebtoon%2Flist%3FtitleId%3D{TITLE_ID}"
        "&output=json&fl=timestamp,statuscode&filter=statuscode:200"
        "&collapse=digest&limit=600"
    )
    r = requests.get(url, proxies={"https": PROXY, "http": PROXY}, timeout=120)
    r.raise_for_status()
    rows = r.json()
    return [row[0] for row in rows[1:]]


def thumb_of(ts):
    target = (
        f"https://web.archive.org/web/{ts}id_/https://comic.naver.com/webtoon/list"
        f"?titleId={TITLE_ID}"
    )
    try:
        r = requests.get(
            target,
            proxies={"https": PROXY, "http": PROXY},
            headers={"User-Agent": UA},
            timeout=90,
        )
        if r.status_code != 200:
            return ts, None, f"http {r.status_code}"
        hits = THUMB_RE.findall(r.text)
        return ts, (hits[0] if hits else None), None if hits else "no-imag21"
    except Exception as exc:  # noqa: BLE001
        return ts, None, str(exc)


def main():
    stamps = snapshots()
    print(f"snapshots={len(stamps)}", flush=True)
    out = []
    with ThreadPoolExecutor(max_workers=4) as pool:
        for ts, uid, err in pool.map(thumb_of, stamps):
            out.append({"ts": ts, "uuid": uid, "err": err})
            print(f"{ts}  {uid or '-'}  {err or ''}", flush=True)
    out.sort(key=lambda x: x["ts"])
    with open(sys.argv[1] if len(sys.argv) > 1 else "wb_covers.json", "w",
              encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)

    # 折叠成「首见时间」序列
    seen = {}
    for item in out:
        uid = item.get("uuid")
        if uid and uid not in seen:
            seen[uid] = item["ts"]
    print("\n=== 首次出现的封面（按时间）===")
    for uid, ts in sorted(seen.items(), key=lambda kv: kv[1]):
        print(ts, uid)


if __name__ == "__main__":
    main()
