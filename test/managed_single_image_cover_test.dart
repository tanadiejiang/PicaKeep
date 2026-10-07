import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/local_cover_cache.dart';
import 'package:picakeep/foundation/local_library.dart';

import 'support/image_disk_quota_fixture.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');
}

final class _CoverIO extends IOOverrides {
  _CoverIO(this.source,
      {this.hideDirectFileType = false, this.unavailableTypedStat = false});
  final String source;
  final bool hideDirectFileType, unavailableTypedStat;
  int reads = 0;
  int childCoverProbes = 0;
  int sourceStats = 0;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    if (p.equals(path, source)) {
      return _ObservedFile(file,
          onRead: () => reads++,
          onStat: () => sourceStats++,
          hideDirectFileType: hideDirectFileType,
          unavailableTypedStat: unavailableTypedStat);
    }
    if (p.equals(p.dirname(path), source) &&
        const ['cover.jpg', 'cover.jpeg', 'cover.png', 'cover.webp']
            .contains(p.basename(path))) {
      return _ObservedFile(file, onExists: () => childCoverProbes++);
    }
    return file;
  }
}

class _ObservedFile implements File {
  _ObservedFile(this.delegate,
      {this.onRead,
      this.onExists,
      this.onStat,
      this.hideDirectFileType = false,
      this.unavailableTypedStat = false});
  final File delegate;
  final void Function()? onRead, onExists, onStat;
  final bool hideDirectFileType, unavailableTypedStat;
  @override
  String get path => delegate.path;
  @override
  Future<FileStat> stat() async {
    onStat?.call();
    if (unavailableTypedStat) {
      throw FileSystemException('Injected unavailable typed stat', path);
    }
    return delegate.stat();
  }

  @override
  Future<bool> exists() {
    onExists?.call();
    return delegate.exists();
  }

  @override
  bool existsSync() => hideDirectFileType ? false : delegate.existsSync();
  @override
  Future<Uint8List> readAsBytes() {
    onRead?.call();
    return delegate.readAsBytes();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected observed file IO: ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final savedPaths = PathProviderPlatform.instance;
  final savedSettings = List<String>.of(appdata.settings);
  final savedQuota = ImageDiskQuota.overrideForTesting;
  late Directory workspace;
  var serial = 0;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('single_cover_probes_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: p.join(workspace.path, 'app'));
    installTaskDiskQuota(() => [App.dataPath, App.cachePath]);
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

  LocalLibraryComicItem itemFor(String path) {
    final id = 'fixture_${serial++}';
    return LocalLibraryComicItem(
        itemId: 'local_download::pixiv_fixture::$id',
        originalId: id,
        type: DownloadType.pixiv,
        name: 'fixture',
        subTitle: '',
        tags: [],
        sourceDisplayName: 'Pixiv',
        fileSystemPath: path,
        episodeFiles: {},
        downloadedEps: [0],
        eps: ['single'],
        localCoverPath: null,
        localStorageExists: true,
        canDelete: false,
        aliases: []);
  }

  for (final extension in ['jpg', 'png']) {
    test('$extension artifact skips child probes and reads source once',
        () async {
      final image = img.Image(width: 16, height: 24);
      img.fill(image, color: img.ColorRgba8(47, 131, 209, 255));
      final bytes =
          extension == 'jpg' ? img.encodeJpg(image) : img.encodePng(image);
      final source = await File(p.join(workspace.path, 'single.$extension'))
          .writeAsBytes(bytes);
      final item = itemFor(source.path);
      final observed = _CoverIO(source.path);
      final manager = LocalLibraryManager();
      final path = await IOOverrides.runWithIOOverrides(
          () => manager.resolveCoverPathForItem(item), observed);
      expect(path, isNotNull);
      expect(p.isWithin(LocalCoverCache.rootDirectory().path, path!), isTrue);
      expect(observed.childCoverProbes, 0);
      expect(observed.reads, 1);
      expect(await File(path).readAsBytes(), bytes);
      expect(await source.readAsBytes(), bytes);

      final warm = _CoverIO(source.path);
      expect(
          await IOOverrides.runWithIOOverrides(
              () => manager.resolveCoverPathForItem(item), warm),
          path);
      expect(warm.childCoverProbes, 0);
      expect(warm.reads, 0);

      await File(path).delete();
      final recovery = _CoverIO(source.path);
      expect(
          await IOOverrides.runWithIOOverrides(
              () => manager.resolveCoverPathForItem(item), recovery),
          path);
      expect(recovery.childCoverProbes, 0);
      expect(recovery.reads, 1);
      expect(await File(path).readAsBytes(), bytes);
      expect(await source.readAsBytes(), bytes);
    });
  }

  test('directory named png keeps named-cover discovery', () async {
    final directory =
        await Directory(p.join(workspace.path, 'collection.png')).create();
    final bytes = img.encodePng(img.Image(width: 16, height: 24));
    final source =
        await File(p.join(directory.path, 'cover.png')).writeAsBytes(bytes);
    final observed = _CoverIO(directory.path);
    final path = await IOOverrides.runWithIOOverrides(
        () => LocalLibraryManager()
            .resolveCoverPathForItem(itemFor(directory.path)),
        observed);
    expect(path, isNotNull);
    // Three named-cover candidates plus the byte reader's existence check.
    expect(observed.childCoverProbes, 4);
    expect(await File(path!).readAsBytes(), bytes);
    expect(await source.readAsBytes(), bytes);
  });

  test('typed stat recovers a single image hidden from direct file type probe',
      () async {
    final source = await File(p.join(workspace.path, 'hidden-type.png'))
        .writeAsBytes(img.encodePng(img.Image(width: 16, height: 24)));
    final bytes = await source.readAsBytes();
    final observed = _CoverIO(source.path, hideDirectFileType: true);
    final path = await IOOverrides.runWithIOOverrides(
        () =>
            LocalLibraryManager().resolveCoverPathForItem(itemFor(source.path)),
        observed);
    expect(path, isNotNull);
    expect(observed.sourceStats, 2);
    expect(observed.childCoverProbes, 0);
    expect(observed.reads, 1);
    expect(await File(path!).readAsBytes(), bytes);
    expect(await source.readAsBytes(), bytes);
  });

  test('unavailable typed stat never guesses an image artifact from its suffix',
      () async {
    final source = await File(p.join(workspace.path, 'unknown-type.png'))
        .writeAsBytes(img.encodePng(img.Image(width: 16, height: 24)));
    final bytes = await source.readAsBytes();
    final observed = _CoverIO(source.path,
        hideDirectFileType: true, unavailableTypedStat: true);
    final path = await IOOverrides.runWithIOOverrides(
        () =>
            LocalLibraryManager().resolveCoverPathForItem(itemFor(source.path)),
        observed);
    expect(path, isNull);
    expect(observed.sourceStats, 2);
    expect(observed.childCoverProbes, 4);
    expect(observed.reads, 0);
    expect(await source.readAsBytes(), bytes);
  });
}
