import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../cover_thumbnail_cache.dart';
import '../remote_library_data_source.dart';
import 'derived_image_store.dart';
import 'image_work_scheduler.dart';
import 'image_background_notifications.dart';

/// Commit/scan callbacks enqueue final paths and return immediately. Preparation
/// never edits a source or participates in the database commit transaction.
class BackgroundImagePreparer {
  BackgroundImagePreparer._();
  static final instance = BackgroundImagePreparer._();
  final Queue<String> _pending = Queue();
  final Set<String> _known = {};
  bool _running = false;
  int _generation = 0;
  int get pendingCount => _pending.length;
  void activate() {
    ImageBackgroundNotifications.onCommitted = committed;
    DerivedImageStore.publicationObserver =
        (path) => RemoteLibraryDataSource.trimCacheToLimit(protectedPath: path);
  }

  void committed(String finalPath) {
    if (finalPath.isEmpty) return;
    final path = p.normalize(p.absolute(finalPath));
    if (!_known.add(path)) return;
    if (_pending.length >= 32) _known.remove(_pending.removeFirst());
    _pending.add(path);
    if (!_running) unawaited(_drain());
  }

  void invalidate() {
    _generation++;
    _pending.clear();
    _known.clear();
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending.isNotEmpty) {
        final path = _pending.removeFirst();
        final generation = _generation;
        try {
          final file = await _firstReadableImage(path);
          if (file == null || generation != _generation) continue;
          await CoverThumbnailCache.prepareDisplay(file.path, 384,
              priority: ImageWorkPriority.background,
              canContinue: () => generation == _generation);
        } catch (_) {
          /* A successful import/download stays successful. */
        } finally {
          _known.remove(path);
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<File?> _firstReadableImage(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    bool image(String value) => const ['.jpg', '.jpeg', '.png', '.webp', '.bmp']
        .contains(p.extension(value).toLowerCase());
    if (type == FileSystemEntityType.file && image(path)) return File(path);
    if (type != FileSystemEntityType.directory) return null;
    final candidates = <File>[];
    await for (final entity in Directory(path).list(followLinks: false)) {
      if (entity is File && image(entity.path)) {
        if (p
            .basenameWithoutExtension(entity.path)
            .toLowerCase()
            .startsWith('cover')) {
          return entity;
        }
        candidates.add(entity);
      }
      if (candidates.length >= 32) break;
    }
    candidates.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return candidates.isEmpty ? null : candidates.first;
  }
}
