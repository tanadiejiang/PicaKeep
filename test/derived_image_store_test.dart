import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'support/image_disk_quota_fixture.dart';

void main() {
  late Directory workspace;
  late DerivedImageStore store;
  const key = DerivedImageKey(
      namespace: 'account-a',
      resourceId: 'work/1/2',
      sourceVersion: 'v1',
      usage: DerivedImageUsage.readerTile,
      variant: '0:0:0:png');
  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('pk022-derived-');
    installTaskDiskQuota(() => [workspace.path]);
    store = DerivedImageStore(p.join(workspace.path, 'cache'),
        maximumTemporaryBytes: 100);
  });
  tearDown(() async {
    store.dispose();
    await workspace.delete(recursive: true);
    ImageDiskQuota.overrideForTesting = null;
  });
  Future<DerivedImageEntry?> write(
          {Stream<List<int>>? content, int maximum = 100}) =>
      store.put(
          key: key,
          content: content ?? Stream.value([1, 2, 3]),
          mimeType: 'image/png',
          width: 1,
          height: 1,
          lossless: true,
          maximumBytes: maximum,
          canPublish: () => true);

  test(
      'atomic index validates bytes and content; changed source/account never reuses',
      () async {
    final entry = (await write())!;
    expect((await store.lookup(key))?.digest, entry.digest);
    expect(
        await store.lookup(const DerivedImageKey(
            namespace: 'account-b',
            resourceId: 'work/1/2',
            sourceVersion: 'v1',
            usage: DerivedImageUsage.readerTile,
            variant: '0:0:0:png')),
        isNull);
    await File(entry.path).writeAsBytes([3, 2, 1]);
    expect(await store.lookup(key), isNull);
  });
  test('clear invalidates an in-flight publisher; no late index or half-file',
      () async {
    final input = StreamController<List<int>>();
    final writing = write(content: input.stream);
    input.add([1]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await store.clear();
    input.add([2]);
    await input.close();
    expect(await writing, isNull);
    expect(await store.lookup(key), isNull);
    expect(store.reservedTemporaryBytes, 0);
    expect(
        await Directory(store.root)
            .list(recursive: true)
            .where((entry) => entry is File)
            .isEmpty,
        isTrue);
  });
  test('shared leases survive clear and release independently', () async {
    final entry = (await write())!;
    final first = store.lease(entry);
    final second = store.lease(entry);
    await store.clear();
    expect(await File(entry.path).exists(), isTrue);
    first.release();
    first.release();
    expect(DerivedImageStore.isPathLeased(entry.path), isTrue);
    second.release();
    await store.clear();
    expect(await File(entry.path).exists(), isFalse);
  });
  test('temporary admission happens before reading and returns budget on error',
      () async {
    var read = false;
    Stream<List<int>> source() async* {
      read = true;
      yield [1, 2, 3];
    }

    expect(await write(content: source(), maximum: 101), isNull);
    expect(read, isFalse);
    expect(await write(content: Stream.value(List.filled(4, 1)), maximum: 3),
        isNull);
    expect(store.reservedTemporaryBytes, 0);
    final pool = ImageTemporaryPool(maximumBytes: 100, maximumPerJob: 70);
    final reservation = pool.reserve(70, purpose: 'native-backing')!;
    expect(pool.reserve(31, purpose: 'second'), isNull);
    reservation.release();
    reservation.release();
    expect(pool.reservedBytes, 0);
  });
  test('formal reader derivatives cannot be published with lossy encoding',
      () async {
    expect(
        () => store.put(
            key: key,
            content: Stream.value([1]),
            mimeType: 'image/jpeg',
            width: 1,
            height: 1,
            lossless: false,
            maximumBytes: 10,
            canPublish: () => true),
        throwsArgumentError);
  });
}
