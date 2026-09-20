import 'download_model.dart';

/// The author/artist shown to users is source metadata, not the generic
/// DownloadedItem.subTitle field. EH uploader and NH groups are deliberately
/// excluded from this resolver.
List<String> resolveDownloadedAuthors(DownloadedItem item) {
  final json = item.toJson();
  final rawJson = json['sourceRowJson']?.toString().trim() ?? '';
  final originalId = json['originalId']?.toString().trim() ?? '';
  if (rawJson.isNotEmpty && originalId.isNotEmpty) {
    final parsed = parseDownloadedItemRecordJson(originalId, rawJson);
    if (parsed != null && parsed != item) {
      return resolveDownloadedAuthors(parsed);
    }
    if (item.type == DownloadType.ehentai ||
        item.type == DownloadType.nhentai) {
      return const <String>[];
    }
  }
  if (item is DownloadedGallery) {
    return resolveEhAuthorsFromFlatTags(item.tags);
  }
  if (item is NhentaiDownloadedComic) {
    return resolveNhentaiAuthors(item.categorizedTags);
  }
  if (item is DownloadedHitomiComic) {
    return _stablePeople(item.artists);
  }
  if (item is DownloadedComic) {
    return _splitPeople(item.author);
  }
  if (item is DownloadedJmComic) {
    return _splitPeople(item.author);
  }
  // HtManga stores an uploader, not an artist, and custom records do not have
  // a source-safe author contract. Do not turn those fields into authors.
  if (item is DownloadedHtComic || item is CustomDownloadedItem) {
    return const <String>[];
  }
  return _splitPeople(item.subTitle);
}

/// Resolves a managed download database row without importing any page/UI
/// code. EH/NH rows with broken or missing JSON intentionally resolve empty.
List<String> resolveDownloadedAuthorsFromRecord(
  String id,
  String rawJson, {
  DownloadedItem? fallback,
}) {
  final parsed = parseDownloadedItemRecordJson(id, rawJson);
  if (parsed != null) {
    return resolveDownloadedAuthors(parsed);
  }
  if (fallback != null &&
      fallback.type != DownloadType.ehentai &&
      fallback.type != DownloadType.nhentai) {
    return resolveDownloadedAuthors(fallback);
  }
  return const <String>[];
}

List<String> resolveEhAuthorsFromFlatTags(Iterable<String> tags) {
  final result = <String>[];
  for (final raw in tags) {
    final separator = raw.indexOf(':');
    if (separator <= 0) continue;
    final namespace = raw.substring(0, separator).trim().toLowerCase();
    if (namespace != 'artist') continue;
    _addStable(result, raw.substring(separator + 1));
  }
  return result;
}

List<String> resolveNhentaiAuthors(
  Map<String, List<String>> categorizedTags,
) {
  final result = <String>[];
  for (final entry in categorizedTags.entries) {
    if (entry.key.trim().toLowerCase() != 'artists') continue;
    for (final value in entry.value) {
      _addStable(result, value);
    }
  }
  return result;
}

/// Resolves the author contract for an online/source-neutral record.
///
/// EH search/favorite rows carry namespaced flat tags, while NH list rows do
/// not carry the Artists category and therefore must remain unknown. Other
/// sources keep their existing explicit author field.
List<String> resolveSourceAuthors({
  required String source,
  Iterable<String> flatTags = const <String>[],
  Map<String, List<String>> categorizedTags = const <String, List<String>>{},
  String fallbackAuthor = '',
}) {
  switch (source.trim().toLowerCase()) {
    case 'ehentai':
    case 'eh':
      return resolveEhAuthorsFromFlatTags(flatTags);
    case 'nhentai':
    case 'nh':
      return resolveNhentaiAuthors(categorizedTags);
    default:
      return splitAuthorNames(fallbackAuthor);
  }
}

List<String> splitAuthorNames(String value) => _stablePeople(
      value.split(RegExp(r'[,，、]')),
    );

List<String> _splitPeople(String value) => splitAuthorNames(value);

List<String> _stablePeople(Iterable<String> values) {
  final result = <String>[];
  for (final value in values) {
    _addStable(result, value);
  }
  return result;
}

void _addStable(List<String> result, String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || result.contains(normalized)) return;
  result.add(normalized);
}

/// 列表卡片"描述位"的显示文本。
///
/// 约定：源自身有简介就显示简介；没有简介时回退到该源的标识号，避免描述位
/// 空白（用户视角"卡片信息不全"）。JM / NH 的列表接口不返回简介，故回退标识号；
/// picacg / ehentai 保持原描述不动。
/// 该回退只在描述为空时发生，不会覆盖任何既有简介。
///
/// [showId] = false 时不回退标识号（「卡片信息显示 → 显示来源 id」关闭），
/// 描述位保持为空；有简介时一律照常显示简介，与本开关无关。
String displaySourceInfoLine({
  required String source,
  required String comicId,
  required String description,
  bool showId = true,
}) {
  final desc = description.trim();
  if (desc.isNotEmpty) return desc;
  if (!showId) return desc;
  final id = comicId.trim();
  if (id.isEmpty) return desc;
  switch (source.trim().toLowerCase()) {
    case 'jm':
      // 与 local_app_links 的下载 id 同构（jm1466163），用户可在站点直接检索。
      return 'jm$id';
    case 'nhentai':
    case 'nh':
      return 'nhentai$id';
    default:
      return desc;
  }
}

/// 本地收藏卡片"来源标识号"那一行的文本（`jm<id>` / `nhentai<id>`）。
///
/// 与 [displaySourceInfoLine] 的区别：后者是**网络列表**描述位的"无简介时兜底"，
/// 有简介就整体让位；本地收藏的描述位已被"时间 | 来源名"占用，需求是**额外多一行
/// id**，所以判定只看"target 是否是有意义的数字 id"，与描述内容无关。
///
/// 仅 JM / NHentai 有该显示：EH 的 target 是完整画廊 URL（远超卡片宽度）、
/// picacg 是 ObjectId、其余源无此形态 —— 一律返回 null（调用方不渲染该行）。
///
/// [showId] = false 时（「卡片信息显示 → 显示来源 id」关闭）直接返回 null，
/// 调用方据此不产生任何占位空白。
String? favoriteSourceIdLabel({
  required int typeKey,
  required String target,
  bool showId = true,
}) {
  if (!showId) return null;
  final id = target.trim();
  if (id.isEmpty) return null;
  switch (typeKey) {
    case favoriteTypeJmKey:
      // 与 local_app_links 的下载 id 同构（jm1472970），可在站点直接检索。
      return 'jm$id';
    case favoriteTypeNhentaiKey:
      return 'nhentai$id';
    default:
      return null;
  }
}

/// [FavoriteType.jm] 的 key（定义在 `foundation/local_favorites.dart`，此处按值引用，
/// 避免本文件反向依赖收藏模块的数据层）。
const favoriteTypeJmKey = 2;

/// [FavoriteType.nhentai] 的 key。
const favoriteTypeNhentaiKey = 6;

