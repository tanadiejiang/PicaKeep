import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

class WebAsset {
  const WebAsset({
    required this.bytes,
    required this.contentType,
  });

  final Uint8List bytes;
  final String contentType;
}

Future<WebAsset?> loadWebAsset(String relativePath) async {
  final normalized = _normalizeRelativePath(relativePath);
  if (normalized == null) {
    return null;
  }
  try {
    final data = await rootBundle.load('assets/web_console/$normalized');
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    return WebAsset(bytes: bytes, contentType: _contentTypeForPath(normalized));
  } catch (_) {
    return null;
  }
}

String? _normalizeRelativePath(String relativePath) {
  final trimmed = relativePath.trim().replaceAll('\\', '/');
  final withoutLeadingSlash = trimmed.replaceFirst(RegExp(r'^/+'), '');
  if (withoutLeadingSlash.isEmpty) {
    return 'index.html';
  }
  final parts = <String>[];
  for (final part in withoutLeadingSlash.split('/')) {
    if (part.isEmpty || part == '.') {
      continue;
    }
    if (part == '..') {
      return null;
    }
    parts.add(part);
  }
  if (parts.isEmpty) {
    return 'index.html';
  }
  return parts.join('/');
}

String _contentTypeForPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.html')) {
    return 'text/html; charset=utf-8';
  }
  if (lower.endsWith('.css')) {
    return 'text/css; charset=utf-8';
  }
  if (lower.endsWith('.js')) {
    return 'application/javascript; charset=utf-8';
  }
  if (lower.endsWith('.json')) {
    return 'application/json; charset=utf-8';
  }
  if (lower.endsWith('.png')) {
    return 'image/png';
  }
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
    return 'image/jpeg';
  }
  if (lower.endsWith('.gif')) {
    return 'image/gif';
  }
  if (lower.endsWith('.webp')) {
    return 'image/webp';
  }
  if (lower.endsWith('.svg')) {
    return 'image/svg+xml';
  }
  if (lower.endsWith('.woff2')) {
    return 'font/woff2';
  }
  return 'application/octet-stream';
}
