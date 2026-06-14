import 'dart:convert';

typedef ArchivePasswordStorePersist = Future<void> Function(
  List<String> defaultPasswords,
  bool autoUnlockEnabled,
);

class ArchivePasswordStore {
  ArchivePasswordStore._();
  static final ArchivePasswordStore instance = ArchivePasswordStore._();

  final Map<String, String> _sessionPasswords = {};
  final Set<String> _forgetBlacklist = {};
  final List<void Function()> _listeners = <void Function()>[];

  List<String> _defaultPasswords = const <String>[];
  bool _autoUnlockEnabled = true;
  ArchivePasswordStorePersist? _persist;

  List<String> get defaultPasswords => List<String>.unmodifiable(_defaultPasswords);

  bool get autoUnlockEnabled => _autoUnlockEnabled;

  void configure({
    List<String>? defaultPasswords,
    bool? autoUnlockEnabled,
    ArchivePasswordStorePersist? persist,
  }) {
    if (defaultPasswords != null) {
      _defaultPasswords = _normalizePasswords(defaultPasswords);
    }
    if (autoUnlockEnabled != null) {
      _autoUnlockEnabled = autoUnlockEnabled;
    }
    if (persist != null) {
      _persist = persist;
    }
    _notifyListeners();
  }

  void configureFromRawSettings({
    required String defaultPasswordsJson,
    required String autoUnlockEnabledValue,
    ArchivePasswordStorePersist? persist,
  }) {
    configure(
      defaultPasswords: decodeDefaultPasswords(defaultPasswordsJson),
      autoUnlockEnabled: autoUnlockEnabledValue == '1',
      persist: persist,
    );
  }

  static List<String> decodeDefaultPasswords(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return _normalizePasswords(decoded.map((e) => e.toString()));
      }
    } catch (_) {}
    return const <String>[];
  }

  static String encodeDefaultPasswords(Iterable<String> passwords) {
    return jsonEncode(_normalizePasswords(passwords));
  }

  Future<void> setAutoUnlockEnabled(bool value) async {
    if (_autoUnlockEnabled == value) {
      return;
    }
    _autoUnlockEnabled = value;
    await _save();
    _notifyListeners();
  }

  Future<void> addDefaultPassword(String password) async {
    final normalized = password.trim();
    if (normalized.isEmpty || _defaultPasswords.contains(normalized)) {
      return;
    }
    _defaultPasswords = <String>[..._defaultPasswords, normalized];
    await _save();
    _notifyListeners();
  }

  Future<void> removeDefaultPassword(String password) async {
    final next = _defaultPasswords.where((p) => p != password).toList();
    if (next.length == _defaultPasswords.length) {
      return;
    }
    _defaultPasswords = next;
    await _save();
    _notifyListeners();
  }

  Future<void> clearDefaultPasswords() async {
    if (_defaultPasswords.isEmpty) {
      return;
    }
    _defaultPasswords = const <String>[];
    await _save();
    _notifyListeners();
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
    _notifyListeners();
  }

  bool isBlacklisted(String archivePath) {
    return _forgetBlacklist.contains(archivePath);
  }

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

  void addListener(void Function() listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  Future<void> _save() async {
    await _persist?.call(_defaultPasswords, _autoUnlockEnabled);
  }

  void _notifyListeners() {
    for (final listener in List<void Function()>.from(_listeners)) {
      listener();
    }
  }

  static List<String> _normalizePasswords(Iterable<String> passwords) {
    final seen = <String>{};
    return passwords
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && seen.add(e))
        .toList(growable: false);
  }
}
