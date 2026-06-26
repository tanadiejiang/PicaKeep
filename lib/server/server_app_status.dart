part of 'server_app.dart';

extension ServerAppStatus on PicaKeepAdminServer {
  String _deviceSystem() {
    return switch (Platform.operatingSystem.toLowerCase()) {
      'android' => 'Android',
      'ios' => 'iOS',
      'macos' => 'macOS',
      'windows' => 'Windows',
      'linux' => 'Linux',
      _ => Platform.operatingSystem.trim().isEmpty
          ? '未知系统'
          : Platform.operatingSystem,
    };
  }

  String _deviceName() {
    final hostName = Platform.localHostname.trim();
    return hostName.isEmpty ? '当前设备' : hostName;
  }

  String _deviceSummary(String deviceSystem, String deviceName) {
    if (deviceSystem.trim().isEmpty) {
      return deviceName;
    }
    if (deviceName.trim().isEmpty) {
      return deviceSystem;
    }
    return '$deviceSystem · $deviceName';
  }

  Map<String, dynamic> buildStatusPayload() {
    final config = _config ?? PicaKeepServerConfig.defaults();
    final snapshot = _snapshot;
    final availableLibraryRootCount =
        snapshot?.roots.where((root) => root.exists).length ?? 0;
    final missingLibraryRootCount =
        snapshot?.roots.where((root) => !root.exists).length ?? 0;
    final deviceSystem = _deviceSystem();
    final deviceName = _deviceName();
    return {
      'serviceName': 'PicaKeepServer',
      'deviceSystem': deviceSystem,
      'deviceName': deviceName,
      'deviceSummary': _deviceSummary(deviceSystem, deviceName),
      'lifecycle': _state.lifecycle,
      'statusText': _state.isRunning ? '在线' : _runtimeStatusText(),
      'online': _state.isRunning,
      'message': _runtimeMessage(),
      'lastError': _state.lastError,
      'startedAt': _state.startedAt?.toIso8601String(),
      'activeConnections': _state.activeConnections,
      'totalRequests': _state.totalRequests,
      'comicCount': snapshot?.totalComicCount ?? 0,
      'connectionCount': _state.activeConnections,
      'libraryRootCount': config.allLibraryRoots.length,
      'availableLibraryRootCount': availableLibraryRootCount,
      'missingLibraryRootCount': missingLibraryRootCount,
      'resourceBytes': snapshot?.totalBytes ?? 0,
      'resourceGeneratedAt': snapshot?.generatedAt.toIso8601String(),
      'librarySignature': _librarySignature ?? '',
      'appUrl': _buildAppUrl(),
      'statusUrl': _buildStatusUrl(),
      'adminUrl': _buildAdminUrl(),
      'consolePasswordEmpty': config.consolePassword.trim().isEmpty,
    };
  }

  Map<String, dynamic> buildSummaryPayload() {
    final config = _config ?? PicaKeepServerConfig.defaults();
    final snapshot = _snapshot;
    return {
      ...buildStatusPayload(),
      'host': config.host,
      'port': _server?.port ?? config.port,
      'logRequests': config.logRequests,
      'configPath': configPath,
      'dataPath': App.dataPath,
      'currentDownloadRoot': config.currentDownloadRoot,
      'originalDownloadRoot': config.originalDownloadRoot,
      'customLibraryRoots': config.customLibraryRoots,
      'managedDataRoot': config.managedDataRoot,
      'effectiveManagedDataRoot': resolveManagedDataRoot(config),
      'rootSummaries':
          snapshot?.roots.map((root) => root.toJson()).toList() ?? const [],
    };
  }

  String _buildStatusUrl() {
    final config = _config ?? PicaKeepServerConfig.defaults();
    final port = _server?.port ?? config.port;
    return 'http://${_buildDisplayHost(config.host)}:$port/status';
  }

  String _buildAppUrl() {
    final config = _config ?? PicaKeepServerConfig.defaults();
    final port = _server?.port ?? config.port;
    return 'http://${_buildDisplayHost(config.host)}:$port/';
  }

  String _buildAdminUrl() {
    final config = _config ?? PicaKeepServerConfig.defaults();
    final port = _server?.port ?? config.port;
    return 'http://${_buildDisplayHost(config.host)}:$port/admin-view';
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

  String _runtimeStatusText() {
    return switch (_state.lifecycle) {
      serverRuntimeLifecycleStarting => '启动中',
      serverRuntimeLifecycleStopping => '停止中',
      serverRuntimeLifecycleError => '启动失败',
      _ => '未启动',
    };
  }

  String _runtimeMessage() {
    if (_state.isRunning) {
      return '当前服务端仅基于本机可访问的本地资源提供服务，客户端模式连接后访问的也是这些资源。';
    }
    if (_state.lastError?.trim().isNotEmpty == true) {
      return _state.lastError!.trim();
    }
    if (_state.lastMessage?.trim().isNotEmpty == true) {
      return _state.lastMessage!.trim();
    }
    return '当前本地服务尚未启动。';
  }
}
