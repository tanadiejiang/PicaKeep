import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/archive/archive_registry.dart';
import 'package:picakeep/foundation/local_cover_cache.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/local_trash_store.dart';
import 'package:picakeep/foundation/pixiv_download_naming.dart';
import 'package:picakeep/foundation/pixiv_library.dart';
import 'package:picakeep/foundation/pixiv_library_locations.dart';
import 'package:sqlite3/open.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');
}

Future<ImageInfo> _decode(ImageProvider provider) async {
  final result = Completer<ImageInfo>();
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener((frame, _) {
    if (!result.isCompleted) result.complete(frame.clone());
  }, onError: (Object e, StackTrace? s) {
    if (!result.isCompleted) result.completeError(e, s);
  });
  stream.addListener(listener);
  try {
    return await result.future.timeout(const Duration(seconds: 10));
  } finally {
    stream.removeListener(listener);
  }
}

Future<ImageInfo> _decodeAndPaint(
    WidgetTester tester, ImageProvider provider) async {
  final frame = (await tester.runAsync(() => _decode(provider)))!;
  await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(width: 128, height: 128, child: Image(image: provider))));
  return frame;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final saved = List<String>.of(appdata.settings);
  final provider = PathProviderPlatform.instance;
  final savedDiskQuota = ImageDiskQuota.overrideForTesting;
  late Directory workspace;
  late PixivLibrary library;
  final manager = LocalLibraryManager();
  final bytes = img.encodePng(img.Image(width: 12, height: 18));
  setUpAll(() async {
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows,
          () => DynamicLibrary.open(
              p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
    }
    final parent = Platform.isWindows
        ? Directory(r'E:\picakeep-image-pipeline-022-work')
        : Directory.systemTemp;
    await parent.create(recursive: true);
    workspace = await parent.createTemp('pk46_integration_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: p.join(workspace.path, 'app'));
    ImageDiskQuota.overrideForTesting = ImageDiskQuota(
        roots: () => [App.cachePath, LocalCoverCache.rootDirectory().path],
        idleLimitBytes: () => 512 << 20,
        space: (_) async =>
            const ImageDiskSpace(100 << 30, 'cover-test-volume'));
    ArchiveRegistry.initDefaults();
    library = PixivLibrary(p.join(workspace.path, 'pixiv'));
    await library.initialize();
    appdata.settings[pixivDownloadDirSettingIndex] = library.root;
    appdata.settings[22] = p.join(workspace.path, 'other');
    setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
  });
  tearDownAll(() async {
    await CoverThumbnailCache.waitForProviderPersistenceForTesting();
    await CoverThumbnailCache.waitForMaintenanceForTesting();
    ImageDiskQuota.overrideForTesting = savedDiskQuota;
    appdata.settings
      ..clear()
      ..addAll(saved);
    PathProviderPlatform.instance = provider;
    LocalTrashStore.instance.dispose();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await workspace.delete(recursive: true);
  });
  tearDown(() async {
    await CoverThumbnailCache.waitForProviderPersistenceForTesting();
    await CoverThumbnailCache.waitForMaintenanceForTesting();
  });
  Future<List<File>> displayFiles() async {
    final root =
        Directory(p.join(LocalCoverCache.rootDirectory().path, 'thumbs'));
    if (!await root.exists()) return [];
    return root
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.png'))
        .cast<File>()
        .toList();
  }

  Future<void> seed(PixivFolder folder, String shape, String id) async {
    final name =
        shape == 'directory' ? id : '$id.${shape == 'zip' ? 'zip' : 'png'}';
    final file = p.join(folder.path, name);
    if (shape == 'directory') {
      await Directory(file).create();
      await File(p.join(file, 'cover.png')).writeAsBytes(bytes);
      await File(p.join(file, '1.png')).writeAsBytes(bytes);
    } else if (shape == 'zip') {
      final archive = Archive()
        ..add(ArchiveFile('cover.png', bytes.length, bytes))
        ..add(ArchiveFile('1.png', bytes.length, bytes));
      await File(file).writeAsBytes(ZipEncoder().encode(archive));
    } else {
      await File(file).writeAsBytes(bytes);
    }
    final db = PixivLibrary.openDownloads(folder.path);
    try {
      db.execute('INSERT INTO download VALUES(?,?,?,?,?,?,?)', [
        id,
        id,
        'author',
        1,
        name,
        1.0,
        jsonEncode({
          'id': id,
          'name': id,
          'subTitle': 'author',
          'sourceKey': 'pixiv',
          'sourceName': 'Pixiv',
          'comicId': id,
          'tags': [],
          'cover': '',
          'downloadedEps': [0]
        })
      ]);
    } finally {
      db.dispose();
    }
  }

  for (final shape in ['directory', 'single', 'zip']) {
    test('$shape: registered folder -> scan -> real resized cover -> app cache',
        () async {
      final folder = await library.createFolder(shape);
      final id = 'pixiv_$shape';
      await seed(folder, shape, id);
      final items = await manager.getManagedDownloads();
      final item = items.singleWhere((i) => i.originalId == id);
      expect(item.isManagedDownloadItem, isTrue);
      expect(item.id, contains(folder.id));
      final frame = await _decode(ResizeImage.resizeIfNeeded(
          4, null, manager.coverImageProviderForItem(item)!));
      expect(frame.image.width, 4);
      expect(frame.image.height, 6);
      frame.dispose();
      expect(
          p.isWithin(
              LocalCoverCache.rootDirectory().path, item.localCoverPath!),
          isTrue);
      final json = jsonDecode(await File(
              p.join(App.dataPath, 'local_library_cache', 'covers_index.json'))
          .readAsString()) as Map;
      expect(
          (json['entries'] as Map).keys.any((k) => k.toString().contains(id)),
          isTrue);
    });
  }
  test('copy keeps two independently addressable scanned instances', () async {
    final source = library.copiesOf('pixiv_single').single;
    final target = await library.createFolder('copy');
    await library.transfer(source, target.id, move: false);
    final items = (await manager.getManagedDownloads())
        .where((i) => i.originalId == source.id)
        .toList();
    expect(items.length, 2);
    expect(items.map((i) => i.id).toSet().length, 2);
    expect(items.map((i) => i.fileSystemPath).toSet().length, 2);
  });
  test(
      'illustration snapshot reuses data until explicit data change or refresh',
      () async {
    final first = await manager.getManagedDownloads(cacheSnapshot: true);
    final folder = library.folder('root');
    await seed(folder, 'single', 'pixiv_snapshot');
    final cached = await manager.getManagedDownloads(cacheSnapshot: true);
    expect(cached.length, first.length);
    expect(cached.any((i) => i.originalId == 'pixiv_snapshot'), isFalse);
    App.notifyLocalDataChanged();
    final invalidated = await manager.getManagedDownloads(cacheSnapshot: true);
    expect(invalidated.any((i) => i.originalId == 'pixiv_snapshot'), isTrue);
    await seed(folder, 'single', 'pixiv_manual_refresh');
    final refreshed = await manager.getManagedDownloads(
        cacheSnapshot: true, forceRefresh: true);
    expect(
        refreshed.any((i) => i.originalId == 'pixiv_manual_refresh'), isTrue);
  });
  testWidgets(
      'prepared illustration covers stay internal and decode from file buffer',
      (tester) async {
    final item = (await tester.runAsync(manager.getManagedDownloads))!
        .firstWhere((i) => i.originalId == 'pixiv_single');
    final provider = await tester.runAsync(
        () => manager.prepareIllustCover(item, 384, canContinue: () => true));
    expect(provider, isNotNull);
    final frame = await _decodeAndPaint(tester, provider!);
    expect(frame.image.width, 12);
    expect(frame.image.height, 18);
    frame.dispose();
    await tester
        .runAsync(CoverThumbnailCache.waitForProviderPersistenceForTesting);
    final files = (await tester.runAsync(displayFiles))!;
    expect(files.isNotEmpty, isTrue);
    expect(
        files.every((file) =>
            p.isWithin(LocalCoverCache.rootDirectory().path, file.path)),
        isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  test('legacy no-cover flag without live negative record is retried',
      () async {
    final record = library.copiesOf('pixiv_single').first;
    final item = LocalLibraryComicItem(
        itemId: 'local_download::${record.folder.sourceId}::sentinel',
        originalId: record.id,
        type: (await manager.getManagedDownloads()).first.type,
        name: 'retry',
        subTitle: '',
        tags: [],
        sourceDisplayName: 'Pixiv',
        fileSystemPath: record.path,
        episodeFiles: {},
        downloadedEps: [0],
        eps: ['all'],
        localCoverPath: LocalLibraryManager.noCoverSentinel,
        localStorageExists: true,
        canDelete: false,
        aliases: []);
    expect(await manager.resolveCoverPathForItem(item), isNotNull);
    expect(
        p.isWithin(LocalCoverCache.rootDirectory().path, item.localCoverPath!),
        isTrue);
  });
  test('provider construction does no disk probes; prepared identity is stable',
      () async {
    final item = (await manager.getManagedDownloads())
        .firstWhere((i) => i.originalId == 'pixiv_single');
    StreamImageProvider buildWithoutIO() => IOOverrides.runZoned(
        () => manager.coverImageProviderForItem(item)! as StreamImageProvider,
        createFile: (_) => throw StateError('build touched disk'),
        createDirectory: (_) => throw StateError('build touched directory'));
    final initial = buildWithoutIO();
    expect(buildWithoutIO(), initial);
    await manager.resolveCoverPathForItem(item);
    final prepared = buildWithoutIO();
    expect(buildWithoutIO(), prepared);
    await manager.beginIllustCoverSession();
    expect(buildWithoutIO(), prepared,
        reason: 'page retry session must not invalidate other views');
    App.notifyLocalDataChanged();
    expect(buildWithoutIO(), isNot(prepared));
  });
  testWidgets(
      'source replacement invalidates display; unchanged warm cover reuses thumbnail',
      (tester) async {
    final item = (await tester.runAsync(() async {
      final folder = await library.createFolder('replace');
      await seed(folder, 'single', 'pixiv_replace');
      return (await manager.getManagedDownloads())
          .singleWhere((i) => i.originalId == 'pixiv_replace');
    }))!;
    final first = (await tester.runAsync(
        () => manager.prepareIllustCover(item, 384, canContinue: () => true)))!;
    final originalFrame = await _decodeAndPaint(tester, first);
    expect((originalFrame.image.width, originalFrame.image.height), (12, 18));
    originalFrame.dispose();
    await tester
        .runAsync(CoverThumbnailCache.waitForProviderPersistenceForTesting);
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    final cached = (await tester.runAsync(() async => {
          for (final file in await displayFiles())
            file.path: await file.lastModified()
        }))!;
    expect(cached, isNotEmpty);
    final warm = await tester.runAsync(
        () => manager.prepareIllustCover(item, 384, canContinue: () => true));
    expect(warm, first);
    final warmFrame = await _decodeAndPaint(tester, warm!);
    expect((warmFrame.image.width, warmFrame.image.height), (12, 18));
    warmFrame.dispose();
    expect(
        await tester.runAsync(() async => {
              for (final file in await displayFiles())
                file.path: await file.lastModified()
            }),
        cached);
    await tester.runAsync(() => File(item.fileSystemPath!)
        .writeAsBytes(img.encodePng(img.Image(width: 30, height: 40))));
    final replacement = (await tester.runAsync(
        () => manager.prepareIllustCover(item, 384, canContinue: () => true)))!;
    expect(replacement, isNot(first));
    final frame = await _decodeAndPaint(tester, replacement);
    expect((frame.image.width, frame.image.height), (30, 40));
    frame.dispose();
    await tester
        .runAsync(CoverThumbnailCache.waitForProviderPersistenceForTesting);
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  testWidgets(
      'non-managed external cover produces a reusable internal thumbnail',
      (tester) async {
    final source = File(p.join(workspace.path, 'album.png'));
    await tester.runAsync(() => source.writeAsBytes(bytes));
    final item = LocalLibraryComicItem(
        itemId: 'local_album::stage',
        originalId: 'stage',
        type: (await tester.runAsync(manager.getManagedDownloads))!.first.type,
        name: 'album',
        subTitle: '',
        tags: [],
        sourceDisplayName: '图集',
        fileSystemPath: workspace.path,
        episodeFiles: {
          0: [source.path]
        },
        downloadedEps: [0],
        eps: ['all'],
        localCoverPath: source.path,
        localStorageExists: true,
        canDelete: false,
        aliases: []);
    final first = (await tester.runAsync(
        () => manager.prepareIllustCover(item, 384, canContinue: () => true)))!;
    final frame = await _decodeAndPaint(tester, first);
    expect((frame.image.width, frame.image.height), (12, 18));
    frame.dispose();
    await tester
        .runAsync(CoverThumbnailCache.waitForProviderPersistenceForTesting);
    final cached = (await tester.runAsync(displayFiles))!;
    expect(cached, isNotEmpty);
    expect(
        cached.every((file) =>
            p.isWithin(LocalCoverCache.rootDirectory().path, file.path)),
        isTrue);
    expect(item.localCoverPath, source.path,
        reason: 'metadata retains actual source dimensions');
    final reads = _CountSourceReads(source.path);
    final warm = await tester.runAsync(() => IOOverrides.runWithIOOverrides(
        () => manager.prepareIllustCover(item, 384, canContinue: () => true),
        reads));
    expect(warm, first);
    expect(reads.reads, 0, reason: 'warm display must not read source bytes');
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  test(
      'wide display fallback invalidates Flutter image cache after replacement',
      () async {
    final folder = await library.createFolder('wide');
    await seed(folder, 'single', 'pixiv_wide');
    final item = (await manager.getManagedDownloads())
        .singleWhere((i) => i.originalId == 'pixiv_wide');
    final first = (await manager.prepareIllustCover(item, 2000,
        canContinue: () => true))!;
    final oldFrame = await _decode(first);
    expect(oldFrame.image.width, 12);
    oldFrame.dispose();
    await File(item.fileSystemPath!)
        .writeAsBytes(img.encodePng(img.Image(width: 90, height: 40)));
    final coverPath = item.localCoverPath;
    final next = (await manager.prepareIllustCover(item, 2000,
        canContinue: () => true))!;
    expect(item.localCoverPath, coverPath,
        reason: 'the registered internal source copy remains addressable');
    expect(next, isNot(first));
    final newFrame = await _decode(next);
    expect((newFrame.image.width, newFrame.image.height), (90, 40));
    newFrame.dispose();
  });
  test('shared external staging survives first consumer leaving the page',
      () async {
    final source = File(p.join(workspace.path, 'shared-stage.png'));
    await source.writeAsBytes(bytes);
    final item = LocalLibraryComicItem(
        itemId: 'local_album::shared',
        originalId: 'shared',
        type: (await manager.getManagedDownloads()).first.type,
        name: 'album',
        subTitle: '',
        tags: [],
        sourceDisplayName: '图集',
        fileSystemPath: workspace.path,
        episodeFiles: {
          0: [source.path]
        },
        downloadedEps: [0],
        eps: ['all'],
        localCoverPath: source.path,
        localStorageExists: true,
        canDelete: false,
        aliases: []);
    expect(manager.coverImageProviderForItem(item), isA<FileImage>(),
        reason: 'ordinary album grids retain their file-buffer fast path');
    // This test exercises the privileged staging fallback. Ordinary readable
    // originals now skip the full read and are decoded from their file buffer.
    final rootMode = appdata.settings[androidRootModeSettingIndex];
    appdata.settings[androidRootModeSettingIndex] = '1';
    addTearDown(() => appdata.settings[androidRootModeSettingIndex] = rootMode);
    final gate = Completer<void>();
    final reads = _CountSourceReads(source.path, beforeRead: gate.future);
    var firstActive = true;
    final secondStaging = Completer<void>();
    var secondChecks = 0;
    await IOOverrides.runWithIOOverrides(() async {
      final first =
          manager.prepareIllustCover(item, 384, canContinue: () => firstActive);
      await reads.started.future;
      final second = manager.prepareIllustCover(item, 384, canContinue: () {
        if (++secondChecks >= 5 && !secondStaging.isCompleted) {
          secondStaging.complete();
        }
        return true;
      });
      try {
        await secondStaging.future.timeout(const Duration(seconds: 5));
      } finally {
        firstActive = false;
        gate.complete();
      }
      expect(await first, isNull);
      final prepared = await second;
      expect(prepared, isNotNull);
      final frame = await _decode(prepared!);
      expect((frame.image.width, frame.image.height), (12, 18));
      frame.dispose();
      expect(reads.reads, 1);
    }, reads);
  });
  test(
      'page re-entry retries ambiguous failures without discarding positive covers',
      () async {
    final folder = await library.createFolder('retry-read');
    await seed(folder, 'single', 'pixiv_retry_read');
    final item = (await manager.getManagedDownloads())
        .singleWhere((i) => i.originalId == 'pixiv_retry_read');
    final source = File(item.fileSystemPath!);
    await source.writeAsBytes([]);
    expect(await manager.resolveCoverPathForItem(item), isNull);
    await source.writeAsBytes(bytes);
    await manager.beginIllustCoverSession();
    final prepared =
        await manager.prepareIllustCover(item, 384, canContinue: () => true);
    expect(prepared, isNotNull);
    final frame = await _decode(prepared!);
    expect((frame.image.width, frame.image.height), (12, 18));
    frame.dispose();
    expect(await source.readAsBytes(), bytes);
  });
  test(
      'root relocation preserves folders, records and redirects old task location',
      () async {
    final old = library.root;
    final before = library.folders();
    final target = p.join(workspace.path, 'moved');
    rememberPixivLibrary(old);
    await relocatePixivLibrary(old, target);
    final moved = PixivLibrary(target);
    expect(moved.folders().map((f) => f.id), before.map((f) => f.id));
    expect(moved.folder('root').libraryId, before.first.libraryId);
    expect(resolvePixivLibraryRoot(old), target);
    expect(Directory(old).existsSync(), isFalse);
    expect(
        (await manager.getManagedDownloads())
            .where((i) => i.originalId == 'pixiv_zip')
            .single
            .localStorageExists,
        isTrue);
  });
}

final class _CountSourceReads extends IOOverrides {
  _CountSourceReads(this.source, {this.beforeRead});
  final String source;
  final Future<void>? beforeRead;
  final started = Completer<void>();
  int reads = 0;
  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path == source
        ? _ObservedFile(file, () {
            reads++;
            if (!started.isCompleted) started.complete();
          }, beforeRead)
        : file;
  }
}

class _ObservedFile implements File {
  _ObservedFile(this.file, this.onRead, this.beforeRead);
  final File file;
  final Future<void>? beforeRead;
  final void Function() onRead;
  @override
  String get path => file.path;
  @override
  Future<FileStat> stat() => file.stat();
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      file.open(mode: mode);
  @override
  Future<Uint8List> readAsBytes() async {
    onRead();
    await beforeRead;
    return file.readAsBytes();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected source I/O: ${invocation.memberName}');
}
