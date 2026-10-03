import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/cache_file_inventory.dart';

void main() {
  late Directory workspace;
  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('pk60_inventory_');
  });
  tearDown(() => workspace.delete(recursive: true));

  Future<File> create(String name, int size, int age) async {
    final file = File(p.join(workspace.path, name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(size, 1));
    await file.setLastModified(DateTime(2020, 1, 1).add(Duration(days: age)));
    return file;
  }

  test('scan runs outside caller IO zone; overlapping roots count once',
      () async {
    final old = await create('cache/old.jpg', 20, 0);
    final newer = await create('cache/sub/new.jpg', 30, 1);
    await create('cache/downloading.part', 40, 2);
    final inventory = await IOOverrides.runZoned(
      () => scanCacheFiles([
        p.join(workspace.path, 'cache'),
        p.join(workspace.path, 'cache/sub'),
        p.join(workspace.path, 'cache'),
        p.join(workspace.path, 'missing'),
      ]),
      createDirectory: (_) => throw StateError('inventory ran on caller'),
      createFile: (_) => throw StateError('stat ran on caller'),
    );
    expect(inventory.totalBytes, 90);
    expect(inventory.files.map((e) => e.path),
        [p.normalize(old.path), p.normalize(newer.path)]);
  });

  test('under limit retains everything; over limit deletes oldest only',
      () async {
    final old = await create('old.jpg', 20, 0);
    final newer = await create('new.jpg', 30, 1);
    final inventory = await scanCacheFiles([workspace.path]);
    await trimCacheInventory(inventory,
        limitBytes: 50, isCurrent: () => true, isProtected: (_) => false);
    expect(await old.exists(), isTrue);
    await trimCacheInventory(inventory,
        limitBytes: 30, isCurrent: () => true, isProtected: (_) => false);
    expect(await old.exists(), isFalse);
    expect(await newer.exists(), isTrue);
  });

  test('protected, partial and changed files survive cleanup', () async {
    final leased = await create('leased.jpg', 20, 0);
    final changed = await create('changed.jpg', 20, 1);
    final removable = await create('old.jpg', 20, 2);
    final partial = await create('download.part', 20, 3);
    final inventory = await scanCacheFiles([workspace.path]);
    await changed.writeAsBytes(List.filled(21, 2));
    await trimCacheInventory(inventory,
        limitBytes: 1,
        isCurrent: () => true,
        isProtected: (path) => path == leased.path);
    expect(await leased.exists(), isTrue);
    expect(await changed.exists(), isTrue);
    expect(await partial.exists(), isTrue);
    expect(await removable.exists(), isFalse);
  });

  test('lease acquired while filesystem awaits is checked before deletion',
      () async {
    final file = await create('acquired.jpg', 20, 0);
    final inventory = await scanCacheFiles([workspace.path]);
    var leased = false;
    await trimCacheInventory(inventory,
        limitBytes: 1,
        isCurrent: () => true,
        isProtected: (_) {
          if (!leased) scheduleMicrotask(() => leased = true);
          return leased;
        });
    expect(leased, isTrue);
    expect(await file.exists(), isTrue);
  });

  test('root change while filesystem awaits cancels deletion', () async {
    final file = await create('old-root.jpg', 20, 0);
    final inventory = await scanCacheFiles([workspace.path]);
    var current = true;
    await trimCacheInventory(inventory,
        limitBytes: 1,
        isCurrent: () => current,
        isProtected: (_) {
          scheduleMicrotask(() => current = false);
          return false;
        });
    expect(current, isFalse);
    expect(await file.exists(), isTrue);
  });

  test('removed files do not abort cleanup of the rest', () async {
    final removed = await create('removed.jpg', 20, 0);
    final other = await create('other.jpg', 20, 1);
    final inventory = await scanCacheFiles([workspace.path]);
    await removed.delete();
    await trimCacheInventory(inventory,
        limitBytes: 1, isCurrent: () => true, isProtected: (_) => false);
    expect(await other.exists(), isFalse);
  });

  test('removed file bytes no longer count towards eviction', () async {
    final removed = await create('removed.jpg', 20, 0);
    final other = await create('other.jpg', 20, 1);
    final inventory = await scanCacheFiles([workspace.path]);
    await removed.delete();
    await trimCacheInventory(inventory,
        limitBytes: 25, isCurrent: () => true, isProtected: (_) => false);
    expect(await other.exists(), isTrue);
  });

  test('a smaller replacement does not evict other files unnecessarily',
      () async {
    final replaced = await create('replaced.jpg', 100, 0);
    final other = await create('other.jpg', 50, 1);
    final inventory = await scanCacheFiles([workspace.path]);
    await replaced.writeAsBytes(List.filled(10, 2));
    await trimCacheInventory(inventory,
        limitBytes: 100, isCurrent: () => true, isProtected: (_) => false);
    expect(await replaced.length(), 10);
    expect(await other.exists(), isTrue);
  });
}
