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

    // 特殊路径：__mounts__ → 显示所有挂载路径的聚合列表
    if (rawPath == '__mounts__') {
      return _handleMountsVirtualDirectory();
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

  /// 处理"挂载路径"虚拟目录：聚合所有挂载项
  Response _handleMountsVirtualDirectory() {
    final entries = <_AdminBrowseRoot>[];
    final seen = <String>{};

    // 1. Docker 用户挂载路径
    for (final mount in _linuxDockerMountRoots()) {
      if (seen.add(mount.jumpPath)) {
        entries.add(mount);
      }
    }

    // 2. 自定义资源根
    if (_config != null) {
      for (final customPath in _config!.customLibraryRoots) {
        final normalized = _normalizeBrowsePath(customPath);
        if (normalized.isNotEmpty && seen.add(normalized)) {
          entries.add(_AdminBrowseRoot(
            label: '自定义: ${_basename(normalized)}',
            jumpPath: normalized,
          ));
        }
      }
    }

    // 注意：存储空间已在根标签显示，这里不再重复

    final roots = _adminBrowseRoots();
    return _jsonResponse({
      'path': '挂载路径',  // 显示友好名称
      'parent': '',  // 返回空表示回到根列表
      'entries': entries
          .map((e) => {
                'name': e.label,
                'path': e.jumpPath,
                'isDirectory': true,
              })
          .toList(),
      'roots': roots.map((root) => root.toJson()).toList(),  // 保持根标签栏
    });
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
      // 1. 根目录：系统根 `/`，列出所有顶层文件夹
      roots.add(const _AdminBrowseRoot(
        label: '根目录',
        jumpPath: '/',
      ));

      // 2. 挂载路径：虚拟导航，点击后显示所有挂载项
      roots.add(const _AdminBrowseRoot(
        label: '挂载路径',
        jumpPath: '__mounts__',
      ));

      // 3. 存储空间：vol*/1000 直接列在根标签里
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

  /// Docker 用户挂载路径（从 /proc/mounts 过滤简短路径）
  List<_AdminBrowseRoot> _linuxDockerMountRoots() {
    if (!Platform.isLinux) {
      return const <_AdminBrowseRoot>[];
    }
    final roots = <_AdminBrowseRoot>[];

    // 从 /proc/mounts 读取挂载点，只保留用户配置的简短路径挂载
    try {
      final mountsFile = File('/proc/mounts');
      if (mountsFile.existsSync()) {
        final lines = mountsFile.readAsLinesSync();
        final seen = <String>{};

        for (final line in lines) {
          final parts = line.split(' ');
          if (parts.length < 2) continue;

          final source = parts[0]; // 宿主机路径
          final mountPoint = parts[1]; // 容器内挂载路径

          // 过滤规则：只保留用户配置的挂载
          // 1. 排除系统目录
          if (mountPoint == '/' ||
              mountPoint.startsWith('/proc') ||
              mountPoint.startsWith('/sys') ||
              mountPoint.startsWith('/dev') ||
              mountPoint.startsWith('/etc') ||
              mountPoint.startsWith('/run') ||
              mountPoint.startsWith('/tmp') ||
              mountPoint.startsWith('/var/run') ||
              mountPoint.startsWith('/var/lock')) {
            continue;
          }

          // 2. 排除 docker overlay2 系统挂载
          if (mountPoint.contains('/docker/overlay') ||
              mountPoint.contains('/merged') ||
              mountPoint.contains('/upperdir') ||
              mountPoint.contains('/workdir')) {
            continue;
          }

          // 3. 只保留"简短路径"（路径段数 ≤ 3）
          final segments = mountPoint.split('/').where((s) => s.isNotEmpty).toList();
          if (segments.length > 3) {
            continue;
          }

          // 4. 或者：宿主机路径在 /vol* 或 /var/apps/ 下
          final isUserMount = source.startsWith('/vol') ||
                              source.startsWith('/var/apps/');

          // 简短路径 或 明确的用户挂载源 → 保留
          if (segments.length <= 2 || isUserMount) {
            if (seen.add(mountPoint)) {
              final label = '挂载: ${_basename(mountPoint)}';
              roots.add(_AdminBrowseRoot(
                label: label,
                jumpPath: _normalizeBrowsePath(mountPoint),
              ));
            }
          }
        }

        if (roots.isNotEmpty) {
          roots.sort((a, b) => a.jumpPath.compareTo(b.jumpPath));
        }
      }
    } catch (_) {}

    return roots;
  }

  /// 存储空间：扫描 /vol* 目录，跳转到 /vol*/1000（原逻辑）
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
