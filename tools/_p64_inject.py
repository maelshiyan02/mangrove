#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P64 反向验证：对**源码文本**做故障注入，跑同一个 `reader-ux-check`，看对应断言是否变红。

为什么不用重新构建
------------------
`reader-ux-check` 里的接线类断言是**运行时读源码文本**（`_read(packageRoot, 'lib/...')`），
所以改源文件后直接跑现成 exe 就能验；只有"纯函数行为"类断言才需要重新编译
（那类由 `_pair` 的 broken_would_pass 反向口覆盖，见 headless_p56_checks.dart）。

判据
----
每个注入都必须满足两件事：
  1) 目标断言变红（否则这条断言是装饰品）；
  2) 失败集合 == {目标}（只红一条）。多红一条说明判据借了别人的取证面（P11.5 §0-15）。
注入后必须把文件逐字节还原，并校验 sha256 与注入前一致。
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
        "case": "no_pointer_focus_heal",
        "file": "Mangrove/lib/pages/reader/gesture.dart",
        "old": "        reader.ensureReaderFocus();\n",
        "new": "        // INJECTED: 指针不再恢复焦点\n",
        "expect_red": {"reader.focus_self_heal_wired"},
        "why": "指针按下时不再还焦点 —— 只走 FocusManager 一条路时就该报警",
    },
    {
        "case": "comments_always_chapter_one",
        "file": "Mangrove/lib/pages/reader/reader.dart",
        "old": "    final epId = chapters.ids.elementAt(chapter - 1);",
        "new": "    final epId = chapters.ids.elementAt(0); // INJECTED",
        "expect_red": {"reader.comments_uses_current_chapter"},
        "why": "把「当前话」写成「第 1 话」—— 阅读器里的评论就会串到别的章",
    },
    {
        "case": "toolbar_comment_back_to_placeholder",
        "file": "Mangrove/lib/pages/reader/side_toolbar.dart",
        "old": "        reader.openChapterComments,\n",
        "new": "        () => context.showMessage(message: \"Comments coming soon\"),\n",
        "expect_red": {"reader.comments_toolbar_wired"},
        "why": "评论按钮退回占位提示",
    },
    {
        "case": "focus_guard_bypassed",
        "file": "Mangrove/lib/pages/reader/reader.dart",
        "old": """    if (!shouldReaderRestoreFocus(
      routeIsCurrent: route == null || route.isCurrent,
      hasFocus: focusNode.hasFocus,
      editableFocused: _isEditableFocused(),
      primaryIsBareScope: primary == null || primary is FocusScopeNode,
    )) {
      return;
    }
""",
        "new": """    if (focusNode.hasFocus) return; // INJECTED: 退回裸守卫
""",
        "expect_red": {"reader.focus_guard_wired"},
        "why": "ensureReaderFocus 退回「只看自己有没有焦点」的裸守卫（不再走纯函数）",
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
        raise RuntimeError("check produced no json (rc=%s stderr=%r)"
                           % (proc.returncode, proc.stderr[:300]))
    with open(json_path, encoding="utf-8") as fp:
        data = json.load(fp)
    red = {c["name"] for c in data["checks"] if not c["passed"]}
    return data, red


def main():
    base_json = os.path.join(OUT_DIR, "p64_inject_baseline.json")
    data, base_red = run_check(base_json)
    print("baseline: passed=%s checks=%d red=%s"
          % (data["passed"], len(data["checks"]), sorted(base_red)))
    if base_red:
        print("BASELINE_NOT_GREEN -- 先修基线再谈注入")
        return 2

    ok_all = True
    summary = []
    for c in CASES:
        path = os.path.join(ROOT, c["file"])
        original = open(path, "rb").read()
        before = sha256(path)
        text = original.decode("utf-8")
        # 🔴 少踩的坑：这些 .dart 是 CRLF，样本串按 LF 写就永远匹配不上，
        #    而 replace 不报错、只是"没变化"，很容易被当成"注入没生效"。
        nl = "\r\n" if "\r\n" in text else "\n"
        norm = text.replace("\r\n", "\n")
        if c["old"] not in norm:
            print("INJECT_MISS %s: needle not found" % c["case"])
            ok_all = False
            summary.append({"case": c["case"], "verdict": "INJECT_MISS"})
            continue
        injected = norm.replace(c["old"], c["new"], 1).replace("\n", nl)
        open(path, "w", encoding="utf-8", newline="").write(injected)
        try:
            json_path = os.path.join(OUT_DIR, "p64_inject_%s.json" % c["case"])
            data2, red = run_check(json_path)
        finally:
            open(path, "wb").write(original)
        after = sha256(path)
        restored = after == before
        only_target = red == c["expect_red"]
        verdict = "PASS" if (only_target and restored) else "FAIL"
        if verdict != "PASS":
            ok_all = False
        summary.append({
            "case": c["case"],
            "verdict": verdict,
            "why": c["why"],
            "expect_red": sorted(c["expect_red"]),
            "actual_red": sorted(red),
            "restored": restored,
            "sha256": before,
        })
        print("%s %-32s expect=%s actual=%s restored=%s"
              % (verdict, c["case"], sorted(c["expect_red"]), sorted(red), restored))

    out = os.path.join(OUT_DIR, "p64_fault_injection.json")
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
