import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'download_directory_migration.dart';

/// 一次尚未搬完的迁移。
class PendingDownloadMigration {
  const PendingDownloadMigration({required this.from, required this.to});

  /// 旧下载目录（还有条目没搬走）。
  final String from;

  /// 新下载目录（已经在用）。
  final String to;

  Map<String, Object?> toJson() => <String, Object?>{'from': from, 'to': to};

  static PendingDownloadMigration? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final from = json['from']?.toString().trim() ?? '';
    final to = json['to']?.toString().trim() ?? '';
    if (from.isEmpty || to.isEmpty) {
      return null;
    }
    return PendingDownloadMigration(from: from, to: to);
  }
}

/// 下载数据迁移的运行器。
///
/// 负责三件事：
/// 1. **持久化**未搬完的任务 —— 应用被杀掉重启后，"继续迁移"仍然可用；
/// 2. **广播进度**给任意正在显示的进度界面（可以是多个，也可以是 0 个）；
/// 3. **可中断**：`requestStop()` 后任务在当前条目边界停下，已完成的成果保留。
///
/// 之所以把"是否搬完"的判断交给文件系统（[hasPendingDownloadEntries]）而不是
/// 记一份清单：文件系统的真实状态是唯一不会与实际漂移的真相。
class DownloadMigrationController extends ChangeNotifier {
  DownloadMigrationController._();

  static final DownloadMigrationController instance =
      DownloadMigrationController._();

  static const String _prefsKey = 'download_migration_pending';
  static const String _lowStoragePrefsKey = 'download_migration_low_storage';

  PendingDownloadMigration? _pending;
  DownloadMigrationProgress? _progress;
  bool _running = false;
  bool _stopRequested = false;
  bool _lowStorageMode = false;
  bool _preferencesLoaded = false;

  PendingDownloadMigration? get pending => _pending;
  DownloadMigrationProgress? get progress => _progress;
  bool get isRunning => _running;

  /// 「存储紧张时的迁移」开关。
  ///
  /// false（默认）：先把全部内容复制到新目录，确认没失败后才清理旧目录，
  /// 峰值占用约两倍，但过程中旧目录始终完整。
  /// true：搬一本删一本，峰值占用只多一本，适合空间吃紧的设备。
  bool get lowStorageMode => _lowStorageMode;

  bool get preferencesLoaded => _preferencesLoaded;

  /// 读取迁移相关偏好（开关状态）。可重复调用。
  Future<void> loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _lowStorageMode = prefs.getBool(_lowStoragePrefsKey) ?? false;
    } catch (_) {
      _lowStorageMode = false;
    }
    _preferencesLoaded = true;
    notifyListeners();
  }

  Future<void> setLowStorageMode(bool value) async {
    _lowStorageMode = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_lowStoragePrefsKey, value);
    } catch (_) {
      // 存不下来只影响下次启动的默认值，不影响本次迁移行为。
    }
  }

  /// 读取上次没搬完的任务。应用启动、进入设置页时调用。
  Future<PendingDownloadMigration?> loadPending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      _pending = (raw == null || raw.isEmpty)
          ? null
          : PendingDownloadMigration.fromJson(jsonDecode(raw));
    } catch (_) {
      _pending = null;
    }
    notifyListeners();
    return _pending;
  }

  Future<void> _savePending(PendingDownloadMigration? migration) async {
    _pending = migration;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (migration == null) {
        await prefs.remove(_prefsKey);
      } else {
        await prefs.setString(_prefsKey, jsonEncode(migration.toJson()));
      }
    } catch (_) {
      // 存不下来不影响本次迁移，只是重启后没法自动提示继续。
    }
    notifyListeners();
  }

  /// **只复制**一份目录内容（不删除源），进度广播与 [start] 共用一套。
  ///
  /// 用在「原应用下载目录」选择"复制到本应用"时：用户想摆脱对原目录与权限的
  /// 依赖，但原应用的数据必须原封不动。
  ///
  /// 与 [start] 的区别是**不写"待续迁移"记录** —— 复制本身幂等（目标已存在
  /// 即跳过），中断后重跑一次即可，不需要额外的断点信息。
  Future<DownloadMigrationResult?> startCopy({
    required String from,
    required String to,
  }) async {
    if (_running) {
      return null;
    }
    _running = true;
    _stopRequested = false;
    _progress = null;
    notifyListeners();
    try {
      return await copyDirectoryContents(
        from: from,
        to: to,
        onProgress: (progress) {
          _progress = progress;
          notifyListeners();
        },
        shouldStop: () => _stopRequested,
      );
    } finally {
      _running = false;
      _stopRequested = false;
      _progress = null;
      notifyListeners();
    }
  }

  /// 请求在当前条目边界停下。已经搬过去的不会退回。
  void requestStop() {
    if (_running) {
      _stopRequested = true;
    }
  }

  /// 开始或继续一次迁移。已有任务在跑时返回 null（不并发搬同一批文件）。
  ///
  /// 调用前应当已经完成"复制数据库 + 切换下载目录"，这样新目录从头到尾可用。
  /// 搬移方式由 [lowStorageMode] 决定（见该开关的说明）。
  Future<DownloadMigrationResult?> start({
    required String from,
    required String to,
  }) async {
    if (_running) {
      return null;
    }
    _running = true;
    _stopRequested = false;
    _progress = null;
    notifyListeners();
    await _savePending(PendingDownloadMigration(from: from, to: to));
    try {
      final result = await migrateDownloadEntries(
        from: from,
        to: to,
        deleteSourceAsWeGo: _lowStorageMode,
        onProgress: (progress) {
          _progress = progress;
          notifyListeners();
        },
        shouldStop: () => _stopRequested,
      );
      // 只有旧目录真的空了才销账；否则保留记录供下次继续。
      if (!await hasPendingDownloadEntries(from)) {
        await _savePending(null);
      }
      return result;
    } finally {
      _running = false;
      _stopRequested = false;
      _progress = null;
      notifyListeners();
    }
  }
}
