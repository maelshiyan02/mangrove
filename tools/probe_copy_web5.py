# -*- coding: utf-8 -*-
"""临时探测5: /comics list属性提取 + 参数矩阵 + 首页分区 (用完即删)"""
import sys, io, json, re, os, html as htmllib
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
import requests

PROXY = {"http": "http://127.0.0.1:7890", "https": "http://127.0.0.1:7890"}
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
OUT = r"d:\Ballonstranslator_Windows\probe_out"
WEB = "www.copy5000.com"
s = requests.Session(); s.proxies.update(PROXY); s.headers.update({"User-Agent": UA})

def extract_list(text):
    # <div class="row exemptComic-box" total="N" list="[{'path_word': '...'}]">
    m = re.search(r'class="[^"]*exemptComic-box[^"]*"\s+total="(\d+)"\s+list="(.*?)"\s*>',
                  text, re.S)
    if not m:
        return None, 0
    total = int(m.group(1))
    raw = htmllib.unescape(m.group(2))  # &#x27; -> '
    items = []
    for blk in raw.split("{'path_word':")[1:]:
        def g(key):
            mm = re.search(r"'" + key + r"':\s*'((?:[^'\\]|\\.)*)'", blk)
            return mm.group(1) if mm else ""
        authors = re.findall(r"\{'name':\s*'((?:[^'\\]|\\.)*)',\s*'path_word':", blk)
        sm = re.search(r"'status':\s*(\d+)", blk)
        items.append({
            "path_word": g("path_word"),
            "name": g("name"),
            "cover": g("cover"),
            "status": int(sm.group(1)) if sm else None,
            "author": authors,
        })
    return items, total

def title(t): print("\n" + "=" * 15 + " " + t + " " + "=" * 15)

title("1. /comics param matrix via list attr")
tests = [
    "/comics?ordering=-datetime_updated&offset=0&limit=50",
    "/comics?ordering=-datetime_updated&offset=50&limit=50",
    "/comics?ordering=-popular&offset=0&limit=50",
    "/comics?theme=maoxian&offset=0&limit=50",
    "/comics?theme=maoxian&top=japan&offset=0&limit=50",
    "/comics?top=korea&offset=0&limit=50",
    "/comics?status=end&offset=0&limit=50",
    "/comics?theme=maoxian&ordering=datetime_updated&offset=0&limit=50",
]
pages = {}
for path in tests:
    r = s.get(f"https://{WEB}{path}", timeout=20)
    lst, total = extract_list(r.text)
    n = len(lst) if lst else 0
    first3 = [x["path_word"] for x in lst[:3]] if lst else []
    print(f"  {path}\n     n={n} total={total} first3={first3}")
    pages[path] = [x["path_word"] for x in (lst or [])]
a = pages[tests[0]]; b = pages[tests[1]]
if a and b:
    print("  page1 vs page2 overlap:", len(set(a) & set(b)), "(expect 0)")

# 完整字段
r = s.get(f"https://{WEB}/comics?ordering=-datetime_updated&offset=0&limit=50", timeout=20)
lst, total = extract_list(r.text)
print("\n  item full:", json.dumps(lst[0], ensure_ascii=False)[:700])
pag = re.search(r'<li class="page-total">/(\d+)</li>', r.text)
print("  total attr:", total, "last page:", pag.group(1) if pag else "?")

# ---------- 2. 首页分区 ----------
title("2. home sections")
home = open(os.path.join(OUT, "home.html"), encoding="utf-8").read()
# 首页是否有 exemptComic-box list
hlst, htotal = extract_list(home)
print("  home exemptComic list:", len(hlst) if hlst else None, "total:", htotal)
# 排行榜 tab + 内容
tabs = re.findall(r'item-rankingList[^>]*>(.*?)</li>', home, re.S)
for t in tabs[:8]:
    print("  tab:", re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', '', t)).strip()[:40])
# tab 里的 a href
tabblocks = re.findall(r'<div class="tab-pane[^"]*"[^>]*>(.*?)</div>\s*</div>', home, re.S)
print("  tab panes:", len(tabblocks))
# rank list 结构样例
i = home.find('class="swiper-rankingList"')
print(home[i:i+1200])

print("\nDONE")
