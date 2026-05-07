import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;

const kCoverThumbnailTargetWidth = 720;
const _coverThumbnailFileName = 'cover_thumb_720.png';

class _CoverThumbnailTask {
  const _CoverThumbnailTask({
    required this.coverPath,
    required this.completer,
  });

  final String coverPath;
  final Completer<String?> completer;
}

class CoverThumbnailCache {
  static final Queue<_CoverThumbnailTask> _queue = Queue<_CoverThumbnailTask>();
  static final Map<String, Future<String?>> _pending = <String, Future<String?>>{};
  static bool _running = false;

  static String thumbnailPathForCover(String coverPath) {
    final file = File(coverPath);
    final parent = file.parent.path;
    return '$parent${Platform.pathSeparator}$_coverThumbnailFileName';
  }

  static String displayPathForCover(String coverPath) {
    final thumbnail = _freshThumbnailFile(coverPath);
    return thumbnail?.path ?? coverPath;
  }

  static bool hasFreshThumbnail(String coverPath) {
    return _freshThumbnailFile(coverPath) != null;
  }

  static Future<String?> ensureForCoverPath(String coverPath) {
    final normalized = coverPath.trim();
    if (normalized.isEmpty) {
      return Future<String?>.value(null);
    }

    final fresh = _freshThumbnailFile(normalized);
    if (fresh != null) {
      return Future<String?>.value(fresh.path);
    }

    final existing = _pending[normalized];
    if (existing != null) {
      return existing;
    }

    final completer = Completer<String?>();
    _queue.add(
      _CoverThumbnailTask(
        coverPath: normalized,
        completer: completer,
      ),
    );
    final future = completer.future.whenComplete(() {
      _pending.remove(normalized);
    });
    _pending[normalized] = future;
    if (!_running) {
      unawaited(_drainQueue());
    }
    return future;
  }

  static Future<void> _drainQueue() async {
    if (_running) {
      return;
    }
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final task = _queue.removeFirst();
        try {
          final result = await _generateThumbnail(task.coverPath);
          if (!task.completer.isCompleted) {
            task.completer.complete(result);
          }
        } catch (_) {
          if (!task.completer.isCompleted) {
            task.completer.complete(null);
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 24));
      }
    } finally {
      _running = false;
      if (_queue.isNotEmpty) {
        unawaited(_drainQueue());
      }
    }
  }

  static File? _freshThumbnailFile(String coverPath) {
    try {
      final coverFile = File(coverPath);
      if (!coverFile.existsSync()) {
        return null;
      }
      final thumbFile = File(thumbnailPathForCover(coverPath));
      if (!thumbFile.existsSync()) {
        return null;
      }
      final coverStat = coverFile.statSync();
      final thumbStat = thumbFile.statSync();
      if (thumbStat.size <= 0) {
        return null;
      }
      if (thumbStat.modified.isBefore(coverStat.modified)) {
        return null;
      }
      return thumbFile;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _generateThumbnail(String coverPath) async {
    final fresh = _freshThumbnailFile(coverPath);
    if (fresh != null) {
      return fresh.path;
    }

    final coverFile = File(coverPath);
    if (!coverFile.existsSync()) {
      return null;
    }

    final bytes = await coverFile.readAsBytes();
    if (bytes.isEmpty) {
      return null;
    }

    ui.Codec? codec;
    ui.FrameInfo? frameInfo;
    try {
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: kCoverThumbnailTargetWidth,
      );
      frameInfo = await codec.getNextFrame();
      final byteData = await frameInfo.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      final pngBytes = byteData?.buffer.asUint8List();
      if (pngBytes == null || pngBytes.isEmpty) {
        return null;
      }
      final thumbPath = thumbnailPathForCover(coverPath);
      final thumbFile = File(thumbPath);
      await thumbFile.parent.create(recursive: true);
      await thumbFile.writeAsBytes(pngBytes, flush: true);
      return thumbPath;
    } catch (_) {
      return null;
    } finally {
      try {
        frameInfo?.image.dispose();
      } catch (_) {}
      try {
        codec?.dispose();
      } catch (_) {}
    }
  }
}