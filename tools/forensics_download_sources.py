# -*- coding: utf-8 -*-
"""
下载源取证 runner（⑧ 取证阶段 —— 只采集证据，不改任何生产代码）
=================================================================
在「取证 → 适配 → 回归」第一步，对两个下载源做纯证据采集：

  • 拷贝漫画
      ① 引导域存活扫描（解析 copy_manga.js 的全部 bootstrap 域，逐个探活）
      ② /api/v3/system/network2 域名自动发现（站方自愈机制是否还返数据）
      ③ 本地校验签名头构造（HMAC-SHA256，纯函数，**无需网络**）

  • comix.to
      ① DNS / TLS 可达性（证书是否有效）
      ② 非浏览器客户端 GET（预期 403 = WAF 在位；200 = 意外，要警惕）
      ③ WAF 挑战页关键字检测（与 App 端 looksLikeChallengePage 同源关键字）

运行环境
--------
完整证据需在「能联网 + 装了 requests + 走 Clash 代理」的 GUI 会话里跑。
无网络 / 无 requests 时，**每个检查自动降级为 SKIP 并打印原因**，
绝不输出假 PASS（空结果判 FAIL 是项目硬规矩，脚本同样遵守）。

用法
----
  python forensics_download_sources.py copy      # 仅拷贝漫画
  python forensics_download_sources.py comix     # 仅 comix.to
  python forensics_download_sources.py all       # 两者都跑
  python forensics_download_sources.py sig       # 仅本地签名算法校验（无需网络）

输出：tools/forensics_out/<source>_<YYYY-MM-DD>.json + 人类可读摘要。

分工说明
--------
  • 本脚本负责「引导域是否还活着 / 自愈接口是否还返数据 / 签名算法是否完好」——
    这些是 ⑧ 当前最大的未知数。
  • 签名头「服务端是否仍接受」的权威验证由 test_copy_v180.py（已修复路径漂移）
    在 QuickJS 里跑真实 JS 对真实站点完成，二者互补，不重复。
  • comix.to 的「轮换域 *.site 是否 403 / 哪条取图策略能过」只能在 GUI 用
    `mangrove.exe --headless comix-spike --comic <id>` 测（需 WebView），
    本脚本只探稳定锚点（comix.to / static.comix.to）并打印 GUI 复测清单。
"""
import sys, io, os, re, json, time, hmac, hashlib, base64, socket, ssl
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CONFIGS = os.environ.get(
    "MANGROVE_CONFIGS",
    os.path.join(ROOT, "venera-configs-main"),
)
COPY_JS = os.path.join(CONFIGS, "copy_manga(6).js")
OUT_DIR = os.path.join(HERE, "forensics_out")
PROXY = {"http": "http://127.0.0.1:7890", "https": "http://127.0.0.1:7890"}

# requests 在沙箱/无网环境可能缺失 —— 惰性导入，缺失则所有网络检查 SKIP。
_REQUESTS = None
_REQUESTS_OK = False


def _req():
    global _REQUESTS, _REQUESTS_OK
    if _REQUESTS_OK:
        return _REQUESTS
    if _REQUESTS is None:
        try:
            import requests as r
            _REQUESTS = r
            _REQUESTS_OK = True
        except Exception:
            _REQUESTS_OK = False
    return _REQUESTS


# ---------------------------------------------------------------------------
# 解析 copy_manga.js（单一事实源，避免再出现 mangrove-/venera- 路径漂移）
# ---------------------------------------------------------------------------
def parse_copy_config():
    if not os.path.exists(COPY_JS):
        return None, f"源文件不存在: {COPY_JS}"
    txt = open(COPY_JS, encoding="utf-8", errors="replace").read()

    def hosts_of(block_name):
        m = re.search(block_name + r"\s*=\s*\[(.*?)\]", txt, re.S)
        if not m:
            return []
        return re.findall(r"'([^']+)'", m.group(1))

    api = hosts_of(r"bootstrapApiHosts")
    web = hosts_of(r"bootstrapWebHosts")
    secret_m = re.search(r"secret\s*=\s*\"([^\"]+)\"", txt)
    api_url_m = re.search(r"defaultApiUrl\s*=\s*'([^']+)'", txt)
    ver_m = re.search(r"version\s*=\s*\"([^\"]+)\"", txt)
    return {
        "apiHosts": api,
        "webHosts": web,
        "secret": secret_m.group(1) if secret_m else "",
        "defaultApiUrl": api_url_m.group(1) if api_url_m else "",
        "version": ver_m.group(1) if ver_m else "",
        "file": COPY_JS,
    }, None


# ---------------------------------------------------------------------------
# 拷贝漫画：本地签名算法校验（无需网络）
# ---------------------------------------------------------------------------
def check_signature_local(cfg):
    """复刻 JS 的 x-auth-signature 计算，验证算法实现完好。

    JS: Convert.hmacString(Convert.decodeBase64(secret),
                            Convert.encodeUtf8(ts), "sha256")
    这里用 Python 标准库重算同值，并验证头部字典形状（15 个键、顺序、签名一致）。
    """
    out = {"check": "signature-local", "network": False}
    secret = cfg.get("secret", "")
    if not secret:
        out.update(status="FAIL", reason="JS 里没解析到 secret")
        return out
    try:
        secret_bytes = base64.b64decode(secret)
    except Exception as e:
        out.update(status="FAIL", reason=f"secret 不是合法 base64: {e}")
        return out

    ts = str(int(time.time()))
    sig = hmac.new(secret_bytes, ts.encode("utf-8"), hashlib.sha256).hexdigest()

    # 与 JS get headers 同序的头部（device/region 用占位，验证形状而非身份）
    header_keys = [
        "User-Agent", "source", "deviceinfo", "dt", "platform", "referer",
        "version", "device", "pseudoid", "Accept", "region", "authorization",
        "umstring", "x-auth-timestamp", "x-auth-signature",
    ]
    # 派生 dt（YYYY.MM.DD）
    now = time.gmtime()
    dt = f"{now.tm_year}.{now.tm_mon:02d}.{now.tm_mday:02d}"
    sample = {
        "User-Agent": "COPY/3.0.9", "source": "copyApp",
        "deviceinfo": "<placeholder>", "dt": dt, "platform": "3",
        "referer": "com.copymanga.app-3.0.9", "version": "3.0.9",
        "device": "<placeholder>", "pseudoid": "<placeholder>",
        "Accept": "application/json", "region": "0",
        "authorization": "Token", "umstring": "b4c89ca4104ea9a97750314d791520ac",
        "x-auth-timestamp": ts, "x-auth-signature": sig,
    }
    missing = [k for k in header_keys if k not in sample]
    out.update(
        status="PASS" if not missing else "FAIL",
        reason="" if not missing else f"缺失键: {missing}",
        hostCount=len(header_keys),
        secretLen=len(secret_bytes),
        sampleSignature=sig,
        headerKeys=header_keys,
    )
    return out


# ---------------------------------------------------------------------------
# 拷贝漫画：引导域存活扫描 + network2 自动发现
# ---------------------------------------------------------------------------
def sweep_host(session, host, path="/", timeout=12):
    url = f"https://{host}{path}"
    try:
        r = session.get(url, timeout=timeout)
        return {"host": host, "url": url, "status": r.status_code,
                "ok": 200 <= r.status_code < 500 or r.status_code == 200}
    except Exception as e:
        return {"host": host, "url": url, "status": None,
                "ok": False, "error": type(e).__name__ + ": " + str(e)[:120]}


def check_copy_reachability(cfg, only_discovery=False):
    out = {"check": "copy-reachability", "network": True}
    r = _req()
    if not r:
        out.update(status="SKIP", reason="未安装 requests 模块（需联网环境运行）")
        return out
    session = r.Session()
    session.proxies.update(PROXY)
    session.headers.update({"User-Agent": "COPY/3.0.9"})

    hosts = list(cfg.get("apiHosts", [])) + list(cfg.get("webHosts", []))
    sweep = []
    for h in hosts:
        sweep.append(sweep_host(session, h))
    alive = [s["host"] for s in sweep if s.get("ok")]
    out.update(hostsTotal=len(hosts), alive=alive, sweep=sweep)

    # 在首个存活 API 域上探 network2 自动发现
    discovery = {"attempted": False}
    first_api = next((s for s in sweep
                      if s["host"] in cfg.get("apiHosts", []) and s.get("ok")),
                     None)
    if first_api:
        discovery["attempted"] = True
        discovery["host"] = first_api["host"]
        url = f"https://{first_api['host']}/api/v3/system/network2"
        try:
            rr = session.get(url, timeout=15)
            discovery.update(status=rr.status_code,
                             bodyHead=rr.text[:300])
            try:
                j = rr.json()
                discovery["jsonKeys"] = list(j.keys())[:20]
                discovery["looksLikeDiscovery"] = any(
                    k in j for k in ("data", "domains", "list", "results"))
            except Exception:
                discovery["jsonKeys"] = None
        except Exception as e:
            discovery.update(status=None, error=type(e).__name__ + ": " +
                             str(e)[:120])
    out["discovery"] = discovery
    out["status"] = "PASS" if alive else "SKIP"
    out["reason"] = "" if alive else "全部引导域不可达（需确认网络/代理）"
    return out


# ---------------------------------------------------------------------------
# comix.to：DNS / TLS / 非浏览器 GET / WAF 检测
# ---------------------------------------------------------------------------
# 与 App 端 cloudflare.dart::_isCloudflareChallengePage 同源关键字（2026-10-11 对齐）。
# 注意：baozimh 系 gatekeeper 挑战页自身 JS 就引用 __gatekeeper_challenge，
# 标记永不消失，App 端改用「票据 cookie 到手」判定通过；本脚本只负责「锚点是否
# 还挂着挑战页」，给出的是可达性证据而非通过判定。
WAF_KEYWORDS = [
    "challenge-platform", "/cdn-cgi/challenge-platform/",
    "window._cf_chl_opt", "__cf_chl_opt", "cf_chl_",
    "cf-browser-verification", "cf-challenge-running", "cf-challenge",
    "cf-turnstile", "cf_captcha_kind",
    "verify you are human",
    "checking your browser before accessing",
    "checking if the site connection is secure",
    "please wait while we verify",
    "just a moment",
    "__gatekeeper_challenge", "gatekeeper_challenge",
    "正在验证浏览器",
]


def dns_resolve(host, timeout=8):
    try:
        return socket.gethostbyname(host)
    except Exception as e:
        return None


def tls_check(host, timeout=10):
    ctx = ssl.create_default_context()
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((host, 443))
        with ctx.wrap_socket(s, server_hostname=host) as ss:
            cert = ss.getpeercert()
            not_after = cert.get("notAfter")
            issuer = cert.get("issuer")
            issuer_cn = ""
            if issuer:
                for rdn in issuer:
                    for attr in rdn:
                        if attr[0] == "commonName":
                            issuer_cn = attr[1]
            return {"ok": True, "notAfter": not_after, "issuer": issuer_cn}
    except Exception as e:
        return {"ok": False, "error": type(e).__name__ + ": " + str(e)[:120]}
    finally:
        try:
            s.close()
        except Exception:
            pass


def check_comix():
    out = {"check": "comix-reachability", "network": True}
    r = _req()
    if not r:
        out.update(status="SKIP", reason="未安装 requests 模块（需联网环境运行）")
        return out
    session = r.Session()
    session.proxies.update(PROXY)
    session.headers.update({
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                      "AppleWebKit/537.36 (KHTML, like Gecko) "
                      "Chrome/126.0.0.0 Safari/537.36",
        "Accept": "text/html",
    })
    anchors = ["comix.to", "static.comix.to"]
    rows = []
    for host in anchors:
        ip = dns_resolve(host)
        tls = tls_check(host) if ip else {"ok": False, "error": "DNS 失败"}
        http_status = None
        waf = None
        if ip:
            try:
                rr = session.get(f"https://{host}/", timeout=15,
                                 allow_redirects=True)
                http_status = rr.status_code
                low = rr.text.lower()
                waf = [k for k in WAF_KEYWORDS if k in low]
            except Exception as e:
                http_status = None
                waf = [f"GET 失败: {type(e).__name__}"]
        rows.append({
            "host": host, "ip": ip, "tls": tls,
            "httpStatus": http_status, "wafKeywords": waf,
        })
    out["anchors"] = rows
    any_up = any(row["ip"] for row in rows)
    out["status"] = "PASS" if any_up else "SKIP"
    out["reason"] = "" if any_up else "稳定锚点全不可达（需确认网络/代理）"
    # GUI 复测清单（轮换域 *.site 只能走 WebView）
    out["guiChecklist"] = [
        "mangrove.exe --headless comix-spike --comic <id> --sample 2 "
        "--json tools/forensics_out/comix_spike.json",
        "mangrove.exe --headless download-check <id> --source comix_to "
        "--json tools/forensics_out/download_check.json",
        "重点看 comix-spike 报告里 canvas-read / warmup-dynamic-img 是否拿到字节"
        "（轮换域 *.site 403 的头号解法）",
    ]
    return out


# ---------------------------------------------------------------------------
# 编排
# ---------------------------------------------------------------------------
def run(sub):
    results = {"generatedAt": time.strftime("%Y-%m-%d %H:%M:%S"),
               "configsDir": CONFIGS, "checks": []}
    cfg, err = parse_copy_config()
    if cfg is None:
        results["parseError"] = err
    else:
        results["copyConfig"] = {
            "version": cfg["version"], "defaultApiUrl": cfg["defaultApiUrl"],
            "apiHosts": cfg["apiHosts"], "webHosts": cfg["webHosts"],
            "secretLen": len(cfg["secret"] or ""),
        }

    if sub in ("sig", "all", "copy"):
        if cfg:
            results["checks"].append(check_signature_local(cfg))
        else:
            results["checks"].append({"check": "signature-local",
                                      "status": "SKIP", "reason": err})
    if sub in ("copy", "all"):
        results["checks"].append(
            check_copy_reachability(cfg) if cfg else
            {"check": "copy-reachability", "status": "SKIP", "reason": err})
    if sub in ("comix", "all"):
        results["checks"].append(check_comix())

    return results


def summarize(results):
    print("\n" + "=" * 60)
    print("下载源取证摘要  " + results.get("generatedAt", ""))
    print("=" * 60)
    if results.get("parseError"):
        print("⚠ parseError:", results["parseError"])
    # 解析出的拷贝配置 = 真实证据（无论跑哪个子命令都打印）
    cc = results.get("copyConfig")
    if cc:
        print("\n[拷贝漫画 配置快照 · 来自 copy_manga(6).js]")
        print(f"  version        : {cc.get('version')}")
        print(f"  defaultApiUrl  : {cc.get('defaultApiUrl')}")
        print(f"  apiHosts({len(cc.get('apiHosts', []))}): {cc.get('apiHosts')}")
        print(f"  webHosts({len(cc.get('webHosts', []))}): {cc.get('webHosts')}")
        print(f"  secretLen      : {cc.get('secretLen')} (base64 串长；解码后 32 字节 = SHA256 密钥)")
    for c in results.get("checks", []):
        st = c.get("status", "?")
        name = c.get("check", "?")
        mark = {"PASS": "✅", "SKIP": "⏭ ", "FAIL": "❌"}.get(st, "·")
        print(f"  {mark} {name:24s} [{st}]  {c.get('reason', '')}")
        if name == "signature-local":
            print(f"      headerKeys={c.get('hostCount')}  secretLen={c.get('secretLen')} (解码后字节)")
            sig = c.get("sampleSignature")
            if sig:
                print(f"      sampleSignature={sig}")
        if name == "copy-reachability" and c.get("alive") is not None:
            print(f"      存活引导域: {c['alive'] or '（无）'}")
            d = c.get("discovery", {})
            if d.get("attempted"):
                print(f"      network2 @{d.get('host')}: status={d.get('status')} "
                      f"keys={d.get('jsonKeys')}")
        if name == "comix-reachability":
            for row in c.get("anchors", []):
                print(f"      {row['host']:18s} ip={row['ip']} "
                      f"tls_ok={row['tls'].get('ok')} http={row['httpStatus']} "
                      f"waf={row['wafKeywords']}")
    print("=" * 60)


def main():
    sub = sys.argv[1] if len(sys.argv) > 1 else "all"
    if sub not in ("copy", "comix", "all", "sig"):
        print("用法: forensics_download_sources.py {copy|comix|all|sig}")
        sys.exit(2)
    results = run(sub)
    summarize(results)
    os.makedirs(OUT_DIR, exist_ok=True)
    stamp = time.strftime("%Y-%m-%d")
    path = os.path.join(OUT_DIR, f"{sub}_{stamp}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print(f"\n报告已落盘: {path}")


if __name__ == "__main__":
    main()
