"""P15 磁盘修复：补章节目录的翻译组名 + 封面池更新。

只做两件事，都可回滚：
1. 章节目录改名：`116 [comix.to]` → `116 [Lua Comic] [comix.to]`
   （组名来自该章在 comix 上的实际上传组，已由 chapters.json 确认）
2. 封面：下载 comix poster 存为 `cover/[cover]season(1).<ext>`，
   同季度的旧扩展名文件（如 .webp）在**新图落盘成功之后**才移除，
   避免中途失败导致封面池变空（A19 迁移脚本第 3 个坑）。

不改章节图片内容，不改 `_manifest.json` 的键（它按页号索引，不含目录名）。
"""

import json
import os
import subprocess
import sys

BASE = os.path.join("ComicLibrary", "downloads")
PROXY = "http://127.0.0.1:7890"
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

# 目录改名：(漫画目录, 旧目录名, 新目录名)
RENAMES = [
    (
        "The Archvillain's Dying Nanny",
        "116 [comix.to]",
        "116 [Lua Comic] [comix.to]",
    ),
    (
        "The Perks of Being a Villainess",
        "109 [comix.to]",
        "109 [Violet Scans] [comix.to]",
    ),
]


def rename_chapters(apply: bool) -> None:
    print("== 章节目录改名 ==")
    for comic, old, new in RENAMES:
        src = os.path.join(BASE, comic, old)
        dst = os.path.join(BASE, comic, new)
        if not os.path.isdir(src):
            print(f"  跳过（不存在）: {comic}/{old}")
            continue
        if os.path.exists(dst):
            print(f"  !! 目标已存在，跳过: {comic}/{new}")
            continue
        if apply:
            os.rename(src, dst)
            print(f"  ✓ {comic}/{old} → {new}")
        else:
            print(f"  [预演] {comic}/{old} → {new}")


def update_cover(comic: str, url: str, apply: bool) -> None:
    from urllib.parse import urlparse

    ext = os.path.splitext(urlparse(url).path)[1].lstrip(".").lower() or "jpg"
    cover_dir = os.path.join(BASE, comic, "cover")
    target = os.path.join(cover_dir, f"[cover]season(1).{ext}")
    if not apply:
        print(f"  [预演] {comic} → {os.path.basename(target)}")
        return
    os.makedirs(cover_dir, exist_ok=True)
    tmp = target + ".part"
    r = subprocess.run(
        ["curl", "-s", "-L", "-m", "90", "-x", PROXY, "-A", UA, url, "-o", tmp],
        capture_output=True,
    )
    size = os.path.getsize(tmp) if os.path.exists(tmp) else 0
    if r.returncode != 0 or size < 2048:
        print(f"  !! {comic} 封面下载失败（{size}B，rc={r.returncode}）")
        if os.path.exists(tmp):
            os.remove(tmp)
        return
    with open(tmp, "rb") as f:
        magic = f.read(12)
    is_jpeg = magic[:2] == b"\xff\xd8"
    is_webp = magic[:4] == b"RIFF" and magic[8:12] == b"WEBP"
    if not (is_jpeg or is_webp):
        print(f"  !! {comic} 封面格式无法识别 magic={magic[:6].hex()}")
        os.remove(tmp)
        return
    real_ext = "jpg" if is_jpeg else "webp"
    final = os.path.join(cover_dir, f"[cover]season(1).{real_ext}")
    if final != tmp:
        os.replace(tmp, final)
    # 新图确认落盘后，才清理同季度的其它扩展名
    removed = []
    for f in os.listdir(cover_dir):
        p = os.path.join(cover_dir, f)
        if p == final or not os.path.isfile(p):
            continue
        if f.startswith("[cover]season(1)."):
            os.remove(p)
            removed.append(f)
    print(
        f"  ✓ {comic} 封面 {size/1024:.0f}KB → {os.path.basename(final)}"
        + (f"（清理旧扩展名 {removed}）" if removed else "")
    )


def main() -> int:
    apply = "--apply" in sys.argv
    meta_path = sys.argv[1]
    with open(meta_path, encoding="utf-8") as f:
        meta = json.load(f)

    rename_chapters(apply)

    print("\n== 封面池 ==")
    for hid, d in meta.items():
        url = (d.get("poster") or {}).get("large")
        if not url:
            print(f"  !! {d['dir']} 无 poster")
            continue
        update_cover(d["dir"], url, apply)

    if not apply:
        print("\n（预演模式，加 --apply 才动手）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
