import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:picakeep/foundation/image_pipeline/original_image_operations.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';

/// Explicit Android Root verification. It only reads the task fixture, writes
/// one byte-verified copy beneath the harness-owned cache, and removes it.
Future<Map<String, Object?>> runImagePipeline022PrivilegedCopyChecks(
    String fixturesPath, String managedCachePath) async {
  final report = <String, Object?>{
    'platform': Platform.operatingSystem,
    'source': null,
    'method': 'Android su stat + bounded app-managed copy',
  };
  if (!Platform.isAndroid) {
    report['status'] = 'androidDeviceRequired';
    return report;
  }

  const channel = MethodChannel('lingxue.picakeep/storage_access');
  File? destination;
  try {
    final rootAvailable = await channel.invokeMethod<bool>(
          'hasRootAccess',
          {'forceRefresh': true},
        ).timeout(const Duration(seconds: 10)) ??
        false;
    report['rootAvailable'] = rootAvailable;
    if (!rootAvailable) {
      report['status'] = 'rootUnavailable';
      return report;
    }

    final source = File('${Directory(fixturesPath).path}/8000x12000.png');
    if (!await source.exists()) {
      throw StateError('Synthetic PNG fixture missing');
    }
    final managedRoot = Directory(managedCachePath).absolute;
    await managedRoot.create(recursive: true);
    final managedCanonical = await managedRoot.resolveSymbolicLinks();
    destination = File(
        '$managedCanonical${Platform.pathSeparator}022-root-copy-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}.png');

    final stat = await channel.invokeMapMethod<String, Object?>(
      'statFileWithRoot',
      {'path': source.path},
    ).timeout(const Duration(seconds: 15));
    if (stat == null) throw StateError('Root stat did not resolve the fixture');
    final sourceLength = await source.length();
    if (stat['size'] != sourceLength || sourceLength <= 64 * 1024) {
      throw StateError(
          'Root stat size mismatched or did not exercise chunked copy');
    }
    final sourceHash = await originalImageDigest(source);
    final requestId =
        'image-pipeline-022-${DateTime.now().microsecondsSinceEpoch}';
    final copiedBytes = await channel.invokeMethod<int>(
      'copyFileToManagedWithRoot',
      {
        'path': source.path,
        'destination': destination.path,
        'maxBytes': sourceLength,
        'requestId': requestId,
      },
    ).timeout(const Duration(seconds: 60));
    if (copiedBytes != sourceLength || !await destination.exists()) {
      throw StateError('Root copy returned a different byte length');
    }
    final copiedHash = await originalImageDigest(destination);
    final header = await destination
        .openRead(0, min(32, sourceLength))
        .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
    final type = readerPageTypeFromHeader(Uint8List.fromList(header));
    await destination.delete();
    var boundRejected = false;
    try {
      await channel.invokeMethod<int>(
        'copyFileToManagedWithRoot',
        {
          'path': source.path,
          'destination': destination.path,
          'maxBytes': sourceLength - 1,
          'requestId': '$requestId-bound',
        },
      ).timeout(const Duration(seconds: 60));
    } on PlatformException {
      boundRejected = !await destination.exists();
    }
    report.addAll({
      'source': source.path,
      'sourceBytes': sourceLength,
      'rootStatBytes': stat['size'],
      'copiedBytes': copiedBytes,
      'sourceSha256': sourceHash,
      'copySha256': copiedHash,
      'exactBytes': sourceHash == copiedHash && copiedBytes == sourceLength,
      'detectedExtension': type.extension,
      'detectedMimeType': type.mime,
      'nativeBoundRejectedAndPartialCleaned': boundRejected,
      'status': sourceHash == copiedHash &&
              copiedBytes == sourceLength &&
              type.extension == '.png' &&
              boundRejected
          ? 'measured'
          : 'originalMismatch',
    });
  } catch (error) {
    report['status'] = 'error';
    report['error'] = error.toString();
  } finally {
    if (destination != null) {
      try {
        if (await destination.exists()) await destination.delete();
        report['managedCopyCleaned'] = !await destination.exists();
      } catch (error) {
        report['managedCopyCleaned'] = false;
        report['cleanupError'] = error.toString();
        report['status'] = 'cleanupError';
      }
    }
  }
  return report;
}
