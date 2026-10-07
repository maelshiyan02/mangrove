# -*- coding: utf-8 -*-
import quickjs, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
PRELUDE = r"""
var console={log(){},error(){},warn(){}};
var Network={get:()=>Promise.resolve({status:200,body:'{}'}),post:()=>Promise.resolve({status:200,body:'{}'})};
function HtmlDocument(){this.getElementById=()=>null;this.querySelector=()=>null;this.querySelectorAll=()=>[];}
var localStorage={getItem:()=>null,setItem:()=>{},removeItem:()=>{}};
class ComicSource{loadSetting(){return {};}setSetting(){}saveData(){}loadData(){return null;}deleteData(){}}
"""
ctx=quickjs.Context(); ctx.eval(PRELUDE)
s=open(r"C:\Users\Administrator\AppData\Roaming\io.github.kyosee\venera\comic_source\comick.js","r",encoding="utf-8").read()
ctx.eval(s)
print(ctx.eval(r"""
(function(){
  var src=new Comick();
  var cfg=src.onImageLoad('https://x/y.webp','c','e');
  return JSON.stringify({keys:Object.keys(cfg), hook:typeof cfg.onLoadFailed,
    headers:cfg.headers, method:cfg.method, url:cfg.url});
})()
"""))
print(ctx.eval(r"""
(function(){
  var src=new Comick();
  var cfg=src.onImageLoad('https://x/y.webp','c','e');
  var r=cfg.onLoadFailed();
  return JSON.stringify({keys:Object.keys(r), hook:typeof r.onLoadFailed, referer:r.headers.referer});
})()
"""))
print(ctx.eval(r"""
(function(){
  var src=new Comick();
  return typeof src.onThumbnailLoad;
})()
"""))
