#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""找出漫画目录里「不完整」的章节，并给出补齐命令。

判据（任一命中即算不完整）：
  1. `_manifest.json` 记了节点数，落盘页数 < 节点数 - 待补数（真缺页）
  2. `_manifest.json` 有 `failures`（URL 拿到了但下载失败）
  3. `_manifest.json` 有 `pending`（节点没抓到地址）
  4. **没有** manifest 记录却已经有图 —— 中断留下的半章，无法自证完整
  5. 目录不存在但 `chapters.json` 里有这一话 —— 还没下

第 4 条最阴：旧版下载器不写 manifest，一个 12 页的残目录会被"目录非空就跳过"
永久放过，界面上看着是"已下载"、翻开只有 12 页。

用法
----
    py -3.12 tools/comix_gap_report.py "<漫画目录>"
    py -3.12 tools/comix_gap_report.py "<漫画目录>" --json   # 机器可读
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

IMG_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".avif"}


def load_json(path: Path):
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        print(f"! 无法解析 {path.name}：{e}")
        return None


def page_count(d: Path) -> int:
    if not d.is_dir():
        return 0
    return sum(1 for f in d.iterdir() if f.is_file() and f.suffix.lower() in IMG_EXTS)


def dir_key(name: str) -> float:
    try:
        return float(name.split()[0])
    except (ValueError, IndexError):
        return 99999.0


def main() -> int:
    ap = argparse.ArgumentParser(description="报告漫画目录里不完整的章节")
    ap.add_argument("comic_dir")
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    args = ap.parse_args()

    root = Path(args.comic_dir)
    if not root.is_dir():
        print(f"目录不存在：{root}")
        return 2

    manifest = load_json(root / "_manifest.json") or {}
    chapters = load_json(root / "chapters.json") or []

    # chapters.json 里按 rokar i 组等给出「这一话该有多少页」的只有节点数，没有；
    # 但它的存在能告诉我们"有哪些话是应该下的"。
    expected = {}
    for c in chapters:
        key = f"{c['number']} [{c['group']}] [comix.to]"
        expected.setdefault(key, c)

    findings = []
    for d in sorted((x for x in root.iterdir() if x.is_dir()), key=lambda p: p.name):
        if d.name.lower() == "cover" or d.name.startswith("."):
            continue
        pages = page_count(d)
        rec = manifest.get(d.name)
        if pages == 0:
            findings.append({"chapter": d.name, "pages": 0,
                             "reason": "目录里没有图片"})
            continue
        if rec is None:
            findings.append({"chapter": d.name, "pages": pages,
                             "reason": "无 manifest 记录，无法确认完整（疑似中断残留）"})
            continue
        nodes = rec.get("nodes") or 0
        pending = rec.get("pending") or []
        failures = rec.get("failures") or []
        if pending:
            findings.append({"chapter": d.name, "pages": pages, "nodes": nodes,
                             "reason": f"{len(pending)} 个节点未取到地址"})
        elif failures:
            findings.append({"chapter": d.name, "pages": pages, "nodes": nodes,
                             "reason": f"{len(failures)} 页下载失败"})
        elif nodes and pages < nodes - len(pending):
            findings.append({"chapter": d.name, "pages": pages, "nodes": nodes,
                             "reason": f"落盘 {pages} < 节点 {nodes}"})

    if args.json:
        print(json.dumps(findings, ensure_ascii=False, indent=2))
        return 0

    if not findings:
        print(f"✓ 全部完整（{sum(1 for x in root.iterdir() if x.is_dir()) - 1} 章）")
        return 0

    print(f"发现 {len(findings)} 个不完整章节：\n")
    for f in findings:
        extra = f"（节点 {f['nodes']}）" if "nodes" in f else ""
        print(f"  {f['chapter']:42} {f['pages']:>4} 页{extra}  {f['reason']}")

    # 生成补齐命令（逐章独立会话，抗封）
    print("\n补齐命令（每章一个独立浏览器会话）：")
    for f in findings:
        name = f["chapter"]
        number = name.split()[0]
        group = ""
        if "[" in name:
            group = name.split("[")[1].split("]")[0]
        cmd = ("py -3.12 -u tools/comix_browser_dl.py download 6emnz "
               f"--out \"{root}\" --numbers {number}")
        if group:
            cmd += f" --group \"{group}\""
        cmd += " --force --restart-each"
        print(f"  {cmd}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
