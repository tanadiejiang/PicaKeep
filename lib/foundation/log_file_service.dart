import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'log.dart';

/// Creates sanitized copies of values that may be written to or exported as logs.
class LogCredentialRedactor {
  LogCredentialRedactor._();

  static const replacement = '<redacted>';

  static const _credentialKeys = <String>{
    'authorization',
    'cookie',
    'setcookie',
    'xapikey',
    'apikey',
    'accesstoken',
    'refreshtoken',
    'password',
    'passwd',
    'pwd',
    'passcode',
    'passphrase',
  };

  static final _urlUserInfoPattern = RegExp(
    r'(\b[a-z][a-z0-9+.-]*://)[^/\s?#@]+@',
    caseSensitive: false,
  );
  static final _urlCredentialPattern = RegExp(
    r'([?&](?:authorization|cookie|set[-_]?cookie|x[-_]?api[-_]?key|api[-_]?key|access[-_]?token|refresh[-_]?token|password|passwd|pwd|passcode|passphrase)=)[^&#\s]*',
    caseSensitive: false,
  );
  static final _bearerPattern = RegExp(
    r'\bBearer[ \t]+[a-z0-9._~+/=-]+',
    caseSensitive: false,
  );
  static final _headerValuePattern = RegExp(
    r'''(\b(?:authorization|cookie|set-cookie)\b["']?\s*[:=]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|.*?)(?=,\s*["']?[a-z0-9_-]+["']?\s*:|[}\]\r\n]|$)''',
    caseSensitive: false,
  );
  static final _fieldValuePattern = RegExp(
    r'''(\b(?:x[-_]?api[-_]?key|api[-_]?key|access[-_]?token|refresh[-_]?token|password|passwd|pwd|passcode|passphrase)\b["']?\s*[:=]\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^,\s&}\]\r\n]+)''',
    caseSensitive: false,
  );

  static bool _isCredentialKey(Object? key) {
    if (key is! String) return false;
    final normalized =
        key.trim().toLowerCase().replaceAll('-', '').replaceAll('_', '');
    return _credentialKeys.contains(normalized);
  }

  /// Recursively copies Map/List values so the value used by the request is
  /// never changed while its log representation is sanitized.
  static Object? redactCopy(Object? value) {
    if (value is Uri) return redactUri(value);
    if (value is String) return redactText(value);
    if (value is List<int>) return List<int>.from(value);
    if (value is List) {
      return value.map<Object?>(redactCopy).toList(growable: false);
    }
    if (value is Map) {
      return <Object?, Object?>{
        for (final entry in value.entries)
          entry.key: _isCredentialKey(entry.key)
              ? replacement
              : redactCopy(entry.value),
      };
    }
    return value;
  }

  static Uri redactUri(Uri uri) {
    final hasSensitiveUserInfo = uri.userInfo.isNotEmpty;
    var hasSensitiveQuery = false;
    final queryParameters = <String, List<String>>{};
    for (final entry in uri.queryParametersAll.entries) {
      if (_isCredentialKey(entry.key)) {
        hasSensitiveQuery = true;
        queryParameters[entry.key] = List<String>.filled(
          entry.value.isEmpty ? 1 : entry.value.length,
          replacement,
        );
      } else {
        queryParameters[entry.key] = List<String>.from(entry.value);
      }
    }
    if (!hasSensitiveUserInfo && !hasSensitiveQuery) return uri;
    return uri.replace(
      userInfo: hasSensitiveUserInfo ? replacement : null,
      queryParameters: hasSensitiveQuery ? queryParameters : null,
    );
  }

  static String redactText(String text) {
    return text
        .replaceAllMapped(
          _urlUserInfoPattern,
          (match) => '${match.group(1)}$replacement@',
        )
        .replaceAllMapped(
          _urlCredentialPattern,
          (match) => '${match.group(1)}$replacement',
        )
        .replaceAll(_bearerPattern, 'Bearer $replacement')
        .replaceAllMapped(
          _headerValuePattern,
          (match) => '${match.group(1)}$replacement',
        )
        .replaceAllMapped(
          _fieldValuePattern,
          (match) => '${match.group(1)}$replacement',
        );
  }
}

/// 日志文件服务：每次启动创建独立日志文件，实时写入，管理历史。
class LogFileService {
  LogFileService._();

  static LogFileService? _instance;
  static LogFileService get instance => _instance ??= LogFileService._();

  static const maxHistoryFiles = 30;
  static const flushInterval = Duration(seconds: 2);
  static const _tempExportDirectoryName = 'picakeep_redacted_logs';

  Directory? _logDir;
  File? _currentFile;
  IOSink? _sink;
  Timer? _flushTimer;
  int _dirtyCount = 0;
  bool _initialized = false;

  String? get currentFilePath => _currentFile?.path;

  Future<void> init() async {
    if (_initialized) return;

    final root = Directory(App.dataPath);
    _logDir = Directory('${root.path}${Platform.pathSeparator}logs');
    await _logDir!.create(recursive: true);
    await _cleanupHistory();

    final now = DateTime.now();
    final name = 'picakeep-log-${now.year}'
        '${_pad(now.month)}${_pad(now.day)}_'
        '${_pad(now.hour)}${_pad(now.minute)}${_pad(now.second)}.txt';
    _currentFile = File('${_logDir!.path}${Platform.pathSeparator}$name');
    _sink = _currentFile!.openWrite(mode: FileMode.writeOnlyAppend);

    _flushTimer = Timer.periodic(flushInterval, (_) => unawaited(flush()));
    _initialized = true;

    // 记录启动
    writeLine('=== PicaKeep 启动 · $name ===\n');
  }

  /// 写一行日志到当前文件（由 LogManager 调用）
  void writeLine(String line) {
    if (!_initialized) return;
    try {
      _sink?.writeln(line);
      _dirtyCount += 1;
      if (_dirtyCount >= 32) {
        unawaited(flush());
      }
    } catch (_) {
      // 写文件失败不影响内存日志
    }
  }

  /// 复制全部日志（当前文件内容；文件不存在时从内存队列读）
  Future<String> copyAll() async {
    await flush();
    final file = _currentFile;
    if (file != null && await file.exists()) {
      return LogCredentialRedactor.redactText(await file.readAsString());
    }
    // fallback：从 LogManager 内存队列读取（逆序拼接）
    final lines = LogManager.logs.reversed.map((log) => log.toFileLine());
    return LogCredentialRedactor.redactText(lines.join('\n'));
  }

  /// 导出当前日志的临时脱敏副本路径。
  Future<String?> exportCurrent({Directory? temporaryDirectory}) async {
    try {
      await flush();
      final file = _currentFile;
      if (file == null || !await file.exists()) return null;
      return await _exportRedactedFile(
        file,
        temporaryDirectory: temporaryDirectory,
      );
    } catch (_) {
      return null;
    }
  }

  /// 导出历史日志的临时脱敏副本路径。
  Future<String?> exportHistory(
    String path, {
    Directory? temporaryDirectory,
  }) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return await _exportRedactedFile(
        file,
        temporaryDirectory: temporaryDirectory,
      );
    } catch (_) {
      return null;
    }
  }

  /// 打包所有历史日志为 ZIP，返回临时 ZIP 路径
  Future<String?> exportAllAsZip({Directory? temporaryDirectory}) async {
    String? zipPath;
    Directory? redactedDir;
    try {
      final dir = _logDir;
      if (dir == null || !await dir.exists()) return null;

      // 先记一条导出日志，再 flush，使这条记录也进入打包内容
      writeLine('=== 打包导出所有日志 ===');
      await flush();

      final files = await _listLogFiles(dir);
      if (files.isEmpty) return null;

      final now = DateTime.now();
      final temp = temporaryDirectory ?? await getTemporaryDirectory();
      redactedDir = await _prepareTempExportDirectory(temp);
      final redactedFiles = <File>[];
      for (final file in files) {
        final redacted = await _writeRedactedCopy(file, redactedDir);
        if (redacted == null) throw StateError('日志脱敏副本生成失败');
        redactedFiles.add(redacted);
      }

      final zipName = 'picakeep_logs_${now.year}'
          '${_pad(now.month)}${_pad(now.day)}_'
          '${_pad(now.hour)}${_pad(now.minute)}${_pad(now.second)}.zip';
      zipPath = '${temp.path}${Platform.pathSeparator}$zipName';

      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      try {
        for (final file in redactedFiles) {
          // 必须用同步版本：addFile 是异步的，不 await 会在写入完成前
          // 就 close，导致打出空压缩包。
          encoder.addFileSync(file, _fileName(file.path));
        }
      } finally {
        encoder.closeSync();
      }
      return zipPath;
    } catch (_) {
      if (zipPath != null) {
        await File(zipPath).delete().catchError((_) => File(zipPath!));
      }
      return null;
    } finally {
      await redactedDir
          ?.delete(recursive: true)
          .catchError((_) => redactedDir!);
    }
  }

  /// 列出历史日志文件信息
  Future<List<LogFileInfo>> listHistory() async {
    final dir = _logDir;
    if (dir == null || !await dir.exists()) return const [];

    final files = await _listLogFiles(dir);
    final infos = <LogFileInfo>[];
    for (final file in files) {
      infos.add(await LogFileInfo.fromFile(file));
    }
    infos.sort((a, b) => b.modified.compareTo(a.modified));
    return infos;
  }

  /// 读取历史文件内容
  Future<String> readHistoryFile(String path) => File(path).readAsString();

  /// 删除历史文件
  Future<void> deleteHistory(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  Future<void> flush() async {
    if (_dirtyCount == 0) return;
    _dirtyCount = 0;
    await _sink?.flush();
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    await flush();
    await _sink?.close();
  }

  Future<void> _cleanupHistory() async {
    final dir = _logDir;
    if (dir == null) return;

    final files = await _listLogFiles(dir);
    files
        .sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

    for (final file in files.skip(maxHistoryFiles - 1)) {
      await file.delete();
    }
  }

  Future<List<File>> _listLogFiles(Directory dir) async {
    final entries = await dir.list().toList();
    return [
      for (final entity in entries)
        if (entity is File &&
            (entity.path.endsWith('.log') || entity.path.endsWith('.txt')))
          entity,
    ];
  }

  Future<String?> _exportRedactedFile(
    File source, {
    Directory? temporaryDirectory,
  }) async {
    final temp = temporaryDirectory ?? await getTemporaryDirectory();
    final exportDir = await _prepareTempExportDirectory(temp);
    final copy = await _writeRedactedCopy(source, exportDir);
    return copy?.path;
  }

  Future<Directory> _prepareTempExportDirectory(Directory temp) async {
    await _cleanupTempExports(temp);
    final exportDir = Directory(
      '${temp.path}${Platform.pathSeparator}$_tempExportDirectoryName',
    );
    await exportDir.create(recursive: true);
    return exportDir;
  }

  Future<File?> _writeRedactedCopy(File source, Directory exportDir) async {
    try {
      final text = await source.readAsString();
      final target = File(
        '${exportDir.path}${Platform.pathSeparator}${_fileName(source.path)}',
      );
      await target.writeAsString(
        LogCredentialRedactor.redactText(text),
        flush: true,
      );
      return target;
    } catch (_) {
      return null;
    }
  }

  Future<void> _cleanupTempExports(Directory temp) async {
    try {
      final entries = await temp.list().toList();
      for (final entity in entries) {
        if (entity is File &&
            entity.path.contains('picakeep_logs_') &&
            entity.path.endsWith('.zip')) {
          await entity.delete().catchError((_) => entity);
        } else if (entity is Directory &&
            _fileName(entity.path) == _tempExportDirectoryName) {
          await entity.delete(recursive: true).catchError((_) => entity);
        }
      }
    } catch (_) {
      // 清理失败不影响导出
    }
  }

  String _pad(int v) => v.toString().padLeft(2, '0');

  String _fileName(String path) => path.split(RegExp(r'[\\/]')).last;
}

class LogFileInfo {
  const LogFileInfo({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.modified,
  });

  final String path;
  final String name;
  final int sizeBytes;
  final DateTime modified;

  static Future<LogFileInfo> fromFile(File file) async {
    final stat = await file.stat();
    return LogFileInfo(
      path: file.path,
      name: file.uri.pathSegments.last,
      sizeBytes: stat.size,
      modified: stat.modified,
    );
  }
}
