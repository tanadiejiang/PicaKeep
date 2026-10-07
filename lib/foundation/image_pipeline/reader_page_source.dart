import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'derived_image_store.dart';

/// Immutable identity of the page selected by the reader.
///
/// The identity is deliberately independent of a signed URL or a widget
/// index.  It can therefore survive a cache refresh while an export/share
/// operation is in progress.
class ReaderPageIdentity {
  const ReaderPageIdentity({
    required this.sourceKey,
    required this.workId,
    required this.downloadId,
    required this.episode,
    required this.page,
    required this.sourceVersion,
    this.accessScope = 'public',
  });

  final String sourceKey;
  final String workId;
  final String downloadId;
  final int episode;
  final int page;
  final String sourceVersion;
  final String accessScope;

  String get stableKey => jsonEncode([
        'reader-original-v2',
        sourceKey,
        workId,
        downloadId,
        episode,
        page,
        accessScope,
        sourceVersion,
      ]);
}

class ReaderPageCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get cancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw StateError('Reader page load cancelled');
  }
}

/// Protects an opened original until native/file consumers have actually
/// stopped using it. Cancelling a scheduler ticket is not native completion.
class ReaderPageFileLease {
  ReaderPageFileLease._();
  static final _counts = <String, int>{};
  static final _drains = <String, Completer<void>>{};
  static int get activeLeaseCount =>
      _counts.values.fold(0, (total, count) => total + count);

  static String _key(File file) {
    final path = file.absolute.path;
    return Platform.isWindows ? path.toLowerCase() : path;
  }

  static void Function() acquire(File file) {
    final key = _key(file);
    final releaseCacheProtection = DerivedImageStore.protectPath(file.path);
    _counts[key] = (_counts[key] ?? 0) + 1;
    var released = false;
    return () {
      if (released) return;
      released = true;
      releaseCacheProtection();
      final remaining = (_counts[key] ?? 1) - 1;
      if (remaining > 0) {
        _counts[key] = remaining;
      } else {
        _counts.remove(key);
        _drains.remove(key)?.complete();
      }
    };
  }

  static Future<void> waitForDrain(File file) {
    final key = _key(file);
    if ((_counts[key] ?? 0) == 0) return Future<void>.value();
    return (_drains[key] ??= Completer<void>()).future;
  }
}

/// A resolved page resource. [openOriginal] always means the best
/// authoritative bytes currently available for this identity; it never means
/// a screenshot, thumbnail, decoded display layer, or tile mosaic.
abstract class ReaderPageSource {
  ReaderPageIdentity get identity;

  /// True when this resource is the original file, false when the source has
  /// explicitly reported that only a lower-quality rendition exists.
  bool get isAuthoritativeOriginal;

  /// True while the source has not finished resolving a higher quality URL.
  bool get isPreviewOnly;

  String? get mimeType;
  String? get extension;
  int? get width;
  int? get height;
  int? get byteLength;

  /// Opens a bounded, cancellable stream of source bytes. Implementations
  /// should prefer a file-backed stream and avoid aggregating large inputs.
  Stream<List<int>> openOriginal({ReaderPageCancellation? cancellation});

  /// Opens the page as a local file, materialising it once when the source is
  /// a privileged path, network response, or archive member.
  Future<File> openOriginalFile({ReaderPageCancellation? cancellation});

  Future<void> dispose();
}

/// Small file-backed implementation used by local/downloaded pages and tests.
class FileReaderPageSource implements ReaderPageSource {
  FileReaderPageSource({
    required this.identity,
    required File file,
    this.isAuthoritativeOriginal = true,
    this.isPreviewOnly = false,
    this.mimeType,
    this.extension,
    this.width,
    this.height,
    this.byteLength,
    this.modifiedMillis,
  }) : _file = file;

  final File _file;
  @override
  final ReaderPageIdentity identity;
  @override
  final bool isAuthoritativeOriginal;
  @override
  final bool isPreviewOnly;
  @override
  final String? mimeType;
  @override
  final String? extension;
  @override
  final int? width;
  @override
  final int? height;

  @override
  final int? byteLength;
  final int? modifiedMillis;

  Future<void> _verifySnapshot() async {
    if (byteLength == null && modifiedMillis == null) return;
    final stat = await _file.stat();
    if ((byteLength != null && stat.size != byteLength) ||
        (modifiedMillis != null &&
            stat.modified.millisecondsSinceEpoch != modifiedMillis)) {
      throw StateError('Original source changed while this page was selected');
    }
  }

  @override
  Stream<List<int>> openOriginal(
      {ReaderPageCancellation? cancellation}) async* {
    cancellation?.throwIfCancelled();
    await _verifySnapshot();
    final release = ReaderPageFileLease.acquire(_file);
    try {
      await for (final chunk in _file.openRead()) {
        cancellation?.throwIfCancelled();
        yield chunk;
      }
      await _verifySnapshot();
    } finally {
      release();
    }
  }

  @override
  Future<File> openOriginalFile({ReaderPageCancellation? cancellation}) async {
    cancellation?.throwIfCancelled();
    await _verifySnapshot();
    return _file;
  }

  @override
  Future<void> dispose() => ReaderPageFileLease.waitForDrain(_file);
}

/// Deferred file opener. File-backed cache providers can set [ownsFile] to
/// false; temporary archive/privileged materialisations set it to true.
class DeferredReaderPageSource implements ReaderPageSource {
  DeferredReaderPageSource({
    required this.identity,
    required Future<File> Function(ReaderPageCancellation cancellation) opener,
    this.ownsFile = true,
    this.isAuthoritativeOriginal = true,
    this.isPreviewOnly = false,
    this.mimeType,
    this.extension,
    this.width,
    this.height,
    this.byteLength,
    this.onDispose,
  }) : _opener = opener;

  @override
  final ReaderPageIdentity identity;
  final Future<File> Function(ReaderPageCancellation cancellation) _opener;
  final bool ownsFile;
  final FutureOr<void> Function()? onDispose;
  @override
  final bool isAuthoritativeOriginal;
  @override
  final bool isPreviewOnly;
  @override
  final String? mimeType;
  @override
  final String? extension;
  @override
  final int? width;
  @override
  final int? height;
  @override
  final int? byteLength;
  final _cancellation = ReaderPageCancellation();
  Future<File>? _pending;
  File? _opened;
  Future<void>? _disposeFuture;

  @override
  Future<File> openOriginalFile({ReaderPageCancellation? cancellation}) async {
    _cancellation.throwIfCancelled();
    cancellation?.throwIfCancelled();
    // The lifetime belongs to this source, not any other consumer's source.
    if (cancellation != null) {
      unawaited(cancellation.cancelled.then((_) => _cancellation.cancel()));
    }
    final file = await (_pending ??= _opener(_cancellation));
    _opened = file;
    _cancellation.throwIfCancelled();
    return file;
  }

  @override
  Stream<List<int>> openOriginal(
      {ReaderPageCancellation? cancellation}) async* {
    final file = await openOriginalFile(cancellation: cancellation);
    final release = ReaderPageFileLease.acquire(file);
    try {
      await for (final chunk in file.openRead()) {
        _cancellation.throwIfCancelled();
        cancellation?.throwIfCancelled();
        yield chunk;
      }
    } finally {
      release();
    }
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _cancellation.cancel();
    try {
      final file = _opened ?? await _pending;
      if (file != null) await ReaderPageFileLease.waitForDrain(file);
      if (ownsFile && file != null && await file.exists()) await file.delete();
    } catch (_) {}
    // Disposal is often intentionally unawaited by Flutter widget lifecycles.
    // A failed cleanup must not become an uncaught asynchronous UI exception.
    try {
      await onDispose?.call();
    } catch (_) {}
  }
}

/// Materialises an arbitrary stream to a managed file without keeping the
/// whole image in a Dart list. The caller owns the returned file and should
/// delete it after the source lease ends.
Future<File> materializeReaderPageStream(
  Stream<List<int>> source, {
  required Directory directory,
  required String fileName,
  void Function(int bytes)? onProgress,
  ReaderPageCancellation? cancellation,
  int maxBytes = 1024 * 1024 * 1024,
}) async {
  await directory.create(recursive: true);
  final target = File('${directory.path}${Platform.pathSeparator}$fileName');
  final sink = target.openWrite();
  var total = 0;
  try {
    await for (final chunk in source) {
      if (chunk.isEmpty) continue;
      cancellation?.throwIfCancelled();
      if (total + chunk.length > maxBytes) {
        throw StateError('Reader source exceeds the disk reservation');
      }
      sink.add(chunk);
      total += chunk.length;
      // Backpressure prevents IOSink's asynchronous queue accumulating the
      // complete compressed input when a fast source outruns disk writes.
      await sink.flush();
      onProgress?.call(total);
    }
    await sink.flush();
    await sink.close();
    return target;
  } catch (_) {
    await sink.close();
    try {
      await target.delete();
    } catch (_) {}
    rethrow;
  }
}

/// Detects a safe extension/mime pair from a small header probe.
({String extension, String mime}) readerPageTypeFromHeader(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return (extension: '.jpg', mime: 'image/jpeg');
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return (extension: '.png', mime: 'image/png');
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return (extension: '.webp', mime: 'image/webp');
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return (extension: '.gif', mime: 'image/gif');
  }
  if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4d) {
    return (extension: '.bmp', mime: 'image/bmp');
  }
  return (extension: '.bin', mime: 'application/octet-stream');
}
