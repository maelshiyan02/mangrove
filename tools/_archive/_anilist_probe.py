import json
import subprocess
import sys

NAMES = {
    "gm28k": "My Dragon Girlfriend Has Returned",
    "9lmnj": "Error the Echo",
    "503jz": "I will save my father",
    "mnm90": "The Archvillain's Dying Nanny",
    "7zdxe": "The Perks of Being a Villainess",
}

QUERY = """
query ($s: String) {
  Page(perPage: 3) {
    media(search: $s, type: MANGA) {
      id
      title { romaji english native }
      description
      genres
      coverImage { extraLarge large }
      status
      chapters
    }
  }
}
"""


def post(body: dict) -> dict:
    r = subprocess.run(
        [
            "curl", "-s", "-m", "40", "-x", "http://127.0.0.1:7890",
            "-H", "Content-Type: application/json",
            "-d", json.dumps(body), "https://graphql.anilist.co",
        ],
        capture_output=True,
    )
    return json.loads(r.stdout)


out = {}
for hid, name in NAMES.items():
    try:
        d = post({"query": QUERY, "variables": {"s": name}})
        medias = d["data"]["Page"]["media"]
    except Exception as exc:  # noqa: BLE001
        print(f"{hid} ERR {str(d)[:140]}")
        continue
    if not medias:
        print(f"{hid:6s} {name[:34]:36s} 无结果")
        continue
    picked = medias[0]
    out[hid] = {"name": name, "anilist": picked}
    desc = (picked.get("description") or "").replace("\n", " ")
    print(f"{hid:6s} {name[:30]:32s} id={picked['id']} ch={picked.get('chapters')} "
          f"romaji={picked['title']['romaji'][:28]}")
    print(f"       cover={picked['coverImage']['extraLarge']}")
    print(f"       desc={desc[:200]}")

with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
print(f"\n写出 {sys.argv[1]}（{len(out)} 本）")
