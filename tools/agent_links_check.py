#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""agent_links_check.py — 多 agent 共享工作区体检。

检查内容：
  1. 9 条目录联接是否存在、是否为联接、目标是否正确；
  2. 主记忆 MEMORY.md 是否超出注入上限（默认 7200 字符，静默截断阈值）；
  3. 关键文件/目录是否齐全（附录 A01~A08、W00、kb 索引、入口文件）；
  4. 是否存在"重复副本"隐患（某侧目录是真目录而非联接）。

用法：
    python tools/agent_links_check.py            # 体检（只读）
    python tools/agent_links_check.py --fix      # 缺失/失效的联接自动重建

退出码：0 = 全部通过；1 = 有问题。
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (相对路径, 期望指向的相对路径)
LINKS = [
    (r".workbuddy\memory", r".agent\memory"),
    (r".workbuddy\documents", r".agent\documents"),
    (r".workbuddy\skills", r".agent\skills"),
    (r".workbuddy\specs", r".agent\specs"),
    (r".trae\memory", r".agent\memory"),
    (r".trae\documents", r".agent\documents"),
    (r".trae\skills", r".agent\skills"),
    (r".trae\specs", r".agent\specs"),
    ("docs", r".agent\documents\worklog"),
]

REQUIRED = [
    r".agent\memory\MEMORY.md",
    r".agent\memory\appendices\A01-环境通道.md",
    r".agent\memory\appendices\A02-硬规矩与断言纪律.md",
    r".agent\memory\appendices\A03-磁盘布局与FT工程互读.md",
    r".agent\memory\appendices\A04-工作室-画布与编辑层.md",
    r".agent\memory\appendices\A05-工作室-字体与渲染.md",
    r".agent\memory\appendices\A06-翻译组与下载语义.md",
    r".agent\memory\appendices\A07-comix源.md",
    r".agent\memory\appendices\A08-排期与阶段现状.md",
    r".agent\memory\appendices\W00-工作日志索引.md",
    r".agent\kb\INDEX.md",
    r".agent\README.md",
    "AGENTS.md",
    "CLAUDE.md",
]

MEMORY_LIMIT = 7200  # 实测自动注入在 ~7200 字符处静默截断


def real(p: str) -> str:
    return os.path.join(ROOT, p)


def is_junction(path: str) -> bool:
    """Windows 目录联接判定（3.12+ 有 isjunction；更低版本退回 islink）。"""
    fn = getattr(os.path, "isjunction", None)
    if fn is not None:
        return bool(fn(path))
    return os.path.islink(path)


def link_target(path: str) -> str:
    try:
        return os.readlink(path)
    except OSError:
        return ""


def norm(p: str) -> str:
    """规范化路径：去掉 Windows 的扩展长度前缀后再比较。

    `os.readlink()` 在 Windows 上会返回 `\\\\?\\D:\\...` 形式，直接与普通
    绝对路径比较会永远不等。
    """
    p = (p or "").strip()
    if p.startswith("\\\\?\\UNC\\"):
        p = "\\\\" + p[8:]
    elif p.startswith("\\\\?\\"):
        p = p[4:]
    return os.path.normcase(os.path.normpath(p))


def make_junction(link: str, target: str) -> bool:
    """用 PowerShell 建目录联接（无需管理员）。返回是否成功。"""
    cmd = (
        "$ErrorActionPreference='Stop'; "
        "if (Test-Path -LiteralPath '{0}') {{ Remove-Item -LiteralPath '{0}' -Force -Recurse }}; "
        "New-Item -ItemType Junction -Path '{0}' -Target '{1}' | Out-Null"
    ).format(link.replace("'", "''"), target.replace("'", "''"))
    try:
        r = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command", cmd],
            capture_output=True,
            text=True,
        )
        return r.returncode == 0
    except Exception as exc:  # noqa: BLE001
        print("  ! 建联接失败：%s" % exc)
        return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fix", action="store_true", help="自动重建缺失/失效的联接")
    args = ap.parse_args()

    problems = []

    print("项目根：%s" % ROOT)
    print()
    print("=== 1. 目录联接 ===")
    for rel, want in LINKS:
        p = real(rel)
        want_abs = real(want)
        if not os.path.exists(p):
            msg = "缺失"
            if args.fix and make_junction(p, want_abs):
                msg = "缺失 → 已重建"
                if is_junction(p):
                    msg = "缺失 → 已重建 ✅"
                else:
                    problems.append("%s 重建后仍不是联接" % rel)
            else:
                problems.append("%s 缺失" % rel)
            print("  [%s] %s" % (msg, rel))
            continue
        if not is_junction(p):
            problems.append("%s 存在但不是目录联接（可能是真实目录 → 有分叉风险）" % rel)
            print("  [✗ 真实目录] %s" % rel)
            continue
        tgt = link_target(p)
        ok = norm(tgt) == norm(want_abs)
        if ok:
            print("  [✅] %s → %s" % (rel, want))
        else:
            problems.append("%s 指向了意外的目标：%s" % (rel, tgt))
            print("  [✗ 目标不符] %s → %s（期望 %s）" % (rel, tgt, want))

    print()
    print("=== 2. 主记忆体积 ===")
    mem = real(r".agent\memory\MEMORY.md")
    if not os.path.exists(mem):
        problems.append("主记忆缺失")
        print("  [✗] 主记忆不存在")
    else:
        with open(mem, encoding="utf-8") as fh:
            n = len(fh.read())
        if n <= MEMORY_LIMIT:
            print("  [✅] MEMORY.md = %d 字符（上限 %d，余量 %d）" % (n, MEMORY_LIMIT, MEMORY_LIMIT - n))
        else:
            problems.append("主记忆超限：%d > %d（会被静默截断尾部）" % (n, MEMORY_LIMIT))
            print("  [✗] MEMORY.md = %d 字符 > 上限 %d" % (n, MEMORY_LIMIT))

    print()
    print("=== 3. 关键文件 ===")
    for rel in REQUIRED:
        p = real(rel)
        if os.path.exists(p):
            print("  [✅] %s" % rel)
        else:
            problems.append("缺少 %s" % rel)
            print("  [✗] %s 缺失" % rel)

    print()
    print("=== 4. 附录规模 ===")
    adir = real(r".agent\memory\appendices")
    if os.path.isdir(adir):
        total = 0
        for fn in sorted(os.listdir(adir)):
            if fn.endswith(".md"):
                with open(os.path.join(adir, fn), encoding="utf-8") as fh:
                    n = len(fh.read())
                total += n
                flag = "  ⚠️ 偏大，考虑再拆" if n > 8000 else ""
                print("  %-40s %6d 字符%s" % (fn, n, flag))
        print("  合计 %d 字符" % total)

    print()
    if problems:
        print("=== 结果：发现 %d 个问题 ===" % len(problems))
        for m in problems:
            print("  - %s" % m)
        return 1
    print("=== 结果：全部通过 ✅ ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
