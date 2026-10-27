#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把整座漫画库的章节目录升级成「四件套」命名，并同步 local.db（P49，2026-10-27）。

## 规则

    旧：`120 [baozimh]`
    新：`[zh-Hans] 120 [baozimh]`

语言是**分类第一维**：同一话的简/繁/英/日版是**不同内容**，不是镜像。
多语种共站（comix.to / mangadex / comick）只靠站点标签区分会撞车。

## 语种判定

按目录名里的**站点标签**推，不猜内容：

| 站点标签 | 语种 | 依据 |
| --- | --- | --- |
| `baozimh` | zh-Hans | 包子漫画只供简体 |
| `copymanga` / `dm5` / `manhuaren` / `komiic` | zh-Hans | 中文站 |
| `comix.to` | en | 本库现有 comix.to 章节的组（Rokari / Asura / Lua / Violet / HiveToons）都是英化组 |

要覆盖某本漫画的判定，用 `--override "漫画目录名=zh-Hant"`。

## DB 同步（必须，否则章节徽标全灭）

`downloadedChapters` 与 `chapters` 里存的是**章节目录名**（早期扫描入库的记录），
改目录名不改 DB → 磁盘有图却显示"未下载"。本脚本按 old→new 映射把两处一起改。
网络漫画的 key 是源 id（`"0"`），映射不命中则自然不动，安全。

## 跳过

- `cos写真`（写真集不是漫画，不按话次命名，见 `--skip`）
- 有任何**翻译工程**引用该漫画章节目录的（改名会让工程找不到图）
- 名字不是「话号开头」的目录（番外/手抄/UUID key）

用法：
  python tools/migrate_chapter_languages.py [--dry-run] [--only "灭门家族的重生者"]
"""
import argparse
import json
import os
import re
import shutil
import sqlite3
import time

IMG_EXTS = {"jpg", "jpeg", "png", "webp", "gif", "jpe", "avif"}
LANG_RE = re.compile(r"^\[[A-Za-z]{2}(?:-[A-Za-z]{2,4})\]\s*")
SITE_RE = re.compile(r"\[([^\]]*)\]")
CHAP_RE = re.compile(r"^(\d+(?:\.\d+)?)\s*(\[[^\]]*\]\s*)*$")

SITE_LANGUAGES = {
    "baozimh": "zh-Hans",
    "copymanga": "zh-Hans",
    "dm5": "zh-Hans",
    "manhuaren": "zh-Hans",
    "komiic": "zh-Hans",
    "Komiic": "zh-Hans",
    "mycomic": "zh-Hans",
    "goda": "zh-Hans",
    "comix.to": "en",
}
DEFAULT_SKIP = {"cos写真"}


def language_of_dirs(names):
    """一章的目录名能推出语种；多站点冲突时返回 None（不猜）。"""
    langs = set()
    for name in names:
        for tag in SITE_RE.findall(name):
            tag = tag.strip()
            if tag in SITE_LANGUAGES:
                langs.add(SITE_LANGUAGES[tag])
                break
    return langs.pop() if len(langs) == 1 else None


def has_pages(path):
    try:
        for name in os.listdir(path):
            lower = name.lower()
            if lower.endswith((".dl", ".tmp")):
                continue
            full = os.path.join(path, name)
            if os.path.isfile(full) and os.path.getsize(full) > 0:
                if "." in lower and lower.rsplit(".", 1)[-1] in IMG_EXTS:
                    return True
    except OSError:
        return False
    return False


def project_names(here):
    """翻译工程目录名（`<漫画> - <章节目录>`），用来判断改名是否会断链。"""
    base = os.path.join(here, "ComicLibrary", "projects")
    if not os.path.isdir(base):
        return []
    return [n for n in os.listdir(base) if os.path.isdir(os.path.join(base, n))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--library-root", default=None)
    ap.add_argument("--local-db", default=None)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--only", default=None, help="只处理这些漫画目录（逗号分隔）")
    ap.add_argument("--skip", default=None, help="额外跳过的漫画目录（逗号分隔）")
    ap.add_argument("--override", default=None,
                    help='强制某本漫画的语种，如 "扔掉的渣男，绝不再捡！=zh-Hans"')
    args = ap.parse_args()

    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    root = args.library_root or os.path.join(here, "ComicLibrary", "downloads")
    db = args.local_db or os.path.join(here, "data", "local.db")

    only = {s.strip() for s in args.only.split(",")} if args.only else None
    skip = set(DEFAULT_SKIP)
    if args.skip:
        skip |= {s.strip() for s in args.skip.split(",")}
    override = {}
    if args.override:
        for pair in args.override.split(","):
            if "=" in pair:
                k, v = pair.split("=", 1)
                override[k.strip()] = v.strip()

    projects = project_names(here)
    con = sqlite3.connect(db, timeout=15)
    con.row_factory = sqlite3.Row
    rows = {r["directory"].split("\\")[-1].split("/")[-1]: dict(r)
            for r in con.execute("SELECT id, title, directory, chapters, "
                                 "downloadedChapters FROM comics")}

    total_renamed, total_failed = 0, 0
    db_changes = {}
    plan = []          # (comic_dir, [ (old, new) ])
    problems = []

    for comic in sorted(os.listdir(root)):
        cdir = os.path.join(root, comic)
        if not os.path.isdir(cdir):
            continue
        if comic in skip or (only and comic not in only):
            continue
        dirs = [n for n in os.listdir(cdir)
                if os.path.isdir(os.path.join(cdir, n)) and n != "cover"]
        todo = [n for n in dirs if CHAP_RE.match(n) and not LANG_RE.match(n)]
        if not todo:
            continue
        lang = override.get(comic) or language_of_dirs(todo + dirs)
        if not lang:
            problems.append((comic, "语种判定失败（站点未知或有多个）"))
            continue
        broken = [p for p in projects if p.startswith(comic + " - ")]
        if broken:
            problems.append((comic, f"有翻译工程引用，改名会断链：{broken[0]}"))
            continue
        mapping = [(n, f"[{lang}] {n}") for n in todo]
        plan.append((comic, lang, mapping))

    for comic, lang, mapping in plan:
        print(f"== {comic}  ->  {lang}   ({len(mapping)} dir(s))")
        print(f"   e.g. {mapping[0][0]}  ->  {mapping[0][1]}")
    for comic, why in problems:
        print(f"!! {comic}: {why}")

    if args.dry_run:
        print("[dry-run] nothing changed")
        con.close()
        return 0

    if plan and os.path.exists(db):
        backup = db + ".bak_p49_lang_" + time.strftime("%Y%m%d_%H%M%S")
        shutil.copy2(db, backup)
        print("db backup:", backup)

    for comic, lang, mapping in plan:
        cdir = os.path.join(root, comic)
        done = {}
        for old, new in mapping:
            src, dst = os.path.join(cdir, old), os.path.join(cdir, new)
            if os.path.exists(dst):
                total_failed += 1
                continue
            try:
                os.rename(src, dst)
                done[old] = new
                total_renamed += 1
            except OSError as exc:  # noqa: BLE001
                total_failed += 1
                print(f"   [fail] {old}: {exc}")
        if done:
            db_changes[comic] = done

    # DB 同步：chapters 的 key 与 downloadedChapters 里出现目录名的一并换掉
    db_hits = 0
    for comic, mapping in db_changes.items():
        row = rows.get(comic)
        if not row:
            continue
        changed = False
        chapters = json.loads(row["chapters"] or "{}")
        new_chapters = {(mapping.get(k, k)): v for k, v in chapters.items()}
        if new_chapters != chapters:
            changed = True
        dl = json.loads(row["downloadedChapters"] or "[]")
        new_dl = [mapping.get(k, k) for k in dl]
        if new_dl != dl:
            changed = True
        if changed:
            con.execute(
                "UPDATE comics SET chapters = ?, downloadedChapters = ? WHERE id = ?",
                (json.dumps(new_chapters, ensure_ascii=False),
                 json.dumps(new_dl, ensure_ascii=False),
                 row["id"]),
            )
            db_hits += 1
    con.commit()
    con.close()

    print(f"[done] renamed={total_renamed} failed={total_failed} db_rows_updated={db_hits}")
    return 0 if total_failed == 0 else 4


if __name__ == "__main__":
    raise SystemExit(main())
