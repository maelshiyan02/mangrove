import 'package:flutter_test/flutter_test.dart';
import 'package:mangrove/foundation/image_provider/base_image_provider.dart';
import 'package:mangrove/foundation/image_provider/reader_image.dart';
import 'package:mangrove/foundation/translation_project/studio_reader.dart';
import 'package:mangrove/utils/io.dart';
import 'package:mangrove/utils/translations.dart';

/// Serves a scripted sequence of read results without touching dart:io, whose
/// real async file operations hang the test isolate.
class _ScriptedFile implements File {
  _ScriptedFile(this.reads, this.size);

  /// One entry per read; the last entry repeats once exhausted.
  final List<Uint8List> reads;

  /// What the file reports as its own size, or -1 to fail the query.
  final int size;

  int readCount = 0;

  @override
  Future<Uint8List> readAsBytes() async {
    final result = reads[readCount.clamp(0, reads.length - 1)];
    readCount++;
    return result;
  }

  @override
  Future<int> length() async {
    if (size < 0) {
      throw const FileSystemException("size unavailable");
    }
    return size;
  }

  @override
  String get path => '/library/comic/003.jpg';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

Uint8List get _page => Uint8List.fromList([0xFF, 0xD8, 0xFF]);

Uint8List get _nothing => Uint8List(0);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The failure messages go through .tl, which reads this table.
  AppTranslation.translations = {};

  // S9.5-b 之前这里测的是 `resolveReaderTranslation`：读旧引擎的缓存，读不到就
  // **当场**排一次翻译。那条路已经把阅读器整个交出去了（开关语义改成"该章入队
  // 工作室管线"，阅读侧只读工程产物），所以判据换成新的来源优先级 ——
  // `chooseReaderPageSource` 是那个决定**唯一**的实现，阅读器只是执行它。
  test('a finished result bitmap wins over re-rendering', () {
    expect(
      chooseReaderPageSource(
        hasResult: true,
        hasInpainted: true,
        hasBlocks: true,
      ),
      ReaderPageSource.projectResult,
    );
  });

  test('inpainted without a result re-renders, so an edit shows immediately', () {
    expect(
      chooseReaderPageSource(
        hasResult: false,
        hasInpainted: true,
        hasBlocks: true,
      ),
      ReaderPageSource.projectRender,
    );
  });

  // 🔴 只有底图没有块时重绘 = 画一张**去字的白页**，比原图更糟：用户会以为
  // "翻译把字弄没了"。这一条是那个判据，不是"顺便"。
  test('an erased base without blocks falls back to the original', () {
    expect(
      chooseReaderPageSource(
        hasResult: false,
        hasInpainted: true,
        hasBlocks: false,
      ),
      ReaderPageSource.original,
    );
  });

  test('a page with no artifact at all falls back to the original', () {
    expect(
      chooseReaderPageSource(
        hasResult: false,
        hasInpainted: false,
        hasBlocks: true,
      ),
      ReaderPageSource.original,
    );
  });

  test('a normal read is returned as-is', () async {
    final file = _ScriptedFile([_page], 3);
    expect(await readLocalPage(file), _page);
    expect(file.readCount, 1);
  });

  test('a file that really is empty fails permanently', () async {
    final file = _ScriptedFile([_nothing], 0);
    await expectLater(
      readLocalPage(file),
      throwsA(isA<ImageLoadingPermanentException>()),
    );
  });

  test('no bytes from a file that has some means retry', () async {
    final file = _ScriptedFile([_nothing, _page], 3);
    expect(await readLocalPage(file), _page);
    expect(file.readCount, 2);
  });

  test('a read that never recovers fails, but not permanently', () async {
    final file = _ScriptedFile([_nothing], 3);
    await expectLater(
      readLocalPage(file),
      throwsA(
        allOf(
          isNot(isA<ImageLoadingPermanentException>()),
          predicate((e) => e.toString().contains('003.jpg')),
        ),
      ),
    );
    expect(file.readCount, 3);
  });

  test('an unreadable size counts as a failed read, not an empty file',
      () async {
    final file = _ScriptedFile([_nothing], -1);
    await expectLater(
      readLocalPage(file),
      throwsA(isNot(isA<ImageLoadingPermanentException>())),
    );
  });
}
