#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""本地漫画库的「语种 / 分类」标注（P49，2026-10-27）。

## 做什么

1. 给每本本地漫画补一个**语种标签**（`语言:简体中文` / `语言:English` / `语言:中文`）。
   复合漫画里同一本书可能既有简体源也有英文源，语种必须能在库里筛出来。
2. `cos写真` 不是漫画，补**分类标签** `分类:写真集` / `Photobook`，把它和连载漫画分开。
3. 顺手清掉 `灭门家族的重生者` 的 `chapters` 里那条历史脏 key
   `"119 [baozimh]"`（目录名当 key 用，导致多出一个假章节）。

## 为什么标在 tags 而不是改目录

语种在目录名里管"这一话是哪一版"（见 `chapter_directory.dart` / 迁移脚本），
`tags` 管"这本书是什么"。两者互补，不重复。

用法：
  python tools/tag_local_comics.py [--dry-run]
"""
import argparse
import json
import shutil
import sqlite3
import time

# 标题（= local.db.comics.title）→ 语种标签
LANGUAGE_TAGS = {
    '回声错误': '语言:English',
    '龙女友回归': '语言:English',
    '做个恶女好安逸': '语言:English',
    '我要救爸爸': '语言:English',
    'The Runaway Extra and the Obsessive Duke': '语言:English',
    '黑幕男主的限时保姆': '语言:English',
    'The Runaway Extra and the Obsessive Duke - 1 [Rokari Comics] [comix.to]':
        '语言:English',
    '扔掉的渣男，绝不再捡！': '语言:简体中文',
    '灭门家族的重生者': '语言:简体中文',
    '第一次告白': '语言:中文',
}

# 非漫画类（写真集）：补分类标签
CATEGORY_TAGS = {
    'cos写真': ['分类:写真集', 'Photobook'],
}

JUNK_KEYS = {
    '灭门家族的重生者': ['119 [baozimh]'],
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--local-db', default=None)
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    import os
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    db = args.local_db or os.path.join(here, 'data', 'local.db')

    con = sqlite3.connect(db, timeout=15)
    con.row_factory = sqlite3.Row
    rows = con.execute(
        'SELECT id, title, tags, chapters FROM comics').fetchall()

    plan = []
    for row in rows:
        title = row['title']
        tags = json.loads(row['tags'] or '[]')
        before = list(tags)
        wanted = []
        if title in LANGUAGE_TAGS:
            wanted.append(LANGUAGE_TAGS[title])
        wanted.extend(CATEGORY_TAGS.get(title, []))
        for tag in wanted:
            if tag not in tags:
                tags.append(tag)
        chapters = json.loads(row['chapters'] or '{}')
        junk = [k for k in JUNK_KEYS.get(title, []) if k in chapters]
        if tags != before or junk:
            plan.append((row['id'], title, before, tags, junk, chapters))

    for _id, title, before, after, junk, chapters in plan:
        added = [t for t in after if t not in before]
        print(f'== {title}')
        if added:
            print(f'   tags +{added}')
        if junk:
            print(f'   drop junk chapter key(s) {junk}')

    if args.dry_run:
        print('[dry-run] nothing written')
        con.close()
        return 0

    backup = db + '.bak_p49_tags_' + time.strftime('%Y%m%d_%H%M%S')
    shutil.copy2(db, backup)
    print('db backup:', backup)

    for _id, title, _before, after, junk, chapters in plan:
        if junk:
            for key in junk:
                chapters.pop(key, None)
        con.execute(
            'UPDATE comics SET tags = ?, chapters = ? WHERE id = ?',
            (json.dumps(after, ensure_ascii=False),
             json.dumps(chapters, ensure_ascii=False), _id),
        )
    con.commit()
    con.close()
    print(f'[done] {len(plan)} row(s) updated')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
