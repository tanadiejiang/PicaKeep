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
    if (!await file.exists()) {
      return;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      final value = decoded is Map ? decoded['mode']?.toString() : null;
      _mode = value == 'nas' ? AccountStorageMode.nas : AccountStorageMode.local;
    } catch (_) {
      _mode = AccountStorageMode.local;
    }
  }

  Future<void> save(AccountStorageMode mode) async {
    _mode = mode;
    final file = File(_filePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'mode': mode.name}), flush: true);
  }
}
