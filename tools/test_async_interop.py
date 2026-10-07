# -*- coding: utf-8 -*-
import quickjs, sys, io, json
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

calls = []
def net_get(url, headers_json):
    calls.append(url)
    return json.dumps({"status": 200, "body": '{"ok":true,"echo":"%s"}' % url})

ctx = quickjs.Context()
ctx.add_callable("__get", net_get)
ctx.eval("""
var Network = { get: async (u,h) => JSON.parse(__get(u, JSON.stringify(h||{}))) };
globalThis.__out = null;
globalThis.__err = null;
(async () => {
    var r = await Network.get("http://x/1", {});
    var j = JSON.parse(r.body);
    var r2 = await Network.get("http://x/2", {});
    globalThis.__out = JSON.stringify(j) + "|" + r2.body;
})().catch(e => { globalThis.__err = String(e && e.stack || e); });
""")
for i in range(100):
    try:
        ctx.execute_pending_job()
    except IndexError:
        break
    except Exception as e:
        print("job err:", type(e).__name__, e); break
print("out:", ctx.eval("globalThis.__out"))
print("err:", ctx.eval("globalThis.__err"))
print("calls:", calls)
