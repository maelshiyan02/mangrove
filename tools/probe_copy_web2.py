# -*- coding: utf-8 -*-
"""临时探测2: session化章节接口 + 分类/排行/阅读器页结构 (用完即删)"""
import sys, io, json, re, os
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
import requests
from Cryptodome.Cipher import AES
from Cryptodome.Util.Padding import unpad

PROXY = {"http": "http://127.0.0.1:7890", "https": "http://127.0.0.1:7890"}
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
OUT = r"d:\Ballonstranslator_Windows\probe_out"
WEB = "www.copy5000.com"

def save(name, text):
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        f.write(text)

def title(t): print("\n" + "=" * 15 + " " + t + " " + "=" * 15)

s = requests.Session()
s.proxies.update(PROXY)
s.headers.update({"User-Agent": UA})

# ---------- 1. session 化章节列表 ----------
title("1. chapters via session")
slug = "haizeiwang"
r = s.get(f"https://{WEB}/comic/{slug}", timeout=20)
print("  detail:", r.status_code, "cookies:", s.cookies.get_dict())
dnt = re.search(r'id="dnt"[^>]*value="([^"]*)"', r.text).group(1)
ccz = re.search(r"var\s+ccz\s*=\s*'([^']*)'", r.text).group(1)
print("  dnt:", dnt, "ccz:", ccz)
r2 = s.get(f"https://{WEB}/comicdetail/{slug}/chapters",
           headers={"Referer": f"https://{WEB}/comic/{slug}",
                    "dnts": dnt, "Accept": "application/json"},
           timeout=20)
print("  chapters status:", r2.status_code, "ct:", r2.headers.get("content-type"),
      "len:", len(r2.text))
if "json" in (r2.headers.get("content-type") or "") or r2.text[:1] == "{":
    cd = r2.json()
    enc = cd.get("results") or ""
    print("  code:", cd.get("code"), "enc len:", len(enc), "head:", enc[:100])
    save("chapters_haizeiwang_enc.txt", enc)
    iv = enc[:16].encode(); ct = bytes.fromhex(enc[16:])
    pt = unpad(AES.new(ccz.encode(), AES.MODE_CBC, iv).decrypt(ct), 16)
    j = json.loads(pt.decode())
    save("chapters_haizeiwang_dec.json", json.dumps(j, ensure_ascii=False)[:300000])
    g = j.get("groups", {}).get("default", {})
    chs = g.get("chapters") or []
    print("  DECRYPT OK. keys:", list(j.keys()))
    print("  build keys:", list(j.get("build", {}).keys()))
    print("  group:", {k: (v if not isinstance(v, list) else f"list[{len(v)}]")
                       for k, v in g.items()})
    if chs:
        print("  chapter[0]:", json.dumps(chs[0], ensure_ascii=False)[:400])
        print("  chapter[-1]:", json.dumps(chs[-1], ensure_ascii=False)[:400])
else:
    save("chapters_fail.txt", r2.text[:3000])
    print("  NON-JSON head:", r2.text[:300])

# ---------- 2. 阅读器页 ----------
title("2. reader page")
uuid = "4bd05882-c7bc-11e8-881a-024352452ce0"
r3 = s.get(f"https://{WEB}/comic/{slug}/chapter/{uuid}", timeout=20)
print("  reader:", r3.status_code, "len:", len(r3.text))
save("reader.html", r3.text)
cct = re.search(r"var\s+cct\s*=\s*'([^']*)'", r3.text)
ckey = re.search(r"contentKey\s*=\s*'([^']*)'", r3.text)
print("  cct:", cct.group(1) if cct else None)
print("  contentKey len:", len(ckey.group(1)) if ckey else None,
      "head:", ckey.group(1)[:80] if ckey else None)
# prev/next 链接
navs = re.findall(r'href="(/comic/[^"]+/chapter/[0-9a-f-]{36})"[^>]*>([^<]{0,30})', r3.text)
for n in navs[:10]:
    print("  nav:", n)
# 页码
pm = re.findall(r"第\s*(\d+)\s*/\s*(\d+)\s*話", r3.text)
print("  page marks:", pm[:5])
# contentKey 上下文
if ckey:
    i = r3.text.find("contentKey")
    print("  ctx:", r3.text[max(0, i-200):i+200].replace("\n", " ")[:400])

# ---------- 3. /comics 發現页 ----------
title("3. /comics discovery page")
r4 = s.get(f"https://{WEB}/comics", timeout=20)
print("  /comics:", r4.status_code, "len:", len(r4.text))
save("comics.html", r4.text[:200000])
# 卡片结构样例
m = re.search(r'/comic/[A-Za-z0-9_\-]+', r4.text)
if m:
    i = m.start()
    print(r4.text[max(0, i-400):i+500])
# 分页线索
for kw in ["page=", "下一頁", "next", "pagination", "totalPage", "total_page", "pageCount"]:
    print(f"  kw {kw!r}: {r4.text.count(kw)}")

# ---------- 4. /filter 题材页 ----------
title("4. /filter page")
r5 = s.get(f"https://{WEB}/filter", timeout=20)
print("  /filter:", r5.status_code, "len:", len(r5.text))
save("filter.html", r5.text[:200000])
themes = sorted(set(re.findall(r'href="/comics\?theme=([a-zA-Z0-9_]+)"', r5.text)))
print("  themes found:", len(themes), themes[:60])

# ---------- 5. /rank 排行榜 ----------
title("5. /rank page")
r6 = s.get(f"https://{WEB}/rank", timeout=20)
print("  /rank:", r6.status_code, "len:", len(r6.text))
save("rank.html", r6.text[:200000])
rlinks = sorted(set(re.findall(r'href="(/rank[^"]*)"', r6.text)))
print("  rank links:", rlinks[:30])
slugs6 = re.findall(r"/comic/([A-Za-z0-9_\-]+)", r6.text)
print("  comic count:", len(set(slugs6)))
m = re.search(r'/comic/[A-Za-z0-9_\-]+', r6.text)
if m:
    i = m.start()
    print(r6.text[max(0, i-300):i+400])

print("\nDONE")
