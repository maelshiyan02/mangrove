import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';
import 'package:mangrove/foundation/app.dart';
import 'package:mangrove/foundation/local.dart';
import 'package:mangrove/utils/file_type.dart';
import 'package:mangrove/utils/io.dart';

class EpubData {
  final String title;

  final String author;

  final File cover;

  final Map<String, List<File>> chapters;

  const EpubData({
    required this.title,
    required this.author,
    required this.cover,
    required this.chapters,
  });
}

/// Builds an EPUB by streaming entries straight into the zip.
///
/// Why streaming (P10.10 ②, upstream v2.3.5): a 汉化工程导出动辄几十 MB，
/// 把整章图片先落临时目录再 `ZipFile.compressFolder` 既吃内存又会在 Windows 上
/// 因为一次性读入而放大风险。`archive` 的 `ZipEncoder().startEncode()` 边读边写，
/// 内存恒定。
///
/// 🔴 静默空字节守卫：本地漫画图片若读出来是 0 字节（磁盘/SAF 读取偶发失败），
/// 旧逻辑会把它当成"正常空图"写进 epub —— 产物看起来导出成功，实际是白图。
/// 这里在读入每个图片时检测 `input.length == 0` 直接抛错，让导出**失败可见**
/// 而不是产出损坏文件。
Future<File> createEpubComic(
    EpubData data, String cacheDir, String outFilePath) async {
  final handle = FileHandle(outFilePath, mode: FileAccess.write);
  final output = OutputFileStream.withFileHandle(handle);
  final zip = ZipEncoder()..startEncode(output);
  var completed = false;

  void addText(String path, String text, {bool store = false}) {
    final entry = ArchiveFile.string(path, text);
    if (store) entry.compression = CompressionType.none;
    zip.add(entry);
  }

  void addImage(String path, File image) {
    // SAF / 本地批量读可能静默返回空字节（读取错误后返回 0 长）。先检测再写。
    final input = InputFileStream.withFileHandle(_EpubImageHandle(image.path));
    try {
      if (input.length == 0) {
        throw 'Failed to read image file: ${image.path}';
      }
      // 图片已压缩，存为 none 以恒定内存流式写入。
      final entry = ArchiveFile.stream(path, input)
        ..compression = CompressionType.none;
      zip.add(entry, autoClose: false);
    } finally {
      input.closeSync();
    }
  }

  String escape(String text) => XmlText(text).toXmlString();

  try {
    addText('mimetype', 'application/epub+zip', store: true);
    addText('META-INF/container.xml', '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''');

    final coverExt = data.cover.extension;
    final coverMime = FileType.fromExtension(coverExt).mime;
    addImage('OEBPS/images/cover.$coverExt', data.cover);
    var imgIndex = 0;
    int chapterIndex = 0;
    final manifestStrBuilder = StringBuffer();
    manifestStrBuilder.writeln(
        '    <item id="cover_image" href="OEBPS/images/cover.$coverExt" media-type="$coverMime"/>');
    manifestStrBuilder.writeln(
        '    <item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>');
    final spineStrBuilder = StringBuffer();
    final navMapStrBuilder = StringBuffer();
    for (final chapter in data.chapters.keys) {
      final title = escape(chapter);
      final images = StringBuffer();
      for (final image in data.chapters[chapter]!) {
        final ext = image.extension;
        final name = 'img$imgIndex.$ext';
        addImage('OEBPS/images/$name', image);
        final mime = FileType.fromExtension(ext).mime;
        manifestStrBuilder.writeln(
            '    <item id="img$imgIndex" href="OEBPS/images/$name" media-type="$mime"/>');
        images.writeln('    <img src="images/$name" alt="$name"/>');
        imgIndex++;
      }
      addText('OEBPS/$chapterIndex.html', '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
  <head>
    <title>$title</title>
    <style type="text/css">
      img { max-width: 100%; height: auto; }
      body { margin: 0; padding: 0; }
    </style>
  </head>
  <body>
    <h1>$title</h1>
    <div>
$images    </div>
  </body>
</html>''');
      manifestStrBuilder.writeln(
          '    <item id="chapter$chapterIndex" href="OEBPS/$chapterIndex.html" media-type="application/xhtml+xml"/>');
      spineStrBuilder.writeln('    <itemref idref="chapter$chapterIndex"/>');
      navMapStrBuilder
          .writeln('    <navPoint id="chapter$chapterIndex" playOrder="${chapterIndex + 2}">');
      navMapStrBuilder
          .writeln('        <navLabel><text>$title</text></navLabel>');
      navMapStrBuilder
          .writeln('        <content src="OEBPS/$chapterIndex.html"/>');
      navMapStrBuilder.writeln('    </navPoint>');
      chapterIndex++;
    }

    final uuid = const Uuid().v4();
    addText('content.opf', '''<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0"
    xmlns="http://www.idpf.org/2007/opf"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
    <metadata>
        <dc:title>${escape(data.title)}</dc:title>
        <dc:creator>${escape(data.author)}</dc:creator>
        <dc:identifier id="book_id">urn:uuid:$uuid</dc:identifier>
        <meta name="cover" content="cover_image"/>
    </metadata>
    <manifest>
${manifestStrBuilder.toString()}
    </manifest>
    <spine toc="toc">
${spineStrBuilder.toString()}
    </spine>
</package>
''');

    addText('toc.ncx', '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx" version="2005-1">
    <head>
        <meta name="dtb:uid" content="urn:uuid:$uuid"/>
        <meta name="dtb:depth" content="1"/>
        <meta name="dtb:totalPageCount" content="0"/>
        <meta name="dtb:maxPageNumber" content="0"/>
    </head>
    <docTitle>
        <text>${escape(data.title)}</text>
    </docTitle>
    <navMap>
${navMapStrBuilder.toString()}
    </navMap>
</ncx>
''');

    zip.endEncode();
    output.closeSync();
    completed = true;
    return File(outFilePath);
  } finally {
    if (!completed) {
      try {
        handle.closeSync();
      } finally {
        await File(outFilePath).deleteIgnoreError();
      }
    }
  }
}

/// archive assumes reads fill its buffer; a short read (SAF on Android, or a
/// partial local read) would otherwise silently truncate the image. Loop until
/// the requested count is satisfied or the file is exhausted.
class _EpubImageHandle extends FileHandle {
  _EpubImageHandle(super.path);

  @override
  int readInto(Uint8List buffer, [int? size]) {
    final count = (size ?? buffer.length).clamp(0, length - position);
    var read = 0;
    while (read < count) {
      final bytes = super.readInto(Uint8List.sublistView(buffer, read, count));
      if (bytes == 0) throw 'Failed to read image file';
      read += bytes;
    }
    return read;
  }
}

Future<File> createEpubWithLocalComic(
    LocalComic comic, String outFilePath) async {
  var chapters = <String, List<File>>{};
  // getImagesForComic also resolves unregistered export mirrors.
  if (comic.chapters == null) {
    chapters[comic.title] =
        (await LocalManager().getImagesForComic(comic, 0))
            .map((e) => File(e.replaceFirst('file://', '')))
            .toList();
  } else {
    for (var chapter in comic.downloadedChapters) {
      chapters[comic.chapters![chapter]!] =
          (await LocalManager().getImagesForComic(comic, chapter))
              .map((e) => File(e.replaceFirst('file://', '')))
              .toList();
    }
  }
  var data = EpubData(
    title: comic.title,
    author: comic.subtitle,
    cover: comic.coverFile,
    chapters: chapters,
  );

  final cacheDir = App.cachePath;

  return Isolate.run(() => overrideIO(() async {
        return createEpubComic(data, cacheDir, outFilePath);
      }));
}
