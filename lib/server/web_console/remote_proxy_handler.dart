import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import '../server_runtime_state.dart';

typedef JsonResponseBuilder = Response Function(
  Map<String, dynamic> body, {
  int statusCode,
});

Future<Response?> handleRemoteProxyRequest(
  Request request, {
  required ServerRuntimeState state,
  required JsonResponseBuilder jsonResponse,
}) async {
  if (request.url.path != 'api/remote/proxy') {
    return null;
  }
  if (request.method != 'GET') {
    return jsonResponse({'error': 'method not allowed'}, statusCode: 405);
  }

  final targetText = request.url.queryParameters['target']?.trim() ?? '';
  final pathText = request.url.queryParameters['path']?.trim() ?? '';
  final target = Uri.tryParse(targetText);
  if (target == null ||
      (target.scheme != 'http' && target.scheme != 'https') ||
      target.host.trim().isEmpty) {
    return jsonResponse({'error': 'invalid target'}, statusCode: 400);
  }
  final pathUri = Uri.tryParse('http://proxy$pathText');
  if (pathText.isEmpty || !pathText.startsWith('/') || pathUri == null) {
    return jsonResponse({'error': 'invalid path'}, statusCode: 400);
  }

  final upstreamUri = target.replace(
    path: _joinPaths(target.path, pathUri.path),
    query: _mergeQuery(target.query, pathUri.query),
    fragment: '',
  );
  state.addLog('remote_proxy', 'GET $upstreamUri');

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final upstreamRequest =
        await client.getUrl(upstreamUri).timeout(const Duration(seconds: 15));
    final range = request.headers[HttpHeaders.rangeHeader];
    if (range != null && range.trim().isNotEmpty) {
      upstreamRequest.headers.set(HttpHeaders.rangeHeader, range);
    }
    upstreamRequest.headers.set(HttpHeaders.acceptHeader,
        request.headers[HttpHeaders.acceptHeader] ?? '*/*');
    final upstreamResponse =
        await upstreamRequest.close().timeout(const Duration(seconds: 15));
    final headers = <String, String>{};
    void copyHeader(String name) {
      final values = upstreamResponse.headers[name];
      if (values != null && values.isNotEmpty) {
        headers[name] = values.join(', ');
      }
    }

    copyHeader(HttpHeaders.contentTypeHeader);
    copyHeader(HttpHeaders.contentLengthHeader);
    copyHeader(HttpHeaders.acceptRangesHeader);
    copyHeader(HttpHeaders.contentRangeHeader);
    headers.putIfAbsent(
        HttpHeaders.cacheControlHeader, () => 'public, max-age=300');

    if (upstreamResponse.statusCode < 200 ||
        upstreamResponse.statusCode >= 300) {
      final bytes = await _readLimited(upstreamResponse, 64 * 1024);
      final text = utf8.decode(bytes, allowMalformed: true);
      return jsonResponse(
        {
          'error': 'remote returned ${upstreamResponse.statusCode}',
          'body': text
        },
        statusCode: upstreamResponse.statusCode == 404 ? 404 : 502,
      );
    }

    return Response(
      upstreamResponse.statusCode,
      body: upstreamResponse,
      headers: headers,
    );
  } on TimeoutException {
    return jsonResponse({'error': 'remote request timeout'}, statusCode: 502);
  } catch (error) {
    return jsonResponse({'error': 'remote request failed: $error'},
        statusCode: 502);
  } finally {
    client.close(force: true);
  }
}

String _joinPaths(String basePath, String subPath) {
  final base = basePath.trim();
  if (base.isEmpty || base == '/') {
    return subPath;
  }
  return '${base.replaceFirst(RegExp(r'/+$'), '')}/${subPath.replaceFirst(RegExp(r'^/+'), '')}';
}

String? _mergeQuery(String baseQuery, String subQuery) {
  if (baseQuery.isEmpty) {
    return subQuery.isEmpty ? null : subQuery;
  }
  if (subQuery.isEmpty) {
    return baseQuery;
  }
  return '$baseQuery&$subQuery';
}

Future<List<int>> _readLimited(Stream<List<int>> stream, int limit) async {
  final result = <int>[];
  await for (final chunk in stream) {
    final remaining = limit - result.length;
    if (remaining <= 0) break;
    result.addAll(chunk.length <= remaining ? chunk : chunk.take(remaining));
  }
  return result;
}
