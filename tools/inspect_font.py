"""Inspect a font binary: sfnt flavour, names, weight, glyph count, cmap hits.

Why this file exists
--------------------
P9.3 shipped two *wrong* conclusions about missing glyphs, both from a
hand-rolled cmap reader that skipped the `idRangeOffset` glyph-id arrays
(format 4) and the whole `format 12` subtable. The lesson recorded in P9.6 was:
**validate the measuring tool against a known answer before trusting any number
it produces.** So this script:

* parses **every** `format 4` and `format 12` subtable and unions their answers
  (a font with several subtables is only "missing" a codepoint when *none* of
  them maps it);
* never reads `format 0`/`6` (irrelevant for CJK) and says so rather than
  silently reporting a miss;
* is used with `--expect` so the caller has to state what it already knows.

Usage
-----
    python tools/inspect_font.py <font.otf> [--expect U+4E2D,glyph>0 ...]

Exit code 0 when every --expect holds, 1 otherwise, 2 on a parse error.
"""
import argparse
import io
import struct
import sys

SKIP_FORMATS = {0, 2, 6, 8, 10}


def _u16(b, o):
    return struct.unpack_from('>H', b, o)[0]


def _u32(b, o):
    return struct.unpack_from('>I', b, o)[0]


def tables(data):
    if len(data) < 12:
        raise ValueError('too short to be a font')
    tag = data[:4].decode('latin-1')
    num = _u16(data, 4)
    out = {}
    for i in range(num):
        rec = 12 + i * 16
        name = data[rec:rec + 4].decode('latin-1')
        off = _u32(data, rec + 8)
        length = _u32(data, rec + 12)
        out[name] = (off, length)
    return tag, out


def name_records(data, off, length):
    """Returns {(name_id, platform_id): text} for the utf-16/ascii names."""
    fmt = _u16(data, off)
    if fmt not in (0, 1):
        return {}
    count = _u16(data, off + 2)
    string_off = _u16(data, off + 4)
    out = {}
    for i in range(count):
        rec = off + 6 + i * 12
        pid = _u16(data, rec)
        nid = _u16(data, rec + 6)
        ln = _u16(data, rec + 8)
        so = off + string_off + _u16(data, rec + 10)
        raw = data[so:so + ln]
        try:
            text = raw.decode('utf-16-be') if pid == 3 else raw.decode('latin-1')
        except UnicodeDecodeError:
            continue
        out[(nid, pid)] = text
    return out


def cmap_hits(data, off):
    """Union of every format 4 / format 12 subtable: {codepoint: glyph_id}.

    ⚠️ Done as a union on purpose: a font whose *first* subtable is a
    BMP-only format 4 (very common) would otherwise look like it lacks every
    astral codepoint, and the SC/TC/KR Noto builds rely on format 12 for
    exactly the ranges that matter here.
    """
    num = _u16(data, off + 2)
    best = {}
    seen = []
    for i in range(num):
        # 🔴 The cmap header is version(2) + numTables(2) = **4** bytes, so the
        # encoding records start at off+4. The first version of this file used
        # off+8 and every subtable offset came out 4 bytes late, which surfaced
        # as "formats seen [0, 42, 59392, ...]" — obviously wrong numbers that
        # the `--expect` self-check caught before any conclusion was drawn.
        sub = off + 4 + i * 8
        sub_off = off + _u32(data, sub + 4)
        fmt = _u16(data, sub_off)
        if fmt == 4:
            mapping = _cmap4(data, sub_off)
        elif fmt == 12:
            mapping = _cmap12(data, sub_off)
        else:
            seen.append(fmt)
            continue
        seen.append(fmt)
        for cp, gid in mapping.items():
            if gid:
                best.setdefault(cp, gid)
    return best, seen


def _cmap4(data, off):
    seg_x2 = _u16(data, off + 6)
    segs = seg_x2 // 2
    ends = [_u16(data, off + 14 + i * 2) for i in range(segs)]
    starts_off = off + 16 + seg_x2
    starts = [_u16(data, starts_off + i * 2) for i in range(segs)]
    deltas_off = starts_off + seg_x2
    deltas = [_u16(data, deltas_off + i * 2) for i in range(segs)]
    ranges_off = deltas_off + seg_x2
    out = {}
    for i in range(segs):
        s, e = starts[i], ends[i]
        if s > e:
            continue
        delta = deltas[i]
        ro = _u16(data, ranges_off + i * 2)
        for cp in range(s, e + 1):
            if cp == 0xFFFF:
                continue
            if ro == 0:
                gid = (cp + delta) & 0xFFFF
            else:
                # 🔴 The pointer array the first parser skipped. Its address is
                # relative to the *slot itself*, not to the subtable.
                addr = ranges_off + i * 2 + ro + (cp - s) * 2
                if addr + 2 > len(data):
                    continue
                gid = _u16(data, addr)
                if gid:
                    gid = (gid + delta) & 0xFFFF
            if gid:
                out[cp] = gid
    return out


def _cmap12(data, off):
    groups = _u32(data, off + 12)
    out = {}
    for i in range(groups):
        rec = off + 16 + i * 12
        start = _u32(data, rec)
        end = _u32(data, rec + 4)
        gid0 = _u32(data, rec + 8)
        for cp in range(start, end + 1):
            out[cp] = gid0 + (cp - start)
    return out


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('font')
    ap.add_argument('--expect', action='append', default=[],
                    help='<U+XXXX|char>=<glyph|>0|0>  e.g. U+D55C=>0')
    args = ap.parse_args(argv[1:])

    data = io.open(args.font, 'rb').read()
    tag, tbl = tables(data)
    print(f'file       : {args.font}')
    print(f'sfnt       : {tag!r} '
          f'({"CFF/OTF outlines" if tag == "OTTO" else "TrueType outlines" if tag == chr(0) + chr(1) + chr(0) + chr(0) else "?"})')

    if 'name' in tbl:
        names = name_records(data, *tbl['name'])
        fam = names.get((1, 3)) or names.get((1, 1))
        sub = names.get((2, 3)) or names.get((2, 1))
        print(f'family     : {fam!r} / {sub!r}')
    else:
        print('family     : (no name table)')

    if 'OS/2' in tbl:
        print(f'weight     : {_u16(data, tbl["OS/2"][0] + 4)}')
    if 'maxp' in tbl:
        print(f'numGlyphs  : {_u16(data, tbl["maxp"][0] + 4)}')

    hits, formats = ({}, [])
    if 'cmap' in tbl:
        hits, formats = cmap_hits(data, tbl['cmap'][0])
    print(f'cmap       : formats seen {sorted(set(formats))}, '
          f'{len(hits)} codepoints mapped by format 4/12')
    skipped = sorted({f for f in formats if f in SKIP_FORMATS})
    if skipped:
        print(f'note       : formats {skipped} not parsed (not needed for CJK)')

    failed = []
    for spec in args.expect:
        cp_s, want = spec.split('=')
        cp = int(cp_s[2:], 16) if cp_s.upper().startswith('U+') else ord(cp_s)
        gid = hits.get(cp, 0)
        ok = (gid != 0) if want == '>0' else (gid == 0 if want == '0' else str(gid) == want)
        mark = 'ok  ' if ok else 'FAIL'
        print(f'  [{mark}] U+{cp:04X} {chr(cp)!r} -> glyph {gid} (want {want})')
        if not ok:
            failed.append(spec)

    print('RESULT:', 'PASS' if not failed else f'FAIL {failed}')
    return 0 if not failed else 1


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv))
    except Exception as exc:  # noqa: BLE001
        print('parse error:', exc)
        sys.exit(2)
