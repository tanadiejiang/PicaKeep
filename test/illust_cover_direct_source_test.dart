import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/image_pipeline/cover_decode_target.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/local_cover_cache.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_settings.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');
}

final class _SourceIO extends IOOverrides {
  _SourceIO(this.source, {this.denyOpen = false, this.afterPrefix});
  final String source;
  final bool denyOpen;
  final FutureOr<void> Function()? afterPrefix;
  int fullReads = 0, opens = 0, closes = 0;
  final List<int> prefixLengths = [];
  bool notified = false;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return p.equals(path, source) ? _SourceFile(file, this) : file;
  }
}

class _SourceFile implements File {
  _SourceFile(this.file, this.observer);
  final File file;
  final _SourceIO observer;
  @override
  String get path => file.path;
  @override
  Future<FileStat> stat() => file.stat();
  @override
  Future<bool> exists() => file.exists();
  @override
  bool existsSync() => file.existsSync();
  @override
  Future<Uint8List> readAsBytes() {
    observer.fullReads++;
    return file.readAsBytes();
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    observer.opens++;
    if (observer.denyOpen) {
      throw FileSystemException(
          'Injected direct-open permission failure', path);
    }
    return _SourceHandle(await file.open(mode: mode), observer);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected source operation: ${invocation.memberName}');
}

class _SourceHandle implements RandomAccessFile {
  _SourceHandle(this.file, this.observer);
  final RandomAccessFile file;
  final _SourceIO observer;
  @override
  String get path => file.path;
  @override
  Future<Uint8List> read(int bytes) async {
    observer.prefixLengths.add(bytes);
    final prefix = await file.read(bytes);
    if (!observer.notified) {
      observer.notified = true;
      await observer.afterPrefix?.call();
    }
    return prefix;
  }

  @override
  Future<RandomAccessFile> close() async {
    observer.closes++;
    await file.close();
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected source handle: ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final savedSettings = List<String>.of(appdata.settings);
  final savedQuota = ImageDiskQuota.overrideForTesting;
  final savedPaths = PathProviderPlatform.instance;
  final imageCache = PaintingBinding.instance.imageCache;
  late Directory workspace;
  var serial = 0;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('illust-direct-source-');
    PathProviderPlatform.instance = _Paths(workspace.path);
    App.dataPath = p.join(workspace.path, 'app');
    App.cachePath = p.join(workspace.path, 'cache');
    ImageDiskQuota.overrideForTesting = ImageDiskQuota(
        roots: () => [App.cachePath, LocalCoverCache.rootDirectory().path],
        idleLimitBytes: () => 512 << 20,
        space: (_) async =>
            const ImageDiskSpace(100 << 30, 'direct-cover-test'));
  });
  setUp(() {
    appdata.settings[androidRootModeSettingIndex] = '0';
    appdata.settings[androidShizukuModeSettingIndex] = '0';
    CoverThumbnailCache.nativeAvailableForTesting = false;
    CoverThumbnailCache.maintenanceForTesting = (_) async {};
    imageCache.clear();
    imageCache.clearLiveImages();
  });
  tearDown(() async {
    CoverThumbnailCache.beforeProviderPersistenceForTesting = null;
    await CoverThumbnailCache.waitForProviderPersistenceForTesting();
    await CoverThumbnailCache.waitForMaintenanceForTesting();
    CoverThumbnailCache.nativeAvailableForTesting = null;
    CoverThumbnailCache.maintenanceForTesting = null;
    imageCache.clear();
    imageCache.clearLiveImages();
  });
  tearDownAll(() async {
    await ImageDiskQuota.shared.drain();
    ImageDiskQuota.overrideForTesting = savedQuota;
    PathProviderPlatform.instance = savedPaths;
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    await workspace.delete(recursive: true);
  });

  Future<File> source(
      {String extension = 'png', int width = 480, int height = 720}) async {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: img.ColorRgba8(45, 125, 200, 255));
    final bytes =
        extension == 'jpg' ? img.encodeJpg(image) : img.encodePng(image);
    return File(p.join(workspace.path, 'cover-${serial++}.$extension'))
        .writeAsBytes(bytes);
  }

  LocalLibraryComicItem itemFor(File cover,
      {bool managed = true, String? artifact, String? hint}) {
    final id = 'direct-${serial++}';
    return LocalLibraryComicItem(
        itemId: managed ? 'local_download::direct_fixture::$id' : 'album::$id',
        originalId: id,
        type: DownloadType.pixiv,
        name: id,
        subTitle: '',
        tags: [],
        sourceDisplayName: 'fixture',
        fileSystemPath: artifact ?? cover.path,
        episodeFiles: {
          0: [cover.path]
        },
        downloadedEps: [0],
        eps: ['all'],
        localCoverPath: hint,
        localStorageExists: true,
        canDelete: false,
        aliases: []);
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() done,
      {required String reason}) async {
    for (var attempt = 0; !done() && attempt < 400; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(done(), isTrue, reason: reason);
  }

  Future<void> drain(WidgetTester tester) async {
    var done = false;
    Object? error;
    await tester.runAsync(() async {
      unawaited(() async {
        await CoverThumbnailCache.waitForProviderPersistenceForTesting();
        await CoverThumbnailCache.waitForMaintenanceForTesting();
      }()
          .then((_) => done = true, onError: (Object failure, StackTrace _) {
        error = failure;
        done = true;
      }));
    });
    await pumpUntil(tester, () => done, reason: 'bounded persistence drains');
    if (error != null) throw error!;
  }

  Future<void> paint(WidgetTester tester, ImageProvider<Object> provider,
      {int width = 384, int height = 576}) async {
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Image(
            image: CoverDecodeTarget(provider,
                frameWidth: width, frameHeight: height, fit: BoxFit.contain))));
    await pumpUntil(tester, () {
      final found = find.byType(RawImage);
      return found.evaluate().isNotEmpty &&
          tester.widget<RawImage>(found).image != null;
    }, reason: 'bounded file-backed cover paints');
    final raster = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect((raster.width, raster.height), (width, height));
    expect(tester.takeException(), isNull);
  }

  for (final extension in ['jpg', 'png']) {
    testWidgets(
        'cold $extension paints without copying or modifying the original',
        (tester) async {
      final file = (await tester.runAsync(() => source(extension: extension)))!;
      final before = (await tester.runAsync(file.stat))!;
      final bytes = (await tester.runAsync(file.readAsBytes))!;
      final registered =
          (await tester.runAsync(LocalCoverCache.registeredReproduciblePaths))!;
      final item = itemFor(file);
      final reads = _SourceIO(file.path);
      final manager = LocalLibraryManager();
      final provider = (await tester.runAsync(() =>
          IOOverrides.runWithIOOverrides(
              () => manager.prepareIllustCover(item, 384,
                  canContinue: () => true),
              reads)))!;
      expect(provider, isNotNull);
      expect(reads.fullReads, 0);
      expect(reads.prefixLengths, [32]);
      expect((reads.opens, reads.closes), (1, 1));
      expect(item.localCoverPath, file.path,
          reason: 'details retain source geometry');
      await paint(tester, provider);
      await drain(tester);
      expect(await tester.runAsync(LocalCoverCache.registeredReproduciblePaths),
          registered,
          reason: 'the original is not registered as a removable copy');
      expect(await tester.runAsync(file.readAsBytes), bytes);
      final after = (await tester.runAsync(file.stat))!;
      expect((after.size, after.modified), (before.size, before.modified));
      expect(
          await tester.runAsync(() => File(p.join(
                  workspace.path, 'local_library_cache', 'direct_fixture.json'))
              .exists()),
          isFalse,
          reason: 'no external hint is persisted');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('managed directory selects its named cover without raw staging',
      (tester) async {
    final folder = (await tester.runAsync(() =>
        Directory(p.join(workspace.path, 'directory-${serial++}')).create()))!;
    final original = (await tester.runAsync(() => source()))!;
    final file = (await tester
        .runAsync(() => original.copy(p.join(folder.path, 'cover.png'))))!;
    final item = itemFor(file, artifact: folder.path);
    final reads = _SourceIO(file.path);
    final provider = (await tester.runAsync(() =>
        IOOverrides.runWithIOOverrides(
            () => LocalLibraryManager()
                .prepareIllustCover(item, 384, canContinue: () => true),
            reads)))!;
    expect(reads.fullReads, 0);
    expect(reads.prefixLengths, [32]);
    expect(item.localCoverPath, file.path);
    await paint(tester, provider);
    await tester.pumpWidget(const SizedBox.shrink());
    await drain(tester);
  });

  testWidgets(
      'existing registered managed raw cover remains the preparation source',
      (tester) async {
    final file = (await tester.runAsync(() => source()))!;
    final item = itemFor(file);
    final manager = LocalLibraryManager();
    final internal =
        (await tester.runAsync(() => manager.resolveCoverPathForItem(item)))!;
    expect(p.isWithin(LocalCoverCache.rootDirectory().path, internal), isTrue);
    final reads = _SourceIO(file.path, denyOpen: true);
    final provider = (await tester.runAsync(() =>
        IOOverrides.runWithIOOverrides(
            () =>
                manager.prepareIllustCover(item, 384, canContinue: () => true),
            reads)))!;
    expect((reads.fullReads, reads.opens), (0, 0));
    expect(item.localCoverPath, internal);
    final direct = (await tester.runAsync(() =>
        CoverThumbnailCache.prepareProvider(internal, 384,
            canContinue: () => true)))!;
    expect(provider, direct,
        reason: 'the existing source identity and thumbs survive');
    await paint(tester, provider);
    await tester.pumpWidget(const SizedBox.shrink());
    await drain(tester);
  });

  testWidgets(
      'route reentry reuses direct pixels before derivative persistence',
      (tester) async {
    final file = (await tester.runAsync(() => source()))!;
    final item = itemFor(file);
    final manager = LocalLibraryManager();
    final barriers = (await tester.runAsync(
        () async => (entered: Completer<void>(), release: Completer<void>())))!;
    CoverThumbnailCache.beforeProviderPersistenceForTesting = () async {
      if (!barriers.entered.isCompleted) barriers.entered.complete();
      await barriers.release.future;
    };
    var firstActive = true;
    try {
      final first = (await tester.runAsync(() => manager
          .prepareIllustCover(item, 384, canContinue: () => firstActive)))!;
      await paint(tester, first);
      await pumpUntil(tester, () => barriers.entered.isCompleted,
          reason: 'persistence waits behind a controlled barrier');
      await tester.pumpWidget(const SizedBox.shrink());
      firstActive = false;
      final key = CoverDecodeTarget.cacheKeyForBoundedProvider(first);
      expect(imageCache.statusForKey(key).keepAlive, isTrue);
      final reads = _SourceIO(file.path);
      final next = (await tester.runAsync(() => IOOverrides.runWithIOOverrides(
          () => manager.prepareIllustCover(item, 384, canContinue: () => true),
          reads)))!;
      expect(next, first);
      expect(identical(next, first), isFalse);
      expect(reads.fullReads, 0);
      await paint(tester, next);
      expect(item.localCoverPath, file.path);
      await tester.runAsync(() =>
          file.writeAsBytes(img.encodePng(img.Image(width: 20, height: 30))));
      final replacement = (await tester.runAsync(() =>
          manager.prepareIllustCover(item, 384, canContinue: () => true)))!;
      expect(replacement, isNot(first),
          reason: 'source stamps reject old cached pixels');
      await paint(tester, replacement, width: 20, height: 30);
    } finally {
      if (!barriers.release.isCompleted) barriers.release.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      await drain(tester);
    }
  });

  for (final fallback in ['permission', 'root', 'shizuku']) {
    testWidgets(
        '$fallback access retains the registered internal staging fallback',
        (tester) async {
      final file = (await tester.runAsync(() => source()))!;
      final item = itemFor(file);
      if (fallback == 'root') {
        appdata.settings[androidRootModeSettingIndex] = '1';
      }
      if (fallback == 'shizuku') {
        appdata.settings[androidShizukuModeSettingIndex] = '1';
      }
      final reads = _SourceIO(file.path, denyOpen: fallback == 'permission');
      final provider = (await tester.runAsync(() =>
          IOOverrides.runWithIOOverrides(
              () => LocalLibraryManager()
                  .prepareIllustCover(item, 384, canContinue: () => true),
              reads)))!;
      expect(provider, isNotNull);
      expect(reads.fullReads, 1);
      expect(reads.opens, fallback == 'permission' ? 1 : 0);
      expect(
          p.isWithin(
              LocalCoverCache.rootDirectory().path, item.localCoverPath!),
          isTrue);
      await paint(tester, provider);
      await tester.pumpWidget(const SizedBox.shrink());
      await drain(tester);
    });
  }

  testWidgets(
      'replacement during prefix validation is not copied into a new request',
      (tester) async {
    final file = (await tester.runAsync(() => source()))!;
    final item = itemFor(file);
    final reads = _SourceIO(file.path, afterPrefix: () async {
      await file.writeAsBytes(img.encodePng(img.Image(width: 20, height: 30)));
    });
    final registered =
        (await tester.runAsync(LocalCoverCache.registeredReproduciblePaths))!;
    final provider = await tester.runAsync(() => IOOverrides.runWithIOOverrides(
        () => LocalLibraryManager()
            .prepareIllustCover(item, 384, canContinue: () => true),
        reads));
    expect(provider, isNull);
    expect((reads.fullReads, reads.opens, reads.closes), (0, 1, 1));
    expect(await tester.runAsync(LocalCoverCache.registeredReproduciblePaths),
        registered);
  });

  testWidgets(
      'cancellation during prefix validation closes the source without staging',
      (tester) async {
    final file = (await tester.runAsync(() => source()))!;
    final item = itemFor(file);
    var active = true;
    final reads = _SourceIO(file.path, afterPrefix: () => active = false);
    final provider = await tester.runAsync(() => IOOverrides.runWithIOOverrides(
        () => LocalLibraryManager()
            .prepareIllustCover(item, 384, canContinue: () => active),
        reads));
    expect(provider, isNull);
    expect((reads.fullReads, reads.opens, reads.closes), (0, 1, 1));
  });

  testWidgets('decode budget rejection does not restart original staging',
      (tester) async {
    final file = (await tester.runAsync(() async {
      final result = await source();
      final handle = await result.open(mode: FileMode.append);
      try {
        await handle.truncate(65 << 20);
      } finally {
        await handle.close();
      }
      return result;
    }))!;
    expect(await tester.runAsync(file.length), 65 << 20);
    final item = itemFor(file);
    final reads = _SourceIO(file.path);
    final registered =
        (await tester.runAsync(LocalCoverCache.registeredReproduciblePaths))!;
    final provider = await tester.runAsync(() => IOOverrides.runWithIOOverrides(
        () => LocalLibraryManager()
            .prepareIllustCover(item, 384, canContinue: () => true),
        reads));
    expect(provider, isNull);
    expect(reads.fullReads, 0);
    expect(reads.prefixLengths, [32]);
    expect(await tester.runAsync(LocalCoverCache.registeredReproduciblePaths),
        registered);
  });
}
