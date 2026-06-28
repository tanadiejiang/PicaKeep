import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'log.dart';

/// 日志文件服务：每次启动创建独立日志文件，实时写入，管理历史。
class LogFileService {
  LogFileService._();

  static LogFileService? _instance;
  static LogFileService get instance => _instance ??= LogFileService._();

  static const maxHistoryFiles = 30;
  static const flushInterval = Duration(seconds: 2);

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
      return file.readAsString();
    }
    // fallback：从 LogManager 内存队列读取（逆序拼接）
    final lines = LogManager.logs.reversed.map((log) => log.toFileLine());
    return lines.join('\n');
  }

  /// 导出当前日志文件路径
  Future<String?> exportCurrent() async {
    await flush();
    return _currentFile?.path;
  }

  /// 打包所有历史日志为 ZIP，返回临时 ZIP 路径
  Future<String?> exportAllAsZip() async {
    final dir = _logDir;
    if (dir == null || !await dir.exists()) return null;

    // 先记一条导出日志，再 flush，使这条记录也进入打包内容
    writeLine('=== 打包导出所有日志 ===');
    await flush();

    final files = await _listLogFiles(dir);
    if (files.isEmpty) return null;

    final now = DateTime.now();
    final temp = await getTemporaryDirectory();
    await _cleanupTempZips(temp);

    final zipName = 'picakeep_logs_${now.year}'
        '${_pad(now.month)}${_pad(now.day)}_'
        '${_pad(now.hour)}${_pad(now.minute)}${_pad(now.second)}.zip';
    final zipPath = '${temp.path}${Platform.pathSeparator}$zipName';

    final encoder = ZipFileEncoder();
    encoder.create(zipPath);
    try {
      for (final file in files) {
        // 必须用同步版本：addFile 是异步的，不 await 会在写入完成前
        // 就 close，导致打出空压缩包。
        encoder.addFileSync(file, _fileName(file.path));
      }
    } finally {
      encoder.closeSync();
    }
    return zipPath;
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
    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));

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

  Future<void> _cleanupTempZips(Directory temp) async {
    try {
      final entries = await temp.list().toList();
      for (final entity in entries) {
        if (entity is File &&
            entity.path.contains('picakeep_logs_') &&
            entity.path.endsWith('.zip')) {
          await entity.delete().catchError((_) => entity);
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
