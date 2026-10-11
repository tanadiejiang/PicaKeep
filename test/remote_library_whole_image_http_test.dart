import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/http_image_body.dart';

import 'support/image_disk_quota_fixture.dart';

Uint8List _pngChunk(String type, List<int> data) {
  final typed = <int>[...ascii.encode(type), ...data];
  var crc = 0xffffffff;
  for (final byte in typed) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320);
    }
  }
  final length = ByteData(4)..setUint32(0, data.length);
  final checksum = ByteData(4)..setUint32(0, (crc ^ 0xffffffff) & 0xffffffff);
  return Uint8List.fromList([
    ...length.buffer.asUint8List(),
    ...typed,
    ...checksum.buffer.asUint8List(),
  ]);
}

// A valid self-made PNG with a compressible ancillary text chunk. No user art,
// live account initialization, native codec or external service is needed.
Uint8List _fixturePng() {
  final ihdr = ByteData(13)
    ..setUint32(0, 2)
    ..setUint32(4, 1)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  return Uint8List.fromList([
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
    ..._pngChunk('IHDR', ihdr.buffer.asUint8List()),
    ..._pngChunk(
        'tEXt', [...ascii.encode('fixture'), 0, ...List.filled(4096, 65)]),
    ..._pngChunk('IDAT', zlib.encode([0, 255, 0, 0, 255, 0, 255, 0, 255])),
    ..._pngChunk('IEND', const []),
  ]);
}

class _Response {
  const _Response(this.bytes,
      {this.encoding, this.declaredLength, this.stall = false});
  final List<int> bytes;
  final String? encoding;
  final int? declaredLength;
  final bool stall;
}

class _LoopbackImages {
  _LoopbackImages(this.server, this.responses) {
    subscription = server.listen((socket) {
      sockets.add(socket);
      var headers = '';
      var handled = false;
      socket.listen((chunk) {
        if (handled) return;
        headers += latin1.decode(chunk);
        if (!headers.contains('\r\n\r\n')) return;
        handled = true;
        final path = Uri.parse(headers.split(' ')[1]).path;
        requests.add(path);
        final response = responses[path];
        if (response == null) {
          unexpected.add(path);
          socket.add(ascii.encode(
              'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'));
          unawaited(socket.close().catchError((_) => socket));
          return;
        }
        socket.add(ascii.encode('HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n'
            'Content-Length: ${response.declaredLength ?? response.bytes.length}\r\n'
            '${response.encoding == null ? '' : 'Content-Encoding: ${response.encoding}\r\n'}'
            'Connection: close\r\n\r\n'));
        socket.add(response.bytes);
        if (response.stall) {
          unawaited(socket.flush().then((_) {
            if (!stalledBody.isCompleted) stalledBody.complete();
          }, onError: (Object _, StackTrace __) {}));
        } else {
          unawaited(socket.close().catchError((_) => socket));
        }
      },
          onError: (Object _, StackTrace __) {},
          onDone: () => sockets.remove(socket));
    });
  }

  final ServerSocket server;
  final Map<String, _Response> responses;
  late final StreamSubscription<Socket> subscription;
  final sockets = <Socket>{};
  final requests = <String>[];
  final unexpected = <String>[];
  final stalledBody = Completer<void>();
  String get address => 'http://127.0.0.1:${server.port}';

  Future<void> close() async {
    await subscription.cancel();
    await server.close();
    for (final socket in sockets.toList()) {
      socket.destroy();
    }
    sockets.clear();
  }
}

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalQuota = ImageDiskQuota.overrideForTesting;
  final originalHttp = HttpOverrides.current;
  final originalLogging = LogManager.recordingEnabled;
  final png = _fixturePng();
  final gzipLarger = GZipCodec(level: 0).encode(png);
  final gzipSmaller = GZipCodec(level: 9).encode(png);
  late Directory root, temporary;
  late ImageDiskQuota quota;
  late _LoopbackImages fixture;
  late RemoteLibraryClient client;
  late String oldAddress, oldProxy, oldConcurrency;
  late int temporaryBaseline;

  setUp(() async {
    HttpOverrides.global = _RealHttpOverrides();
    LogManager.recordingEnabled = false;
    root = await Directory.systemTemp.createTemp('remote-whole-http-');
    temporary = await Directory('${root.path}/temporary').create();
    quota = installTaskDiskQuota(() => [root.path]);
    temporaryBaseline = ImageTemporaryPool.shared.reservedBytes;
    fixture = _LoopbackImages(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      {
        '/identity.png': _Response(png),
        '/gzip-larger.png': _Response(gzipLarger, encoding: 'gzip'),
        '/gzip-smaller.png': _Response(gzipSmaller, encoding: 'gzip'),
        '/short.png': _Response(png.sublist(0, 32), declaredLength: png.length),
        '/gzip-short.png': _Response(
            gzipSmaller.sublist(0, gzipSmaller.length - 5),
            encoding: 'gzip',
            declaredLength: gzipSmaller.length),
        '/empty.png': const _Response([]),
        '/unsupported.png': _Response(png, encoding: 'br'),
        '/oversized.png': _Response(png, declaredLength: (512 << 20) + 1),
        '/stall.png': _Response(png.sublist(0, 32),
            declaredLength: png.length, stall: true),
      },
    );
    oldAddress = appdata.settings[remoteServerAddressSettingIndex];
    oldProxy = appdata.settings[8];
    oldConcurrency = appdata.settings[remoteReaderImageConcurrencySettingIndex];
    appdata.settings[remoteServerAddressSettingIndex] = fixture.address;
    // The production remote policy must keep loopback DIRECT even with a proxy.
    appdata.settings[8] = '127.0.0.1:1';
    appdata.settings[remoteReaderImageConcurrencySettingIndex] = '1';
    client = RemoteLibraryClient.fromCurrentSettings();
  });

  tearDown(() async {
    try {
      expect(fixture.unexpected, isEmpty,
          reason: 'No status/manifest/tile request is allowed');
      expect(ImageTemporaryPool.shared.reservedBytes, temporaryBaseline);
      await quota.drain();
      expect(
          await temporary
              .list(recursive: true)
              .where((entry) => entry is File)
              .toList(),
          isEmpty);
    } finally {
      appdata.settings[remoteServerAddressSettingIndex] = oldAddress;
      appdata.settings[8] = oldProxy;
      appdata.settings[remoteReaderImageConcurrencySettingIndex] =
          oldConcurrency;
      RemoteLibraryClient.rebuildAllTransports();
      await fixture.close();
      await quota.drain();
      ImageDiskQuota.overrideForTesting = originalQuota;
      HttpOverrides.global = originalHttp;
      LogManager.recordingEnabled = originalLogging;
      // This exact directory was created by this test; no user cache/root is used.
      await root.delete(recursive: true);
    }
  });

  RemoteLibraryReadingData readingData(String path) {
    return RemoteLibraryReadingData(
        item: RemoteLibraryComicItem(
      client: client,
      remoteId: 'offline-page',
      rootId: 'test-root',
      title: 'Generated test page',
      sourceTitle: 'fixture',
      remotePath: '/fixture',
      coverUrl: '',
      detailUrl: '/never-detail',
      imageCount: 1,
      totalBytes: png.length,
      episodesData: [
        RemoteLibraryEpisode(
            index: 1,
            title: 'one',
            path: '/fixture',
            imageCount: 1,
            totalBytes: png.length,
            coverUrl: '',
            pages: ['${fixture.address}$path'])
      ],
    ));
  }

  Future<T> isolated<T>(Future<T> Function() body) =>
      IOOverrides.runZoned(body, getSystemTempDirectory: () => temporary);

  Future<void> readWhole(String path) => isolated(() async {
        final data = readingData(path);
        final urls = await data.loadEpNetwork(1);
        final source = await data.resolvePageSource(1, 0, urls.single);
        File? staged;
        try {
          staged = await source
              .openOriginalFile()
              .timeout(const Duration(seconds: 5));
          expect(staged.path, startsWith(temporary.path));
          expect(await staged.readAsBytes(), png);
        } finally {
          await source.dispose();
        }
        expect(await staged.exists(), isFalse);
      });

  Future<void> rejectWhole(String path, [Matcher? error]) => isolated(() async {
        final data = readingData(path);
        final source =
            await data.resolvePageSource(1, 0, '${fixture.address}$path');
        try {
          await expectLater(
              source.openOriginalFile().timeout(const Duration(seconds: 5)),
              throwsA(error ?? anything));
        } finally {
          await source.dispose();
        }
        expect(
            await temporary
                .list(recursive: true)
                .where((entry) => entry is File)
                .toList(),
            isEmpty,
            reason:
                'A rejected body must not leave a final or .part staging file');
      });

  test('identity complete page uses production resolve/open with no manifest',
      () async {
    await readWhole('/identity.png');
    expect(fixture.requests, ['/identity.png']);
  });

  test('gzip wire longer than decoded page is accepted without fake short read',
      () async {
    expect(gzipLarger.length, greaterThan(png.length));
    await readWhole('/gzip-larger.png');
    expect(fixture.requests, ['/gzip-larger.png']);
  });

  test('gzip wire shorter than decoded page is not used as staging maximum',
      () async {
    expect(gzipSmaller.length, lessThan(png.length));
    await readWhole('/gzip-smaller.png');
    expect(fixture.requests, ['/gzip-smaller.png']);
  });

  test('progress exposes decoded length only when actually known', () async {
    for (final path in [
      '/identity.png',
      '/gzip-larger.png',
      '/gzip-smaller.png'
    ]) {
      final response =
          await client.loadImageWithProgress('${fixture.address}$path');
      expect(response.expectedTotalBytes,
          path == '/identity.png' ? png.length : null);
      expect(await response.stream.expand((bytes) => bytes).toList(), png);
    }
    final empty =
        await client.loadImageWithProgress('${fixture.address}/empty.png');
    await expectLater(
        empty.stream.drain<void>(),
        throwsA(isA<HttpImageBodyException>()
            .having((error) => error.reason, 'reason', 'empty-body')));
  });

  test(
      'real identity and gzip truncation reject, clean staging and permit retry',
      () async {
    for (final path in ['/short.png', '/gzip-short.png']) {
      await rejectWhole(path);
      await readWhole('/identity.png');
    }
    expect(fixture.requests,
        ['/short.png', '/identity.png', '/gzip-short.png', '/identity.png']);
  });

  test('empty, unsupported and oversized responses release the sole permit',
      () async {
    for (final path in ['/empty.png', '/unsupported.png', '/oversized.png']) {
      // The generic source rejects a known zero length before subscribing to
      // the body; header encoding/upper-limit failures originate in the client.
      await rejectWhole(
          path,
          path == '/empty.png'
              ? isA<StateError>().having((error) => error.message, 'message',
                  'Original response exceeds staging limit')
              : isA<HttpImageBodyException>());
      await readWhole('/identity.png');
    }
  });

  test(
      'cancelled incomplete body releases permit and task-owned staged bytes',
      () => isolated(() async {
            final data = readingData('/stall.png');
            final source = await data.resolvePageSource(
                1, 0, '${fixture.address}/stall.png');
            final cancellation = ReaderPageCancellation();
            final opening = source.openOriginalFile(cancellation: cancellation);
            final failed = expectLater(opening, throwsA(anything));
            try {
              await fixture.stalledBody.future
                  .timeout(const Duration(seconds: 5));
              cancellation.cancel();
              await failed.timeout(const Duration(seconds: 5));
            } finally {
              cancellation.cancel();
              await source.dispose();
            }
            expect(
                await temporary
                    .list(recursive: true)
                    .where((entry) => entry is File)
                    .toList(),
                isEmpty);
            await readWhole('/identity.png');
            expect(fixture.requests, ['/stall.png', '/identity.png']);
          }));
}
