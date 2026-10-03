import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:picakeep/foundation/app.dart';

import 'ai_tool_plugin.dart';
export 'ai_tool_plugin.dart';

class AiToolPluginRecord {
  const AiToolPluginRecord(this.plugin, {this.enabled = true, this.previous});
  final AiToolPlugin plugin;
  final bool enabled;
  final AiToolPlugin? previous;
}

class AiToolPluginStore extends ChangeNotifier {
  static const maxStoreBytes = 4 * 1024 * 1024;
  AiToolPluginStore.atFile(this.file);
  static AiToolPluginStore? _instance;
  static AiToolPluginStore get instance =>
      _instance ??= AiToolPluginStore.atFile(
          File('${App.dataPath}/ai_tool_plugins/plugins.json'));

  static List<AiToolPluginRecord> get loadedRecords =>
      _instance?.records ?? const [];

  final File file;
  Map<String, AiToolPluginRecord> _records = {
    builtinImagePluginId: AiToolPluginRecord(builtinImageSearchPlugin()),
  };
  bool _maintenanceEnabled = false;
  bool get maintenanceEnabled => _maintenanceEnabled;
  String? loadWarning;
  Future<void>? _loading;
  Future<void> _tail = Future.value();
  List<AiToolPluginRecord> get records => List.unmodifiable(_records.values);
  AiToolPluginRecord? record(String id) => _records[id];
  bool enabled(String id) => _records[id]?.enabled == true;

  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      if (!await file.exists()) return;
      if (await file.length() > maxStoreBytes) {
        throw const FormatException('插件库过大');
      }
      final data = jsonDecode(await file.readAsString());
      if (data is! Map ||
          data['version'] != 1 ||
          data['plugins'] is! List ||
          data['plugins'].length > 32) {
        throw const FormatException('插件库结构不正确');
      }
      final loaded = <String, AiToolPluginRecord>{};
      for (final item in data['plugins']) {
        final plugin =
            AiToolPlugin.fromJson(Map<String, dynamic>.from(item['plugin']));
        if (loaded.containsKey(plugin.id)) {
          throw const FormatException('重复的插件 ID');
        }
        final previous = item['previous'] == null
            ? null
            : AiToolPlugin.fromJson(
                Map<String, dynamic>.from(item['previous']));
        if (previous != null &&
            (previous.id != plugin.id || previous.kind != plugin.kind)) {
          throw const FormatException('上一版本身份不匹配');
        }
        loaded[plugin.id] = AiToolPluginRecord(plugin,
            enabled: item['enabled'] == true, previous: previous);
      }
      loaded.putIfAbsent(builtinImagePluginId,
          () => AiToolPluginRecord(builtinImageSearchPlugin()));
      if (loaded.length > 32) {
        throw const FormatException('最多安装 32 个工具插件（含内置搜图）');
      }
      _records = loaded;
      _maintenanceEnabled = data['maintenanceEnabled'] == true;
    } catch (_) {
      loadWarning = '插件库无法读取，已使用内置搜图适配。原文件尚未改动。';
    }
    notifyListeners();
  }

  Future<void> _mutate(void Function(Map<String, AiToolPluginRecord>) action,
      {bool? maintenance}) {
    final result = _tail.then((_) async {
      await load();
      final next = Map<String, AiToolPluginRecord>.from(_records);
      action(next);
      if (next.length > 32) throw const FormatException('最多安装 32 个工具插件');
      final allowMaintenance = maintenance ?? _maintenanceEnabled;
      final encoded = jsonEncode({
        'version': 1,
        'maintenanceEnabled': allowMaintenance,
        'plugins': [
          for (final record in next.values)
            {
              'plugin': record.plugin.toJson(),
              'enabled': record.enabled,
              if (record.previous != null)
                'previous': record.previous!.toJson(),
            }
        ],
      });
      final encodedBytes = utf8.encode(encoded);
      if (encodedBytes.length > maxStoreBytes) {
        throw const FormatException('插件库超过 4MB，请删除不再使用的插件');
      }
      await file.parent.create(recursive: true);
      if (loadWarning != null && await file.exists()) {
        await file.copy(
            '${file.path}.unreadable-${DateTime.now().millisecondsSinceEpoch}');
      }
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsBytes(encodedBytes, flush: true);
      await temporary.rename(file.path);
      _records = next;
      _maintenanceEnabled = allowMaintenance;
      loadWarning = null;
      notifyListeners();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> importManifest(String text, {bool fromAi = false}) async {
    if (utf8.encode(text).length > aiToolPluginManifestMaxBytes) {
      throw const FormatException('插件清单超过 64KB');
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map) throw const FormatException('插件清单必须为 JSON 对象');
    final plugin = AiToolPlugin.fromJson(Map<String, dynamic>.from(decoded));
    await _mutate((next) {
      final old = next[plugin.id];
      if (fromAi) {
        if (!_maintenanceEnabled) {
          throw const FormatException('请先在插件管理中开启 AI 维护');
        }
        if (old == null) throw const FormatException('AI 只能更新已安装插件；新插件请先导入');
        if (old.plugin.endpoint.origin != plugin.endpoint.origin ||
            old.plugin.kind != plugin.kind) {
          throw const FormatException('AI 更新不能变更网络来源或执行器类型');
        }
      }
      if (old != null && old.plugin.kind != plugin.kind) {
        throw const FormatException('不能改变已安装插件类型');
      }
      if (old != null &&
          jsonEncode(old.plugin.toJson()) == jsonEncode(plugin.toJson())) {
        return;
      }
      next[plugin.id] = AiToolPluginRecord(plugin,
          enabled: old?.enabled ?? true, previous: old?.plugin);
    });
  }

  Future<void> setEnabled(String id, bool enabled) => _mutate((next) {
        final current = next[id];
        if (current == null) throw const FormatException('插件不存在');
        next[id] = AiToolPluginRecord(current.plugin,
            enabled: enabled, previous: current.previous);
      });

  Future<void> setMaintenanceEnabled(bool enabled) =>
      _mutate((_) {}, maintenance: enabled);

  Future<void> rollback(String id, {bool fromAi = false}) => _mutate((next) {
        if (fromAi && !_maintenanceEnabled) {
          throw const FormatException('AI 维护未开启');
        }
        final current = next[id];
        if (current?.previous == null) {
          throw const FormatException('没有可恢复的上一版本');
        }
        if (fromAi &&
            (current!.previous!.endpoint.origin !=
                    current.plugin.endpoint.origin ||
                current.previous!.kind != current.plugin.kind)) {
          throw const FormatException('AI 回退不能变更网络来源或执行器类型');
        }
        next[id] = AiToolPluginRecord(current!.previous!,
            enabled: current.enabled, previous: current.plugin);
      });

  Future<void> restoreBuiltin() => _mutate((next) {
        final old = next[builtinImagePluginId];
        next[builtinImagePluginId] = AiToolPluginRecord(
            builtinImageSearchPlugin(),
            previous: old?.plugin);
      });

  Future<void> remove(String id) => _mutate((next) {
        if (id == builtinImagePluginId) {
          throw const FormatException('内置搜图可以关闭或恢复，不能删除');
        }
        next.remove(id);
      });

  String exportManifest(String id) {
    final plugin = _records[id]?.plugin;
    if (plugin == null) throw const FormatException('插件不存在');
    final formatted =
        const JsonEncoder.withIndent('  ').convert(plugin.toJson());
    // Pretty-printing must not make a valid manifest impossible to re-import.
    return utf8.encode(formatted).length <= aiToolPluginManifestMaxBytes
        ? formatted
        : jsonEncode(plugin.toJson());
  }
}
