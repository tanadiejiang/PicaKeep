import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_session_raster_cache.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';

class _Snapshot implements FileStat {
  _Snapshot({this.size = 100, int modified = 1, int changed = 1})
      : modified = DateTime.fromMicrosecondsSinceEpoch(modified),
        changed = DateTime.fromMicrosecondsSinceEpoch(changed);
  @override
  final int size;
  @override
  final DateTime modified;
  @override
  final DateTime changed;
  @override
  FileSystemEntityType get type => FileSystemEntityType.file;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const demand = ReaderTileDemand(ui.Rect.fromLTWH(0, 0, 4, 3), 1, -1, -1);
  final caches = <ReaderSessionRasterCache>[];
  final ownedImages = <ui.Image>[];

  ReaderSessionRasterCache cache({int bytes = 96, int entries = 128}) {
    final result =
        ReaderSessionRasterCache(maximumBytes: bytes, maximumEntries: entries);
    caches.add(result);
    return result;
  }

  ReaderSessionRasterKey key(String source,
          {ReaderSessionRasterCache? session,
          FileStat? snapshot,
          String pixelIdentity = 'native-rgba-v3',
          ReaderTileDemand rasterDemand = demand,
          String path = 'reader-test-original.png'}) =>
      (session ?? caches.first).keyForSnapshot(
        file: File(path),
        snapshot: snapshot ?? _Snapshot(),
        sourceIdentity: source,
        demand: rasterDemand,
        pixelIdentity: pixelIdentity,
      )!;

  Future<ui.Image> image(WidgetTester tester) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
    final picture = recorder.endRecording();
    try {
      final result = (await tester.runAsync(() => picture.toImage(4, 3)))!;
      ownedImages.add(result);
      return result;
    } finally {
      picture.dispose();
    }
  }

  Future<List<int>> pixels(WidgetTester tester, ui.Image value) async =>
      (await tester.runAsync(
              () => value.toByteData(format: ui.ImageByteFormat.rawRgba)))!
          .buffer
          .asUint8List()
          .toList();

  tearDown(() {
    for (final value in caches) {
      value.dispose();
    }
    caches.clear();
    for (final value in ownedImages) {
      value.dispose();
    }
    ownedImages.clear();
    expect(ReaderSessionRasterCache.totalRetainedBytes, 0);
  });

  testWidgets(
      'clone survives page disposal and take transfers sole cache handle',
      (tester) async {
    final session = cache();
    final original = await image(tester);
    final reference = await pixels(tester, original);
    final identity = key('page-1');
    expect(session.put(identity, original), isTrue);
    original.dispose();
    ownedImages.remove(original);
    expect(session.retainedBytes, 48);
    expect(ReaderSessionRasterCache.totalRetainedBytes, 48);
    final restored = session.take(identity)!;
    ownedImages.add(restored);
    expect(session.take(identity), isNull);
    expect(session.retainedBytes, 0);
    session.dispose();
    expect(await pixels(tester, restored), reference,
        reason: 'route cache disposal must not dispose a transferred image');
  });

  testWidgets('source stamp, geometry and pixel treatment cannot cross-hit',
      (tester) async {
    final session = cache();
    final original = await image(tester);
    expect(session.put(key('page-1'), original), isTrue);
    for (final different in [
      key('page-2'),
      key('page-1', snapshot: _Snapshot(size: 101)),
      key('page-1', snapshot: _Snapshot(modified: 2)),
      key('page-1', snapshot: _Snapshot(changed: 2)),
      key('page-1', path: 'another-original.png'),
      key('page-1', pixelIdentity: 'flutter-icc-preserved-v4'),
      key('page-1',
          rasterDemand:
              const ReaderTileDemand(ui.Rect.fromLTWH(4, 0, 4, 3), 1, 1, 0)),
      key('page-1',
          rasterDemand: const ReaderTileDemand(
              ui.Rect.fromLTWH(0, 0, 8, 6), 0.5, -1, -1)),
    ]) {
      expect(session.take(different), isNull);
    }
    expect(session.length, 1);
    ownedImages.add(session.take(key('page-1'))!);
  });

  testWidgets(
      'page revisit refreshes bounded recency, without retaining chapter',
      (tester) async {
    final session = cache(bytes: 96, entries: 2);
    final original = await image(tester);
    session.put(key('page-1'), original);
    session.put(key('page-2'), original);
    final revisited = session.take(key('page-1'))!;
    expect(session.put(key('page-1'), revisited), isTrue);
    revisited.dispose();
    session.put(key('page-3'), original);
    expect(session.length, 2);
    expect(session.retainedBytes, 96);
    expect(session.take(key('page-2')), isNull);
    ownedImages.add(session.take(key('page-1'))!);
    ownedImages.add(session.take(key('page-3'))!);
  });

  testWidgets('global budget evicts oldest session cache before visible work',
      (tester) async {
    final first = cache();
    final second = cache();
    final original = await image(tester);
    first.put(key('first-route'), original);
    second.put(key('second-route', session: second), original);
    expect(
        ReaderSessionRasterCache.trimToCombinedBudget(
            activeAndPendingBytes: 72, requiredBytes: 24, limitBytes: 144),
        isTrue);
    expect(first.length, 0);
    expect(second.length, 1);
    expect(ReaderSessionRasterCache.totalRetainedBytes, 48);
    expect(
        ReaderSessionRasterCache.trimToCombinedBudget(
            activeAndPendingBytes: 145, limitBytes: 144),
        isFalse,
        reason: 'visible bytes cannot be hidden by clearing inactive rasters');
    expect(second.length, 0);
  });

  testWidgets('failed admission preserves caller and existing cache ownership',
      (tester) async {
    final session = cache(bytes: 48);
    final original = await image(tester);
    expect(session.put(key('first'), original), isTrue);
    expect(session.put(key('second'), original, availableBytes: 0), isFalse);
    expect(session.length, 1);
    expect((await pixels(tester, original)).length, 48);
    expect(
        session.put(
            key('different-output',
                rasterDemand: const ReaderTileDemand(
                    ui.Rect.fromLTWH(0, 0, 2, 3), 1, -1, -1)),
            original),
        isFalse);
    ownedImages.add(session.take(key('first'))!);
  });

  testWidgets(
      'refresh targets one source; memory pressure and route exit clear',
      (tester) async {
    final session = cache();
    final original = await image(tester);
    final firstKey = key('page-1');
    final secondKey = key('page-2');
    session.put(firstKey, original);
    session.put(secondKey, original);
    session.invalidateSource('page-1');
    expect(session.take(firstKey), isNull);
    expect(session.put(firstKey, original), isFalse,
        reason: 'old surface cannot refill this source after explicit reload');
    expect(session.length, 1);
    final unaffected = session.take(secondKey)!;
    expect(session.put(secondKey, unaffected), isTrue,
        reason: 'refreshing one page must preserve other existing keys');
    unaffected.dispose();
    final refreshed = key('page-1');
    expect(session.put(refreshed, original), isTrue);
    expect(session.take(firstKey), isNull,
        reason: 'old key cannot consume a new-generation raster');
    expect(session.length, 2);
    session.didHaveMemoryPressure();
    expect(session.length, 0);
    expect(ReaderSessionRasterCache.totalRetainedBytes, 0);
    expect(session.put(firstKey, original), isFalse);
    expect(session.put(secondKey, original), isFalse);
    expect(session.put(refreshed, original), isFalse,
        reason: 'later surface retirement must not undo a memory warning');
    final afterPressure = key('page-2');
    expect(session.put(afterPressure, original), isTrue);
    expect(session.take(secondKey), isNull);
    session.dispose();
    session.dispose();
    expect(session.put(afterPressure, original), isFalse);
    expect(session.take(afterPressure), isNull);
    expect(
        session.keyForSnapshot(
            file: File('reader-test-original.png'),
            snapshot: _Snapshot(),
            sourceIdentity: 'page-2',
            demand: demand,
            pixelIdentity: 'native-rgba-v3'),
        isNull);
    expect((await pixels(tester, original)).length, 48);
  });

  testWidgets('clear rejects in-flight keys; only this cache can own its keys',
      (tester) async {
    final first = cache();
    final second = cache();
    final original = await image(tester);
    final old = key('page-1');
    final foreign = key('page-1', session: second);
    final unbound = ReaderSessionRasterKey.forSnapshot(
        file: File('reader-test-original.png'),
        snapshot: _Snapshot(),
        sourceIdentity: 'page-1',
        demand: demand,
        pixelIdentity: 'native-rgba-v3')!;
    expect(first.put(foreign, original), isFalse);
    expect(first.put(unbound, original), isFalse);
    expect(first.put(old, original), isTrue);
    first.clear();
    expect(first.put(old, original), isFalse);
    final current = key('page-1');
    expect(current.token, old.token,
        reason: 'refresh is independent of immutable source/raster identity');
    expect(first.put(current, original), isTrue);
    expect(first.take(old), isNull);
    expect(second.take(current), isNull);
    expect(first.take(unbound), isNull);
    expect(first.length, 1);
    ownedImages.add(first.take(current)!);
  });

  const metadata = ReaderRasterMetadata(
      size: ui.Size(1280, 1800),
      animated: false,
      format: 'jpeg',
      workingBytes: 32 << 20);

  test(
      'metadata reuse requires exact source snapshot; peek is only a geometry hint',
      () {
    final session = cache();
    final file = File('reader-test-original.png');
    final snapshot = _Snapshot();
    final guard = session.sourceKeyForSnapshot(
        file: file, snapshot: snapshot, sourceIdentity: 'page-1')!;
    expect(
        session.rememberSourceMetadata(
            file: file,
            snapshot: snapshot,
            sourceIdentity: 'page-1',
            metadata: metadata,
            fullOrdinaryImage: true,
            guard: guard),
        isTrue);
    final hit = session.sourceMetadata(
        file: file, snapshot: _Snapshot(), sourceIdentity: 'page-1')!;
    expect(hit.metadata, same(metadata));
    expect(hit.fullOrdinaryImage, isTrue);
    for (final changed in [
      _Snapshot(size: 101),
      _Snapshot(modified: 2),
      _Snapshot(changed: 2),
    ]) {
      expect(
          session.sourceMetadata(
              file: file, snapshot: changed, sourceIdentity: 'page-1'),
          isNull);
    }
    expect(
        session.sourceMetadata(
            file: File('different-original.png'),
            snapshot: snapshot,
            sourceIdentity: 'page-1'),
        isNull);
    expect(
        session.sourceMetadata(
            file: file, snapshot: snapshot, sourceIdentity: 'page-2'),
        isNull);
    expect(session.peekSourceMetadata('page-1')!.metadata.size, metadata.size);
    expect(session.peekSourceMetadata('page-2'), isNull);
    expect(session.retainedBytes, 0);
    expect(session.length, 0);
  });

  test('late metadata probes cannot repopulate refreshed or cleared sessions',
      () {
    final session = cache();
    final other = cache();
    final file = File('reader-test-original.png');
    final snapshot = _Snapshot();
    ReaderSessionSourceKey guard(String source,
            {ReaderSessionRasterCache? owner}) =>
        (owner ?? session).sourceKeyForSnapshot(
            file: file, snapshot: snapshot, sourceIdentity: source)!;
    bool remember(String source, ReaderSessionSourceKey captured,
            {FileStat? sourceSnapshot}) =>
        session.rememberSourceMetadata(
            file: file,
            snapshot: sourceSnapshot ?? snapshot,
            sourceIdentity: source,
            metadata: metadata,
            fullOrdinaryImage: true,
            guard: captured);
    final old = guard('page-1');
    final unaffected = guard('page-2');
    expect(remember('page-1', old), isTrue);
    expect(remember('page-2', unaffected), isTrue);
    session.invalidateSource('page-1');
    expect(session.peekSourceMetadata('page-1'), isNull);
    expect(remember('page-1', old), isFalse);
    expect(remember('page-2', unaffected), isTrue);
    expect(session.sourceMetadataCount, 1);
    final refreshed = guard('page-1');
    expect(remember('page-1', refreshed), isTrue);
    expect(remember('page-1', guard('page-1', owner: other)), isFalse);
    expect(remember('page-1', refreshed, sourceSnapshot: _Snapshot(size: 101)),
        isFalse);
    expect(remember('page-2', refreshed), isFalse);
    session.didHaveMemoryPressure();
    expect(session.sourceMetadataCount, 0);
    expect(remember('page-1', refreshed), isFalse);
    expect(remember('page-2', unaffected), isFalse);
    final afterPressure = guard('page-1');
    expect(remember('page-1', afterPressure), isTrue);
    session.clear();
    expect(remember('page-1', afterPressure), isFalse);
    final afterClear = guard('page-1');
    expect(remember('page-1', afterClear), isTrue);
    session.dispose();
    expect(session.sourceMetadataCount, 0);
    expect(remember('page-1', afterClear), isFalse);
    expect(session.peekSourceMetadata('page-1'), isNull);
  });

  test('source metadata LRU remains bounded without retaining chapter pixels',
      () {
    final session = cache();
    final file = File('reader-test-original.png');
    final snapshot = _Snapshot();
    void remember(int page) {
      final identity = 'page-$page';
      expect(
          session.rememberSourceMetadata(
              file: file,
              snapshot: snapshot,
              sourceIdentity: identity,
              metadata: metadata,
              fullOrdinaryImage: page.isEven,
              guard: session.sourceKeyForSnapshot(
                  file: file, snapshot: snapshot, sourceIdentity: identity)!),
          isTrue);
    }

    for (var page = 0; page < 128; page++) {
      remember(page);
    }
    expect(session.sourceMetadataCount, 128);
    expect(
        session.sourceMetadata(
            file: file, snapshot: snapshot, sourceIdentity: 'page-0'),
        isNotNull);
    remember(128);
    expect(session.sourceMetadataCount, 128);
    expect(session.peekSourceMetadata('page-0'), isNotNull);
    expect(session.peekSourceMetadata('page-1'), isNull);
    expect(session.length, 0);
    expect(ReaderSessionRasterCache.totalRetainedBytes, 0);
  });
}
