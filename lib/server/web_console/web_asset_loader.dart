import 'dart:io';
import 'dart:typed_data';

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

  final roots = _candidateAssetRoots();
  for (final root in roots) {
    final file = File(_joinPath(root, normalized));
    try {
      if (!await file.exists()) {
        continue;
      }
      return WebAsset(
        bytes: await file.readAsBytes(),
        contentType: _contentTypeForPath(normalized),
      );
    } catch (_) {}
  }
  return null;
}

List<String> _candidateAssetRoots() {
  final roots = <String>[];
  final seen = <String>{};

  void addRoot(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) {
      return;
    }
    final absolute = Directory(trimmed).absolute.path;
    if (seen.add(absolute)) {
      roots.add(absolute);
    }
  }

  addRoot(Platform.environment['PICAKEEP_WEB_CONSOLE_ROOT']);
  addRoot(Platform.environment['PICAKEEP_ASSET_ROOT']);

  // 基于真实可执行文件定位:Flutter 编译产物里 Platform.script 往往为空/无意义,
  // 而 resolvedExecutable 指向二进制本身(如 /opt/PicaKeep/picakeep),其旁的
  // data/flutter_assets/assets/web_console 即 web 控制台资源,绝对可靠。
  try {
    final exeDir = File(Platform.resolvedExecutable).parent.absolute.path;
    addRoot(_joinPath(exeDir, 'data/flutter_assets/assets/web_console'));
    addRoot(_joinPath(exeDir, 'flutter_assets/assets/web_console'));
    addRoot(_joinPath(exeDir, 'assets/web_console'));
  } catch (_) {}

  final cwd = Directory.current.absolute.path;
  addRoot(_joinPath(cwd, 'assets/web_console'));
  addRoot(_joinPath(cwd, 'data/flutter_assets/assets/web_console'));
  addRoot(_joinPath(cwd, 'flutter_assets/assets/web_console'));

  final scriptDir = File.fromUri(Platform.script).parent.absolute.path;
  addRoot(_joinPath(scriptDir, 'assets/web_console'));
  addRoot(_joinPath(scriptDir, '../assets/web_console'));
  addRoot(_joinPath(scriptDir, '../../assets/web_console'));
  addRoot(_joinPath(scriptDir, '../../../assets/web_console'));
  addRoot(_joinPath(scriptDir, 'data/flutter_assets/assets/web_console'));
  addRoot(_joinPath(scriptDir, 'flutter_assets/assets/web_console'));

  return roots;
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

String _joinPath(String root, String child) {
  final separator = Platform.pathSeparator;
  final normalizedChild = child.replaceAll('/', separator);
  if (root.endsWith('/') || root.endsWith('\\')) {
    return '$root$normalizedChild';
  }
  return '$root$separator$normalizedChild';
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
  if (lower.endsWith('.webmanifest')) {
    return 'application/manifest+json; charset=utf-8';
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
