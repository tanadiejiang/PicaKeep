import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_gallery_saver/flutter_image_gallery_saver.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/image_pipeline/original_image_operations.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/privileged_storage_access.dart';
import 'package:picakeep/tools/translations.dart';
import 'android_original_gallery.dart';
import 'package:share_plus/share_plus.dart';

void _toast(String message) {
  final c = App.globalContext;
  if (c == null) return;
  ScaffoldMessenger.maybeOf(c)?.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
  );
}

String _fileNameFromPath(String path) {
  final i = path.replaceAll('\\', '/').lastIndexOf('/');
  return i >= 0 ? path.substring(i + 1) : path;
}

class _TypedOriginalCopy {
  _TypedOriginalCopy(
      this.file, this.directory, this.reservation, this.releaseSource);
  final File file;
  final Directory directory;
  final ImageTemporaryReservation reservation;
  final void Function() releaseSource;

  static Future<_TypedOriginalCopy> prepare(File original, String name) async {
    final releaseSource = ReaderPageFileLease.acquire(original);
    ImageTemporaryReservation? reservation;
    Directory? directory;
    try {
      final before = await original.stat();
      if (before.type != FileSystemEntityType.file || before.size <= 0) {
        throw StateError('Original file is unavailable for export');
      }
      directory =
          await Directory.systemTemp.createTemp('picakeep-original-export-');
      final target = File('${directory.path}/$name');
      reservation = await ImageTemporaryPool.shared.reserveOnDisk(before.size,
          purpose: 'original-export-type', path: target.path);
      final copied = await PrivilegedStorageAccess.copyFileToManagedFile(
          original.path, target,
          maxBytes: before.size);
      final after = await original.stat();
      if (await copied.length() != before.size ||
          after.size != before.size ||
          after.modified != before.modified) {
        throw StateError('Original file changed during export preparation');
      }
      return _TypedOriginalCopy(copied, directory, reservation, releaseSource);
    } catch (_) {
      try {
        if (directory != null && await directory.exists()) {
          await directory.delete(recursive: true);
        }
      } finally {
        reservation?.release();
        releaseSource();
      }
      rethrow;
    }
  }

  Future<void> dispose() async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } finally {
      reservation.release();
      releaseSource();
    }
  }
}

/// Save current image to gallery (mobile) or user-chosen path (desktop).
Future<void> saveImage(File file) async {
  final type = await originalImageType(file);
  var fileName = _fileNameFromPath(file.path);
  fileName = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '') + type.extension;
  if (App.isAndroid) {
    await saveAndroidOriginalToGallery(file);
    _toast("已保存".tl);
  } else if (App.isIOS) {
    final imageSaver = ImageGallerySaver();
    _TypedOriginalCopy? prepared;
    try {
      // Keep the existing iOS file-save implementation. Android uses its
      // original-byte MediaStore bridge with integrity verification above.
      if (!file.path.toLowerCase().endsWith(type.extension)) {
        prepared = await _TypedOriginalCopy.prepare(file, fileName);
      }
      await imageSaver.saveFile((prepared?.file ?? file).path);
    } finally {
      await prepared?.dispose();
    }
    _toast("已保存".tl);
  } else if (App.isDesktop) {
    try {
      final path = (await getSaveLocation(suggestedName: fileName))?.path;
      if (path != null) {
        await file.copy(path);
        _toast("已保存".tl);
      }
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Save Image", "$e\n$s");
    }
  }
}

Future<String> persistentCurrentImage(File file,
    {ReaderPageIdentity? identity}) async {
  final dir = Directory("${App.dataPath}/images");
  final persisted = await persistOriginalImage(file,
      directory: dir,
      identity: identity ??
          ReaderPageIdentity(
              sourceKey: 'legacy-local',
              workId: file.path,
              downloadId: '',
              episode: 0,
              page: 0,
              sourceVersion: 'file'));
  return persisted.path;
}

Future<void> shareImage(File file) async {
  final type = await originalImageType(file);
  _TypedOriginalCopy? prepared;
  try {
    if (!file.path.toLowerCase().endsWith(type.extension)) {
      prepared =
          await _TypedOriginalCopy.prepare(file, 'image${type.extension}');
    }
    await Share.shareXFiles(
        [XFile((prepared?.file ?? file).path, mimeType: type.mime)]);
  } finally {
    await prepared?.dispose();
  }
}
