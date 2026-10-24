"""检查 5 本漫画是否存在「第二季」独立条目（可能对应另一张封面）。

只查关系图，不下载任何东西：AniList 的 relations 里出现 SEQUEL / SIDE_STORY /
ALTERNATIVE 且 type=MANGA，就说明有另一张官方封面存在。
"""

import json
import subprocess
import sys

IDS = {
    "Error the Echo": 217286,
    "I will save my father": 212727,
    "The Archvillain's Dying Nanny": 176804,
    "The Perks of Being a Villainess": 158706,
}

QUERY = """
query ($id: Int) {
  Media(id: $id, type: MANGA) {
    id
    title { romaji english }
    chapters
    coverImage { extraLarge }
    relations {
      edges {
        relationType
        node { id type title { romaji english } chapters coverImage { extraLarge } }
      }
    }
  }
}
"""


def post(body):
    r = subprocess.run(
        ["curl", "-s", "-m", "40", "-x", "http://127.0.0.1:7890",
         "-H", "Content-Type: application/json",
         "-d", json.dumps(body), "https://graphql.anilist.co"],
        capture_output=True,
    )
    return json.loads(r.stdout)


for name, aid in IDS.items():
    try:
        d = post({"query": QUERY, "variables": {"id": aid}})
        m = d["data"]["Media"]
    except Exception:  # noqa: BLE001
        print(f"{name}: 查询失败 {str(d)[:100]}")
        continue
    seasons = [
        e for e in m["relations"]["edges"]
        if e["node"]["type"] == "MANGA"
        and e["relationType"] in ("SEQUEL", "PREQUEL", "SIDE_STORY", "ALTERNATIVE")
    ]
    print(f"\n{name}  （AniList id={aid}，{m.get('chapters') or '?'} 话）")
    if not seasons:
        print("  无系列关系 → 单季封面")
    for e in seasons:
        n = e["node"]
        t = n["title"]["english"] or n["title"]["romaji"]
        print(f"  [{e['relationType']}] id={n['id']} {t}  {n.get('chapters')} 话")
        print(f"      cover={n['coverImage']['extraLarge']}")
