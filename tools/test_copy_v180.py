# -*- coding: utf-8 -*-
"""v1.8.0 QuickJS 全链路实测: Network 由 Python 直连真实拷贝网站(经 Clash)"""
import sys, io, os, json, hmac, hashlib, base64, time, traceback
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
import quickjs, requests

SRC = r"d:\Ballonstranslator_Windows\venera-configs-main\copy_manga(6).js"
PROXY = {"http": "http://127.0.0.1:7890", "https": "http://127.0.0.1:7890"}
http = requests.Session()
http.proxies.update(PROXY)
# 站点慢, 放宽超时 (JS 侧等待)
http.request = http.request

def pump(ctx, cap=20000):
    for _ in range(cap):
        try:
            ctx.execute_pending_job()
        except IndexError:
            return
        except Exception as e:
            print("[job error]", type(e).__name__, str(e)[:200])
            return

def run_async(ctx, js_expr, tag):
    """执行返回 Promise 的表达式, 把结果/异常挂全局"""
    ctx.eval(f"""
    globalThis.__r = null; globalThis.__e = null;
    Promise.resolve({js_expr}).then(
        v => {{ globalThis.__r = JSON.stringify(v, (k,val) =>
            val instanceof Map ? Object.fromEntries(val) : val, 2); }},
        e => {{ globalThis.__e = String((e && e.message) || e); }}
    );""")
    pump(ctx)
    err = ctx.eval("globalThis.__e")
    out = ctx.eval("globalThis.__r")
    if err:
        print(f"\n### {tag}: ERROR -> {err[:500]}")
        return None
    return json.loads(out)

def make_ctx(channel_mode):
    store = {}
    settings = {"channel_mode": channel_mode}
    ctx = quickjs.Context()
    ctx.set_memory_limit(256 * 1024 * 1024)

    def net_get(url, hj):
        h = json.loads(hj)
        try:
            r = http.get(url, headers=h, timeout=40)
            return json.dumps({"status": r.status_code, "body": r.text})
        except Exception as e:
            # 抛 JS 异常: JS 调用约定里用特殊返回 0 + 消息
            return json.dumps({"status": 0, "error": "NETWORK:" + str(e)[:200]})

    def net_post(url, hj, body):
        h = json.loads(hj)
        try:
            r = http.post(url, headers=h, data=body, timeout=40)
            return json.dumps({"status": r.status_code, "body": r.text})
        except Exception as e:
            return json.dumps({"status": 0, "error": "NETWORK:" + str(e)[:200]})

    ctx.add_callable("__get", net_get)
    ctx.add_callable("__post", net_post)
    ctx.add_callable("__loadSetting", lambda k: settings.get(k))
    ctx.add_callable("__saveData", lambda k, v: store.__setitem__(k, v))
    ctx.add_callable("__loadData", lambda k: store.get(k))
    ctx.add_callable("__deleteData", lambda k: store.pop(k, None))
    ctx.add_callable("__log", lambda *a: print("  [js]", " ".join(str(x) for x in a)[:200]))
    ctx.add_callable("__hmac", lambda key_b64raw, msg, algo:
        hmac.new(key_b64raw.encode("latin-1"), msg.encode("latin-1"), hashlib.sha256).hexdigest())
    ctx.add_callable("__b64dec", lambda s: base64.b64decode(s).decode("latin-1"))
    ctx.add_callable("__b64enc", lambda s: base64.b64encode(s.encode("latin-1")).decode())
    ctx.add_callable("__utf8", lambda s: s)

    pre = r"""
    class ComicSource {
        loadSetting(k){ return __loadSetting(k); }
        saveData(k,v){ __saveData(k, v); }
        loadData(k){ var v=__loadData(k); return v===undefined?null:v; }
        deleteData(k){ __deleteData(k); }
    }
    var Convert = {
        hmacString: (key, msg, algo) => __hmac(key, msg, algo),
        decodeBase64: (s) => __b64dec(s),
        encodeBase64: (s) => __b64enc(s),
        encodeUtf8: (s) => __utf8(s)
    };
    var APP = { version: "1.10.0" };
    var console = { log: (...a) => __log(...a) };
    var localStorage = {
        _d:{}, getItem(k){return this._d[k]||null;},
        setItem(k,v){this._d[k]=String(v);}, removeItem(k){delete this._d[k];}
    };
    function setTimeout(fn, ms){ return 0; }   // 测试环境: 立即返回, 不执行等待
    var Network = {
        get: async (u,h) => {
            var r = JSON.parse(__get(u, JSON.stringify(h||{})));
            if (r.status === 0) throw new Error(r.error || "network error");
            return r;
        },
        post: async (u,h,d) => {
            var r = JSON.parse(__post(u, JSON.stringify(h||{}), d||""));
            if (r.status === 0) throw new Error(r.error || "network error");
            return r;
        }
    };
    """
    src = open(SRC, encoding="utf-8").read()
    ctx.eval(pre + src)
    return ctx

print("=" * 30, "环境A: 强制网页端 (channel=web)", "=" * 30)
ctx = make_ctx("web")
inst = ctx.eval("var src = new CopyManga(); src")

# 1. 搜索
r = run_async(ctx, 'src.search.load("海贼王", [""], 1)', "search")
if r:
    names = [c["title"] for c in r["comics"]][:5]
    print(f"[1] search OK: {r['maxPage']} 页, 前5: {names}")
    assert any("海贼" in n for n in names), "未搜到海贼王"
    assert r["comics"][0]["cover"].startswith("http")

# 2. 分类-排行
r = run_async(ctx, 'src.categoryComics.load("排行","ranking",["1","day"],1)', "rank")
if r:
    print(f"[2] rank OK: {len(r['comics'])} 本, 榜首: {r['comics'][0]['title']} "
          f"封面={'有' if r['comics'][0]['cover'] else '无'}")
    assert len(r["comics"]) == 50

# 3. 分类-题材翻页
r1 = run_async(ctx, 'src.categoryComics.load("冒險","maoxian",["-全部","-datetime_updated"],1)', "theme1")
r2 = run_async(ctx, 'src.categoryComics.load("冒險","maoxian",["-全部","-datetime_updated"],2)', "theme2")
if r1 and r2:
    ids1 = {c["id"] for c in r1["comics"]}; ids2 = {c["id"] for c in r2["comics"]}
    print(f"[3] theme OK: p1={len(r1['comics'])} max={r1['maxPage']} "
          f"p2={len(r2['comics'])} 两页重叠={len(ids1 & ids2)}")
    assert len(r1["comics"]) == 50 and len(ids1 & ids2) <= 1

# 4. 探索页
r = run_async(ctx, 'src.explore[0].load()', "explore")
if r:
    print(f"[4] explore OK: 分区={list(r.keys())}")
    for k, v in list(r.items())[:3]:
        print(f"    {k}: {len(v)} 本, 首={v[0]['title']} 封面={'有' if v[0]['cover'] else '无'}")
    assert len(r) >= 5

# 5. 详情+章节
r = run_async(ctx, 'src.comic.loadInfo("haizeiwang")', "loadInfo")
if r:
    print(f"[5] detail OK: {r['title']} 作者={r['tags']['作者']} "
          f"状态={r['tags']['状态']} 分组数={len(r['chapters'])}")
    g0 = r["chapters"][list(r["chapters"])[0]]
    print(f"    章节数={len(g0)}, 首={list(g0.items())[0]}, 末={list(g0.items())[-1]}")
    assert r["title"] == "海贼王"
    assert len(g0) >= 390
    ep_uuid = list(g0)[0]
    ep_name = g0[ep_uuid]
else:
    ep_uuid = None

# 6. 阅读器
if ep_uuid:
    r = run_async(ctx, f'src.comic.loadEp("haizeiwang","{ep_uuid}")', "loadEp")
    if r:
        imgs = r["images"]
        print(f"[6] loadEp OK: {ep_name} -> {len(imgs)} 张, 首={imgs[0][-60:]}")
        assert len(imgs) > 100 and imgs[0].startswith("http")

# 7. 图片钩子
h = ctx.eval("""
    (function(){
        var c = src.comic.onImageLoad('https://sl.mangafunb.fun/x.jpg','a','b');
        var r = c.onLoadFailed();
        return JSON.stringify({ref:c.headers.Referer, ua:!!c.headers['User-Agent'],
            retryRef:r.headers.Referer, retryHook:typeof r.onLoadFailed});
    })()
""")
print("[7] onImageLoad:", h)

print("\n" + "=" * 30, "环境B: 自动通道 (真实软封禁 -> 应自动转网页端)", "=" * 30)
ctx2 = make_ctx("auto")
ctx2.eval("var src2 = new CopyManga();")
t0 = time.time()
r = run_async(ctx2, 'src2.search.load("哥布林", [""], 1)', "auto-search")
if r:
    print(f"[8] auto search OK ({time.time()-t0:.0f}s): {len(r['comics'])} 本, "
          f"前3: {[c['title'] for c in r['comics'][:3]]}")
    print("    appDead 标记:", ctx2.eval("String(src2._appDead)"))
    assert len(r["comics"]) > 0

# 9. 强制标记 App 死亡 -> auto 必须走网页端
r = run_async(ctx2, 'src2.markAppDead(); src2.search.load("哥布林", [""], 1)', "forced-web")
if r:
    print(f"[9] forced-web OK: {len(r['comics'])} 本 (经网页通道)")
    assert len(r["comics"]) == 30

# 10. 坏网页镜像(530) -> 自动故障转移到存活镜像
r = run_async(ctx, 'src._webHost="www.copy202601.com"; src.webSearch("海贼王",[""],1)', "web-failover")
if r:
    print(f"[10] web-failover OK: 当前host={ctx.eval('src.webBase')}, "
          f"{len(r['comics'])} 本")
    assert "copy5000" in ctx.eval("src.webBase")

# 11. init() 含动态题材表刷新
r = run_async(ctx, 'src.init(); "ok"', "init")
cat = ctx.eval("JSON.stringify(src.category.map(x=>x.title))")
print(f"[11] init OK: 分类={cat}")
assert "冒險" in cat

print("\n全部场景执行完毕")
