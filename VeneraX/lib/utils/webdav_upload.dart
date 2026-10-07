import 'package:dio/dio.dart';
import 'package:venera/utils/io.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

typedef WebdavUploadAttempt = Future<void> Function();

/// Streams [local] to [remotePath] without ever calling [File.openRead].
///
/// Replaces `client.writeFromFile`, which reads the body via openRead: for a
/// file inside a user-picked directory that is an [AndroidFile], whose openRead
/// throws immediately, so the upload died before the first request went out —
/// the server saw no OPTIONS and no PUT at all (#285). Reading through a
/// RandomAccessFile works for both plain and user-picked locations and keeps the
/// upload streamed, so a large page is never held in memory whole.
Future<void> writeFileStreamed(
  webdav.Client client,
  File local,
  String remotePath, {
  void Function(int count, int total)? onProgress,
  CancelToken? cancelToken,
}) async {
  final length = await local.length();
  await client.c.wdWriteWithStream(
    client,
    remotePath,
    readFileChunked(local, expectedLength: length),
    length,
    onProgress: onProgress,
    cancelToken: cancelToken,
  );
}

String serverAbsoluteWebdavPath(String path) {
  return path.startsWith('/') ? path : '/$path';
}

Future<bool> uploadWithWebdav404Fallback({
  required WebdavUploadAttempt streamUpload,
  required WebdavUploadAttempt bufferedUpload,
}) async {
  try {
    await streamUpload();
    return false;
  } on DioException catch (error) {
    if (error.response?.statusCode != 404) rethrow;
    await bufferedUpload();
    return true;
  }
}
