import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/archive/archive_registry.dart';
import 'package:picakeep/foundation/local_cover_cache.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_library.dart';
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
    if (!result.isCompleted) result.complete(frame);
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final saved = List<String>.of(appdata.settings);
  final provider = PathProviderPlatform.instance;
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
    workspace = await Directory.systemTemp.createTemp('pk46_integration_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: p.join(workspace.path, 'app'));
    ArchiveRegistry.initDefaults();
    library = PixivLibrary(p.join(workspace.path, 'pixiv'));
    await library.initialize();
    appdata.settings[pixivDownloadDirSettingIndex] = library.root;
    appdata.settings[22] = p.join(workspace.path, 'other');
    setManagedDataSourceMode(managedDataSourceModeCurrentOnly);
  });
  tearDownAll(() async {
    appdata.settings
      ..clear()
      ..addAll(saved);
    PathProviderPlatform.instance = provider;
    LocalTrashStore.instance.dispose();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await workspace.delete(recursive: true);
  });
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
  test('prepared illustration covers stay internal and decode from file buffer',
      () async {
    final item = (await manager.getManagedDownloads())
        .firstWhere((i) => i.originalId == 'pixiv_single');
    final provider =
        await manager.prepareIllustCover(item, 384, canContinue: () => true);
    expect(provider, isA<FileImage>());
    expect(
        p.isWithin(LocalCoverCache.rootDirectory().path,
            (provider as FileImage).file.path),
        isTrue);
    final frame = await _decode(provider);
    expect(frame.image.width, 12);
    expect(frame.image.height, 18);
    frame.dispose();
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
