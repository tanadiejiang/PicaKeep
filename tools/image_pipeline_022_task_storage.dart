// Persistent storage adapters used only by the isolated normal-UI entrypoint.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

class ImagePipelineTaskStorage {
  ImagePipelineTaskStorage._(this.root);
  final String root;
  static const markerName = 'normal-ui-verification-022.json';
  static const scope = 'picakeep-isolated-normal-ui-022';

  String get support => p.join(root, 'support');
  String get cache => p.join(root, 'cache');
  String get temporary => p.join(root, 'temporary');
  String get library => p.join(root, 'library');
  String get documents => p.join(root, 'exports');
  String get preferences => p.join(root, 'preferences.json');

  static Future<ImagePipelineTaskStorage> prepare(String value) async {
    if (!p.isAbsolute(value) ||
        p.dirname(p.normalize(value)) == p.normalize(value)) {
      throw ArgumentError('A non-root absolute task directory is required');
    }
    final root = p.normalize(value);
    if (!p.basename(root).startsWith('normal-ui-022-')) {
      throw ArgumentError('Task directory name must start with normal-ui-022-');
    }
    await _rejectLinks(root);
    final directory = Directory(root);
    final marker = File(p.join(root, markerName));
    await _rejectLinks(marker.path);
    if (await directory.exists()) {
      if (!await marker.exists()) {
        throw StateError(
            'Refusing an existing directory without the task marker');
      }
      final data = jsonDecode(await marker.readAsString());
      if (data is! Map ||
          data['scope'] != scope ||
          data['version'] != 1 ||
          data['root'] != root) {
        throw StateError('Task marker identity does not match this directory');
      }
    } else {
      await directory.create(recursive: true);
      await marker.writeAsString(
          jsonEncode({'scope': scope, 'version': 1, 'root': root}),
          flush: true);
    }
    final storage = ImagePipelineTaskStorage._(root);
    for (final path in [
      storage.support,
      storage.cache,
      storage.temporary,
      storage.library,
      storage.documents,
      p.join(storage.support, 'download'),
      p.join(storage.support, 'download_pixiv')
    ]) {
      await storage.checkPath(path);
      await Directory(path).create(recursive: true);
    }
    return storage;
  }

  Future<void> checkPath(String path) async {
    final normalized = p.normalize(p.absolute(path));
    if (normalized != root && !p.isWithin(root, normalized)) {
      throw StateError('Path is outside the verification task');
    }
    await _rejectLinks(normalized);
  }

  static Future<void> _rejectLinks(String path) async {
    var current = p.normalize(path);
    while (true) {
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw StateError('Task storage cannot traverse links: $current');
      }
      if (current != path &&
          type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory) {
        throw StateError('Task storage has a non-directory ancestor');
      }
      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
  }
}

class TaskPathProvider extends PathProviderPlatform {
  TaskPathProvider(this.storage);
  final ImagePipelineTaskStorage storage;

  Future<String> _path(String path) async {
    await storage.checkPath(path);
    await Directory(path).create(recursive: true);
    return path;
  }

  @override
  Future<String?> getTemporaryPath() => _path(storage.temporary);
  @override
  Future<String?> getApplicationSupportPath() => _path(storage.support);
  @override
  Future<String?> getApplicationCachePath() => _path(storage.cache);
  @override
  Future<String?> getLibraryPath() => _path(storage.support);
  @override
  Future<String?> getApplicationDocumentsPath() => _path(storage.documents);
  @override
  Future<String?> getDownloadsPath() => _path(storage.documents);
  @override
  Future<String?> getExternalStoragePath() => _path(storage.documents);
  @override
  Future<List<String>?> getExternalCachePaths() async =>
      [await _path(storage.cache)];
  @override
  Future<List<String>?> getExternalStoragePaths(
          {StorageDirectory? type}) async =>
      [await _path(storage.documents)];
}

/// A real JSON-backed StorePlatform; never delegates to OS/user preferences.
class TaskSharedPreferencesStore extends SharedPreferencesStorePlatform {
  TaskSharedPreferencesStore._(this.storage, this._data);
  final ImagePipelineTaskStorage storage;
  Map<String, Object> _data;
  Future<void>? _tail;

  static Future<TaskSharedPreferencesStore> open(
      ImagePipelineTaskStorage storage) async {
    await storage.checkPath(storage.preferences);
    await storage.checkPath('${storage.preferences}.previous');
    if (await File('${storage.preferences}.previous').exists()) {
      throw StateError(
          'Task preferences recovery file exists; inspect it before retrying');
    }
    final file = File(storage.preferences);
    final data = <String, Object>{};
    if (await file.exists()) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map ||
          decoded['version'] != 1 ||
          decoded['values'] is! Map) {
        throw const FormatException('Invalid task preferences schema');
      }
      for (final entry in (decoded['values'] as Map).entries) {
        if (entry.key is! String) {
          throw const FormatException('Invalid preference key');
        }
        data[entry.key as String] = _copyValue(entry.value);
      }
    }
    return TaskSharedPreferencesStore._(storage, data);
  }

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = (_tail ?? Future<void>.value()).then((_) => operation());
    final tail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _tail = tail;
    unawaited(tail.then((_) {
      if (identical(_tail, tail)) _tail = null;
    }));
    return result;
  }

  static Object _copyValue(Object? value) {
    if (value is String ||
        value is bool ||
        value is int ||
        value is double && value.isFinite) {
      return value!;
    }
    if (value is List && value.every((element) => element is String)) {
      return List<String>.from(value);
    }
    throw const FormatException('Unsupported task preference value');
  }

  Map<String, Object> _copyData() =>
      _data.map((key, value) => MapEntry(key, _copyValue(value)));

  Future<bool> _publish(Map<String, Object> next) async {
    final file = File(storage.preferences);
    final part = File('${file.path}.part');
    final previous = File('${file.path}.previous');
    for (final path in [file.path, part.path, previous.path]) {
      await storage.checkPath(path);
    }
    if (await previous.exists()) {
      throw StateError(
          'Task preferences recovery file exists; inspect it before retrying');
    }
    var movedPrevious = false;
    try {
      await part.writeAsString(jsonEncode({'version': 1, 'values': next}),
          flush: true);
      await storage.checkPath(file.path);
      if (await file.exists()) {
        await file.rename(previous.path);
        movedPrevious = true;
      }
      await part.rename(file.path);
      _data = next;
    } catch (_) {
      if (movedPrevious && !await file.exists()) {
        await previous.rename(file.path);
      }
      rethrow;
    } finally {
      if (await part.exists()) await part.delete();
    }
    if (movedPrevious) await previous.delete();
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      _serial(() async {
        final valid = switch (valueType) {
          'Bool' => value is bool,
          'Double' => value is double && value.isFinite,
          'Int' => value is int,
          'String' => value is String,
          'StringList' =>
            value is List && value.every((element) => element is String),
          _ => false,
        };
        if (!valid) {
          throw ArgumentError('Preference value does not match $valueType');
        }
        final next = _copyData()..[key] = _copyValue(value);
        return _publish(next);
      });

  @override
  Future<bool> remove(String key) =>
      _serial(() => _publish(_copyData()..remove(key)));

  bool _matches(String key, PreferencesFilter filter) =>
      key.startsWith(filter.prefix) &&
      (filter.allowList == null || filter.allowList!.contains(key));

  @override
  Future<bool> clear() => clearWithPrefix('flutter.');
  @override
  Future<bool> clearWithPrefix(String prefix) => clearWithParameters(
      ClearParameters(filter: PreferencesFilter(prefix: prefix)));
  @override
  Future<bool> clearWithParameters(ClearParameters parameters) =>
      _serial(() => _publish(_copyData()
        ..removeWhere((key, _) => _matches(key, parameters.filter))));
  @override
  Future<Map<String, Object>> getAll() => getAllWithPrefix('flutter.');
  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      getAllWithParameters(
          GetAllParameters(filter: PreferencesFilter(prefix: prefix)));
  @override
  Future<Map<String, Object>> getAllWithParameters(
          GetAllParameters parameters) =>
      _serial(() async => _copyData()
        ..removeWhere((key, _) => !_matches(key, parameters.filter)));
}
