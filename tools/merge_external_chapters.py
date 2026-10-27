# -*- coding: utf-8 -*-
"""把「别的源补来的章节」并进一本漫画的章节表。

## 场景

一本书的主源（例如包子 152 话）落后于原作最新（157 话）。补来的那几话来自
另一个源、往往是**另一个语言**，目录名带 `[en] 152 [Asura Scans] [comix.to]`。

`local.db.comics.chapters` 是扁平 `{ key: 标题 }`，key 的坐标系必须和主源一致
（这里两边都是 **话号 - 1**），否则详情页的"已下载"判定（靠
`chapterDirectoryName` 反算目录名）会失效 —— 磁盘上有图却显示未下载。

## 用法

    python -u tools/merge_external_chapters.py \\
        --local-id miemenjiazudezhongshengzhe-yangpyungpainkillersaintnine \\
        --from 153 --to 157 --dry-run

    python -u tools/merge_external_chapters.py --local-id ... --from 153 --to 157 --apply
"""

import argparse
import json
import os
import re
import shutil
import sqlite3
import sys
import time

DATA_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data"
)
LOCAL_DB = os.path.join(DATA_DIR, "local.db")
LIBRARY_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "ComicLibrary",
    "downloads",
)


def _numeric_key(text):
    try:
        return (0, float(text))
    except (TypeError, ValueError):
        return (1, str(text))


def _has_images(path):
    if not os.path.isdir(path):
        return 0
    count = 0
    for name in os.listdir(path):
        full = os.path.join(path, name)
        if os.path.isfile(full) and os.path.getsize(full) > 1024:
            if name.lower().rsplit(".", 1)[-1] in (
                "webp",
                "jpg",
                "jpeg",
                "png",
                "gif",
                "jpe",
            ):
                count += 1
    return count


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--local-id", required=True, help="local.db 的漫画 id")
    parser.add_argument("--from", dest="start", type=int, required=True, help="起始话号")
    parser.add_argument("--to", dest="end", type=int, required=True, help="结束话号")
    parser.add_argument("--lang", default="en", help="这些章节的语言标签")
    parser.add_argument("--group", default="", help="翻译组名")
    parser.add_argument("--site", default="", help="来源站点标签")
    parser.add_argument(
        "--comic-id",
        help="域库 comic_id（remote:站点:id）；给了才会顺带写章节展示标签",
    )
    parser.add_argument(
        "--label",
        help='章节格子小字，如 "英文 · Asura Scans · comix.to"；默认按 lang/group/site 拼',
    )
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    con = sqlite3.connect(LOCAL_DB)
    con.row_factory = sqlite3.Row
    row = con.execute(
        "select * from comics where id = ?", (args.local_id,)
    ).fetchone()
    if row is None:
        print(f"[错误] 找不到 id={args.local_id}")
        return 2
    comic = dict(row)
    title = comic.get("title") or args.local_id
    directory = comic.get("directory") or title
    base = directory if os.path.isabs(directory) else os.path.join(
        LIBRARY_DIR, directory
    )
    chapters = json.loads(comic.get("chapters") or "{}")
    downloaded = json.loads(comic.get("downloadedChapters") or "[]")
    if not isinstance(chapters, dict):
        print("[错误] chapters 不是扁平 map")
        return 2
    downloaded_set = set(downloaded)

    print(f"[漫画] {title}")
    print(f"[目录] {base}")
    print(f"[现状] chapters {len(chapters)} 话 / downloaded {len(downloaded_set)} 条")

    added_chapters, added_downloads, missing = [], [], []
    for number in range(args.start, args.end + 1):
        key = str(number - 1)  # 与主源同一套 0-based 坐标系
        parts = [f"[{args.lang}]", key]
        if args.group:
            parts.append(f"[{args.group}]")
        if args.site:
            parts.append(f"[{args.site}]")
        dir_name = " ".join(parts)
        image_count = _has_images(os.path.join(base, dir_name))
        if image_count == 0:
            missing.append(dir_name)
            continue
        if key not in chapters:
            chapters[key] = f"第{number}话"
            added_chapters.append((key, chapters[key]))
        if key not in downloaded_set:
            added_downloads.append(key)
            downloaded_set.add(key)
        print(f"  + {dir_name}  ({image_count} 张)")

    print(f"[结果] 新增章节 {len(added_chapters)}，新增下载标记 {len(added_downloads)}")
    if missing:
        print(f"[警告] 以下目录不存在或没有图，已跳过：")
        for name in missing:
            print(f"  ? {name}")
    if not added_chapters and not added_downloads:
        print("（没有需要写的）")
        return 0
    if not args.apply:
        print("（dry-run，未写库；加 --apply 生效）")
        return 0

    ordered = {
        key: chapters[key]
        for key in sorted(chapters.keys(), key=_numeric_key)
    }
    ordered_downloads = sorted(downloaded_set, key=_numeric_key)

    stem, ext = os.path.splitext(LOCAL_DB)
    backup = f"{stem}.bak_p50_merge_{time.strftime('%Y%m%d_%H%M%S')}{ext}"
    shutil.copy2(LOCAL_DB, backup)
    print(f"[备份] {backup}")

    con.execute(
        "update comics set chapters = ?, downloadedChapters = ? where id = ?",
        (
            json.dumps(ordered, ensure_ascii=False),
            json.dumps(ordered_downloads, ensure_ascii=False),
            args.local_id,
        ),
    )
    con.commit()
    con.close()
    print("[完成] 已并入 local.db")

    if args.comic_id:
        _write_chapter_labels(args, [key for key, _ in added_chapters] or [
            str(n - 1) for n in range(args.start, args.end + 1)
        ])
    return 0


def _write_chapter_labels(args, keys):
    """给补进来的章节写展示标签（`chapter_labels`）。

    扁平章节的 key 只是个数字，组名/站点只活在目录名里，而扁平 map 没有
    scanlationGroup —— `chapterDirectoryName` 反算不出组名。想让格子小字
    显示"谁翻的、从哪来的"，只能由并库这一步直接写进去。
    """
    domain_db = os.path.join(DATA_DIR, "data", "mangrove.db")
    if not os.path.exists(domain_db):
        print("[警告] 找不到域库，跳过标签")
        return
    label = (args.label or "").strip()
    if not label:
        language = {
            "en": "英文",
            "zh-Hans": "简中",
            "zh-Hant": "繁中",
            "ja": "日文",
            "ko": "韩文",
        }.get(args.lang, args.lang)
        parts = [language]
        if args.group:
            parts.append(args.group)
        if args.site:
            parts.append(args.site)
        label = " · ".join(parts)

    con = sqlite3.connect(domain_db)
    row = con.execute(
        "select value_json from comic_field_overrides "
        "where comic_id = ? and field_key = 'chapter_labels'",
        (args.comic_id,),
    ).fetchone()
    labels = {}
    if row and row[0]:
        try:
            labels = json.loads(row[0])
        except (TypeError, ValueError):
            labels = {}
    changed = 0
    for key in keys:
        if labels.get(key) != label:
            labels[key] = label
            changed += 1
    con.execute(
        """
        insert into comic_field_overrides(comic_id, field_key, value_json, updated_at)
        values(?, 'chapter_labels', ?, ?)
        on conflict(comic_id, field_key) do update set
          value_json = excluded.value_json,
          updated_at = excluded.updated_at
        """,
        (args.comic_id, json.dumps(labels, ensure_ascii=False), int(time.time() * 1000)),
    )
    con.commit()
    con.close()
    print(f"[标签] {changed} 条 → {label}")


if __name__ == "__main__":
    sys.exit(main())
