import 'dart:async';
import 'dart:io';

/// Only a fully received page becomes a resumable download. A killed process
/// can leave .part behind, but it is replaced on retry and never counts as done.
Future<void> writeDownloadStreamFile({
  required File target,
  required Stream<List<int>> stream,
  required void Function() checkCancelled,
  void Function(int length)? onChunk,
  int? expectedLength,
}) async {
  final partial = File('${target.path}.part');
  await partial.parent.create(recursive: true);
  final sink = partial.openWrite();
  // IOSink errors may arrive while the network stream is still awaiting data.
  // Register immediately; flush/close below still propagates the same failure.
  unawaited(sink.done.catchError((Object _) {}));
  var closed = false;
  var received = 0;
  try {
    await for (final chunk in stream) {
      checkCancelled();
      sink.add(chunk);
      received += chunk.length;
      onChunk?.call(chunk.length);
    }
    checkCancelled();
    if (received == 0 ||
        (expectedLength != null && received != expectedLength)) {
      throw const FormatException('下载内容不完整，请重试');
    }
    await sink.flush();
    await sink.close();
    closed = true;
    checkCancelled();
    await partial.rename(target.path);
  } catch (_) {
    if (!closed) {
      try {
        await sink.close();
      } catch (_) {}
    }
    if (await partial.exists()) await partial.delete();
    rethrow;
  }
}
