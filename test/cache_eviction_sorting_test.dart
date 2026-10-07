import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/cache_file_inventory.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';

void main() {
  late Directory root;
  setUp(() async {
    final parent = Platform.isWindows
        ? Directory(r'D:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    root = await parent.createTemp('cache-eviction-order-');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> file(String name, int bytes, int year) async {
    final result = File(p.join(root.path, name));
    await result.parent.create(recursive: true);
    await result.writeAsBytes(List.filled(bytes, 1));
    await result.setLastModified(DateTime(year));
    return result;
  }

  ImageDiskQuota quota({
    required int limit,
    required CacheEvictionSorter sorter,
    List<String> Function()? roots,
    bool Function(String)? protected,
  }) =>
      ImageDiskQuota(
        roots: roots ?? () => [root.path],
        idleLimitBytes: () => limit,
        maximumActiveBytes: 120000,
        headroomBytes: 1,
        sortCandidates: sorter,
        protected: protected ?? (_) => false,
        space: (_) async => const ImageDiskSpace(1000000, 'test-volume'),
      );

  test('worker ranks exact scratch directories and preserves input ordering',
      () async {
    final old = DateTime(2000), recent = DateTime(2001);
    CacheFileSnapshot snapshot(String name, DateTime stamp) =>
        CacheFileSnapshot(p.join(root.path, name), 1, stamp, stamp);
    final cover = snapshot('covers/old.jpg', old);
    final similar = snapshot('native_backing_backup/new.rgba', recent);
    final filename = snapshot('cache/native_backing', DateTime(2002));
    final scratch = snapshot('cache/COVER_BACKING/new.rgba', recent);
    final input = [filename, scratch, similar, cover];
    var callerMicrotaskRan = false;
    final ordered = sortCacheEvictionCandidates(input);
    scheduleMicrotask(() => callerMicrotaskRan = true);
    final result = await ordered;
    expect(callerMicrotaskRan, isTrue);
    expect(result.map((value) => value.path),
        [scratch.path, cover.path, similar.path, filename.path]);
    expect(input.map((value) => value.path),
        [filename.path, scratch.path, similar.path, cover.path]);
  });

  test('under-limit general maintenance skips ordering entirely', () async {
    final existing = await file('covers/old.jpg', 100, 2000);
    final inventory = await scanCacheFiles([root.path]);
    await trimCacheInventory(inventory,
        limitBytes: 100,
        isCurrent: () => true,
        isProtected: (_) => false,
        sortCandidates: (_) => throw StateError('unnecessary cache sort'));
    expect(await existing.exists(), isTrue);
  });

  test('under-limit admission, publication and abort never order the cache',
      () async {
    final existing = await file('covers/old.jpg', 10000, 2000);
    final value = quota(
        limit: 40000,
        sorter: (_) => throw StateError('unnecessary cache sort'));
    final workspace = await value
        .admitWorkspace(p.join(root.path, 'temporary.rgba'), peakBytes: 10);
    await workspace.abort();
    final destination = p.join(root.path, 'new.png');
    final published =
        await value.admitPublication(destination, maximumBytes: 1000);
    await File(destination).writeAsBytes(List.filled(1000, 2));
    await published.commit([destination]);
    final unused = await value.admitPublication(p.join(root.path, 'unused.png'),
        maximumBytes: 1000);
    await unused.abort();
    expect(await existing.exists(), isTrue);
    expect(value.idleBytes, 11000);
    expect(value.pendingCount, 0);
  });

  for (final changeRoot in [false, true]) {
    test('quota checks ${changeRoot ? 'root' : 'lease'} changes after ordering',
        () async {
      final old = await file('covers/old.jpg', 100, 2000);
      final newer = await file('covers/new.jpg', 100, 2001);
      final started = Completer<List<CacheFileSnapshot>>();
      final resume = Completer<List<CacheFileSnapshot>>();
      var currentRoot = root.path;
      var leased = false;
      final value = quota(
        limit: 100,
        roots: () => [currentRoot],
        protected: (path) => leased && p.equals(path, old.path),
        sorter: (files) {
          started.complete(files);
          return resume.future;
        },
      );
      final claim = await value
          .admitWorkspace(p.join(root.path, 'trigger.rgba'), peakBytes: 1);
      final release = claim.abort();
      final candidates = await started.future;
      // This event must run while ordering is pending; no timing threshold is
      // needed. Deletion authority can change during real worker execution.
      await Future<void>(() {
        if (changeRoot) {
          currentRoot = p.join(root.path, 'next-root');
        } else {
          leased = true;
        }
      });
      resume.complete(await sortCacheEvictionCandidates(candidates));
      await release;
      expect(await old.exists(), isTrue);
      expect(await newer.exists(), changeRoot);
      expect(value.pendingCount, 0);
    });

    test(
        'general maintenance checks ${changeRoot ? 'root' : 'lease'} changes after ordering',
        () async {
      final old = await file('covers/old.jpg', 100, 2000);
      final newer = await file('covers/new.jpg', 100, 2001);
      final inventory = await scanCacheFiles([root.path]);
      final started = Completer<List<CacheFileSnapshot>>();
      final resume = Completer<List<CacheFileSnapshot>>();
      var current = true;
      var leased = false;
      final maintenance = trimCacheInventory(
        inventory,
        limitBytes: 100,
        isCurrent: () => current,
        isProtected: (path) => leased && p.equals(path, old.path),
        sortCandidates: (files) {
          started.complete(files);
          return resume.future;
        },
      );
      final candidates = await started.future;
      await Future<void>(() {
        if (changeRoot) {
          current = false;
        } else {
          leased = true;
        }
      });
      resume.complete(await sortCacheEvictionCandidates(candidates));
      await maintenance;
      expect(await old.exists(), isTrue);
      expect(await newer.exists(), changeRoot);
    });
  }
}
