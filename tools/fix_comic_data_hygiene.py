# -*- coding: utf-8 -*-
"""P50 数据体检：章节顺序归位 + 清掉已完成的残留下载任务。

两件独立的事，都只动数据不动文件：

1. `comics.chapters` / `downloadedChapters` 的**顺序**。
   JSON object 的键序就是详情页章节列表的顺序（扁平 `ComicChapters(Map)`
   不排序，按插入序渲染）。历史上有脚本重建过这个 map，把某一话挪到了末尾，
   于是「第120话」跑到列表最后一位。这里按数值升序重新落一遍。

2. `downloading_tasks.json` 里的**幽灵任务**。
   章节图已经被外部脚本（tools/baozi_app_download.py）下完、`downloadedChapters`
   也登记了，但 App 里那次点击留下的任务还挂在队列里（downloadedCount=0、
   wasRunning=false），于是详情页把这一话判成"待命"（浅绿）—— 明明磁盘上齐全。
   任务没有任何进度、目标章节又已在 `downloadedChapters` 里，就是幽灵，
   直接移除。

用法：
    python -u tools/fix_comic_data_hygiene.py --dry-run
    python -u tools/fix_comic_data_hygiene.py
"""

import argparse
import json
import os
import shutil
import sqlite3
import sys
import time

DATA_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data"
)
LOCAL_DB = os.path.join(DATA_DIR, "local.db")
TASKS_JSON = os.path.join(DATA_DIR, "downloading_tasks.json")


def _chap_key(text):
    """排序键：纯数字按数值，`12.5` 这类半话按浮点，其它排到最后。"""
    try:
        return (0, float(text))
    except (TypeError, ValueError):
        return (1, str(text))


def _backup(path):
    if not os.path.exists(path):
        return None
    stem, ext = os.path.splitext(path)
    dest = f"{stem}.bak_p50_hygiene_{time.strftime('%Y%m%d_%H%M%S')}{ext}"
    shutil.copy2(path, dest)
    return dest


def fix_chapter_order(apply):
    con = sqlite3.connect(LOCAL_DB)
    con.row_factory = sqlite3.Row
    rows = con.execute(
        "select id, title, chapters, downloadedChapters from comics"
    ).fetchall()
    changes = []
    for row in rows:
        update = {}
        for col in ("chapters", "downloadedChapters"):
            raw = row[col]
            if not raw:
                continue
            try:
                value = json.loads(raw)
            except (TypeError, ValueError):
                continue
            # 只处理扁平 `{key: 标题}` 与 `[key, ...]`；分组/多版本结构原样放过。
            if isinstance(value, dict):
                keys = list(value.keys())
                ordered = [k for k in sorted(keys, key=_chap_key)]
                if ordered != keys:
                    update[col] = json.dumps(
                        {k: value[k] for k in ordered},
                        ensure_ascii=False,
                    )
            elif isinstance(value, list):
                if all(isinstance(v, str) for v in value):
                    ordered = sorted(value, key=_chap_key)
                    if ordered != value:
                        update[col] = json.dumps(ordered, ensure_ascii=False)
        if update:
            changes.append((row["id"], row["title"], list(update.keys())))
            if apply:
                sets = ", ".join(f"{c} = ?" for c in update)
                con.execute(
                    f"update comics set {sets} where id = ?",
                    list(update.values()) + [row["id"]],
                )
    if apply:
        con.commit()
    con.close()
    return changes


def prune_ghost_tasks(apply):
    """移除"目标章节已经全部登记为已下载、且毫无进度"的下载任务。"""
    if not os.path.exists(TASKS_JSON):
        return [], []
    try:
        tasks = json.load(open(TASKS_JSON, encoding="utf-8"))
    except (TypeError, ValueError):
        return [], []
    if not isinstance(tasks, list):
        return [], []

    con = sqlite3.connect(LOCAL_DB)
    con.row_factory = sqlite3.Row
    downloaded = {}
    for row in con.execute("select id, downloadedChapters from comics"):
        try:
            downloaded[row["id"]] = set(json.loads(row["downloadedChapters"] or "[]"))
        except (TypeError, ValueError):
            downloaded[row["id"]] = set()
    con.close()

    kept, dropped = [], []
    for task in tasks:
        comic_id = task.get("comicId")
        chapters = task.get("chapters") or []
        bytes_done = task.get("downloadedCount") or 0
        has_progress = bool(task.get("images")) or bytes_done > 0
        if (
            task.get("type") == "ImagesDownloadTask"
            and chapters
            and not has_progress
            and not task.get("wasRunning")
            and set(chapters) <= downloaded.get(comic_id, set())
        ):
            dropped.append(
                (comic_id, task.get("comicTitle"), chapters, bytes_done)
            )
        else:
            kept.append(task)

    if apply and dropped:
        _backup(TASKS_JSON)
        with open(TASKS_JSON, "w", encoding="utf-8", newline="\n") as fp:
            json.dump(kept, fp, ensure_ascii=False)
    return dropped, kept


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    apply = not args.dry_run

    if apply:
        _backup(LOCAL_DB)

    order = fix_chapter_order(apply)
    print(f"[顺序] 需重排的漫画 {len(order)} 本")
    for comic_id, title, cols in order:
        print(f"  - {title} :: {','.join(cols)}")

    dropped, kept = prune_ghost_tasks(apply)
    print(f"[任务] 幽灵任务 {len(dropped)} 条，保留 {len(kept)} 条")
    for comic_id, title, chapters, done in dropped:
        print(f"  - {title} :: chapters={chapters} downloadedCount={done}")
    if not apply:
        print("（dry-run，未写盘）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
