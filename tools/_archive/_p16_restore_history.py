"""P16 补救：把被删掉的 comix_to 远端身份的阅读历史/收藏迁到新的 local 身份。

背景：P16 把 3 本 comix 漫画从 `remote:comix_to:*` 转成本地 `local:*`，
删旧 comics 行时 `history_events.comic_id` 的 `ON DELETE CASCADE` 把
798 条阅读史一起带走了。这里从改库前的备份里捞回来，只改 comic_id 归属。

用法：
    py -3.12 tools/_p16_restore_history.py           # 只读体检
    py -3.12 tools/_p16_restore_history.py --apply   # 写库（务必先关 App）
"""

import os
import sqlite3
import sys

DOMAIN_DB = os.path.join("data", "data", "mangrove.db")
BACKUP = os.path.join("data", "data", "mangrove.db.bak_p15_20261024_204321")

# 旧远端身份 → 新本地身份
ID_MAP = {
    "remote:comix_to:9lmnj//error-the-echo":
        "local:9lmnj//error-the-echo",
    "remote:comix_to:503jz//i-will-save-my-father":
        "local:503jz//i-will-save-my-father",
    "remote:comix_to:gm28k//my-dragon-girlfriend-has-returned":
        "local:gm28k//my-dragon-girlfriend-has-returned",
}


def main() -> int:
    apply = "--apply" in sys.argv
    if not os.path.exists(BACKUP):
        print(f"备份不存在：{BACKUP}")
        return 1

    old = sqlite3.connect(f"file:{BACKUP}?mode=ro", uri=True)
    old.row_factory = sqlite3.Row
    cur = sqlite3.connect(DOMAIN_DB)
    cur.execute("PRAGMA foreign_keys=ON")

    print("=" * 62)
    print("P16 历史迁移" + ("（执行）" if apply else "（只读体检）"))
    print("=" * 62)

    total_hist = 0
    total_fav = 0
    for old_id, new_id in ID_MAP.items():
        if not cur.execute(
            "SELECT 1 FROM comics WHERE comic_id=?", (new_id,)
        ).fetchone():
            print(f"  ✗ 新身份不存在，跳过：{new_id}")
            continue
        hist = old.execute(
            "SELECT chapter_id, page_id, event_type, occurred_at "
            "FROM history_events WHERE comic_id=? ORDER BY occurred_at",
            (old_id,),
        ).fetchall()
        favs = old.execute(
            "SELECT folder_name, sort_order, created_at FROM favorites "
            "WHERE comic_id=?",
            (old_id,),
        ).fetchall()
        have = cur.execute(
            "SELECT COUNT(*) FROM history_events WHERE comic_id=?", (new_id,)
        ).fetchone()[0]
        print(f"\n{new_id}")
        print(f"  备份里 history {len(hist)} 条 / favorites {len(favs)} 条，"
              f"当前新身份已有 {have} 条"
              f"（chapter_id 非空 {sum(1 for h in hist if h['chapter_id'])} 条）")
        total_hist += len(hist)
        total_fav += len(favs)
        if not apply:
            continue
        # 只迁 comic_id 归属；chapter_id 在旧库里几乎全是 NULL，
        # 有值的（极少数）随章节重建一起作废，置空比指向错章安全。
        cur.executemany(
            "INSERT INTO history_events (comic_id, chapter_id, page_id,"
            " event_type, occurred_at) VALUES (?, NULL, ?, ?, ?)",
            [(new_id, h["page_id"], h["event_type"], h["occurred_at"])
             for h in hist],
        )
        cur.executemany(
            "INSERT OR IGNORE INTO favorites (comic_id, folder_name,"
            " sort_order, created_at) VALUES (?, ?, ?, ?)",
            [(new_id, f["folder_name"], f["sort_order"], f["created_at"])
             for f in favs],
        )
        print(f"  ✓ 迁入 history {len(hist)} / favorites {len(favs)}")

    print(f"\n合计 history {total_hist} 条 / favorites {total_fav} 条")
    if apply:
        cur.commit()
        print("已提交。")
    else:
        print("（只读体检，未改动；加 --apply 执行）")
    cur.close()
    old.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
