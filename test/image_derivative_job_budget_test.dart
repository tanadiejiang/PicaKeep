import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_derivative_renderer.dart';
import 'package:picakeep/foundation/image_pipeline/image_derivative_service.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'support/image_disk_quota_fixture.dart';

class _BudgetCheckingRenderer implements ImageDerivativeRenderer {
  int minimumWorkingBytes = 0;
  int? receivedBudget;
  @override
  bool get supportsLargeRegions => false;
  @override
  Future<ImageDerivativeProbe> probe(String path) async =>
      const ImageDerivativeProbe(width: 8, height: 8);
  @override
  Future<ImageDerivativeRaster> render(String path,
      {required ImageDerivativeRect region,
      required int width,
      required int height,
      required String format,
      required String backingPath,
      required bool Function() isCancelled,
      int? jobBudgetBytes}) async {
    receivedBudget = jobBudgetBytes;
    if (jobBudgetBytes == null || minimumWorkingBytes > jobBudgetBytes) {
      throw StateError('Changed source needs more memory than this job owns');
    }
    return ImageDerivativeRaster(
        bytes: Uint8List.fromList([1, 2, 3]),
        width: width,
        height: height,
        mimeType: 'image/png',
        lossless: true);
  }
}

void main() {
  tearDown(() => ImageDiskQuota.overrideForTesting = null);
  test(
      'same-process server cannot fit aggregate memory: preparation fails explicitly and leaves no poll job',
      () async {
    final parent = Platform.isWindows
        ? Directory(r'E:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    final directory = await parent.createTemp('derivative-network-budget-');
    installTaskDiskQuota(() => [directory.path]);
    final store = DerivedImageStore(directory.path);
    final renderer = _BudgetCheckingRenderer();
    final scheduler = ImageWorkScheduler(memoryBudgetBytes: 1000);
    final service = ImageDerivativeService(
        store: store,
        renderer: renderer,
        scheduler: scheduler,
        responseWait: const Duration(milliseconds: 100));
    const key = DerivedImageKey(
        namespace: 'server-page',
        resourceId: '1',
        sourceVersion: 'v1',
        usage: DerivedImageUsage.readerTile,
        variant: 'network-budget');
    try {
      final caller = scheduler.submit<ImageDerivativePreparation>(
          key: 'http-consumer',
          lane: ImageWorkLane.network,
          priority: ImageWorkPriority.visible,
          estimatedBytes: 600,
          run: (_) => service.prepare(
              sourcePath: 'source.png',
              key: key,
              region: const ImageDerivativeRect(0, 0, 1, 1),
              width: 1,
              height: 1,
              format: 'png',
              estimatedWorkingBytes: 500,
              isSourceCurrent: () async => true));
      final response = await caller.future;
      expect(response.error, isA<ImageWorkBudgetExceeded>());
      expect(response.isPreparing, isFalse);
      expect(renderer.receivedBudget, isNull,
          reason: 'never execute an unreserved native image request');
      await Future<void>.delayed(Duration.zero);
      expect(service.pendingCount, 0);
      expect(scheduler.reservedBytes, 0);
      expect(scheduler.activeCount, 0);
    } finally {
      service.dispose();
      store.dispose();
      await directory.delete(recursive: true);
    }
  });
  test(
      'changed source cannot use shared total memory beyond its own reservation',
      () async {
    final parent = Platform.isWindows
        ? Directory(r'E:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    final directory = await parent.createTemp('derivative-job-budget-');
    installTaskDiskQuota(() => [directory.path]);
    final store = DerivedImageStore(directory.path);
    final renderer = _BudgetCheckingRenderer();
    final scheduler = ImageWorkScheduler(memoryBudgetBytes: 1 << 30);
    final service = ImageDerivativeService(
        store: store,
        renderer: renderer,
        scheduler: scheduler,
        responseWait: const Duration(seconds: 5));
    const key = DerivedImageKey(
        namespace: 'server-page',
        resourceId: '1:0:0',
        sourceVersion: 'source-1',
        usage: DerivedImageUsage.readerTile,
        variant: '0:0:0:png');
    const estimate = 32 << 20;
    try {
      renderer.minimumWorkingBytes = 64 << 20;
      final rejected = await service.prepare(
          sourcePath: 'changing-source.png',
          key: key,
          region: const ImageDerivativeRect(0, 0, 8, 8),
          width: 8,
          height: 8,
          format: 'png',
          estimatedWorkingBytes: estimate,
          isSourceCurrent: () async => true);
      expect(renderer.receivedBudget, estimate + 8 * 8 * 4);
      expect(rejected.error, isA<StateError>());
      expect(await store.lookup(key), isNull);
      expect(scheduler.reservedBytes, 0);
      renderer.minimumWorkingBytes = estimate;
      final ready = await service.prepare(
          sourcePath: 'changing-source.png',
          key: key,
          region: const ImageDerivativeRect(0, 0, 8, 8),
          width: 8,
          height: 8,
          format: 'png',
          estimatedWorkingBytes: estimate,
          isSourceCurrent: () async => true);
      expect(ready.entry, isNotNull);
      expect(scheduler.reservedBytes, 0);
    } finally {
      service.dispose();
      await directory.delete(recursive: true);
    }
  });
}
