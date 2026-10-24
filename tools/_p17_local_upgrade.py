"""P17：封面语言标识 + 原名译名 + 渣男转本地（断网络链接）。

四件事，全程只碰数据与文件名，不动任何既有图片的像素：

1. 封面改名（磁盘）：`[cover]season(N).jpg` → `[LANG][cover]season(N).jpg`。
   语言标签看**这张图本身**的文字，不看漫画国籍（韩漫的英文版封面标 EN）。
2. 新增封面：`扔掉的渣男` 补一张韩文原版封面（AniList 官方 poster）。
3. local.db（真相层）：写 `alt_titles`；`扔掉的渣男` 由网络漫画转本地
   （comic_type → 0、chapters 按磁盘 133 个目录重建、下载列表排序）。
4. 域库（镜像层）：更新 cover_uri；`扔掉的渣男` 的 4 个远程身份合并成一个
   `local:*`，**先把 2357 条 history_events 迁过去再删旧行**——`comic_id`
   带 ON DELETE CASCADE，顺序反了就是 A21 那次 798 条历史消失的重演。
5. history.db：同一本的 `type` 从网络类型值改成 0，否则转本地后读不到进度。

用法：
    py -3.12 tools/_p17_local_upgrade.py --check
    py -3.12 tools/_p17_local_upgrade.py --apply
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
HISTORY_DB = os.path.join("data", "history.db")

BRACKET = re.compile(r"\[([^\]]*)\]")
SITE_TAG = re.compile(r"^[\w-]+(?:\.[\w-]+)+$")
KNOWN_SITES = {"comix.to", "baozimh", "copymanga", "comick", "mangadex",
               "komiic", "dm5", "goda", "manhuaren", "mycomic"}

TRASH_ID = "rengdiaodezhananjuebuzaijian-vertexteavahn"
TRASH_DIR = "扔掉的渣男，绝不再捡！"


def is_site_tag(text: str) -> bool:
    t = text.strip()
    return bool(SITE_TAG.match(t)) or t.lower() in KNOWN_SITES


def chapter_display(dir_name: str) -> str:
    """目录名 → 显示名，逐字复刻 Dart `chapterDisplayName()`。"""
    name = dir_name.strip()
    m = re.match(r"^(\d+(?:\.\d+)?)[\s_]*(.*)$", name)
    if not m:
        return name
    number, rest = m.group(1), m.group(2).strip()
    labels = [
        t.strip()
        for t in (b.group(1) for b in BRACKET.finditer(rest))
        if t.strip() and not is_site_tag(t)
    ]
    return f"第{number}话" + (f" · {' '.join(labels)}" if labels else "")


def natural_key(s: str):
    return [float(p) if re.fullmatch(r"\d+(?:\.\d+)?", p) else p
            for p in re.split(r"(\d+(?:\.\d+)?)", s)]


# --------------------------------------------------------------------------
# 1. 封面：语言标签
# --------------------------------------------------------------------------
# 语言按**图上文字**判定，不是漫画国籍：
#   Runaway / 龙女友 / 保姆 / 恶女 / 回声 → 封面印韩文标题 → KR
#   我要救爸爸 → "I'll Save My Dad" + DAON 标 → EN
#   扔掉的渣男 → 中文站（包子漫画）在用的无字插画 → CN
COVER_RENAMES = [
    ("The Runaway Extra and the Obsessive Duke",
     "[cover]season(1).jpg", "[KR][cover]season(1).jpg"),
    ("The Runaway Extra and the Obsessive Duke",
     "[cover]season(2).jpg", "[KR][cover]season(2).jpg"),
    ("My Dragon Girlfriend Has Returned",
     "[cover]season(1).jpg", "[KR][cover]season(1).jpg"),
    ("I will save my father",
     "[cover]season(1).jpg", "[EN][cover]season(1).jpg"),
    ("The Archvillain's Dying Nanny",
     "[cover]season(1).jpg", "[KR][cover]season(1).jpg"),
    ("The Perks of Being a Villainess",
     "[cover]season(1).jpg", "[KR][cover]season(1).jpg"),
    ("Error the Echo",
     "[cover]season(1).jpg", "[KR][cover]season(1).jpg"),
    (TRASH_DIR, "[cover]season(1).jpg", "[CN][cover]season(1).jpg"),
]

# 新抓的封面：(漫画目录, 目标文件名)，源图固定为 tools/_p17_cover_trash_kr.jpg
NEW_COVERS = [(TRASH_DIR, "[KR][cover]season(1).jpg")]

# 每本的默认封面（相对漫画根目录）。手动钉死，避免扫描器按"季度+语言"规则
# 重选：渣男那张 CN 是无字插画，让带标题的 KR 当门面更好认。
COVER_PICK = {
    "The Runaway Extra and the Obsessive Duke":
        "cover\\[KR][cover]season(1).jpg",
    "My Dragon Girlfriend Has Returned":
        "cover\\[KR][cover]season(1).jpg",
    "I will save my father":
        "cover\\[EN][cover]season(1).jpg",
    "The Archvillain's Dying Nanny":
        "cover\\[KR][cover]season(1).jpg",
    "The Perks of Being a Villainess":
        "cover\\[KR][cover]season(1).jpg",
    "Error the Echo":
        "cover\\[KR][cover]season(1).jpg",
    TRASH_DIR:
        "cover\\[KR][cover]season(1).jpg",
}

# --------------------------------------------------------------------------
# 2. 原名 / 译名（按**目录名**索引，目录名才是稳定标识）
# --------------------------------------------------------------------------
ALT_TITLES = {
    "My Dragon Girlfriend Has Returned": [
        "原名：드래곤 여친이 귀환했다",
        "英译：My Dragon Girlfriend Has Returned / Return of the Dragon Girlfriend / The Dragon Girlfriend Has Returned",
    ],
    "I will save my father": [
        "原名：아빠를 살려보겠습니다",
        "英译：I Will Save My Father / I'll Save My Dad / I Will Try to Save My Dad",
        "日译：伯爵家のお嬢様はパパを助けたいです",
    ],
    "The Archvillain's Dying Nanny": [
        "原名：흑막 남주의 시한부 유모입니다",
        "英译：The Archvillain's Dying Nanny / I Am the Nanny of the Villain",
    ],
    "The Perks of Being a Villainess": [
        "原名：악녀라서 편하고 좋은데요?",
        "英译：The Perks of Being a Villainess / Isn't Being a Wicked Woman Much Better? / What's Wrong With Being the Villainess?",
    ],
    "Error the Echo": [
        "原名：에러 디 에코",
        "英译：Error: The Echo",
    ],
    "The Runaway Extra and the Obsessive Duke": [
        "原名：집착남주 두고 튀려는 엑스트라입니다",
        "英译：The Runaway Extra and the Obsessive Duke / An Extra Who Wants to Escape the Obsessive Male Lead",
        "日译：執着系ヒーローから逃げたいモブ令嬢です",
    ],
    TRASH_DIR: [
        "原名：버린 쓰레기는 다시 줍지 않는다",
        "英译：Trash Will Always Be Trash / Don't Pick Up What You've Thrown Away",
        "台版：放生渣男不再回收",
        "日译：捨てたゴミは二度と拾いません",
    ],
}

# --------------------------------------------------------------------------
# 3. 渣男：网络 → 本地
# --------------------------------------------------------------------------
TRASH_REMOTE_IDS = [
    "remote:baozi:rengdiaodezhananjuebuzaijian-vertexteavahn",
    "remote:baozi:repair:rengdiaodezhananjuebuzaijian-vertexteavahn",
    "remote:baozi:repair:rengdiaodezhananjuebuzaijian-vertexteavahn:100",
    "remote:baozi:repair:rengdiaodezhananjuebuzaijian-vertexteavahn:93",
]
TRASH_TAGS = ["大女主", "奇幻", "剧情"]
TRASH_SUBTITLE = "Vertex（버텍스）作画 · TEAVA（티바）编剧 · H.N.（배고픈밤）原作"
TRASH_UPDATE = "2026-06-24"


def disk_chapters(dir_name: str):
    root = os.path.join(BASE, dir_name)
    if not os.path.isdir(root):
        return []
    return sorted(
        [e for e in os.listdir(root)
         if os.path.isdir(os.path.join(root, e)) and e.lower() != "cover"],
        key=natural_key,
    )


def main() -> int:
    apply = "--apply" in sys.argv
    out = []

    # ---------- 1. 封面改名 ----------
    out.append("## 封面改名")
    for dir_name, old, new in COVER_RENAMES:
        src = os.path.join(BASE, dir_name, "cover", old)
        dst = os.path.join(BASE, dir_name, "cover", new)
        if os.path.exists(dst):
            out.append(f"  跳过（已存在）{dir_name}/{new}")
            continue
        if not os.path.exists(src):
            out.append(f"  ⚠ 缺文件 {dir_name}/{old}")
            continue
        out.append(f"  {dir_name}: {old} → {new}")
        if apply:
            os.rename(src, dst)

    # ---------- 2. 新封面 ----------
    out.append("## 新封面")
    src_kr = os.path.join("tools", "_p17_cover_trash_kr.jpg")
    for dir_name, new in NEW_COVERS:
        dst = os.path.join(BASE, dir_name, "cover", new)
        if os.path.exists(dst):
            out.append(f"  跳过（已存在）{dir_name}/{new}")
            continue
        if not os.path.exists(src_kr):
            out.append(f"  ⚠ 缺源图 {src_kr}")
            continue
        out.append(f"  {dir_name}: + {new}")
        if apply:
            shutil.copy2(src_kr, dst)

    # ---------- 3. local.db ----------
    conn = sqlite3.connect(LOCAL_DB)
    conn.row_factory = sqlite3.Row
    cols = [r[1] for r in conn.execute("PRAGMA table_info(comics)")]
    out.append(f"## local.db（alt_titles 列{'已存在' if 'alt_titles' in cols else '待新增'}）")
    if apply and "alt_titles" not in cols:
        conn.execute(
            "ALTER TABLE comics ADD COLUMN alt_titles TEXT NOT NULL DEFAULT '';")

    out.append("## 原名 / 译名")
    for dir_name, lines in ALT_TITLES.items():
        row = conn.execute("SELECT id, title FROM comics WHERE directory=?",
                           (dir_name,)).fetchone()
        if row is None:
            out.append(f"  ⚠ 找不到 directory={dir_name}")
            continue
        out.append(f"  {row['title']}（id={row['id']}）: {len(lines)} 行")
        if apply:
            conn.execute("UPDATE comics SET alt_titles=? WHERE id=?",
                         (json.dumps(lines, ensure_ascii=False), row["id"]))

    out.append("## 封面指针")
    for dir_name, rel in COVER_PICK.items():
        row = conn.execute(
            "SELECT id, cover FROM comics WHERE directory=?", (dir_name,)
        ).fetchone()
        if row is None:
            out.append(f"  ⚠ 找不到 directory={dir_name}")
            continue
        out.append(f"  {row['id']}: {row['cover']} → {rel}")
        if apply:
            conn.execute("UPDATE comics SET cover=? WHERE directory=?",
                         (rel, dir_name))

    # ---------- 4. 渣男转本地 ----------
    out.append("## 渣男转本地（local.db）")
    row = conn.execute("SELECT * FROM comics WHERE id=?", (TRASH_ID,)).fetchone()
    if row is None:
        out.append("  ⚠ local.db 里找不到这本")
    else:
        dirs = disk_chapters(TRASH_DIR)
        chapters = {d: chapter_display(d) for d in dirs}
        old_n = len(json.loads(row["chapters"]))
        out.append(f"  磁盘章节 {len(dirs)} 个（原记录 {old_n} 章）")
        out.append(f"  comic_type {row['comic_type']} → 0")
        if apply:
            # 🔴 绝不能先 DELETE 再 UPDATE：`comic_type` 是复合主键的一半，
            # "删旧行+插入新行"当时写成"删旧行+UPDATE 同 id"，删完 UPDATE 就
            # 匹配不到任何行，整本漫画凭空消失（P17 第一次跑就踩了，靠
            # local.db.bak_p17_* 才捞回来）。主键列可以直接改，没有冲突。
            conn.execute(
                "UPDATE comics SET comic_type=0, chapters=?, downloadedChapters=?,"
                " tags=?, subtitle=?, update_time=?, cover=? WHERE id=?",
                (json.dumps(chapters, ensure_ascii=False),
                 json.dumps(dirs, ensure_ascii=False),
                 json.dumps(TRASH_TAGS, ensure_ascii=False),
                 TRASH_SUBTITLE, TRASH_UPDATE,
                 COVER_PICK[TRASH_DIR], TRASH_ID),
            )
    if apply:
        conn.commit()
    conn.close()

    # ---------- 5. history.db ----------
    out.append("## history.db（type → 0）")
    h = sqlite3.connect(HISTORY_DB)
    n1 = h.execute("SELECT count(*) FROM history WHERE id=? AND type<>0",
                   (TRASH_ID,)).fetchone()[0]
    n2 = h.execute("SELECT count(*) FROM reading_statistics WHERE id=? AND type<>0",
                   (TRASH_ID,)).fetchone()[0]
    out.append(f"  history {n1} 行 / reading_statistics {n2} 行")
    if apply:
        h.execute("UPDATE history SET type=0 WHERE id=? AND type<>0", (TRASH_ID,))
        h.execute("UPDATE reading_statistics SET type=0 WHERE id=? AND type<>0",
                  (TRASH_ID,))
        h.commit()
    h.close()

    # ---------- 6. 域库 ----------
    out.append("## 域库 cover_uri")
    d = sqlite3.connect(DOMAIN_DB)
    d.row_factory = sqlite3.Row
    conn2 = sqlite3.connect(LOCAL_DB)
    conn2.row_factory = sqlite3.Row
    for r in conn2.execute("SELECT id, title, cover FROM comics"):
        cid = f"local:{r['id']}"
        cur = d.execute("SELECT cover_uri FROM comics WHERE comic_id=?",
                        (cid,)).fetchone()
        if cur is None:
            continue
        if cur["cover_uri"] != r["cover"]:
            out.append(f"  {cid}: {cur['cover_uri']} → {r['cover']}")
            if apply:
                d.execute("UPDATE comics SET cover_uri=? WHERE comic_id=?",
                          (r["cover"], cid))
    conn2.close()

    out.append("## 域库 渣男身份合并")
    new_id = f"local:{TRASH_ID}"
    for old in TRASH_REMOTE_IDS:
        he = d.execute("SELECT count(*) FROM history_events WHERE comic_id=?",
                       (old,)).fetchone()[0]
        ch = d.execute("SELECT count(*) FROM chapters WHERE comic_id=?",
                       (old,)).fetchone()[0]
        out.append(f"  {old}: history={he} chapters={ch}")
    exists = d.execute("SELECT 1 FROM comics WHERE comic_id=?",
                       (new_id,)).fetchone()
    out.append(f"  目标身份 {new_id} {'已存在' if exists else '待创建'}")
    if apply:
        # 先迁历史（CASCADE 会随旧行一起删），再改主行、删多余行
        for old in TRASH_REMOTE_IDS:
            d.execute("UPDATE history_events SET comic_id=? WHERE comic_id=?",
                      (new_id, old))
            d.execute("UPDATE favorites SET comic_id=? WHERE comic_id=?",
                      (new_id, old))
        d.execute("UPDATE comics SET comic_id=?, cover_uri=? WHERE comic_id=?",
                  (new_id, COVER_PICK[TRASH_DIR], TRASH_REMOTE_IDS[0]))
        # 断链：chapter_sources → comic_sources → comics（顺序不能反）
        d.execute(
            "DELETE FROM chapter_sources WHERE chapter_id IN "
            "(SELECT chapter_id FROM chapters WHERE comic_id=?)", (new_id,))
        d.execute("DELETE FROM comic_sources WHERE comic_id=?", (new_id,))
        for old in TRASH_REMOTE_IDS[1:]:
            d.execute("DELETE FROM comic_sources WHERE comic_id=?", (old,))
            d.execute("DELETE FROM comics WHERE comic_id=?", (old,))
        d.execute("UPDATE chapters SET comic_id=? WHERE comic_id=?",
                  (new_id, TRASH_REMOTE_IDS[0]))
        now = int(time.time() * 1000)
        if d.execute("SELECT 1 FROM local_library_items WHERE comic_id=?",
                     (new_id,)).fetchone() is None:
            # local_item_id 是 INTEGER 主键（不是字符串），必须自己取下一个号；
            # storage_state 的取值是 `available`（老数据里就是这么写的）。
            next_id = d.execute(
                "SELECT COALESCE(MAX(local_item_id), 0) + 1 FROM local_library_items"
            ).fetchone()[0]
            d.execute(
                "INSERT INTO local_library_items (local_item_id, comic_id, "
                "directory, import_root, storage_state, created_at, updated_at) "
                "VALUES (?,?,?,?,?,?,?)",
                (next_id, new_id, TRASH_DIR,
                 os.path.abspath(os.path.join(BASE, TRASH_DIR)),
                 "available", now, now),
            )
        d.commit()

    out.append("## 域库合计")
    for q, label in [
        ("SELECT COUNT(*) FROM history_events", "history_events"),
        ("SELECT COUNT(*) FROM comics", "comics"),
        ("SELECT COUNT(*) FROM chapters WHERE comic_id LIKE 'local:%'",
         "local chapters"),
        ("SELECT COUNT(*) FROM comic_sources WHERE comic_id=?",
         "渣男 comic_sources"),
    ]:
        args = (new_id,) if "?" in q else ()
        out.append(f"  {label} = {d.execute(q, args).fetchone()[0]}")
    d.close()

    print("\n".join(out))
    print("\n" + ("APPLIED" if apply else "DRY-RUN（加 --apply 执行）"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
