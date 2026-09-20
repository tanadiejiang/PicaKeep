import 'dart:convert';
import 'dart:io';

import 'package:picakeep/foundation/app.dart';

enum AccountStorageMode {
  local,
  nas,
}

class AccountModeController {
  AccountModeController._();

  static final AccountModeController instance = AccountModeController._();

  AccountStorageMode _mode = AccountStorageMode.local;

  AccountStorageMode get mode => _mode;

  String get modeName => switch (_mode) {
        AccountStorageMode.local => '本地',
        AccountStorageMode.nas => 'NAS',
      };

  String get _filePath =>
      '${App.dataPath}${Platform.pathSeparator}account_mode.json';

  Future<void> load() async {
    final file = File(_filePath);
    try {
      if (!await file.exists()) {
        _mode = AccountStorageMode.local;
        return;
      }
      final decoded = jsonDecode(await file.readAsString());
      final raw = decoded is Map ? decoded['mode']?.toString() : null;
      // 目前只有 local 是有效模式：NAS 尚未接入，历史文件里写入的 nas
      // 在读取时一律回退 local（不生效即不高亮）。这里不主动迁移或删除旧文件，
      // 避免静默改写用户数据；用户明确选择本地时才按既有方式写回。
      _mode = switch (raw) {
        'nas' => AccountStorageMode.local,
        _ => AccountStorageMode.local,
      };
    } catch (_) {
      _mode = AccountStorageMode.local;
    }
  }

  Future<void> save(AccountStorageMode mode) async {
    final file = File(_filePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'mode': mode.name}), flush: true);
    _mode = mode;
  }
}
