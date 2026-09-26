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

/// 托管下载行要显示的**作者文本**（列表卡片的 `subTitle` 位）。
///
/// ## 三条来源与优先级（从高到低）
///
/// 1. **自定义源（`CustomDownloadedItem` 系）→ 直取 `subTitle`。**
///    这类记录的 `subTitle` **本身就是作者**：Pixiv 写的是 `comic.author`
///    （单作者），Komiic 写的是 `comic.authors.join(', ')`
///    （见 `online_download_manager.dart:1470` 与 `:1768`）。21 号真机实测的
///    `電瘋扇` / `久蒼穹` / `LightRia` 就是它。
/// 2. json 里能解析出源自身的作者元数据 → 用它（EH 的 `artist:` 标签、
///    NH 的 `Artists` 分类，13 号轮建立）。
/// 3. EH/NH 拿不到 → **空串**（既有铁律：宁可不显示，也不用 uploader 冒充作者）。
///
/// ## 为什么自定义源必须**绕开**第 2、3 步那条链
///
/// 那条链是为 EH/NH 的**分类元数据**建的，而 Pixiv/Komiic 的 json 里根本没有
/// 那些字段（第一步必然为空）；它们的 `type` 又是 `DownloadType.other`，
/// 躲过了那句 `return ''`，于是落到最后一步 [resolveDownloadedAuthors] ——
/// 而它**刻意**对 `CustomDownloadedItem` 返回空（见该函数 37-39 行：
/// "自定义记录没有源安全的作者契约"）。两处都为空 → 作者被**静默丢掉**：
/// `subTitle` 为空 → 卡片侧 `buildIllustCardInfoSpans` 对空值跳过 → 作者不显示。
/// （33 号真机反馈"已下载的插画没有作者字段"，根因就是这里绕错了链。）
///
/// ## 为什么只认类型、不再看 `sourceKey`
///
/// `parseDownloadedItemRecordJson` 只在两种情况下产出 `CustomDownloadedItem`：
/// json 里带 `sourceKey`，或 id 含 `-`。而 `subTitle` 这个**驼峰键**只由
/// `CustomDownloadedItem.toJson` 写入（其余类的 toJson 写的是小写 `subtitle`
/// 列名，两者不同键），所以"是 `CustomDownloadedItem` 且 `subTitle` 非空"
/// 等价于"这条记录确实是自定义源写下的"。
///
/// 反过来，**真实 EH/NH 记录永远不会在这里被截走**：它们的 json 带
/// `galleryTitle` 之类字段，被解析成 `DownloadedGallery` / `NhentaiDownloadedComic`，
/// 走第 2、3 步，行为与改动前逐字一致。唯一会落到本分支的 EH 形态是
/// "id 含 `-` 且 json 坏到没有 `galleryTitle`"——那种 json 里也不会出现驼峰
/// `subTitle`，返回值仍是空串，与原行为相同。
///
/// ## 空值是合法结果
///
/// `subTitle` 为空时**原样返回空串**（不兜底成"未知"之类的占位文案）：
/// 卡片侧对空值的"整项跳过、连分隔符一起不产出"是**有意的**，见
/// `illust_card_info_config.dart:255-257`。
String resolveDownloadedRowAuthor({
  required String rawJson,
  required DownloadedItem fallback,
}) {
  if (fallback is CustomDownloadedItem) {
    return fallback.subTitle.trim();
  }
  final resolved = resolveDownloadedAuthorsFromRecord(
    fallback.id,
    rawJson,
    fallback: fallback,
  );
  if (resolved.isNotEmpty) {
    return resolved.join(', ');
  }
  if (fallback.type == DownloadType.ehentai ||
      fallback.type == DownloadType.nhentai) {
    return '';
  }
  return resolveDownloadedAuthors(fallback).join(', ');
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

