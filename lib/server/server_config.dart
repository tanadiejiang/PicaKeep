import 'dart:convert';
import 'dart:io';

import '../foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/local_library_settings.dart';

class PicaKeepServerConfig {
  const PicaKeepServerConfig({
    required this.host,
    required this.port,
    required this.currentDownloadRoot,
    required this.originalDownloadRoot,
    required this.customLibraryRoots,
    required this.customLibraryCollectionShellModes,
    required this.managedDataRoot,
    required this.logRequests,
    required this.consolePassword,
  });

  // 配置文件名用 .data 后缀（内容仍为 JSON），避免被其他程序/扫描器
  // 当成普通 json 误扫。旧 picakeep_server.json 不做迁移（按计划 04 决策）。
  static const defaultFileName = 'picakeep_server.data';

  final String host;
  final int port;
  final String currentDownloadRoot;
  final String originalDownloadRoot;
  final List<String> customLibraryRoots;
  final Map<String, bool> customLibraryCollectionShellModes;
  final String managedDataRoot;
  final bool logRequests;
  final String consolePassword;

  List<String> get allLibraryRoots => [
        if (currentDownloadRoot.trim().isNotEmpty) currentDownloadRoot.trim(),
        if (originalDownloadRoot.trim().isNotEmpty) originalDownloadRoot.trim(),
        ...customLibraryRoots.map((e) => e.trim()).where((e) => e.isNotEmpty),
      ];

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'currentDownloadRoot': currentDownloadRoot,
        'originalDownloadRoot': originalDownloadRoot,
        'customLibraryRoots': customLibraryRoots,
        'customLibraryCollectionShellModes': encodeLocalCollectionShellPathMap(
            customLibraryCollectionShellModes),
        'managedDataRoot': managedDataRoot,
        'logRequests': logRequests,
        'consolePassword': consolePassword,
      };

  PicaKeepServerConfig copyWith({
    String? host,
    int? port,
    String? currentDownloadRoot,
    String? originalDownloadRoot,
    List<String>? customLibraryRoots,
    Map<String, bool>? customLibraryCollectionShellModes,
    String? managedDataRoot,
    bool? logRequests,
    String? consolePassword,
  }) {
    return PicaKeepServerConfig(
      host: host ?? this.host,
      port: port ?? this.port,
      currentDownloadRoot: currentDownloadRoot ?? this.currentDownloadRoot,
      originalDownloadRoot: originalDownloadRoot ?? this.originalDownloadRoot,
      customLibraryRoots: customLibraryRoots ?? this.customLibraryRoots,
      customLibraryCollectionShellModes: customLibraryCollectionShellModes ??
          this.customLibraryCollectionShellModes,
      managedDataRoot: managedDataRoot ?? this.managedDataRoot,
      logRequests: logRequests ?? this.logRequests,
      consolePassword: consolePassword ?? this.consolePassword,
    );
  }

  static PicaKeepServerConfig defaults() {
    return const PicaKeepServerConfig(
      host: '0.0.0.0',
      port: defaultServiceAdminPortInt,
      currentDownloadRoot: '',
      originalDownloadRoot: '',
      customLibraryRoots: [],
      customLibraryCollectionShellModes: {},
      managedDataRoot: '',
      logRequests: false,
      consolePassword: '',
    );
  }

  static PicaKeepServerConfig fromJson(Map<String, dynamic> json) {
    return PicaKeepServerConfig(
      host: (json['host']?.toString().trim().isNotEmpty ?? false)
          ? json['host'].toString().trim()
          : '0.0.0.0',
      port: _normalizePort(json['port']),
      currentDownloadRoot: json['currentDownloadRoot']?.toString().trim() ?? '',
      originalDownloadRoot:
          json['originalDownloadRoot']?.toString().trim() ?? '',
      customLibraryRoots: _normalizeStringList(json['customLibraryRoots']),
      customLibraryCollectionShellModes: _normalizeCollectionShellModes(
        json['customLibraryCollectionShellModes'],
      ),
      managedDataRoot: json['managedDataRoot']?.toString().trim() ??
          json['favoritesDbRoot']?.toString().trim() ??
          json['historyDbRoot']?.toString().trim() ??
          '',
      logRequests: json['logRequests'] == true,
      consolePassword: json['consolePassword']?.toString() ?? '',
    );
  }

  static Future<PicaKeepServerConfig> load(String configPath) async {
    final file = File(configPath);
    if (!await file.exists()) {
      final defaultsConfig = defaults();
      await save(configPath, defaultsConfig);
      return defaultsConfig;
    }
    final content = await file.readAsString();
    final decoded = jsonDecode(content);
    if (decoded is Map<String, dynamic>) {
      return fromJson(decoded);
    }
    if (decoded is Map) {
      return fromJson(decoded.map((k, v) => MapEntry(k.toString(), v)));
    }
    return defaults();
  }

  static Future<void> save(
    String configPath,
    PicaKeepServerConfig config,
  ) async {
    final file = File(configPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
    );
  }

  bool isCollectionShellEnabledForPath(String path) {
    final key = normalizeLocalCollectionShellPathKey(path);
    if (key.isEmpty) {
      return false;
    }
    return customLibraryCollectionShellModes[key] == true;
  }

  PicaKeepServerConfig setCollectionShellModeForPath(
    String path,
    bool enabled,
  ) {
    final key = normalizeLocalCollectionShellPathKey(path);
    if (key.isEmpty) {
      return this;
    }
    final next = Map<String, bool>.from(customLibraryCollectionShellModes);
    if (enabled) {
      next[key] = true;
    } else {
      next.remove(key);
    }
    return copyWith(customLibraryCollectionShellModes: next);
  }

  static int _normalizePort(Object? value) {
    final port = int.tryParse(value?.toString() ?? '');
    if (port == null || port < 1 || port > 65535) {
      return defaultServiceAdminPortInt;
    }
    return port;
  }

  static List<String> _normalizeStringList(Object? value) {
    if (value is List) {
      return value
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return const [];
  }

  static Map<String, bool> _normalizeCollectionShellModes(Object? value) {
    if (value is String) {
      return decodeLocalCollectionShellPathMap(value);
    }
    if (value is Map) {
      return decodeLocalCollectionShellPathMap(jsonEncode(value));
    }
    if (value is List) {
      return decodeLocalCollectionShellPathMap(jsonEncode(value));
    }
    return const <String, bool>{};
  }
}
