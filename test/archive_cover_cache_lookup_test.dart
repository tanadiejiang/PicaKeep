import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/archive/archive_errors.dart';
import 'package:picakeep/foundation/archive/archive_models.dart';
import 'package:picakeep/foundation/archive/archive_password_store.dart';
import 'package:picakeep/foundation/archive/archive_reading_service.dart';
import 'package:picakeep/foundation/archive/archive_registry.dart';
import 'package:picakeep/foundation/archive/backends/dart_zip_backend.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/local_cover_cache.dart';

import 'support/image_disk_quota_fixture.dart';

class _CountingZipBackend extends DartZipBackend {
  _CountingZipBackend(this.root);
  final String root;
  final reads = <String, int>{};
  final failedIndexes = <String>{};
  final afterRead = <String, Future<void> Function()>{};

  @override
  bool supportsPath(String archivePath) =>
      p.isWithin(root, archivePath) && super.supportsPath(archivePath);

  @override
  Future<ArchiveIndex> openIndex(String archivePath, {String? password}) async {
    if (failedIndexes.contains(archivePath)) {
      throw const ArchiveFailure(
          code: ArchiveErrorCode.ioError, debugMessage: 'Index unavailable');
    }
    return super.openIndex(archivePath, password: password);
  }

  @override
  Future<Uint8List> readEntry(String archivePath, String entryPath,
      {String? password}) async {
    reads[archivePath] = (reads[archivePath] ?? 0) + 1;
    final bytes =
        await super.readEntry(archivePath, entryPath, password: password);
    await afterRead.remove(archivePath)?.call();
    return bytes;
  }
}

class _UnreadableFile implements File {
  _UnreadableFile(this.real);
  final File real;
  @override
  Future<FileStat> stat() => real.stat();
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      throw FileSystemException(
          'Test read access revoked', real.path, const OSError('', 13));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _UnreadableIO extends IOOverrides {
  _UnreadableIO(this.source);
  final String source;
  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path == source ? _UnreadableFile(file) : file;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace;
  late _CountingZipBackend backend;
  final quotaOverride = ImageDiskQuota.overrideForTesting;
  final passwords = ArchivePasswordStore.instance;
  final originalDefaults = List<String>.of(passwords.defaultPasswords);
  final originalAutoUnlock = passwords.autoUnlockEnabled;
  final service = ArchiveReadingService.instance;
  var sequence = 0;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('archive-cover-cache-');
    App.dataPath = p.join(workspace.path, 'app');
    App.cachePath = p.join(workspace.path, 'cache');
    installTaskDiskQuota(() => [workspace.path]);
    backend = _CountingZipBackend(workspace.path);
    ArchiveRegistry.instance.register(backend);
  });

  setUp(() {
    LocalCoverCache.debugResetForTest();
    service.clearAllReadingState();
    passwords.configure(defaultPasswords: const [], autoUnlockEnabled: false);
  });

  tearDownAll(() async {
    await ImageDiskQuota.shared.drain();
    ImageDiskQuota.overrideForTesting = quotaOverride;
    passwords.configure(
        defaultPasswords: originalDefaults,
        autoUnlockEnabled: originalAutoUnlock);
    service.clearAllReadingState();
    await workspace.delete(recursive: true);
  });

  Uint8List png(int color) {
    final pixels = img.Image(width: 8, height: 12);
    pixels.setPixelRgb(0, 0, color, 20, 200);
    return Uint8List.fromList(img.encodePng(pixels));
  }

  Future<File> archive(Map<String, Uint8List> members,
      {File? destination}) async {
    final content = Archive();
    for (final member in members.entries) {
      content.add(ArchiveFile(member.key, member.value.length, member.value));
    }
    final file =
        destination ?? File(p.join(workspace.path, 'source-${sequence++}.zip'));
    await file.writeAsBytes(ZipEncoder().encode(content), flush: true);
    return file;
  }

  test(
      'real ZIP disk cover hit skips member decoding and survives reading-state clear',
      () async {
    final bytes = png(80);
    final file = await archive({'cover.png': bytes});
    final original = await file.readAsBytes();
    final path = await service.extractCoverToCache(file.path, 'cover.png');
    expect(path, isNotNull);
    expect(backend.reads[file.path], 1);
    expect(await File(path!).readAsBytes(), bytes);
    service.clearAllReadingState();
    final warm = await service.extractCoverToCache(file.path, 'cover.png');
    expect(warm, path);
    expect(backend.reads[file.path], 1,
        reason: 'persistent cache lookup must precede archive member decoding');
    expect(await file.readAsBytes(), original);
    expect(ImageDiskQuota.shared.activeBytes, 0);
  });

  test('member full path and archive identity keep independent cache entries',
      () async {
    final first = png(30), nested = png(70), other = png(190);
    final file =
        await archive({'cover.png': first, 'nested/cover.png': nested});
    final secondArchive = await archive({'cover.png': other});
    final a = await service.extractCoverToCache(file.path, 'cover.png');
    final b = await service.extractCoverToCache(file.path, 'nested/cover.png');
    final c =
        await service.extractCoverToCache(secondArchive.path, 'cover.png');
    expect({a, b, c}, hasLength(3));
    expect(await File(a!).readAsBytes(), first);
    expect(await File(b!).readAsBytes(), nested);
    expect(await File(c!).readAsBytes(), other);
    expect(await service.extractCoverToCache(file.path, 'nested/cover.png'), b);
    expect(backend.reads[file.path], 2);
    expect(await service.extractCoverToCache(file.path, 'missing/cover.png'),
        isNull);
  });

  test('deleted derivative rebuilds and replaced archive rejects the old cover',
      () async {
    final before = png(20), after = png(210);
    final file = await archive({'cover.png': before});
    final original = await file.readAsBytes();
    final first = await service.extractCoverToCache(file.path, 'cover.png');
    await File(first!).delete();
    final repaired = await service.extractCoverToCache(file.path, 'cover.png');
    expect(backend.reads[file.path], 2);
    expect(await File(repaired!).readAsBytes(), before);
    expect(await file.readAsBytes(), original);
    await archive({'cover.png': after}, destination: file);
    await file.setLastModified(DateTime.utc(2004, 1, 2));
    final updated = await service.extractCoverToCache(file.path, 'cover.png');
    expect(backend.reads[file.path], 3);
    expect(await File(updated!).readAsBytes(), after);
    expect(await service.extractCoverToCache(file.path, 'cover.png'), updated);
    expect(backend.reads[file.path], 3);
  });

  test('a source changed during extraction is not published', () async {
    final file = await archive({'cover.png': png(40)});
    backend.afterRead[file.path] = () async {
      await archive({'cover.png': png(180)}, destination: file);
      await file.setLastModified(DateTime.utc(2005, 2, 3));
    };
    expect(await service.extractCoverToCache(file.path, 'cover.png'), isNull);
    final recovered = await service.extractCoverToCache(file.path, 'cover.png');
    expect(await File(recovered!).readAsBytes(), png(180));
  });

  test(
      'unverified index, revoked read access and absent source do not reuse stale bytes',
      () async {
    final file = await archive({'cover.png': png(50)});
    final stored = await service.extractCoverToCache(file.path, 'cover.png');
    service.disposeReadingSession(file.path);
    backend.failedIndexes.add(file.path);
    expect(await service.extractCoverToCache(file.path, 'cover.png'), stored);
    expect(backend.reads[file.path], 2,
        reason: 'unknown encryption/index state must retain member validation');
    backend.failedIndexes.remove(file.path);
    final result = await IOOverrides.runWithIOOverrides(
        () => service.extractCoverToCache(file.path, 'cover.png'),
        _UnreadableIO(file.path));
    expect(result, isNull);
    expect(await File(stored!).exists(), isTrue);
    await file.delete();
    expect(await service.extractCoverToCache(file.path, 'cover.png'), isNull);
    expect(await File(stored).exists(), isTrue);
  });

  test(
      'encrypted cover still checks forgotten and fallback passwords after caching',
      () async {
    final source = File('test/fixtures/image-pipeline-022/zipcrypto.zip');
    final file = await source
        .copy(p.join(workspace.path, 'encrypted-${sequence++}.zip'));
    final original = await file.readAsBytes();
    passwords.setSessionPassword(file.path, 'fixture-password');
    final stored = await service.extractCoverToCache(file.path, '1.png');
    expect(stored, isNotNull);
    final firstReads = backend.reads[file.path]!;
    passwords.forget(file.path);
    expect(await service.extractCoverToCache(file.path, '1.png'), isNull,
        reason: 'cached plaintext cover cannot bypass password revocation');
    expect(backend.reads[file.path], greaterThan(firstReads));
    passwords.setSessionPassword(file.path, 'wrong-password');
    passwords.configure(
        defaultPasswords: ['fixture-password'], autoUnlockEnabled: true);
    final beforeFallback = backend.reads[file.path]!;
    expect(await service.extractCoverToCache(file.path, '1.png'), stored);
    expect(backend.reads[file.path], beforeFallback + 2,
        reason: 'the same wrong-session/default-password fallback must run');
    expect(await file.readAsBytes(), original);
  });
}
