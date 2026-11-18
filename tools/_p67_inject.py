#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P67 反向验证：四组故障，每组必须只红自己那条断言且源码逐字节还原。

前三组只改详情页源码接线（断言在运行时读源码，无需重建）：
  * 摘掉本地视图的 subId 接线         -> local.comments_subid_from_online
  * 摘掉 loadData 的缓存回填调度       -> local.cache_chapter_enrich
  * 摘掉 _composeDetails 的缓存视图兜底 -> local.cached_view_first_frame
第四组改纯策略函数体（编译进 app.so，必须重建）：
  * commentsSubId 永远返回 null        -> local.comments_subid_from_online

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
DETAIL = "Mangrove/lib/pages/comic_details_page/comic_page.dart"
POLICY = "Mangrove/lib/foundation/local_details_policy.dart"

CASES = [
    {
        "case": "comments_subid_wiring_dropped",
        "file": DETAIL,
        "old": "      'subId': commentsSubIdForLocalDetails(\n",
        "new": "      'subId': null, // INJECTED\n",
        "expect_red": {"local.comments_subid_from_online"},
        "needs_build": False,
        "why": "本地视图不给 subId：拷贝评论再次打出 comic_id=null",
    },
    {
        "case": "cache_enrich_call_dropped",
        "file": DETAIL,
        "old": ("        scheduleMicrotask(\n"
                "          () => _enrichFromCache(cachedForLocal!, localComic),\n"
                "        );\n"),
        "new": "",
        "expect_red": {"local.cache_chapter_enrich"},
        "needs_build": False,
        "why": "缓存 68 话不再回填本地 63 话，本地模式仍是旧列表",
    },
    {
        "case": "cached_view_wiring_dropped",
        "file": DETAIL,
        "old": ("        (shouldUseCachedOnlineView(\n"
                "          sourceKey: widget.sourceKey,\n"
                "          hasCachedDetails: cached != null,\n"
                "        )"),
        "new": "        (false",
        "expect_red": {"local.cached_view_first_frame"},
        "needs_build": False,
        "why": "首帧不再用缓存视图，63 话 + null subId 重新成为终态",
    },
    {
        "case": "policy_subid_always_null",
        "file": POLICY,
        "old": "  return id;",
        "new": "  return null; // INJECTED",
        "expect_red": {"local.comments_subid_from_online"},
        "needs_build": True,
        "why": "策略本身永远返回 null：证明纯函数判据不是装饰品",
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
        timeout=600,
    )
    if "BUILD_OK" not in proc.stdout:
        raise RuntimeError("BUILD_FAIL: %s" % proc.stdout[-600:])


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
    data, base_red = run_check(os.path.join(OUT_DIR, "p67_inject_baseline.json"))
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
            if c["needs_build"]:
                rebuild()
            _, red = run_check(
                os.path.join(OUT_DIR, "p67_inject_%s.json" % c["case"])
            )
        finally:
            open(path, "wb").write(original)
            if c["needs_build"]:
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
                "expect_red": sorted(c["expect_red"]),
                "actual_red": sorted(red),
                "restored": restored,
                "sha256": before,
                "rebuilt": c["needs_build"],
            }
        )
        print(
            "%s %-30s expect=%s actual=%s restored=%s"
            % (verdict, c["case"], sorted(c["expect_red"]), sorted(red), restored)
        )

    out = os.path.join(OUT_DIR, "p67_fault_injection.json")
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
