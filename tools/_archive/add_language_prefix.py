#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""给章节目录补「语言段」，把三件套升级成四件套（P49，2026-10-27）。

## 规范（与 lib/foundation/chapter_directory.dart 一致）

    旧：`120 [baozimh]`
    新：`[zh-Hans] 120 [baozimh]`

语言是**分类的第一维**：同一话的简/繁/英/日版是不同内容，不是同一话的镜像。
多语种共站的源（comix.to / mangadex / comick）只靠站点标签区分会撞车，
所以语言必须写进目录名。

## 安全边界（重要）

只做 **同盘 os.rename**（瞬时，不复制不占空间），且：

- 已有语言段 / 不以话号开头的目录一律跳过（`cover`、`backup_*` 不动）
- `--dry-run` 先看清单
- 默认拒绝在漫画根目录里有 `*.dl`/`*.tmp`（说明还有下载在跑）

## 什么时候**不能**用这个脚本

本地漫画如果 `local.db.comics.chapters` 的 **key 就是目录名**（早期扫描入库的
记录，如 `0 [baozimh]`），改名会让 key 与磁盘脱钩 → 章节读不到。
这类漫画要么先重写 DB 的 chapters/downloadedChapters，要么**不要改名**。
本脚本只负责磁盘；DB 侧的迁移另行处理（见 --check-db）。

用法：
  python tools/add_language_prefix.py --dir "ComicLibrary/downloads/灭门家族的重生者" \
      --lang zh-Hans [--site baozimh] [--dry-run]
"""
import argparse
import json
import os
import re
import sys

LANG_RE = re.compile(r"^\[[A-Za-z]{2}(?:-[A-Za-z]{2,4})?\]\s*")
NUM_RE = re.compile(r"^(\d+(?:\.\d+)?)\s*(\[[^\]]*\]\s*)*$")


def has_language(name):
    return bool(LANG_RE.match(name))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="漫画根目录（含章节目录）")
    ap.add_argument("--lang", required=True, help="语言标签，如 zh-Hans / zh-Hant / en")
    ap.add_argument("--site", default=None, help="只处理站点标签匹配的目录（可选）")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--check-db", default=None,
                    help="local.db 路径；给出时会检查该漫画的 chapters key 是否等于目录名")
    args = ap.parse_args()

    root = args.dir
    if not os.path.isdir(root):
        raise SystemExit(f"dir not found: {root}")

    # 防御：还在下载的目录不改名
    for name in os.listdir(root):
        if name.lower().endswith((".dl", ".tmp")):
            if not args.dry_run:
                raise SystemExit(f"download in progress ({name}); retry later")
            print(f"[warn] download artifact present: {name}")

    if args.check_db:
        warn_db_keys(root, args.check_db)

    todo, skipped = [], []
    for name in sorted(os.listdir(root)):
        full = os.path.join(root, name)
        if not os.path.isdir(full):
            continue
        if has_language(name):
            skipped.append((name, "already has lang"))
            continue
        if not NUM_RE.match(name):
            skipped.append((name, "not a chapter dir"))
            continue
        if args.site and f"[{args.site}]" not in name:
            skipped.append((name, "site mismatch"))
            continue
        todo.append(name)

    print(f"[scan] {len(todo)} dir(s) to rename, {len(skipped)} skipped")
    if skipped:
        print("[skip]", [f"{n} ({r})" for n, r in skipped][:10])

    if args.dry_run:
        for name in todo[:10]:
            print(f"  {name}  ->  [{args.lang}] {name}")
        if len(todo) > 10:
            print(f"  ... and {len(todo) - 10} more")
        print("[dry-run] nothing renamed")
        return 0

    ok, failed = 0, []
    for name in todo:
        src = os.path.join(root, name)
        dst = os.path.join(root, f"[{args.lang}] {name}")
        if os.path.exists(dst):
            failed.append((name, "target exists"))
            continue
        try:
            os.rename(src, dst)
            ok += 1
        except OSError as exc:  # noqa: BLE001
            failed.append((name, str(exc)))

    print(f"[done] renamed={ok} failed={len(failed)}")
    for name, err in failed[:10]:
        print(f"  [fail] {name}: {err}")
    return 0 if not failed else 4


def warn_db_keys(root, db_path):
    """本地漫画的 chapters key 若就是目录名，改名会让它读不到图 —— 先提醒。"""
    try:
        import sqlite3
    except ImportError:  # pragma: no cover
        return
    if not os.path.exists(db_path):
        print(f"[db] missing: {db_path}")
        return
    base = os.path.basename(root.rstrip("\\/"))
    con = sqlite3.connect(db_path, timeout=10)
    try:
        rows = con.execute(
            "SELECT id, title, chapters FROM comics WHERE directory LIKE ?",
            (f"%{base}%",),
        ).fetchall()
    finally:
        con.close()
    if not rows:
        print(f"[db] no local record for '{base}' (network comic? keys are source keys)")
        return
    for cid, title, chapters in rows:
        try:
            keys = list(json.loads(chapters or "{}").keys())
        except Exception:  # noqa: BLE001
            print(f"[db] {title}: chapters not a flat map, skip check")
            continue
        looks_like_dir = [k for k in keys[:20] if re.match(r"^\d+\s*\[", k)]
        print(f"[db] {title}: {len(keys)} keys; "
              f"{len(looks_like_dir)}/20 sampled look like dir names")
        if looks_like_dir:
            print("🔴 该漫画的 key 就是目录名，改名会脱钩 —— 请先迁移 DB 再改名")


if __name__ == "__main__":
    sys.exit(main())
