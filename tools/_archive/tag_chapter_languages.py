# -*- coding: utf-8 -*-
"""把「章节语言」写进漫画的记录表（`comic_field_overrides.chapter_languages`）。

## 为什么需要它

语种是复合漫画的第一分类维度：同一话的简/繁/英/日版是**四份不同内容**，
不是镜像。P49 把语言塞进了章节目录名（`[zh-Hans] 120 [baozimh]`），
但目录名是**约定、不是所有权**：

* 有翻译工程的漫画改目录名 = 断链（工程目录按章节名建）；
* 源侧重新下载会把目录名按源侧规则覆盖回来；
* 别的设备/别的时间点看到的目录可能不一样。

所以语言必须有第二个落点 —— 这本漫画自己的记录表。读取顺序
**记录表 > 目录名**（见 `ComicOverrideStore.fieldChapterLanguages`）。

## 用法

    # 先看会写什么（默认就是 dry-run）
    python -u tools/tag_chapter_languages.py --comic-id remote:baozi:xxx

    # 真的写
    python -u tools/tag_chapter_languages.py --comic-id remote:baozi:xxx --apply

    # 整本统一标成简体中文（源目录不带语言段时）
    python -u tools/tag_chapter_languages.py --comic-id remote:baozi:xxx \\
        --all zh-Hans --apply

    # 只给某几话标（例如英文源补的第 153-157 话）
    python -u tools/tag_chapter_languages.py --comic-id remote:baozi:xxx \\
        --set 153-157=en --apply

匹配方式：目录名里的**话号**与 `chapters` 标题里的**数字**对齐（`第120话` ↔
`[zh-Hans] 120 [baozimh]`）。对不上的章节不猜，列出来让人看。
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
DOMAIN_DB = os.path.join(DATA_DIR, "data", "mangrove.db")
LIBRARY_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "ComicLibrary",
    "downloads",
)
FIELD = "chapter_languages"

# `[zh-Hans] 120 [baozimh]` / `[en] 5 [Asura Scans] [comix.to]`
DIR_LANG_RE = re.compile(r"^\[([A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?)\]\s*(.+)$")
LEADING_NUM_RE = re.compile(r"^(\d+(?:\.\d+)?)")
TITLE_NUM_RE = re.compile(r"(\d+(?:\.\d+)?)")


def _backup(path):
    stem, ext = os.path.splitext(path)
    dest = f"{stem}.bak_p50_lang_{time.strftime('%Y%m%d_%H%M%S')}{ext}"
    shutil.copy2(path, dest)
    return dest


def _load_local_comic(title_dir=None, local_id=None):
    con = sqlite3.connect(LOCAL_DB)
    con.row_factory = sqlite3.Row
    if local_id:
        row = con.execute(
            "select * from comics where id = ?", (local_id,)
        ).fetchone()
    else:
        row = con.execute(
            "select * from comics where directory = ? or title = ?",
            (title_dir, title_dir),
        ).fetchone()
    con.close()
    return dict(row) if row else None


def _chapter_dirs(base):
    """返回 [(话号, 语言, 目录名)]，只认 `[lang] 话号 ...` 形态。"""
    result = []
    if not os.path.isdir(base):
        return result
    for name in os.listdir(base):
        if not os.path.isdir(os.path.join(base, name)):
            continue
        match = DIR_LANG_RE.match(name.strip())
        if not match:
            continue
        language, rest = match.group(1), match.group(2)
        num = LEADING_NUM_RE.match(rest.strip())
        if not num:
            continue
        result.append((num.group(1), language, name))
    return result


def _title_number(text):
    match = TITLE_NUM_RE.search(text or "")
    return match.group(1) if match else None


def _expand_range(spec):
    """"153-157=en" / "12=en" → [(号码集合, 语言)]。"""
    if "=" not in spec:
        raise ValueError(f"--set 需要 `号码=语言` 形式：{spec}")
    numbers, language = spec.split("=", 1)
    numbers, language = numbers.strip(), language.strip()
    wanted = set()
    for part in numbers.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            left, right = part.split("-", 1)
            start, end = int(float(left)), int(float(right))
            wanted.update(str(i) for i in range(start, end + 1))
        else:
            wanted.add(str(int(float(part))))
    return wanted, language


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--comic-id", required=True, help="域库 comic_id，如 remote:baozi:xxx")
    parser.add_argument("--local-id", help="local.db 里的 id（默认取 comic_id 最后一段）")
    parser.add_argument("--title-dir", help="漫画目录名（默认取 local.db 的 directory）")
    parser.add_argument("--all", dest="all_language", help="整本统一语言，如 zh-Hans")
    parser.add_argument("--set", action="append", default=[], metavar="号码=语言")
    parser.add_argument("--clear", action="store_true", help="清空这本的语言标注")
    parser.add_argument("--apply", action="store_true", help="真的写库（默认 dry-run）")
    args = parser.parse_args()

    local_id = args.local_id or args.comic_id.split(":")[-1]
    record = _load_local_comic(args.title_dir, local_id)
    if record is None:
        print(f"[错误] local.db 里找不到 id={local_id}")
        return 2
    title = record.get("title") or local_id
    directory = record.get("directory") or title
    base = directory if os.path.isabs(directory) else os.path.join(
        LIBRARY_DIR, directory
    )
    chapters = {}
    try:
        chapters = json.loads(record.get("chapters") or "{}")
    except (TypeError, ValueError):
        chapters = {}
    if not isinstance(chapters, dict):
        print("[错误] chapters 不是扁平 map，本脚本不处理版本化结构")
        return 2

    print(f"[漫画] {title}")
    print(f"[目录] {base}")
    print(f"[章节] {len(chapters)} 话")

    # 现有标注（决定是 merge 还是重写）
    con = sqlite3.connect(DOMAIN_DB)
    row = con.execute(
        f"select value_json from comic_field_overrides where comic_id = ? and field_key = ?",
        (args.comic_id, FIELD),
    ).fetchone()
    existing = {}
    if row and row[0]:
        try:
            existing = json.loads(row[0])
        except (TypeError, ValueError):
            existing = {}
    if not isinstance(existing, dict):
        existing = {}
    con.close()
    print(f"[已有标注] {len(existing)} 条")

    mapping = {} if args.clear else dict(existing)

    # 1) 目录名回填
    #
    # 🔴 目录名里的数字是**章节 key 的数字形态**，不是"第几话"。包子源的
    # key 是 `"0".."151"`，目录就是 `[zh-Hans] 0 [baozimh]`、`... 151 ...`；
    # 而章节标题是 `第1话..第152话`（1-based）。拿标题数字去配目录数字会
    # **整体错位一格**，把第 2 话的目录标成第 1 话的语言 —— 所以先按 key
    # 精确匹配，匹配不上才退回标题数字（给 key 是 UUID / 整条 URL 的源用）。
    by_key = {str(k).strip(): k for k in chapters}
    by_title_number = {}
    for key, value in chapters.items():
        num = _title_number(value if isinstance(value, str) else "")
        if num:
            by_title_number.setdefault(num, key)
    filled, unmatched = 0, []
    for number, language, dir_name in _chapter_dirs(base):
        key = by_key.get(number)
        if key is None:
            key = by_title_number.get(number)
        if key is None:
            unmatched.append(dir_name)
            continue
        if mapping.get(key) != language:
            mapping[key] = language
            filled += 1
    print(f"[目录回填] 新标 {filled} 条，未匹配目录 {len(unmatched)} 个")
    for name in unmatched[:8]:
        print(f"  ? {name}")

    # 2) 整本统一
    if args.all_language:
        lang = args.all_language.strip()
        added = 0
        for key in chapters:
            if mapping.get(key) != lang:
                mapping[key] = lang
                added += 1
        print(f"[整本 {lang}] 新标 {added} 条")

    # 3) 指定号码
    for spec in args.set:
        numbers, language = _expand_range(spec)
        added = 0
        for key in chapters:
            # `--set` 的号码是**给人看的话号**（第 153 话），既认 key 也认
            # 标题里的数字，两种写法都能命中。
            if str(key).strip() not in numbers:
                num = _title_number(
                    chapters[key] if isinstance(chapters[key], str) else ""
                )
                if num not in numbers:
                    continue
            if mapping.get(key) != language:
                mapping[key] = language
                added += 1
        print(f"[指定 {spec}] 新标 {added} 条")

    summary = {}
    for language in mapping.values():
        summary[language] = summary.get(language, 0) + 1
    print(f"[结果] 共 {len(mapping)} 条：{summary}")

    if not args.apply:
        print("（dry-run，未写库；加 --apply 生效）")
        return 0

    _backup(DOMAIN_DB)
    con = sqlite3.connect(DOMAIN_DB)
    if mapping:
        con.execute(
            """
            insert into comic_field_overrides(comic_id, field_key, value_json, updated_at)
            values(?,?,?,?)
            on conflict(comic_id, field_key) do update set
              value_json = excluded.value_json,
              updated_at = excluded.updated_at
            """,
            (
                args.comic_id,
                FIELD,
                json.dumps(mapping, ensure_ascii=False),
                int(time.time() * 1000),
            ),
        )
    else:
        con.execute(
            "delete from comic_field_overrides where comic_id = ? and field_key = ?",
            (args.comic_id, FIELD),
        )
    con.commit()
    con.close()
    print("[完成] 已写入 comic_field_overrides")
    return 0


if __name__ == "__main__":
    sys.exit(main())
