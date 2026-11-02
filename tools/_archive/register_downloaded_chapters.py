#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把磁盘上已下好的章节登记进 `local.db` 的 `downloadedChapters`（P48）。

## 为什么需要单独一步

`tools/baozi_app_download.py` 只负责落盘（因为 appcn 对 Dart 侧下 CF 挑战，
App 的下载器无法完成任务）。但 App 判断"这一章下好了没"读的是
`local.db.comics.downloadedChapters`，且**比的是章节 key**：

    LocalComic.downloadedChapters.contains(chapterKey)
        → lib/foundation/chapter_download_status.dart:93

🔴 这里有个坑：本作 DB 里原值是 `["119 [baozimh]"]` —— **目录名**而非 key，
`contains("119")` 恒为 false，所以磁盘有图却显示"未下载"。
本脚本按 key 重写，顺带修正这条历史脏值。

## 判定口径

- 目录名 `<key> [<siteTag>]` → 取 key
- 目录里**至少 1 个非 0 字节的页文件**才算完成（与 `_existingPageIndexes` 同判据）
- 只登记漫画自己的章节目录，跳过 `cover/`（封面池不是章节，见 A22）

用法：
  python tools/register_downloaded_chapters.py --comic-id <cid> \
      --title-dir "灭门家族的重生者" [--expect 152] [--dry-run]
"""
import argparse
import json
import os
import re
import shutil
import sqlite3
import time

SITE_TAG = "baozimh"
IMG_EXTS = {"jpg", "jpeg", "png", "webp", "gif", "jpe"}
# P49（2026-10-27）：目录名升级为四件套 `[<lang>] <key> [<site>]`，
# 语言段可选（老目录没有），所以正则把前导 `[...]` 做成可选项。
DIR_RE = re.compile(r"^(?:\[[^\]]{2,12}\]\s*)?(\d+(?:\.\d+)?)\s*\[([^\]]*)\]$")
COVER_DIR = "cover"


def page_count(path):
    n = 0
    for name in os.listdir(path):
        lower = name.lower()
        if lower.endswith(".dl") or lower.endswith(".tmp"):
            continue
        full = os.path.join(path, name)
        if not os.path.isfile(full) or os.path.getsize(full) == 0:
            continue
        ext = lower.rsplit(".", 1)[-1] if "." in lower else ""
        if ext in IMG_EXTS:
            n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--comic-id", required=True)
    ap.add_argument("--title-dir", required=True)
    ap.add_argument("--library-root", default=None)
    ap.add_argument("--local-db", default=None)
    ap.add_argument("--expect", type=int, default=None)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    root = args.library_root or os.path.join(here, "ComicLibrary", "downloads")
    comic_dir = os.path.join(root, args.title_dir)
    db = args.local_db or os.path.join(here, "data", "local.db")

    if not os.path.isdir(comic_dir):
        raise SystemExit(f"comic dir not found: {comic_dir}")
    if not os.path.exists(db):
        raise SystemExit(f"local.db not found: {db}")

    found = {}          # key -> page count
    empty_dirs = []
    skipped = []
    for name in sorted(os.listdir(comic_dir)):
        full = os.path.join(comic_dir, name)
        if not os.path.isdir(full):
            continue
        if name.strip().lower() == COVER_DIR:
            continue
        m = DIR_RE.match(name.strip())
        if not m:
            skipped.append(name)
            continue
        tag = m.group(2).strip()
        if tag and tag != SITE_TAG:
            skipped.append(name)
            continue
        pages = page_count(full)
        if pages == 0:
            empty_dirs.append(name)
            continue
        found[m.group(1)] = pages

    keys = sorted(found, key=lambda k: float(k))
    print(f"[scan] chapters with pages: {len(keys)}")
    if empty_dirs:
        print(f"[warn] empty dirs (not registered): {empty_dirs[:10]}")
    if skipped:
        print(f"[info] skipped non-chapter dirs: {skipped[:10]}")
    total_pages = sum(found.values())
    print(f"[scan] total pages: {total_pages}")
    if keys:
        print(f"[scan] key range: {keys[0]} .. {keys[-1]}")
    if args.expect is not None and len(keys) != args.expect:
        print(f"[warn] expected {args.expect} chapters, got {len(keys)}")

    # 连续性检查：缺哪些 key
    if keys:
        ints = {int(float(k)) for k in keys}
        holes = [i for i in range(int(float(keys[0])), int(float(keys[-1])) + 1) if i not in ints]
        if holes:
            print(f"[warn] missing chapter keys: {holes[:20]}"
                  f"{' ...' if len(holes) > 20 else ''}")

    if args.dry_run:
        print("[dry-run] nothing written")
        return 0

    backup = db + ".bak_p48_reg_" + time.strftime("%Y%m%d_%H%M%S")
    shutil.copy2(db, backup)
    print("backup:", backup)

    con = sqlite3.connect(db, timeout=15)
    try:
        row = con.execute(
            "SELECT id, title, downloadedChapters FROM comics WHERE id = ?",
            (args.comic_id,),
        ).fetchone()
        if not row:
            raise SystemExit(f"comic row not found in local.db: {args.comic_id}")
        old = json.loads(row[2]) if row[2] else []
        print(f"[db] {row[1]}: old downloadedChapters = {old}")

        payload = json.dumps(keys, ensure_ascii=False)
        con.execute(
            "UPDATE comics SET downloadedChapters = ? WHERE id = ?",
            (payload, args.comic_id),
        )
        con.commit()
        after = con.execute(
            "SELECT downloadedChapters FROM comics WHERE id = ?",
            (args.comic_id,),
        ).fetchone()[0]
        parsed = json.loads(after)
        print(f"[db] written {len(parsed)} keys; first={parsed[:3]} last={parsed[-3:]}")
        if len(parsed) != len(keys):
            raise SystemExit("write verification failed")
    finally:
        con.close()

    # 落一份报告，便于事后核对
    report = {
        "comicId": args.comic_id,
        "chapters": len(keys),
        "totalPages": total_pages,
        "keyRange": [keys[0], keys[-1]] if keys else None,
        "perChapter": found,
    }
    out = os.path.join(here, "builds", "register_downloaded_chapters.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=1)
    print("report:", out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
