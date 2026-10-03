import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

enum IllustFolderRetention { session, restart }

class IllustFolderPreferences extends ChangeNotifier {
  IllustFolderPreferences({Future<SharedPreferences> Function()? loader})
      : _loader = loader ?? SharedPreferences.getInstance;
  static final instance = IllustFolderPreferences();
  static const storageKey = 'illust_folder_preferences_v1';
  final Future<SharedPreferences> Function() _loader;
  Future<void>? _loading;
  Future<void> _tail = Future.value();
  SharedPreferences? _preferences;
  final _selected = <String, String?>{};
  IllustFolderRetention _retention = IllustFolderRetention.restart;
  IllustFolderRetention get retention => _retention;

  static String scope(String root, String libraryId) =>
      jsonEncode([p.normalize(root), libraryId]);
  String? selection(String scope) => _selected[scope];

  Future<void> load() =>
      _loading ??= _read().catchError((Object error, StackTrace stack) {
        _loading = null;
        Error.throwWithStackTrace(error, stack);
      });
  Future<void> _read() async {
    _preferences = await _loader();
    try {
      final data = jsonDecode(_preferences!.getString(storageKey) ?? '{}');
      if (data is! Map) return;
      _retention = data['retention'] == 'session'
          ? IllustFolderRetention.session
          : IllustFolderRetention.restart;
      if (_retention == IllustFolderRetention.restart &&
          data['selected'] is Map) {
        for (final entry in (data['selected'] as Map).entries.take(64)) {
          if (entry.key is String &&
              (entry.value == null || entry.value is String)) {
            _selected[entry.key] = entry.value;
          }
        }
      }
    } catch (_) {
      // A damaged view preference never changes a directory or download record.
    }
    notifyListeners();
  }

  Future<void> remember(String scope, String? folderId) => _change(() {
        _selected.remove(scope);
        _selected[scope] = folderId;
        while (_selected.length > 64) {
          _selected.remove(_selected.keys.first);
        }
      });

  Future<void> setRetention(IllustFolderRetention retention) => _change(() {
        _retention = retention;
      });

  Future<void> _change(VoidCallback change) {
    final operation = _tail.then((_) async {
      await load();
      final previous = Map<String, String?>.from(_selected);
      final previousRetention = _retention;
      change();
      try {
        final saved = await _preferences!.setString(
            storageKey,
            jsonEncode({
              'retention': _retention.name,
              'selected':
                  _retention == IllustFolderRetention.restart ? _selected : {},
            }));
        if (!saved) throw StateError('无法保存文件夹选择偏好');
      } catch (_) {
        _selected
          ..clear()
          ..addAll(previous);
        _retention = previousRetention;
        rethrow;
      }
      notifyListeners();
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }
}
