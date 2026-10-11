import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:image/image.dart' as image;

/// Raw loopback HTTP lets tests send genuinely malformed framing/short bodies.
class HttpImageReply {
  HttpImageReply(this.body,
      {this.encoding,
      this.declaredLength,
      this.chunked = false,
      this.brokenChunked = false,
      this.prefixBytes = 0,
      this.disconnectBeforeHeaders = false,
      this.release,
      this.status = 200});
  final List<int> body;
  final String? encoding;
  final int? declaredLength;
  final bool chunked;
  final bool brokenChunked;
  final int prefixBytes;
  final bool disconnectBeforeHeaders;
  final Future<void>? release;
  final int status;
}

class HttpImageFixture {
  HttpImageFixture._(this.server, this.reply) {
    server.listen(_accept);
  }
  final ServerSocket server;
  final HttpImageReply Function(Uri uri, String headers) reply;
  final sockets = <Socket>{};
  final requests = <Uri>[];
  final requestHeaders = <String>[];

  static Future<HttpImageFixture> start(
          HttpImageReply Function(Uri uri, String headers) reply) async =>
      HttpImageFixture._(
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), reply);

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  void _accept(Socket socket) {
    sockets.add(socket);
    var received = '';
    var sent = false;
    socket.listen((bytes) {
      received += latin1.decode(bytes);
      if (sent || !received.contains('\r\n\r\n')) return;
      sent = true;
      final uri = Uri.parse(received.split(' ')[1]);
      requests.add(uri);
      requestHeaders.add(received);
      unawaited(_respond(socket, reply(uri, received)));
    }, onError: (Object _) {}, onDone: () => sockets.remove(socket));
  }

  Future<void> _respond(Socket socket, HttpImageReply response) async {
    try {
      if (response.disconnectBeforeHeaders) {
        socket.destroy();
        return;
      }
      final head = 'HTTP/1.1 ${response.status} fixture\r\n'
          'Connection: close\r\nContent-Type: image/png\r\n'
          '${response.encoding == null ? '' : 'Content-Encoding: ${response.encoding}\r\n'}'
          '${response.chunked ? 'Transfer-Encoding: chunked' : 'Content-Length: ${response.declaredLength ?? response.body.length}'}\r\n\r\n';
      socket.add(latin1.encode(head));
      if (!response.chunked && response.prefixBytes > 0) {
        socket.add(response.body.sublist(0, response.prefixBytes));
      }
      await socket.flush();
      await response.release;
      if (response.chunked) {
        if (response.body.isNotEmpty) {
          socket.add(
              latin1.encode('${response.body.length.toRadixString(16)}\r\n'));
          socket.add(response.body);
          socket.add(latin1.encode('\r\n'));
        }
        if (!response.brokenChunked) socket.add(latin1.encode('0\r\n\r\n'));
      } else {
        socket.add(response.body.sublist(response.prefixBytes));
      }
      await socket.flush();
      await socket.close();
    } catch (_) {
      // Client rejection/cancellation intentionally closes its connection.
      socket.destroy();
    } finally {
      sockets.remove(socket);
    }
  }

  Future<void> close() async {
    for (final socket in sockets.toList()) {
      socket.destroy();
    }
    await server.close();
  }
}

class _RealHttpOverrides extends HttpOverrides {}

HttpClient directImageClient() => HttpOverrides.runWithHttpOverrides(
    () => HttpClient()..findProxy = (_) => 'DIRECT', _RealHttpOverrides());

Dio directImageDio() => Dio(BaseOptions(followRedirects: false))
  ..httpClientAdapter =
      IOHttpClientAdapter(createHttpClient: directImageClient);

/// Both wire-size directions use the SAME valid PNG. level=0's gzip overhead
/// makes it larger; normal gzip compresses the intentionally uncompressed PNG.
Uint8List syntheticHttpPng() => image.encodePng(
    image.Image(width: 24, height: 32)..clear(image.ColorRgb8(60, 120, 180)),
    level: 0);
