#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""章节一致性体检（P51，2026-10-27）。

P49 把语言段写进目录名 + DB key，结果三处同时坏掉：排序变字典序、
"已下载"判不出来、源站 key 对不上。这个脚本就是那次的**回归闸门**：
以后再有人想动目录名或 key，先跑它。

## 检查项（任一不满足 → 退出码非 0）

1. `chapters` 的 key 里不能再出现 `[zh-Hans]` 这类语言前缀；
2. 扁平章节的 key 顺序必须是**数值升序**（0,1,2,…,10,11，不是 0,1,10,100）；
3. `downloadedChapters` 里不许有 `chapters` 不认识的 key（幽灵下载标记）；
4. key 形如目录名的漫画，磁盘上必须有同名目录（否则读不到图）；
5. 磁盘上每个章节目录都必须在 `chapters` 里登记（否则它永远打不开）。

用法：
    python -u tools/verify_chapter_consistency.py
    python -u tools/verify_chapter_consistency.py --json
"""
import argparse
import json
import os
import re
import sqlite3
import sys

DATA_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data"
)
LOCAL_DB = os.path.join(DATA_DIR, "local.db")
LIBRARY_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "ComicLibrary",
    "downloads",
)

LANG_PREFIX_RE = re.compile(r"^\[[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?\]\s+")
LEADING_NUM_RE = re.compile(r"^(\d+(?:\.\d+)?)")
DIR_ISH_RE = re.compile(r"^\d+(?:\.\d+)?(\s*\[[^\]]*\])+\s*$")


def num_of(key):
    m = LEADING_NUM_RE.match(key)
    return float(m.group(1)) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    failures = []
    notes = []

    def fail(comic, check, detail):
        failures.append({"comic": comic, "check": check, "detail": detail})

    con = sqlite3.connect("file:" + LOCAL_DB + "?mode=ro", uri=True)
    rows = con.execute(
        "select id, title, directory, chapters, downloadedChapters from comics"
    ).fetchall()
    con.close()

    for cid, title, directory, chapters, dch in rows:
        try:
            ch_map = json.loads(chapters) if chapters else {}
        except Exception as exc:  # noqa: BLE001
            fail(title, "chapters-json", str(exc))
            continue
        if not isinstance(ch_map, dict):
            fail(title, "chapters-type", type(ch_map).__name__)
            continue

        keys = list(ch_map.keys())
        flat = all(isinstance(v, str) for v in ch_map.values())

        # 1. 残留语言前缀
        bad = [k for k in keys if LANG_PREFIX_RE.match(k)]
        if bad:
            fail(title, "lang-prefix-in-key", f"{len(bad)} 个，如 {bad[0]!r}")

        # 2. 数值升序
        if flat:
            nums = [num_of(k) for k in keys]
            if all(n is not None for n in nums):
                if nums != sorted(nums):
                    where = next(
                        i for i in range(1, len(nums)) if nums[i] < nums[i - 1]
                    )
                    fail(
                        title,
                        "chapter-order",
                        f"第 {where} 位 {keys[where - 1]!r} 后面跟 {keys[where]!r}",
                    )

        # 3. 幽灵下载标记。判据必须是「扁平化之后的全集」：
        # 分组 map 的顶层键是组名（`默認`），版本化 map 的顶层键是话号，
        # 拿顶层键去比对 `downloadedChapters` 会 100% 误报。
        known = set(keys)
        for v in ch_map.values():
            if isinstance(v, dict):
                known.update(v.keys())
            elif isinstance(v, list):
                for item in v:
                    if isinstance(item, dict) and isinstance(item.get("key"), str):
                        known.add(item["key"])
        try:
            d_list = json.loads(dch) if dch else []
        except Exception:  # noqa: BLE001
            d_list = []
        if isinstance(d_list, list):
            ghosts = [k for k in d_list if k not in known]
            if ghosts:
                fail(
                    title,
                    "ghost-downloaded",
                    f"{len(ghosts)} 个，如 {ghosts[0]!r}",
                )

        # 4/5. 磁盘对账（只对 key 就是目录名的漫画做）
        dir_ish = [k for k in keys if DIR_ISH_RE.match(k)]
        if len(dir_ish) < max(1, len(keys) // 2):
            notes.append(f"{title}: key 不是目录名形态，跳过磁盘对账")
            continue
        comic_dir = directory
        if not os.path.isabs(comic_dir):
            comic_dir = os.path.join(LIBRARY_DIR, directory)
        if not os.path.isdir(comic_dir):
            fail(title, "dir-missing", comic_dir)
            continue
        on_disk = {
            n for n in os.listdir(comic_dir) if os.path.isdir(os.path.join(comic_dir, n))
        }
        missing = [k for k in dir_ish if k not in on_disk]
        if missing:
            fail(
                title,
                "key-without-dir",
                f"{len(missing)} 个，如 {missing[0]!r}",
            )
        unregistered = [
            n
            for n in on_disk
            if DIR_ISH_RE.match(n) and n not in ch_map
        ]
        if unregistered:
            fail(
                title,
                "dir-without-key",
                f"{len(unregistered)} 个，如 {unregistered[0]!r}",
            )

    if args.json:
        print(json.dumps({"failures": failures, "notes": notes}, ensure_ascii=False, indent=2))
    else:
        for n in notes:
            print("[note]", n)
        if not failures:
            print(f"[PASS] {len(rows)} 本漫画，0 个问题")
        else:
            print(f"[FAIL] {len(failures)} 个问题：")
            for f in failures:
                print(f"  - {f['comic']} / {f['check']}: {f['detail']}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
