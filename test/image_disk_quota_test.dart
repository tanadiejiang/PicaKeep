import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'dart:async';

void main() {
  late Directory root;
  late ImageDiskQuota quota;
  var available = 1000000;
  final leased = <String>{};
  setUp(() async {
    final parent = Platform.isWindows
        ? Directory(r'E:\picakeep-image-pipeline-022-runtime')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    root = await parent.createTemp('disk-quota-');
    available = 1000000;
    leased.clear();
    quota = ImageDiskQuota(
        roots: () => [root.path],
        idleLimitBytes: () => 40000,
        maximumActiveBytes: 120000,
        headroomBytes: 10000,
        protected: leased.contains,
        space: (path) async => ImageDiskSpace(
            available, path.contains('other-volume') ? 'other' : 'task'));
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('same-volume unwritten promises preserve headroom and recover',
      () async {
    available = 70000;
    final first = await quota.admitWorkspace(p.join(root.path, 'a.raw'),
        peakBytes: 40000);
    await expectLater(
        quota.admitWorkspace(p.join(root.path, 'b.raw'), peakBytes: 30000),
        throwsA(isA<ImageDiskQuotaExceeded>()));
    expect(quota.pendingCount, 1);
    await first.abort();
    final recovered = await quota.admitWorkspace(p.join(root.path, 'b.raw'),
        peakBytes: 30000);
    await recovered.abort();
    expect(quota.activeBytes, 0);
  });

  test('materialized bytes are not subtracted twice from physical free',
      () async {
    available = 70000;
    final path = p.join(root.path, 'a.raw');
    final first = await quota.admitWorkspace(path, peakBytes: 40000);
    await File(path).writeAsBytes(List.filled(40000, 1));
    available = 30000;
    await first.finishWorkspace();
    final second = await quota.admitWorkspace(p.join(root.path, 'b.raw'),
        peakBytes: 10000);
    expect(quota.activeBytes, 50000);
    await second.abort();
    await first.abort();
  });

  test(
      'claims on a different physical volume do not consume its free-space promises',
      () async {
    available = 70000;
    final first = await quota.admitWorkspace(p.join(root.path, 'a.raw'),
        peakBytes: 50000);
    final second = await quota.admitWorkspace(
        p.join(root.path, 'other-volume.raw'),
        peakBytes: 50000);
    expect(quota.activeBytes, 100000);
    await first.abort();
    await second.abort();
  });

  test(
      'two active backings may exceed idle cap; last release immediately trims unleased files',
      () async {
    final a = p.join(root.path, 'a.raw'), b = p.join(root.path, 'b.raw');
    final first = await quota.admitWorkspace(a, peakBytes: 30000);
    final second = await quota.admitWorkspace(b, peakBytes: 30000);
    await File(a).writeAsBytes(List.filled(30000, 1));
    await File(b).writeAsBytes(List.filled(30000, 1));
    await first.finishWorkspace();
    await second.finishWorkspace();
    expect(quota.activeBytes, 60000);
    expect(quota.idleBytes, 0);
    await first.abort();
    expect(await File(b).exists(), isTrue);
    await second.abort();
    expect(quota.idleBytes, lessThanOrEqualTo(40000));
  });

  test(
      'persistent admission evicts owned idle cache before writing; leased original remains',
      () async {
    final original = await File(p.join(root.path, 'original.img'))
        .writeAsBytes(List.filled(30000, 1));
    leased.add(original.path.toLowerCase());
    await expectLater(
        quota.admitPublication(p.join(root.path, 'new.png'),
            maximumBytes: 10000),
        throwsA(isA<ImageDiskQuotaExceeded>()));
    expect(await original.exists(), isTrue);
    expect(quota.pendingCount, 0);
  });

  test('space-query failure is explicit, without reading or writing a source',
      () async {
    final denied = ImageDiskQuota(
        roots: () => [root.path],
        idleLimitBytes: () => 50000,
        space: (_) async => throw UnsupportedError('unknown'));
    await expectLater(
        denied.admitWorkspace(p.join(root.path, 'a.raw'), peakBytes: 100),
        throwsA(isA<ImageDiskQuotaExceeded>()));
    expect(denied.rejectedCount, 1);
    expect(denied.pendingCount, 0);
    expect(await root.list().isEmpty, isTrue);
  });

  test('Android emulated and data aliases share all unwritten promises',
      () async {
    final conservative = ImageDiskQuota(
        roots: () => [root.path],
        idleLimitBytes: () => 40000,
        maximumActiveBytes: 120000,
        headroomBytes: 10000,
        sharePendingAcrossVolumes: true,
        space: (path) async => ImageDiskSpace(70000,
            path.contains('emulated') ? 'posix-dev:33' : 'posix-dev:66322'));
    final first = await conservative
        .admitWorkspace(p.join(root.path, 'data.raw'), peakBytes: 40000);
    await expectLater(
        conservative.admitWorkspace(p.join(root.path, 'emulated.raw'),
            peakBytes: 30000),
        throwsA(isA<ImageDiskQuotaExceeded>()));
    await first.abort();
    final recovered = await conservative
        .admitWorkspace(p.join(root.path, 'emulated.raw'), peakBytes: 30000);
    await recovered.abort();
    expect(conservative.pendingCount, 0);
  });

  test(
      'unknown protected-path registry cannot turn existing files into eviction candidates',
      () async {
    final cover = await File(p.join(root.path, 'manual-cover.png'))
        .writeAsBytes(List.filled(30000, 1));
    final failClosed = ImageDiskQuota(
        roots: () => [root.path],
        idleLimitBytes: () => 40000,
        maximumActiveBytes: 120000,
        headroomBytes: 1,
        additionalProtectedPaths: () async =>
            throw StateError('registry unavailable'),
        space: (_) async => const ImageDiskSpace(1000000, 'task'));
    await expectLater(
        failClosed.admitPublication(p.join(root.path, 'new.png'),
            maximumBytes: 10000),
        throwsA(isA<ImageDiskQuotaExceeded>()));
    expect(await cover.exists(), isTrue);
  });

  test('replacement admission includes old body and new part peak before IO',
      () async {
    final path = p.join(root.path, 'replaced.png');
    await File(path).writeAsBytes(List.filled(10000, 1));
    available = 37000;
    final ticket = await quota.admitPublication(path, maximumBytes: 10000);
    expect(ticket.maximumBytes, 36384);
    await ticket.abort();
    expect(quota.pendingCount, 0);
  });

  test('concurrent publishers cannot both spend the same idle quota', () async {
    final first = await quota.admitPublication(p.join(root.path, 'first.png'),
        maximumBytes: 10000);
    await expectLater(
        quota.admitPublication(p.join(root.path, 'second.png'),
            maximumBytes: 10000),
        throwsA(isA<ImageDiskQuotaExceeded>()));
    await first.abort();
    final second = await quota.admitPublication(p.join(root.path, 'second.png'),
        maximumBytes: 10000);
    await second.abort();
  });

  test(
      'a shared index is counted exactly without adopting or evicting siblings',
      () async {
    final cache = await Directory(p.join(root.path, 'cache')).create();
    final index = File(p.join(root.path, 'covers_index.json'));
    final manual = File(p.join(root.path, 'manual-cover.png'));
    await index.writeAsBytes(List.filled(5000, 1));
    await manual.writeAsBytes(List.filled(30000, 3));
    final managed = ImageDiskQuota(
        roots: () => [cache.path],
        idleLimitBytes: () => 40000,
        maximumActiveBytes: 120000,
        headroomBytes: 10000,
        space: (_) async => const ImageDiskSpace(1000000, 'task'));
    final ticket =
        await managed.admitManagedIndex(index.path, maximumBytes: 10000);
    expect(ticket.maximumBytes, 5000 + 10000 + 16 * 1024);
    await index.writeAsBytes(List.filled(10000, 2));
    await ticket.commit([index.path]);
    expect(managed.idleBytes, 10000);
    await expectLater(
        managed.admitManagedIndex(index.path, maximumBytes: 30000),
        throwsA(isA<ImageDiskQuotaExceeded>()));
    expect(await index.length(), 10000);
    expect(await manual.length(), 30000);
    expect(managed.pendingCount, 0);
    expect(await File('${index.path}.part').exists(), isFalse);
  });

  test(
      'a repeated live backing is one active claim but every owner must release',
      () async {
    final path = p.join(root.path, 'shared.raw');
    final first = await quota.admitWorkspace(path, peakBytes: 30000);
    final second = await quota.admitWorkspace(path, peakBytes: 30000);
    expect(quota.activeBytes, 30000);
    await File(path).writeAsBytes(List.filled(30000, 1));
    await first.finishWorkspace();
    await second.finishWorkspace();
    await first.abort();
    expect(quota.activeBytes, 30000);
    expect(await File(path).exists(), isTrue);
    await second.abort();
    expect(quota.activeBytes, 0);
  });
  test('leased warm backing survives denied replacement admission', () async {
    final path = p.join(root.path, 'original-pixels.raw');
    await File(path).writeAsBytes(List.filled(30000, 3));
    leased.add(path.toLowerCase());
    available = 15000;
    await expectLater(quota.admitWorkspace(path, peakBytes: 60000),
        throwsA(isA<ImageDiskQuotaExceeded>()));
    expect(await File(path).length(), 30000);
    expect(quota.activeBytes, 0);
  });

  test('root change while eviction awaits cannot delete from old task root',
      () async {
    var currentRoot = root.path;
    final old = await File(p.join(root.path, 'old.png'))
        .writeAsBytes(List.filled(30000, 1));
    final changed = ImageDiskQuota(
        roots: () => [currentRoot],
        idleLimitBytes: () => 40000,
        maximumActiveBytes: 120000,
        headroomBytes: 1,
        space: (_) async => const ImageDiskSpace(1000000, 'task'),
        protected: (_) {
          scheduleMicrotask(() => currentRoot = p.join(root.path, 'new-root'));
          return false;
        });
    await expectLater(
        changed.admitPublication(p.join(root.path, 'new.png'),
            maximumBytes: 20000),
        throwsA(isA<ImageDiskQuotaExceeded>()));
    expect(await old.exists(), isTrue);
  });

  test('live workspace protects existing backing from old global LRU',
      () async {
    final path = p.join(root.path, 'live.raw');
    await File(path).writeAsBytes(List.filled(30000, 1));
    final ticket = await quota.admitWorkspace(path, peakBytes: 30000);
    expect(DerivedImageStore.isPathLeased(path), isTrue);
    await ticket.abort();
    expect(DerivedImageStore.isPathLeased(path), isFalse);
  });
}
