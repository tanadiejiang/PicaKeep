import 'dart:convert';

const builtinImagePluginId = 'soutubot';
const aiToolPluginManifestMaxBytes = 64 * 1024;

/// Versioned declarative adapters. Executable code and arbitrary headers are
/// deliberately outside this format; executors define their own capabilities.
class AiToolPlugin {
  AiToolPlugin._(this.json);

  factory AiToolPlugin.fromJson(Map<String, dynamic> input) {
    final encoded = jsonEncode(input);
    if (utf8.encode(encoded).length > aiToolPluginManifestMaxBytes) {
      throw const FormatException('插件清单超过 64KB');
    }
    final json = jsonDecode(encoded) as Map<String, dynamic>;
    if (json['schemaVersion'] != 1) throw const FormatException('不支持的插件格式版本');
    for (final key in ['id', 'name', 'version', 'kind', 'endpoint']) {
      if (json[key] is! String ||
          (json[key] as String).trim().isEmpty ||
          (json[key] as String).length > 256) {
        throw FormatException('插件缺少有效的 $key');
      }
    }
    if (!RegExp(r'^[a-z][a-z0-9_]{1,39}$').hasMatch(json['id'])) {
      throw const FormatException('插件 ID 只允许小写字母、数字和下划线（2–40位）');
    }
    if (!['image_search', 'http_json'].contains(json['kind'])) {
      throw const FormatException('不支持的插件类型');
    }
    final endpoint = Uri.tryParse(json['endpoint']);
    if (endpoint == null ||
        !isPublicPluginUri(endpoint) ||
        endpoint.hasQuery ||
        endpoint.hasFragment) {
      throw const FormatException('接口必须为公开 HTTPS 地址，不含账号、查询串或片段');
    }
    if (json['kind'] == 'image_search') {
      if (json['id'] != builtinImagePluginId ||
          endpoint.host != 'soutubot.moe' ||
          endpoint.port != 443) {
        throw const FormatException('当前搜图执行器只支持 soutubot.moe');
      }
      if (json['fileField'] is! String ||
          !RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,39}$')
              .hasMatch(json['fileField'])) {
        throw const FormatException('无效的图片表单字段');
      }
      _validateStringMap(json['fields'], 'fields');
      final response = json['response'];
      if (response is! Map ||
          !['soutubot_v2', 'legacy'].contains(response['format'])) {
        throw const FormatException('不支持的搜图响应格式');
      }
      for (final key in [
        'resultsPath',
        'segmentsPath',
        'scorePath',
        'idPath'
      ]) {
        _validatePath(response[key]);
      }
      final fieldPaths = response['fieldPaths'];
      if (fieldPaths is! Map || fieldPaths.length > 16) {
        throw const FormatException('无效字段映射');
      }
      for (final paths in fieldPaths.values) {
        if (paths is! List || paths.isEmpty || paths.length > 8) {
          throw const FormatException('无效字段路径');
        }
        for (final path in paths) {
          _validatePath(path);
        }
      }
    } else {
      if (json['id'] == builtinImagePluginId) {
        throw const FormatException('保留的插件 ID');
      }
      if (json['description'] is! String ||
          (json['description'] as String).length > 1000) {
        throw const FormatException('请提供 1000 字以内的工具说明');
      }
      _validateStringMap(json['query'], 'query');
      _validatePath(json['resultPath'] ?? '');
      final parameters = json['parameters'];
      if (parameters is! Map || parameters.length > 12) {
        throw const FormatException('无效参数定义');
      }
      for (final entry in parameters.entries) {
        if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,39}$')
                .hasMatch(entry.key.toString()) ||
            entry.value is! String ||
            entry.value.length > 200) {
          throw const FormatException('工具参数必须为名称与简短说明');
        }
      }
      for (final value in (json['query'] as Map).values) {
        for (final match in RegExp(r'\{([a-zA-Z0-9_]+)\}').allMatches(value)) {
          if (!parameters.containsKey(match.group(1))) {
            throw const FormatException('查询模板引用了未定义参数');
          }
        }
      }
    }
    return AiToolPlugin._(_freezeJson(json) as Map<String, dynamic>);
  }

  final Map<String, dynamic> json;
  String get id => json['id'];
  String get name => json['name'];
  String get version => json['version'];
  String get kind => json['kind'];
  Uri get endpoint => Uri.parse(json['endpoint']);
  String get toolName =>
      kind == 'image_search' ? 'search_by_image' : 'plugin_$id';
  String get description => json['description']?.toString() ?? name;
  Map<String, Object?> get adapter => Map<String, Object?>.from(json);
  Map<String, dynamic> toJson() => jsonDecode(jsonEncode(json));

  // Validation remains true for the lifetime of the adapter, including nested
  // response maps and candidate path lists handed to an executor.
  static Object? _freezeJson(Object? value, [int depth = 0]) {
    if (depth > 32) throw const FormatException('插件清单嵌套过深');
    if (value is Map) {
      return Map<String, dynamic>.unmodifiable({
        for (final entry in value.entries)
          entry.key as String: _freezeJson(entry.value, depth + 1),
      });
    }
    if (value is List) {
      return List<Object?>.unmodifiable(
          value.map((item) => _freezeJson(item, depth + 1)));
    }
    return value;
  }

  static void _validateStringMap(dynamic map, String name) {
    if (map is! Map ||
        map.length > 20 ||
        map.entries.any((entry) =>
            entry.key is! String ||
            !RegExp(r'^[a-zA-Z][a-zA-Z0-9_.-]{0,63}$').hasMatch(entry.key) ||
            entry.value is! String ||
            entry.value.length > 2048)) {
      throw FormatException('无效的 $name 字段');
    }
  }

  static void _validatePath(dynamic path) {
    if (path is! String ||
        path.length > 200 ||
        (path.isNotEmpty &&
            !RegExp(r'^[a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_]+)*$').hasMatch(path))) {
      throw const FormatException('字段路径只支持以点分隔的 JSON 键');
    }
  }
}

bool isPublicPluginUri(Uri uri) {
  final host = uri.host.toLowerCase();
  // Require a normal DNS name. In particular, a final dot must not turn
  // device.local into an apparently public name and bypass the suffix rule.
  final dnsName = RegExp(
      r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$');
  return uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      host.length <= 253 &&
      dnsName.hasMatch(host) &&
      !host.endsWith('.local') &&
      !host.endsWith('.localhost') &&
      !host.endsWith('.internal') &&
      host != 'localhost' &&
      !RegExp(r'^[\d.]+$').hasMatch(host) &&
      !host.contains(':');
}

Object? readPluginJsonPath(Object? value, String path) {
  if (path.isEmpty) return value;
  for (final part in path.split('.')) {
    if (value is! Map || !value.containsKey(part)) return null;
    value = value[part];
  }
  return value;
}

AiToolPlugin builtinImageSearchPlugin() => AiToolPlugin.fromJson({
      'schemaVersion': 1,
      'id': builtinImagePluginId,
      'name': '搜图 Bot',
      'version': '2026.10.03',
      'kind': 'image_search',
      'endpoint': 'https://soutubot.moe/api/search',
      'fileField': 'file',
      'fields': {'factor': '1.2', 'metadata_mode': 'display'},
      'response': {
        'format': 'soutubot_v2',
        'resultsPath': 'results',
        'segmentsPath': 'path_segments',
        'scorePath': 'score',
        'idPath': 'result_id',
        'fieldPaths': {
          'source': [
            'metadata.source.key',
            'metadata.post.source_key',
            'source_key'
          ],
          'sourceId': [
            'metadata.source.id',
            'metadata.post.post_id',
            'external_id'
          ],
          'title': ['metadata.title.primary', 'metadata.title'],
          'url': ['source_url', 'links.source_url'],
          'thumbnail': ['thumbnail_url', 'links.thumbnail_url'],
          'page': ['page_no'],
          'language': [
            'metadata.language',
            'metadata.facts.language',
            'language'
          ],
        },
      },
    });
