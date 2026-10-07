import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/image_pipeline/cover_decode_target.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/local_cover_cache.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';

class _UnresolvedProvider extends ImageProvider<_UnresolvedProvider> {
  int decodes = 0;
  @override
  Future<_UnresolvedProvider> obtainKey(
          ImageConfiguration configuration) async =>
      this;
  @override
  ImageStreamCompleter loadImage(
      _UnresolvedProvider key, ImageDecoderCallback decode) {
    decodes++;
    throw StateError('A reader preview miss must not decode');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace;
  final savedQuota = ImageDiskQuota.overrideForTesting;
  final cache = PaintingBinding.instance.imageCache;
  var sequence = 0;

  setUpAll(() async {
    final parent = Platform.isWindows
        ? Directory(r'D:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    workspace = await parent.createTemp('reader-cached-cover-');
    App.dataPath = p.join(workspace.path, 'app');
    App.cachePath = p.join(workspace.path, 'cache');
    ImageDiskQuota.overrideForTesting = ImageDiskQuota(
        roots: () =>
            [App.cachePath, p.join(App.dataPath, 'local_library_cache')],
        idleLimitBytes: () => 512 << 20,
        space: (_) async => const ImageDiskSpace(100 << 30, 'preview-test'));
  });
  setUp(() {
    CoverThumbnailCache.nativeAvailableForTesting = false;
    CoverThumbnailCache.maintenanceForTesting = (_) async {};
    cache.clear();
    cache.clearLiveImages();
  });
  tearDown(() {
    CoverThumbnailCache.nativeAvailableForTesting = null;
    CoverThumbnailCache.maintenanceForTesting = null;
    cache.clear();
    cache.clearLiveImages();
  });
  tearDownAll(() async {
    ImageDiskQuota.overrideForTesting = savedQuota;
    await workspace.delete(recursive: true);
  });

  Future<File> source() async {
    final file = File(p.join(workspace.path, 'source-${sequence++}.png'));
    await file.writeAsBytes(img.encodePng(img.Image(width: 80, height: 120)));
    return file;
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
    for (var attempt = 0; !done() && attempt < 400; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(done(), isTrue);
  }

  Future<void> drain(WidgetTester tester) async {
    var done = false;
    await tester.runAsync(() async {
      unawaited(() async {
        await CoverThumbnailCache.waitForProviderPersistenceForTesting();
        await CoverThumbnailCache.waitForMaintenanceForTesting();
        done = true;
      }());
    });
    await pumpUntil(tester, () => done);
  }

  Future<ui.Image> paint(
      WidgetTester tester, ImageProvider<Object> provider) async {
    await tester.pumpWidget(MaterialApp(
        home: Image(
            image: CoverDecodeTarget(provider,
                frameWidth: 80, frameHeight: 120, fit: BoxFit.contain))));
    await pumpUntil(tester, () {
      final raw = find.byType(RawImage);
      return raw.evaluate().isNotEmpty &&
          tester.widget<RawImage>(raw).image != null;
    });
    expect(tester.takeException(), isNull);
    return tester.widget<RawImage>(find.byType(RawImage)).image!;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await drain(tester);
  }

  Future<ui.Image?> clone(
          WidgetTester tester, ImageProvider<Object> provider, File file,
          {ui.Size size = const ui.Size(80, 120), FileStat? snapshot}) =>
      tester.runAsync<ui.Image?>(() async =>
          CoverThumbnailCache.cloneCachedReaderPreview(provider,
              original: file,
              snapshot: snapshot ?? await file.stat(),
              originalSize: size));

  LocalLibraryComicItem item(File file,
          {bool managed = false, Map<int, List<String>>? files}) =>
      LocalLibraryComicItem(
          itemId: managed
              ? 'local_download::current_download::${file.path}'
              : 'local_album::${file.path}',
          originalId: file.path,
          type: DownloadType.other,
          name: 'Preview fixture',
          subTitle: '',
          tags: const [],
          sourceDisplayName: 'Pixiv',
          fileSystemPath: file.path,
          episodeFiles: files ??
              {
                0: [file.path]
              },
          downloadedEps: const [0],
          eps: const ['All'],
          localCoverPath: null,
          localStorageExists: true,
          canDelete: false,
          aliases: const []);

  Future<ReaderResolvedOriginal> original(File file, String workId,
      {int page = 0, bool previewOnly = false}) async {
    final stat = await file.stat();
    return ReaderResolvedOriginal(
        source: FileReaderPageSource(
            identity: ReaderPageIdentity(
                sourceKey: 'local',
                workId: workId,
                downloadId: workId,
                episode: 0,
                page: page,
                sourceVersion: '${stat.size}:${stat.modified}'),
            file: file,
            isPreviewOnly: previewOnly),
        file: file,
        metadata: const ReaderRasterMetadata(
            size: ui.Size(80, 120),
            animated: false,
            format: 'png',
            workingBytes: 80 * 120 * 4),
        fileSnapshot: stat);
  }

  testWidgets('displayed cover is cloned after the waterfall is paused',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    var active = true;
    final trace = CoverThumbnailTrace();
    final provider = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => active, trace: trace)))!;
    final shown = await paint(tester, provider);
    await drain(tester);
    active = false;
    final stageCount = trace.stages.length;
    final image = (await clone(tester, provider, file))!;
    expect(identical(image, shown), isFalse);
    expect(image.isCloneOf(shown), isTrue);
    image.dispose();
    expect(image.debugDisposed, isTrue);
    expect(shown.debugDisposed, isFalse);
    expect(trace.stages.length, stageCount);
    final second = (await clone(tester, provider, file))!;
    second.dispose();
    await finish(tester);
  });

  testWidgets('unknown provider and evicted cover return null without decoding',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final unresolved = _UnresolvedProvider();
    expect(await clone(tester, unresolved, file), isNull);
    expect(unresolved.decodes, 0);
    final trace = CoverThumbnailTrace();
    final provider = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true, trace: trace)))!;
    await paint(tester, provider);
    await finish(tester);
    cache.clear();
    cache.clearLiveImages();
    final count = trace.stages.length;
    expect(await clone(tester, provider, file), isNull);
    expect(trace.stages.length, count);
  });

  testWidgets('pending persistence pixels remain independently owned',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final release =
        CoverThumbnailCache.deferProviderPersistenceForVisibleWork();
    try {
      final provider = (await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(file.path, 384,
              canContinue: () => true)))!;
      await paint(tester, provider);
      await tester.pumpWidget(const SizedBox.shrink());
      cache.clear();
      cache.clearLiveImages();
      final first = (await clone(tester, provider, file))!;
      first.dispose();
      final second = (await clone(tester, provider, file))!;
      expect(second.debugDisposed, isFalse);
      second.dispose();
    } finally {
      release();
      await finish(tester);
    }
  });

  testWidgets(
      'wrong shape, source, snapshot and generation reject cached cover',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final other = (await tester.runAsync(source))!;
    final provider = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(file.path, 384,
            canContinue: () => true)))!;
    await paint(tester, provider);
    await drain(tester);
    expect(await clone(tester, provider, file, size: const ui.Size(120, 80)),
        isNull);
    expect(await clone(tester, provider, other), isNull);
    final stale = (await tester.runAsync(file.stat))!;
    await tester.runAsync(() => file.writeAsBytes([0], mode: FileMode.append));
    expect(await clone(tester, provider, file, snapshot: stale), isNull);
    expect(await clone(tester, provider, file), isNull);
    CoverThumbnailCache.invalidatePendingPublications();
    expect(await clone(tester, provider, file), isNull);
    await finish(tester);
  });

  testWidgets(
      'single-file index aliases reuse cover copies but reject stale ones',
      (tester) async {
    for (final managed in [false, true]) {
      final file = (await tester.runAsync(source))!;
      final selected = item(file, managed: managed);
      final key = LocalCoverCache.entryKeyFor(
          sourceId: managed ? 'current_download' : 'illust::${selected.id}',
          originalId: selected.originalId,
          sourceRelative: file.path);
      final copy = (await tester.runAsync(() async =>
          LocalCoverCache.storeBytes(
              entryKey: key,
              bytes: await file.readAsBytes(),
              fingerprint: await LocalCoverCache.fingerprintForAsync(file),
              extension: '.png')))!;
      final provider = (await tester.runAsync(() =>
          CoverThumbnailCache.prepareProvider(copy, 384,
              canContinue: () => true)))!;
      await paint(tester, provider);
      final data =
          selected.createLocalReadingData(cachedCoverPreview: provider);
      final resolved =
          (await tester.runAsync(() => original(file, selected.id)))!;
      expect(await clone(tester, provider, file), isNull,
          reason: 'a cached copy needs a manager-validated relationship');
      final preview = (await tester
          .runAsync(() => data.loadCachedPreview(0, 0, file.path, resolved)))!;
      preview.dispose();
      await tester
          .runAsync(() => file.writeAsBytes([0], mode: FileMode.append));
      final updated =
          (await tester.runAsync(() => original(file, selected.id)))!;
      expect(
          await tester
              .runAsync(() => data.loadCachedPreview(0, 0, file.path, updated)),
          isNull);
      await finish(tester);
    }
  });

  testWidgets(
      'page bindings reject another work, page, URL and multi-image item',
      (tester) async {
    final file = (await tester.runAsync(source))!;
    final other = (await tester.runAsync(source))!;
    final selected = item(file);
    var calls = 0;
    LocalPathReadingData data(Map<int, List<String>> files) =>
        LocalPathReadingData(
            title: 'Bound preview',
            id: selected.id,
            downloadId: selected.id,
            sourceKey: 'local',
            directoryPath: file.path,
            hasEp: false,
            comicType: comicTypeForDownloadType(DownloadType.other),
            episodeFiles: files,
            downloadedEpisodeIndexes: const [],
            cachedPreviewLoader: (_) async {
              calls++;
              return null;
            });
    final single = data({
      0: [file.path]
    });
    final correct = (await tester.runAsync(() => original(file, selected.id)))!;
    final wrongWork = (await tester.runAsync(() => original(file, 'another')))!;
    final wrongPage =
        (await tester.runAsync(() => original(file, selected.id, page: 1)))!;
    final preview = (await tester
        .runAsync(() => original(file, selected.id, previewOnly: true)))!;
    for (final resolved in [wrongWork, wrongPage, preview]) {
      expect(
          await tester.runAsync(
              () => single.loadCachedPreview(0, 0, file.path, resolved)),
          isNull);
    }
    expect(
        await tester.runAsync(
            () => single.loadCachedPreview(0, 0, other.path, correct)),
        isNull);
    expect(
        await tester.runAsync(() => data({
              0: [file.path, other.path]
            }).loadCachedPreview(0, 0, file.path, correct)),
        isNull);
    expect(calls, 0);
    await tester
        .runAsync(() => single.loadCachedPreview(0, 0, file.path, correct));
    expect(calls, 1);
  });
}
