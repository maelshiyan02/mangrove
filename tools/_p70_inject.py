#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P70 反向验证：编号 key ↔ UUID key 的同一话归一，三组故障各自只红一条断言。

每组的故障点：
  * _cellNumberKey 只认 parseChapterTitle（不认「1 [copymanga]」）-> chapters.merge_dedupes_numbered_key_form
  * 磁盘目录反查只返回第一个 key                                  -> chapters.disk_dir_maps_to_all_equivalent_keys
  * 磁盘对账改回逐字 chapterDirectoryName                          -> chapters.equivalent_key_mapping_wired

合格标准（A02 §7）：① 目标变红；② 失败集合恰好等于目标；③ sha256 逐字节还原。
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
DIR = "Mangrove/lib/foundation/chapter_directory.dart"
LOCAL = "Mangrove/lib/foundation/local.dart"

CELL_NUMBER_OLD = (
    "String? _cellNumberKey(String bucketKey, ComicChapterVersion v) {\n"
    "  final n = chapterNumberKeyOf(v.chapterKey) ??\n"
    "      chapterNumberKeyOf(v.title) ??\n"
    "      chapterNumberKeyOf(bucketKey);\n"
    "  return n;\n"
    "}"
)
CELL_NUMBER_NEW = (
    "String? _cellNumberKey(String bucketKey, ComicChapterVersion v) {\n"
    "  final n = parseChapterTitle(v.chapterKey).chapterNumber ??\n"
    "      parseChapterTitle(v.title).chapterNumber ??\n"
    "      parseChapterTitle(bucketKey).chapterNumber; // INJECTED\n"
    "  return n?.toString();\n"
    "}"
)
KEYS_RETURN_OLD = (
    "  if (diskGroup.isEmpty) {\n"
    "    keys.addAll(byNumberNoGroup[disk.number] ?? const <String>[]);\n"
    "  }\n"
    "  return keys.toList();\n"
)
KEYS_RETURN_NEW = (
    "  if (diskGroup.isEmpty) {\n"
    "    keys.addAll(byNumberNoGroup[disk.number] ?? const <String>[]);\n"
    "  }\n"
    "  return keys.take(1).toList(); // INJECTED\n"
)
WIRE_OLD = "      final keys = chapterKeysForDirectoryName(chapters, name);\n"
WIRE_NEW = (
    "      final keys = <String>[chapterDirectoryName(chapters, name)]; // INJECTED\n"
)

CASES = [
    {
        "case": "cell_number_ignores_directory_style",
        "file": MODELS,
        "old": CELL_NUMBER_OLD,
        "new": CELL_NUMBER_NEW,
        "expect_red": {"chapters.merge_dedupes_numbered_key_form"},
        "why": "话号归一退回 parseChapterTitle，编号 key 与 UUID key 各占一格",
    },
    {
        "case": "disk_dir_returns_only_first_key",
        "file": DIR,
        "old": KEYS_RETURN_OLD,
        "new": KEYS_RETURN_NEW,
        "expect_red": {"chapters.disk_dir_maps_to_all_equivalent_keys"},
        "why": "目录只反查到一个 key，网络视图的 UUID key 永远不会被标已下载",
    },
    {
        "case": "reconcile_wired_back_to_exact_name",
        "file": LOCAL,
        "old": WIRE_OLD,
        "new": WIRE_NEW,
        "expect_red": {"chapters.equivalent_key_mapping_wired"},
        "why": "磁盘对账改回逐字目录名 ⇒ 69 个目录 unmapped，刷新反复误报新增",
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
    idx = -1
    for _ in range(n):
        idx = text.find(old, idx + 1)
        if idx < 0:
            return None
    return text[:idx] + new + text[idx + len(old):]


def main():
    only = [a for a in sys.argv[1:] if not a.startswith("-")]
    cases = [c for c in CASES if not only or c["case"] in only]
    if not cases:
        print("no such case: %s" % only)
        return 2

    data, base_red = run_check(os.path.join(OUT_DIR, "p70_inject_baseline.json"))
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
        path = os.path.join(ROOT, c["file"])
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
                os.path.join(OUT_DIR, "p70_inject_%s.json" % c["case"])
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
                "file": c["file"],
                "expect_red": sorted(c["expect_red"]),
                "actual_red": sorted(red),
                "restored": restored,
                "sha256": before,
            }
        )
        print(
            "%s %-34s expect=%s actual=%s restored=%s"
            % (verdict, c["case"], sorted(c["expect_red"]), sorted(red), restored)
        )

    out = os.path.join(OUT_DIR, "p70_fault_injection.json")
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
