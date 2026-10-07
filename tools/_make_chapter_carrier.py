"""为 S9.5-a 造一个「整章」验证载体工程（不复制原图）。

背景：`S9Fixture` 只有 5 页，而 §4.10 序 0 的验收写的是「整章」。真正的整章
只有 `downloads/My Dragon Girlfriend Has Returned` 下的章节（94~177 页），
它没有对应的 `projects/` 工程 —— 因为**应用里没有任何"从下载创建工程"的入口**
（`BtProjectManager` 只有 `ensureProject` / `scan`，没有 create；`ProjectWriter.adopt`
只被 `project_validator` 调用）。所以本脚本补上这一步。

🔴 三条硬约束（与 `S9Fixture/README.md` 同源）：

1. **原图不复制** —— 走 A 方案：`directory` 指向 `downloads/<漫画>`，
   产物落在 `projects/<工程名>`（json 所在目录即 `workspace` 的回落值）。
   复制 94×852KB 既慢又没意义。
2. **`projects/` 必须是 `downloads/` 的兄弟** —— 扫描器红线：章节目录内出现
   任何子目录 → 整本漫画被 `local_comic_scanner` 拒绝。所以产物绝不进
   `downloads/`。
3. **json 只写测到的字段** —— `image_info` 只有 `width`/`height`（实测），
   不编造 FT 的 `finish_code` / `translation_target`。工程第一次保存后，
   这些键由 Dart 侧按自己的规则补齐。

用法：
    python tools/_make_chapter_carrier.py [--comic NAME] [--chapter DIR]
                                          [--project NAME] [--list]
"""
import io
import json
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOWNLOADS = os.path.join(ROOT, 'ComicLibrary', 'downloads')
PROJECTS = os.path.join(ROOT, 'ComicLibrary', 'projects')

IMAGE_EXTS = {'.webp', '.jpg', '.jpeg', '.png', '.gif', '.jpe'}


def webp_size(path):
    """返回 (width, height)；不是 WebP 或解析失败返回 None。

    只读文件头，不引入 PIL（本机不一定有）。
    """
    with io.open(path, 'rb') as f:
        head = f.read(30)
    if len(head) < 30 or head[0:4] != b'RIFF' or head[8:12] != b'WEBP':
        return None
    fourcc = head[12:16]
    if fourcc == b'VP8X':
        w = int.from_bytes(head[24:27], 'little') + 1
        h = int.from_bytes(head[27:30], 'little') + 1
        return (w, h)
    if fourcc == b'VP8 ':
        w = int.from_bytes(head[26:28], 'little') & 0x3FFF
        h = int.from_bytes(head[28:30], 'little') & 0x3FFF
        return (w, h) if w and h else None
    if fourcc == b'VP8L':
        bits = int.from_bytes(head[21:25], 'little')
        w = (bits & 0x3FFF) + 1
        h = ((bits >> 14) & 0x3FFF) + 1
        return (w, h)
    return None


def png_size(path):
    with io.open(path, 'rb') as f:
        head = f.read(24)
    if len(head) < 24 or head[0:8] != b'\x89PNG\r\n\x1a\n':
        return None
    w, h = struct.unpack('>II', head[16:24])
    return (w, h)


def size_of(path):
    ext = os.path.splitext(path)[1].lower()
    if ext == '.webp':
        return webp_size(path)
    if ext == '.png':
        return png_size(path)
    return None


def page_order_key(name):
    stem = os.path.splitext(name)[0]
    return (0, int(stem)) if stem.isdigit() else (1, stem)


def main():
    args = sys.argv[1:]

    def opt(name, default=None):
        if name in args:
            i = args.index(name)
            if i + 1 < len(args):
                return args[i + 1]
        return default

    comic = opt('--comic', 'My Dragon Girlfriend Has Returned')
    topic = os.path.join(DOWNLOADS, comic)
    if not os.path.isdir(topic):
        print('comic folder not found:', topic)
        return 1

    chapters = sorted(
        d for d in os.listdir(topic)
        if os.path.isdir(os.path.join(topic, d))
    )
    if '--list' in args:
        for d in chapters:
            n = len([
                f for f in os.listdir(os.path.join(topic, d))
                if os.path.splitext(f)[1].lower() in IMAGE_EXTS
            ])
            print('%4d pages  %s' % (n, d))
        return 0

    chapter = opt('--chapter', chapters[0] if chapters else None)
    if not chapter or chapter not in chapters:
        print('chapter not found:', chapter, '| available:', chapters)
        return 1
    project = opt('--project', 'MDGH-' + chapter.split()[0])

    chapter_dir = os.path.join(topic, chapter)
    names = sorted(
        (f for f in os.listdir(chapter_dir)
         if os.path.splitext(f)[1].lower() in IMAGE_EXTS),
        key=page_order_key,
    )
    if not names:
        print('no images in', chapter_dir)
        return 1

    keys = ['%s/%s' % (chapter, n) for n in names]
    image_info = {}
    unknown = []
    for key, name in zip(keys, names):
        size = size_of(os.path.join(chapter_dir, name))
        if size is None:
            unknown.append(key)
            continue
        image_info[key] = {'width': size[0], 'height': size[1]}

    out_dir = os.path.join(PROJECTS, project)
    if not os.path.isdir(out_dir):
        os.makedirs(out_dir)
    json_path = os.path.join(out_dir, 'imgtrans_%s.json' % project)

    # 键序刻意与 FT / S9Fixture 一致；**不写 `workspace`** ——
    # `TranslationProject.workspace` 会回落到 json 父目录，结果相同，
    # 而 FT 本身不写这个键（写了就是"编造"）。
    doc = {
        'directory': topic.replace('\\', '/'),
        'pages': {key: [] for key in keys},
        'current_img': keys[0],
        'image_info': image_info,
        'page_order': keys,
        'chapters': [{'name': chapter, 'pages': keys}],
    }
    with io.open(json_path, 'w', encoding='utf-8') as f:
        f.write(json.dumps(doc, ensure_ascii=False))

    print('project   :', project)
    print('json      :', json_path)
    print('directory :', doc['directory'])
    print('chapter   :', chapter)
    print('pages     :', len(keys))
    sizes = sorted({(v['width'], v['height']) for v in image_info.values()})
    print('sizes     :', sizes)
    if unknown:
        print('NO SIZE   :', len(unknown), unknown[:5])
    print('bytes     :', os.path.getsize(json_path))
    return 0


if __name__ == '__main__':
    sys.exit(main())
