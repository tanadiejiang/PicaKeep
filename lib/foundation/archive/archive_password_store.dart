import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../base.dart';
import '../local_library_settings.dart';

class ArchivePasswordStore extends ChangeNotifier {
  ArchivePasswordStore._();
  static final ArchivePasswordStore instance = ArchivePasswordStore._();

  // Runtime-only: path -> password (cleared on restart)
  final Map<String, String> _sessionPasswords = {};
  // Runtime-only: paths where user explicitly forgot password (cleared on restart)
  final Set<String> _forgetBlacklist = {};

  List<String> get defaultPasswords {
    final raw = appdata.settings[archiveDefaultPasswordsSettingIndex];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return const [];
  }

  bool get autoUnlockEnabled =>
      appdata.settings[archiveAutoUnlockEnabledSettingIndex] == '1';

  Future<void> setAutoUnlockEnabled(bool value) async {
    appdata.settings[archiveAutoUnlockEnabledSettingIndex] = value ? '1' : '0';
    await appdata.updateSettings();
    notifyListeners();
  }

  Future<void> addDefaultPassword(String password) async {
    final passwords = defaultPasswords.toList();
    if (!passwords.contains(password)) {
      passwords.add(password);
      appdata.settings[archiveDefaultPasswordsSettingIndex] =
          jsonEncode(passwords);
      await appdata.updateSettings();
      notifyListeners();
    }
  }

  Future<void> removeDefaultPassword(String password) async {
    final passwords = defaultPasswords.where((p) => p != password).toList();
    appdata.settings[archiveDefaultPasswordsSettingIndex] =
        jsonEncode(passwords);
    await appdata.updateSettings();
    notifyListeners();
  }

  Future<void> clearDefaultPasswords() async {
    appdata.settings[archiveDefaultPasswordsSettingIndex] = '[]';
    await appdata.updateSettings();
    notifyListeners();
  }

  void setSessionPassword(String archivePath, String password) {
    _sessionPasswords[archivePath] = password;
    _forgetBlacklist.remove(archivePath);
  }

  String? getSessionPassword(String archivePath) {
    return _sessionPasswords[archivePath];
  }

  void forget(String archivePath) {
    _sessionPasswords.remove(archivePath);
    _forgetBlacklist.add(archivePath);
    notifyListeners();
  }

  bool isBlacklisted(String archivePath) {
    return _forgetBlacklist.contains(archivePath);
  }

  // Returns candidates in priority order: session > defaults
  List<String?> passwordCandidates(String archivePath) {
    final candidates = <String?>[];
    final session = _sessionPasswords[archivePath];
    if (session != null) candidates.add(session);
    if (!isBlacklisted(archivePath) && autoUnlockEnabled) {
      candidates.addAll(defaultPasswords);
    }
    candidates.add(null);
    return candidates;
  }
}
