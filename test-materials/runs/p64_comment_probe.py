"""P64 探针：验证拷贝漫画 App 端评论接口是否可达、是否真返回数据。

评论是**网页端关闭、只有手机 App 能看**的能力，所以只能用 App v3 接口 +
HMAC 签名请求头。本脚本复刻 copy_manga(5).js 的 headers 构造，取 comic 级
/api/v3/comments 与章节级 /api/v3/roasts 两个端点，打印状态码与条数。

用法：
  python p64_comment_probe.py <comic_uuid> <chapter_uuid> [more_chapter_uuid...]
不传参数时只跑搜索接口拿一个真实 comic uuid。
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.path.join(ROOT, "data", "comic_source", "copy_manga.data")
SECRET_B64 = "M2FmMDg1OTAzMTEwMzJlZmUwNjYwNTUwYTA1NjNhNTM="

PROXY = os.environ.get("P64_PROXY", "http://127.0.0.1:7890")


def load_state():
    with open(DATA, encoding="utf-8") as f:
        return json.load(f)


def build_headers(st):
    token = st.get("token") or ""
    auth = f"Token {token}" if token else "Token"
    ts = str(int(time.time()))
    sig = hmac.new(base64.b64decode(SECRET_B64), ts.encode("utf-8"), hashlib.sha256).hexdigest()
    now = time.localtime()
    return {
        "User-Agent": "COPY/3.0.9",
        "source": "copyApp",
        "deviceinfo": st.get("_deviceinfo", "3371150V-9327"),
        "dt": time.strftime("%Y.%m.%d", now),
        "platform": "3",
        "referer": "com.copymanga.app-3.0.9",
        "version": "3.0.9",
        "device": st.get("_device", "EB0O.675141.548"),
        "pseudoid": st.get("_pseudoid", ""),
        "Accept": "application/json",
        "region": st.get("region", "0"),
        "authorization": auth,
        "umstring": "b4c89ca4104ea9a97750314d791520ac",
        "x-auth-timestamp": ts,
        "x-auth-signature": sig,
    }


def get(url, headers, use_proxy=True):
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": PROXY, "https": PROXY}) if use_proxy
        else urllib.request.ProxyHandler({})
    )
    req = urllib.request.Request(url, headers=headers)
    t0 = time.time()
    try:
        with opener.open(req, timeout=25) as r:
            body = r.read().decode("utf-8", "replace")
            return r.status, body, time.time() - t0
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), time.time() - t0
    except Exception as e:  # noqa: BLE001
        return -1, repr(e), time.time() - t0


def show(label, status, body, cost):
    s = body[:260].replace("\n", " ")
    print(f"[{label}] status={status} {cost:.2f}s body={s}")
    return status


def summarize_comments(label, body):
    try:
        d = json.loads(body)
    except Exception:  # noqa: BLE001
        print(f"  {label}: 非 JSON")
        return
    res = d.get("results")
    if res is None:
        print(f"  {label}: results=null (软风控/未登录)")
        return
    lst = res.get("list") if isinstance(res, dict) else None
    total = res.get("total") if isinstance(res, dict) else None
    if lst is None:
        print(f"  {label}: results 无 list, keys={list(res.keys())[:8]}")
        return
    print(f"  {label}: total={total} 本页={len(lst)}")
    for c in lst[:3]:
        u = c.get("user_name")
        txt = (c.get("comment") or "")[:40].replace("\n", " ")
        print(f"    - {u}: {txt}")


def main():
    st = load_state()
    headers = build_headers(st)
    host = st.get("_api_host") or "api.copy202601.com"
    print(f"host={host} deviceinfo={headers['deviceinfo']} has_token={bool(st.get('token'))}")

    comic_uuid = sys.argv[1] if len(sys.argv) > 1 else None
    chapter_ids = sys.argv[2:]

    if not comic_uuid:
        url = f"https://{host}/api/v3/search/comic?limit=3&offset=0&q={urllib.parse.quote('大公')}&q_type="
        status, body, cost = get(url, headers)
        show("search", status, body, cost)
        if status == 200:
            try:
                for c in json.loads(body)["results"]["list"][:3]:
                    print("   comic:", c.get("name"), "path=", c.get("path_word"))
                    print("     keys:", [k for k in c.keys() if "uuid" in k or "id" in k])
            except Exception as e:  # noqa: BLE001
                print("   parse fail", e)
        return

    url = f"https://{host}/api/v3/comments?comic_id={comic_uuid}&limit=20&offset=0"
    status, body, cost = get(url, headers)
    show("comments(comic)", status, body, cost)
    if status == 200:
        summarize_comments("comic", body)

    for cid in chapter_ids:
        url = f"https://{host}/api/v3/roasts?chapter_id={cid}&limit=20&offset=0"
        status, body, cost = get(url, headers)
        show(f"roasts({cid[:8]})", status, body, cost)
        if status == 200:
            summarize_comments(cid[:8], body)


if __name__ == "__main__":
    main()
