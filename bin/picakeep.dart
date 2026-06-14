import 'dart:convert';
import 'dart:io' as io;

import 'picakeep_server_runner.dart' deferred as server_runner;

Future<void> main(List<String> args) async {
  try {
    final options = _CliOptions.parse(args);
    final version = await _readPackageVersion();
    final exitCode = switch (options.action) {
      _CliAction.help => _printHelp(options, version),
      _CliAction.status => await _printStatus(options, version),
      _CliAction.run => await _runServer(options, version),
      _CliAction.stop => await _stopServer(options, version),
    };
    if (exitCode != 0) {
      io.exitCode = exitCode;
    }
  } on _CliUsageException catch (error) {
    io.stderr.writeln(error.message);
    io.stderr.writeln('');
    _writeHelp(version: _fallbackVersion, configPath: _defaultConfigPath);
    io.exitCode = error.exitCode;
  } catch (error, stackTrace) {
    io.stderr.writeln('PicaKeep CLI 执行失败: $error');
    io.stderr.writeln(stackTrace);
    io.exitCode = 1;
  }
}

const _fallbackVersion = 'unknown';
const _defaultConfigFileName = 'picakeep_server.json';
const _versionFileName = 'picakeep.version';
const _compiledVersion = String.fromEnvironment('PICAKEEP_VERSION');

String get _defaultConfigPath {
  return _resolveAbsolutePath(
    '${io.Directory.current.path}${io.Platform.pathSeparator}$_defaultConfigFileName',
  );
}

Future<int> _runServer(_CliOptions options, String version) async {
  if (!options.foreground) {
    return _runServerInBackground(options, version);
  }
  await server_runner.loadLibrary();
  return server_runner.runServer(
    configPath: options.configPath,
    json: options.json,
    version: version,
    logPath: options.logPath,
  );
}

Future<int> _runServerInBackground(_CliOptions options, String version) async {
  final existingProbe = await _probeService(options.targetUrl);
  if (existingProbe.online) {
    return _printBackgroundStarted(
      options: options,
      version: version,
      pid: null,
      logPath: null,
      alreadyRunning: true,
    );
  }

  final logPath = options.logPath ?? _defaultServerLogPath();
  final logFile = io.File(logPath);
  await logFile.parent.create(recursive: true);
  final executable = io.Platform.resolvedExecutable;
  final script = io.Platform.script.toFilePath(windows: io.Platform.isWindows);
  final childArgs = <String>[
    if (_looksLikeDartExecutable(executable)) script,
    'run',
    '--foreground',
    '--config',
    options.configPath,
    '--url',
    options.targetUrl,
    '--log',
    logPath,
  ];

  final process = await io.Process.start(
    executable,
    childArgs,
    mode: io.ProcessStartMode.detached,
    workingDirectory: io.Directory.current.path,
  );

  final pidPath = _defaultServerPidPath();
  final pidFile = io.File(pidPath);
  await pidFile.parent.create(recursive: true);
  await pidFile.writeAsString('${process.pid}\n');

  final started = await _waitForServiceOnline(options.targetUrl);
  if (!started) {
    io.stderr.writeln('PicaKeep 后台服务启动后暂未探测到在线。');
    io.stderr.writeln('日志: $logPath');
    return 1;
  }

  return _printBackgroundStarted(
    options: options,
    version: version,
    pid: process.pid,
    logPath: logPath,
    alreadyRunning: false,
  );
}

Future<bool> _waitForServiceOnline(String targetUrl) async {
  for (var index = 0; index < 30; index++) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final probe = await _probeService(targetUrl);
    if (probe.online) {
      return true;
    }
  }
  return false;
}

int _printBackgroundStarted({
  required _CliOptions options,
  required String version,
  required int? pid,
  required String? logPath,
  required bool alreadyRunning,
}) {
  final baseUri = _normalizeTargetUri(options.targetUrl);
  final urls = _buildServiceUrls(
    scheme: baseUri.scheme,
    host: baseUri.host,
    port: baseUri.hasPort ? baseUri.port : null,
  );

  if (options.json) {
    io.stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'mode': 'server',
        'version': version,
        'background': true,
        'alreadyRunning': alreadyRunning,
        if (pid != null) 'pid': pid,
        if (logPath != null) 'logPath': logPath,
        'urls': {
          'app': urls.app,
          'admin': urls.admin,
          'status': urls.status,
        },
      }),
    );
    return 0;
  }

  io.stdout.writeln('PicaKeep $version');
  io.stdout.writeln('运行模式: server-background');
  io.stdout.writeln(alreadyRunning ? '后台服务: 已在运行' : '后台服务: 已启动');
  if (pid != null) {
    io.stdout.writeln('进程 PID: $pid');
  }
  if (logPath != null) {
    io.stdout.writeln('日志文件: $logPath');
  }
  io.stdout.writeln('网页应用: ${urls.app}');
  io.stdout.writeln('管理后台: ${urls.admin}');
  io.stdout.writeln('状态接口: ${urls.status}');
  io.stdout.writeln('查看状态: picakeep -v');
  io.stdout.writeln('前台调试: picakeep run --foreground');
  return 0;
}

String _defaultServerRuntimeDir() {
  final envHome = io.Platform.environment['HOME']?.trim();
  if (!io.Platform.isWindows && envHome != null && envHome.isNotEmpty) {
    return '$envHome/.local/share/picakeep-cli';
  }
  final localAppData = io.Platform.environment['LOCALAPPDATA']?.trim();
  if (io.Platform.isWindows && localAppData != null && localAppData.isNotEmpty) {
    return '$localAppData${io.Platform.pathSeparator}PicaKeepCLI';
  }
  return '${io.Directory.systemTemp.path}${io.Platform.pathSeparator}picakeep-cli';
}

String _defaultServerLogPath() {
  return '${_defaultServerRuntimeDir()}${io.Platform.pathSeparator}server.log';
}

String _defaultServerPidPath() {
  return '${_defaultServerRuntimeDir()}${io.Platform.pathSeparator}server.pid';
}

bool _looksLikeDartExecutable(String executable) {
  final name = executable.split(io.Platform.pathSeparator).last.toLowerCase();
  return name == 'dart' || name == 'dart.exe';
}

Future<int> _stopServer(_CliOptions options, String version) async {
  final pidFile = io.File(_defaultServerPidPath());
  if (!await pidFile.exists()) {
    return _printStopResult(options, version, stopped: false, message: '未找到 PID 文件');
  }
  final rawPid = (await pidFile.readAsString()).trim();
  final pid = int.tryParse(rawPid);
  if (pid == null || pid <= 0) {
    await pidFile.delete();
    return _printStopResult(options, version, stopped: false, message: 'PID 文件无效，已清理');
  }

  final killed = io.Process.killPid(pid);
  if (!killed) {
    await pidFile.delete();
    return _printStopResult(options, version, stopped: false, message: '进程不存在，已清理 PID 文件');
  }

  for (var index = 0; index < 20; index++) {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final probe = await _probeService(options.targetUrl);
    if (!probe.online) {
      if (await pidFile.exists()) {
        await pidFile.delete();
      }
      return _printStopResult(options, version, stopped: true, message: '后台服务已停止');
    }
  }

  return _printStopResult(options, version, stopped: true, message: '已发送停止信号');
}

int _printStopResult(
  _CliOptions options,
  String version, {
  required bool stopped,
  required String message,
}) {
  if (options.json) {
    io.stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'mode': 'stop',
        'version': version,
        'stopped': stopped,
        'message': message,
      }),
    );
    return 0;
  }
  io.stdout.writeln('PicaKeep $version');
  io.stdout.writeln('运行模式: stop');
  io.stdout.writeln(message);
  return 0;
}

Future<int> _printStatus(_CliOptions options, String version) async {
  final probe = await _probeService(options.targetUrl);
  final urls = _buildServiceUrls(
    scheme: probe.baseUri.scheme,
    host: probe.baseUri.host,
    port: probe.baseUri.hasPort ? probe.baseUri.port : null,
  );

  if (options.json) {
    io.stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'command': options.statusCommand,
        'mode': options.displayMode,
        'version': version,
        'system': {
          'os': io.Platform.operatingSystem,
          'osVersion': io.Platform.operatingSystemVersion,
        },
        'dart': _dartVersionSummary(),
        'targetService': probe.baseUri.toString(),
        'online': probe.online,
        'status': probe.online ? 'online' : 'offline',
        'urls': {
          'app': urls.app,
          'admin': urls.admin,
          'status': urls.status,
        },
        'service': {
          'httpStatusCode': probe.httpStatusCode,
          'latencyMs': probe.latencyMs,
          'serviceName': probe.payload?['serviceName']?.toString(),
          'deviceSystem': probe.payload?['deviceSystem']?.toString(),
          'deviceName': probe.payload?['deviceName']?.toString(),
          'deviceSummary': probe.payload?['deviceSummary']?.toString(),
          'lifecycle': probe.payload?['lifecycle']?.toString(),
          'message': probe.payload?['message']?.toString(),
          'statusText': probe.payload?['statusText']?.toString(),
          'startedAt': probe.payload?['startedAt']?.toString(),
          'comicCount': _readInt(probe.payload?['comicCount']),
          'connectionCount': _readInt(probe.payload?['connectionCount']),
          'libraryRootCount': _readInt(probe.payload?['libraryRootCount']),
          'availableLibraryRootCount':
              _readInt(probe.payload?['availableLibraryRootCount']),
          'missingLibraryRootCount':
              _readInt(probe.payload?['missingLibraryRootCount']),
          'resourceBytes': _readInt(probe.payload?['resourceBytes']),
          'resourceGeneratedAt':
              probe.payload?['resourceGeneratedAt']?.toString(),
          'librarySignature': probe.payload?['librarySignature']?.toString(),
          'totalRequests': _readInt(probe.payload?['totalRequests']),
        },
        if (!probe.online && probe.errorMessage != null)
          'error': probe.errorMessage,
      }),
    );
    return 0;
  }

  io.stdout.writeln('PicaKeep $version');
  io.stdout.writeln('运行模式: ${options.displayMode}');
  io.stdout.writeln(
    '系统: ${io.Platform.operatingSystem} ${io.Platform.operatingSystemVersion}',
  );
  io.stdout.writeln('Dart: ${_dartVersionSummary()}');
  io.stdout.writeln('目标服务: ${probe.baseUri}');
  io.stdout.writeln('连接状态: ${probe.online ? '在线' : '离线'}');
  io.stdout.writeln('网页应用: ${urls.app}');
  io.stdout.writeln('管理后台: ${urls.admin}');
  io.stdout.writeln('状态接口: ${urls.status}');
  if (probe.httpStatusCode != null) {
    io.stdout.writeln('HTTP 状态: ${probe.httpStatusCode}');
  }
  if (probe.latencyMs != null) {
    io.stdout.writeln('探测延迟: ${probe.latencyMs} ms');
  }

  if (probe.online && probe.payload != null) {
    final payload = probe.payload!;
    final serviceName = payload['serviceName']?.toString().trim() ?? '';
    final deviceSummary = payload['deviceSummary']?.toString().trim() ?? '';
    final message = payload['message']?.toString().trim() ?? '';
    final comicCount = _readInt(payload['comicCount']);
    final connectionCount = _readInt(payload['connectionCount']);
    final libraryRootCount = _readInt(payload['libraryRootCount']);
    final resourceBytes = _readInt(payload['resourceBytes']);
    final totalRequests = _readInt(payload['totalRequests']);
    final startedAt = payload['startedAt']?.toString().trim() ?? '';
    if (serviceName.isNotEmpty) {
      io.stdout.writeln('服务名称: $serviceName');
    }
    if (deviceSummary.isNotEmpty) {
      io.stdout.writeln('设备信息: $deviceSummary');
    }
    if (startedAt.isNotEmpty) {
      io.stdout.writeln('启动时间: $startedAt');
    }
    if (comicCount != null ||
        connectionCount != null ||
        libraryRootCount != null ||
        resourceBytes != null ||
        totalRequests != null) {
      io.stdout.writeln(
        '资源摘要: '
        '漫画 ${comicCount ?? 0} / '
        '连接 ${connectionCount ?? 0} / '
        '资源根 ${libraryRootCount ?? 0} / '
        '体积 ${_formatBytes(resourceBytes)} / '
        '请求 ${totalRequests ?? 0}',
      );
    }
    if (message.isNotEmpty) {
      io.stdout.writeln('服务说明: $message');
    }
  } else {
    io.stdout.writeln('启动提示: 执行 `picakeep run` 启动本地服务端。');
    if (probe.errorMessage != null && probe.errorMessage!.trim().isNotEmpty) {
      io.stdout.writeln('探测结果: ${probe.errorMessage}');
    }
  }

  return 0;
}

int _printHelp(_CliOptions options, String version) {
  _writeHelp(version: version, configPath: options.configPath);
  return 0;
}

void _writeHelp({
  required String version,
  required String configPath,
}) {
  io.stdout.writeln('PicaKeep $version');
  io.stdout.writeln('');
  io.stdout.writeln('用法:');
  io.stdout.writeln('  picakeep [command] [options]');
  io.stdout.writeln('');
  io.stdout.writeln('默认行为:');
  io.stdout.writeln('  未指定命令时后台启动 headless 服务端，并立即返回终端。');
  io.stdout.writeln('');
  io.stdout.writeln('常用命令:');
  io.stdout.writeln('  picakeep                后台启动服务端');
  io.stdout.writeln('  picakeep run            后台启动服务端');
  io.stdout.writeln('  picakeep run --foreground  前台启动服务端，用于调试');
  io.stdout.writeln('  picakeep stop           停止后台服务端');
  io.stdout.writeln('  picakeep -v             显示版本与目标服务状态');
  io.stdout.writeln('  picakeep help           显示帮助');
  io.stdout.writeln('');
  io.stdout.writeln('命令:');
  io.stdout.writeln('  run      后台启动服务端');
  io.stdout.writeln('  server   后台启动服务端');
  io.stdout.writeln('  start    后台启动服务端');
  io.stdout.writeln('  stop     停止后台服务端');
  io.stdout.writeln('  client   只查看目标服务状态，不启动本地服务端');
  io.stdout.writeln('  status   显示版本、系统、目标服务和在线状态');
  io.stdout.writeln('  version  显示版本、系统、目标服务和在线状态');
  io.stdout.writeln('  help     显示帮助');
  io.stdout.writeln('');
  io.stdout.writeln('选项:');
  io.stdout.writeln('  --config <path>   服务端配置文件，默认: $configPath');
  io.stdout.writeln('  --url <url>       目标服务地址，默认: http://127.0.0.1:9527');
  io.stdout.writeln('  --mode <mode>     默认 server，可选 server 或 client');
  io.stdout.writeln('  --foreground      前台启动服务端，不进入后台');
  io.stdout.writeln('  --log <path>      后台/前台服务日志文件');
  io.stdout.writeln('  --json            输出 JSON');
  io.stdout.writeln('  -v, --version     显示版本与目标服务状态');
  io.stdout.writeln('  -h, --help        显示帮助');
  io.stdout.writeln('');
  io.stdout.writeln('输出说明:');
  io.stdout.writeln('  后台服务启动后会显示网页应用、管理后台、状态接口、PID 和日志路径。');
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

Future<_StatusProbeResult> _probeService(String targetUrl) async {
  final baseUri = _normalizeTargetUri(targetUrl);
  final statusUri = baseUri.resolve('/status');
  final stopwatch = Stopwatch()..start();
  final client = io.HttpClient()
    ..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client.getUrl(statusUri).timeout(
          const Duration(seconds: 3),
        );
    request.headers.set(io.HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(
          const Duration(seconds: 3),
        );
    final body = await utf8.decoder.bind(response).join().timeout(
          const Duration(seconds: 2),
          onTimeout: () => '',
        );
    stopwatch.stop();
    return _StatusProbeResult(
      baseUri: baseUri,
      online: response.statusCode >= 200 && response.statusCode < 300,
      httpStatusCode: response.statusCode,
      latencyMs: stopwatch.elapsedMilliseconds,
      payload: _tryParseJsonMap(body),
      errorMessage: response.statusCode >= 200 && response.statusCode < 300
          ? null
          : '服务有响应，但返回状态码 ${response.statusCode}',
    );
  } catch (error) {
    stopwatch.stop();
    return _StatusProbeResult(
      baseUri: baseUri,
      online: false,
      latencyMs: stopwatch.elapsedMilliseconds,
      errorMessage: error.toString(),
    );
  } finally {
    client.close(force: true);
  }
}

Uri _normalizeTargetUri(String value) {
  final trimmed = value.trim();
  final candidate =
      trimmed.startsWith('http://') || trimmed.startsWith('https://')
      ? trimmed
      : 'http://$trimmed';
  final uri = Uri.tryParse(candidate);
  if (uri == null || !uri.hasAuthority || uri.host.trim().isEmpty) {
    throw _CliUsageException('无效的服务地址: $value');
  }
  return Uri(
    scheme: uri.scheme.isEmpty ? 'http' : uri.scheme,
    userInfo: uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  );
}

Map<String, dynamic>? _tryParseJsonMap(String raw) {
  if (raw.trim().isEmpty) {
    return null;
  }
  final decoded = jsonDecode(raw);
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  if (decoded is Map) {
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

Future<String> _readPackageVersion() async {
  if (_compiledVersion.trim().isNotEmpty) {
    return _compiledVersion.trim();
  }

  final candidates = <io.File>[
    io.File.fromUri(io.Platform.script.resolve(_versionFileName)),
    io.File.fromUri(io.Platform.script.resolve('../$_versionFileName')),
    io.File.fromUri(io.Platform.script.resolve('../../$_versionFileName')),
    io.File.fromUri(io.Platform.script.resolve('../../../$_versionFileName')),
    io.File('${io.Directory.current.path}${io.Platform.pathSeparator}$_versionFileName'),
    io.File('${io.Directory.current.path}${io.Platform.pathSeparator}pubspec.yaml'),
    io.File.fromUri(io.Platform.script.resolve('../pubspec.yaml')),
  ];
  final seen = <String>{};
  for (final file in candidates) {
    final path = file.absolute.path;
    if (!seen.add(path)) {
      continue;
    }
    if (!await file.exists()) {
      continue;
    }
    final content = await file.readAsString();
    if (file.path.endsWith(_versionFileName)) {
      final version = content.trim();
      if (version.isNotEmpty) {
        return version;
      }
      continue;
    }
    for (final line in const LineSplitter().convert(content)) {
      final match = RegExp(r'^\s*version:\s*(\S+)\s*$').firstMatch(line);
      if (match != null) {
        return match.group(1) ?? _fallbackVersion;
      }
    }
  }
  return _fallbackVersion;
}

String _dartVersionSummary() {
  return io.Platform.version.split('\n').first.trim();
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

String _formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) {
    return '0 B';
  }
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  final fractionDigits = value >= 10 || unitIndex == 0 ? 0 : 1;
  return '${value.toStringAsFixed(fractionDigits)} ${units[unitIndex]}';
}

String _resolveAbsolutePath(String path) {
  return io.File(path).absolute.path;
}

enum _CliAction {
  help,
  status,
  run,
  stop,
}

class _CliOptions {
  const _CliOptions({
    required this.action,
    required this.statusCommand,
    required this.displayMode,
    required this.json,
    required this.foreground,
    required this.configPath,
    required this.targetUrl,
    this.logPath,
  });

  final _CliAction action;
  final String statusCommand;
  final String displayMode;
  final bool json;
  final bool foreground;
  final String configPath;
  final String targetUrl;
  final String? logPath;

  static _CliOptions parse(List<String> args) {
    String? command;
    String mode = 'server';
    String configPath = _defaultConfigPath;
    String targetUrl = 'http://127.0.0.1:9527';
    var json = false;
    var foreground = false;
    String? logPath;
    var showHelp = false;
    var showVersion = false;

    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      if (arg == '-h' || arg == '--help') {
        showHelp = true;
        continue;
      }
      if (arg == '-v' || arg == '--version') {
        showVersion = true;
        continue;
      }
      if (arg == '--json') {
        json = true;
        continue;
      }
      if (arg == '--foreground') {
        foreground = true;
        continue;
      }
      if (arg.startsWith('--log=')) {
        logPath = _resolveAbsolutePath(
          _parseOptionValue(arg.substring('--log='.length), 'log'),
        );
        continue;
      }
      if (arg == '--log') {
        index++;
        if (index >= args.length) {
          throw const _CliUsageException('缺少 --log 的参数值');
        }
        logPath = _resolveAbsolutePath(
          _parseOptionValue(args[index], 'log'),
        );
        continue;
      }
      if (arg.startsWith('--config=')) {
        configPath = _parseOptionValue(arg.substring('--config='.length), 'config');
        configPath = _resolveAbsolutePath(configPath);
        continue;
      }
      if (arg == '--config') {
        index++;
        if (index >= args.length) {
          throw const _CliUsageException('缺少 --config 的参数值');
        }
        configPath = _resolveAbsolutePath(
          _parseOptionValue(args[index], 'config'),
        );
        continue;
      }
      if (arg.startsWith('--url=')) {
        targetUrl = _parseOptionValue(arg.substring('--url='.length), 'url');
        continue;
      }
      if (arg == '--url') {
        index++;
        if (index >= args.length) {
          throw const _CliUsageException('缺少 --url 的参数值');
        }
        targetUrl = _parseOptionValue(args[index], 'url');
        continue;
      }
      if (arg.startsWith('--mode=')) {
        mode = _normalizeMode(
          _parseOptionValue(arg.substring('--mode='.length), 'mode'),
        );
        continue;
      }
      if (arg == '--mode') {
        index++;
        if (index >= args.length) {
          throw const _CliUsageException('缺少 --mode 的参数值');
        }
        mode = _normalizeMode(_parseOptionValue(args[index], 'mode'));
        continue;
      }
      if (arg.startsWith('-')) {
        throw _CliUsageException('未知选项: $arg');
      }
      if (command != null) {
        throw _CliUsageException('只支持一个命令，收到多余参数: $arg');
      }
      command = arg.trim();
    }

    if (showHelp || command == 'help') {
      return _CliOptions(
        action: _CliAction.help,
        statusCommand: 'help',
        displayMode: mode,
        json: json,
        foreground: foreground,
        configPath: configPath,
        targetUrl: targetUrl,
        logPath: logPath,
      );
    }

    if (showVersion || command == 'status' || command == 'version') {
      return _CliOptions(
        action: _CliAction.status,
        statusCommand: command == 'version' ? 'version' : 'status',
        displayMode: 'status',
        json: json,
        foreground: foreground,
        configPath: configPath,
        targetUrl: targetUrl,
        logPath: logPath,
      );
    }

    if (command == null || command.isEmpty) {
      if (mode == 'client') {
        return _CliOptions(
          action: _CliAction.status,
          statusCommand: 'client',
          displayMode: 'client',
          json: json,
          foreground: foreground,
          configPath: configPath,
          targetUrl: targetUrl,
          logPath: logPath,
        );
      }
      return _CliOptions(
        action: _CliAction.run,
        statusCommand: 'run',
        displayMode: 'server',
        json: json,
        foreground: foreground,
        configPath: configPath,
        targetUrl: targetUrl,
        logPath: logPath,
      );
    }

    if (command == 'client') {
      return _CliOptions(
        action: _CliAction.status,
        statusCommand: 'client',
        displayMode: 'client',
        json: json,
        foreground: foreground,
        configPath: configPath,
        targetUrl: targetUrl,
        logPath: logPath,
      );
    }

    if (command == 'run' || command == 'server' || command == 'start') {
      return _CliOptions(
        action: _CliAction.run,
        statusCommand: command,
        displayMode: 'server',
        json: json,
        foreground: foreground,
        configPath: configPath,
        targetUrl: targetUrl,
        logPath: logPath,
      );
    }

    if (command == 'stop') {
      return _CliOptions(
        action: _CliAction.stop,
        statusCommand: 'stop',
        displayMode: 'stop',
        json: json,
        foreground: foreground,
        configPath: configPath,
        targetUrl: targetUrl,
        logPath: logPath,
      );
    }

    throw _CliUsageException('未知命令: $command');
  }

  static String _parseOptionValue(String value, String optionName) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw _CliUsageException('缺少 --$optionName 的参数值');
    }
    return trimmed;
  }

  static String _normalizeMode(String value) {
    final trimmed = value.trim().toLowerCase();
    if (trimmed == 'server' || trimmed == 'client') {
      return trimmed;
    }
    throw _CliUsageException('无效的 --mode 参数: $value');
  }
}

class _CliUsageException implements Exception {
  const _CliUsageException(this.message);

  final String message;

  int get exitCode => 64;
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

class _StatusProbeResult {
  const _StatusProbeResult({
    required this.baseUri,
    required this.online,
    this.httpStatusCode,
    this.latencyMs,
    this.payload,
    this.errorMessage,
  });

  final Uri baseUri;
  final bool online;
  final int? httpStatusCode;
  final int? latencyMs;
  final Map<String, dynamic>? payload;
  final String? errorMessage;
}
