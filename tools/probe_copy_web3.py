# -*- coding: utf-8 -*-
"""临时探测3: /comics筛选参数/排行/阅读器解密/图片referer (用完即删)"""
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

def aes_dec(key_str, enc):
    iv = enc[:16].encode()
    ct = bytes.fromhex(enc[16:])
    return unpad(AES.new(key_str.encode(), AES.MODE_CBC, iv).decrypt(ct), 16)

def title(t): print("\n" + "=" * 15 + " " + t + " " + "=" * 15)

# ---------- 1. /comics 参数矩阵 ----------
title("1. /comics params")
card_re = re.compile(r'/comic/([A-Za-z0-9_\-]+)"[^>]*>.*?data-src="([^"]+)"', re.S)
tests = [
    "/comics?ordering=-datetime_updated&offset=0&limit=50",
    "/comics?ordering=-datetime_updated&offset=50&limit=50",
    "/comics?theme=maoxian&ordering=-popular&offset=0&limit=50",
    "/comics?theme=maoxian&top=japan&offset=0&limit=50",
    "/comics?top=korea&offset=0&limit=50",
    "/comics?status=end&offset=0&limit=50",
]
for path in tests:
    r = s.get(f"https://{WEB}{path}", timeout=20)
    slugs = re.findall(r'href="/comic/([A-Za-z0-9_\-]+)"', r.text)
    uniq = list(dict.fromkeys(slugs))
    pag = re.search(r'<li class="page-total">/(\d+)</li>', r.text)
    print(f"  {path}\n    -> {r.status_code} len={len(r.text)} uniqComics={len(uniq)} "
          f"totalPages={pag.group(1) if pag else '?'} first3={uniq[:3]}")

# ---------- 2. 列表卡片字段样例(标题/作者/封面/更新话) ----------
title("2. list card sample")
r = s.get(f"https://{WEB}/comics?ordering=-datetime_updated&offset=0&limit=50", timeout=20)
# 找到主体列表容器
m = re.search(r'<ul class="[^"]*comic[^"]*"', r.text)
print("  comic ul class:", m.group(0) if m else None)
for cls in ["comic", "list", "card", "item"]:
    ms = re.findall(r'class="([^"]*' + cls + r'[^"]*)"', r.text)
    from collections import Counter
    print(f"  classes containing {cls!r}:", Counter(ms).most_common(8))
# 打印一个卡片完整块
i = r.text.find('href="/comic/grandblue"')
if i < 0:
    i = r.text.find('class="comic')
print(r.text[max(0, i-700):i+700])

# ---------- 3. 排行 tabs ----------
title("3. rank tabs")
for tab in ["male&table=day", "male&table=week", "male&table=month",
            "male&table=total", "female&table=day"]:
    r = s.get(f"https://{WEB}/rank?type={tab}", timeout=20)
    slugs = list(dict.fromkeys(re.findall(r'href="/comic/([A-Za-z0-9_\-]+)"', r.text)))
    box = re.findall(r'ranking-box-title">\s*<span>([^<]+)</span>', r.text)
    print(f"  {tab}: {r.status_code} comics={len(slugs)} titles={box} first={slugs[:3]}")

# ---------- 4. 阅读器解密 ----------
title("4. reader decrypt")
slug = "haizeiwang"
uuid = "4bd05882-c7bc-11e8-881a-024352452ce0"
r = s.get(f"https://{WEB}/comic/{slug}/chapter/{uuid}", timeout=20)
cct = re.search(r"var\s+cct\s*=\s*'([^']*)'", r.text).group(1)
ckey = re.search(r"contentKey\s*=\s*'([^']*)'", r.text).group(1)
pt = aes_dec(cct, ckey)
j = json.loads(pt.decode())
urls = j.get("url") or []
print("  decrypted keys:", list(j.keys()), "S:", j.get("S"), "urls:", len(urls))
print("  first 3:", urls[:3])
savef = os.path.join(OUT, "reader_urls.json")
open(savef, "w", encoding="utf-8").write(json.dumps(j, ensure_ascii=False)[:50000])
# 图片下载测试(带/不带 Referer)
if urls:
    u = urls[0]
    for name, hdr in [("no-referer", {}),
                      ("web-referer", {"Referer": f"https://{WEB}/"})]:
        rr = requests.get(u, headers={"User-Agent": UA, **hdr},
                          proxies=PROXY, timeout=30)
        print(f"  img {name}: {rr.status_code} {len(rr.content)}B "
              f"magic={rr.content[:3].hex()} ctype={rr.headers.get('content-type')}")

# ---------- 5. 首页轮播 ----------
title("5. home carousel")
home = open(os.path.join(OUT, "home.html"), encoding="utf-8").read()
slides = re.findall(
    r'carousel-item[^>]*>\s*<a href="/comic/([^"]+)"[^>]*>\s*'
    r'<img[^>]*data-src="([^"]+)"[^>]*/?>\s*</a>\s*'
    r'<div class="carousel-caption">\s*<a[^>]*>\s*<p>([^<]*)</p>',
    home)
print("  slides:", len(slides))
for x in slides[:5]:
    print("   ", x)
# 每日推荐块
daily = re.findall(
    r'dailyRecommendation-img[^>]*>\s*<a href="/comic/([^"]+)"[^>]*>\s*'
    r'<img[^>]*data-src="([^"]+)"', home)
print("  daily boxes:", len(daily), daily[:3])
# 排行榜 tab 名称
tabs = re.findall(r'item-rankingList[^>]*>(.*?)</li>', home, re.S)
for t in tabs[:6]:
    txt = re.sub(r'<[^>]+>', '', t).strip()
    print("  rank tab:", txt[:30])

print("\nDONE")
