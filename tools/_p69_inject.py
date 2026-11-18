#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P69 反向验证：章节矩阵跨形态合并，五组故障各自只红一条断言。

每组的"断点在链路哪一段"：
  * 版本化本地记录跨形态时直接返回本地        -> chapters.cross_mode_merge_grows
  * 分组式本地记录跨形态时直接返回本地        -> chapters.cross_mode_keeps_local_shape
  * 并集只取源侧（丢掉本地）                  -> chapters.cross_mode_never_shrinks
  * 身份判定不再从标题读话号                  -> chapters.merge_identity_reads_title_number
  * toGrouped/toVersioned 不真转              -> chapters.mode_conversion_roundtrip

合格标准（A02 §7）：① 目标变红；② 失败集合恰好等于目标；③ sha256 逐字节还原。
全部 5 组都改 Dart 源码，需要各自重建一次（约 2–3 分钟/组）。
"""
import hashlib
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PY = r"C:\Users\Administrator\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
OUT_DIR = os.path.join(ROOT, "test-materials", "runs")
MODELS = "Mangrove/lib/foundation/comic_source/models.dart"

CROSS_MODE_ANCHOR = "    final mine = _canonicalCells();"

IDENTITY_OLD = (
    "  final num = parseChapterTitle(v.chapterKey).chapterNumber ??\n"
    "      parseChapterTitle(v.title).chapterNumber ??\n"
    "      (bucketKey == null ? null : parseChapterTitle(bucketKey).chapterNumber);"
)

TO_GROUPED_OLD = (
    "  ComicChapters toGrouped({String defaultGroup = '默認'}) =>\n"
    "      matrixMode == ChapterMatrixMode.grouped\n"
    "          ? this\n"
    "          : _emitCells(\n"
    "              _canonicalCells(),\n"
    "              ChapterMatrixMode.grouped,\n"
    "              defaultGroup: defaultGroup,\n"
    "            );"
)

CASES = [
    {
        "case": "cross_mode_versioned_bails",
        "old": CROSS_MODE_ANCHOR,
        "new": "    if (isVersioned) return this; // INJECTED\n" + CROSS_MODE_ANCHOR,
        "expect_red": {"chapters.cross_mode_merge_grows"},
        "why": "版本化本地记录遇分组式源直接 return this（P67 那条死路）",
    },
    {
        "case": "cross_mode_grouped_bails",
        "old": CROSS_MODE_ANCHOR,
        "new": "    if (isGrouped) return this; // INJECTED\n" + CROSS_MODE_ANCHOR,
        "expect_red": {"chapters.cross_mode_keeps_local_shape"},
        "why": "分组式本地记录遇版本化源直接 return this（反方向同样不可接受）",
    },
    {
        "case": "union_drops_local",
        # 注入点必须是「并集的底」，不能换成 `union = []`：那样会连带打红
        # grows / keeps_shape（本地侧被整段丢掉，只剩源侧真正新增的 5 格），
        # 也会打红 wiring（它读源码里的这行字面量）。把底换成源侧才是"只丢本地"。
        "old": CROSS_MODE_ANCHOR,
        "new": "    final mine = other._canonicalCells(); // INJECTED",
        "expect_red": {"chapters.cross_mode_never_shrinks"},
        "why": "并集以源侧为底 ⇒ 源比本地少时缩水（已下载 key 变孤儿）",
    },
    {
        "case": "identity_no_title_number",
        "old": IDENTITY_OLD,
        "new": (
            "  final num = parseChapterTitle(v.chapterKey).chapterNumber ??\n"
            "      (bucketKey == null\n"
            "          ? null\n"
            "          : parseChapterTitle(bucketKey).chapterNumber); // INJECTED"
        ),
        "expect_red": {"chapters.merge_identity_reads_title_number"},
        "why": "身份判定只看章节 key 的话号 ⇒ UUID 键与编号键各建一格（整本翻倍）",
    },
    {
        "case": "conversion_is_noop",
        "old": TO_GROUPED_OLD,
        "new": "  ComicChapters toGrouped({String defaultGroup = '默認'}) =>\n"
        "      this; // INJECTED",
        "expect_red": {"chapters.mode_conversion_roundtrip"},
        "why": "toGrouped 不真转 ⇒ 形态互转是空话（下游按分组渲染的地方拿不到组）",
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
    # 直接 subprocess 调用拿不到 stdout/json。
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
    # 可选：只跑指定组（改判据/换注入点后重跑单组，不必等 5 组全跑）。
    only = [a for a in sys.argv[1:] if not a.startswith("-")]
    cases = [c for c in CASES if not only or c["case"] in only]
    if not cases:
        print("no such case: %s" % only)
        return 2

    data, base_red = run_check(os.path.join(OUT_DIR, "p69_inject_baseline.json"))
    print(
        "baseline: passed=%s checks=%d red=%s"
        % (data["passed"], len(data["checks"]), sorted(base_red))
    )
    if base_red:
        print("BASELINE_NOT_GREEN")
        return 2

    ok_all = True
    summary = []
    for c in cases:
        path = os.path.join(ROOT, MODELS)
        original = open(path, "rb").read()
        before = sha256(path)
        text = original.decode("utf-8")
        nl = "\r\n" if "\r\n" in text else "\n"
        norm = text.replace("\r\n", "\n")
        injected = replace_nth(norm, c["old"], c["new"], c.get("occurrence", 1))
        if injected is None:
            print("INJECT_MISS %s" % c["case"])
            ok_all = False
            summary.append({"case": c["case"], "verdict": "INJECT_MISS"})
            continue
        open(path, "w", encoding="utf-8", newline="").write(
            injected.replace("\n", nl)
        )
        try:
            rebuild()
            _, red = run_check(
                os.path.join(OUT_DIR, "p69_inject_%s.json" % c["case"])
            )
        finally:
            open(path, "wb").write(original)
            rebuild()
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
                "file": MODELS,
                "expect_red": sorted(c["expect_red"]),
                "actual_red": sorted(red),
                "restored": restored,
                "sha256": before,
            }
        )
        print(
            "%s %-32s expect=%s actual=%s restored=%s"
            % (verdict, c["case"], sorted(c["expect_red"]), sorted(red), restored)
        )

    out = os.path.join(OUT_DIR, "p69_fault_injection.json")
    # 单组重跑时把结果并回上一版台账，避免"只跑了 1 组就写出一份残缺台账"。
    if only and os.path.exists(out):
        prev = json.load(open(out, encoding="utf-8"))
        by_case = {c["case"]: c for c in prev.get("cases", [])}
        for s in summary:
            by_case[s["case"]] = s
        summary = [by_case[c["case"]] for c in CASES if c["case"] in by_case]
        ok_all = all(s.get("verdict") == "PASS" for s in summary)
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
