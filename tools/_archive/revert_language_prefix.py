#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把 P49 塞进章节目录名的语言段**全部撤掉**（P51，2026-10-27）。

## 为什么必须撤

P49 按「语言是第一分类维度」的推理，把章节目录从

    120 [baozimh]   →   [zh-Hans] 120 [baozimh]

逻辑本身没错，**落点错了**。目录名不只是显示用的字符串，它同时是：

1. **本地漫画的章节 key**（`local.db.comics.chapters` 的 map 键）。
   目录名一加前缀，key 就从 `"120"` 变成 `"[zh-Hans] 120 [baozimh]"`；
2. **排序依据**。`ComicChapters._compareChapterNumbersAsc` 走
   `double.tryParse(key)`，加了前缀就 parse 不出数字，退化成**字典序**：
   第 0 话、第 1 话、第 10 话、第 100 话、第 101 话…… 章节列表直接乱掉；
3. **源站 key**。源侧下一轮同步会按它自己的规则重新给目录命名，
   我们改的这层是"租来的"，迟早被覆盖回去。

结论（用户 2026-10-27 定案）：**目录名只归源站所有，我们一个字都不改**。
语言、翻译组、站点这些信息改存**记录表**（`comic_field_overrides` 的
`chapter_languages` / `chapter_labels` / `chapter_numbers`），那才是我们
拥有、能自由写入、而且不会反噬排序的地方。

## 安全边界

- 只做**同盘 os.rename**，瞬间完成，不复制不占空间；
- 目标名已存在 → 跳过并报错（绝不覆盖，覆盖 = 丢一章的图）；
- 默认 dry-run，`--apply` 才动手；
- 只剥**最前面**的 `[xx]` / `[xx-YY]` 语言段，位置在中间的方括号（翻译组、
  站点）原样保留。

用法：
    python -u tools/revert_language_prefix.py               # 看清单
    python -u tools/revert_language_prefix.py --apply       # 真改
"""
import argparse
import os
import re
import sys

LIBRARY_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "ComicLibrary",
    "downloads",
)

# 只认语言段形态：`[en] ` / `[zh-Hans] ` / `[ja-JP] `。
# 不匹配 `[cover]`、`[Rokari Comics]`，因为它们不是语言。
LANG_PREFIX_RE = re.compile(r"^\[([A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?)\]\s+(.+)$")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="真的改名（默认 dry-run）")
    ap.add_argument("--comic", default=None, help="只处理某本漫画的目录")
    args = ap.parse_args()

    if not os.path.isdir(LIBRARY_DIR):
        raise SystemExit(f"library not found: {LIBRARY_DIR}")

    comics = sorted(
        n
        for n in os.listdir(LIBRARY_DIR)
        if os.path.isdir(os.path.join(LIBRARY_DIR, n))
    )
    if args.comic:
        comics = [c for c in comics if c == args.comic]

    total_ok = 0
    problems = []
    for comic in comics:
        root = os.path.join(LIBRARY_DIR, comic)
        todo = []
        for name in sorted(os.listdir(root)):
            full = os.path.join(root, name)
            if not os.path.isdir(full):
                continue
            m = LANG_PREFIX_RE.match(name)
            if not m:
                continue
            target = m.group(2).strip()
            if not target:
                problems.append((comic, name, "empty remainder"))
                continue
            dst = os.path.join(root, target)
            if os.path.exists(dst):
                # 目标已存在 = 这名字上已经有一份图，绝不能覆盖
                problems.append((comic, name, f"target exists: {target}"))
                continue
            todo.append((name, target))

        if not todo:
            continue
        print(f"[{comic}] {len(todo)} dir(s)")
        for name, target in todo[:3]:
            print(f"    {name}  ->  {target}")
        if len(todo) > 3:
            print(f"    ... and {len(todo) - 3} more")

        if not args.apply:
            total_ok += len(todo)
            continue

        done = 0
        for name, target in todo:
            try:
                os.rename(os.path.join(root, name), os.path.join(root, target))
                done += 1
            except OSError as exc:  # noqa: BLE001
                problems.append((comic, name, str(exc)))
        total_ok += done
        print(f"[{comic}] renamed {done}/{len(todo)}")

    mode = "APPLIED" if args.apply else "DRY-RUN"
    print(f"[{mode}] total={total_ok} problems={len(problems)}")
    for comic, name, why in problems[:20]:
        print(f"  [skip] {comic} / {name}: {why}")
    return 0 if not problems else 4


if __name__ == "__main__":
    sys.exit(main())
