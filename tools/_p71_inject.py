#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P71 反向验证：存量重复章节矩阵自愈，四组故障各自只红一条断言。

每组的故障点：
  * 去重后仍输出原始 138 格（只计算 remap，不落折叠结果）
        -> chapters.existing_duplicate_matrix_collapses
  * remapKeys 不查映射表（旧 UUID key 原样保留）
        -> chapters.downloaded_keys_remapped_on_dedupe
  * 去重身份退化成「只按话号」（同话不同翻译组被误折）
        -> chapters.dedupe_keeps_distinct_scanlation_groups
  * 存量迁移只在 init 跑、restoreFrom 不跑
        -> chapters.duplicate_migration_wired

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
LOCAL = "Mangrove/lib/foundation/local.dart"

EMIT_OLD = (
    "    final chapters = _emitCells(\n"
    "      keptByIdentity.values.toList(),\n"
)
EMIT_NEW = (
    "    final chapters = _emitCells(\n"
    "      cells, // INJECTED\n"
)
REMAP_OLD = "      final next = remap[key] ?? key;\n"
REMAP_NEW = "      final next = key; // INJECTED\n"
IDENTITY_OLD = (
    "      final identity =\n"
    "          _chapterMergeIdentity(cell.version, bucketKey: cell.bucketKey);\n"
)
IDENTITY_NEW = (
    "      final identity =\n"
    "          'n:${chapterNumberKeyOf(cell.version.chapterKey) ?? "
    "chapterNumberKeyOf(cell.version.title) ?? "
    "chapterNumberKeyOf(cell.bucketKey) ?? cell.bucketKey}'; // INJECTED\n"
)
RESTORE_OLD = (
    "    _ensureSchema();\n"
    "    _migrateDuplicateChapterKeys();\n"
    "    notifyListeners();\n"
)
RESTORE_NEW = (
    "    _ensureSchema();\n"
    "    notifyListeners(); // INJECTED\n"
)

CASES = [
    {
        "case": "dedupe_emits_unfolded",
        "file": MODELS,
        "old": EMIT_OLD,
        "new": EMIT_NEW,
        "expect_red": {"chapters.existing_duplicate_matrix_collapses"},
        "why": "只算了 remap 却仍把 138 格写回，列表翻倍与卡顿照旧",
    },
    {
        "case": "remap_keys_disabled",
        "file": MODELS,
        "old": REMAP_OLD,
        "new": REMAP_NEW,
        "expect_red": {"chapters.downloaded_keys_remapped_on_dedupe"},
        "why": "旧 UUID 下载 key 不改写，折叠后蓝标全丢",
    },
    {
        "case": "dedupe_ignores_scanlation_group",
        "file": MODELS,
        "old": IDENTITY_OLD,
        "new": IDENTITY_NEW,
        "expect_red": {"chapters.dedupe_keeps_distinct_scanlation_groups"},
        "why": "只按话号判等，同话两个翻译组被折成一个版本",
    },
    {
        "case": "migration_skips_restore",
        "file": LOCAL,
        "old": RESTORE_OLD,
        "new": RESTORE_NEW,
        "expect_red": {"chapters.duplicate_migration_wired"},
        "why": "恢复备份后不再自愈，138 格会重新回到列表",
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
        timeout=1200,
    )
    if "BUILD_OK" not in proc.stdout:
        raise RuntimeError("BUILD_FAIL: %s" % proc.stdout[-800:])


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
        timeout=600,
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

    data, base_red = run_check(os.path.join(OUT_DIR, "p71_inject_baseline.json"))
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
                os.path.join(OUT_DIR, "p71_inject_%s.json" % c["case"])
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

    out = os.path.join(OUT_DIR, "p71_fault_injection.json")
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
