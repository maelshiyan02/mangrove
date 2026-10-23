"""下载 Chrome for Testing（绿色版独立 Chrome）到 App 分发目录。

用途：Mangrove 的 comix.to 采集需要一个「随 App 分发的独立浏览器」，
不依赖目标机器是否安装了 Chrome / Edge。本脚本从 Google 官方 CfT 清单
拉取 Stable 通道 win64 的 chrome-win64.zip，解压到
`builds/mangrove/chrome-win64/`，与 mangrove.exe 同级。

用法：
    python tools/fetch_cft.py            # 默认落到 builds/mangrove/chrome-win64
    python tools/fetch_cft.py --force    # 已存在也重新下载

代理：自动读取 HTTP_PROXY / HTTPS_PROXY 环境变量（requests 默认 trust_env）。
"""

import argparse
import io
import os
import sys
import zipfile

import requests

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DEST = os.path.join(ROOT, "builds", "mangrove")
META_URL = (
    "https://googlechromelabs.github.io/chrome-for-testing/"
    "last-known-good-versions-with-downloads.json"
)


def resolve_version() -> str:
    resp = requests.get(META_URL, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    version = data["channels"]["Stable"]["version"]
    print(f"CfT Stable version: {version}")
    return version


def candidate_urls(version: str):
    # Google 官方存储在本机常被 SSL 干扰；优先国内镜像，最后回落官方。
    return [
        f"https://cdn.npmmirror.com/binaries/chrome-for-testing/{version}/win64/chrome-win64.zip",
        f"https://registry.npmmirror.com/-/binary/chrome-for-testing/{version}/win64/chrome-win64.zip",
        f"https://storage.googleapis.com/chrome-for-testing-public/{version}/win64/chrome-win64.zip",
    ]


def already_present(dest: str) -> bool:
    return os.path.isfile(os.path.join(dest, "chrome-win64", "chrome.exe"))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dest", default=DEFAULT_DEST)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    dest = os.path.abspath(args.dest)
    if already_present(dest) and not args.force:
        print(f"already present: {os.path.join(dest, 'chrome-win64', 'chrome.exe')}")
        return 0

    version = resolve_version()
    buf = None
    for url in candidate_urls(version):
        print(f"downloading: {url}")
        try:
            with requests.get(url, stream=True, timeout=180) as r:
                r.raise_for_status()
                total = int(r.headers.get("Content-Length", 0))
                cur = io.BytesIO()
                got = 0
                for chunk in r.iter_content(chunk_size=1024 * 512):
                    if not chunk:
                        continue
                    cur.write(chunk)
                    got += len(chunk)
                    if total:
                        pct = got * 100 // total
                        print(
                            f"\r  {got/1048576:.1f}/{total/1048576:.1f} MB ({pct}%)",
                            end="",
                        )
                print()
            if got > 10 * 1024 * 1024:
                buf = cur
                break
            print("  too small, try next mirror")
        except Exception as e:
            print(f"  failed: {e}")
    if buf is None:
        print("ERROR: all mirrors failed", file=sys.stderr)
        return 2

    os.makedirs(dest, exist_ok=True)
    with zipfile.ZipFile(buf) as zf:
        zf.extractall(dest)
    print(f"extracted to: {dest}")

    exe = os.path.join(dest, "chrome-win64", "chrome.exe")
    if not os.path.isfile(exe):
        print("ERROR: chrome.exe not found after extraction", file=sys.stderr)
        return 2
    print(f"OK: {exe}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
