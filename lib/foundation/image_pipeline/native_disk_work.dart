import 'dart:io';
import 'dart:math' as math;

import 'package:picakeep_image_engine/picakeep_image_engine.dart';

import 'derived_image_store.dart';
import 'image_disk_quota.dart';
import 'native_image_disk_plan.dart';

/// Native disk checks remain a final guard. Admission precedes its first write,
/// while source/backing leases remain until the native operation actually ends.
Future<T> withNativeDiskWork<T>(File source, String backingPath,
    {required Future<T> Function(int diskBudgetBytes) run,
    NativeImageRect? region,
    int? outputWidth,
    int? outputHeight,
    bool prepare = false}) async {
  final plan = await NativeImageDiskPlan.inspect(source,
      backingPath: backingPath,
      region: region,
      outputWidth: outputWidth,
      outputHeight: outputHeight,
      prepare: prepare);
  if (plan.additionalBytes == 0) return run(plan.nativeDiskBudgetBytes);
  final backing = File(backingPath);
  final oldBytes = await backing.exists() ? await backing.length() : 0;
  final peak = oldBytes + plan.additionalBytes;
  final temporary = ImageTemporaryPool.shared.reserve(
      math.max(1, plan.additionalBytes),
      purpose: 'native-codec-workspace');
  if (temporary == null) {
    throw ImageDiskQuotaExceeded(
        '原生工作区额度不足',
        peak,
        ImageTemporaryPool.shared.maximumBytes -
            ImageTemporaryPool.shared.reservedBytes);
  }
  ImageDiskReservation? disk;
  final release = DerivedImageStore.protectTemporaryPath(backingPath);
  try {
    disk = await ImageDiskQuota.shared
        .admitWorkspace(backingPath, peakBytes: peak);
    final result = await run(plan.nativeDiskBudgetBytes);
    await disk.finishWorkspace();
    return result;
  } finally {
    // Keep the backing protected through transfer from active to idle quota.
    release();
    await disk?.abort();
    temporary.release();
    DerivedImageStore.scheduleMaintenance(backingPath);
  }
}
