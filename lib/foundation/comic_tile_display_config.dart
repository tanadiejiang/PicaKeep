import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';

/// 卡片信息显示配置（JSON）占用的 settings 索引。
///
/// 结构见 [ComicTileDisplaySettings.toJson]：
/// `{"idColor":"orange","local":{...},"online":{...},"search":{"<源 key>":{...}}}`
/// 每个节点是 `{"tagRows":2,"showTags":true,"showId":true}`。
const comicTileDisplayConfigSettingIndex = 150;

/// 来源标识号（`jm<id>` / `nhentai<id>`）那一行的颜色。
///
/// 是**整体一份**、不按页面/源分开：用户改颜色的动机是"这一行我想让它显眼/低调"，
/// 而不是"本地收藏用红、搜索页用蓝"；拆开只会让颜色在同一个应用里乱掉。
///
/// 取值是稳定的字符串键（不是色值数字），坏值一律回退 [comicTileDisplayDefaultIdColor]。
const comicTileDisplayDefaultIdColor = 'orange';

/// 颜色在配置 JSON 里的键名。
const comicTileDisplayIdColorKey = 'idColor';

/// 颜色可选项（存储键）。UI 负责把键映射成 [Color] 与本地化文案。
///
/// - `theme`：跟随主题色（`Theme.of(context).colorScheme.primary`）；
/// - `black`：浅色模式纯黑、**深色模式自动转纯白**（用户明确要求）；
/// - 其余为主题色板里的固定色。
///
/// 不含 `dynamic`：主题色的"跟随系统动态取色"只对主题有意义，卡片上一行小字
/// 没有对应的"动态"来源。
const comicTileDisplayIdColorOptions = <String>[
  comicTileDisplayDefaultIdColor,
  'red',
  'pink',
  'purple',
  'blue',
  'teal',
  'green',
  'black',
  'theme',
];

/// 把任意输入归一化为合法颜色键。
String normalizeComicTileIdColor(Object? raw) {
  if (raw is String && comicTileDisplayIdColorOptions.contains(raw)) {
    return raw;
  }
  return comicTileDisplayDefaultIdColor;
}

/// 颜色键 → 实际颜色。
///
/// - `theme` → 当前主题主色；
/// - `black` → **浅色模式纯黑、深色模式纯白**（深色下纯黑会看不见）；
/// - 其余键映射到主题色板里的固定色（与「外观 → 主题色」同一套取值）。
///
/// 定义在本模块而不是设置页：卡片组件与设置页的色点预览都要用它，放一处才能
/// 保证"预览什么颜色、卡片就是什么颜色"。
Color resolveComicTileIdColor(BuildContext context, String colorKey) {
  if (colorKey == 'theme') {
    return Theme.of(context).colorScheme.primary;
  }
  if (colorKey == 'black') {
    return Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
  }
  return switch (colorKey) {
    'red' => Colors.red,
    'pink' => Colors.pink,
    'purple' => Colors.purple,
    'blue' => Colors.blue,
    'teal' => Colors.teal,
    'green' => Colors.green,
    _ => Colors.orange,
  };
}

/// 颜色键在设置界面上的展示文本（**未翻译原文**，由设置页调 `.tl`）。
String comicTileDisplayIdColorOptionTitle(String colorKey) {
  return switch (colorKey) {
    'theme' => '跟随主题',
    'black' => '黑 / 白',
    _ => colorKey,
  };
}

/// 「标签行数」下拉的可选值。
///
/// 与值对象里的 `tagRows` 一一对应：`2` / `3` / `0`（0 = 不限行）。
const comicTileDisplayTagRowOptions = <int>[2, 3, 0];

/// 「标签行数」在设置界面上的展示文本。
///
/// 返回的是**未翻译的原文**：本模块属于 foundation 层，不感知 UI 语言；
/// 设置页负责在渲染前调 `.tl`（见 comic_card_display_settings.dart）。
String comicTileDisplayTagRowOptionTitle(int rows) {
  if (rows <= 0) {
    return '不限';
  }
  return '$rows';
}

/// 把界面选项归一化为合法 `tagRows`：只接受 2 / 3 / 不限(0)。
///
/// 未知值（含负数）一律回退默认值，避免坏配置把卡片布局打乱。
int normalizeComicTileTagRows(Object? raw) {
  if (raw is int && comicTileDisplayTagRowOptions.contains(raw)) {
    return raw;
  }
  return ComicTileDisplayConfig.defaultTagRows;
}

bool _decodeBool(Object? raw, bool fallback) => raw is bool ? raw : fallback;

/// 单套卡片的「显示哪些信息」。不可变值对象。
class ComicTileDisplayConfig {
  const ComicTileDisplayConfig({
    required this.tagRows,
    required this.showTags,
    required this.showId,
  });

  static const int defaultTagRows = 2;
  static const bool defaultShowTags = true;
  static const bool defaultShowId = true;

  /// 升级前后观感一致的默认值：标签 2 行、显示标签、显示来源 id。
  static const ComicTileDisplayConfig defaults = ComicTileDisplayConfig(
    tagRows: defaultTagRows,
    showTags: defaultShowTags,
    showId: defaultShowId,
  );

  /// 标签展示行数；`<= 0` 表示不限行（交给卡片自身的可选布局处理）。
  final int tagRows;
  final bool showTags;

  /// 仅对描述位回退为 `jm<id>` / `nhentai<id>` 的源有可见效果
  /// （见 `displaySourceInfoLine`）；其余源该项保留但无副作用。
  final bool showId;

  /// 传给卡片的「标签最多几行」；不限行时为 null（走不截断布局）。
  int? get maxTagRows => tagRows <= 0 ? null : tagRows;

  /// 字段严格校验：类型不符即回退默认值，只接受 2 / 3 / 不限。
  factory ComicTileDisplayConfig.fromJson(Object? json) {
    if (json is! Map) {
      return defaults;
    }
    return ComicTileDisplayConfig(
      tagRows: normalizeComicTileTagRows(json['tagRows']),
      showTags: _decodeBool(json['showTags'], defaultShowTags),
      showId: _decodeBool(json['showId'], defaultShowId),
    );
  }

  ComicTileDisplayConfig copyWith({
    int? tagRows,
    bool? showTags,
    bool? showId,
  }) {
    return ComicTileDisplayConfig(
      tagRows: normalizeComicTileTagRows(tagRows ?? this.tagRows),
      showTags: showTags ?? this.showTags,
      showId: showId ?? this.showId,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'tagRows': tagRows,
        'showTags': showTags,
        'showId': showId,
      };

  @override
  bool operator ==(Object other) =>
      other is ComicTileDisplayConfig &&
      other.tagRows == tagRows &&
      other.showTags == showTags &&
      other.showId == showId;

  @override
  int get hashCode => Object.hash(tagRows, showTags, showId);

  @override
  String toString() =>
      'ComicTileDisplayConfig(tagRows: $tagRows, showTags: $showTags, '
      'showId: $showId)';
}

/// 源 key 归一化：大小写与空白不应产生两套独立配置。
String normalizeComicTileSourceKey(String sourceKey) =>
    sourceKey.trim().toLowerCase();

/// 缓存页面键：本地收藏（统一一套，不区分源）。
const comicTileDisplayLocalPageKey = 'local';

/// 缓存页面键：在线收藏（统一一套，不区分源）。
const comicTileDisplayOnlinePageKey = 'online';

/// 缓存页面键：搜索页下按源的配置容器。
const comicTileDisplaySearchPageKey = 'search';

/// 搜索页某个源的配置键（值对象内部用，写成 `search/<源>`）。
///
/// 仅用于缓存失效判定——真正改的是什么由 [writeComicTileDisplayConfig] 落盘。
String comicTileDisplaySearchScopeKey(String sourceKey) =>
    '$comicTileDisplaySearchPageKey/${normalizeComicTileSourceKey(sourceKey)}';

/// JSON 配置的解析结果：既保留合法数据，也记住原始文本。
///
/// 缓存以 [raw] 为准：设置页写入后字符串一定变化，因此不会读到过期副本。
class _DecodedComicTileDisplaySettings {
  const _DecodedComicTileDisplaySettings(this.raw, this.settings);

  final String raw;
  final ComicTileDisplaySettings settings;
}

_DecodedComicTileDisplaySettings? _cached;

/// 读取 settings 索引 150 的原始字符串；索引缺失时按默认值处理。
String readComicTileDisplayConfigRaw() {
  final settings = appdata.settings;
  if (comicTileDisplayConfigSettingIndex < 0 ||
      comicTileDisplayConfigSettingIndex >= settings.length) {
    return '';
  }
  return settings[comicTileDisplayConfigSettingIndex];
}

/// 解析全局配置。
///
/// **任何**解析失败（空串、JSON 损坏、不是对象、节点类型异常）都回退默认值，
/// 绝不抛异常——否则收藏/搜索列表会白屏，比设置失效严重得多。
ComicTileDisplaySettings readComicTileDisplaySettings() {
  final raw = readComicTileDisplayConfigRaw();
  final cached = _cached;
  if (cached != null && cached.raw == raw) {
    return cached.settings;
  }
  final settings = ComicTileDisplaySettings.fromJsonString(raw);
  _cached = _DecodedComicTileDisplaySettings(raw, settings);
  return settings;
}

/// 本地收藏页用的那一套（统一，不区分源）。
ComicTileDisplayConfig readLocalComicTileDisplayConfig() =>
    readComicTileDisplaySettings().local;

/// 在线收藏（网络收藏列表）用的那一套（统一，不区分源）。
ComicTileDisplayConfig readOnlineComicTileDisplayConfig() =>
    readComicTileDisplaySettings().online;

/// 搜索结果页用的那一套；按当前源 key 取，源未配置或 key 未知时回退默认值。
ComicTileDisplayConfig readSearchComicTileDisplayConfig(String sourceKey) =>
    readComicTileDisplaySettings().search(sourceKey);

/// 写入 [scope] 那一套配置：读取原始 JSON → 只改目标节点 → 写回并落盘。
///
/// - `scope: 'local'` / `'online'`：改页面级的那一套；
/// - `scope: 'search'` + [sourceKey]：改「搜索页-该源」那一套。
///
/// 未传的字段沿用该节点当前值（读-改-写），而不是整串重建：值对象在解析时会把
/// 非法字段洗成默认值，整串重建会连用户没碰过的节点一起"重写"。
Future<void> writeComicTileDisplayConfig({
  required String scope,
  String sourceKey = '',
  int? tagRows,
  bool? showTags,
  bool? showId,
}) async {
  final settings = appdata.settings;
  while (settings.length <= comicTileDisplayConfigSettingIndex) {
    settings.add('');
  }
  final root = decodeComicTileDisplayRoot(
      settings[comicTileDisplayConfigSettingIndex]);

  final isSearch = scope == comicTileDisplaySearchPageKey;
  final normalizedSourceKey = normalizeComicTileSourceKey(sourceKey);
  if (isSearch && normalizedSourceKey.isEmpty) {
    // 没有源 key 就无处可写：直接返回，避免在 search 下写出一个空 key 的节点。
    return;
  }

  // 先取出容器再取值，避免在条件表达式里混合空安全索引。
  final existingSearchNode = isSearch ? _searchNode(root) : null;
  final Object? existingNode = isSearch
      ? (existingSearchNode == null
          ? null
          : existingSearchNode[normalizedSourceKey])
      : root[scope];
  final current = ComicTileDisplayConfig.fromJson(existingNode);
  final updated = current.copyWith(
    tagRows: tagRows,
    showTags: showTags,
    showId: showId,
  );

  if (isSearch) {
    _searchNode(root, create: true)![normalizedSourceKey] = updated.toJson();
  } else {
    root[scope] = updated.toJson();
  }

  settings[comicTileDisplayConfigSettingIndex] = jsonEncode(root);
  await appdata.updateSettings();
}

/// 保存整个配置（设置页用）。
///
/// 写的是**已归一化**的 [ComicTileDisplaySettings]：损坏字段在读入时已被洗成
/// 默认值，因此这一写同时修好了坏配置；搜索页下未被识别为源的节点会被丢弃，
/// 这是有意为之——节点的唯一来源就是设置页列出的源。
Future<void> saveComicTileDisplaySettings(
    ComicTileDisplaySettings settings) async {
  final values = appdata.settings;
  while (values.length <= comicTileDisplayConfigSettingIndex) {
    values.add('');
  }
  values[comicTileDisplayConfigSettingIndex] = jsonEncode(settings.toJson());
  await appdata.updateSettings();
}

/// 解析 settings 里的 JSON 根对象；损坏或非对象时返回新的空对象。
///
/// 写回路径必须能修复被损坏的配置，因此这里不做默认值填充，只保证可写。
Map<String, dynamic> decodeComicTileDisplayRoot(String raw) {
  if (raw.trim().isEmpty) {
    return <String, dynamic>{};
  }
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return <String, dynamic>{};
  }
  if (decoded is! Map) {
    return <String, dynamic>{};
  }
  final root = <String, dynamic>{};
  decoded.forEach((key, value) {
    root[key.toString()] = value;
  });
  return root;
}

Map<String, dynamic>? _searchNode(
  Map<String, dynamic> root, {
  bool create = false,
}) {
  final node = root[comicTileDisplaySearchPageKey];
  if (node is Map) {
    final result = <String, dynamic>{};
    node.forEach((key, value) {
      result[key.toString()] = value;
    });
    root[comicTileDisplaySearchPageKey] = result;
    return result;
  }
  if (!create) {
    return null;
  }
  final created = <String, dynamic>{};
  root[comicTileDisplaySearchPageKey] = created;
  return created;
}

/// 整个配置：id 行颜色（整体一份）+ 本地收藏一套 + 在线收藏一套 + 搜索页按源各一套。
class ComicTileDisplaySettings {
  const ComicTileDisplaySettings({
    this.idColor = comicTileDisplayDefaultIdColor,
    required this.local,
    required this.online,
    required this.searchBySource,
  });

  static const ComicTileDisplaySettings defaults = ComicTileDisplaySettings(
    idColor: comicTileDisplayDefaultIdColor,
    local: ComicTileDisplayConfig.defaults,
    online: ComicTileDisplayConfig.defaults,
    searchBySource: <String, ComicTileDisplayConfig>{},
  );

  /// 来源标识号那一行的颜色键（见 [comicTileDisplayIdColorOptions]）。
  final String idColor;
  final ComicTileDisplayConfig local;
  final ComicTileDisplayConfig online;
  final Map<String, ComicTileDisplayConfig> searchBySource;

  /// 只改颜色，其余节点原样保留。
  ComicTileDisplaySettings withIdColor(String colorKey) {
    return ComicTileDisplaySettings(
      idColor: normalizeComicTileIdColor(colorKey),
      local: local,
      online: online,
      searchBySource: searchBySource,
    );
  }

  /// 只改本地收藏那一套。
  ComicTileDisplaySettings withLocal(ComicTileDisplayConfig config) {
    return ComicTileDisplaySettings(
      idColor: idColor,
      local: config,
      online: online,
      searchBySource: searchBySource,
    );
  }

  /// 只改在线收藏那一套。
  ComicTileDisplaySettings withOnline(ComicTileDisplayConfig config) {
    return ComicTileDisplaySettings(
      idColor: idColor,
      local: local,
      online: config,
      searchBySource: searchBySource,
    );
  }

  /// 搜索页某个源的配置；没配过就回退默认值（即与升级前观感一致）。
  ComicTileDisplayConfig search(String sourceKey) {
    if (sourceKey.trim().isEmpty) {
      return ComicTileDisplayConfig.defaults;
    }
    return searchBySource[normalizeComicTileSourceKey(sourceKey)] ??
        ComicTileDisplayConfig.defaults;
  }

  /// 覆盖某个源的搜索页配置；其余节点原样保留。
  ComicTileDisplaySettings withSearch(
    String sourceKey,
    ComicTileDisplayConfig config,
  ) {
    return ComicTileDisplaySettings(
      idColor: idColor,
      local: local,
      online: online,
      searchBySource: <String, ComicTileDisplayConfig>{
        ...searchBySource,
        normalizeComicTileSourceKey(sourceKey): config,
      },
    );
  }

  /// 容错解析：任何类型的异常都回退默认值。
  factory ComicTileDisplaySettings.fromJson(Object? json) {
    if (json is! Map) {
      return defaults;
    }
    final search = <String, ComicTileDisplayConfig>{};
    final searchNode = json[comicTileDisplaySearchPageKey];
    if (searchNode is Map) {
      searchNode.forEach((key, value) {
        final normalized = normalizeComicTileSourceKey(key.toString());
        if (normalized.isEmpty) {
          return;
        }
        search[normalized] = ComicTileDisplayConfig.fromJson(value);
      });
    }
    return ComicTileDisplaySettings(
      idColor: normalizeComicTileIdColor(json[comicTileDisplayIdColorKey]),
      local: ComicTileDisplayConfig.fromJson(
          json[comicTileDisplayLocalPageKey]),
      online: ComicTileDisplayConfig.fromJson(
          json[comicTileDisplayOnlinePageKey]),
      searchBySource: search,
    );
  }

  factory ComicTileDisplaySettings.fromJsonString(String raw) {
    if (raw.trim().isEmpty) {
      return defaults;
    }
    try {
      return ComicTileDisplaySettings.fromJson(jsonDecode(raw));
    } catch (_) {
      return defaults;
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
        comicTileDisplayIdColorKey: idColor,
        comicTileDisplayLocalPageKey: local.toJson(),
        comicTileDisplayOnlinePageKey: online.toJson(),
        comicTileDisplaySearchPageKey: <String, Object?>{
          for (final entry in searchBySource.entries)
            entry.key: entry.value.toJson(),
        },
      };

  /// 深比较（含 [idColor] 与 [searchBySource] 逐键比较）——设置页与测试都靠它判断"配置没变"。
  @override
  bool operator ==(Object other) {
    if (other is! ComicTileDisplaySettings) {
      return false;
    }
    if (other.idColor != idColor) {
      return false;
    }
    if (other.local != local || other.online != online) {
      return false;
    }
    if (other.searchBySource.length != searchBySource.length) {
      return false;
    }
    for (final entry in searchBySource.entries) {
      if (other.searchBySource[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        idColor,
        local,
        online,
        Object.hashAllUnordered(
          searchBySource.entries.map((entry) => Object.hash(entry.key, entry.value)),
        ),
      );

  @override
  String toString() =>
      'ComicTileDisplaySettings(idColor: $idColor, local: $local, '
      'online: $online, search: $searchBySource)';
}
