// Read-only diagnostics around the actual application and registered plugins.
// ignore_for_file: depend_on_referenced_packages, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/image_favorites.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/state_controller.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

import 'image_pipeline_022_task_storage.dart';

/// Diagnostic I/O changes timings: do not use this target for performance runs.
class ImagePipelineNormalUiObserver with WidgetsBindingObserver {
  ImagePipelineNormalUiObserver(this.storage);
  final ImagePipelineTaskStorage storage;
  Timer? _timer;
  Future<void> _writes = Future<void>.value();
  String? _lastState;
  String? _lastFavorites;
  bool _sampling = false;
  int _sequence = 0;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    unawaited(record('observer-start', {
      'version': 1,
      'scope': 'Actual PicaKeepApp state and real registered share plugin',
      'boundary':
          'State snapshots are not pixel, raster timing or receiver proof',
    }));
    _timer =
        Timer.periodic(const Duration(seconds: 1), (_) => unawaited(sample()));
    SharePlatform.instance = TaskNativeShareAudit(SharePlatform.instance, this);
  }

  /// Audit failures are retained on stdout but never alter product behavior.
  Future<void> record(String event, Map<String, Object?> values) {
    final line = jsonEncode({
      'event': event,
      'sequence': ++_sequence,
      'utc': DateTime.now().toUtc().toIso8601String(),
      ...values,
    });
    stdout.writeln('PICAKEEP_022_NORMAL_UI_AUDIT $line');
    final write = _writes.then((_) async {
      final file = File(p.join(storage.root, 'normal-ui-audit.jsonl'));
      await storage.checkPath(file.path);
      await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
    });
    _writes = write.catchError((Object error) {
      stdout.writeln('PICAKEEP_022_NORMAL_UI_AUDIT_WRITE_ERROR $error');
    });
    return _writes;
  }

  Future<Map<String, Object?>> fileEvidence(File file) async {
    await storage.checkPath(file.path);
    final before = await file.stat();
    final digest = (await sha256.bind(file.openRead()).first).toString();
    final after = await file.stat();
    return {
      'path': file.path,
      'bytes': before.size,
      'sha256': digest,
      'sourceStable': before.size == after.size &&
          before.modified == after.modified &&
          before.changed == after.changed,
    };
  }

  Future<void> sample() async {
    if (_sampling) return;
    _sampling = true;
    try {
      final logic = StateController.findOrNull<ComicReadingPageLogic>();
      final surfaces = ReaderSurfaceDiagnostics.snapshot().map((surface) {
        final desired = surface['desired'] as List;
        final resident = surface['residentVariants'] as List;
        return {
          ...surface,
          'demandComplete':
              desired.isNotEmpty && desired.every(resident.contains)
        };
      }).toList();
      final state = <String, Object?>{
        'readerOpen': logic != null,
        'layout': appdata.settings[9],
        'pipelineSettings':
            appdata.settings.length > readerImagePipelineSettingIndex
                ? appdata.settings[readerImagePipelineSettingIndex]
                : null,
        if (logic != null) ...{
          'workId': logic.data.id,
          'sourceKey': logic.data.sourceKey,
          'chapter': logic.order,
          'page': logic.index,
          'pageCount': logic.urls.length,
          'isLoading': logic.isLoading,
          'nativePixelScales': {
            for (final entry in logic.nativePixelScales.entries)
              '${entry.key}': entry.value,
          },
          'controllers': {
            for (final entry in logic.photoViewControllers.entries)
              '${entry.key}': {
                'scale': entry.value.scale,
                'x': entry.value.position.dx,
                'y': entry.value.position.dy,
              },
          },
        },
        'surfaces': surfaces,
        'resources': {
          'activeSurfaces': ReaderSurfaceDiagnostics.activeSurfaces,
          'residentBytes': ReaderSurfaceDiagnostics.residentBytes,
          'pendingBytes': ReaderSurfaceDiagnostics.pendingBytes,
          'jobs': ImageWorkScheduler.shared.pendingCount,
          'workBytes': ImageWorkScheduler.shared.reservedBytes,
          'leases': ReaderPageFileLease.activeLeaseCount,
          'temporaryBytes': ImageTemporaryPool.shared.reservedBytes,
          'diskClaims': ImageDiskQuota.shared.pendingCount,
          'diskActiveBytes': ImageDiskQuota.shared.activeBytes,
        },
      };
      final stamp = jsonEncode(state);
      if (stamp != _lastState) {
        _lastState = stamp;
        await record('reader-state', state);
      }
      // Deferred application startup may not have opened HistoryManager yet.
      List<ImageFavorite> favorites;
      try {
        favorites = ImageFavoriteManager.getAll();
      } catch (_) {
        return;
      }
      final metadata = [
        for (final favorite in favorites)
          {
            'id': favorite.id,
            'title': favorite.title,
            'chapter': favorite.ep,
            'page': favorite.page,
            'path': favorite.imagePath,
            'otherInfo': favorite.otherInfo,
          },
      ];
      final favoritesStamp = jsonEncode(metadata);
      if (favoritesStamp != _lastFavorites) {
        _lastFavorites = favoritesStamp;
        final files = <Map<String, Object?>>[];
        for (final favorite in favorites) {
          try {
            files.add(await fileEvidence(File(favorite.imagePath)));
          } catch (error) {
            files.add({'path': favorite.imagePath, 'auditError': '$error'});
          }
        }
        await record('favorites-state', {'records': metadata, 'files': files});
      }
    } catch (error) {
      await record('observer-error', {'error': '$error'});
    } finally {
      _sampling = false;
    }
  }

  @override
  void didHaveMemoryPressure() {
    unawaited(record('os-memory-pressure', {
      'readerOpen': StateController.findOrNull<ComicReadingPageLogic>() != null,
      'surfaces': ReaderSurfaceDiagnostics.snapshot(),
      'residentBytes': ReaderSurfaceDiagnostics.residentBytes,
      'pendingBytes': ReaderSurfaceDiagnostics.pendingBytes,
      'jobs': ImageWorkScheduler.shared.pendingCount,
      'workBytes': ImageWorkScheduler.shared.reservedBytes,
      'leases': ReaderPageFileLease.activeLeaseCount,
      'boundary': 'Received from WidgetsBinding; no synthetic callback invoked',
    }).then((_) => sample()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(record('app-lifecycle', {'state': state.name}));
    if (state == AppLifecycleState.detached) {
      _timer?.cancel();
      WidgetsBinding.instance.removeObserver(this);
    }
  }
}

/// Every method forwards to the already registered implementation. No mock
/// channel, fabricated result, receiver, or copied share output is installed.
class TaskNativeShareAudit extends SharePlatform {
  TaskNativeShareAudit(this.delegate, this.observer);
  final SharePlatform delegate;
  final ImagePipelineNormalUiObserver observer;

  @override
  Future<ShareResult> shareXFiles(List<XFile> files,
      {String? subject, String? text, Rect? sharePositionOrigin}) async {
    final evidence = <Map<String, Object?>>[];
    for (final file in files) {
      try {
        evidence.add({
          ...await observer.fileEvidence(File(file.path)),
          'mime': file.mimeType
        });
      } catch (error) {
        evidence.add({'path': file.path, 'auditError': '$error'});
      }
    }
    await observer.record('native-share-start', {'files': evidence});
    try {
      final result = await delegate.shareXFiles(files,
          subject: subject,
          text: text,
          sharePositionOrigin: sharePositionOrigin);
      await observer.record('native-share-return', {
        'status': result.status.name,
        'raw': result.raw,
        'boundary': 'Native return; receiver bytes were not captured',
      });
      return result;
    } catch (error) {
      await observer.record('native-share-error', {'error': '$error'});
      rethrow;
    }
  }

  @override
  Future<void> shareUri(Uri uri, {Rect? sharePositionOrigin}) =>
      delegate.shareUri(uri, sharePositionOrigin: sharePositionOrigin);
  @override
  Future<void> share(String text,
          {String? subject, Rect? sharePositionOrigin}) =>
      delegate.share(text,
          subject: subject, sharePositionOrigin: sharePositionOrigin);
  @override
  Future<ShareResult> shareWithResult(String text,
          {String? subject, Rect? sharePositionOrigin}) =>
      delegate.shareWithResult(text,
          subject: subject, sharePositionOrigin: sharePositionOrigin);
  @override
  Future<void> shareFiles(List<String> paths,
          {List<String>? mimeTypes,
          String? subject,
          String? text,
          Rect? sharePositionOrigin}) =>
      delegate.shareFiles(paths,
          mimeTypes: mimeTypes,
          subject: subject,
          text: text,
          sharePositionOrigin: sharePositionOrigin);
  @override
  Future<ShareResult> shareFilesWithResult(List<String> paths,
          {List<String>? mimeTypes,
          String? subject,
          String? text,
          Rect? sharePositionOrigin}) =>
      delegate.shareFilesWithResult(paths,
          mimeTypes: mimeTypes,
          subject: subject,
          text: text,
          sharePositionOrigin: sharePositionOrigin);
}
