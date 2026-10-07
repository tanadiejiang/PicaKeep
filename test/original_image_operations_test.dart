import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/original_image_operations.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';

ReaderPageIdentity identity(String work) => ReaderPageIdentity(
    sourceKey: 'local_album',
    workId: work,
    downloadId: work,
    episode: 1,
    page: 0,
    sourceVersion: 'version1');

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('original-operation-test-');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('same basename in separate works persists distinct exact original bytes',
      () async {
    final first = await File('${root.path}/a/1.jpg').create(recursive: true);
    final second = await File('${root.path}/b/1.jpg').create(recursive: true);
    await first.writeAsBytes([255, 216, 255, ...List.filled(128 * 1024, 1)]);
    await second.writeAsBytes([255, 216, 255, ...List.filled(128 * 1024, 2)]);
    final folder = Directory('${root.path}/favorites');
    final savedFirst = await persistOriginalImage(first,
        directory: folder, identity: identity('a'));
    final savedSecond = await persistOriginalImage(second,
        directory: folder, identity: identity('b'));
    expect(savedFirst.path, isNot(savedSecond.path));
    expect(await originalImageDigest(savedFirst),
        await originalImageDigest(first));
    expect(await originalImageDigest(savedSecond),
        await originalImageDigest(second));
    final repeated = await persistOriginalImage(first,
        directory: folder, identity: identity('a'));
    expect(repeated.path, savedFirst.path);
    expect(await folder.list().length, 2);
  });

  test('real magic controls the extension without re-encoding mislabeled files',
      () async {
    final file = await File('${root.path}/pretend.jpg')
        .writeAsBytes([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3]);
    final saved = await persistOriginalImage(file,
        directory: Directory('${root.path}/favorites'),
        identity: identity('png'));
    expect(saved.path, endsWith('.png'));
    expect(await saved.readAsBytes(), await file.readAsBytes());
    expect(
        readerPageTypeFromHeader(Uint8List.fromList(
            [82, 73, 70, 70, 0, 0, 0, 0, 65, 86, 73, 32])).extension,
        '.bin');
  });

  test(
      'selected source refuses a replaced file instead of silently exporting a new page version',
      () async {
    final file =
        await File('${root.path}/original.png').writeAsBytes([1, 2, 3]);
    final stat = await file.stat();
    final source = FileReaderPageSource(
        identity: identity('changed'),
        file: file,
        byteLength: stat.size,
        modifiedMillis: stat.modified.millisecondsSinceEpoch);
    await file.writeAsBytes([4, 5, 6, 7]);
    await expectLater(source.openOriginalFile(), throwsStateError);
  });

  test(
      'deferred materialisation is single-flight, chunked, cancellable and released once',
      () async {
    var opens = 0;
    var releases = 0;
    final source = DeferredReaderPageSource(
        identity: identity('stream'),
        onDispose: () {
          releases++;
        },
        opener: (cancel) async {
          opens++;
          return materializeReaderPageStream(
              Stream.fromIterable([
                List<int>.filled(65536, 1),
                List<int>.filled(65536, 2),
              ]),
              directory: root,
              fileName: 'page.bin',
              cancellation: cancel);
        });
    final files = await Future.wait(
        [source.openOriginalFile(), source.openOriginalFile()]);
    expect(opens, 1);
    expect(files[0].path, files[1].path);
    expect(await files[0].length(), 131072);
    await source.dispose();
    await source.dispose();
    expect(releases, 1);
    expect(await files[0].exists(), isFalse);
  });

  test('disposing a temporary original waits for every native file consumer',
      () async {
    final file = await File('${root.path}/leased.png').writeAsBytes([1, 2, 3]);
    var releasedBudget = false;
    final source = DeferredReaderPageSource(
        identity: identity('leased'),
        opener: (_) async => file,
        onDispose: () => releasedBudget = true);
    await source.openOriginalFile();
    final releaseFirst = ReaderPageFileLease.acquire(file);
    final releaseSecond = ReaderPageFileLease.acquire(file);
    expect(DerivedImageStore.isPathLeased(file.path), isTrue);
    expect(DerivedImageStore.isPathLeased('${file.path}.json'), isTrue);
    final disposing = source.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(await file.exists(), isTrue);
    expect(releasedBudget, isFalse);
    releaseFirst();
    releaseFirst();
    expect(DerivedImageStore.isPathLeased(file.path), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(await file.exists(), isTrue);
    expect(releasedBudget, isFalse);
    releaseSecond();
    expect(DerivedImageStore.isPathLeased(file.path), isFalse);
    await disposing;
    expect(await file.exists(), isFalse);
    expect(releasedBudget, isTrue);
  });

  test('non-owned originals remain intact when cleanup fails', () async {
    final file = await File('${root.path}/user.png').writeAsBytes([1, 2, 3]);
    final source = DeferredReaderPageSource(
        identity: identity('user'),
        ownsFile: false,
        opener: (_) async => file,
        onDispose: () => throw StateError('cleanup failed'));
    await source.openOriginalFile();
    await source.dispose();
    await source.dispose();
    expect(await file.readAsBytes(), [1, 2, 3]);
  });

  test('disposing a paused original stream retains its file until cancellation',
      () async {
    final file = await File('${root.path}/paused.bin')
        .writeAsBytes(List<int>.filled(256 * 1024, 42));
    var budgetReleased = false;
    final source = DeferredReaderPageSource(
        identity: identity('paused'),
        opener: (_) async => file,
        onDispose: () => budgetReleased = true);
    final chunkReady = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    subscription = source.openOriginal().listen((chunk) {
      subscription.pause();
      if (!chunkReady.isCompleted) chunkReady.complete();
    });
    await chunkReady.future;
    expect(ReaderPageFileLease.activeLeaseCount, 1);
    final disposing = source.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(await file.exists(), isTrue);
    expect(budgetReleased, isFalse);
    await subscription.cancel();
    await disposing;
    expect(await file.exists(), isFalse);
    expect(budgetReleased, isTrue);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
  });

  test('plain file stream protects cache consumers without deleting the file',
      () async {
    final file = await File('${root.path}/user-stream.bin')
        .writeAsBytes(List<int>.filled(256 * 1024, 42));
    final source =
        FileReaderPageSource(identity: identity('plain'), file: file);
    final chunkReady = Completer<void>();
    late StreamSubscription<List<int>> subscription;
    subscription = source.openOriginal().listen((chunk) {
      subscription.pause();
      if (!chunkReady.isCompleted) chunkReady.complete();
    });
    await chunkReady.future;
    expect(DerivedImageStore.isPathLeased(file.path), isTrue);
    final disposing = source.dispose();
    await subscription.cancel();
    await disposing;
    expect(DerivedImageStore.isPathLeased(file.path), isFalse);
    expect(await file.length(), 256 * 1024);
  });
}
