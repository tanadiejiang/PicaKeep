import 'package:picakeep/base.dart';

const int pixivAuthorPreviewCountSettingIndex = 168;
const int pixivRelatedBatchSizeSettingIndex = 169;
const int pixivRelatedModeSettingIndex = 170;
const String pixivRelatedModePixiv = 'pixiv';
const String pixivRelatedModeCustom = 'custom';
const int pixivDetailFeedDefaultCount = 5;
const int pixivAuthorPreviewMaximumCount = 30;
const int pixivRelatedMaximumBatchSize = 18;

int _normalizeCount(Object? raw, int maximum) {
  final int? value;
  if (raw is int) {
    value = raw;
  } else if (raw is String && RegExp(r'^[0-9]+$').hasMatch(raw.trim())) {
    value = int.tryParse(raw.trim());
  } else {
    value = null;
  }
  return value != null && value >= 1 && value <= maximum
      ? value
      : pixivDetailFeedDefaultCount;
}

int normalizePixivAuthorPreviewCount(Object? raw) =>
    _normalizeCount(raw, pixivAuthorPreviewMaximumCount);

int normalizePixivRelatedBatchSize(Object? raw) =>
    _normalizeCount(raw, pixivRelatedMaximumBatchSize);

String normalizePixivRelatedMode(Object? raw) =>
    raw is String && raw == pixivRelatedModeCustom
        ? pixivRelatedModeCustom
        : pixivRelatedModePixiv;

String readPixivRelatedMode([List<String>? settings]) =>
    normalizePixivRelatedMode((settings ?? appdata.settings)
        .elementAtOrNull(pixivRelatedModeSettingIndex));

/// null lets Pixiv determine this round's size; the stored manual count remains
/// available when the user switches back to custom mode.
int? readPixivRelatedRequestedCount([List<String>? settings]) =>
    readPixivRelatedMode(settings) == pixivRelatedModePixiv
        ? null
        : readPixivRelatedBatchSize(settings);

int readPixivAuthorPreviewCount([List<String>? settings]) =>
    normalizePixivAuthorPreviewCount((settings ?? appdata.settings)
        .elementAtOrNull(pixivAuthorPreviewCountSettingIndex));

int readPixivRelatedBatchSize([List<String>? settings]) =>
    normalizePixivRelatedBatchSize((settings ?? appdata.settings)
        .elementAtOrNull(pixivRelatedBatchSizeSettingIndex));
