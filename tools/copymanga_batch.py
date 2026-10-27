#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""分块批量下载拷贝漫画的整本（走 App 官方下载路径）。

## 为什么分块

`tools/run_headless_task.py` 等输出的上限是 **600 秒**，而整本 69 话要跑一个多
小时。所以按话号区间切成小块，一块一块跑：

* 每块单独起一次 headless 进程（App 自己的下载队列、源的风控退避都照常）；
* 下载任务**按页跳过已存在的文件** ⇒ 中断后重跑同一块就是续传；
* 某块失败不阻塞后面的块（最后统一报告缺口）。

用法：
    python -u tools/copymanga_batch.py --comic-id ngdgdhlhypj \
        --title-dir "那個大公的華麗婚姻騙局" --from 1 --to 69 --chunk 5
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNNER = os.path.join(REPO, "tools", "run_headless_task.py")
PY = sys.executable


def run_chunk(args, start, end, out_path):
    cmd = [
        PY,
        RUNNER,
        "download-check",
        args.comic_id,
        "--source",
        args.source,
        "--from",
        str(start),
        "--to",
        str(end),
        "--timeout",
        str(args.chunk_timeout),
        "--json",
        out_path,
    ]
    started = time.time()
    proc = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    text = proc.stdout + proc.stderr
    summary = {}
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("[CLI PRINT]"):
            try:
                payload = json.loads(line[len("[CLI PRINT]"):].strip())
            except ValueError:
                continue
            if payload.get("status") in ("success", "error"):
                summary = payload
    return {
        "range": [start, end],
        "status": summary.get("status", "unknown"),
        "message": summary.get("message", ""),
        "elapsed": round(time.time() - started, 1),
        "stdout_tail": text[-400:],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--comic-id", required=True)
    ap.add_argument("--title-dir", required=True)
    ap.add_argument("--source", default="copy_manga")
    ap.add_argument("--from", dest="start", type=int, default=1)
    ap.add_argument("--to", dest="end", type=int, default=9999)
    ap.add_argument("--chunk", type=int, default=5)
    ap.add_argument("--chunk-timeout", type=int, default=560)
    ap.add_argument("--json", default="")
    args = ap.parse_args()

    out_dir = os.path.join(REPO, "test-materials", "runs")
    os.makedirs(out_dir, exist_ok=True)
    results = []
    start = args.start
    while start <= args.end:
        end = min(start + args.chunk - 1, args.end)
        out_path = os.path.join(
            out_dir, "dl_%s_%d_%d.json" % (args.source, start, end)
        )
        result = run_chunk(args, start, end, out_path)
        results.append(result)
        print(
            "[chunk %d-%d] %s | %s | %.0fs"
            % (start, end, result["status"], result["message"][:120], result["elapsed"]),
            flush=True,
        )
        if result["status"] != "success":
            print("  失败，重试一次", flush=True)
            result = run_chunk(args, start, end, out_path)
            results[-1] = result
            print(
                "  重试结果：%s | %s"
                % (result["status"], result["message"][:120]),
                flush=True,
            )
        start = end + 1

    summary = {
        "comicId": args.comic_id,
        "titleDir": args.title_dir,
        "range": [args.start, args.end],
        "chunks": results,
        "ok": sum(1 for r in results if r["status"] == "success"),
        "total": len(results),
    }
    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(summary, fh, ensure_ascii=False, indent=1)
    print("chunks ok=%d/%d" % (summary["ok"], summary["total"]), flush=True)
    return 0 if summary["ok"] == summary["total"] else 1


if __name__ == "__main__":
    sys.exit(main())
