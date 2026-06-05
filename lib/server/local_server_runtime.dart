import 'dart:async';
import 'dart:io';

import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/image_favorites.dart';
import 'package:picakeep/foundation/picakeep_mdns.dart';

import 'local_resource_scanner.dart';
import 'library_trash_store.dart';
import 'server_app.dart';
import 'server_config.dart';
import 'server_runtime_state.dart';

class LocalServerRuntimeSnapshot {
  const LocalServerRuntimeSnapshot({
    required this.lifecycle,
    required this.statusText,
    required this.detailText,
    required this.configPath,
    required this.host,
    required this.port,
    required this.logRequests,
    required this.currentDownloadRoot,
    required this.originalDownloadRoot,
    required this.customLibraryRoots,
    this.statusUrl,
    this.adminUrl,
    this.comicCount,
    this.connectionCount,
    this.libraryRootCount,
    this.resourceBytes,
    this.totalRequests,
    this.startedAt,
    this.lastError,
  });

  final String lifecycle;
  final String statusText;
  final String detailText;
  final String configPath;
  final String host;
  final int port;
  final bool logRequests;
  final String currentDownloadRoot;
  final String originalDownloadRoot;
  final List<String> customLibraryRoots;
  final String? statusUrl;
  final String? adminUrl;
  final int? comicCount;
  final int? connectionCount;
  final int? libraryRootCount;
  final int? resourceBytes;
  final int? totalRequests;
  final String? startedAt;
  final String? lastError;

  bool get isRunning => lifecycle == serverRuntimeLifecycleRunning;
  bool get hasError => lifecycle == serverRuntimeLifecycleError;
}

class LocalServerRuntime {
  LocalServerRuntime._() {
    _state.onChanged = _scheduleNotify;
    _state.onStatsChanged = _scheduleStatsNotify;
  }

  static final LocalServerRuntime instance = LocalServerRuntime._();

  final ServerRuntimeState _state = ServerRuntimeState();
  Future<void> _operationQueue = Future.value();
  Timer? _pendingNotifyTimer;
  Timer? _pendingStatsNotifyTimer;

  final LocalResourceScanner _scanner = LocalResourceScanner();
  final PicaKeepMdnsAdvertiser _mdnsAdvertiser = PicaKeepMdnsAdvertiser();
  PicaKeepAdminServer? _server;
  ServerResourceSnapshot? _standaloneSnapshot;
  String? _standaloneSnapshotKey;

  bool get isRunning => _server?.isRunning == true;

  String get configPath =>
      '${App.dataPath}${Platform.pathSeparator}${PicaKeepServerConfig.defaultFileName}';

  void markResourceStateDirty() {
    unawaited(refreshResourceState());
  }

  Future<void> refreshResourceState() {
    return _runExclusive(() async {
      _invalidateStandaloneSnapshot();
      final nextConfig = await _resolveEffectiveConfig();
      await PicaKeepServerConfig.save(configPath, nextConfig);
      final server = _server;
      if (server != null && server.isRunning) {
        final currentConfig = server.config ?? await _loadBaseConfig();
        try {
          if (_hasSameServerBinding(currentConfig, nextConfig)) {
            await server.applyConfig(nextConfig);
          } else {
            await _restartWithResolvedConfig(nextConfig);
          }
        } catch (e, s) {
          _state.addLog('config', '热更新服务配置失败，回退到重新扫描: $e');
          _state.addLog('scan', s.toString());
          try {
            await server.rescanResources();
          } catch (rescanError, rescanStack) {
            _state.addLog('scan', '重新扫描本地资源失败: $rescanError');
            _state.addLog('scan', rescanStack.toString());
          }
        }
      }
      _notify();
    });
  }

  String get _trashIndexPath =>
      '${File(configPath).parent.path}${Platform.pathSeparator}library_trash.json';

  Future<LibraryTrashEntry> restoreTrashItem(String trashId) {
    return _runExclusive(() async {
      _invalidateStandaloneSnapshot();
      final server = _server;
      final LibraryTrashEntry restored;
      if (server != null && server.isRunning) {
        restored = await server.restoreTrashItem(trashId);
      } else {
        restored =
            await LibraryTrashStore(_trashIndexPath).restoreItem(trashId);
      }
      _notify();
      return restored;
    });
  }

  Future<void> purgeTrashItem(String trashId) {
    return _runExclusive(() async {
      _invalidateStandaloneSnapshot();
      final server = _server;
      if (server != null && server.isRunning) {
        final deleted = await server.purgeTrashItem(trashId);
        if (deleted == null) {
          throw StateError('trash item not found');
        }
      } else {
        final deleted =
            await LibraryTrashStore(_trashIndexPath).purgeItem(trashId);
        if (deleted == null) {
          throw StateError('trash item not found');
        }
      }
      _notify();
    });
  }

  Future<void> createFavoriteFolder(String name) {
    return _runExclusive(() async {
      final favorites = LocalFavoritesManager();
      await favorites.init();
      favorites.createFolder(name);
      _invalidateStandaloneSnapshot();
      _notify();
    });
  }

  Future<void> renameFavoriteFolder(String oldName, String newName) {
    return _runExclusive(() async {
      final favorites = LocalFavoritesManager();
      await favorites.init();
      favorites.rename(oldName, newName);
      _invalidateStandaloneSnapshot();
      _notify();
    });
  }

  Future<void> deleteFavoriteFolder(String name) {
    return _runExclusive(() async {
      final favorites = LocalFavoritesManager();
      await favorites.init();
      favorites.deleteFolder(name);
      _invalidateStandaloneSnapshot();
      _notify();
    });
  }

  Future<void> addFavoriteItem(String folder, FavoriteItem item) {
    return _runExclusive(() async {
      final favorites = LocalFavoritesManager();
      await favorites.init();
      favorites.addComic(folder, item);
      _invalidateStandaloneSnapshot();
      _notify();
    });
  }

  Future<void> deleteFavoriteItem(String folder, FavoriteItem item) {
    return _runExclusive(() async {
      final favorites = LocalFavoritesManager();
      await favorites.init();
      favorites.deleteComic(folder, item);
      _invalidateStandaloneSnapshot();
      _notify();
    });
  }

  Future<void> addImageFavorite(ImageFavorite item) {
    return _runExclusive(() async {
      ImageFavoriteManager.add(item);
      _invalidateStandaloneSnapshot();
      _notify();
    });
  }

  Future<void> deleteImageFavorite(ImageFavorite item) {
    return _runExclusive(() async {
      ImageFavoriteManager.delete(item);
      _invalidateStandaloneSnapshot();
      _notify();
    });
  }

  Future<void> start() {
    return _runExclusive(() async {
      if (_server?.isRunning == true) {
        return;
      }
      _invalidateStandaloneSnapshot();
      final config = await _resolveEffectiveConfig();
      await PicaKeepServerConfig.save(configPath, config);
      final server = PicaKeepAdminServer(
        configPath: configPath,
        runtimeState: _state,
      );
      _server = server;
      _notify();
      try {
        await server.start(config: config);
      } catch (e) {
        _server = null;
        await _stopMdnsAdvertisement();
        if (_isPortAlreadyBoundError(e)) {
          _state.markError('端口 ${config.port} 已被占用');
          _notify();
          return;
        }
        _notify();
        rethrow;
      }
      await _startMdnsAdvertisement(config);
      _notify();
    });
  }

  Future<void> stop() {
    return _runExclusive(() async {
      final server = _server;
      if (server == null) {
        _state.markStopped('服务未启动');
        _invalidateStandaloneSnapshot();
        _notify();
        return;
      }
      try {
        await _stopMdnsAdvertisement();
        await server.stop();
      } finally {
        _server = null;
        _invalidateStandaloneSnapshot();
        _notify();
      }
    });
  }

  Future<void> restart() {
    return _runExclusive(() async {
      final config = await _resolveEffectiveConfig();
      await _restartWithResolvedConfig(config);
      _notify();
    });
  }

  bool _isPortAlreadyBoundError(Object error) {
    if (error is! SocketException) {
      return false;
    }
    final message = error.message.toLowerCase();
    return error.osError?.errorCode == 10048 ||
        message.contains('only one usage of each socket address') ||
        message.contains('只允许使用一次');
  }

  Future<LocalServerRuntimeSnapshot> readSnapshot() async {
    final config = await _resolveEffectiveConfig();
    final server = _server;
    if (server != null) {
      final summary = server.buildSummaryPayload();
      return LocalServerRuntimeSnapshot(
        lifecycle: _state.lifecycle,
        statusText:
            (summary['statusText']?.toString().trim().isNotEmpty ?? false)
                ? summary['statusText'].toString()
                : _statusTextForLifecycle(_state.lifecycle),
        detailText: (summary['message']?.toString().trim().isNotEmpty ?? false)
            ? summary['message'].toString()
            : _detailTextForLifecycle(_state),
        configPath: configPath,
        host: summary['host']?.toString() ?? config.host,
        port: _readInt(summary['port']) ?? config.port,
        logRequests: summary['logRequests'] == true,
        currentDownloadRoot: summary['currentDownloadRoot']?.toString() ??
            config.currentDownloadRoot,
        originalDownloadRoot: summary['originalDownloadRoot']?.toString() ??
            config.originalDownloadRoot,
        customLibraryRoots: _readStringList(
            summary['customLibraryRoots'], config.customLibraryRoots),
        statusUrl: summary['statusUrl']?.toString(),
        adminUrl: summary['adminUrl']?.toString(),
        comicCount: _readInt(summary['comicCount']),
        connectionCount: _readInt(summary['connectionCount']),
        libraryRootCount: _readInt(summary['libraryRootCount']),
        resourceBytes: _readInt(summary['resourceBytes']),
        totalRequests: _readInt(summary['totalRequests']),
        startedAt: summary['startedAt']?.toString(),
        lastError: _state.lastError,
      );
    }

    final snapshot = await _readStandaloneSnapshot(config);
    return LocalServerRuntimeSnapshot(
      lifecycle: _state.lifecycle,
      statusText: _statusTextForLifecycle(_state.lifecycle),
      detailText: _detailTextForStandaloneSnapshot(config, snapshot),
      configPath: configPath,
      host: config.host,
      port: config.port,
      logRequests: config.logRequests,
      currentDownloadRoot: config.currentDownloadRoot,
      originalDownloadRoot: config.originalDownloadRoot,
      customLibraryRoots: config.customLibraryRoots,
      statusUrl: _buildStatusUrl(config),
      adminUrl: _buildAdminUrl(config),
      comicCount: snapshot.totalComicCount,
      connectionCount: 0,
      libraryRootCount: config.allLibraryRoots.length,
      resourceBytes: snapshot.totalBytes,
      totalRequests: _state.totalRequests,
      startedAt: _state.startedAt?.toIso8601String(),
      lastError: _state.lastError,
    );
  }

  Future<T> _runExclusive<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _operationQueue;
    _operationQueue = previous.catchError((_, __) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  Future<PicaKeepServerConfig> _resolveEffectiveConfig() async {
    final baseConfig = await _loadBaseConfig();
    final currentDownloadRoot = _resolveCurrentDownloadRoot();
    final originalDownloadRoot =
        appdata.settings[originalDownloadDirSettingIndex].trim();
    final customLibraryRoots =
        decodeLocalComicPathList(appdata.settings[localComicPathsSettingIndex]);
    final customLibraryCollectionShellModes =
        decodeLocalCollectionShellPathMap(
      appdata.settings[localLibraryCollectionShellSettingIndex],
    );
    final port = int.tryParse(
          normalizeServiceAdminPortValue(
            appdata.settings[serviceAdminPortSettingIndex],
          ),
        ) ??
        9527;
    final mode = normalizeManagedDataSourceMode(
      appdata.settings[managedDataSourceModeSettingIndex],
    );

    return baseConfig.copyWith(
      port: port,
      currentDownloadRoot: switch (mode) {
        managedDataSourceModeCurrentAndOriginal => currentDownloadRoot,
        managedDataSourceModeOriginalOnly => '',
        _ => currentDownloadRoot,
      },
      originalDownloadRoot: switch (mode) {
        managedDataSourceModeCurrentAndOriginal =>
          originalDownloadRoot != currentDownloadRoot
              ? originalDownloadRoot
              : '',
        managedDataSourceModeOriginalOnly => originalDownloadRoot,
        _ => '',
      },
      customLibraryRoots: customLibraryRoots,
      customLibraryCollectionShellModes: customLibraryCollectionShellModes,
    );
  }

  Future<PicaKeepServerConfig> _loadBaseConfig() async {
    final file = File(configPath);
    if (!await file.exists()) {
      return PicaKeepServerConfig.defaults();
    }
    return PicaKeepServerConfig.load(configPath);
  }

  bool _hasSameServerBinding(
    PicaKeepServerConfig currentConfig,
    PicaKeepServerConfig nextConfig,
  ) {
    return currentConfig.host.trim() == nextConfig.host.trim() &&
        currentConfig.port == nextConfig.port;
  }

  Future<void> _restartWithResolvedConfig(
    PicaKeepServerConfig config,
  ) async {
    final server = _server;
    if (server != null) {
      try {
        await _stopMdnsAdvertisement();
        await server.stop();
      } finally {
        _server = null;
        _invalidateStandaloneSnapshot();
        _notify();
      }
    }
    _invalidateStandaloneSnapshot();
    await PicaKeepServerConfig.save(configPath, config);
    final nextServer = PicaKeepAdminServer(
      configPath: configPath,
      runtimeState: _state,
    );
    _server = nextServer;
    _notify();
    try {
      await nextServer.start(config: config);
    } catch (e) {
      _server = null;
      await _stopMdnsAdvertisement();
      if (_isPortAlreadyBoundError(e)) {
        _state.markError('端口 ${config.port} 已被占用');
        _notify();
        return;
      }
      _notify();
      rethrow;
    }
    await _startMdnsAdvertisement(config);
  }

  Future<ServerResourceSnapshot> _readStandaloneSnapshot(
    PicaKeepServerConfig config,
  ) async {
    final cacheKey = _buildStandaloneSnapshotKey(config);
    final snapshot = _standaloneSnapshot;
    if (snapshot != null && _standaloneSnapshotKey == cacheKey) {
      return snapshot;
    }
    final nextSnapshot = await _scanner.scan(
      currentDownloadRoot: config.currentDownloadRoot,
      originalDownloadRoot: config.originalDownloadRoot,
      customLibraryRoots: config.customLibraryRoots,
      customLibraryCollectionShellModes:
          config.customLibraryCollectionShellModes,
    );
    _standaloneSnapshot = nextSnapshot;
    _standaloneSnapshotKey = cacheKey;
    return nextSnapshot;
  }

  String _buildStandaloneSnapshotKey(PicaKeepServerConfig config) {
    return [
      config.currentDownloadRoot.trim(),
      config.originalDownloadRoot.trim(),
      encodeLocalCollectionShellPathMap(
        config.customLibraryCollectionShellModes,
      ),
      ...config.customLibraryRoots.map((path) => path.trim()),
    ].where((path) => path.isNotEmpty).join('\n');
  }

  void _invalidateStandaloneSnapshot() {
    _standaloneSnapshot = null;
    _standaloneSnapshotKey = null;
  }

  String _detailTextForStandaloneSnapshot(
    PicaKeepServerConfig config,
    ServerResourceSnapshot snapshot,
  ) {
    if (_state.lifecycle != serverRuntimeLifecycleStopped) {
      return _detailTextForLifecycle(_state);
    }
    if (snapshot.roots.isEmpty) {
      return '当前服务未启动，且还没有可纳入管理的本地资源目录。配置完成后可通过 ${_buildStatusUrl(config)} 暴露状态接口。';
    }
    final availableRootCount =
        snapshot.roots.where((root) => root.exists).length;
    final missingRootCount = snapshot.roots.length - availableRootCount;
    final buffer = StringBuffer(
      '当前服务未启动，但已预扫描到 ${snapshot.totalComicCount} 本漫画、${snapshot.totalBytes} 字节资源。',
    )..write('可用根目录 $availableRootCount 个');
    if (missingRootCount > 0) {
      buffer.write('，缺失根目录 $missingRootCount 个');
    }
    buffer.write('。启动后将直接基于这些本地资源对外提供服务。');
    return buffer.toString();
  }

  String _resolveCurrentDownloadRoot() {
    final configuredPath = appdata.settings[22].trim();
    if (configuredPath.isNotEmpty) {
      return configuredPath;
    }
    return '${App.dataPath}${Platform.pathSeparator}download';
  }

  String _statusTextForLifecycle(String lifecycle) {
    return switch (lifecycle) {
      serverRuntimeLifecycleStarting => '启动中',
      serverRuntimeLifecycleRunning => '在线',
      serverRuntimeLifecycleStopping => '停止中',
      serverRuntimeLifecycleError => '启动失败',
      _ => '未启动',
    };
  }

  String _detailTextForLifecycle(ServerRuntimeState state) {
    if (state.lastError?.trim().isNotEmpty == true) {
      return state.lastError!.trim();
    }
    if (state.lastMessage?.trim().isNotEmpty == true) {
      return state.lastMessage!.trim();
    }
    return '当前本地服务尚未启动。配置文件与资源路径已准备，可直接在设置或服务信息页启动本地服务。';
  }

  Future<void> _startMdnsAdvertisement(PicaKeepServerConfig config) async {
    try {
      await _mdnsAdvertiser.start(
        host: config.host,
        port: config.port,
      );
      _state.addLog('mdns', '已发布 mDNS 服务 _picakeep._tcp.local:${config.port}');
    } catch (error) {
      _state.addLog('mdns', 'mDNS 服务发布失败：$error');
    }
  }

  Future<void> _stopMdnsAdvertisement() async {
    try {
      await _mdnsAdvertiser.stop();
    } catch (error) {
      _state.addLog('mdns', 'mDNS 服务撤销失败：$error');
    }
  }

  String _buildStatusUrl(PicaKeepServerConfig config) {
    return 'http://${_buildDisplayHost(config.host)}:${config.port}/status';
  }

  String _buildAdminUrl(PicaKeepServerConfig config) {
    return 'http://${_buildDisplayHost(config.host)}:${config.port}/admin';
  }

  String _buildDisplayHost(String host) {
    final trimmed = host.trim();
    if (trimmed.isEmpty ||
        trimmed == '0.0.0.0' ||
        trimmed == '::' ||
        trimmed == '::0') {
      return '<当前设备IP>';
    }
    return trimmed;
  }

  List<String> _readStringList(Object? value, List<String> fallback) {
    if (value is List) {
      final seen = <String>{};
      return value
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty && seen.add(e))
          .toList(growable: false);
    }
    return fallback;
  }

  int? _readInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  void _scheduleNotify() {
    _pendingNotifyTimer?.cancel();
    _pendingNotifyTimer = Timer(const Duration(milliseconds: 250), _notifyNow);
  }

  void _scheduleStatsNotify() {
    _pendingStatsNotifyTimer?.cancel();
    _pendingStatsNotifyTimer =
        Timer(const Duration(milliseconds: 500), _notifyStatsNow);
  }

  void _notify() {
    _pendingNotifyTimer?.cancel();
    _notifyNow();
  }

  void _notifyNow() {
    App.notifyServiceRuntimeChanged();
  }

  void _notifyStatsNow() {
    App.notifyServiceStatsChanged();
  }
}
