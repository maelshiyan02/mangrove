# -*- coding: utf-8 -*-
"""临时探测脚本: 拷贝漫画网页端结构取证 (用完即删)"""
import sys, io, json, re, hmac, hashlib, base64, time
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
import requests

PROXY = {"http": "http://127.0.0.1:7890", "https": "http://127.0.0.1:7890"}
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
OUT = r"d:\Ballonstranslator_Windows\probe_out"
import os
os.makedirs(OUT, exist_ok=True)

def save(name, text):
    p = os.path.join(OUT, name)
    with open(p, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"  [saved] {name} ({len(text)} bytes)")

def show(title):
    print("\n" + "=" * 20 + " " + title + " " + "=" * 20)

# ---------- 1. network2 官方公布的网页域 ----------
show("1. network2 hosts")
secret = base64.b64decode("M2FmMDg1OTAzMTEwMzJlZmUwNjYwNTUwYTA1NjNhNTM=")
ts = str(int(time.time()))
sig = hmac.new(secret, ts.encode(), hashlib.sha256).hexdigest()
h = {
    "User-Agent": "COPY/3.0.9", "source": "copyApp",
    "deviceinfo": "3371150V-9327", "platform": "3",
    "referer": "com.copymanga.app-3.0.9", "version": "3.0.9",
    "device": "EB0O.675141.548", "region": "0",
    "umstring": "b4c89ca4104ea9a97750314d791520ac",
    "x-auth-timestamp": ts, "x-auth-signature": sig,
}
for host in ["api.copy202601.com", "api.copy5000.com", "api.copy4000.com"]:
    try:
        r = requests.get(f"https://{host}/api/v3/system/network2?platform=3",
                         headers=h, proxies=PROXY, timeout=15)
        d = r.json().get("results") or {}
        print(f"  {host}: api={d.get('api')} share={d.get('share')}")
    except Exception as e:
        print(f"  {host}: ERR {type(e).__name__} {e}")

# ---------- 2. 候选网页域可达性 ----------
show("2. web hosts reachability")
web_hosts = ["www.copy5000.com", "www.copy4000.com", "www.copy20.com",
             "www.copy202601.com", "copy5000.com", "www.copymanga.app"]
ok_web = None
for wh in web_hosts:
    try:
        r = requests.get(f"https://{wh}/", headers={"User-Agent": UA},
                         proxies=PROXY, timeout=15, allow_redirects=True)
        has_nuxt = "__NUXT__" in r.text
        title_m = re.search(r"<title>(.*?)</title>", r.text, re.S)
        print(f"  {wh}: {r.status_code} final={r.url} nuxt={has_nuxt} "
              f"title={(title_m.group(1)[:40] if title_m else '')!r} len={len(r.text)}")
        if r.status_code == 200 and ok_web is None and len(r.text) > 30000 and "拷" in r.text:
            ok_web = wh
            save("home.html", r.text)
    except Exception as e:
        print(f"  {wh}: ERR {type(e).__name__} {str(e)[:80]}")
web = ok_web or "www.copy5000.com"
print(f"  >> using web host: {web}")

# ---------- 3. 首页 SSR 结构 ----------
show("3. home SSR structure")
home = open(os.path.join(OUT, "home.html"), encoding="utf-8").read()
# 漫画链接样例
slugs = re.findall(r"/comic/([A-Za-z0-9_\-]+)", home)
print("  /comic/ link uniq count:", len(set(slugs)),
      "sample:", list(dict.fromkeys(slugs))[:15])
# 分区线索
for kw in ["推荐", "热门", "最新", "完结", "排行", "rankDay", "recComics",
           "hotComics", "newComics", "finishComics", "comicList",
           "moduleData", "pageData", "updateList", "homeModule"]:
    print(f"  kw {kw!r}: {home.count(kw)}")
# 导航链接
navs = sorted(set(re.findall(r'href="(/[a-zA-Z0-9/_\-\?=&\.]*?)"', home)))
print("  nav links (<40 chars):", [n for n in navs if len(n) < 40][:60])
# 分区标题/section 结构
heads = re.findall(r'<(?:h2|h3|div)[^>]*class="[^"]*(?:title|module|section|part)[^"]*"[^>]*>(.{0,60})', home)
print("  section head nodes:", [re.sub(r'<[^>]+>', '', x).strip()[:20] for x in heads[:20]])
# 取第一个 comic 卡片上下文
i = home.find("/comic/" + (list(dict.fromkeys(slugs))[0] if slugs else ""))
print("\n  --- card context (first comic link, 1200 chars) ---")
print(home[max(0, i - 600):i + 600])

# ---------- 4. 搜索 ----------
show("4. searchci on web host")
try:
    r = requests.get(
        f"https://{web}/api/kb/web/searchci/comics?limit=10&offset=0&q=%E6%B5%B7%E8%B4%BC%E7%8E%8B&q_type=",
        headers={"User-Agent": UA, "Referer": f"https://{web}/search"},
        proxies=PROXY, timeout=20)
    print("  status:", r.status_code, "ct:", r.headers.get("content-type"))
    d = r.json()
    save("search.json", json.dumps(d, ensure_ascii=False)[:100000])
    res = d.get("results")
    print("  code:", d.get("code"), "results type:", type(res).__name__)
    if isinstance(res, dict):
        print("  results keys:", list(res.keys()))
        lst = res.get("list") or []
        print("  total:", res.get("total"), "list len:", len(lst))
        if lst:
            item = lst[0]
            comic = item.get("comic", item)
            print("  item keys:", list(item.keys()))
            print("  comic keys:", list(comic.keys())[:40])
            print("  sample:", json.dumps({k: comic.get(k) for k in
                  ["name", "path_word", "cover", "brief", "status", "datetime_updated"]},
                  ensure_ascii=False)[:600])
except Exception as e:
    print("  ERR", type(e).__name__, e)

# ---------- 5. 详情页 ----------
show("5. detail SSR page")
slug = None
try:
    sd = json.load(open(os.path.join(OUT, "search.json"), encoding="utf-8"))
    lst = sd["results"]["list"]
    for it in lst:
        c = it.get("comic", it)
        if c.get("name") == "海贼王" or "海賊王" in (c.get("name") or ""):
            slug = c.get("path_word"); break
    if not slug:
        slug = lst[0].get("comic", lst[0]).get("path_word")
except Exception as e:
    print("  pick slug ERR", e)
print("  slug:", slug)
if slug:
    r = requests.get(f"https://{web}/comic/{slug}",
                     headers={"User-Agent": UA}, proxies=PROXY, timeout=20)
    print("  status:", r.status_code, "len:", len(r.text))
    save("detail.html", r.text)
    html = r.text
    for pat in [r'id="dnt"\s+value="([^"]*)"',
                r"var\s+ccz\s*=\s*'([^']*)'",
                r"var\s+cct\s*=\s*'([^']*)'"]:
        mm = re.search(pat, html)
        print(f"  {pat[:30]} -> {mm.group(1) if mm else None}")
    chaps = re.findall(rf"/comic/{re.escape(slug)}/chapter/([0-9a-fA-F-]{{36}})", html)
    print("  chapter uuids found:", len(chaps), list(dict.fromkeys(chaps))[:5])
    # nuxt data keys
    m = re.search(r"window\.__NUXT__\s*=\s*(.+?);?\s*</script>", html, re.S)
    if m:
        raw = m.group(1)
        save("detail_nuxt.js", raw[:200000])
        print("  detail __NUXT__ len:", len(raw), "head 500:\n" + raw[:500])
    # 关键 SSR 字段直接搜
    for kw in ["comicName", "pathWord", "path_word", "brief", "authorList",
               "themeList", "comicStatus", "datetimeUpdated", "chapterList",
               "defaultChapter", "uuid", "name:"]:
        print(f"  kw {kw!r}: {html.count(kw)}")
    # 标题/作者等可见结构
    mm = re.search(r'<h1[^>]*>(.*?)</h1>', html, re.S)
    print("  h1:", (mm.group(1)[:120] if mm else None))

    # ---------- 6. 章节列表 AES 接口 ----------
    show("6. chapters endpoint")
    dnt = re.search(r'id="dnt"\s+value="([^"]*)"', html)
    dnt = dnt.group(1) if dnt else ""
    r2 = requests.get(f"https://{web}/comicdetail/{slug}/chapters",
                      headers={"User-Agent": UA, "Referer": f"https://{web}/comic/{slug}",
                               "dnts": dnt, "platform": "1"},
                      proxies=PROXY, timeout=20)
    print("  status:", r2.status_code)
    cd = r2.json()
    print("  code:", cd.get("code"), "results type:", type(cd.get("results")).__name__,
          "len:", len(cd.get("results") or ""))
    save("chapters_enc.json", json.dumps(cd)[:5000])
    print("  results head 120:", (cd.get("results") or "")[:120])
    # 尝试解密
    try:
        from Crypto.Cipher import AES
        from Crypto.Util.Padding import unpad
        key = re.search(r"var\s+ccz\s*=\s*'([^']*)'", html).group(1).encode()
        enc = cd["results"]
        iv = enc[:16].encode()
        ct = bytes.fromhex(enc[16:])
        pt = unpad(AES.new(key, AES.MODE_CBC, iv).decrypt(ct), 16)
        j = json.loads(pt.decode())
        save("chapters_dec.json", json.dumps(j, ensure_ascii=False)[:100000])
        print("  DECRYPTED. top keys:", list(j.keys()))
        b = j.get("build", {})
        g = j.get("groups", {}).get("default", {})
        print("  build keys:", list(b.keys())[:20])
        print("  group keys:", list(g.keys()), "chapters len:", len(g.get("chapters") or []))
        print("  build sample:", json.dumps(b, ensure_ascii=False)[:500])
    except ImportError:
        print("  pycryptodome NOT available in bundled python")
    except Exception as e:
        print("  decrypt ERR", type(e).__name__, e)

# ---------- 7. 分类/列表页 ----------
show("7. category pages")
for path in ["/genres", "/category", "/comics", "/index?theme=aiqing"]:
    try:
        r = requests.get(f"https://{web}{path}", headers={"User-Agent": UA},
                         proxies=PROXY, timeout=15)
        print(f"  {path}: {r.status_code} len={len(r.text)} nuxt={'__NUXT__' in r.text}")
        if r.status_code == 200 and len(r.text) > 3000:
            save("cat_" + path.strip("/").replace("?", "_").replace("=", "_") + ".html",
                 r.text[:150000])
    except Exception as e:
        print(f"  {path}: ERR {type(e).__name__} {str(e)[:60]}")

print("\nDONE")
