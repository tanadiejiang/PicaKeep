import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A terminal, display-only refusal. Original export/download limits are not
/// changed and the reader must not automatically retry this condition.
class ReaderImageLimit implements Exception {
  const ReaderImageLimit(this.reason);
  final String reason;

  String get message => '当前图片无法在安全预算内完成原尺寸预览。'
      '请在阅读设置的“图片显示”中切换为“清晰优先”，并选择“安全整图”。';

  @override
  String toString() => 'ReaderImageLimit($reason)';
}

final _readerImageReadLimitsKey = Object();

/// Reading-only input contract. It is intentionally separate from transport
/// retry ownership: downloads can own retries without opting into preview.
///
/// A provider declaring this capability must enforce the bound BEFORE growing
/// its buffers, not just check a fully allocated result. An arbitrary custom
/// loader cannot be made bounded merely by running it in this Zone.
class ReaderImageReadLimits {
  const ReaderImageReadLimits({
    this.maximumBytes = 64 << 20,
    bool Function()? isCancelled,
    this.cancelled,
  })  : _isCancelled = isCancelled,
        assert(maximumBytes >= 0);

  static ReaderImageReadLimits? get current =>
      Zone.current[_readerImageReadLimitsKey] as ReaderImageReadLimits?;

  final int maximumBytes;
  final bool Function()? _isCancelled;
  final Future<void>? cancelled;
  bool get isCancelled => _isCancelled?.call() == true;

  void check(int bytes) {
    if (isCancelled) throw StateError('Reader image input cancelled');
    if (bytes < 0 || bytes > maximumBytes) {
      throw const ReaderImageLimit('encoded-input');
    }
  }
}

T runWithReaderImageReadLimits<T>(
        ReaderImageReadLimits limits, T Function() body) =>
    runZoned(body, zoneValues: {_readerImageReadLimitsKey: limits});

/// Keep non-reader consumers unchanged. Readers check the stat before opening
/// a body stream AND count actual chunks, since a file can grow after stat.
Future<Uint8List> readReaderImageFile(File file) async {
  final limits = ReaderImageReadLimits.current;
  if (limits == null) return file.readAsBytes();
  limits.check(0);
  limits.check(await file.length());
  final builder = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in file.openRead()) {
    limits.check(total + chunk.length);
    total += chunk.length;
    builder.add(chunk);
  }
  limits.check(total);
  return builder.takeBytes();
}
