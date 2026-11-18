#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P66 反向验证：只给「章末内嵌评论页」注入故障，证明逐类断言真能钉住它。

背景：修复前 `comments.both_pages_use_order_policy` 用整份文件 contains 判定 ——
同一个 chapter_comments.dart 里独立评论页接好了排序，内嵌页没接也照样 PASS
（假绿）。修复把断言改成逐类体取值，这里给内嵌页单独下毒：

  * 旧的文件级判据：独立页仍有 `_order = CommentOrder.oldestFirst`，仍会绿；
  * 新的逐类判据：内嵌类体被改坏 -> `comments.both_pages_use_order_policy` 必须红。

合格标准（A02 §7）：① 目标变红；② 失败集合恰好等于目标；③ sha256 逐字节还原。
"""
import hashlib
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(ROOT, "builds", "mangrove", "mangrove.exe")
OUT_DIR = os.path.join(ROOT, "test-materials", "runs")
TARGET_ASSERTION = "comments.both_pages_use_order_policy"

CASES = [
    {
        "case": "embedded_page_default_newest",
        "file": "Mangrove/lib/pages/reader/chapter_comments.dart",
        # 只命中内嵌页（带 P65-embedded 行尾标记），独立页那行不带标记，不受影响。
        "old": "CommentOrder _order = CommentOrder.oldestFirst; // P65-embedded",
        "new": "CommentOrder _order = CommentOrder.newestFirst; // P65-embedded INJECTED",
        "expect_red": {TARGET_ASSERTION},
        "why": "内嵌页默认退回拷贝的「最新在前」；旧文件级断言会被独立页喂绿，逐类断言必须红",
    },
    {
        "case": "embedded_page_no_order_bar",
        "file": "Mangrove/lib/pages/reader/chapter_comments.dart",
        # 内嵌 build() 里的 buildOrderBar() 调用紧跟着它的 _buildHeader()（独立页
        # 那处缩进/上下文不同，用更长锚点确保只改内嵌页）。
        "old": "            _buildHeader(),\n            buildOrderBar(),\n            Expanded(child: _buildBody()),",
        "new": "            _buildHeader(),\n            Expanded(child: _buildBody()),",
        "expect_red": {TARGET_ASSERTION},
        "why": "内嵌页去掉排序条；逐类断言必须红",
    },
]


def sha256(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def run_check(json_path):
    if os.path.exists(json_path):
        os.remove(json_path)
    proc = subprocess.run(
        [EXE, "--headless", "reader-ux-check", "--json", json_path],
        cwd=ROOT,
        capture_output=True,
        timeout=180,
    )
    if not os.path.exists(json_path):
        raise RuntimeError(
            "no json (rc=%s stderr=%r)" % (proc.returncode, proc.stderr[:300])
        )
    with open(json_path, encoding="utf-8") as fp:
        data = json.load(fp)
    return data, {c["name"] for c in data["checks"] if not c["passed"]}


def main():
    data, base_red = run_check(os.path.join(OUT_DIR, "p66_inject_baseline.json"))
    print(
        "baseline: passed=%s checks=%d red=%s"
        % (data["passed"], len(data["checks"]), sorted(base_red))
    )
    if base_red:
        print("BASELINE_NOT_GREEN")
        return 2

    ok_all = True
    summary = []
    for c in CASES:
        path = os.path.join(ROOT, c["file"])
        original = open(path, "rb").read()
        before = sha256(path)
        text = original.decode("utf-8")
        nl = "\r\n" if "\r\n" in text else "\n"
        norm = text.replace("\r\n", "\n")
        if norm.count(c["old"]) != 1:
            print("INJECT_MISS %s (count=%d)" % (c["case"], norm.count(c["old"])))
            ok_all = False
            summary.append({"case": c["case"], "verdict": "INJECT_MISS"})
            continue
        injected = norm.replace(c["old"], c["new"], 1).replace("\n", nl)
        open(path, "w", encoding="utf-8", newline="").write(injected)
        try:
            _, red = run_check(
                os.path.join(OUT_DIR, "p66_inject_%s.json" % c["case"])
            )
        finally:
            open(path, "wb").write(original)
        restored = sha256(path) == before
        only_target = red == c["expect_red"]
        verdict = "PASS" if (only_target and restored) else "FAIL"
        if verdict != "PASS":
            ok_all = False
        summary.append(
            {
                "case": c["case"],
                "verdict": verdict,
                "why": c["why"],
                "expect_red": sorted(c["expect_red"]),
                "actual_red": sorted(red),
                "restored": restored,
                "sha256": before,
            }
        )
        print(
            "%s %-30s expect=%s actual=%s restored=%s"
            % (verdict, c["case"], sorted(c["expect_red"]), sorted(red), restored)
        )

    out = os.path.join(OUT_DIR, "p66_fault_injection.json")
    with open(out, "w", encoding="utf-8") as fp:
        json.dump(
            {
                "baseline_checks": len(data["checks"]),
                "baseline_green": not base_red,
                "cases": summary,
                "overall": "PASS" if ok_all else "FAIL",
            },
            fp,
            ensure_ascii=False,
            indent=2,
        )
    print("overall:", "PASS" if ok_all else "FAIL", "->", out)
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
