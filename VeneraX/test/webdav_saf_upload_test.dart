import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/webdav_upload.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

/// #285: a local library kept in a user-picked directory made every WebDAV
/// upload fail with the server seeing no request at all. The body was read via
/// [File.openRead], which such a file does not implement, so the throw happened
/// while the client was still assembling its first call — before OPTIONS, before
/// PUT. These tests pin what prevents that: the body comes from a
/// [RandomAccessFile], it can be produced more than once, and a short read
/// fails the upload rather than publishing a truncated page.
void main() {
  test('streams a file that has no openRead, and the server receives the bytes',
      () async {
    final dir = Directory.systemTemp.createTempSync('venera_saf_upload');
    addTearDown(() => dir.deleteSync(recursive: true));

    // ~2.5 MiB so the body spans several chunks.
    final payload = Uint8List(2500 * 1024);
    for (var i = 0; i < payload.length; i++) {
      payload[i] = i % 251;
    }
    final path = '${dir.path}/page.jpg';
    File(path).writeAsBytesSync(payload);

    final adapter = _RecordingAdapter();
    final client = webdav.newClient('https://example.test', adapter: adapter);

    await writeFileStreamed(
      client,
      _NoStreamFile(path),
      '/comics/Title/001.jpg',
    );

    expect(adapter.methods, containsAllInOrder(['OPTIONS', 'PUT']));
    final put = adapter.bodies['PUT'];
    expect(put, isNotNull);
    expect(put!.length, payload.length);
    expect(put, orderedEquals(payload));
  });

  test('re-reads from the start when the body is sent twice', () async {
    final dir = Directory.systemTemp.createTempSync('venera_saf_replay');
    addTearDown(() => dir.deleteSync(recursive: true));

    final payload = Uint8List.fromList(List.generate(4096, (i) => i % 256));
    final path = '${dir.path}/page.jpg';
    File(path).writeAsBytesSync(payload);

    // An auth challenge makes the client resend the same body; a single-shot
    // stream would arrive empty on the retry.
    final adapter = _RecordingAdapter(challengeFirstPut: true);
    final client = webdav.newClient(
      'https://example.test',
      user: 'u',
      password: 'p',
      adapter: adapter,
    );

    await writeFileStreamed(client, _NoStreamFile(path), '/comics/a.jpg');

    expect(adapter.putBodies, hasLength(2));
    expect(adapter.putBodies.last, orderedEquals(payload));
  });

  test('rejects a body that came up short of the declared length', () async {
    final dir = Directory.systemTemp.createTempSync('venera_saf_short');
    addTearDown(() => dir.deleteSync(recursive: true));

    final path = '${dir.path}/page.jpg';
    File(path).writeAsBytesSync(Uint8List(1024));

    // A declared size the file cannot satisfy stands in for a read that stops
    // early: the PUT must fail rather than publish a truncated page.
    final stream = readFileChunked(File(path), expectedLength: 4096);
    await expectLater(stream.drain(), throwsA(isA<FileSystemException>()));
  });

  test('reports a read failure instead of yielding an empty body', () async {
    final dir = Directory.systemTemp.createTempSync('venera_saf_missing');
    addTearDown(() => dir.deleteSync(recursive: true));

    final stream = readFileChunked(File('${dir.path}/absent.jpg'));
    await expectLater(stream.drain(), throwsA(isA<FileSystemException>()));
  });
}

/// Stands in for a file inside a user-picked directory: reads work through
/// [RandomAccessFile], while [openRead] throws the way flutter_saf's does.
class _NoStreamFile implements File {
  _NoStreamFile(this._path);

  final String _path;

  File get _real => File(_path);

  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      throw UnimplementedError();

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      _real.open(mode: mode);

  @override
  Future<int> length() => _real.length();

  @override
  String get path => _path;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({this.challengeFirstPut = false});

  final bool challengeFirstPut;
  final methods = <String>[];
  final bodies = <String, Uint8List>{};
  final putBodies = <Uint8List>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final method = options.method.toUpperCase();
    methods.add(method);

    final collected = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        collected.addAll(chunk);
      }
    }
    final body = Uint8List.fromList(collected);
    bodies[method] = body;
    if (method == 'PUT') {
      putBodies.add(body);
      if (challengeFirstPut && putBodies.length == 1) {
        return ResponseBody.fromString(
          '',
          401,
          headers: {
            'www-authenticate': ['Basic realm="test"'],
          },
        );
      }
      return ResponseBody.fromString('', 201);
    }
    if (method == 'MKCOL') {
      // Already present, which is what a resumed migration sees.
      return ResponseBody.fromString('', 405);
    }
    return ResponseBody.fromString('', 200);
  }

  @override
  void close({bool force = false}) {}
}
