import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;

import 'package:picakeep/foundation/local_cover_cache.dart';

const kCoverThumbnailTargetWidth = 720;

/// 缩略图子目录名（位于统一封面缓存根之下）。
const String _coverThumbnailDirName = 'thumbs';

/// 缩略图文件后缀。
///
/// 旧实现把文件名固定成 `cover_thumb_720.png`；现在文件名是稳定哈希，
/// 后缀单独留一个常量，便于识别与清理。
const String _coverThumbnailSuffix = '.png';

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

  /// 缩略图路径：**统一缓存根下的 `thumbs/` 子目录**（plan/12）。
  ///
  /// ## 改动前的问题
  ///
  /// 旧实现是 `原封面父目录/cover_thumb_720.png`，有两个真问题：
  ///
  /// 1. **往用户下载目录里写文件** —— 原封面在下载目录时，缩略图就落在那里，
  ///    违背"缓存只写应用目录"（计划验收标准 4）；
  /// 2. **同一目录下的多个封面共用一个文件名** —— 一个下载目录里的两张封面
  ///    会互相覆盖对方的缩略图，`_freshThumbnailFile` 的 mtime 判断还可能
  ///    让它误认为"是这张图的缩略图"，于是显示**别人的图**。
  ///
  /// ## 键的构成
  ///
  /// `哈希(封面绝对路径 + 封面长度 + 封面 mtime)`：源图变化后键就变了，
  /// 于是**不会误用旧缩略图**（计划第 5 条的要求）。旧键的残留文件由
  /// 缓存目录整体清理，不影响正确性。
  static String thumbnailPathForCover(String coverPath) {
    return p.join(_thumbRoot().path, '${_thumbnailKey(coverPath)}$_coverThumbnailSuffix');
  }

  /// 缩略图根目录：`<App.dataPath>/local_library_cache/covers/thumbs`。
  static Directory _thumbRoot() {
    return Directory(
      p.join(
        LocalCoverCache.rootDirectory().path,
        _coverThumbnailDirName,
      ),
    );
  }

  static String _thumbnailKey(String coverPath) {
    var fingerprint = '0|0';
    try {
      final stat = File(coverPath).statSync();
      fingerprint = '${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    } catch (_) {}
    // 用与 LocalCoverCache 同一套稳定哈希，避免再引入一个哈希实现。
    return LocalCoverCache.stableHashForFileName('$coverPath|$fingerprint');
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