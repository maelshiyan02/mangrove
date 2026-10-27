#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把 `local.db` 里被 P49 污染的章节 key 复原（P51，2026-10-27）。

## 污染是什么

`migrate_chapter_languages.py` 为了"给目录加语言段"，顺手把 DB 侧也改了：

```
chapters["120"] = "第121话"     →     chapters["[zh-Hans] 120 [baozimh]"] = "第121话"
```

两个后果，都很致命：

1. **key 不再等于源站 key**。源侧同步回来的还是 `120`，本地存的是
   `[zh-Hans] 120 [baozimh]`，两边对不上，下载状态判不出来 → 出现"明明
   下好了却显示待命"的幽灵条目。
2. **顺序变成字典序**。脚本是按 `sorted(os.listdir())` 重建 map 的，
   而 `sorted()` 排的是字符串：`0, 1, 10, 100, 101, …`。
   章节列表是直接吃 map 顺序的（`ComicChapters(Map)` 不排序），
   于是第 1 话后面直接跳到第 100 话。

## 这个脚本做什么

- 把 key 开头/结尾的 `[lang] ` 段剥掉，恢复源站 key 原文；
- 按 key 里的**前导数字**重排（`0,1,2,…,10,11,…,100`），而不是字典序；
- `downloadedChapters` 同步去前缀、同步重排；
- 值类型不动（`str` / 版本列表 / 分组 map 原样保留，只处理 key）。

**不碰目录名**（那是另一个脚本的事），**不碰记录表**。

用法：
    python -u tools/revert_db_chapter_keys.py                # dry-run
    python -u tools/revert_db_chapter_keys.py --apply
"""
import argparse
import json
import os
import re
import shutil
import sqlite3
import time

DATA_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data"
)
LOCAL_DB = os.path.join(DATA_DIR, "local.db")

# `[zh-Hans] 120 [baozimh]` → `120 [baozimh]`
# `120 [baozimh] [zh-Hans]` → `120 [baozimh]`（防御：也可能被追加到尾部）
HEAD_LANG_RE = re.compile(r"^\[[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?\]\s+")
TAIL_LANG_RE = re.compile(r"\s*\[[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?\]$")
LEADING_NUM_RE = re.compile(r"^(\d+(?:\.\d+)?)")


def strip_lang(key: str) -> str:
    """只剥语言段，不动翻译组/站点方括号。"""
    out = HEAD_LANG_RE.sub("", key)
    out = TAIL_LANG_RE.sub("", out)
    return out.strip() or key


def sort_key(key: str):
    """前导数字优先按数值排；没有数字的排后面按字典序。"""
    m = LEADING_NUM_RE.match(key)
    if m:
        try:
            return (0, float(m.group(1)), key)
        except ValueError:  # pragma: no cover
            pass
    return (1, 0.0, key)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--db", default=LOCAL_DB)
    args = ap.parse_args()

    if not os.path.exists(args.db):
        raise SystemExit(f"db not found: {args.db}")

    con = sqlite3.connect(args.db, timeout=20)
    rows = con.execute(
        "select id, title, chapters, downloadedChapters from comics"
    ).fetchall()

    plan = []
    for cid, title, chapters, dch in rows:
        try:
            ch_map = json.loads(chapters) if chapters else {}
        except Exception:  # noqa: BLE001
            print(f"[warn] {title}: chapters 不是合法 JSON，跳过")
            continue
        if not isinstance(ch_map, dict):
            print(f"[warn] {title}: chapters 不是 map，跳过")
            continue

        new_map = {}
        renaming = 0
        for k, v in ch_map.items():
            nk = strip_lang(k)
            if nk != k:
                renaming += 1
            new_map[nk] = v

        # 只对「扁平 map」重排；分组/版本化结构靠源侧顺序，别乱动
        flat = all(isinstance(v, str) for v in new_map.values())
        if flat:
            ordered = {k: new_map[k] for k in sorted(new_map, key=sort_key)}
        else:
            ordered = new_map

        try:
            d_list = json.loads(dch) if dch else []
        except Exception:  # noqa: BLE001
            d_list = []
        if isinstance(d_list, list):
            new_d = []
            seen = set()
            for k in d_list:
                if not isinstance(k, str):
                    continue
                nk = strip_lang(k)
                if nk in seen:
                    continue
                seen.add(nk)
                new_d.append(nk)
            new_d.sort(key=sort_key)
        else:  # 老版本可能是 map
            new_d = d_list

        before_keys = list(ch_map.keys())
        after_keys = list(ordered.keys())
        changed = before_keys != after_keys or (
            isinstance(d_list, list) and d_list != new_d
        )
        if not changed:
            continue
        plan.append(
            (
                cid,
                title,
                len(after_keys),
                renaming,
                before_keys[:4],
                after_keys[:4],
                json.dumps(ordered, ensure_ascii=False),
                json.dumps(new_d, ensure_ascii=False),
            )
        )

    print(f"[scan] {len(plan)} 本需要修")
    for cid, title, n, renaming, bk, ak, _, _ in plan:
        print(f"  {title[:22]:24s} chapters={n:4d} 去前缀={renaming:4d}")
        print(f"      前4 之前: {bk}")
        print(f"      前4 之后: {ak}")

    if not args.apply:
        print("[dry-run] 未写入")
        return 0

    bak = f"{args.db}.bak_p51_keys_{time.strftime('%Y%m%d_%H%M%S')}"
    shutil.copy2(args.db, bak)
    print(f"[backup] {os.path.basename(bak)}")

    try:
        con.execute("BEGIN;")
        for cid, title, _, _, _, _, ch_json, d_json in plan:
            con.execute(
                "update comics set chapters=?, downloadedChapters=? where id=?",
                (ch_json, d_json, cid),
            )
        con.execute("COMMIT;")
    except Exception:
        con.execute("ROLLBACK;")
        raise
    finally:
        con.close()
    print(f"[done] 已修 {len(plan)} 本")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
