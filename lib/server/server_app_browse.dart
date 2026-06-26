part of 'server_app.dart';

extension ServerAppBrowse on PicaKeepAdminServer {
  Future<Response> _handleAdminBrowse(Request request) async {
    final rawPath = request.url.queryParameters['path']?.trim() ?? '';
    final roots = _adminBrowseRoots();
    if (rawPath.isEmpty) {
      return _jsonResponse({
        'path': '',
        'parent': '',
        'entries': roots
            .map(
              (root) => {
                'name': root.label,
                'path': root.jumpPath,
                'isDirectory': true,
              },
            )
            .toList(),
        'roots': roots.map((root) => root.toJson()).toList(),
      });
    }

    final normalizedPath = _normalizeBrowsePath(rawPath);
    try {
      final exists =
          await PrivilegedStorageAccess.directoryExists(normalizedPath);
      if (!exists) {
        return _jsonResponse(
          {'error': '目录不存在或无法访问'},
          statusCode: 404,
        );
      }
      final entries = await PrivilegedStorageAccess.listDirectoryEntries(
        normalizedPath,
      );
      final directories = entries.where((entry) => entry.isDirectory).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return _jsonResponse({
        'path': normalizedPath,
        'parent': _parentBrowsePath(normalizedPath),
        'entries': directories
            .map(
              (entry) => {
                'name': entry.name,
                'path': _normalizeBrowsePath(entry.path),
                'isDirectory': true,
              },
            )
            .toList(),
        'roots': roots.map((root) => root.toJson()).toList(),
      });
    } catch (error) {
      return _jsonResponse(
        {'error': '无法读取目录：$error'},
        statusCode: 400,
      );
    }
  }

  List<_AdminBrowseRoot> _adminBrowseRoots() {
    final roots = <_AdminBrowseRoot>[];
    final seen = <String>{};
    void addRoot(String path, [String? label]) {
      final normalized = _normalizeBrowsePath(path);
      if (normalized.isEmpty || !seen.add(normalized)) {
        return;
      }
      roots.add(_AdminBrowseRoot(
        label: label ?? _adminBrowseRootName(normalized),
        jumpPath: normalized,
      ));
    }

    if (Platform.isWindows) {
      for (var code = 65; code <= 90; code++) {
        final path = '${String.fromCharCode(code)}:${Platform.pathSeparator}';
        try {
          if (Directory(path).existsSync()) {
            addRoot(path);
          }
        } catch (_) {}
      }
      return roots;
    }

    if (Platform.isLinux) {
      roots.addAll(_linuxStorageVolumeRoots());
      return roots;
    }

    if (Platform.isAndroid) {
      addRoot('/storage/emulated/0');
      addRoot('/sdcard');
      return roots;
    }

    addRoot('/');
    return roots;
  }

  List<_AdminBrowseRoot> _linuxStorageVolumeRoots() {
    if (!Platform.isLinux) {
      return const <_AdminBrowseRoot>[];
    }
    final roots = <_AdminBrowseRoot>[];
    try {
      for (final entity in Directory('/').listSync(followLinks: false)) {
        final name = _basename(entity.path);
        final match =
            RegExp(r'^vol([1-9]\d*)$', caseSensitive: false).firstMatch(name);
        if (match == null) {
          continue;
        }
        final volumeNumber = match.group(1)!;
        final jumpPath = '/$name/1000';
        try {
          if (Directory(jumpPath).existsSync()) {
            roots.add(_AdminBrowseRoot(
              label: '存储空间 $volumeNumber',
              jumpPath: _normalizeBrowsePath(jumpPath),
            ));
          }
        } catch (_) {}
      }
    } catch (_) {}
    roots.sort((a, b) {
      final aNumber =
          int.tryParse(RegExp(r'\d+').firstMatch(a.label)?.group(0) ?? '') ?? 0;
      final bNumber =
          int.tryParse(RegExp(r'\d+').firstMatch(b.label)?.group(0) ?? '') ?? 0;
      return aNumber.compareTo(bNumber);
    });
    return roots;
  }

  Map<String, dynamic> _configPayload() {
    final config = _config ?? PicaKeepServerConfig.defaults();
    return {
      ...config.toJson(),
      'effectiveManagedDataRoot': resolveManagedDataRoot(config),
    };
  }

  String _adminBrowseRootName(String path) {
    final normalized = _normalizeBrowsePath(path);
    if (Platform.isWindows &&
        normalized.endsWith(':${Platform.pathSeparator}')) {
      return normalized;
    }
    if (normalized == '/') {
      return '/';
    }
    final parts = normalized
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    return parts.isEmpty ? normalized : parts.last;
  }

  String _normalizeBrowsePath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    try {
      return Directory(trimmed).absolute.path;
    } catch (_) {
      return trimmed;
    }
  }

  String _parentBrowsePath(String path) {
    final normalized = _normalizeBrowsePath(path);
    if (normalized.isEmpty) {
      return '';
    }
    final parent = Directory(normalized).parent.path;
    if (_normalizeBrowsePath(parent) == normalized) {
      return '';
    }
    return _normalizeBrowsePath(parent);
  }
}

class _AdminBrowseRoot {
  const _AdminBrowseRoot({
    required this.label,
    required this.jumpPath,
  });

  final String label;
  final String jumpPath;

  Map<String, dynamic> toJson() => {
        'label': label,
        'jumpPath': jumpPath,
      };
}
