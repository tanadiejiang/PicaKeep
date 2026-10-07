import 'dart:io';

import 'package:flutter/services.dart';
import 'package:picakeep/foundation/image_pipeline/original_image_operations.dart';
import 'package:picakeep/tools/android_original_gallery.dart';

/// Call only from the authorized independent verification run. Successful
/// synthetic export is retained; this checks its own URI and never scans albums.
Future<Map<String, Object?>> runImagePipeline022OriginalExportChecks(
  String fixturesPath,
) async {
  final report = <String, Object?>{'platform': Platform.operatingSystem};
  if (!Platform.isAndroid) {
    report['status'] = 'androidDeviceRequired';
    return report;
  }
  const channel = MethodChannel('lingxue.picakeep/storage_access');
  try {
    print('PICAKEEP_022_ORIGINAL_EXPORT capability-status-start');
    report['shizukuStatus'] = await channel.invokeMapMethod<String, Object?>(
      'getShizukuStatus',
      {'forceRefresh': true},
    ).timeout(const Duration(seconds: 10));
    report['rootAccess'] = await channel.invokeMethod<bool>(
      'hasRootAccess',
      {'forceRefresh': true},
    ).timeout(const Duration(seconds: 10));
  } catch (error) {
    report['capabilityCheckError'] = error.toString();
  }
  final original = File('${Directory(fixturesPath).path}/640x960.png');
  report['syntheticSource'] = original.path;
  try {
    if (!await original.exists()) throw StateError('Synthetic fixture missing');
    final hashBefore = await originalImageDigest(original);
    final bytesBefore = await original.length();
    print('PICAKEEP_022_ORIGINAL_EXPORT source-hash-ready bytes=$bytesBefore');
    final saved = await saveAndroidOriginalToGallery(original)
        .timeout(const Duration(seconds: 30));
    final hashAfter = await originalImageDigest(original);
    report.addAll(saved);
    report['fixtureSha256Before'] = hashBefore;
    report['fixtureSha256After'] = hashAfter;
    report['verifiedOnlyReturnedUri'] = true;
    report['testGalleryItemRetained'] = true;
    report['status'] = hashBefore == hashAfter &&
            hashBefore == saved['savedSha256'] &&
            bytesBefore == saved['savedBytes']
        ? 'measured'
        : 'originalByteHashMismatch';
    print('PICAKEEP_022_ORIGINAL_EXPORT finished status=${report['status']}');
  } catch (error) {
    report['status'] = 'error';
    report['error'] = error.toString();
    print('PICAKEEP_022_ORIGINAL_EXPORT error=$error');
  }
  return report;
}
