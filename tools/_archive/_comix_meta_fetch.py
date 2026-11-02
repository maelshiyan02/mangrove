"""抓 comix.to 详情页的 SSR 元数据（作者/画师/标签/简介/封面/话数）。

验证过：详情页 HTML 里带完整 JSON 片段（authors/artists/genres/poster/
altTitles/synopsis/latestChapter），不需要浏览器，也不触发 WAF。
仅用于 P15 的一本一次性补全，不进主程序。
"""

import json
import re
import subprocess
import sys

PROXY = "http://127.0.0.1:7890"
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

BOOKS = [
    ("gm28k", "My Dragon Girlfriend Has Returned"),
    ("9lmnj", "Error the Echo"),
    ("503jz", "I will save my father"),
    ("mnm90", "The Archvillain's Dying Nanny"),
    ("7zdxe", "The Perks of Being a Villainess"),
]


def fetch_html(hid: str) -> str:
    url = f"https://comix.to/title/{hid}"
    r = subprocess.run(
        ["curl", "-s", "-L", "-m", "60", "-x", PROXY, "-A", UA, url],
        capture_output=True,
    )
    return r.stdout.decode("utf-8", errors="replace")


def grab(html: str, key: str, limit: int = 3000) -> str | None:
    """取 `"key":` 之后的原始片段（够长以容纳嵌套）。"""
    m = re.search(r'"%s"\s*:\s*' % key, html)
    if not m:
        return None
    return html[m.end() : m.end() + limit]


def decode_json_prefix(raw: str):
    """从某个 JSON 值的起点解出第一个完整值。"""
    raw = raw.lstrip()
    dec = json.JSONDecoder()
    try:
        value, _ = dec.raw_decode(raw)
        return value
    except json.JSONDecodeError:
        return None


def parse(html: str) -> dict:
    out = {}
    for key in ("altTitles", "authors", "artists", "genres", "tags", "poster", "synopsis"):
        raw = grab(html, key)
        if raw is None:
            continue
        value = decode_json_prefix(raw)
        if value is not None:
            out[key] = value
    for key in ("latestChapter", "finalChapter", "status", "originalLanguage", "type"):
        m = re.search(r'"%s"\s*:\s*("[^"]*"|null|-?\d+)' % key, html)
        if m:
            v = m.group(1)
            out[key] = None if v == "null" else (v[1:-1] if v.startswith('"') else int(v))
    m = re.search(r'"title"\s*:\s*"([^"]+)"', html)
    if m:
        out["title"] = m.group(1)
    return out


def main() -> int:
    result = {}
    for hid, name in BOOKS:
        html = fetch_html(hid)
        if len(html) < 3000:
            print(f"!! {name}: 只拿到 {len(html)} 字节", file=sys.stderr)
            continue
        meta = parse(html)
        meta["hid"] = hid
        meta["dir"] = name
        result[hid] = meta
        print(
            f"{hid} {name[:34]:36s} "
            f"作者={[a['title'] for a in meta.get('authors', [])]} "
            f"画={[a['title'] for a in meta.get('artists', [])]} "
            f"标签={[g['title'] for g in meta.get('genres', [])]} "
            f"话数={meta.get('latestChapter')}"
        )
    with open(sys.argv[1], "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)
    print(f"\n写出 {sys.argv[1]}（{len(result)} 本）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
