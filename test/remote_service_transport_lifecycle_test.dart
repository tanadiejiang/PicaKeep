import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';

void main() {
  test('stable RemoteLibraryClient reference uses a rebuilt transport',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final firstRequestReceived = Completer<void>();
    final releaseFirstResponse = Completer<void>();
    var requestCount = 0;

    final subscription = server.listen((request) async {
      requestCount++;
      if (requestCount == 1) {
        firstRequestReceived.complete();
        await releaseFirstResponse.future;
      }
      request.response.headers.contentType = ContentType.json;
      request.response
          .write(jsonEncode({'items': <Object>[], 'roots': <Object>[]}));
      await request.response.close();
    });

    final oldAddress = appdata.settings[remoteServerAddressSettingIndex];
    final oldProxy = appdata.settings[8];
    final address = 'http://127.0.0.1:${server.port}';
    appdata.settings[remoteServerAddressSettingIndex] = address;
    appdata.settings[8] = '127.0.0.1:65530';
    addTearDown(() {
      appdata.settings[remoteServerAddressSettingIndex] = oldAddress;
      appdata.settings[8] = oldProxy;
      RemoteLibraryClient.rebuildAllTransports();
    });

    try {
      final client = RemoteLibraryClient.fromCurrentSettings();
      final first = client.fetchItems(forceRefresh: true);
      await firstRequestReceived.future.timeout(const Duration(seconds: 2));

      RemoteLibraryClient.rebuildAllTransports();
      releaseFirstResponse.complete();
      try {
        await first;
      } catch (_) {
        // Closing the old transport is allowed to fail its in-flight request.
      }

      final items = await client.fetchItems(forceRefresh: true);
      expect(items, isEmpty);
      expect(requestCount, greaterThanOrEqualTo(2));
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
