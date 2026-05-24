import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/local_library_settings.dart';

class ToolDisplayDefinition {
  const ToolDisplayDefinition({
    required this.id,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.quickLabel,
  });

  final String id;
  final IconData icon;
  final String title;
  final String subtitle;
  final String quickLabel;
}

class ToolDisplayPreferences {
  const ToolDisplayPreferences({
    required this.orderedExternalIds,
    required this.visibleExternalIds,
  });

  final List<String> orderedExternalIds;
  final Set<String> visibleExternalIds;
}

const serviceInfoToolId = 'service_info';
const localFilesToolId = 'local_files';
const localStorageToolId = 'local_storage';
const albumsToolId = 'albums';
const appCapabilitiesToolId = 'app_capabilities';
const trashToolId = 'trash';
const clearCacheToolId = 'clear_cache';

const List<ToolDisplayDefinition> allToolDisplayDefinitions = [
  ToolDisplayDefinition(
    id: serviceInfoToolId,
    icon: Icons.router_outlined,
    title: '服务信息',
    subtitle: '查看当前连接状态、扫描局域网并切换远程服务',
    quickLabel: '服务信息',
  ),
  ToolDisplayDefinition(
    id: localFilesToolId,
    icon: Icons.folder_open,
    title: '本地文件管理',
    subtitle: '管理本地漫画路径与目录来源',
    quickLabel: '本地文件',
  ),
  ToolDisplayDefinition(
    id: localStorageToolId,
    icon: Icons.storage,
    title: '存储空间',
    subtitle: '查看每个本地路径与图集占用',
    quickLabel: '存储空间',
  ),
  ToolDisplayDefinition(
    id: albumsToolId,
    icon: Icons.photo_library,
    title: '图集',
    subtitle: '浏览并切换本地 / 聚合 / 远程图集',
    quickLabel: '图集',
  ),
  ToolDisplayDefinition(
    id: appCapabilitiesToolId,
    icon: Icons.cloud_sync_outlined,
    title: 'APP能力',
    subtitle: '管理客户端 / 服务端运行能力与未来规划',
    quickLabel: 'APP能力',
  ),
  ToolDisplayDefinition(
    id: trashToolId,
    icon: Icons.restore_from_trash_outlined,
    title: '回收站',
    subtitle: '恢复或彻底删除本地与远程已删除项目',
    quickLabel: '回收站',
  ),
  ToolDisplayDefinition(
    id: clearCacheToolId,
    icon: Icons.delete_sweep,
    title: '缓存管理',
    subtitle: '管理本地缓存数据',
    quickLabel: '缓存管理',
  ),
];

final List<String> allExternalToolIds = allToolDisplayDefinitions
    .map((definition) => definition.id)
    .toList(growable: false);

const List<String> defaultVisibleExternalToolIds = [
  serviceInfoToolId,
  localFilesToolId,
  appCapabilitiesToolId,
  trashToolId,
];

final Map<String, ToolDisplayDefinition> toolDisplayDefinitionMap = {
  for (final definition in allToolDisplayDefinitions) definition.id: definition,
};

List<ToolDisplayDefinition> get externalToolDisplayDefinitions =>
    allToolDisplayDefinitions;

ToolDisplayPreferences readToolDisplayPreferences() {
  final orderedExternalIds = decodeExternalToolOrder(
    appdata.settings[externalToolOrderSettingIndex],
  );
  final visibleExternalIds = decodeExternalToolVisibility(
    appdata.settings[externalToolVisibilitySettingIndex],
  ).toSet();
  return ToolDisplayPreferences(
    orderedExternalIds: orderedExternalIds,
    visibleExternalIds: visibleExternalIds,
  );
}

Future<void> saveToolDisplayPreferences(
  ToolDisplayPreferences preferences,
) async {
  final orderedExternalIds = normalizeExternalToolIdOrder(
    preferences.orderedExternalIds,
  );
  final visibleExternalIds = preferences.visibleExternalIds
      .where(allExternalToolIds.contains)
      .toList(growable: false);
  appdata.settings[externalToolOrderSettingIndex] =
      jsonEncode(orderedExternalIds);
  appdata.settings[externalToolVisibilitySettingIndex] =
      jsonEncode(visibleExternalIds);
  await appdata.writeData();
  App.notifyToolDisplayConfigChanged();
}

List<ToolDisplayDefinition> resolveVisibleExternalToolDefinitions() {
  final preferences = readToolDisplayPreferences();
  return preferences.orderedExternalIds
      .where(preferences.visibleExternalIds.contains)
      .map((id) => toolDisplayDefinitionMap[id])
      .whereType<ToolDisplayDefinition>()
      .toList(growable: false);
}

List<String> decodeExternalToolOrder(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return List<String>.from(allExternalToolIds);
  }
  return normalizeExternalToolIdOrder(_decodeToolIdList(raw));
}

List<String> decodeExternalToolVisibility(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return List<String>.from(defaultVisibleExternalToolIds);
  }
  return _decodeToolIdList(
    raw,
  ).where(allExternalToolIds.contains).toList(growable: false);
}

String normalizeExternalToolOrderSetting(String? raw) {
  return jsonEncode(decodeExternalToolOrder(raw));
}

String normalizeExternalToolVisibilitySetting(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return jsonEncode(defaultVisibleExternalToolIds);
  }
  return jsonEncode(decodeExternalToolVisibility(raw));
}

List<String> normalizeExternalToolIdOrder(Iterable<String> ids) {
  final seen = <String>{};
  final ordered = <String>[];
  for (final id in ids) {
    if (allExternalToolIds.contains(id) && seen.add(id)) {
      ordered.add(id);
    }
  }
  for (final id in allExternalToolIds) {
    if (seen.add(id)) {
      ordered.add(id);
    }
  }
  return ordered;
}

List<String> _decodeToolIdList(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      final seen = <String>{};
      return decoded
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty && seen.add(item))
          .toList(growable: false);
    }
  } catch (_) {}

  final seen = <String>{};
  return raw
      .split(',')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty && seen.add(item))
      .toList(growable: false);
}
