import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:picakeep/server/headless_cli_server.dart';
import 'package:picakeep/server/server_config.dart';

Future<int> runServer({
  required String configPath,
  required bool json,
  required String version,
  String? logPath,
}) async {
  IOSink? logSink;
  if (logPath != null && logPath.trim().isNotEmpty) {
    final logFile = File(logPath);
    await logFile.parent.create(recursive: true);
    logSink = logFile.openWrite(mode: FileMode.append);
  }

  void writeLine(String line) {
    stdout.writeln(line);
    logSink?.writeln(line);
  }

  try {
    final config = await PicaKeepServerConfig.load(configPath);
    final server = PicaKeepHeadlessCliServer(
      configPath: configPath,
      version: version,
    );
    await server.start(config: config);

    final localHost = _displayHostForLocal(config.host);
    final localUrls = _buildServiceUrls(
      scheme: 'http',
      host: localHost,
      port: config.port,
    );
    final listenUrl = Uri(
      scheme: 'http',
      host: config.host,
      port: config.port,
      path: '/',
    ).toString();
    final lanUrls = await _buildLanUrlEntries(config.host, config.port);

    if (json) {
      writeLine(
        const JsonEncoder.withIndent('  ').convert({
          'mode': 'server',
          'version': version,
          'configPath': configPath,
          'listen': listenUrl,
          'urls': {
            'app': localUrls.app,
            'admin': localUrls.admin,
            'status': localUrls.status,
          },
          'lan': lanUrls,
        }),
      );
    } else {
      writeLine('PicaKeep $version');
      writeLine('运行模式: server');
      writeLine(
        '系统: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      );
      writeLine('配置文件: $configPath');
      writeLine('监听地址: $listenUrl');
      writeLine('本机访问: ${localUrls.app}');
      writeLine('网页应用: ${localUrls.app}');
      writeLine('管理后台: ${localUrls.admin}');
      writeLine('状态接口: ${localUrls.status}');
      for (final entry in lanUrls) {
        writeLine('局域网访问: ${entry['app']}');
        writeLine('局域网后台: ${entry['admin']}');
      }
      writeLine('停止服务: Ctrl+C');
    }

    await _waitForShutdown(server, jsonMode: json, writeLine: writeLine);
    return 0;
  } finally {
    await logSink?.flush();
    await logSink?.close();
  }
}

Future<void> _waitForShutdown(
  PicaKeepHeadlessCliServer server, {
  required bool jsonMode,
  required void Function(String line) writeLine,
}) async {
  final completer = Completer<void>();
  var stopping = false;

  Future<void> shutdown(String signalName) async {
    if (stopping) {
      return;
    }
    stopping = true;
    if (!jsonMode) {
      writeLine('');
      writeLine('收到 $signalName，正在停止服务...');
    }
    try {
      await server.stop();
    } finally {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
  }

  final sigintSub = ProcessSignal.sigint.watch().listen((_) {
    unawaited(shutdown('Ctrl+C'));
  });

  StreamSubscription<ProcessSignal>? sigtermSub;
  if (!Platform.isWindows) {
    sigtermSub = ProcessSignal.sigterm.watch().listen((_) {
      unawaited(shutdown('SIGTERM'));
    });
  }

  await completer.future;
  await sigintSub.cancel();
  await sigtermSub?.cancel();
}

Future<List<Map<String, String>>> _buildLanUrlEntries(String host, int port) async {
  if (!_isWildcardHost(host)) {
    return const <Map<String, String>>[];
  }
  final results = <Map<String, String>>[];
  final seen = <String>{};
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final value = address.address.trim();
        if (value.isEmpty || !seen.add(value)) {
          continue;
        }
        final urls = _buildServiceUrls(
          scheme: 'http',
          host: value,
          port: port,
        );
        results.add({
          'host': value,
          'app': urls.app,
          'admin': urls.admin,
          'status': urls.status,
        });
      }
    }
  } catch (_) {}
  return results;
}

_ServiceUrls _buildServiceUrls({
  required String scheme,
  required String host,
  required int? port,
}) {
  Uri buildUri(String path) {
    return Uri(
      scheme: scheme,
      host: host,
      port: port,
      path: path,
    );
  }

  return _ServiceUrls(
    app: buildUri('/').toString(),
    admin: buildUri('/admin-view').toString(),
    status: buildUri('/status').toString(),
  );
}

String _displayHostForLocal(String host) {
  if (_isWildcardHost(host)) {
    return '127.0.0.1';
  }
  final trimmed = host.trim();
  if (trimmed == 'localhost') {
    return '127.0.0.1';
  }
  return trimmed;
}

bool _isWildcardHost(String host) {
  final trimmed = host.trim();
  return trimmed.isEmpty ||
      trimmed == '0.0.0.0' ||
      trimmed == '::' ||
      trimmed == '::0' ||
      trimmed == '[::]';
}

class _ServiceUrls {
  const _ServiceUrls({
    required this.app,
    required this.admin,
    required this.status,
  });

  final String app;
  final String admin;
  final String status;
}