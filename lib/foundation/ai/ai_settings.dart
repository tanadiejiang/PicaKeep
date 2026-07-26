import '../../base.dart';

// AI Tab 可见性
const showAiTabSettingIndex = 120;

// 能力开关
const aiCapabilitySearchOnlineSettingIndex = 121;
const aiCapabilityDownloadComicSettingIndex = 122;
const aiCapabilitySearchLocalSettingIndex = 123;
const aiCapabilityQueryLocalLibrarySettingIndex = 124;
const aiCapabilityResolveLocalItemsSettingIndex = 125;
const aiCapabilityGetDownloadStatusSettingIndex = 126;
const aiCapabilityQueryRemoteLibrarySettingIndex = 133;
const aiCapabilityDisplayResultListSettingIndex = 134;
const aiCapabilityManageFavoritesSettingIndex = 135;

// Provider 配置
const aiProviderTemplateSettingIndex = 127;
const aiBaseUrlSettingIndex = 128;
const aiApiKeySettingIndex = 129;
const aiModelIdSettingIndex = 130;
const aiModelParamsSettingIndex = 131;

// 提示词模板
const aiPromptTemplatesSettingIndex = 132;
const aiPromptTagsLongTermSettingIndex = 136;
const aiPromptTemplatesInitializedSettingIndex = 137;
// 工具调用最大轮次；'0' 表示不限制
const aiMaxToolRoundsSettingIndex = 138;
const aiCapabilityGetComicDetailSettingIndex = 139;

// 消息索引（17号计划步骤 10）
// '1' = 索引面板只列用户消息；'0' = user + assistant 都列。
const aiIndexUserOnlySettingIndex = 141;
// 右边缘迷你索引条的横线数上限；'0' 表示不限制。
// 只截断迷你索引条，面板内条目始终与消息 1:1（保证松手跳转精确）。
const aiIndexBarMaxTicksSettingIndex = 142;

/// 返回给定能力名称对应的 settings index；找不到返回 null。
int? aiCapabilitySettingIndex(String toolName) {
  return const {
    'search_online': aiCapabilitySearchOnlineSettingIndex,
    'download_comic': aiCapabilityDownloadComicSettingIndex,
    'search_local': aiCapabilitySearchLocalSettingIndex,
    'query_local_library': aiCapabilityQueryLocalLibrarySettingIndex,
    'resolve_local_items': aiCapabilityResolveLocalItemsSettingIndex,
    'get_download_status': aiCapabilityGetDownloadStatusSettingIndex,
    'query_remote_library': aiCapabilityQueryRemoteLibrarySettingIndex,
    'display_result_list': aiCapabilityDisplayResultListSettingIndex,
    'manage_favorites': aiCapabilityManageFavoritesSettingIndex,
    'get_comic_detail': aiCapabilityGetComicDetailSettingIndex,
  }[toolName];
}

/// 能力是否已开启。
bool isAiCapabilityEnabled(String toolName) {
  final idx = aiCapabilitySettingIndex(toolName);
  if (idx == null) return false;
  return appdata.settings[idx] == '1';
}
