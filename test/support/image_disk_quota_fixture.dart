import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';

// Disk admission is exercised separately with real OS queries and pressure
// cases. Codec/cache unit tests explicitly supply a deterministic task volume.
ImageDiskQuota installTaskDiskQuota(List<String> Function() roots) {
  final quota = ImageDiskQuota(
      roots: roots,
      idleLimitBytes: () => 500 << 20,
      space: (_) async => const ImageDiskSpace(16 << 30, 'test-volume'));
  ImageDiskQuota.overrideForTesting = quota;
  return quota;
}
