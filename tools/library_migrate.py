#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""漫画图书馆磁盘规范化迁移（D1，2026-10-24）。

把 `ComicLibrary/downloads/<漫画>/` 里的内容按 D1 规范重整：

1. **章节目录** → `<话号> [翻译组] [来源站点]`（缺哪项就少哪项，不编造）
2. **封面池**   → `<漫画>/cover/[cover]season(1).<ext>`，并删掉根目录的旧封面
3. **数据库**   → `data/local.db` 的 `chapters` / `downloadedChapters` / `cover`
                  跟着改（本地漫画的 chapter key 就是目录名，不改就读不到图）

设计原则：**不猜**。站点标签只在能确证的场合补：
   - 目录名里已经带了域名（`116 [comix.to]`）
   - 漫画目录里有本采集脚本的产物（`chapters.json` / `_manifest.json` → comix.to）
   - `_library_sources.json` 手工登记
三条都不满足 → 原样保留，列进报告的 `unknown_site`，绝不写错站名。

用法
----
    py -3.12 tools/library_migrate.py                 # 预演，只打报告
    py -3.12 tools/library_migrate.py --apply         # 真的改
    py -3.12 tools/library_migrate.py --only "The Runaway Extra and the Obsessive Duke"
    py -3.12 tools/library_migrate.py --apply --no-db # 只动磁盘，不碰数据库

报告落在 `<图书馆>/_migration_report.json`，原始状态另存
`_migration_backup.json`（--apply 时写），回滚照着它反着做即可。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sqlite3
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LIBRARY = ROOT / "ComicLibrary" / "downloads"
DEFAULT_DB = ROOT / "data" / "local.db"
SOURCE_MAP_FILE = "_library_sources.json"

IMG_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".avif"}
COVER_DIR = "cover"

# 目录名解析：`<数字> [A] [B] (2)` / `116` / `Chapter 5`
#
# 🔴 数字后面必须跟空格 / `[` / 结尾：`2860aaf9-bc44-11f1-...` 这种 UUID
# 目录名（复制漫画的章节 key 就是 UUID）绝不能被当成"第 2860 话"。
LEADING_NUM = re.compile(r"^\s*(\d+(?:\.\d+)?)(?=\s|\[|$)\s*(.*)$")
BRACKET = re.compile(r"\[([^\]]*)\]")
VARIANT = re.compile(r"\((\d+)\)\s*$")
# 域名的样子：至少一个点、无空格（`comix.to` / `cn.cnbzmg.com`）
DOMAIN = re.compile(r"^[\w-]+(?:\.[\w-]+)+$")
# Windows 非法字符
ILLEGAL = re.compile(r'[\\/:*?"<>|]')


def log(msg: str) -> None:
    print(msg, flush=True)


# ---------------------------------------------------------------- 名字解析


class DirName:
    """一个章节目录名的结构化视图。"""

    __slots__ = ("raw", "number", "groups", "site", "variant", "loose")

    def __init__(self, raw, number, groups, site, variant, loose):
        self.raw = raw
        self.number = number
        self.groups = groups
        self.site = site
        self.variant = variant
        self.loose = loose

    def build(self, site: str | None = None) -> str:
        """按规范拼回去。site 传 None 用自身的，传 '' 表示明确不要站标。"""
        use_site = self.site if site is None else site
        parts = [self.number]
        if self.loose:
            parts.append(self.loose)
        for g in self.groups:
            # 站标被误当成组名（`119 [baozimh] [baozimh]`）时只留一份。
            if use_site and g.lower() == use_site.lower():
                continue
            parts.append(f"[{g}]")
        if use_site:
            parts.append(f"[{use_site}]")
        name = " ".join(parts)
        if self.variant > 1:
            name += f" ({self.variant})"
        return ILLEGAL.sub("_", name).strip()


def parse_dir_name(name: str) -> DirName | None:
    """解析章节目录名；读不出话号返回 None（UUID、番外之类保持原样）。"""
    raw = name.strip()
    if not raw:
        return None
    m = LEADING_NUM.match(raw)
    if not m:
        return None
    number = m.group(1)
    rest = m.group(2).strip()

    variant = 1
    vm = VARIANT.search(rest)
    if vm:
        variant = int(vm.group(1))
        rest = rest[: vm.start()].strip()

    groups: list[str] = []
    site: str | None = None
    for b in BRACKET.finditer(rest):
        text = b.group(1).strip()
        if not text:
            continue
        if DOMAIN.match(text) or text.lower() in KNOWN_SITE_TAGS:
            site = text.lower()
        else:
            groups.append(text)
    loose = BRACKET.sub("", rest).strip()
    return DirName(raw, number, groups, site, variant, loose)


# ---------------------------------------------------------------- 站点确证

# 源 key → 目录名站点标签。**必须与 Dart 侧
# `lib/foundation/chapter_directory.dart` 的 `_sourceSiteTags` 保持一致**，
# 否则同一本漫画在程序侧和脚本侧会算出两个不同的目录名。
SOURCE_TAGS = {
    "comix_to": "comix.to",
    "comix": "comix.to",
    "baozi": "baozimh",
    "copy_manga": "copymanga",
    "comick": "comick",
    "manga_dex": "mangadex",
    "Komiic": "komiic",
    "dm5": "dm5",
    "goda": "goda",
    "manhuaren": "manhuaren",
    "mycomic": "mycomic",
}


def site_tag(source_key: str) -> str:
    return SOURCE_TAGS.get(source_key, source_key)


# 站标不一定长成域名（`baozimh` / `copymanga` 都没有点）。识别这些，否则
# 会被当成"翻译组"再拼一遍，跑两次就变成 `119 [baozimh] [baozimh]`。
KNOWN_SITE_TAGS = {v.lower() for v in SOURCE_TAGS.values()} | {
    k.lower() for k in SOURCE_TAGS
}


def load_source_registry(implicit_path: Path) -> dict[int, str]:
    """读 `data/implicitData.json` 的 `sourceTypeRegistry`（comic_type → 源 key）。

    这张表就是 App 自己持久化的映射（`SourcePlatformResolver` 学到就写一份），
    所以它比任何猜测都可靠：**本地库里的 comic_type 一问就知道是哪家站**。
    """
    if not implicit_path.exists():
        return {}
    try:
        data = json.loads(implicit_path.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        log(f"  ! implicitData 解析失败，跳过类型表：{e}")
        return {}
    raw = data.get("sourceTypeRegistry") or {}
    out: dict[int, str] = {}
    for k, v in raw.items():
        try:
            out[int(k)] = str(v)
        except (TypeError, ValueError):
            continue
    return out


def detect_comic_site(comic_dir: Path, override: str | None,
                      row: sqlite3.Row | None,
                      registry: dict[int, str]) -> tuple[str | None, str]:
    """确定这本漫画的来源站点，返回 (站点标签, 依据)。确定不了返回 (None, 原因)。"""
    if override:
        return override, "_library_sources.json"
    # ① 本地库的 comic_type → 源 key（最权威：App 自己写的）
    if row is not None:
        key = registry.get(row["comic_type"])
        if key:
            return site_tag(key), f"local.db comic_type={row['comic_type']} → {key}"
        if row["source"]:
            return row["source"], "local.db source 列"
    # ② 本采集脚本自己的产物 → comix.to
    if (comic_dir / "chapters.json").exists():
        return "comix.to", "chapters.json（采集脚本产物）"
    if (comic_dir / "_manifest.json").exists():
        return "comix.to", "_manifest.json（采集脚本产物）"
    # ③ 目录名里已经带域名的章节 → 这本就是这个站
    for child in comic_dir.iterdir():
        if not child.is_dir() or child.name.lower() == COVER_DIR:
            continue
        ref = parse_dir_name(child.name)
        if ref and ref.site:
            return ref.site, f"子目录自带站标（{child.name}）"
    return None, "无任何来源线索"


def load_source_map(library: Path) -> dict[str, str]:
    path = library / SOURCE_MAP_FILE
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:  # noqa: BLE001
        log(f"  ! {SOURCE_MAP_FILE} 解析失败，忽略：{e}")
        return {}
    return {k: v for k, v in data.items() if isinstance(v, str) and v}


# ---------------------------------------------------------------- 数据库


def build_chapter_index(row: sqlite3.Row | None) -> dict[str, tuple[str, list[str]]]:
    """`chapters` JSON → {章节目录名(key): (话号, [翻译组])}。

    网络漫画的 chapters 是版本矩阵 `{话号: [{key, group, ...}, ...]}`，key 往往
    是 UUID 或整条 URL，**目录名里什么信息都没有**。想看"第几话谁翻的"只能回
    数据库反查——这就是那份信息的唯一来源。
    """
    if row is None or not row["chapters"]:
        return {}
    try:
        data = json.loads(row["chapters"])
    except Exception:  # noqa: BLE001
        return {}
    if not isinstance(data, dict):
        return {}
    out: dict[str, tuple[str, list[str]]] = {}
    for number, versions in data.items():
        if isinstance(versions, list):          # 版本化矩阵
            for v in versions:
                if not isinstance(v, dict):
                    continue
                key = v.get("key") or ""
                if not key:
                    continue
                group = (v.get("group") or "").strip()
                out.setdefault(key, (str(number), [group] if group else []))
        elif isinstance(versions, str):          # 扁平 `{key: 标题}`
            out.setdefault(number, (number, []))
    return out


def open_db(path: Path) -> sqlite3.Connection | None:
    if not path.exists():
        log(f"  ! 找不到数据库 {path}，跳过数据库同步")
        return None
    conn = sqlite3.connect(str(path))
    conn.row_factory = sqlite3.Row
    return conn


def db_rows(conn: sqlite3.Connection) -> dict[str, sqlite3.Row]:
    """按 `directory` 的末段（目录名）索引，便于和磁盘对账。"""
    out: dict[str, sqlite3.Row] = {}
    for row in conn.execute("select * from comics"):
        d = (row["directory"] or "").replace("\\", "/").rstrip("/")
        out.setdefault(d.split("/")[-1], row)
    return out


def rename_chapters_json(raw: str, mapping: dict[str, str]) -> tuple[str, int]:
    """**扁平** chapters（`{目录名: 标题}`）改键：key 与 value 都要跟着磁盘改。

    🔴 只处理 value 全是字符串的扁平结构。版本矩阵 `{话号: [{key: ...}]}` 与
    分组结构 `{组名: {源id: 标题}}` 的键是**源 id / 话号**，不是目录名——动了
    就等于把章节和源数据切断，从此刷不出章节、下载判重全乱。
    """
    if not raw:
        return raw, 0
    try:
        data = json.loads(raw)
    except Exception:  # noqa: BLE001
        return raw, 0
    if not isinstance(data, dict) or not data:
        return raw, 0
    if not all(isinstance(v, str) for v in data.values()):
        return raw, 0
    changed = 0
    out = {}
    for k, v in data.items():
        nk = mapping.get(k, k)
        nv = mapping.get(v, v)
        if nk != k or nv != v:
            changed += 1
        out[nk] = nv
    if not changed:
        return raw, 0
    return json.dumps(out, ensure_ascii=False), changed


def align_flat_chapter_keys(comic_dir: Path, row: sqlite3.Row) -> tuple[dict, dict, int]:
    """把扁平 chapters 的键对齐到磁盘上**真实存在**的目录名。

    迁移可能跑在旧数据上（或上一次只改了盘没改库），所以不能只依赖本次
    `mapping`：直接拿「库里的键」去磁盘找，找不到就按语义（话号 + 翻译组）
    匹配出实际目录名。返回 (新chapters, 键映射, 改动数)。
    """
    raw = row["chapters"]
    if not raw:
        return {}, {}, 0
    try:
        data = json.loads(raw)
    except Exception:  # noqa: BLE001
        return {}, {}, 0
    if not isinstance(data, dict) or not data:
        return {}, {}, 0
    if not all(isinstance(v, str) for v in data.values()):
        return {}, {}, 0

    on_disk = {
        d.name for d in comic_dir.iterdir()
        if d.is_dir() and d.name.lower() != COVER_DIR and not d.name.startswith(".")
    }
    mapping: dict[str, str] = {}
    for key in data:
        if key in on_disk:
            continue
        ref = parse_dir_name(key)
        if ref is None:
            continue
        best, best_score = None, 0
        for cand in on_disk:
            a = parse_dir_name(cand)
            if a is None or a.number != ref.number:
                continue
            # 模板点名了组就必须同组；模板没点名则接受任意组（补全场景）。
            if ref.groups:
                if [g.lower() for g in a.groups] != [g.lower() for g in ref.groups]:
                    continue
            score = 10 + (5 if a.site else 0)
            if score > best_score:
                best, best_score = cand, score
        if best:
            mapping[key] = best

    if not mapping:
        return data, {}, 0
    out = {}
    for k, v in data.items():
        nk = mapping.get(k, k)
        out[nk] = mapping.get(v, v) if v else v
    return out, mapping, len(mapping)


def rename_downloaded(raw: str, mapping: dict[str, str]) -> tuple[str, int]:
    if not raw:
        return raw, 0
    try:
        data = json.loads(raw)
    except Exception:  # noqa: BLE001
        return raw, 0
    if not isinstance(data, list):
        return raw, 0
    out = [mapping.get(x, x) if isinstance(x, str) else x for x in data]
    changed = sum(1 for a, b in zip(data, out) if a != b)
    return json.dumps(out, ensure_ascii=False), changed


# ---------------------------------------------------------------- 单本迁移


def plan_comic(comic_dir: Path, site_override: str | None,
               row: sqlite3.Row | None = None,
               registry: dict[int, str] | None = None) -> dict:
    """产出一本漫画的迁移计划（只读，不改盘）。"""
    site, why = detect_comic_site(comic_dir, site_override, row, registry or {})
    plan: dict = {
        "comic": comic_dir.name,
        "site": site,
        "site_reason": why,
        "renames": [],       # [(旧名, 新名)]
        "skipped": [],       # [(名字, 原因)]
        "cover": None,       # {"from": 根目录文件, "to": cover/xxx}
        "stale_covers": [],  # 根目录待删的旧封面
    }

    chapter_dirs = [
        d for d in comic_dir.iterdir()
        if d.is_dir() and d.name.lower() != COVER_DIR and not d.name.startswith(".")
    ]
    chapter_dirs.sort(key=lambda p: p.name)

    chapter_index = build_chapter_index(row)

    for d in chapter_dirs:
        ref = parse_dir_name(d.name)
        if ref is None:
            # 目录名读不出话号（UUID / 整条 URL）→ **绝不动**。
            #
            # 这类目录名就是章节的源 id，读取侧 `chapterDirectoryName` 也是原样
            # 拿 key 当目录名。改名后两边对不上，`resolveChapterDirectoryName`
            # 的语义匹配也救不了（模板本身没有数字可比），结果是"图在磁盘上但
            # 读不到"。数据库里能查到它是第几话谁翻的，这里只写进报告供人看。
            info = chapter_index.get(d.name)
            detail = f"（数据库记录：第 {info[0]} 话 {info[1]}）" if info else ""
            plan["skipped"].append((d.name, f"目录名即源 id，改名会读不到{detail}"))
            continue
        # 已经有站标 → 用它；否则用整本推断出的站点
        target_site = ref.site or site
        if target_site is None:
            plan["skipped"].append((d.name, "站点未知，不猜"))
            continue
        new_name = ref.build(site=target_site)
        if not new_name or new_name == d.name:
            continue
        if (comic_dir / new_name).exists():
            plan["skipped"].append((d.name, f"目标目录已存在：{new_name}"))
            continue
        plan["renames"].append((d.name, new_name))

    # 封面：根目录 `cover*` 图 → cover/ 池
    root_covers = sorted(
        f for f in comic_dir.iterdir()
        if f.is_file() and f.suffix.lower() in IMG_EXTS and f.stem.lower().startswith("cover")
    )
    cover_dir = comic_dir / COVER_DIR
    pool = (
        sorted(f for f in cover_dir.iterdir() if f.is_file() and f.suffix.lower() in IMG_EXTS)
        if cover_dir.is_dir() else []
    )
    if root_covers:
        first = root_covers[0]
        target = cover_dir / f"[cover]season(1){first.suffix.lower()}"
        if target.exists():
            # 池里已经有 season(1)，根目录这几张就是历史残留 → 只删不搬。
            plan["stale_covers"] = [f.name for f in root_covers]
        else:
            plan["cover"] = {"from": first.name, "to": f"{COVER_DIR}/{target.name}"}
            plan["stale_covers"] = [f.name for f in root_covers]
    elif not pool and row is not None and row["cover"]:
        # 根目录没有封面文件 → 封面是**从章节里挑的一页**，记录成相对路径
        # `116 [comix.to]\0.webp`。只按路径拆，别猜分隔符（那个 `0` 是文件名
        # 的一部分，不是转义）。
        # 这种封面只能**复制**：那一页本身是正文的一部分，搬走就是缺页。
        rel = row["cover"].replace("\\", "/")
        parts = [p for p in rel.split("/") if p]
        if len(parts) >= 2:
            src = comic_dir.joinpath(*parts)
            if src.is_file():
                target = cover_dir / f"[cover]season(1){src.suffix.lower()}"
                if not target.exists():
                    plan["cover"] = {
                        "from": "/".join(parts),
                        "to": f"{COVER_DIR}/{target.name}",
                        "copy": True,
                    }

    # 数据库对齐（只读预检）：扁平 chapters 的键可能还停在改名前的目录名上。
    if row is not None:
        _, amap, n_align = align_flat_chapter_keys(comic_dir, row)
        plan["db_align"] = n_align
        plan["db_align_pairs"] = amap

    return plan


def apply_comic(comic_dir: Path, plan: dict, conn: sqlite3.Connection | None,
                row: sqlite3.Row | None, backup: dict) -> dict:
    """执行一本漫画的计划，返回实际变更统计。"""
    stats = {"renamed": 0, "cover_moved": False, "stale_removed": 0, "db_updated": False}
    mapping: dict[str, str] = {}

    for old, new in plan["renames"]:
        src, dst = comic_dir / old, comic_dir / new
        try:
            src.rename(dst)
            mapping[old] = new
            stats["renamed"] += 1
        except Exception as e:  # noqa: BLE001
            log(f"    ! 改名失败 {old} → {new}：{e}")

    if plan["cover"]:
        src = comic_dir / plan["cover"]["from"].replace("/", os.sep)
        dst = comic_dir / plan["cover"]["to"].replace("/", os.sep)
        try:
            dst.parent.mkdir(exist_ok=True)
            if plan["cover"].get("copy"):
                # 封面取自章节内页：复制，原页留在章节里（搬走就是缺页）。
                shutil.copy2(src, dst)
            else:
                src.rename(dst)
            stats["cover_moved"] = True
        except Exception as e:  # noqa: BLE001
            log(f"    ! 封面搬运失败：{e}")

    # 旧封面清理：**只有池里确实有封面**才删根目录残留。
    # 顺序很重要——先搬/复制进池，再删，中途失败也不会把唯一的封面删掉。
    pool = comic_dir / COVER_DIR
    pool_has_cover = pool.is_dir() and any(
        f.is_file() and f.suffix.lower() in IMG_EXTS for f in pool.iterdir()
    )
    if pool_has_cover:
        for name in plan["stale_covers"]:
            f = comic_dir / name
            if not f.exists():
                continue
            try:
                f.unlink()
                stats["stale_removed"] += 1
            except Exception as e:  # noqa: BLE001
                log(f"    ! 旧封面删除失败 {name}：{e}")

    # 数据库同步
    #
    # 扁平 chapters 的键**就是目录名**（本地漫画、以及包子这类源的扁平存储），
    # 磁盘改名后不同步键，程序就会"图在磁盘上但读不到"。版本矩阵 / 分组结构
    # 的键是源 id，绝不能动 —— 由 rename_chapters_json 内部把关。
    if conn is not None and row is not None:
        updates = {}
        merged = dict(mapping)
        aligned, amap, n_align = align_flat_chapter_keys(comic_dir, row)
        if n_align:
            merged.update(amap)
        if merged:
            new_ch, n1 = rename_chapters_json(row["chapters"], merged)
            if n1:
                updates["chapters"] = new_ch
            new_dl, n2 = rename_downloaded(row["downloadedChapters"], merged)
            if n2:
                updates["downloadedChapters"] = new_dl
        if plan["cover"]:
            updates["cover"] = plan["cover"]["to"].replace("/", "\\" if os.name == "nt" else "/")
        if updates:
            backup.setdefault("db", {})[row["id"]] = {k: row[k] for k in updates}
            sets = ", ".join(f"{k} = ?" for k in updates)
            conn.execute(f"update comics set {sets} where id = ?",
                         (*updates.values(), row["id"]))
            conn.commit()
            stats["db_updated"] = True

    return stats


# ---------------------------------------------------------------- 主流程


def main() -> int:
    ap = argparse.ArgumentParser(description="漫画图书馆磁盘规范化迁移（D1）")
    ap.add_argument("--library", default=str(DEFAULT_LIBRARY))
    ap.add_argument("--db", default=str(DEFAULT_DB))
    ap.add_argument("--implicit", default=str(ROOT / "data" / "implicitData.json"),
                    help="App 的 implicitData.json（含 sourceTypeRegistry）")
    ap.add_argument("--only", default="", help="只处理名字包含该子串的漫画")
    ap.add_argument("--apply", action="store_true", help="真的执行（默认只预演）")
    ap.add_argument("--no-db", action="store_true", help="不改数据库")
    args = ap.parse_args()

    library = Path(args.library)
    if not library.is_dir():
        log(f"图书馆目录不存在：{library}")
        return 2

    source_map = load_source_map(library)
    registry = load_source_registry(Path(args.implicit))
    log(f"图书馆：{library}")
    log(f"模式：{'APPLY（会真的改盘）' if args.apply else 'DRY-RUN（只预演）'}")
    log(f"源类型注册表：{len(registry)} 条（来自 implicitData.json）")
    if source_map:
        log(f"手工站点登记：{len(source_map)} 条")

    conn = None if args.no_db else open_db(Path(args.db))
    rows = db_rows(conn) if conn else {}

    comic_dirs = sorted(
        d for d in library.iterdir()
        if d.is_dir() and not d.name.startswith(".") and d.name != "cos写真"
    )
    if args.only:
        comic_dirs = [d for d in comic_dirs if args.only in d.name]

    report = {"generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
              "mode": "apply" if args.apply else "dry-run",
              "comics": []}
    backup = {"generated_at": report["generated_at"], "renames": {}, "db": {}}
    total_renamed = total_cover = total_stale = 0

    for comic_dir in comic_dirs:
        plan = plan_comic(
            comic_dir,
            source_map.get(comic_dir.name),
            rows.get(comic_dir.name),
            registry,
        )
        if not plan["renames"] and not plan["cover"] and not plan["stale_covers"] \
                and not plan["skipped"] and not plan.get("db_align"):
            continue
        log(f"\n== {comic_dir.name}")
        log(f"   站点：{plan['site'] or '未知'}（{plan['site_reason']}）")
        for old, new in plan["renames"]:
            log(f"   改名：{old}  →  {new}")
        for name, why in plan["skipped"]:
            log(f"   跳过：{name}（{why}）")
        if plan["cover"]:
            log(f"   封面：{plan['cover']['from']}  →  {plan['cover']['to']}")
        if plan["stale_covers"]:
            log(f"   待删旧封面：{', '.join(plan['stale_covers'])}")
        if plan.get("db_align"):
            log(f"   记录表对齐：{plan['db_align']} 个章节键跟磁盘不同名")
            for old, new in list(plan["db_align_pairs"].items())[:4]:
                log(f"      {old} → {new}")

        if args.apply:
            backup["renames"][comic_dir.name] = plan["renames"]
            stats = apply_comic(comic_dir, plan, conn, rows.get(comic_dir.name), backup)
            plan["applied"] = stats
            total_renamed += stats["renamed"]
            total_cover += 1 if stats["cover_moved"] else 0
            total_stale += stats["stale_removed"]
            log(f"   已执行：改名 {stats['renamed']}，封面 {stats['cover_moved']}，"
                f"删旧 {stats['stale_removed']}，数据库 {stats['db_updated']}")
        report["comics"].append(plan)

    if conn is not None:
        conn.close()

    out = library / "_migration_report.json"
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    log(f"\n报告：{out}")

    pending_unknown = sum(
        1 for c in report["comics"] for _, why in c["skipped"] if "站点未知" in why
    )
    log(f"合计：改名 {total_renamed}，封面池 {total_cover}，删旧封面 {total_stale}")
    if pending_unknown:
        log(f"⚠ {pending_unknown} 个章节目录因「站点未知」被跳过。"  )
        log(f"  在 {library / SOURCE_MAP_FILE} 里登记 {{漫画目录名: 站点域名}} 后再跑一次。")

    if args.apply:
        bpath = library / "_migration_backup.json"
        bpath.write_text(json.dumps(backup, ensure_ascii=False, indent=2), encoding="utf-8")
        log(f"回滚依据：{bpath}")
    else:
        log("（预演结束，加 --apply 才会真的执行）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
