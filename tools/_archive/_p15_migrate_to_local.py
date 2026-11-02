"""P15：把 5 本 comix.to 漫画转成本地漫画，并重建记录表。

两库分工（别搞反）：
- `data/local.db` 是**真相层**：LocalComic 的 title/subtitle/description/tags/
  cover/chapters/downloadedChapters 都在这。`comic_type=0` 即本地漫画。
  这里的 `chapters` 决定**章节列表显示什么**，所以只放磁盘上真有的章。
- `data/data/mangrove.db` 是**镜像层**（域库）：comics / comic_sources /
  local_library_items / chapters / chapter_sources。
  `chapters` 只按 (comic_id, chapter_index) upsert、从不清空，所以可以装
  「全量章节信息」；`chapter_sources` 才是"磁盘上真有哪一话"的来源映射。

本脚本做四件事：
1. local.db：3 本 `comic_type` 496108553 → 0（comix 源 → 本地），5 本全部
   写入中文元数据；`chapters` 统一成**扁平** `{目录名: 显示名}`（与
   `local_comic_scanner.dart` 输出一致，见 P15 结论）
2. 域库：删掉失效身份（`local:bt_*` 死路径、`local:0` cos写真重复身份、
   3 本 comix_to 的远端身份）
3. 域库：5 本统一按 `local:*` 重建 comics / comic_sources / local_library_items
4. 域库：按 comix 站上的**全量话号**写 chapters（title=`第N话`），
   已下载的那话把 source_chapter_id 记成真实目录名，未下载的留空

用法：
    py -3.12 tools/_p15_migrate_to_local.py --check   # 只读体检
    py -3.12 tools/_p15_migrate_to_local.py --apply   # 执行（务必先关 App）
"""

import json
import os
import re
import shutil
import sqlite3
import sys
import time

BASE = os.path.join("ComicLibrary", "downloads")
LOCAL_DB = os.path.join("data", "local.db")
DOMAIN_DB = os.path.join("data", "data", "mangrove.db")
META = os.path.join("tools", "_p15_meta_zh.json")
IMG_EXT = {".webp", ".jpg", ".jpeg", ".png", ".gif"}

# 与 Dart 侧 `_siteTagPattern` 同规则：带点的域名不算翻译组名
SITE_TAG = re.compile(r"^[\w-]+(?:\.[\w-]+)+$")
BRACKET = re.compile(r"\[([^\]]*)\]")

# 域库要删的失效身份
STALE_COMIC_IDS = [
    "local:0",  # cos写真 的重复身份（真相层只有 id=1）
    "remote:comix_to:9lmnj//error-the-echo",
    "remote:comix_to:503jz//i-will-save-my-father",
    "remote:comix_to:gm28k//my-dragon-girlfriend-has-returned",
]


def natural_key(s: str):
    return [float(p) if re.fullmatch(r"\d+(?:\.\d+)?", p) else p
            for p in re.split(r"(\d+(?:\.\d+)?)", s)]


def chapter_display(dir_name: str) -> str:
    """目录名 → 显示名，逐字复刻 Dart `chapterDisplayName()`。

    `1 [Rokari Comics] [comix.to]` → `第1话 · Rokari Comics`
    `116 [Lua Comic] [comix.to]`   → `第116话 · Lua Comic`
    `HaneAme - Nikke Helm`         → 原样（无话号目录，cos写真那类）
    """
    name = dir_name.strip()
    if not name:
        return name
    m = re.match(r"^(\d+(?:\.\d+)?)[\s_]*(.*)$", name)
    if not m:
        return name
    number, rest = m.group(1), m.group(2).strip()
    labels = [
        text.strip()
        for text in (b.group(1) for b in BRACKET.finditer(rest))
        if text.strip() and not SITE_TAG.match(text.strip())
    ]
    suffix = f" · {' '.join(labels)}" if labels else ""
    return f"第{number}话{suffix}"


def chapter_number(dir_name: str):
    m = re.match(r"^(\d+(?:\.\d+)?)", dir_name.strip())
    return m.group(1) if m else None


def disk_chapters(comic_dir: str):
    """磁盘上的真实章节。返回 [(目录名, 图数)]，按话号自然序。"""
    root = os.path.join(BASE, comic_dir)
    out = []
    for name in os.listdir(root):
        p = os.path.join(root, name)
        if not os.path.isdir(p) or name.startswith(".") or name == "cover":
            continue
        n = sum(1 for f in os.listdir(p)
                if os.path.splitext(f)[1].lower() in IMG_EXT)
        if n:
            out.append((name, n))
    out.sort(key=lambda x: natural_key(x[0]))
    return out


def load_site_chapters(tmp_dir: str):
    """读 comix 章节清单，返回按话号升序的 [(话号, [组名…])]（全量）。"""
    path = os.path.join(os.environ["TEMP"], tmp_dir, "chapters.json")
    with open(path, encoding="utf-8") as f:
        rows = json.load(f)
    by_number = {}
    for r in rows:
        num = str(r["number"])
        by_number.setdefault(num, [])
        group = r.get("group")
        if group and group not in by_number[num]:
            by_number[num].append(group)
    return sorted(by_number.items(), key=lambda kv: natural_key(kv[0]))


def cover_rel(comic_dir: str) -> str:
    """真相层的 cover 是相对路径、反斜杠（与既有行一致）。"""
    cdir = os.path.join(BASE, comic_dir, "cover")
    if not os.path.isdir(cdir):
        return ""
    files = sorted(os.listdir(cdir))
    return f"cover\\{files[0]}" if files else ""


def normalized(title: str) -> str:
    return re.sub(r"\s+", "", title).lower()


def main() -> int:
    apply = "--apply" in sys.argv
    with open(META, encoding="utf-8") as f:
        meta = json.load(f)

    print("=" * 66)
    print("P15 迁移：comix.to → 本地漫画" + ("（执行）" if apply else "（只读体检）"))
    print("=" * 66)

    plan = []
    for local_id, m in meta.items():
        disks = disk_chapters(m["dir"])
        site = load_site_chapters(m["chapters_file"])
        plan.append({"local_id": local_id, "meta": m, "disks": disks, "site": site})
        print(f"\n{m['title']}（{m['dir']}）")
        print(f"  真相层 id={local_id}  站上 {len(site)} 话"
              f"（{site[0][0] if site else '-'}–{site[-1][0] if site else '-'}）"
              f"  磁盘 {len(disks)} 章")
        for d, n in disks:
            print(f"    {d:44s} {n:4d} 页 → 显示名「{chapter_display(d)}」")
        print(f"  封面: {cover_rel(m['dir']) or '(无)'}")

    if not apply:
        print("\n（只读体检，未改动任何文件；加 --apply 执行）")
        return 0

    # 备份：改库前必须留一份，出错能整库回滚
    stamp = time.strftime("%Y%m%d_%H%M%S")
    for db in (LOCAL_DB, DOMAIN_DB):
        bak = f"{db}.bak_p15_{stamp}"
        shutil.copy2(db, bak)
        print(f"\n备份 {db} → {bak}")

    now_ms = int(time.time() * 1000)

    # ---------- 1. 真相层 local.db ----------
    lc = sqlite3.connect(LOCAL_DB)
    for p in plan:
        m, disks = p["meta"], p["disks"]
        chapters = {name: chapter_display(name) for name, _ in disks}
        downloaded = [name for name, _ in disks]
        lc.execute(
            """UPDATE comics SET comic_type=0, source='', title=?, subtitle=?,
                   description=?, tags=?, cover=?, chapters=?, downloadedChapters=?,
                   update_time=?
               WHERE id=?""",
            (
                m["title"], m["subtitle"], m["description"],
                json.dumps(m["tags"], ensure_ascii=False),
                cover_rel(m["dir"]),
                json.dumps(chapters, ensure_ascii=False),
                json.dumps(downloaded, ensure_ascii=False),
                "",
                p["local_id"],
            ),
        )
        print(f"  ✓ local.db {m['title']} → 本地（{len(chapters)} 章）")
    lc.commit()
    lc.close()

    # ---------- 2. 镜像层域库 ----------
    dc = sqlite3.connect(DOMAIN_DB)
    dc.execute("PRAGMA foreign_keys=ON")
    for cid in STALE_COMIC_IDS:
        n = dc.execute("DELETE FROM comics WHERE comic_id=?", (cid,)).rowcount
        if n:
            print(f"  ✓ 域库删除旧身份 {cid}")
    # 死路径的本地条目（`D:/Mangrove_Windows/...` 早就不存在）
    dead = [r[0] for r in dc.execute(
        "SELECT comic_id FROM local_library_items "
        "WHERE directory LIKE 'D:/Mangrove_Windows%'"
        "   OR directory LIKE 'D:\\Mangrove_Windows%'"
    ).fetchall()]
    for cid in sorted(set(dead)):
        dc.execute("DELETE FROM comics WHERE comic_id=?", (cid,))
        print(f"  ✓ 域库删除死路径条目 {cid}")

    for p in plan:
        m, disks, site = p["meta"], p["disks"], p["site"]
        comic_id = f"local:{p['local_id']}"
        downloaded_by_num = {}
        for name, _ in disks:
            num = chapter_number(name)
            if num:
                downloaded_by_num.setdefault(num, name)

        dc.execute(
            """INSERT INTO comics (comic_id,title,subtitle,description,author,status,
                   update_time,language,cover_uri,tags_json,page_count,normalized_title,
                   created_at,updated_at,base_info_updated_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(comic_id) DO UPDATE SET
                   title=excluded.title, subtitle=excluded.subtitle,
                   description=excluded.description, author=excluded.author,
                   status=excluded.status, cover_uri=excluded.cover_uri,
                   tags_json=excluded.tags_json, normalized_title=excluded.normalized_title,
                   updated_at=excluded.updated_at""",
            (
                comic_id, m["title"], m["subtitle"], m["description"],
                m["subtitle"], m["status"], None, "zh",
                cover_rel(m["dir"]), json.dumps(m["tags"], ensure_ascii=False),
                None, normalized(m["title"]), now_ms, now_ms, now_ms,
            ),
        )
        # 来源：本地漫画只有一条 local 源，source_comic_id = 真相层 id
        dc.execute(
            """INSERT INTO comic_sources
                   (comic_id,platform_id,source_comic_id,source_url,source_title,
                    status,created_at,accepted_at)
               VALUES (?,?,?,?,?,?,?,?)
               ON CONFLICT(platform_id, source_comic_id) DO UPDATE SET
                   comic_id=excluded.comic_id, source_title=excluded.source_title""",
            (comic_id, "local", p["local_id"], None, m["title"],
             "accepted", now_ms, now_ms),
        )
        dc.execute(
            """INSERT INTO local_library_items
                   (comic_id,directory,import_root,storage_state,created_at,updated_at)
               VALUES (?,?,?,?,?,?)
               ON CONFLICT(comic_id) DO UPDATE SET
                   directory=excluded.directory, storage_state=excluded.storage_state,
                   updated_at=excluded.updated_at""",
            (comic_id, m["dir"], None, "available", now_ms, now_ms),
        )
        source_row = dc.execute(
            "SELECT comic_source_id FROM comic_sources "
            "WHERE platform_id='local' AND source_comic_id=?", (p["local_id"],),
        ).fetchone()
        comic_source_id = source_row[0]

        # 章节：按站上全量话号重建（chapters + chapter_sources 两张表一致）
        dc.execute("DELETE FROM chapters WHERE comic_id=?", (comic_id,))
        for idx, (num, groups) in enumerate(site, 1):
            chapter_id = f"{comic_id}:chapter:{idx}"
            dir_name = downloaded_by_num.get(num)
            dc.execute(
                """INSERT INTO chapters (chapter_id,comic_id,title,chapter_index,
                       source_chapter_id,is_hidden,created_at)
                   VALUES (?,?,?,?,?,0,?)""",
                (chapter_id, comic_id, f"第{num}话", idx, dir_name, now_ms),
            )
            dc.execute(
                """INSERT INTO chapter_sources (chapter_id,comic_source_id,
                       source_chapter_id,source_chapter_index,source_title,
                       source_chapter_group,source_group_title,
                       source_chapter_index_in_group)
                   VALUES (?,?,?,?,?,?,?,?)""",
                (chapter_id, comic_source_id, dir_name, idx, f"第{num}话",
                 1 if groups else None,
                 " / ".join(groups) if groups else None,
                 idx),
            )
        filled = sum(1 for num, _ in site if num in downloaded_by_num)
        print(f"  ✓ 域库 {m['title']} 全量 {len(site)} 话"
              f"（其中 {filled} 话有图 / 磁盘 {len(disks)} 章）")

    dc.commit()
    dc.close()
    print("\n完成。启动 App 检查：5 本应显示为本地漫画，章节列表只出现已下载的话，"
          "且格子主标题只有「第N话」。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
