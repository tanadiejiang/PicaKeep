import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/image_pipeline/cover_decode_target.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';

import 'support/image_disk_quota_fixture.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory task;
  late HttpServer server;
  late RemoteLibraryClient client;
  late String url;
  late String oldAddress;
  HttpOverrides? oldHttp;
  final requests = <String>[];
  final files = <int, Uint8List>{};
  var landscape = false;

  setUpAll(() async {
    final parent = Directory(r'D:\picakeep-image-pipeline-022-work\test-temp');
    await parent.create(recursive: true);
    task = await parent.createTemp('remote-cover-');
    App.dataPath = task.path;
    App.cachePath = p.join(task.path, 'cache');
    for (final width in [384, 768, 1536, 2400]) {
      files[width] = Uint8List.fromList(img.encodePng(
          img.Image(width: width, height: width * 3 ~/ 4, numChannels: 4)
            ..setPixelRgba(0, 0, 255, 0, 0, 255)));
    }
  });
  setUp(() async {
    oldAddress = appdata.settings[remoteServerAddressSettingIndex];
    oldHttp = HttpOverrides.current;
    HttpOverrides.global = _RealHttp();
    installTaskDiskQuota(() => [task.path]);
    requests.clear();
    landscape = false;
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((request) async {
      if (request.uri.path == '/status') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'imageCapabilities': {
            'version': 1,
            'coverWidths': [1536, 384, 768],
            'coverFormats': ['png'],
            'manifests': false,
          }
        }));
      } else {
        requests.add(request.uri.toString());
        final width =
            int.tryParse(request.uri.queryParameters['w'] ?? '') ?? 2400;
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.headers.set('x-image-source-version', 'v1');
        request.response.headers.set('x-image-width', '$width');
        request.response.headers.set(
            'x-image-height', '${landscape ? width ~/ 2 : width * 3 ~/ 4}');
        final bytes = files[width]!;
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
      }
      await request.response.close();
    });
    appdata.settings[remoteServerAddressSettingIndex] =
        'http://127.0.0.1:${server.port}';
    client = RemoteLibraryClient.fromCurrentSettings();
    url = client.resolveUrlString('/api/library/items/task/cover?v=v1');
  });
  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await server.close(force: true);
    await ImageDiskQuota.shared.drain();
    ImageDiskQuota.overrideForTesting = null;
    appdata.settings[remoteServerAddressSettingIndex] = oldAddress;
    HttpOverrides.global = oldHttp;
  });
  tearDownAll(() => task.delete(recursive: true));

  test(
      'remote chooses the first advertised width that satisfies physical cover dimensions',
      () async {
    expect(
        await client.loadCoverDerivative(url,
            minimumWidth: 1200, minimumHeight: 900, fit: BoxFit.cover),
        files[1536]);
    expect(Uri.parse(requests.single).queryParameters['w'], '1536');
    requests.clear();
    expect(
        await client.loadCoverDerivative(url,
            minimumWidth: 1700, minimumHeight: 900, fit: BoxFit.cover),
        isNull);
    expect(requests, isEmpty,
        reason: 'Insufficient advertised variants use the original URL');
  });

  test(
      'remote cover uses both frame axes and escalates a short landscape variant',
      () async {
    landscape = true;
    await client.loadCoverDerivative(url,
        minimumWidth: 500, minimumHeight: 500, fit: BoxFit.cover);
    expect(requests.map((value) => Uri.parse(value).queryParameters['w']),
        ['768', '1536']);
    requests.clear();
    await client.loadCoverDerivative(url,
        minimumWidth: 500, minimumHeight: 500, fit: BoxFit.contain);
    expect(requests.map((value) => Uri.parse(value).queryParameters['w']),
        ['768']);
  });

  Future<ui.Image> resolve(int width, int height) async {
    final provider = CoverDecodeTarget(client.coverImageProviderForUrl(url)!,
        frameWidth: width, frameHeight: height, fit: BoxFit.cover);
    final stream = provider.resolve(ImageConfiguration.empty);
    final ready = Completer<ui.Image>();
    late ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      ready.complete(info.image.clone());
      stream.removeListener(listener);
    }, onError: (Object error, StackTrace? stack) {
      ready.completeError(error, stack);
      stream.removeListener(listener);
    });
    stream.addListener(listener);
    return ready.future.timeout(const Duration(seconds: 10));
  }

  test(
      'same remote URL grows from DPR1 to DPR4 and retains separate encoded cache variants',
      () async {
    final small = await resolve(300, 225);
    final large = await resolve(1200, 900);
    final repeat = await resolve(300, 225);
    final original = await resolve(2000, 1500);
    try {
      expect((small.width, small.height), (300, 225));
      expect((large.width, large.height), (1200, 900));
      expect((repeat.width, repeat.height), (300, 225));
      expect((original.width, original.height), (2000, 1500));
      expect(requests.map((value) => Uri.parse(value).queryParameters['w']),
          ['384', '1536', null]);
      final cache =
          Directory(p.join(task.path, 'cache', 'remote_library_covers'));
      expect(await cache.list().where((file) => file is File).length, 3);
      expect(ImageDiskQuota.shared.pendingCount, 0);
    } finally {
      small.dispose();
      large.dispose();
      repeat.dispose();
      original.dispose();
    }
  });
}
