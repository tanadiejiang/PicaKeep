/// 从画廊链接中提取唯一标识：`画廊号-token`。
///
/// 公共契约（02 计划钉死）：正则 `/g/(\d+)/([a-z0-9]+)` → `'数字-token'`。
///
/// 与 `download_model.dart::DownloadedGallery.id` 规则完全一致，
/// 保证在线详情页打开阅读时算出的 downloadId 能命中已下载条目。
/// 注：PicaKeep 的 `DownloadedGallery.id`/`downloadId` 不带 `'eh'` 前缀，
/// 因此 ehentai 的 downloadId 直接取 `getGalleryId(link)`，不再额外拼前缀。
///
/// （history.dart / local_favorites.dart 的 `_extractEhGalleryId` 目前只取
/// 纯数字，作为模糊匹配候选之一，属既有遗留，不在本计划修改范围。）
String getGalleryId(String link) {
  final match = RegExp(r'/g/(\d+)/([a-z0-9]+)').firstMatch(link);
  if (match != null) {
    return '${match.group(1)}-${match.group(2)}';
  }
  return link;
}
