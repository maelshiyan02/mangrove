# -*- coding: utf-8 -*-
# QuickJS 实测 comick.js：语法加载 + 钩子 referer 保持 + 重试 config 无钩子（让 429 走 App 退避）
import quickjs, re, sys, io, json
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

def load_source(path):
    s = open(path, "r", encoding="utf-8").read()
    s = re.sub(r"^\s*\d+→", "", s, flags=re.M)
    return s

PRELUDE = r"""
var __mocks = { gets: [], storage: {}, logs: [] };
var console = { log: function(){__mocks.logs.push(Array.prototype.slice.call(arguments).map(String).join(' '));},
                error: function(){__mocks.logs.push('ERR '+Array.prototype.slice.call(arguments).map(String).join(' '));},
                warn: function(){} };
var Network = { get: (u) => Promise.resolve({status:200, body:'{}'}),
                post: (u,d) => Promise.resolve({status:200, body:'{}'}) };
function HtmlDocument(){ this.getElementById=()=>null; this.querySelector=()=>null; this.querySelectorAll=()=>[]; this.title=''; }
var localStorage = { getItem:k=>__mocks.storage[k]??null, setItem:(k,v)=>{__mocks.storage[k]=String(v);}, removeItem:k=>{delete __mocks.storage[k];} };
class ComicSource {
  loadSetting(){ return {}; }
  setSetting(){}
  saveData(){}
  loadData(){ return null; }
  deleteData(){}
}
"""

PROBE = r"""
(function(){
  function scan(o, depth, seen){
    if(!o || depth>4 || seen.has(o)) return null;
    seen.add(o);
    if(typeof o.onImageLoad==='function') return o;
    for(var k in o){ try{ var v=o[k]; if(v && typeof v==='object'){ var r=scan(v, depth+1, seen); if(r) return r; } }catch(e){} }
    return null;
  }
  var src = null;
  try { src = new Comick(); } catch(e) { return JSON.stringify({error:'INSTANTIATE: '+e}); }
  var keys = Object.getOwnPropertyNames(Object.getPrototypeOf(src)).concat(Object.keys(src));
  var c = src.comic;
  var cfg = c.onImageLoad('https://cdn1.comicknew.pictures/x/y/01.webp','cid','eid');
  var retry=null, tretry=null, thumb=null;
  try { retry = cfg.onLoadFailed(); } catch(e) { retry = {__err:String(e)}; }
  try { thumb = c.onThumbnailLoad ? c.onThumbnailLoad('https://thumb/1.jpg') : null;
        if (thumb) tretry = thumb.onLoadFailed(); } catch(e) { tretry = {__err:String(e)}; }
  return JSON.stringify({
    dbg: {hasImg: typeof src.onImageLoad, hasThumb: typeof src.onThumbnailLoad,
          cfgType: typeof cfg, cfgKeys: cfg ? Object.keys(cfg) : null,
          hookType: cfg ? typeof cfg.onLoadFailed : null,
          spreadTest: (function(){var a={x:1,b:{y:2}};var b={...a,z:3};return b.x===1&&b.z===3&&b.b.y===2;})()},
    firstHasReferer: cfg.headers && cfg.headers.referer === 'https://comick.art/',
    firstMethod: cfg.method,
    firstUrl: cfg.url,
    retryHasReferer: retry.headers && retry.headers.referer === 'https://comick.art/',
    retryHasHook: (typeof retry.onLoadFailed)==='function',
    retryUrlOk: retry.url === cfg.url,
    thumbRetryHasReferer: tretry.headers && tretry.headers.referer === 'https://comick.art/',
    thumbRetryHasHook: (typeof tretry.onLoadFailed)==='function'
  });
})()
"""

fails = []
for path, label in [
    (r"C:\Users\Administrator\AppData\Roaming\io.github.kyosee\venera\comic_source\comick.js", "deployed"),
    (r"d:\Ballonstranslator_Windows\venera-configs-main\comick.js", "workcopy"),
]:
    ctx = quickjs.Context()
    ctx.eval(PRELUDE)
    try:
        ctx.eval(load_source(path))
        print(f"[{label}] loaded OK")
    except Exception as e:
        fails.append((label, "LOAD: " + str(e)))
        print(f"[{label}] LOAD FAIL: {e}")
        continue
    res = json.loads(ctx.eval(PROBE))
    print(f"[{label}] hooks: {res}")
    expect = {
        "firstHasReferer": True, "firstMethod": "GET",
        "retryHasReferer": True, "retryHasHook": False, "retryUrlOk": True,
        "thumbRetryHasReferer": True, "thumbRetryHasHook": False,
    }
    for k, v in expect.items():
        if res.get(k) != v:
            fails.append((label, f"{k}={res.get(k)}"))

print("\nRESULT:", "ALL PASS" if not fails else f"FAILS={fails}")
sys.exit(1 if fails else 0)
