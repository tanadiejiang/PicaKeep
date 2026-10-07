import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/cache_file_inventory.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';

void main() {
  late Directory root;
  final held = <void Function()>[];

  Future<File> file(String relative, int bytes, int year) async {
    final value = File(p.join(root.path, relative));
    await value.parent.create(recursive: true);
    await value.writeAsBytes(List.filled(bytes, 1), flush: true);
    await value.setLastModified(DateTime(year));
    return value;
  }

  ImageDiskQuota quota(int limit,
          {List<String>? roots,
          Future<Set<String>> Function()? additionalProtectedPaths}) =>
      ImageDiskQuota(
          roots: () => roots ?? [root.path],
          idleLimitBytes: () => limit,
          headroomBytes: 1,
          space: (_) async => const ImageDiskSpace(1 << 30, 'fixture-volume'),
          additionalProtectedPaths: additionalProtectedPaths);

  Future<void> trim(ImageDiskQuota value,
      {int expectedPendingCount = 0}) async {
    // Workspace release is the same maintenance trigger as finishing a native
    // decode. No persistent-publication overhead obscures the eviction order.
    final claim = await value.admitWorkspace(p.join(root.path, 'trigger.rgba'),
        peakBytes: 1);
    await claim.abort();
    expect(value.pendingCount, expectedPendingCount);
  }

  setUp(() async {
    final parent = Platform.isWindows
        ? Directory(r'D:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    root = await parent.createTemp('quota-cover-retention-');
  });
  tearDown(() async {
    for (final release in held) {
      release();
    }
    held.clear();
    if (await root.exists()) await root.delete(recursive: true);
  });

  for (final backingDirectory in ['native_backing', 'cover_backing']) {
    test('new inactive $backingDirectory is evicted before old cover',
        () async {
      final cover = await file(p.join('covers', 'old.jpg'), 100, 2001);
      final backing = await file(
          p.join('cache', 'image_pipeline', backingDirectory, 'new.rgba'),
          100,
          2002);
      final inventory = await scanCacheFiles([root.path]);
      expect(p.equals(inventory.files.first.path, cover.path), isTrue,
          reason: 'plain modification-time LRU used to evict this cover first');
      final value = quota(100);
      await trim(value);
      expect(await cover.exists(), isTrue);
      expect(await backing.exists(), isFalse,
          reason: 'inactive decoded scratch yields the shared quota first');
      expect(value.idleBytes, 100);
    });
  }

  test('scratch directory ranking uses complete path components', () async {
    final cover = await file(p.join('covers', 'old.jpg'), 100, 2001);
    final similarDirectory = await file(
        p.join('cache', 'native_backing_backup', 'sample.rgba'), 100, 2002);
    final similarFile =
        await file(p.join('cache', 'native_backing'), 100, 2003);
    final backing =
        await file(p.join('cache', 'cover_backing', 'new.rgba'), 100, 2004);
    final value = quota(300);
    await trim(value);
    expect(await backing.exists(), isFalse);
    expect(await cover.exists(), isTrue);
    expect(await similarDirectory.exists(), isTrue);
    expect(await similarFile.exists(), isTrue,
        reason: 'a filename is not a backing directory component');
    expect(value.idleBytes, 300);
  });

  test('active and leased backings retain their existing deletion protection',
      () async {
    final cover = await file(p.join('covers', 'old.jpg'), 100, 2001);
    final active =
        await file(p.join('cache', 'native_backing', 'active.rgba'), 100, 2002);
    final leased =
        await file(p.join('cache', 'cover_backing', 'leased.rgba'), 100, 2003);
    held.add(DerivedImageStore.protectTemporaryPath(leased.path));
    final value = quota(100);
    final activeClaim = await value.admitWorkspace(active.path, peakBytes: 100);
    try {
      await activeClaim.finishWorkspace();
      await trim(value, expectedPendingCount: 1);
      expect(await active.exists(), isTrue,
          reason: 'active backing cannot be a scratch eviction victim');
      expect(await leased.exists(), isTrue,
          reason: 'an image consumer lease still protects a backing');
      expect(await cover.exists(), isFalse,
          reason:
              'the user limit still applies when preferred victims are busy');
      expect(value.idleBytes, 100);
    } finally {
      await activeClaim.abort();
    }
    expect(await leased.exists(), isTrue);
    expect(value.pendingCount, 0);
  });

  test('remaining pressure still evicts covers after inactive scratch',
      () async {
    final cover = await file(p.join('covers', 'old.jpg'), 100, 2001);
    final backing =
        await file(p.join('cache', 'native_backing', 'new.rgba'), 100, 2002);
    final value = quota(50);
    await trim(value);
    expect(await backing.exists(), isFalse);
    expect(await cover.exists(), isFalse,
        reason: 'cover preference is not an exemption from the user cache cap');
    expect(value.idleBytes, lessThanOrEqualTo(50));
  });

  test('registry-protected covers and external files remain untouched',
      () async {
    final owned = await Directory(p.join(root.path, 'owned')).create();
    final cover =
        await file(p.join('owned', 'covers', 'manual.jpg'), 100, 2001);
    final backing = await file(
        p.join('owned', 'cache', 'native_backing', 'new.rgba'), 100, 2002);
    final external = await file(
        p.join('external', 'native_backing', 'original.rgba'), 100, 2000);
    final value = quota(100,
        roots: [owned.path],
        additionalProtectedPaths: () async => {cover.path});
    // The trigger path is an external workspace. Admission does not grant it
    // deletion ownership and the owned inventory remains the only victim pool.
    await trim(value);
    expect(await backing.exists(), isFalse);
    expect(await cover.exists(), isTrue);
    expect(await external.exists(), isTrue,
        reason: 'matching a directory name grants no ownership of its files');
    expect(value.idleBytes, 100);
  });
}
