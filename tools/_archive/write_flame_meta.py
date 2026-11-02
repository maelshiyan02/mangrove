#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""给《灭门家族的重生者》写「用户覆盖层」元数据（P48，2026-10-27）。

写入目标：`data/data/mangrove.db` 的 `comic_field_overrides`（KV 表）。
这一层优先级最高（覆盖值 > 网络值 > 兜底），所以不会被下一次源刷新冲掉。
格式必须与 `ComicOverrideStore._upsertRow` 一致：`value_json = json.dumps(value)`。

⚠️ 必须在 App 未运行时执行（App 持有 sqlite 连接 + 内存缓存）。
"""
import json
import os
import shutil
import sqlite3
import time

DB = r"D:/AI Coding Project Management/Mangrove/data/data/mangrove.db"
COMIC_ID = (
    "remote:baozi:"
    "miemenjiazudezhongshengzhe-yangpyungpainkillersaintnine"
)

SUBTITLE = "멸망한 가문의 회귀자 ／ A Flame Reborn"

AUTHOR = "原著小说 Painkiller ｜ 分镜改编 양평 Yang Pyung ｜ 作画 성구 Saint Nine"

STATUS = "连载中 · 韩国 157 话（2026-10-23）"

TAGS = [
    "韩国",
    "奇幻",
    "重生",
    "复仇",
    "战争",
    "中世纪",
    "每周六更新（韩国）",
    "简体正版：咚漫/快看/哔哩哔哩漫画",
    "繁体正版：LINE WEBTOON",
]

DESCRIPTION = """▍原名：멸망한 가문의 회귀자（Myeolmanghan Gamunui Hoegwija）
▍官方英文名：A Flame Reborn（WEBTOON 官方）
▍其他译名：Regressor of the Fallen Family ／ Returner of a Ruined Family（英·非官方）｜復仇者羅根（台译）｜滅亡した家門の回帰者（日译）

▍创作分工
· 原著小说：Painkiller
· 分镜／剧本改编：양평 Yang Pyung
· 作画：성구 Saint Nine
（Naver Webtoon 官方作者栏、LINE WEBTOON 繁中页、Bangumi 三处一致）

▍原著小说
《멸망한 가문의 회귀자 [독점]》Naver Series 独家，全 500 话，2024-01-05 收官。

▍韩国连载（原版）
· 平台：Naver Webtoon ＋ Naver Series
· 开载：2024-01-05
· 排期：每周六（Naver 官方分类「토요웹툰」，即周六漫画），每日 22:00 KST 免费开放
· 进度：157 话，最后更新 2026-10-23

▍简体中文正版（中国大陆）
· 引进／发行：北京咚漫娱乐有限公司，2024-07-05 于「咚漫漫画」首发
· 排期：每周六 0:00 更新（北京时间）
· 渠道：咚漫漫画（首发）／快看漫画／哔哩哔哩漫画（mc38194）
· 进度：三渠道均更新至 150 话

▍繁体中文正版（台港澳）
· 平台：LINE WEBTOON（NAVER WEBTOON 直营），译名《復仇者羅根》
· 官方标注：周五更新（话次上架日期实际落在周四；订阅 154.3 万）
· 进度：第 133 話（2026-10-22）；最新 20 話仅限 APP 内阅读

▍封面沿革（Naver 官方主视觉 480×623，按时间顺序）
· 第 1 张 — 2024-01-05 首发（带标题字；2024-01-13 存档已见该图）
· 第 2 张 — 最晚 2025-01-04 起（2025-01-08 存档确认；启用时点缺可靠存档）
· 第 3 张 — 2025-09-16～2025-09-29 之间更换（2025-09-16 存档仍为第 2 张，
  2025-09-29 该图像文件首见）→ 现行

▍简介
他这一生充满悔恨。认识到错误想重新做人，但还没得到家人的原谅，家族已经被付之一炬。
作为被灭门家族的幸存者，他在愤怒的地狱中苟活着，而在绝望的尽头，他内心的渴望终于
打动了上天。重来一世，他向命运举起了反抗之剑。"""

FIELDS = {
    "subtitle": SUBTITLE,
    "author": AUTHOR,
    "status": STATUS,
    "language": "zh-CN",
    "tags": TAGS,
    "description": DESCRIPTION,
}


def main():
    if not os.path.exists(DB):
        raise SystemExit(f"db not found: {DB}")
    backup = DB + ".bak_p48_meta_" + time.strftime("%Y%m%d_%H%M%S")
    shutil.copy2(DB, backup)
    print("backup:", backup)

    con = sqlite3.connect(DB, timeout=15)
    try:
        row = con.execute(
            "SELECT comic_id, title FROM comics WHERE comic_id = ?", (COMIC_ID,)
        ).fetchone()
        if not row:
            raise SystemExit(f"comic row not found: {COMIC_ID}")
        print("target:", row)

        now = int(time.time() * 1000)
        con.execute("BEGIN;")
        for key, value in FIELDS.items():
            con.execute(
                "INSERT INTO comic_field_overrides (comic_id, field_key, value_json, updated_at) "
                "VALUES (?, ?, ?, ?) "
                "ON CONFLICT(comic_id, field_key) DO UPDATE SET "
                "value_json = excluded.value_json, updated_at = excluded.updated_at;",
                (COMIC_ID, key, json.dumps(value, ensure_ascii=False), now),
            )
        con.execute("COMMIT;")
    finally:
        con.close()

    con = sqlite3.connect(DB, timeout=15)
    print("\n=== 写入结果 ===")
    for key, value_json, ts in con.execute(
        "SELECT field_key, value_json, updated_at FROM comic_field_overrides "
        "WHERE comic_id = ? ORDER BY field_key;",
        (COMIC_ID,),
    ):
        print(f"{key}: {value_json[:160]}")
    con.close()


if __name__ == "__main__":
    main()
