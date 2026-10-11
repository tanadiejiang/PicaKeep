import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as zip;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart' as pc;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/def.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/archive/archive_backend.dart';
import 'package:picakeep/foundation/archive/archive_errors.dart';
import 'package:picakeep/foundation/archive/archive_image_provider.dart';
import 'package:picakeep/foundation/archive/archive_memory_cache.dart';
import 'package:picakeep/foundation/archive/archive_models.dart';
import 'package:picakeep/foundation/archive/archive_password_store.dart';
import 'package:picakeep/foundation/archive/archive_reading_service.dart';
import 'package:picakeep/foundation/archive/archive_registry.dart';
import 'package:picakeep/foundation/archive/backends/dart_zip_backend.dart';
import 'package:picakeep/foundation/image_loader/reader_image_limits.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';

import 'support/image_disk_quota_fixture.dart';

class _TracingLimits extends ReaderImageReadLimits {
  _TracingLimits(int maximum, {bool Function()? isCancelled})
      : super(maximumBytes: maximum, isCancelled: isCancelled);
  final checks = <int>[];
  void Function(int)? afterCheck;
  @override
  void check(int bytes) {
    checks.add(bytes);
    super.check(bytes);
    afterCheck?.call(bytes);
  }
}

class _ExternalBackend implements ArchiveBackend, StreamingArchiveBackend {
  _ExternalBackend(this.extension, this.bytes);
  final String extension;
  final List<int> bytes;
  Future<void>? wait;
  bool fail = false;
  File? returnedFile;
  int? receivedMaximum;
  File? destination;
  final entered = Completer<void>();
  @override
  String get id => extension;
  @override
  ArchiveBackendCapabilities get capabilities =>
      const ArchiveBackendCapabilities(canReadEntryStreaming: true);
  @override
  bool supportsPath(String path) => path.endsWith(extension);
  @override
  Future<ArchiveIndex> openIndex(String path, {String? password}) async =>
      throw StateError('Reader entry must not call an unbounded index');
  @override
  Future<ArchiveProbeResult> probe(String path) async =>
      throw StateError('No unbounded probing');
  @override
  Future<Uint8List> readEntry(String path, String entry,
          {String? password}) async =>
      throw StateError('No unbounded byte aggregation');
  @override
  Future<File> materializeEntry(String path, String entry, File target,
      {String? password,
      int maxBytes = 2 << 30,
      bool Function()? isCancelled}) async {
    receivedMaximum = maxBytes;
    destination = target;
    entered.complete();
    await wait;
    // The mock represents a bounded but non-preemptible extractor. It may
    // finish late, but its native/file work is done when this Future settles.
    final output = await target.open(mode: FileMode.write);
    try {
      var total = 0;
      for (var start = 0; start < bytes.length; start += 128) {
        final end = start + 128 < bytes.length ? start + 128 : bytes.length;
        if (total + end - start > maxBytes) throw StateError('extract bound');
        await output.writeFrom(bytes, start, end);
        total += end - start;
      }
    } finally {
      await output.close();
    }
    if (fail) throw StateError('fixture extraction failed');
    return returnedFile ?? target;
  }
}

class _UnboundedBackend implements ArchiveBackend {
  _UnboundedBackend(this.extension);
  final String extension;
  var calls = 0;
  @override
  String get id => extension;
  @override
  ArchiveBackendCapabilities get capabilities =>
      const ArchiveBackendCapabilities();
  @override
  bool supportsPath(String path) => path.endsWith(extension);
  @override
  Future<ArchiveIndex> openIndex(String path, {String? password}) async =>
      throw StateError('unbounded index');
  @override
  Future<ArchiveProbeResult> probe(String path) async =>
      throw StateError('probe');
  @override
  Future<Uint8List> readEntry(String path, String entry,
      {String? password}) async {
    calls++;
    return Uint8List.fromList([1, 2, 3]);
  }
}

int _central(Uint8List bytes) {
  for (var i = 0; i + 4 <= bytes.length; i++) {
    if (bytes[i] == 0x50 &&
        bytes[i + 1] == 0x4b &&
        bytes[i + 2] == 1 &&
        bytes[i + 3] == 2) {
      return i;
    }
  }
  throw StateError('Missing fixture central directory');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final expected =
      List<int>.generate(192 * 1024 + 7, (i) => (i * 31 + i ~/ 251) & 255);
  final savedQuota = ImageDiskQuota.overrideForTesting;
  final store = ArchivePasswordStore.instance;
  final savedPasswords = store.defaultPasswords;
  final savedAutoUnlock = store.autoUnlockEnabled;
  final cache = ArchiveMemoryCache.instance;
  late Directory root;
  late ImageDiskQuota quota;
  var sequence = 0;
  final gates = <Completer<void>>[];
  final drains = <Future<void>>[];

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('archive_reader_limits_057_');
    App.dataPath = p.join(root.path, 'app');
    App.cachePath = p.join(root.path, 'cache');
    await Directory(App.dataPath).create(recursive: true);
    await Directory(App.cachePath).create(recursive: true);
    quota = installTaskDiskQuota(() => [App.cachePath]);
    ArchiveRegistry.initDefaults();
  });
  setUp(() {
    cache.clearAll();
    store.configure(defaultPasswords: [], autoUnlockEnabled: true);
  });
  tearDown(() async {
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    gates.clear();
    await Future.wait(drains);
    drains.clear();
    cache.clearAll();
    await quota.drain();
    expect(ImageTemporaryPool.shared.reservedBytes, 0);
    expect(quota.activeBytes, 0);
    expect(quota.pendingCount, 0);
  });
  tearDownAll(() async {
    store.configure(
        defaultPasswords: savedPasswords, autoUnlockEnabled: savedAutoUnlock);
    ImageDiskQuota.overrideForTesting = savedQuota;
    expect(p.basename(root.path), startsWith('archive_reader_limits_057_'));
    await root.delete(recursive: true);
  });

  Future<File> makeZip(List<int> payload, {int entries = 1}) async {
    final archive = zip.Archive();
    for (var i = 1; i <= entries; i++) {
      archive.addFile(zip.ArchiveFile('$i.png', payload.length, payload));
    }
    return File(p.join(root.path, 'fixture-${sequence++}.zip'))
        .writeAsBytes(zip.ZipEncoder().encode(archive));
  }

  Future<Uint8List> bounded(String path, ReaderImageReadLimits limits,
          {String? password}) =>
      runWithReaderImageReadLimits(limits,
          () => DartZipBackend().readEntry(path, '1.png', password: password));

  for (final name in [
    'stored.zip',
    'deflate.zip',
    'zipcrypto.zip',
    'aes256.zip',
    'zipcrypto-deflate.zip',
    'aes256-deflate.zip',
    'aes256-ae1.zip'
  ]) {
    test(
        'reader bounded $name preserves true decrypted entry bytes without disk staging',
        () async {
      final path = p.join('test', 'fixtures', 'image-pipeline-022', name);
      final limits = _TracingLimits(256 << 10);
      final bytes = await bounded(path, limits, password: 'fixture-password');
      expect(bytes, expected);
      expect(limits.checks, contains(expected.length));
      if (name == 'zipcrypto.zip' || name == 'aes256.zip') {
        expect(limits.checks.where((n) => n == 65536).length,
            greaterThanOrEqualTo(2),
            reason: 'decrypted and output totals are checked independently');
      }
      expect(
          Directory(App.cachePath).listSync(recursive: true).whereType<File>(),
          isEmpty);
      expect(ImageTemporaryPool.shared.reservedBytes, 0);
    });
  }

  test(
      'real deflate bomb with tiny false declaration stops during chunk production',
      () async {
    final file = await makeZip(Uint8List(1 << 20));
    final bytes = await file.readAsBytes();
    final cd = _central(bytes);
    ByteData.sublistView(bytes).setUint32(cd + 24, 1, Endian.little);
    ByteData.sublistView(bytes).setUint32(22, 1, Endian.little);
    await file.writeAsBytes(bytes);
    expect(await file.length(), lessThan(8192));
    final limits = _TracingLimits(8192);
    await expectLater(bounded(file.path, limits),
        throwsA(anyOf(isA<ReaderImageLimit>(), isA<StateError>())));
    expect(
        limits.checks.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(65536),
        reason:
            'no check may wait until the full 1 MiB output has been aggregated');
    expect(Directory(App.cachePath).listSync(recursive: true).whereType<File>(),
        isEmpty);
  });

  for (final offset in [20, 24]) {
    test(
        'declared ${offset == 20 ? 'compressed' : 'inflated'} bytes are rejected before entry allocation',
        () async {
      final file = await makeZip([1, 2, 3]);
      final bytes = await file.readAsBytes();
      ByteData.sublistView(bytes)
          .setUint32(_central(bytes) + offset, 513, Endian.little);
      await file.writeAsBytes(bytes);
      final limits = _TracingLimits(512);
      await expectLater(
          bounded(file.path, limits), throwsA(isA<ReaderImageLimit>()));
      expect(limits.checks, contains(513));
    });
  }

  for (final name in ['zipcrypto.zip', 'aes256.zip']) {
    test(
        'encrypted $name checks compressed/decrypted bounds before retaining payload',
        () async {
      final original =
          File(p.join('test', 'fixtures', 'image-pipeline-022', name));
      final bytes = await original.readAsBytes();
      final cd = _central(bytes);
      ByteData.sublistView(bytes).setUint32(cd + 24, 1, Endian.little);
      final file = await File(p.join(root.path, 'encrypted-${sequence++}.zip'))
          .writeAsBytes(bytes);
      final limits = _TracingLimits(128 << 10);
      await expectLater(
          bounded(file.path, limits, password: 'fixture-password'),
          throwsA(isA<ReaderImageLimit>()));
      expect(limits.checks.any((n) => n > 128 << 10), isTrue);
    });
  }

  test(
      'bounded encrypted password fallback preserves success and explicit wrong-password errors',
      () async {
    for (final name in ['zipcrypto-deflate.zip', 'aes256-deflate.zip']) {
      final path = p.join('test', 'fixtures', 'image-pipeline-022', name);
      await expectLater(
          bounded(path, const ReaderImageReadLimits(), password: 'wrong'),
          throwsA(isA<ArchiveFailure>()
              .having((f) => f.code, 'code', ArchiveErrorCode.wrongPassword)));
      store.setSessionPassword(path, 'wrong');
      store.configure(defaultPasswords: ['wrong', 'fixture-password']);
      final bytes = await runWithReaderImageReadLimits(
          const ReaderImageReadLimits(),
          () => ArchiveReadingService.instance.readEntryBytes(path, '1.png'));
      expect(bytes, expected);
      store.forget(path);
    }
  });

  test(
      'AES verifier collision preserves authenticate-before-inflate password errors',
      () async {
    final encoded = await File(p.join(
            'test', 'fixtures', 'image-pipeline-022', 'aes256-deflate.zip'))
        .readAsBytes();
    final header = ByteData.sublistView(encoded);
    final dataOffset = 30 +
        header.getUint16(26, Endian.little) +
        header.getUint16(28, Endian.little);
    final salt = Uint8List.sublistView(encoded, dataOffset, dataOffset + 16);
    final derive = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA1Digest(), 64))
      ..init(pc.Pbkdf2Parameters(salt, 1000, 66));
    final wrongKey = derive.process(Uint8List.fromList('wrong'.codeUnits));
    // Force the two-byte verifier to accept this wrong password. Only the
    // authenticated ciphertext can reject it correctly, before zlib sees it.
    encoded.setRange(dataOffset + 16, dataOffset + 18, wrongKey, 64);
    final file = await File(p.join(root.path, 'verifier-${sequence++}.zip'))
        .writeAsBytes(encoded);
    final wrongPassword = throwsA(isA<ArchiveFailure>().having(
        (failure) => failure.code, 'code', ArchiveErrorCode.wrongPassword));
    await expectLater(
        DartZipBackend().readEntry(file.path, '1.png', password: 'wrong'),
        wrongPassword);
    await expectLater(
        bounded(file.path, const ReaderImageReadLimits(), password: 'wrong'),
        wrongPassword);
  });

  test(
      'archive provider advertises only the implemented bound and cached bytes obey it',
      () async {
    final png = image.encodePng(image.Image(width: 24, height: 32), level: 0);
    final file = await makeZip(png);
    final provider = ArchiveImageProvider(
        archivePath: file.path,
        entryPath: '1.png',
        fileSize: await file.length(),
        mtimeMillis: 0);
    final chunks = StreamController<ImageChunkEvent>.broadcast();
    addTearDown(chunks.close);
    expect(provider.supportsReaderInputLimits, isTrue);
    expect(provider.readerInputOverheadBytes, (64 << 20) + (1 << 20));
    expect(
        await runWithReaderImageReadLimits(
            const ReaderImageReadLimits(), () => provider.load(chunks)),
        png);
    final small = ReaderImageReadLimits(maximumBytes: png.length - 1);
    await expectLater(
        runWithReaderImageReadLimits(small, () => provider.load(chunks)),
        throwsA(isA<ReaderImageLimit>()));
    await expectLater(
        runWithReaderImageReadLimits(
            ReaderImageReadLimits(isCancelled: () => true),
            () => provider.load(chunks)),
        throwsStateError);
  });

  test(
      'reader metadata budget includes directory objects, not only compressed entry size',
      () async {
    final file = await makeZip([], entries: 30);
    expect(await file.length(), lessThan(4096));
    await expectLater(
        runWithReaderImageReadLimits(
            const ReaderImageReadLimits(maximumBytes: 4096),
            () => ArchiveReadingService.instance.getIndex(file.path)),
        throwsA(isA<ReaderImageLimit>()));
    final normal = await ArchiveReadingService.instance.getIndex(file.path);
    expect(normal.entries, hasLength(30),
        reason: 'non-reader index behavior is unchanged');
    await expectLater(
        runWithReaderImageReadLimits(
            const ReaderImageReadLimits(maximumBytes: 4096),
            () => ArchiveReadingService.instance
                .getIndex(file.path, readerInput: true)),
        throwsA(isA<ReaderImageLimit>()),
        reason: 'cached index expansion is bounded too');
  });

  for (final cancel in [false, true]) {
    test(
        'local reader ${cancel ? 'cancellation' : 'index limit'} is not swallowed or cached as zero pages',
        () async {
      final file = await makeZip([], entries: 30);
      final data = LocalPathReadingData(
          title: 'isolated',
          id: 'fixture',
          downloadId: 'fixture',
          sourceKey: 'pixiv',
          directoryPath: file.path,
          hasEp: false,
          comicType: ComicType.pixiv,
          episodeFiles: const {},
          downloadedEpisodeIndexes: const []);
      final limits = ReaderImageReadLimits(
          maximumBytes: cancel ? 1 << 20 : 4096, isCancelled: () => cancel);
      await expectLater(
          runWithReaderImageReadLimits(limits, () => data.loadEp(0)),
          throwsA(cancel ? isA<StateError>() : isA<ReaderImageLimit>()));
      expect(await data.loadEp(0), hasLength(30),
          reason:
              'a failed reader index must not poison the same reader instance');
    });
  }

  test(
      'cancellation after actual inflate output publishes no cached partial entry',
      () async {
    final payload = Uint8List(512 << 10);
    final file = await makeZip(payload);
    final encoded = await file.readAsBytes();
    final compressed = ByteData.sublistView(encoded)
        .getUint32(_central(encoded) + 20, Endian.little);
    var declared = false, cancelled = false, scheduled = false;
    int? prefix;
    final limits = _TracingLimits(1 << 20, isCancelled: () => cancelled);
    limits.afterCheck = (bytes) {
      if (!declared && bytes == payload.length) {
        declared = true;
        return;
      }
      if (declared && bytes > compressed && bytes <= payload.length) {
        prefix = bytes;
        if (!scheduled) {
          scheduled = true;
          // A real event-queue cancellation, not an artificial synchronous
          // predicate change. Memory inflation must yield before finishing.
          Timer.run(() => cancelled = true);
        }
      }
    };
    await expectLater(
        runWithReaderImageReadLimits(
            limits,
            () => ArchiveReadingService.instance
                .readEntryBytes(file.path, '1.png')),
        throwsStateError);
    expect(prefix, isNotNull);
    expect(prefix, lessThanOrEqualTo(256 << 10));
    final stat = await file.stat();
    expect(
        cache.getEntry(ArchiveMemoryCache.entryCacheKey(file.path, '1.png',
            stat.size, stat.modified.millisecondsSinceEpoch)),
        isNull);
    expect(await file.readAsBytes(), encoded);
  });

  test('reader cancellation propagates without unbounded index/read fallback',
      () async {
    final file = await makeZip(Uint8List(256 << 10));
    var checks = 0;
    final limits = _TracingLimits(1 << 20, isCancelled: () => ++checks >= 5);
    await expectLater(bounded(file.path, limits), throwsStateError);
    expect(checks, 5);
    expect(await file.exists(), isTrue);
  });

  test(
      'other streaming backend gets capped owned staging, not its unbounded byte method',
      () async {
    final original = await File(p.join(root.path, 'user-original.bin'))
        .writeAsBytes([7, 8, 9]);
    final backend = _ExternalBackend('.bounded${sequence++}', [1, 2, 3])
      ..returnedFile = original;
    ArchiveRegistry.instance.register(backend);
    final archive = await File(p.join(root.path, 'input${backend.extension}'))
        .writeAsBytes([0]);
    final bytes = await runWithReaderImageReadLimits(
        const ReaderImageReadLimits(maximumBytes: 128 << 20),
        () => ArchiveReadingService.instance
            .readEntryBytes(archive.path, '1.png'));
    expect(bytes, [1, 2, 3]);
    expect(backend.receivedMaximum, 64 << 20);
    expect(await backend.destination!.parent.exists(), isFalse);
    expect(await original.readAsBytes(), [7, 8, 9]);
  });

  for (final fail in [false, true]) {
    test(
        'late ${fail ? 'failed' : 'cancelled'} bounded extraction drains before owned cleanup and budget release',
        () async {
      final release = Completer<void>();
      gates.add(release);
      final backend = _ExternalBackend('.late${sequence++}', [1, 2, 3])
        ..wait = release.future
        ..fail = fail;
      ArchiveRegistry.instance.register(backend);
      final archive = await File(p.join(root.path, 'input${backend.extension}'))
          .writeAsBytes([0]);
      var cancelled = false, settled = false;
      final pending = runWithReaderImageReadLimits(
          ReaderImageReadLimits(
              maximumBytes: 4096, isCancelled: () => cancelled),
          () => ArchiveReadingService.instance.readEntryBytes(
              archive.path, '1.png')).whenComplete(() => settled = true);
      drains.add(
          pending.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      final rejected = expectLater(pending, throwsStateError);
      await backend.entered.future;
      cancelled = !fail;
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
      expect(ImageTemporaryPool.shared.reservedBytes, 4096);
      expect(await backend.destination!.parent.exists(), isTrue);
      release.complete();
      await rejected;
      expect(await backend.destination!.parent.exists(), isFalse);
      expect(ImageTemporaryPool.shared.reservedBytes, 0);
      expect(await archive.readAsBytes(), [0]);
    });
  }

  test(
      'unbounded external backend is refused before execution only for reader loads',
      () async {
    final backend = _UnboundedBackend('.unsafe${sequence++}');
    ArchiveRegistry.instance.register(backend);
    final archive = await File(p.join(root.path, 'input${backend.extension}'))
        .writeAsBytes([0]);
    await expectLater(
        runWithReaderImageReadLimits(
            const ReaderImageReadLimits(),
            () => ArchiveReadingService.instance
                .readEntryBytes(archive.path, '1.png')),
        throwsA(isA<ReaderImageLimit>()));
    expect(backend.calls, 0);
    expect(
        await ArchiveReadingService.instance
            .readEntryBytes(archive.path, '1.png'),
        [1, 2, 3]);
    expect(backend.calls, 1);
  });
}
