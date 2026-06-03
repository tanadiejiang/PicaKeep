import 'package:shelf/shelf.dart';

import 'web_asset_loader.dart';

Future<Response?> handleWebConsoleRequest(Request request) async {
  final path = request.url.path;
  if (path == 'api' || path.startsWith('api/')) {
    return null;
  }

  if (path == 'admin') {
    return Response.movedPermanently('/');
  }

  if (request.method != 'GET' && request.method != 'HEAD') {
    return Response(405, body: 'method not allowed');
  }

  final assetPath = _isStaticAssetPath(path) ? path : 'index.html';
  final asset = await loadWebAsset(assetPath);
  if (asset == null) {
    return Response.notFound('not found');
  }

  final isIndex = assetPath == 'index.html';
  return Response.ok(
    asset.bytes,
    headers: {
      'content-type': asset.contentType,
      'cache-control': isIndex ? 'no-cache' : 'public, max-age=300',
    },
  );
}

bool _isStaticAssetPath(String path) {
  final segments = path.split('/').where((part) => part.isNotEmpty).toList();
  if (segments.isEmpty) {
    return false;
  }
  final first = segments.first;
  if (first == 'css' ||
      first == 'js' ||
      first == 'assets' ||
      first == 'fonts') {
    return true;
  }
  final lower = path.toLowerCase();
  return lower.endsWith('.html') ||
      lower.endsWith('.css') ||
      lower.endsWith('.js') ||
      lower.endsWith('.json') ||
      lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.svg') ||
      lower.endsWith('.woff2');
}
