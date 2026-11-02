#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把一本「中英混装」的本地漫画拆成两本，再用**合集**把它们绑在一起。

P51（2026-10-27）用户定案：

> 相当于我们强行把灭门家族重生者这本漫画的中文 152 话与 comix.to 来源的
> 153 到 157 话强行拼接在一起了。这是非常不好的……应该是分成两个漫画，
> 然后用合集的方式把中文版和英文版组合在一起。可用章节列表上方的来源网站
> UI 切换语言版本。

## 为什么不能硬拼

跨源补章看起来只是"多几行数据"，实际撞了三个模型：

1. **话号坐标系不同**。包子 key `151` = 第152话，comix key `152` = 第153话。
   并进同一个 map 只能靠"话号-1"这种约定对齐，一旦某个源改起点就整体错位；
2. **语言是内容维度，不是标签**。简中第 1-152 话和英文第 153-157 话是
   **两份不同的书**（译者不同、断章位置不同、甚至话号定义不同）。混在一个
   map 里，`语言` 字段只能说一个，排序/进度/翻译工程全都要额外分支；
3. **记录表会说谎**。混装的那本，`comic.language` 只能填"简体中文"，
   于是 5 话英文在库里被当成简体中文 —— 用户截图里就是这个。

拆开之后：两本各自 `language` 干净、各自 key 坐标系干净、各自可独立下载/翻译；
需要"当一本书看"时用**合集**（`CollectionDisplayMode.tabs`，一个 tab 一个版本）。

## 这次做什么（只对一本，参数化）

1. 新目录 `<原名> [en]`，把英文章节目录**移动**进去，并按真实话号改名
   （`152 [Asura Scans] [comix.to]` → `153 [Asura Scans] [comix.to]`，
   因为新目录里不再有"和中文本共享 0-based 坐标"这回事）；
2. 新插一条 `comics` 记录（`comic_type = 0` = 纯本地）；
3. 原记录的 `chapters` / `downloadedChapters` 只保留中文话；
4. 记录表写 `chapter_languages`（两本各一个语种）；
5. `appdata.json` 里建一个 `tabs` 模式的合集，成员就是这两本。

## 安全

- 默认 dry-run；
- 动文件前先备份 `local.db` / `appdata.json` / `mangrove.db`；
- 移动用 `shutil.move`（同盘 = rename，瞬时）；目标已存在就中止，绝不覆盖。

用法：
    python -u tools/split_multilang_comic.py
    python -u tools/split_multilang_comic.py --apply
"""
import argparse
import json
import os
import shutil
import sqlite3
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_DIR = os.path.join(ROOT, "data")
LOCAL_DB = os.path.join(DATA_DIR, "local.db")
DOMAIN_DB = os.path.join(DATA_DIR, "data", "mangrove.db")
APPDATA_JSON = os.path.join(DATA_DIR, "appdata.json")
SYNCDATA_JSON = os.path.join(DATA_DIR, "syncdata.json")
LIBRARY_DIR = os.path.join(ROOT, "ComicLibrary", "downloads")

# ---- 本次目标：灭门家族的重生者 -------------------------------------------
TARGET_ID = "miemenjiazudezhongshengzhe-yangpyungpainkillersaintnine"
TARGET_DIR = "灭门家族的重生者"
# 中文本的源身份：`source_platforms` 里 canonical_key=`baozi`（platform_id=
# `remote:baozi`），章节目录旁的站标 `[baozimh]` 就是它（见 chapter_directory
# 的 _sourceSiteTags）。合集成员的 sourceKey 用 **canonical key**，因为
# `ComicType.fromKey` 吃的就是这个。
ZH_SOURCE_KEY = "baozi"
ZH_PLATFORM = "remote:baozi"
SPLIT_LANG = "en"
SPLIT_LABEL = "英文"
KEEP_LANG = "zh-Hans"
KEEP_LABEL = "简体中文"
SPLIT_SITE = "comix.to"
SPLIT_GROUP = "Asura Scans"
# 旧 key → 新话号（comix 的 key 是 0-based，标题才是真实话号）
SPLIT_KEYS = {
    "152": 153,
    "153": 154,
    "154": 155,
    "155": 156,
    "156": 157,
}

COLLECTION_NAME = "灭门家族的重生者"
FIELD_CHAPTER_LANGUAGES = "chapter_languages"


def override_comic_id(platform_id, source_comic_id):
    return f"{platform_id}:{source_comic_id}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    src_dir = os.path.join(LIBRARY_DIR, TARGET_DIR)
    if not os.path.isdir(src_dir):
        raise SystemExit(f"源目录不存在: {src_dir}")

    con = sqlite3.connect("file:" + LOCAL_DB + "?mode=ro", uri=True)
    row = con.execute(
        "select id,title,tags,directory,chapters,cover,comic_type,"
        "downloadedChapters,created_at,description,subtitle "
        "from comics where id = ?",
        (TARGET_ID,),
    ).fetchone()
    con.close()
    if not row:
        raise SystemExit(f"local.db 里找不到 {TARGET_ID}")

    (cid, title, tags, directory, chapters_json, cover, comic_type,
     dch_json, created_at, description, subtitle) = row
    ch_map = json.loads(chapters_json)
    dch = json.loads(dch_json)

    split_keys = [k for k in ch_map if k in SPLIT_KEYS]
    keep_keys = [k for k in ch_map if k not in SPLIT_KEYS]
    print(f"[src] {title}: 共 {len(ch_map)} 章，待拆出 {len(split_keys)} 章 → {SPLIT_LANG}")
    print(f"      保留 {len(keep_keys)} 章，末话 {ch_map.get(keep_keys[-1]) if keep_keys else '-'}")

    # 磁盘目录：key 是裸数字，目录名带组名/站标（`152 [Asura Scans] [comix.to]`），
    # 所以按「前导话号 + 站标」去找，不能直接拿 key 当目录名。
    existing_dirs = [
        n for n in os.listdir(src_dir)
        if os.path.isdir(os.path.join(src_dir, n))
    ]

    def find_dir(number):
        for name in existing_dirs:
            if not name.startswith(f"{number} "):
                continue
            if SPLIT_SITE.lower() in name.lower():
                return name
        raise SystemExit(
            f"找不到 key={number} 对应的目录（{SPLIT_SITE}），中止"
        )

    moves = []
    for old_key in split_keys:
        number = SPLIT_KEYS[old_key]
        old_dir = find_dir(old_key)
        new_name = f"{number} [{SPLIT_GROUP}] [{SPLIT_SITE}]"
        moves.append((old_dir, new_name))
    new_dir_name = f"{TARGET_DIR} · {SPLIT_LABEL}版"
    new_dir = os.path.join(LIBRARY_DIR, new_dir_name)
    print(f"[dir] 新目录: {new_dir_name}")
    for old_dir, new_name in moves:
        print(f"      {old_dir}  →  {new_name}")

    # 新记录
    new_id = f"{TARGET_ID}-en"
    new_chapters = {}
    for old_key, (old_dir, new_name) in zip(split_keys, moves):
        new_chapters[new_name] = f"第{SPLIT_KEYS[old_key]}话"
    new_dch = [new_name for _, new_name in moves]
    # `tags` 列是 JSON 文本，不是列表 —— 直接迭代会按**字符**拆开
    tags_list = json.loads(tags) if tags else []
    new_tags = [
        t.replace("语言:简体中文", f"语言:{SPLIT_LABEL}") for t in tags_list
    ]
    if not any(t.startswith("语言:") for t in new_tags):
        new_tags.append(f"语言:{SPLIT_LABEL}")

    print(f"[db] 新记录 id={new_id}  comic_type=0  chapters={len(new_chapters)}")
    print(f"      tags = {new_tags}")

    # 记录表（语言第二落点）
    zh_override = override_comic_id(ZH_PLATFORM, TARGET_ID)
    en_override = override_comic_id("local", new_id)
    print(f"[records] 中文本 override = {zh_override}")
    print(f"[records] 英文本 override = {en_override}")

    # 合集
    collection = {
        "id": "p51miemenjia",
        "sourceKey": "comic_collection_p51miemenjia",
        "name": COLLECTION_NAME,
        "customCover": "",
        "displayMode": "tabs",
        "members": [
            {
                "sourceKey": ZH_SOURCE_KEY,
                "comicId": TARGET_ID,
                "displayName": f"{KEEP_LABEL} · 包子漫画",
                "cachedTitle": title,
                "cachedSubtitle": subtitle or "",
                "cachedCover": "file://" + os.path.join(src_dir, cover),
            },
            {
                "sourceKey": "local",
                "comicId": new_id,
                "displayName": f"{SPLIT_LABEL} · {SPLIT_GROUP} · {SPLIT_SITE}",
                "cachedTitle": f"{title}（{SPLIT_LABEL}版）",
                "cachedSubtitle": subtitle or "",
                "cachedCover": "file://"
                + os.path.join(new_dir, cover),
            },
        ],
        "createdAt": int(time.time() * 1000),
    }
    print("[collection]")
    print(json.dumps(collection, ensure_ascii=False, indent=1)[:900])

    if not args.apply:
        print("[dry-run] 未做任何改动")
        return 0

    # ---------------- 真正开始 ----------------
    stamp = time.strftime("%Y%m%d_%H%M%S")
    for path in (LOCAL_DB, APPDATA_JSON, DOMAIN_DB):
        if os.path.exists(path):
            shutil.copy2(path, f"{path}.bak_p51_split_{stamp}")
    print(f"[backup] *{stamp}*")

    # 1. 目录
    if os.path.isdir(new_dir):
        raise SystemExit(f"目标目录已存在，中止: {new_dir}")
    os.makedirs(new_dir, exist_ok=True)
    # 封面跟着复制一份（不移动：中文本还要用）
    src_cover_dir = os.path.join(src_dir, "cover")
    if os.path.isdir(src_cover_dir):
        shutil.copytree(src_cover_dir, os.path.join(new_dir, "cover"))
    for old_dir, new_name in moves:
        shutil.move(os.path.join(src_dir, old_dir), os.path.join(new_dir, new_name))
    print(f"[dir] 已移动 {len(moves)} 个章节目录")

    # 2. local.db
    con = sqlite3.connect(LOCAL_DB, timeout=20)
    try:
        con.execute("BEGIN;")
        con.execute(
            "insert into comics (id,title,subtitle,tags,directory,chapters,cover,"
            "comic_type,downloadedChapters,created_at,description) "
            "values (?,?,?,?,?,?,?,?,?,?,?)",
            (
                new_id,
                f"{title}（{SPLIT_LABEL}版）",
                subtitle,
                json.dumps(new_tags, ensure_ascii=False),
                new_dir_name,
                json.dumps(new_chapters, ensure_ascii=False),
                cover,
                0,
                json.dumps(new_dch, ensure_ascii=False),
                int(time.time() * 1000),
                description,
            ),
        )
        kept_chapters = {k: ch_map[k] for k in keep_keys}
        kept_dch = [k for k in dch if k in kept_chapters]
        con.execute(
            "update comics set chapters=?, downloadedChapters=? where id=?",
            (
                json.dumps(kept_chapters, ensure_ascii=False),
                json.dumps(kept_dch, ensure_ascii=False),
                TARGET_ID,
            ),
        )
        con.execute("COMMIT;")
    except Exception:
        con.execute("ROLLBACK;")
        raise
    finally:
        con.close()
    print(f"[db] 拆分完成：中文本 {len(keep_keys)} 章，英文本 {len(new_chapters)} 章")

    # 3. 记录表
    dcon = sqlite3.connect(DOMAIN_DB, timeout=20)
    try:
        dcon.execute(
            "CREATE TABLE IF NOT EXISTS comic_field_overrides ("
            "comic_id TEXT NOT NULL, field_key TEXT NOT NULL, "
            "value_json TEXT, updated_at INTEGER, "
            "PRIMARY KEY (comic_id, field_key));"
        )
        now = int(time.time() * 1000)
        if zh_override:
            payload = {k: KEEP_LANG for k in keep_keys}
            dcon.execute(
                "insert into comic_field_overrides (comic_id,field_key,value_json,updated_at)"
                " values (?,?,?,?) on conflict(comic_id,field_key) do update set"
                " value_json=excluded.value_json, updated_at=excluded.updated_at;",
                (zh_override, FIELD_CHAPTER_LANGUAGES,
                 json.dumps(payload, ensure_ascii=False), now),
            )
        payload_en = {k: SPLIT_LANG for k in new_chapters}
        dcon.execute(
            "insert into comic_field_overrides (comic_id,field_key,value_json,updated_at)"
            " values (?,?,?,?) on conflict(comic_id,field_key) do update set"
            " value_json=excluded.value_json, updated_at=excluded.updated_at;",
            (en_override, FIELD_CHAPTER_LANGUAGES,
             json.dumps(payload_en, ensure_ascii=False), now),
        )
        dcon.execute("COMMIT;")
    finally:
        dcon.close()
    print("[records] chapter_languages 已写入")

    # 4. appdata.json（合集）
    for path in (APPDATA_JSON, SYNCDATA_JSON):
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as fp:
            data = json.load(fp)
        settings = data.get("settings")
        if not isinstance(settings, dict):
            continue
        existing = settings.get("comicCollections")
        if not isinstance(existing, list):
            existing = []
        existing = [c for c in existing if c.get("id") != collection["id"]]
        existing.append(collection)
        settings["comicCollections"] = existing
        with open(path, "w", encoding="utf-8") as fp:
            json.dump(data, fp, ensure_ascii=False)
        print(f"[appdata] {os.path.basename(path)} 已写入合集")

    print("[done] 拆分 + 合集完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
