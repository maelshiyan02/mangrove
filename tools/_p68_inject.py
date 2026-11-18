#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P68 反向验证：五组故障，每组必须只红自己那条断言且源码逐字节还原。

链条三段各自下毒，缺一段都证明不了判据有效：
  * 源脚本 maxPage 退回 (total - total%20)/20 + 1 -> comments.maxpage_no_overestimate
    （运行时读 JS 文件，无需重建）
  * orderComments 退回定长列表                     -> comments.order_list_growable（需重建）
  * commentFallbackPage 永不回退                   -> comments.first_page_fallback（需重建）
  * commentNextPage 忽略 exhausted                 -> comments.exhausted_stops_paging（需重建）
  * 只摘掉「章末内嵌页」的回退循环（同文件另一类保持完好）
                                                  -> comments.paging_wired_in_all_pages
    （这一组专门证明断言是**逐类体**判定，不会因为同文件里另一个类接好了而喂绿）

合格标准（A02 §7）：① 目标变红；② 失败集合恰好等于目标；③ sha256 逐字节还原。
"""
import hashlib
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(ROOT, "builds", "mangrove", "mangrove.exe")
PY = r"C:\Users\Administrator\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
OUT_DIR = os.path.join(ROOT, "test-materials", "runs")
POLICY = "Mangrove/lib/foundation/comment_order_policy.dart"
DETAIL_COMMENTS = "Mangrove/lib/pages/comic_details_page/comments_page.dart"
READER_COMMENTS = "Mangrove/lib/pages/reader/chapter_comments.dart"
COPY_JS = "comic_source/copy_manga(5).js"

EMBEDDED_LOOP = (
    "      // P68：尾页可能空（源站 maxPage 高估一页）→ 逐页回退，别停在空列表。\n"
    "      var attempts = 0;\n"
    "      while (!res.error && res.data.isEmpty && target > 1) {\n"
    "        final back = commentFallbackPage(page: target, attempts: attempts);\n"
    "        if (back == null) break;\n"
    "        target = back;\n"
    "        attempts++;\n"
    "        res = await _load(target);\n"
    "      }\n"
)

CASES = [
    {
        "case": "source_maxpage_overestimate",
        "file": COPY_JS,
        # 运行时加载的是 data/comic_source 下的副本，两处都要注入，否则
        # copy.runtime_copy_in_sync 会跟着变红，失败集合就不再"恰好等于目标"。
        "also": ["data/comic_source/copy_manga(5).js"],
        "old": "maxPage: Math.max(1, Math.ceil(total / 20)),",
        "new": "maxPage: (total - (total % 20)) / 20 + 1, // INJECTED",
        "occurrence": 1,
        "expect_red": {"comments.maxpage_no_overestimate"},
        "needs_build": False,
        "why": "源站重新高估一页：40 条算出 3 页，尾页 offset=40 必空",
    },
    {
        "case": "order_list_fixed_length",
        "file": POLICY,
        "old": "  return indices.map((i) => comments[i]).toList();",
        "new": "  return indices.map((i) => comments[i]).toList(growable: false); // INJECTED",
        "occurrence": 1,
        "expect_red": {"comments.order_list_growable"},
        "needs_build": True,
        "why": "P65 原样：第二页 addAll 抛 fixed-length，异常在 setState 里 → 无限请求",
    },
    {
        "case": "fallback_never_steps_back",
        "file": POLICY,
        "old": ("  if (attempts >= kCommentPageFallbackLimit) return null;\n"
                "  return page > 1 ? page - 1 : null;"),
        "new": "  return null; // INJECTED",
        "occurrence": 1,
        "expect_red": {"comments.first_page_fallback"},
        "needs_build": True,
        "why": "尾页空了也不回退 → 首屏停在空列表 + 转圈（本次用户看到的症状）",
    },
    {
        "case": "exhausted_flag_ignored",
        "file": POLICY,
        "old": "  if (exhausted) return null;",
        "new": "  if (false) return null; // INJECTED",
        "occurrence": 1,
        "expect_red": {"comments.exhausted_stops_paging"},
        "needs_build": True,
        "why": "确认到头后仍继续请求：空 maxPage 场景会无限翻页",
    },
    {
        "case": "embedded_page_fallback_dropped",
        "file": READER_COMMENTS,
        "old": EMBEDDED_LOOP,
        "new": "      // INJECTED: 内嵌页漏接回退\n",
        "occurrence": 2,
        "expect_red": {"comments.paging_wired_in_all_pages"},
        "needs_build": False,
        "why": "只摘内嵌页（同文件独立页完好），证明逐类体判定不会假绿",
    },
]


def sha256(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def rebuild():
    proc = subprocess.run(
        [PY, os.path.join(ROOT, "tools", "run_build_task.py")],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=900,
    )
    if "BUILD_OK" not in proc.stdout:
        raise RuntimeError("BUILD_FAIL: %s" % proc.stdout[-600:])


def run_check(json_path):
    # 🔴 必须走 tools/run_headless_task.py：mangrove.exe 是 GUI 子系统，
    # main.cpp 里的 AttachConsole(ATTACH_PARENT_PROCESS) 会吞掉调用方的重定向，
    # 直接 subprocess 调用会得到「rc=1 且没有 json」的假象。
    if os.path.exists(json_path):
        os.remove(json_path)
    proc = subprocess.run(
        [
            PY,
            os.path.join(ROOT, "tools", "run_headless_task.py"),
            "reader-ux-check",
            "--json",
            json_path,
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=300,
    )
    if not os.path.exists(json_path):
        raise RuntimeError(
            "no json (rc=%s stdout=%r stderr=%r)"
            % (proc.returncode, proc.stdout[-400:], proc.stderr[:300])
        )
    with open(json_path, encoding="utf-8") as fp:
        data = json.load(fp)
    return data, {c["name"] for c in data["checks"] if not c["passed"]}


def replace_nth(text, old, new, n):
    """替换第 n 次（1-based）出现的 old；找不到返回 None。"""
    idx = -1
    for _ in range(n):
        idx = text.find(old, idx + 1)
        if idx < 0:
            return None
    return text[:idx] + new + text[idx + len(old):]


def main():
    data, base_red = run_check(os.path.join(OUT_DIR, "p68_inject_baseline.json"))
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
        targets = [c["file"]] + list(c.get("also", []))
        saved = []  # (abspath, original bytes, sha256)
        missed = None
        for rel in targets:
            path = os.path.join(ROOT, rel)
            original = open(path, "rb").read()
            before = sha256(path)
            text = original.decode("utf-8")
            nl = "\r\n" if "\r\n" in text else "\n"
            norm = text.replace("\r\n", "\n")
            injected_norm = replace_nth(
                norm, c["old"], c["new"], c.get("occurrence", 1)
            )
            if injected_norm is None:
                missed = rel
                break
            saved.append((path, original, before, nl, injected_norm))
        if missed is not None:
            print(
                "INJECT_MISS %s (%s nth=%d not found)"
                % (c["case"], missed, c.get("occurrence", 1))
            )
            ok_all = False
            summary.append({"case": c["case"], "verdict": "INJECT_MISS"})
            continue
        for path, _original, _before, nl, injected_norm in saved:
            open(path, "w", encoding="utf-8", newline="").write(
                injected_norm.replace("\n", nl)
            )
        try:
            if c["needs_build"]:
                rebuild()
            _, red = run_check(
                os.path.join(OUT_DIR, "p68_inject_%s.json" % c["case"])
            )
        finally:
            for path, original, _before, _nl, _inj in saved:
                open(path, "wb").write(original)
            if c["needs_build"]:
                rebuild()
        restored = all(sha256(p) == before for p, _o, before, _nl, _i in saved)
        only_target = red == c["expect_red"]
        verdict = "PASS" if (only_target and restored) else "FAIL"
        if verdict != "PASS":
            ok_all = False
        summary.append(
            {
                "case": c["case"],
                "verdict": verdict,
                "why": c["why"],
                "files": targets,
                "expect_red": sorted(c["expect_red"]),
                "actual_red": sorted(red),
                "restored": restored,
                "sha256": saved[0][2],
                "rebuilt": c["needs_build"],
            }
        )
        print(
            "%s %-32s expect=%s actual=%s restored=%s"
            % (verdict, c["case"], sorted(c["expect_red"]), sorted(red), restored)
        )

    out = os.path.join(OUT_DIR, "p68_fault_injection.json")
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
