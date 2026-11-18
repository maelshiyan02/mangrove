#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P65 反向验证：源码故障注入 → 跑同一个 reader-ux-check → 只有目标断言变红。

接线类断言是运行时读源码文本，所以注入后直接跑现成 exe 即可；纯函数行为类
（时间格式、排序方向、分页方向）由 _pair 的 broken_would_pass 反向口覆盖。

每个用例必须满足：① 目标变红；② 失败集合恰好等于目标；③ 文件 sha256 逐字节还原。
"""
import hashlib
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(ROOT, "builds", "mangrove", "mangrove.exe")
OUT_DIR = os.path.join(ROOT, "test-materials", "runs")

CASES = [
    {
        "case": "chapter_setter_no_notify",
        "file": "Mangrove/lib/pages/reader/reader.dart",
        "old": "    chapterRevision.value++;\n",
        "new": "    // INJECTED: 章号变了但不通知\n",
        "expect_red": {"reader.chapter_revision_subscription"},
        "why": "章号 setter 不再推进 revision —— 复现原来的右上角数字卡住",
    },
    {
        "case": "capsule_no_subscription",
        "file": "Mangrove/lib/pages/reader/chapter_capsule.dart",
        "old": "    return ValueListenableBuilder<int>(\n",
        "new": "    return Builder(\n",
        "expect_red": {"reader.chapter_revision_subscription"},
        "why": "胶囊退回「只靠父级 rebuild 碰运气」的写法",
    },
    {
        "case": "comments_default_newest",
        "file": "Mangrove/lib/pages/comic_details_page/comments_page.dart",
        "old": "  CommentOrder _order = CommentOrder.oldestFirst;",
        "new": "  CommentOrder _order = CommentOrder.newestFirst; // INJECTED",
        "expect_red": {"comments.both_pages_use_order_policy"},
        "why": "作品评论退回拷贝默认的「最新在前」",
    },
    {
        "case": "comments_order_label_missing",
        "file": "Mangrove/assets/translation.json",
        # 两个 locale 都有这个键，必须一起抹掉；只改一处另一处仍会喂绿断言。
        "old": '"Oldest first"',
        "new": '"INJECTED label"',
        "replace_all": True,
        "expect_red": {"comments.order_labels_localized"},
        "why": "缺翻译键时排序条会把英文原样露给用户",
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
        raise RuntimeError("no json (rc=%s stderr=%r)" % (proc.returncode, proc.stderr[:300]))
    with open(json_path, encoding="utf-8") as fp:
        data = json.load(fp)
    return data, {c["name"] for c in data["checks"] if not c["passed"]}


def main():
    data, base_red = run_check(os.path.join(OUT_DIR, "p65_inject_baseline.json"))
    print("baseline: passed=%s checks=%d red=%s"
          % (data["passed"], len(data["checks"]), sorted(base_red)))
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
        # 这些 .dart 是 CRLF：按 LF 写 needle 会静默不匹配。
        nl = "\r\n" if "\r\n" in text else "\n"
        norm = text.replace("\r\n", "\n")
        if c["old"] not in norm:
            print("INJECT_MISS %s" % c["case"])
            ok_all = False
            summary.append({"case": c["case"], "verdict": "INJECT_MISS"})
            continue
        count = -1 if c.get("replace_all") else 1
        injected = norm.replace(c["old"], c["new"], count).replace("\n", nl)
        open(path, "w", encoding="utf-8", newline="").write(injected)
        try:
            _, red = run_check(os.path.join(OUT_DIR, "p65_inject_%s.json" % c["case"]))
        finally:
            open(path, "wb").write(original)
        restored = sha256(path) == before
        only_target = red == c["expect_red"]
        verdict = "PASS" if (only_target and restored) else "FAIL"
        if verdict != "PASS":
            ok_all = False
        summary.append({
            "case": c["case"], "verdict": verdict, "why": c["why"],
            "expect_red": sorted(c["expect_red"]), "actual_red": sorted(red),
            "restored": restored, "sha256": before,
        })
        print("%s %-30s expect=%s actual=%s restored=%s"
              % (verdict, c["case"], sorted(c["expect_red"]), sorted(red), restored))

    out = os.path.join(OUT_DIR, "p65_fault_injection.json")
    with open(out, "w", encoding="utf-8") as fp:
        json.dump({"baseline_checks": len(data["checks"]),
                   "baseline_green": not base_red,
                   "cases": summary,
                   "overall": "PASS" if ok_all else "FAIL"},
                  fp, ensure_ascii=False, indent=2)
    print("overall:", "PASS" if ok_all else "FAIL", "->", out)
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
