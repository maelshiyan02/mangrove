# -*- coding: utf-8 -*-
"""临时探测4: go.js列表接口 + 阅读器解密结构 (用完即删)"""
import sys, io, json, re, os
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
import requests
from Cryptodome.Cipher import AES
from Cryptodome.Util.Padding import unpad

PROXY = {"http": "http://127.0.0.1:7890", "https": "http://127.0.0.1:7890"}
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
OUT = r"d:\Ballonstranslator_Windows\probe_out"
WEB = "www.copy5000.com"
s = requests.Session(); s.proxies.update(PROXY); s.headers.update({"User-Agent": UA})

def title(t): print("\n" + "=" * 15 + " " + t + " " + "=" * 15)

# ---------- 1. 阅读器解密真实结构 ----------
title("1. reader decrypt structure")
slug, uuid = "haizeiwang", "4bd05882-c7bc-11e8-881a-024352452ce0"
r = s.get(f"https://{WEB}/comic/{slug}/chapter/{uuid}", timeout=20)
cct = re.search(r"var\s+cct\s*=\s*'([^']*)'", r.text).group(1)
ckey = re.search(r"contentKey\s*=\s*'([^']*)'", r.text).group(1)
enc = ckey
pt = unpad(AES.new(cct.encode(), AES.MODE_CBC, enc[:16].encode()).decrypt(
    bytes.fromhex(enc[16:])), 16)
val = json.loads(pt.decode())
print("  top type:", type(val).__name__)
if isinstance(val, list):
    print("  len:", len(val))
    print("  item[0] type:", type(val[0]).__name__)
    print("  item[0]:", json.dumps(val[0], ensure_ascii=False)[:300])
    urls = [x if isinstance(x, str) else x.get("url") for x in val]
    print("  urls count:", len([u for u in urls if u]))
    print("  sample urls:", urls[:3])
    open(os.path.join(OUT, "reader_urls.json"), "w", encoding="utf-8").write(
        json.dumps(val, ensure_ascii=False)[:80000])
    # 图片 referer 测试
    u0 = urls[0]
    for name, hdr in [("no-ref", {}), ("web-ref", {"Referer": f"https://{WEB}/"})]:
        rr = requests.get(u0, headers={"User-Agent": UA, **hdr},
                          proxies=PROXY, timeout=30)
        print(f"  img {name}: {rr.status_code} {len(rr.content)}B magic={rr.content[:3].hex()}")

# ---------- 2. go.js ----------
title("2. go.js")
for js in ["/static/websitefree/js20190704/go.js"]:
    rj = requests.get(f"https://s3.mangafunb.fun{js}", timeout=20)
    print("  status:", rj.status_code, "len:", len(rj.text))
    open(os.path.join(OUT, "go.js"), "w", encoding="utf-8").write(rj.text)
    print(rj.text[:4000])

# ---------- 3. comics.html 中列表容器/接口线索 ----------
title("3. comics.html list area")
html = open(os.path.join(OUT, "comics.html"), encoding="utf-8").read()
# page-all 之前的主体部分 class
i = html.find('class="page-all"')
seg = html[max(0, i-6000):i]
classes = re.findall(r'class="([^"]+)"', seg)
from collections import Counter
print("  classes before pagination:", Counter(classes).most_common(15))
for kw in ["/api/", "request(", "API_URL", "url=\"", ".load(", "append(", "comicList",
           "exemptComic", "limit=", "offset"]:
    idxs = [m.start() for m in re.finditer(re.escape(kw), html)][:5]
    print(f"  {kw!r} hits={html.count(kw)} at={idxs}")

print("\nDONE")
