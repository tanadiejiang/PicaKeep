import 'package:collection/collection.dart';

import 'log_file_service.dart';

class LogManager {
  static final List<Log> _logs = <Log>[];

  static List<Log> get logs => _logs;

  static const maxLogLength = 3000;

  static const maxLogNumber = 500;

  static bool ignoreLimitation = false;

  static bool recordingEnabled = true;

  static void addLog(LogLevel level, String title, String content) {
    if (!recordingEnabled) {
      return;
    }

    if (!ignoreLimitation && content.length > maxLogLength) {
      content = "${content.substring(0, maxLogLength)}...";
    }

    var newLog = Log(level, title, content);

    if (newLog == _logs.lastOrNull) {
      return;
    }

    _logs.add(newLog);
    if (_logs.length > maxLogNumber) {
      var res = _logs.remove(
          _logs.where((element) => element.level == LogLevel.info).firstOrNull);
      if (!res) {
        _logs.removeAt(0);
      }
    }

    // 同时写入文件
    LogFileService.instance.writeLine(newLog.toFileLine());
  }

  static void clear() => _logs.clear();

  @override
  String toString() {
    var res = "Logs\n\n";
    for (var log in _logs) {
      res += log.toString();
    }
    return res;
  }
}

class Log {
  final LogLevel level;
  final String title;
  final String content;
  final DateTime time = DateTime.now();

  @override
  toString() => "${level.name} $title $time \n$content\n\n";

  /// 输出到文件的格式（单行，便于解析）
  String toFileLine() {
    final timeText = '${_pad(time.hour)}:${_pad(time.minute)}:${_pad(time.second)}.${time.millisecond.toString().padLeft(3, '0')}';
    return '$timeText [${level.name.toUpperCase()}] [$title] $content';
  }

  String _pad(int v) => v.toString().padLeft(2, '0');

  Log(this.level, this.title, this.content);

  static void info(String title, String message) {
    LogManager.addLog(LogLevel.info, title, message);
  }

  static void warning(String title, String message) {
    LogManager.addLog(LogLevel.warning, title, message);
  }

  static void error(String title, String message) {
    LogManager.addLog(LogLevel.error, title, message);
  }

  @override
  bool operator ==(Object other) {
    if (other is! Log) return false;
    return other.level == level &&
        other.title == title &&
        other.content == content;
  }

  @override
  int get hashCode => level.hashCode ^ title.hashCode ^ content.hashCode;
}

enum LogLevel { error, warning, info }
