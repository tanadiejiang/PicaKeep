/// Only the visible numerical caption is optional; queue state stays intact.
const int pixivBookmarkQueueCountsSettingIndex = 166;

String normalizePixivBookmarkQueueCounts(String? raw) => raw == '1' ? '1' : '0';

bool showPixivBookmarkQueueCounts(List<String> settings) =>
    settings.length > pixivBookmarkQueueCountsSettingIndex &&
    settings[pixivBookmarkQueueCountsSettingIndex] == '1';
