import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/archive_password_dialog.dart';
import 'package:picakeep/components/info_value_action.dart';
import 'package:picakeep/components/scrollable.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/archive/archive_memory_cache.dart';
import 'package:picakeep/foundation/archive/archive_password_store.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/favorite_source_id.dart'
    as source_id_rules;
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/foundation/trash.dart';
import 'package:picakeep/foundation/untranslated_tags/untranslated_tag_coordinator.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';
import 'package:picakeep/tools/read_history_helper.dart';
import 'package:picakeep/pages/online_comic/eh_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/eh_content_warning.dart';
import 'package:picakeep/pages/online_comic/jm_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/picacg_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/nhentai_comic_page_v2.dart';
import 'package:picakeep/tools/tags_translation.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:uuid/uuid.dart';

import 'local_search_page.dart';

// 提取为顶层纯函数，便于单元测试覆盖（不依赖 State/BuildContext）。
// LocalLibraryComicItem.id 返回内部拼接键 itemId（如
// "local_download::current_download::jm1228705"），不是真实来源ID；
// 真实ID存放在 originalId。取错字段会导致下面的 startsWith/正则校验必然失配，
// 误判为"缺少有效在线ID"（即使该记录本身ID合法）。
String resolveOnlineRawId(DownloadedItem comic) {
  return comic is LocalLibraryComicItem ? comic.originalId : comic.id;
}

// 历史遗留/异常路径的落库数据可能缺少 comicId（jm 前缀去除后为空或非纯数字），
// 直接放行会把空/非法 id 打到服务端，命中 jm_network.dart 的通用
// 'Empty data' 兜底，报错文案对用户毫无意义。返回 null 表示应拦截。
//
// 实现委托给 foundation/favorite_source_id.dart：来源层的
// `FavoriteData.loadComicInfo` 也要用同一套规则，口径只能有一份。
String? extractJmNumericId(String rawId) =>
    source_id_rules.extractJmNumericId(rawId);

String? extractNhentaiNumericId(String rawId) =>
    source_id_rules.extractNhentaiNumericId(rawId);

// 07号计划：菜单"更新信息"可见性条件必须与"在线详情"动作项共用同一判断，
// 不重新发明一套条件（计划执行范围第1节明确要求）。提取为顶层纯函数便于
// 单元测试覆盖，_buildComicInfo 的"在线详情"入口与 _showTitleActionsMenu
// 的"更新信息"菜单项都调用这一个函数。
bool supportsUpdateInfo(DownloadType type) {
  return type == DownloadType.jm ||
      type == DownloadType.picacg ||
      type == DownloadType.nhentai ||
      type == DownloadType.ehentai;
}

// 07号计划：信息区渲染需要 works/actors/chineseTeam/categories/categorizedTags
// 这些具体子类字段，但 _comic 运行时大多是 LocalLibraryComicItem 包装层，其
// toJson() 不包含底层具体子类字段。用 sourceRowJson（download.db 该行原始
// json 列）还原出具体子类实例。parseDownloadedItemRecordJson 内部已经把
// jsonDecode/解析异常吞掉返回 null，这里再包一层显式判空/类型检查，确保
// 非 LocalLibraryComicItem 来源、或 sourceRowJson 为空/非法时都安全返回
// null，不能让信息区因为这个还原失败而崩掉或空白（调用方必须静默回退）。
DownloadedItem? restoreConcreteDownloadedRecord(DownloadedItem comic) {
  if (comic is! LocalLibraryComicItem) {
    return null;
  }
  final rawJson = comic.sourceRowJson;
  if (rawJson == null || rawJson.trim().isEmpty) {
    return null;
  }
  try {
    return parseDownloadedItemRecordJson(comic.originalId, rawJson);
  } catch (_) {
    return null;
  }
}

/// Restores an EH gallery's persisted canonical link without inventing a
/// domain from its `gid-token` local id. Both current flat and historical
/// nested JSON records are handled by [restoreConcreteDownloadedRecord].
String? resolveEhGalleryLink(DownloadedItem comic) {
  final record = comic is DownloadedGallery
      ? comic
      : comic is LocalLibraryComicItem
          ? restoreConcreteDownloadedRecord(comic)
          : null;
  if (record is! DownloadedGallery) {
    return null;
  }

  final link = record.link.trim();
  final uri = Uri.tryParse(link);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  const validHosts = {
    'e-hentai.org',
    'www.e-hentai.org',
    'exhentai.org',
    'www.exhentai.org',
  };
  if (!validHosts.contains(uri.host.toLowerCase()) ||
      !RegExp(r'^/g/\d+/[a-z0-9]+/?$', caseSensitive: false)
          .hasMatch(uri.path)) {
    return null;
  }
  return link;
}

/// 本地详情标签的显示值与源站原始值。显示文本只用于界面；搜索必须使用
/// [rawText]/[rawNamespace]，不能拿翻译后的 [displayText] 反查。
class LocalDetailTagDisplayValue {
  const LocalDetailTagDisplayValue({
    required this.displayText,
    required this.rawText,
    required this.rawValue,
    required this.rawNamespace,
  });

  final String displayText;

  /// 平铺记录中的完整原始文本；分类桶记录中与 [rawValue] 相同。
  final String rawText;

  /// 拆分后的原始源站值，不含 namespace。
  final String rawValue;

  /// 原始 namespace/分类桶名；没有 namespace 时为空字符串。
  final String rawNamespace;
}

/// 本地详情中一个来源感知的标签分类组。
class LocalDetailTagDisplayGroup {
  const LocalDetailTagDisplayGroup({
    required this.displayName,
    required this.rawNamespace,
    required this.values,
  });

  final String displayName;
  final String rawNamespace;
  final List<LocalDetailTagDisplayValue> values;
}

/// EH/NH 在线详情只在中文环境启用标签翻译；本地详情沿用这一来源边界。
bool shouldTranslateLocalDetailTags(
  DownloadType source,
  String languageCode,
) {
  return languageCode.trim().toLowerCase() == 'zh' &&
      (source == DownloadType.ehentai || source == DownloadType.nhentai);
}

/// 将本地保存的平铺标签或 NH 分类桶转换为详情页显示模型。
///
/// - EH/NH 平铺数据只按第一个冒号拆分，避免丢失 value 中的后续冒号。
/// - NH 有分类桶时优先使用分类桶，避免和历史 flat 标签重复。
/// - JM/Picacg 等非 EH/NH 来源保持 flat 标签原样，不套用 EH/NH 翻译表。
List<LocalDetailTagDisplayGroup> buildLocalDetailTagDisplayGroups({
  required DownloadType source,
  required Iterable<String> flatTags,
  Map<String, List<String>> categorizedTags = const <String, List<String>>{},
  required String languageCode,
}) {
  final translate = shouldTranslateLocalDetailTags(source, languageCode);

  LocalDetailTagDisplayValue buildValue({
    required String rawText,
    required String rawValue,
    required String rawNamespace,
  }) {
    final displayText = translate && rawNamespace.isNotEmpty
        ? tagTranslateWithNs(rawValue, rawNamespace)
        : rawValue;
    return LocalDetailTagDisplayValue(
      displayText: displayText,
      rawText: rawText,
      rawValue: rawValue,
      rawNamespace: rawNamespace,
    );
  }

  LocalDetailTagDisplayGroup buildGroup(
    String namespace,
    List<LocalDetailTagDisplayValue> values,
  ) {
    return LocalDetailTagDisplayGroup(
      displayName: namespace.isEmpty
          ? '标签'
          : (translate ? tagTranslateCategory(namespace) : namespace),
      rawNamespace: namespace,
      values: values,
    );
  }

  if (source != DownloadType.ehentai && source != DownloadType.nhentai) {
    final values = <LocalDetailTagDisplayValue>[];
    final seen = <String>{};
    for (final tag in flatTags) {
      final raw = tag.trim();
      if (raw.isEmpty || !seen.add(raw)) continue;
      values.add(LocalDetailTagDisplayValue(
        displayText: raw,
        rawText: raw,
        rawValue: raw,
        rawNamespace: '',
      ));
    }
    return values.isEmpty
        ? const <LocalDetailTagDisplayGroup>[]
        : [buildGroup('', values)];
  }

  final groupedValues = <String, List<LocalDetailTagDisplayValue>>{};
  final seen = <String>{};

  void addValue({
    required String rawText,
    required String rawValue,
    required String rawNamespace,
  }) {
    final text = rawText.trim();
    final value = rawValue.trim();
    final namespace = rawNamespace.trim();
    if (text.isEmpty || value.isEmpty) return;
    final identity = '$namespace\u0000$text';
    if (!seen.add(identity)) return;
    groupedValues
        .putIfAbsent(namespace, () => <LocalDetailTagDisplayValue>[])
        .add(buildValue(
          rawText: text,
          rawValue: value,
          rawNamespace: namespace,
        ));
  }

  final hasUsableCategorizedTags = source == DownloadType.nhentai &&
      categorizedTags.entries.any(
        (entry) =>
            entry.key.trim().isNotEmpty &&
            entry.value.any((value) => value.trim().isNotEmpty),
      );
  if (hasUsableCategorizedTags) {
    for (final entry in categorizedTags.entries) {
      final namespace = entry.key.trim();
      if (namespace.isEmpty) continue;
      for (final rawValue in entry.value) {
        final value = rawValue.trim();
        addValue(
          rawText: value,
          rawValue: value,
          rawNamespace: namespace,
        );
      }
    }
  } else {
    for (final tag in flatTags) {
      final raw = tag.trim();
      if (raw.isEmpty) continue;
      final separator = raw.indexOf(':');
      final namespace = separator < 0 ? '' : raw.substring(0, separator).trim();
      final value = separator < 0 ? raw : raw.substring(separator + 1).trim();
      addValue(
        rawText: raw,
        rawValue: value,
        rawNamespace: namespace,
      );
    }
  }

  return [
    for (final entry in groupedValues.entries)
      buildGroup(entry.key, entry.value),
  ];
}

/// Stable roles drive the local-detail order without depending on translated
/// labels such as "画师" or "语言".
enum LocalDetailInfoRole {
  id,
  creator,
  uploader,
  downloadTime,
  language,
  pageCount,
  sourceTime,
  normal,
}

const localDetailDownloadTimeLabel = '下载时间';

/// A value keeps its source-search representation separate from its display
/// text, so translated EH/NH tags never change the recommendation query.
class LocalDetailInfoValue {
  const LocalDetailInfoValue({
    required this.displayText,
    this.rawTagSearchValue,
    this.rawValue,
    this.rawNamespace = '',
  });

  final String displayText;

  /// Legacy name retained for callers/tests that still provide the original
  /// flat tag. New source-aware groups should pass [rawValue] instead, because
  /// [rawNamespace] is appended by the local search keyword builder.
  final String? rawTagSearchValue;

  /// Raw source value without its namespace (for example `foo bar`, not
  /// `artist:foo bar`). This is intentionally separate from display text so a
  /// translated label is never sent back to the source search.
  final String? rawValue;
  final String rawNamespace;

  String? get effectiveRawValue => rawValue ?? rawTagSearchValue;
}

/// One titled information group in a local comic detail page.
class LocalDetailInfoGroup {
  const LocalDetailInfoGroup({
    required this.name,
    required this.values,
    this.isTagGroup = false,
    this.localizeName = true,
    this.role = LocalDetailInfoRole.normal,
    this.rawNamespace = '',
  });

  final String name;
  final List<LocalDetailInfoValue> values;
  final bool isTagGroup;
  final bool localizeName;
  final LocalDetailInfoRole role;

  /// The original tag namespace used to derive [role], never a translated
  /// display label. Values retain their individual namespace as well.
  final String rawNamespace;

  bool get hasDisplayValues =>
      values.any((value) => value.displayText.trim().isNotEmpty);
}

/// Classifies an original source namespace. Display labels are intentionally
/// not considered because translations and app locales are mutable.
LocalDetailInfoRole localDetailInfoRoleForNamespace(String rawNamespace) {
  switch (rawNamespace.trim().toLowerCase()) {
    case 'artist':
    case 'artists':
    case '画师':
    case '作者':
      return LocalDetailInfoRole.creator;
    case 'language':
    case 'languages':
    case '语言':
      return LocalDetailInfoRole.language;
    case 'page':
    case 'pages':
    case '页数':
      return LocalDetailInfoRole.pageCount;
    case 'time':
    case '时间':
    case 'uploaded':
      return LocalDetailInfoRole.sourceTime;
    default:
      return LocalDetailInfoRole.normal;
  }
}

bool _isLocalDetailSummaryRole(LocalDetailInfoRole role) {
  return role == LocalDetailInfoRole.pageCount ||
      role == LocalDetailInfoRole.language ||
      role == LocalDetailInfoRole.sourceTime;
}

/// Applies the fixed information hierarchy before rows are rendered.
///
/// The function is intentionally independent of widgets so that ordering and
/// missing-value behavior can be unit tested without a BuildContext.
List<LocalDetailInfoGroup> orderLocalDetailInfoGroups(
  Iterable<LocalDetailInfoGroup> groups,
) {
  final validGroups =
      groups.where((group) => group.hasDisplayValues).toList(growable: false);
  final result = <LocalDetailInfoGroup>[];

  void addRole(LocalDetailInfoRole role) {
    result.addAll(validGroups.where((group) => group.role == role));
  }

  addRole(LocalDetailInfoRole.id);
  addRole(LocalDetailInfoRole.creator);
  addRole(LocalDetailInfoRole.downloadTime);

  for (final group in validGroups) {
    if (group.role == LocalDetailInfoRole.id ||
        group.role == LocalDetailInfoRole.creator ||
        group.role == LocalDetailInfoRole.downloadTime ||
        _isLocalDetailSummaryRole(group.role)) {
      continue;
    }
    result.add(group);
  }

  for (final role in const [
    LocalDetailInfoRole.pageCount,
    LocalDetailInfoRole.language,
    LocalDetailInfoRole.sourceTime,
  ]) {
    addRole(role);
  }
  return result;
}

/// Converts ordered groups into visual rows. Ordinary groups occupy one row;
/// page count, language and source time share a single responsive Wrap row.
List<List<LocalDetailInfoGroup>> buildLocalDetailInfoRows(
  Iterable<LocalDetailInfoGroup> groups,
) {
  final rows = <List<LocalDetailInfoGroup>>[];
  final summaryGroups = <LocalDetailInfoGroup>[];
  for (final group in orderLocalDetailInfoGroups(groups)) {
    if (_isLocalDetailSummaryRole(group.role)) {
      summaryGroups.add(group);
    } else {
      rows.add([group]);
    }
  }
  if (summaryGroups.isNotEmpty) {
    rows.add(summaryGroups);
  }
  return rows;
}

/// Counts the readable local image files recorded for every episode.
///
/// The scanner may surface a root `cover.*` file alongside page files; it is
/// artwork for the detail header rather than a readable page. Repeated paths
/// are also counted once because they refer to the same on-disk image.
int countLocalComicPageFiles(Map<int, Iterable<String>> episodeFiles) {
  final seenPaths = <String>{};
  var count = 0;
  for (final files in episodeFiles.values) {
    for (final file in files) {
      final normalized = file.trim().replaceAll('\\', '/');
      if (normalized.isEmpty ||
          _isLocalDetailCoverPath(normalized) ||
          !seenPaths.add(normalized)) {
        continue;
      }
      count++;
    }
  }
  return count;
}

bool _isLocalDetailCoverPath(String normalizedPath) {
  final fileName = normalizedPath.split('/').last.toLowerCase();
  return RegExp(r'^cover\.(?:jpe?g|png|webp)$').hasMatch(fileName);
}

/// Resolves the displayed local page count without treating online totals as
/// authoritative. EH and legacy NH have the only explicit fallback paths.
int? resolveLocalDetailPageCount({
  required DownloadType source,
  required Map<int, Iterable<String>> episodeFiles,
  int? ehFallbackPageCount,
  Iterable<String> nhSourcePageValues = const <String>[],
}) {
  if (source != DownloadType.jm &&
      source != DownloadType.ehentai &&
      source != DownloadType.nhentai &&
      source != DownloadType.picacg) {
    return null;
  }

  final localPageCount = countLocalComicPageFiles(episodeFiles);
  if (localPageCount > 0) {
    return localPageCount;
  }

  if (source == DownloadType.ehentai &&
      ehFallbackPageCount != null &&
      ehFallbackPageCount > 0) {
    return ehFallbackPageCount;
  }

  if (source == DownloadType.nhentai) {
    for (final value in nhSourcePageValues) {
      final normalized = value.trim();
      if (!RegExp(r'^\d+$').hasMatch(normalized)) {
        continue;
      }
      final parsed = int.tryParse(normalized);
      if (parsed != null && parsed > 0) {
        return parsed;
      }
    }
  }
  return null;
}

String formatLocalDetailDateTime(DateTime time) {
  return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

/// Formats an upstream timestamp while leaving human-readable source strings
/// (for example, "7 months ago") unchanged.
String? formatLocalDetailSourceTime(String? sourceTime) {
  final raw = sourceTime?.trim();
  if (raw == null || raw.isEmpty) {
    return null;
  }
  final parsed = DateTime.tryParse(raw);
  return parsed == null ? raw : formatLocalDetailDateTime(parsed.toLocal());
}

class LocalComicDetailPage extends StatefulWidget {
  final DownloadedItem comic;

  const LocalComicDetailPage({super.key, required this.comic});

  @override
  State<LocalComicDetailPage> createState() => _LocalComicDetailPageState();
}

class _LocalRecommendation {
  const _LocalRecommendation({
    required this.item,
    required this.score,
    required this.reason,
  });

  final DownloadedItem item;
  final double score;
  final String reason;
}

/// 07号计划"更新信息"拉取结果的统一载体。三源 `getComicInfo` 返回类型互不
/// 相同（JmComicInfo/PicacgComicItem/NhentaiComic），用这个小包装收敛成单一
/// 返回类型，方便 `_onUpdateInfo` 用同一套 await/校验流程处理三个分支，
/// 避免为每个来源单独写一套几乎相同的成功/失败判断代码。
class UpdateInfoFetchResult {
  const UpdateInfoFetchResult._({
    this.jmData,
    this.picacgData,
    this.nhentaiData,
    this.ehentaiData,
    this.errorMessage,
  });

  factory UpdateInfoFetchResult.jm(JmComicInfo data) =>
      UpdateInfoFetchResult._(jmData: data);

  factory UpdateInfoFetchResult.picacg(PicacgComicItem data) =>
      UpdateInfoFetchResult._(picacgData: data);

  factory UpdateInfoFetchResult.nhentai(NhentaiComic data) =>
      UpdateInfoFetchResult._(nhentaiData: data);

  factory UpdateInfoFetchResult.ehentai(Gallery data) =>
      UpdateInfoFetchResult._(ehentaiData: data);

  factory UpdateInfoFetchResult.failure(String message) =>
      UpdateInfoFetchResult._(errorMessage: message);

  final JmComicInfo? jmData;
  final PicacgComicItem? picacgData;
  final NhentaiComic? nhentaiData;
  final Gallery? ehentaiData;
  final String? errorMessage;
}

/// 07号计划的核心覆盖契约，提取为顶层纯函数便于不依赖真实网络请求做单元测试：
/// 用 [fetchResult] 里拉到的新元数据整体覆盖 [existing]（旧的具体子类实例），
/// 构造出一个新的具体子类实例。
///
/// 契约（对应计划"覆盖策略"与"覆盖字段范围"）：
/// - 整体覆盖，不做字段级 merge：新值直接替换旧值，即使新值为空也照样替换。
/// - 只覆盖"来源元数据标签"字段（作者/标签/以及各源特有分类），不覆盖
///   ID/时间/页数——因此这里不去处理 comicId/directory/size 之外的结构性字段，
///   调用方（`_applyUpdateInfoOverwrite`）在拿到返回值后还会再顶一层
///   `updated.time = existing.time`，确保"下载时间"语义不被在线的"上传时间"覆盖。
/// - [existing] 的具体类型与 [fetchResult] 携带的数据源类型不匹配时返回 null
///   （理论上不应该发生，因为来源类型在拉取分支时已经按 `comic.type` 分流；
///   保守起见拒绝写入而不是猜测转换）。
DownloadedItem? buildUpdatedDownloadedRecord(
  DownloadedItem existing,
  UpdateInfoFetchResult fetchResult,
) {
  try {
    if (fetchResult.jmData != null && existing is DownloadedJmComic) {
      final data = fetchResult.jmData!;
      return DownloadedJmComic(
        comicId: existing.comicId,
        name: existing.name,
        author: data.authors.join(', '),
        size: existing.size,
        downloadedChapters: existing.downloadedChapters,
        epNames: existing.epNames,
        tagList: data.tags,
        works: data.works,
        actors: data.actors,
      );
    }
    if (fetchResult.picacgData != null && existing is DownloadedComic) {
      final data = fetchResult.picacgData!;
      return DownloadedComic(
        comicId: existing.comicId,
        title: existing.title,
        author: data.author,
        description: existing.description,
        thumbUrl: existing.thumbUrl,
        chapters: existing.chapters,
        downloadedChapters: existing.downloadedChapters,
        size: existing.size,
        tagList: data.tags,
        chineseTeam: data.chineseTeam,
        categories: data.categories,
        sourceTime: data.updatedAt,
      );
    }
    if (fetchResult.nhentaiData != null && existing is NhentaiDownloadedComic) {
      final data = fetchResult.nhentaiData!;
      final flatTags = data.tags.values.expand((v) => v).toList();
      return NhentaiDownloadedComic(
        comicID: existing.comicID,
        title: existing.title,
        size: existing.size,
        cover: existing.cover,
        tagList: flatTags,
        categorizedTags: data.tags,
      );
    }
    if (fetchResult.ehentaiData != null && existing is DownloadedGallery) {
      final data = fetchResult.ehentaiData!;
      return DownloadedGallery(
        galleryTitle: existing.galleryTitle,
        subtitle: existing.subtitle,
        uploader: data.uploader,
        link: existing.link,
        coverPath: existing.coverPath,
        size: existing.size,
        tagList: data.toBrief().tags,
        sourceTime: data.time,
        pageCount: existing.pageCount,
      );
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Builds the raw keyword used when a local-detail information value is
/// searched. EH/NH tags keep their namespace and quote values containing
/// whitespace, while metadata and non-EH/NH values remain plain text.
///
/// [rawValue] is normally the value without a namespace. The legacy flat form
/// (`namespace:value`) is accepted defensively so old callers cannot produce a
/// duplicated `namespace:namespace:value` query.
String buildLocalInfoSearchKeyword({
  required DownloadType source,
  required String displayText,
  String? rawValue,
  String rawNamespace = '',
}) {
  var raw = (rawValue ?? displayText).trim();
  if (raw.isEmpty) return '';
  final namespace = rawNamespace.trim();
  if ((source == DownloadType.ehentai || source == DownloadType.nhentai) &&
      namespace.isNotEmpty) {
    final prefix = '${namespace.toLowerCase()}:';
    if (raw.toLowerCase().startsWith(prefix)) {
      raw = raw.substring(prefix.length).trim();
    }
    if (raw.isEmpty) return '';
    final alreadyQuoted =
        raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"');
    final quoted =
        alreadyQuoted || !RegExp(r'\s').hasMatch(raw) ? raw : '"$raw"';
    return '$namespace:$quoted';
  }
  return raw;
}

class _LocalComicDetailPageState extends State<LocalComicDetailPage> {
  final _scrollController = ScrollController();
  final _remoteDataSource = const RemoteLibraryDataSource();
  final List<DownloadedItem> _localItems = [];
  late DownloadedItem _comic;

  bool _reverseEpsOrder = false;
  bool _showFullEps = false;
  bool _showAppbarTitle = false;
  bool _isDeleteOperationRunning = false;
  int _deleteProgressCurrent = 0;
  int _deleteProgressTotal = 0;
  String _deleteProgressActionLabel = '';
  int _recommendationPage = 0;
  double _bottomPullDistance = 0;

  // 07号计划"更新信息"：网络拉取进行中标记，用于按钮置灰等待反馈。
  bool _isUpdatingInfo = false;

  // 异步解析出的封面路径：本地项首帧可能 episodeFiles 为空、localCoverPath 为 null
  // （图集 / 本地扫描项按需补全），同步的 resolveLocalComicCover 找不到封面会破图。
  // initState 里异步走 LocalLibraryManager().resolveCoverPathForItem（含目录扫描兜底）
  // 补上，与底栏侧栏 _resolveCoverIfNeeded 同思路。
  String? _resolvedCoverPath;

  // 推荐结果缓存：_buildRecommendations() 对全库做正则相似度+排序，开销大
  // （profile 实测单次 ~150ms）。原先放在 build() 里每次 setState 都重算，
  // 导致下滑切标题/进入/退出详情页掉帧。改为缓存，仅当依赖变化时重算。
  // 依赖 = _comic 实例 + 推荐模式设置；_localItems 内容变化时在 _loadLocalItems
  // 里显式置 _recommendationsCache=null 失效。
  List<_LocalRecommendation>? _recommendationsCache;
  DownloadedItem? _recCacheComic;
  String? _recCacheMode;

  static const _recommendationPageSize = 10;
  late final String _untranslatedTagOperationId =
      'local-detail-${const Uuid().v4()}';

  @override
  void initState() {
    super.initState();
    _comic = widget.comic;
    unawaited(_observeUntranslatedTags(_comic));
    _scrollController.addListener(_handleScroll);
    _loadRemoteDetailIfNeeded();
    _loadLocalItems();
    _resolveCoverIfNeeded();
    unawaited(_refreshTagTranslationsWhenReady());
  }

  Future<void> _observeUntranslatedTags(DownloadedItem item) async {
    final concrete = restoreConcreteDownloadedRecord(item) ?? item;
    if (concrete.type != DownloadType.ehentai &&
        concrete.type != DownloadType.nhentai) {
      return;
    }
    try {
      if (!tagTranslationsReady) {
        try {
          await loadTagTranslations();
        } catch (_) {
          // The collector keeps a bounded observation queue until retry.
        }
      }
      final categorized = concrete is NhentaiDownloadedComic
          ? concrete.categorizedTags
          : const <String, List<String>>{};
      final comicId =
          concrete is NhentaiDownloadedComic ? concrete.comicID : concrete.id;
      await UntranslatedTagCoordinator.instance.observe(
        UntranslatedTagObservation(
          source: concrete.type == DownloadType.ehentai ? 'ehentai' : 'nhentai',
          comicId: comicId,
          operationId: _untranslatedTagOperationId,
          context: 'local-detail',
          flat: concrete.tags,
          categorized: categorized,
        ),
      );
    } catch (_) {
      // Tag collection must never block or break local detail loading.
    }
  }

  /// 启动阶段的标签表是异步预热的。详情页可能先于它完成构建，因此在完成后
  /// 只重建当前页面一次，避免用户必须退出再进入才能看到 EH/NH 中文标签。
  Future<void> _refreshTagTranslationsWhenReady() async {
    if (!shouldTranslateLocalDetailTags(
      _comic.type,
      App.locale.languageCode,
    )) {
      return;
    }
    try {
      await loadTagTranslations();
    } catch (_) {
      return;
    }
    await UntranslatedTagCoordinator.instance.flushPending();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _resolveCoverIfNeeded() async {
    final comic = _comic;
    if (comic is! LocalLibraryComicItem) {
      return;
    }
    // 同步路径已能拿到封面就不必异步解析。
    final cached = comic.localCoverPath?.trim();
    if (cached != null &&
        cached.isNotEmpty &&
        cached != LocalLibraryManager.noCoverSentinel &&
        File(cached).existsSync()) {
      return;
    }
    final path = await LocalLibraryManager().resolveCoverPathForItem(comic);
    if (!mounted || path == null || path.trim().isEmpty) {
      return;
    }
    setState(() {
      _resolvedCoverPath = path.trim();
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    final showTitle = _scrollController.position.pixels > 136;
    if (showTitle != _showAppbarTitle) {
      setState(() {
        _showAppbarTitle = showTitle;
      });
    }
  }

  Future<void> _loadLocalItems() async {
    List<DownloadedItem> items;
    final current = _comic;
    if (current is RemoteLibraryComicItem) {
      try {
        final rootId = current.rootId.trim();
        items = rootId.isNotEmpty
            ? await _remoteDataSource.fetchItemsForRoot(rootId)
            : await _remoteDataSource.fetchItems();
      } catch (_) {
        items = const <DownloadedItem>[];
      }
    } else {
      items = await LocalLibraryManager().getAll();
    }
    if (!mounted) return;
    setState(() {
      _localItems
        ..clear()
        ..addAll(items);
      _recommendationsCache = null; // _localItems 内容已变，失效推荐缓存
    });
  }

  Future<void> _loadRemoteDetailIfNeeded() async {
    final current = _comic;
    if (current is! RemoteLibraryComicItem || current.hasUsableDetailPayload) {
      return;
    }
    try {
      final detail = await current.client.fetchItemDetail(current.id);
      if (!mounted) return;
      setState(() {
        _comic = detail;
      });
    } catch (_) {}
  }

  String get _sourceLabel {
    final label = _comic.sourceDisplayName.trim();
    if (label.isNotEmpty) return label.tl;
    return downloadTypeDisplayName(_comic.type).tl;
  }

  bool get _isAlbum {
    final comic = _comic;
    if (comic is LocalLibraryComicItem) return comic.isAlbum;
    return comic.sourceDisplayName == '图集';
  }

  bool get _canDeleteComic {
    final comic = _comic;
    if (comic is RemoteLibraryRootItem) {
      return false;
    }
    if (comic is RemoteLibraryComicItem) {
      return true;
    }
    if (comic is LocalLibraryComicItem) {
      return comic.fileSystemPath?.trim().isNotEmpty == true;
    }
    return comic.canDelete;
  }

  String _formatSize(double? size) {
    if (size == null) return '未知'.tl;
    if (size > 1024) return '${(size / 1024).toStringAsFixed(1)} GB';
    return '${size.toStringAsFixed(1)} MB';
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '';
    return formatLocalDetailDateTime(time);
  }

  String _recommendationAuthor(DownloadedItem item) {
    final direct = resolveDownloadedAuthors(item).join(', ').trim();
    if (direct.isNotEmpty) {
      return direct;
    }
    try {
      final json = item.toJson();
      for (final key in const ['subtitle', 'subTitle', 'author']) {
        final value = json[key]?.toString().trim();
        if (value != null && value.isNotEmpty) {
          return value;
        }
      }
    } catch (_) {}
    return '';
  }

  List<String> _recommendationTags(DownloadedItem item) {
    if (item.tags.isNotEmpty) {
      return item.tags;
    }
    try {
      final json = item.toJson();
      for (final key in const ['tags', 'tagList', 'metadataTags']) {
        final raw = json[key];
        if (raw is List) {
          final values = raw
              .map((entry) => entry.toString().trim())
              .where((entry) => entry.isNotEmpty)
              .toList(growable: false);
          if (values.isNotEmpty) {
            return values;
          }
        }
      }
    } catch (_) {}
    return const <String>[];
  }

  List<String> _historyTargetsFor(DownloadedItem comic) {
    final targets = <String>{comic.id};
    try {
      final json = comic.toJson();
      for (final key in const [
        'comicId',
        'id',
        'itemId',
        'link',
        'favoriteTarget',
      ]) {
        final value = json[key]?.toString().trim();
        if (value != null && value.isNotEmpty) targets.add(value);
      }
    } catch (_) {}
    if (comic is LocalLibraryComicItem) {
      final originalId = comic.originalId.trim();
      if (originalId.isNotEmpty) targets.add(originalId);
      final favoriteTarget = comic.favoriteTarget?.trim();
      if (favoriteTarget != null && favoriteTarget.isNotEmpty) {
        targets.add(favoriteTarget);
      }
      for (final alias in comic.aliases) {
        final value = alias.trim();
        if (value.isNotEmpty) targets.add(value);
      }
    }
    return targets.toList();
  }

  dynamic _historyFor(DownloadedItem comic) {
    for (final target in _historyTargetsFor(comic)) {
      final history = appdata.history.find(target);
      if (history != null) return history;
    }
    return null;
  }

  Future<void> _onRead({int? ep, int? page}) async {
    final unlocked = await _ensureRemoteArchiveUnlocked();
    if (!unlocked) {
      return;
    }
    await ensureHistoryBeforeRead(
      _comic,
      legacyTargets: _historyTargetsFor(_comic),
    );
    if (!mounted) {
      return;
    }
    await App.openReader(
      () => _comic.createReadingPage(ep: ep, page: page),
      context: context,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (mounted) {
      setState(() {});
    }
  }

  Future<bool> _ensureRemoteArchiveUnlocked() async {
    final comic = _comic;
    if (comic is! RemoteLibraryComicItem || !comic.needsArchivePassword) {
      return true;
    }
    final result = await showArchivePasswordDialog(
      context: context,
      archivePath: comic.remotePath,
      archiveFileName: comic.name,
      format: comic.archiveFormat,
      allowAddToDefaults: false,
      onVerify: (password) => comic.client.unlockArchive(comic.id, password),
    );
    if (result == null) {
      return false;
    }
    comic.archivePasswordMatched = true;
    try {
      final detail = await comic.client.fetchItemDetail(comic.id);
      if (mounted) {
        setState(() {
          _comic = detail.copyWith(archivePasswordMatched: true);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _comic = comic.copyWith(archivePasswordMatched: true);
        });
      }
    }
    return true;
  }

  Future<void> _onForgetArchivePassword(LocalLibraryComicItem item) async {
    final path = item.fileSystemPath;
    if (path == null || path.isEmpty) return;
    ArchivePasswordStore.instance.forget(path);
    ArchiveMemoryCache.instance.evictAllForArchive(path);
    item.markArchiveLocked();
    if (mounted) setState(() {});
  }

  Future<void> _onDelete() async {
    if (!_canDeleteComic) {
      _showMessage('当前项目不支持在此删除'.tl);
      return;
    }
    final texts = buildDeleteActionTexts(
      itemName: _comic.name,
      itemLabel: _comic.sourceDisplayName == '图集' ? '图集' : '漫画',
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(texts.title.tl),
        content: Text(texts.content.tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(texts.confirmLabel.tl),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final error = await _runDeleteOperation();
      if (error != null) {
        _showMessage(error);
        return;
      }
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<String?> _runDeleteOperation() async {
    if (_isDeleteOperationRunning) {
      return null;
    }
    setState(() {
      _isDeleteOperationRunning = true;
      _deleteProgressCurrent = 1;
      _deleteProgressTotal = 1;
      _deleteProgressActionLabel =
          TrashManager.instance.useTrashByDefault ? '正在放进回收站' : '正在删除';
    });
    App.beginNavigationLock();
    App.temporaryDisablePopGesture = true;
    String? errorText;
    try {
      final comic = _comic;
      if (comic is RemoteLibraryComicItem) {
        await TrashManager.instance.deleteRemoteItems([comic]);
      } else {
        final result = await TrashManager.instance.deleteItem(comic);
        if (!result.ok) {
          errorText = deleteFailureMessage(result.error).tl;
        }
      }
    } catch (e) {
      final message = e is StateError
          ? e.message.toString()
          : e.toString().replaceFirst('Exception: ', '');
      if (message.contains(deleteFailurePermissionDenied) ||
          message.toLowerCase().contains('permission denied')) {
        errorText = deleteFailureMessage(deleteFailurePermissionDenied).tl;
      } else if (message.contains(deleteFailureLocalPathNotFound)) {
        errorText = deleteFailureMessage(deleteFailureLocalPathNotFound).tl;
      } else {
        errorText = message.replaceFirst('Bad state: ', '');
      }
    } finally {
      App.temporaryDisablePopGesture = false;
      App.endNavigationLock();
      if (mounted) {
        setState(() {
          _isDeleteOperationRunning = false;
          _deleteProgressCurrent = 0;
          _deleteProgressTotal = 0;
          _deleteProgressActionLabel = '';
        });
      } else {
        _isDeleteOperationRunning = false;
        _deleteProgressCurrent = 0;
        _deleteProgressTotal = 0;
        _deleteProgressActionLabel = '';
      }
    }
    return errorText;
  }

  Future<void> _onDeleteEpisode(int ep) async {
    if (!_comic.canDelete) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除章节'.tl),
        content: Text('确定要删除"${_comic.eps[ep]}"吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除'.tl),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final error = await DownloadManager().deleteEpisode(_comic, ep);
      if (error != null) _showMessage(error);
      if (mounted) setState(() {});
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Widget _buildDeleteProgressOverlay() {
    final theme = Theme.of(context);
    final progressText = '$_deleteProgressCurrent/$_deleteProgressTotal';
    final isDesktop = App.isDesktop;
    final barrierColor = Color.alphaBlend(
      theme.colorScheme.primary.withValues(alpha: 0.06),
      Colors.white.withValues(alpha: 0.76),
    );
    final panelColor = Color.alphaBlend(
      theme.colorScheme.primary.withValues(alpha: 0.04),
      theme.colorScheme.surface.withValues(alpha: 0.97),
    );
    return Stack(
      children: [
        ModalBarrier(
          dismissible: false,
          color: barrierColor,
        ),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: isDesktop ? 440 : 300,
              minWidth: isDesktop ? 340 : 260,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: panelColor,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.shadow.withValues(alpha: 0.08),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
                border: Border.all(
                  color:
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 22,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                        strokeWidth: 3.2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      isDesktop
                          ? '$_deleteProgressActionLabel $progressText'
                          : _deleteProgressActionLabel,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    if (!isDesktop) ...[
                      const SizedBox(height: 6),
                      Text(
                        progressText,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      '请不要退出，强制退出可能导致操作异常'.tl,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _copyText(String text) {
    Clipboard.setData(ClipboardData(text: text));
    _showMessage('已复制'.tl);
  }

  String? _getDescription() {
    try {
      final json = _comic.toJson();
      final candidates = [
        json['description'],
        json['comicItem'] is Map ? json['comicItem']['description'] : null,
        json['intro'],
        json['introduction'],
      ];
      for (final value in candidates) {
        final text = value?.toString().trim();
        if (text != null && text.isNotEmpty) return text;
      }
    } catch (_) {}
    return null;
  }

  String _displayIdFor(DownloadedItem comic) {
    final isAlbum = comic is LocalLibraryComicItem
        ? comic.isAlbum
        : comic.sourceDisplayName == '图集';
    if (isAlbum) {
      return comic.name;
    }
    if (comic is LocalLibraryComicItem) {
      final originalId = comic.originalId.trim();
      if (originalId.isNotEmpty) {
        return originalId;
      }
    }
    final json = comic.toJson();
    for (final key in const ['displayId', 'comicId', 'id', 'itemId']) {
      final value = json[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    final comicItem = json['comicItem'];
    if (comicItem is Map) {
      for (final key in const ['displayId', 'comicId', 'id']) {
        final value = comicItem[key]?.toString().trim();
        if (value != null && value.isNotEmpty) {
          return value;
        }
      }
    }
    return comic.id;
  }

  // 路径不再在详情信息区显示（按用户要求隐藏），方法保留待恢复。
  // ignore: unused_element
  String? _displayPathForRemoved(DownloadedItem comic) {
    String? fullPath;
    final fileSystemPath = comic.fileSystemPath?.trim();
    if (fileSystemPath != null && fileSystemPath.isNotEmpty) {
      fullPath = fileSystemPath;
    } else {
      final directory = comic.directory?.trim();
      if (directory != null && directory.isNotEmpty) {
        final rootPath =
            (DownloadManager().path ?? appdata.settings[22]).trim();
        fullPath = rootPath.isNotEmpty
            ? '$rootPath${Platform.pathSeparator}$directory'
            : directory;
      }
    }
    if (fullPath == null || fullPath.isEmpty) {
      return null;
    }

    final normalized = fullPath.replaceAll('\\', '/');
    final trimmed = normalized.endsWith('/') && normalized.length > 1
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final lastSeparator = trimmed.lastIndexOf('/');
    if (lastSeparator <= 0) {
      return trimmed.replaceAll('/', Platform.pathSeparator);
    }
    return trimmed
        .substring(0, lastSeparator)
        .replaceAll('/', Platform.pathSeparator);
  }

  void _showNextRecommendationPage(int total) {
    if (total <= _recommendationPageSize) return;
    setState(() {
      final pages = (total / _recommendationPageSize).ceil();
      _recommendationPage = (_recommendationPage + 1) % pages;
    });
  }

  List<LocalDetailInfoGroup> _buildInfoGroups() {
    final comic = _comic;
    final groups = <LocalDetailInfoGroup>[];

    void add(
      String key,
      Iterable<String?> values, {
      LocalDetailInfoRole role = LocalDetailInfoRole.normal,
      bool isTagGroup = false,
      bool localizeName = true,
      String rawNamespace = '',
    }) {
      final normalized = values
          .whereType<String>()
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList();
      if (normalized.isEmpty) return;
      groups.add(
        LocalDetailInfoGroup(
          name: key,
          role: role,
          isTagGroup: isTagGroup,
          localizeName: localizeName,
          rawNamespace: rawNamespace,
          values: [
            for (final value in normalized)
              LocalDetailInfoValue(displayText: value),
          ],
        ),
      );
    }

    final restored = restoreConcreteDownloadedRecord(comic);
    final concrete =
        restored ?? (comic is LocalLibraryComicItem ? null : comic);
    final resolvedAuthors = concrete == null
        ? (comic is LocalLibraryComicItem
            ? resolveDownloadedAuthorsFromRecord(
                comic.originalId,
                comic.sourceRowJson ?? '',
                fallback: comic,
              )
            : resolveDownloadedAuthors(comic))
        : resolveDownloadedAuthors(concrete);

    void addTagGroup(
      LocalDetailTagDisplayGroup tagGroup,
      LocalDetailInfoRole role,
    ) {
      groups.add(
        LocalDetailInfoGroup(
          name: tagGroup.displayName,
          role: role,
          isTagGroup: true,
          // 无 namespace 时仍是原有通用“标签”标题，交给应用语言包；有
          // namespace 的分类名已由在线权威翻译函数决定，不再二次翻译。
          localizeName: tagGroup.rawNamespace.isEmpty,
          rawNamespace: tagGroup.rawNamespace,
          values: [
            for (final value in tagGroup.values)
              LocalDetailInfoValue(
                displayText: value.displayText,
                // Keep namespace and value separate. Recombining a complete
                // `namespace:value` string with rawNamespace would produce
                // `artist:artist:value` for EH/NH local searches.
                rawValue: value.rawValue,
                rawNamespace: value.rawNamespace,
              ),
          ],
        ),
      );
    }

    void addMergedTagGroups(
      List<LocalDetailTagDisplayGroup> tagGroups,
      LocalDetailInfoRole role,
    ) {
      if (tagGroups.isEmpty) return;
      final values = <LocalDetailInfoValue>[];
      final seen = <String>{};
      for (final tagGroup in tagGroups) {
        for (final value in tagGroup.values) {
          final identity = '${value.rawNamespace}\u0000${value.rawText}';
          if (!seen.add(identity)) continue;
          values.add(LocalDetailInfoValue(
            displayText: value.displayText,
            rawValue: value.rawValue,
            rawNamespace: value.rawNamespace,
          ));
        }
      }
      if (values.isEmpty) return;
      final firstGroup = tagGroups.first;
      groups.add(LocalDetailInfoGroup(
        name: firstGroup.displayName,
        role: role,
        isTagGroup: true,
        localizeName: firstGroup.rawNamespace.isEmpty,
        rawNamespace: firstGroup.rawNamespace,
        values: values,
      ));
    }

    add('ID', [_displayIdFor(comic)], role: LocalDetailInfoRole.id);
    if (comic.type == DownloadType.jm || comic.type == DownloadType.picacg) {
      add('作者', [resolvedAuthors.join(', ')],
          role: LocalDetailInfoRole.creator);
    }
    add(
      localDetailDownloadTimeLabel,
      [_formatTime(comic.time)],
      role: LocalDetailInfoRole.downloadTime,
    );
    if (comic.type == DownloadType.ehentai) {
      final uploader = concrete is DownloadedGallery ? concrete.uploader : '';
      add('上传者', [uploader], role: LocalDetailInfoRole.uploader);
    }

    if (comic is LocalLibraryComicItem && comic.isArchiveItem) {
      add('格式', [comic.archiveFormatDisplay]);
      final path = comic.fileSystemPath;
      if (path != null && path.isNotEmpty) {
        try {
          final bytes = File(path).statSync().size;
          final mb = bytes / (1024 * 1024);
          add('文件大小', ['${mb.toStringAsFixed(1)} MB']);
        } catch (_) {}
      }
      final chapterCount = comic.eps.length;
      if (chapterCount > 0) {
        add('章节数', ['$chapterCount']);
      }
    }

    final concreteTags = concrete?.tags ?? const <String>[];
    final flatTags = concreteTags.isNotEmpty ? concreteTags : comic.tags;
    final categorizedTags = concrete is NhentaiDownloadedComic
        ? concrete.categorizedTags
        : const <String, List<String>>{};
    final tagGroups = buildLocalDetailTagDisplayGroups(
      source: comic.type,
      flatTags: flatTags,
      categorizedTags: categorizedTags,
      languageCode: App.locale.languageCode,
    );
    final languageTagGroups = <LocalDetailTagDisplayGroup>[];
    final sourceTimeTagValues = <String>[];
    final nhSourcePageValues = <String>[];
    for (final tagGroup in tagGroups) {
      final role = localDetailInfoRoleForNamespace(tagGroup.rawNamespace);
      switch (role) {
        case LocalDetailInfoRole.creator:
          addTagGroup(tagGroup, role);
          break;
        case LocalDetailInfoRole.language:
          languageTagGroups.add(tagGroup);
          break;
        case LocalDetailInfoRole.sourceTime:
          sourceTimeTagValues.addAll(
            tagGroup.values.map((value) => value.rawValue),
          );
          break;
        case LocalDetailInfoRole.pageCount:
          nhSourcePageValues.addAll(
            tagGroup.values.map((value) => value.rawValue),
          );
          break;
        default:
          addTagGroup(tagGroup, role);
          break;
      }
    }
    _appendConcreteInfoGroups(concrete, (key, values) => add(key, values));

    final episodeFiles = comic is LocalLibraryComicItem
        ? comic.episodeFiles
        : const <int, Iterable<String>>{};
    final pageCount = resolveLocalDetailPageCount(
      source: comic.type,
      episodeFiles: episodeFiles,
      ehFallbackPageCount:
          concrete is DownloadedGallery ? concrete.pageCount : null,
      nhSourcePageValues: nhSourcePageValues,
    );
    if (pageCount != null) {
      add('页数', ['$pageCount'], role: LocalDetailInfoRole.pageCount);
    }
    addMergedTagGroups(languageTagGroups, LocalDetailInfoRole.language);

    final concreteSourceTime = concrete is DownloadedGallery
        ? concrete.sourceTime
        : concrete is DownloadedComic
            ? concrete.sourceTime
            : '';
    final sourceTimeValues = concreteSourceTime.trim().isNotEmpty
        ? <String>[concreteSourceTime]
        : sourceTimeTagValues;
    add(
      '时间',
      sourceTimeValues.map(formatLocalDetailSourceTime),
      role: LocalDetailInfoRole.sourceTime,
    );
    return orderLocalDetailInfoGroups(groups);
  }

  // 07号计划：还原具体子类实例后追加 JM/Picacg 的来源元数据分组。NH 分类桶
  // 已在来源感知标签显示模型中统一处理，以免和 flat 标签重复。
  void _appendConcreteInfoGroups(
    DownloadedItem? concrete,
    void Function(String key, Iterable<String?> values) add,
  ) {
    if (concrete == null) {
      return;
    }
    if (concrete is DownloadedJmComic) {
      add('作品', concrete.works);
      add('演员', concrete.actors);
    } else if (concrete is DownloadedComic) {
      add('汉化组', [concrete.chineseTeam]);
      add('分类', concrete.categories);
    }
  }

  List<_LocalRecommendation> _buildRecommendations() {
    final mode = normalizeLocalDetailRecommendationMode(
      appdata.settings[localDetailRecommendationSettingIndex],
    );
    // 命中缓存：_comic 实例与推荐模式未变、且未被显式失效（_localItems 变化时
    // 在 _loadLocalItems 里置 null）时直接复用。
    if (_recommendationsCache != null &&
        identical(_recCacheComic, _comic) &&
        _recCacheMode == mode) {
      return _recommendationsCache!;
    }
    final result = _computeRecommendations(mode);
    _recommendationsCache = result;
    _recCacheComic = _comic;
    _recCacheMode = mode;
    return result;
  }

  List<_LocalRecommendation> _computeRecommendations(String mode) {
    if (mode == '5') return const [];

    final current = _comic;
    final currentName = current.name;
    final currentAuthor = _recommendationAuthor(current).trim().toLowerCase();
    final currentTags = _recommendationTags(current)
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();
    final currentTopics = _nameTopics(currentName);
    final albumOnly = _isAlbum;

    final recommendations = <_LocalRecommendation>[];
    for (final item in _localItems) {
      final sameId = item.id == current.id;
      final sameName = item.name == current.name;
      final sameLocalOriginalId = item is LocalLibraryComicItem &&
          (item.originalId == current.id || item.originalId == current.name);
      if (sameId || sameName || sameLocalOriginalId) {
        continue;
      }

      final nameScore = _nameSimilarity(currentName, item.name);
      final itemAuthor = _recommendationAuthor(item).trim().toLowerCase();
      final sameAuthor =
          currentAuthor.isNotEmpty && currentAuthor == itemAuthor;
      final itemTags = _recommendationTags(item)
          .map((e) => e.trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .toSet();
      final tagMatches = currentTags.intersection(itemTags).length;
      final topicMatches =
          currentTopics.intersection(_nameTopics(item.name)).length;
      final hasTopic = topicMatches > 0 || nameScore >= 0.36;

      double score;
      String reason;
      if (albumOnly) {
        score = nameScore * 1000;
        reason = '名称相似'.tl;
        if (score <= 0) continue;
      } else {
        final strongName = nameScore >= 0.62;
        final authorAndTopic = sameAuthor && hasTopic;
        final sameTopic = hasTopic;
        final hasTags = tagMatches > 0;

        switch (mode) {
          case '1':
            if (nameScore <= 0) continue;
            score = nameScore * 1000 + tagMatches * 20 + (sameAuthor ? 80 : 0);
            reason = '名称相似'.tl;
            break;
          case '2':
            if (!authorAndTopic) continue;
            score =
                3000 + topicMatches * 80 + nameScore * 300 + tagMatches * 20;
            reason = '同作者 + 同题材'.tl;
            break;
          case '3':
            if (!sameTopic) continue;
            score = 2000 + topicMatches * 90 + nameScore * 400;
            reason = '同题材'.tl;
            break;
          case '4':
            if (!hasTags) continue;
            score = 1000 +
                tagMatches * 120 +
                nameScore * 200 +
                (sameAuthor ? 60 : 0);
            reason = '同标签'.tl;
            break;
          case '0':
          default:
            if (strongName) {
              score = 4000 + nameScore * 1000 + tagMatches * 20;
              reason = '名称高度相似'.tl;
            } else if (authorAndTopic) {
              score =
                  3000 + topicMatches * 100 + nameScore * 400 + tagMatches * 20;
              reason = '同作者 + 同题材'.tl;
            } else if (sameTopic) {
              score = 2000 + topicMatches * 100 + nameScore * 400;
              reason = '同题材'.tl;
            } else if (hasTags) {
              score = 1000 + tagMatches * 120 + nameScore * 200;
              reason = '同标签'.tl;
            } else {
              continue;
            }
            break;
        }
      }

      recommendations
          .add(_LocalRecommendation(item: item, score: score, reason: reason));
    }

    recommendations.sort((a, b) {
      final score = b.score.compareTo(a.score);
      if (score != 0) return score;
      final at = a.item.time ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bt = b.item.time ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bt.compareTo(at);
    });
    return recommendations;
  }

  Set<String> _nameTopics(String value) {
    final normalized = value
        .toLowerCase()
        .replaceAll(RegExp(r'[\[\]【】()（）「」『』<>《》!！?？:：,，.。_\-]+'), ' ');
    final matches = RegExp(r'[a-z0-9]{3,}|[\u4e00-\u9fa5]{2,}|[ぁ-んァ-ンー]{2,}')
        .allMatches(normalized)
        .map((e) => e.group(0)!)
        .where((e) => e.length >= 2)
        .toSet();
    return matches;
  }

  double _nameSimilarity(String a, String b) {
    final left = _normalizeName(a);
    final right = _normalizeName(b);
    if (left.isEmpty || right.isEmpty) return 0;
    if (left == right) return 1;
    if (left.contains(right) || right.contains(left)) {
      final minLen = math.min(left.length, right.length);
      final maxLen = math.max(left.length, right.length);
      return 0.72 + (minLen / maxLen) * 0.18;
    }
    final leftBigrams = _bigrams(left);
    final rightBigrams = _bigrams(right);
    if (leftBigrams.isEmpty || rightBigrams.isEmpty) return 0;
    final intersection = leftBigrams.intersection(rightBigrams).length;
    return (2 * intersection) / (leftBigrams.length + rightBigrams.length);
  }

  String _normalizeName(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'\[[^\]]*\]|【[^】]*】|\([^)]*\)|（[^）]*）'), '')
        .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fa5ぁ-んァ-ンー]+'), '');
  }

  Set<String> _bigrams(String value) {
    if (value.length < 2) return {value};
    return {
      for (int i = 0; i < value.length - 1; i++) value.substring(i, i + 2),
    };
  }

  bool _handleRecommendationOverscroll(
      OverscrollNotification notification, int total) {
    if (notification.dragDetails == null ||
        notification.overscroll <= 0 ||
        total <= _recommendationPageSize) {
      return false;
    }
    final metrics = notification.metrics;
    if (metrics.pixels < metrics.maxScrollExtent - 24) return false;
    _bottomPullDistance += notification.overscroll;
    if (_bottomPullDistance >= 120) {
      _showNextRecommendationPage(total);
      _bottomPullDistance = 0;
    }
    return false;
  }

  Future<void> _showRecommendationSettings() async {
    var mode = normalizeLocalDetailRecommendationMode(
      appdata.settings[localDetailRecommendationSettingIndex],
    );
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18)),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
                        child: Row(
                          children: [
                            Text(
                              '相关推荐设置'.tl,
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w600),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () => Navigator.pop(dialogContext),
                            ),
                          ],
                        ),
                      ),
                      for (final entry in const <MapEntry<String, String>>[
                        MapEntry('0', '智能推荐'),
                        MapEntry('1', '名称相似优先'),
                        MapEntry('2', '同作者 + 同题材'),
                        MapEntry('3', '同题材'),
                        MapEntry('4', '同标签最多'),
                        MapEntry('5', '不推荐'),
                      ])
                        ListTile(
                          leading: Icon(
                            mode == entry.key
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                          ),
                          title: Text(entry.value.tl),
                          onTap: () async {
                            setDialogState(() => mode = entry.key);
                            appdata.settings[
                                    localDetailRecommendationSettingIndex] =
                                entry.key;
                            await appdata.updateSettings();
                            if (mounted) {
                              setState(() => _recommendationPage = 0);
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildCover(BuildContext context, double width, double height) {
    final legacyTargets = <String>{
      ..._historyTargetsFor(_comic),
      if (_comic is RemoteLibraryComicItem)
        ...(_comic as RemoteLibraryComicItem).candidateValues,
    };
    final cover = resolveLocalComicCover(
      _comic,
      legacyTargets: legacyTargets,
    );
    // 同步解析不到（图集/本地扫描项首帧）时，回退到异步补出的封面路径。
    final resolvedExtra = _resolvedCoverPath?.trim();
    final effectiveCoverPath = cover.path.isNotEmpty
        ? cover.path
        : (resolvedExtra != null && resolvedExtra.isNotEmpty
            ? resolvedExtra
            : '');
    // 本地项一律走 privileged-aware 的 imageProviderForLocalPath：root/shizuku 模式
    // 无 MANAGE_EXTERNAL_STORAGE，裸 Image.file / existsSync 读外部路径会失败破图，
    // 该 provider 在 dart:io 读不到时回退特权通道补字节。existsSync 同样不可靠
    // （root/shizuku 下对外部路径恒 false），故不再用它判定 hasLocalCover。
    final remoteProvider = _comic is RemoteLibraryComicItem
        ? (_comic as RemoteLibraryComicItem).coverImageProvider
        : _comic is RemoteLibraryRootItem
            ? (_comic as RemoteLibraryRootItem).coverImageProvider
            : null;
    final ImageProvider<Object>? coverProvider = remoteProvider ??
        (effectiveCoverPath.isNotEmpty
            ? LocalLibraryManager()
                .imageProviderForLocalPath(effectiveCoverPath)
            : _comic is LocalLibraryComicItem
                ? LocalLibraryManager()
                    .coverImageProviderForItem(_comic as LocalLibraryComicItem)
                : null);
    final heroTag = 'local-cover-${_comic.id}';
    return GestureDetector(
      onTap: coverProvider != null
          ? () => _showCoverPreviewProvider(coverProvider)
          : null,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: coverProvider != null
            ? Hero(
                tag: heroTag,
                child: Image(
                  image: coverProvider,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  isAntiAlias: true,
                  errorBuilder: (_, __, ___) => _placeholderCover(),
                ),
              )
            : _placeholderCover(),
      ),
    );
  }

  Widget _placeholderCover() {
    return const Center(child: Icon(Icons.image_not_supported, size: 36));
  }

  void _showCoverPreviewProvider(ImageProvider<Object> coverProvider) {
    App.globalTo(
      () => _CoverPreviewPage(
        imageProvider: coverProvider,
        heroTag: 'local-cover-${_comic.id}',
      ),
    );
  }

  Widget _sectionHeader(String title, {Widget? trailing}) {
    return SliverToBoxAdapter(
      child: Column(
        children: [
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                Text(
                  title.tl,
                  style: const TextStyle(
                      fontWeight: FontWeight.w500, fontSize: 18),
                ),
                const Spacer(),
                if (trailing != null) trailing,
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openRecommendationSearch(String keyword) {
    final normalized = keyword.trim();
    if (normalized.isEmpty) {
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LocalSearchPage(initialKeyword: normalized),
      ),
    );
  }

  String _localInfoSearchKeyword({
    required String displayText,
    String? rawSearchValue,
    String rawNamespace = '',
  }) {
    return buildLocalInfoSearchKeyword(
      source: _comic.type,
      displayText: displayText,
      rawValue: rawSearchValue,
      rawNamespace: rawNamespace,
    );
  }

  bool _isPlaceholderInfoValue(String value) {
    final normalized = value.trim();
    return normalized.isEmpty || normalized == '未知'.tl;
  }

  Widget _infoCard(
    String text, {
    bool title = false,
    String? rawSearchValue,
    String rawNamespace = '',
  }) {
    final isPlaceholder = _isPlaceholderInfoValue(text);
    final displayText = text.trim().isEmpty ? '未知'.tl : text;
    final colorScheme = Theme.of(context).colorScheme;
    final card = Card(
      margin: EdgeInsets.zero,
      color: title
          ? colorScheme.primaryContainer.withAlpha(160)
          : ElevationOverlay.applySurfaceTint(
              colorScheme.surface,
              colorScheme.surfaceTint,
              3,
            ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: Text(displayText, style: const TextStyle(fontSize: 13)),
      ),
    );
    if (title || isPlaceholder) {
      return Container(
        margin: const EdgeInsets.fromLTRB(4, 4, 4, 4),
        child: card,
      );
    }
    final keyword = _localInfoSearchKeyword(
      displayText: displayText,
      rawSearchValue: rawSearchValue,
      rawNamespace: rawNamespace,
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      child: InfoValueAction(
        data: InfoValueData(
          displayText: displayText,
          rawSearchValue: rawSearchValue ?? displayText,
          rawNamespace: rawNamespace,
        ),
        onSearch:
            keyword.isEmpty ? null : () => _openRecommendationSearch(keyword),
        child: card,
      ),
    );
  }

  void _onVisitOnline() {
    final comic = _comic;
    final rawId = resolveOnlineRawId(comic);
    if (comic.type == DownloadType.jm) {
      final numericId = extractJmNumericId(rawId);
      if (numericId == null) {
        LogManager.addLog(
          LogLevel.warning,
          'LocalComicDetailPage',
          '_onVisitOnline: invalid JM numericId, rawId="$rawId"',
        );
        _showMessage('该本地记录缺少有效的在线ID，无法查看在线详情'.tl);
        return;
      }
      App.pushInner(() => JmComicPageV2(numericId));
    } else if (comic.type == DownloadType.picacg) {
      if (rawId.isEmpty) {
        LogManager.addLog(
          LogLevel.warning,
          'LocalComicDetailPage',
          '_onVisitOnline: empty picacg rawId, comic.id="${comic.id}"',
        );
        _showMessage('该本地记录缺少有效的在线ID，无法查看在线详情'.tl);
        return;
      }
      App.pushInner(() => PicacgComicPageV2(rawId));
    } else if (comic.type == DownloadType.nhentai) {
      final numericId = extractNhentaiNumericId(rawId);
      if (numericId == null) {
        LogManager.addLog(
          LogLevel.warning,
          'LocalComicDetailPage',
          '_onVisitOnline: invalid nhentai numericId, rawId="$rawId"',
        );
        _showMessage('该本地记录缺少有效的在线ID，无法查看在线详情'.tl);
        return;
      }
      App.pushInner(() => NhentaiComicPageV2(numericId));
    } else if (comic.type == DownloadType.ehentai) {
      final link = resolveEhGalleryLink(comic);
      if (link == null) {
        LogManager.addLog(
          LogLevel.warning,
          'LocalComicDetailPage',
          '_onVisitOnline: missing or invalid EH gallery link',
        );
        _showMessage('该本地记录缺少有效的在线链接，无法查看在线详情'.tl);
        return;
      }
      App.pushInner(() => EhentaiComicPageV2(link));
    }
  }

  /// 07号计划：右上角"更新信息"菜单项的入口。仅 jm/picacg/nhentai 三源可见
  /// （与 `_onVisitOnline`/在线详情动作项共用同一可见性判断，不重新发明）。
  ///
  /// 校验前置逻辑与 `_onVisitOnline` 保持一致：先用 06号计划的
  /// resolveOnlineRawId/extractJmNumericId/extractNhentaiNumericId 校验，
  /// 校验失败直接提示中断，不发起网络请求。
  ///
  /// 契约：网络拉取必须完全成功（getComicInfo 一次调用返回完整对象）之后才
  /// 触发写库；任一环节失败（网络异常/写回失败）都不改动 `_comic` 内存状态
  /// 与磁盘数据，不做部分覆盖的中间状态。
  Future<void> _onUpdateInfo() async {
    if (_isUpdatingInfo) {
      return;
    }
    final comic = _comic;
    if (comic is! LocalLibraryComicItem) {
      _showMessage('该本地记录未关联本地数据库，无法更新信息'.tl);
      return;
    }
    final rawId = resolveOnlineRawId(comic);

    Future<UpdateInfoFetchResult?> fetchOverlay(
      Future<UpdateInfoFetchResult?> Function() body,
    ) async {
      setState(() => _isUpdatingInfo = true);
      try {
        return await body();
      } finally {
        if (mounted) setState(() => _isUpdatingInfo = false);
      }
    }

    UpdateInfoFetchResult? fetchResult;
    if (comic.type == DownloadType.jm) {
      final numericId = extractJmNumericId(rawId);
      if (numericId == null) {
        _showMessage('该本地记录缺少有效的在线ID，无法更新信息'.tl);
        return;
      }
      fetchResult = await fetchOverlay(() async {
        final res = await JmNetwork().getComicInfo(numericId);
        if (res.error) {
          return UpdateInfoFetchResult.failure(res.errorMessageWithoutNull);
        }
        return UpdateInfoFetchResult.jm(res.data);
      });
    } else if (comic.type == DownloadType.picacg) {
      if (rawId.isEmpty) {
        _showMessage('该本地记录缺少有效的在线ID，无法更新信息'.tl);
        return;
      }
      fetchResult = await fetchOverlay(() async {
        final res = await PicacgNetwork().getComicInfo(rawId);
        if (res.error) {
          return UpdateInfoFetchResult.failure(res.errorMessageWithoutNull);
        }
        return UpdateInfoFetchResult.picacg(res.data);
      });
    } else if (comic.type == DownloadType.nhentai) {
      final numericId = extractNhentaiNumericId(rawId);
      if (numericId == null) {
        _showMessage('该本地记录缺少有效的在线ID，无法更新信息'.tl);
        return;
      }
      fetchResult = await fetchOverlay(() async {
        final res = await NhentaiNetwork().getComicInfo(numericId);
        if (res.error) {
          return UpdateInfoFetchResult.failure(res.errorMessageWithoutNull);
        }
        return UpdateInfoFetchResult.nhentai(res.data);
      });
    } else if (comic.type == DownloadType.ehentai) {
      final link = resolveEhGalleryLink(comic);
      if (link == null) {
        _showMessage('该本地记录缺少有效的在线链接，无法更新信息'.tl);
        return;
      }
      fetchResult = await fetchOverlay(() async {
        final res = await getEhGalleryInfoWithContentWarning(
          context: context,
          link: link,
        );
        if (res.error) {
          return UpdateInfoFetchResult.failure(
            isEhContentWarning(res) ? '已取消内容警告确认' : res.errorMessageWithoutNull,
          );
        }
        return UpdateInfoFetchResult.ehentai(res.data);
      });
    } else {
      // 菜单可见性已排除其它来源，这里同样是防御性兜底。
      return;
    }

    if (!mounted || fetchResult == null) {
      return;
    }
    if (fetchResult.errorMessage != null) {
      _showMessage('更新信息失败：${fetchResult.errorMessage}'.tl);
      return;
    }

    final ok = await _applyUpdateInfoOverwrite(comic, fetchResult);
    if (!mounted) return;
    if (ok) {
      _showMessage('信息已更新'.tl);
    } else {
      _showMessage('更新信息失败：写回本地数据库失败'.tl);
    }
  }

  /// 网络拉取已完全成功后才调用：把新拉取的元数据整体覆盖进具体子类实例，
  /// 序列化写回 sourceDbPath 对应行的 json/title/subtitle 列，成功后刷新
  /// `_comic` 内存状态。任一步失败都直接返回 false，不做半成品覆盖
  /// （旧实例保持不变，_comic 与磁盘数据不会产生不一致）。
  Future<bool> _applyUpdateInfoOverwrite(
    LocalLibraryComicItem comic,
    UpdateInfoFetchResult fetchResult,
  ) async {
    final sourceDbPath = comic.sourceDbPath?.trim();
    final sourceDbId = comic.sourceDbId?.trim();
    if (sourceDbPath == null ||
        sourceDbPath.isEmpty ||
        sourceDbId == null ||
        sourceDbId.isEmpty) {
      return false;
    }
    final rawJson = comic.sourceRowJson;
    if (rawJson == null || rawJson.trim().isEmpty) {
      return false;
    }
    final existing = restoreConcreteDownloadedRecord(comic);
    if (existing == null) {
      return false;
    }

    final updated = buildUpdatedDownloadedRecord(existing, fetchResult);
    if (updated == null) {
      return false;
    }

    String newJson;
    try {
      newJson = jsonEncode(updated.toJson());
    } catch (_) {
      return false;
    }

    bool wrote;
    try {
      wrote = await TrashManager.instance.updateSourceDbRowMetadata(
        sourceDbPath: sourceDbPath,
        sourceDbId: sourceDbId,
        newTitle: updated.name,
        newSubtitle: updated.subTitle,
        newJson: newJson,
      );
    } catch (e) {
      LogManager.addLog(
        LogLevel.error,
        'LocalComicDetailPage',
        '_applyUpdateInfoOverwrite: write failed: $e',
      );
      return false;
    }
    if (!wrote) {
      return false;
    }

    // 写回成功后刷新页面状态：复用页面初始化时加载 _comic 的同一套逻辑，重新读取
    // 该行数据，让"信息"区立即显示新值，不需要用户手动退出再重进页面。
    final refreshed = LocalLibraryComicItem(
      itemId: comic.itemId,
      originalId: comic.originalId,
      type: comic.type,
      name: updated.name,
      subTitle: updated.subTitle,
      tags: updated.tags,
      sourceDisplayName: comic.sourceDisplayName,
      fileSystemPath: comic.fileSystemPath ?? '',
      episodeFiles: comic.episodeFiles,
      downloadedEps: comic.downloadedEps,
      eps: comic.eps,
      localCoverPath: comic.localCoverPath,
      localStorageExists: comic.localStorageExists,
      canDelete: comic.canDelete,
      aliases: comic.aliases,
      favoriteTarget: comic.favoriteTarget,
      comicSize: comic.comicSize,
      sourceDbPath: comic.sourceDbPath,
      sourceDbId: comic.sourceDbId,
      sourceDirectory: comic.sourceDirectory,
      sourceDbRowId: comic.sourceDbRowId,
      sourceRowJson: newJson,
      sourceRowTimeMillis: comic.sourceRowTimeMillis,
    )..time = comic.time;
    if (mounted) {
      setState(() {
        _comic = refreshed;
      });
    }
    unawaited(_observeUntranslatedTags(refreshed));
    App.notifyLocalDataChanged();
    return true;
  }

  Future<void> _showTitleActionsMenu(Offset position) async {
    final comic = _comic;
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) {
      return;
    }
    final localPosition = overlay.globalToLocal(position);
    final size = overlay.size;
    final dx = localPosition.dx.clamp(0.0, size.width);
    final dy = localPosition.dy.clamp(0.0, size.height);
    final showUpdateInfo = supportsUpdateInfo(comic.type);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        dx,
        dy,
        size.width - dx,
        size.height - dy,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'copy_title',
          child: Text('复制标题'.tl),
        ),
        if (showUpdateInfo)
          PopupMenuItem<String>(
            value: 'update_info',
            child: Text('更新信息'.tl),
          ),
      ],
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case 'copy_title':
        _copyText(comic.name);
        break;
      case 'update_info':
        await _onUpdateInfo();
        break;
    }
  }

  Widget _buildActionItem(String title, IconData icon, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 72, minHeight: 72),
        child: SizedBox(
          width: 72,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 24,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 8),
                Text(
                  title.tl,
                  textAlign: TextAlign.center,
                  softWrap: true,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _recommendationTile(_LocalRecommendation recommendation) {
    final item = recommendation.item;
    final cover = resolveLocalComicCover(
      item,
      legacyTargets: _historyTargetsFor(item),
    );
    // 本地项走 privileged-aware provider（root/shizuku 下裸 Image.file/existsSync
    // 读外部路径会破图）；远程项用其自带 provider。
    final remoteProvider = item is RemoteLibraryComicItem
        ? item.coverImageProvider
        : item is RemoteLibraryRootItem
            ? item.coverImageProvider
            : null;
    final ImageProvider<Object>? coverProvider = remoteProvider ??
        (item is LocalLibraryComicItem && cover.path.isNotEmpty
            ? LocalLibraryManager().imageProviderForLocalPath(cover.path)
            : null);
    final author = _recommendationAuthor(item);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        App.pushInner(() => LocalComicDetailPage(comic: item));
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 18, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 76,
              height: 112,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              clipBehavior: Clip.antiAlias,
              child: coverProvider != null
                  ? Image(
                      image: coverProvider,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.image_not_supported),
                    )
                  : const Icon(Icons.image_not_supported),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 4),
                  if (author.isNotEmpty)
                    Text(
                      author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const Spacer(),
                  Text(
                    _displayIdFor(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    recommendation.reason,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.primary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final comic = _comic;
    final description = _getDescription();
    final history = _historyFor(comic);
    final infoGroups = _buildInfoGroups();
    final infoRows = buildLocalDetailInfoRows(infoGroups);
    final recommendations = _buildRecommendations();
    final start = recommendations.isEmpty
        ? 0
        : (_recommendationPage * _recommendationPageSize) %
            recommendations.length;
    final pageRecommendations =
        recommendations.skip(start).take(_recommendationPageSize).toList();

    Widget page = Scaffold(
      body: NotificationListener<OverscrollNotification>(
        onNotification: (notification) => _handleRecommendationOverscroll(
          notification,
          recommendations.length,
        ),
        // 点击空白/非文字处清除封面旁标题/作者选中态：点击时让 SelectableText 失焦，
        // translucent 不挡子级点击/滚动/长按选中。
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusScope.of(context).unfocus(),
          child: SmoothCustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverAppBar(
                pinned: true,
                title: AnimatedOpacity(
                  opacity: _showAppbarTitle ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    comic.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                actions: [
                  Builder(
                    builder: (buttonContext) => IconButton(
                      tooltip: '更多'.tl,
                      icon: const Icon(Icons.more_horiz),
                      onPressed: () {
                        // 参考 _showTextActionsAt 的坐标定位写法：取按钮的
                        // RenderBox 全局位置构造菜单弹出坐标（按钮左下角）。
                        final renderBox =
                            buttonContext.findRenderObject() as RenderBox?;
                        if (renderBox == null) return;
                        final position = renderBox.localToGlobal(
                          Offset(0, renderBox.size.height),
                        );
                        _showTitleActionsMenu(position);
                      },
                    ),
                  ),
                ],
              ),
              SliverToBoxAdapter(child: _buildComicInfo(context, history)),
              _sectionHeader('信息'),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final row in infoRows)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Wrap(
                            children: [
                              for (final group in row) ...[
                                _infoCard(
                                  group.localizeName
                                      ? group.name.tl
                                      : group.name,
                                  title: true,
                                ),
                                for (final value in group.values)
                                  _infoCard(
                                    value.displayText,
                                    rawSearchValue: group.isTagGroup
                                        ? value.effectiveRawValue
                                        : null,
                                    rawNamespace: group.isTagGroup
                                        ? value.rawNamespace
                                        : '',
                                  ),
                              ],
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              ..._buildEpisodes(context),
              ..._buildIntroduction(description),
              ..._buildRecommendationSlivers(
                pageRecommendations,
                recommendations.length,
              ),
              SliverPadding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom + 24,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (_isDeleteOperationRunning) {
      page = Stack(
        fit: StackFit.expand,
        children: [
          page,
          Positioned.fill(child: _buildDeleteProgressOverlay()),
        ],
      );
    }
    return PopScope(
      canPop: !_isDeleteOperationRunning,
      child: page,
    );
  }

  Widget _buildComicInfo(BuildContext context, dynamic history) {
    final comic = _comic;
    final author = comic is LocalLibraryComicItem
        ? resolveDownloadedAuthorsFromRecord(
            comic.originalId,
            comic.sourceRowJson ?? '',
            fallback: comic,
          ).join(', ')
        : resolveDownloadedAuthors(comic).join(', ');
    final canContinue = history != null && (history.ep > 0 || history.page > 0);
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 500;
      Widget infoValue(
        String displayText, {
        String? rawSearchValue,
        TextStyle? style,
      }) {
        final isPlaceholder = _isPlaceholderInfoValue(displayText);
        final value = Align(
          alignment: Alignment.centerLeft,
          child: Text(
            displayText,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        );
        if (isPlaceholder) {
          return value;
        }
        final keyword = _localInfoSearchKeyword(
          displayText: displayText,
          rawSearchValue: rawSearchValue,
        );
        return InfoValueAction(
          data: InfoValueData(
            displayText: displayText,
            rawSearchValue: rawSearchValue ?? displayText,
          ),
          onSearch:
              keyword.isEmpty ? null : () => _openRecommendationSearch(keyword),
          child: value,
        );
      }

      final actions = Wrap(
        alignment: compact ? WrapAlignment.center : WrapAlignment.start,
        children: [
          if (canContinue)
            _buildActionItem('继续阅读', Icons.menu_book,
                () => _onRead(ep: history.ep, page: history.page)),
          _buildActionItem(
            '从头开始',
            Icons.not_started_outlined,
            () => _onRead(ep: comic.eps.length > 1 ? 1 : 0),
          ),
          _buildActionItem('分享', Icons.share, () => _copyText(comic.name)),
          if (supportsUpdateInfo(_comic.type))
            _buildActionItem('在线详情', Icons.public, _onVisitOnline),
          if (comic is LocalLibraryComicItem &&
              comic.isArchiveItem &&
              comic.archivePasswordMatched)
            _buildActionItem(
              '忘记密码',
              Icons.lock_reset_outlined,
              () => _onForgetArchivePassword(comic),
            ),
          if (_canDeleteComic)
            _buildActionItem('删除下载', Icons.delete_outline, _onDelete),
        ],
      );

      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildCover(context, 102, 136),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        comic.name.trim(),
                        style: const TextStyle(fontSize: 18),
                      ),
                      if (author.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        SelectableText(
                          author,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ],
                      const SizedBox(height: 8),
                      infoValue(
                        _sourceLabel,
                        rawSearchValue: comic.sourceDisplayName,
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      infoValue(
                        _formatSize(comic.comicSize),
                        rawSearchValue: comic.comicSize?.toString(),
                        style: const TextStyle(fontSize: 12),
                      ),
                      if (!compact)
                        Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: actions),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (compact)
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: actions),
        ],
      );
    });
  }

  bool _canToggleChapterNumber(DownloadedItem comic) {
    if (comic is LocalLibraryComicItem) {
      return comic.isArchiveItem ||
          (comic.sourceDisplayName == '合集图集' && comic.eps.length > 1);
    }
    if (comic is RemoteLibraryComicItem) {
      return comic.isArchive ||
          (comic.isCustomLibraryRoot && comic.hasMultipleEpisodes);
    }
    return false;
  }

  bool _isCollectionShellAlbum(DownloadedItem comic) {
    if (comic is LocalLibraryComicItem) {
      return comic.sourceDisplayName == '合集图集';
    }
    if (comic is RemoteLibraryComicItem) {
      return comic.metadataSourceDisplayName.trim() == '合集图集';
    }
    return false;
  }

  String _stripCollectionShellPrefix(DownloadedItem comic, String title) {
    if (!_isCollectionShellAlbum(comic)) {
      return title;
    }
    final itemTitle = comic.name.trim();
    final normalizedTitle = title.trim();
    if (itemTitle.isEmpty || !normalizedTitle.startsWith(itemTitle)) {
      return title;
    }
    final rest = normalizedTitle.substring(itemTitle.length).trimLeft();
    final cleaned =
        rest.replaceFirst(RegExp(r'^[\s/_\\\-—:：]+'), '').trimLeft();
    return cleaned.isEmpty ? title : cleaned;
  }

  String _chapterNumberDisplayName({
    required int index,
    required int episodeIndex,
    required String title,
  }) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      return '${episodeIndex > 0 ? episodeIndex : index + 1}';
    }
    if (RegExp(r'^(第\s*)?\d+\s*(章|话|集|回)?([\s._-]+|$)').hasMatch(trimmed)) {
      return trimmed;
    }
    return '${episodeIndex > 0 ? episodeIndex : index + 1} $trimmed';
  }

  List<String> _chapterDisplayNamesFor(DownloadedItem comic) {
    if (comic is LocalLibraryComicItem && comic.isArchiveItem) {
      return LocalLibraryManager.archiveDisplayChapterNames(comic);
    }
    if (comic is LocalLibraryComicItem && comic.sourceDisplayName == '合集图集') {
      final titles = comic.eps
          .map((title) => _stripCollectionShellPrefix(comic, title))
          .toList(growable: false);
      if (!readArchiveUseChapterNumber()) {
        return titles;
      }
      return List<String>.generate(titles.length, (index) {
        return _chapterNumberDisplayName(
          index: index,
          episodeIndex: index + 1,
          title: titles[index],
        );
      });
    }
    if (comic is RemoteLibraryComicItem) {
      final titles = comic.eps
          .map((title) => _stripCollectionShellPrefix(comic, title))
          .toList(growable: false);
      if (!comic.isArchive && !comic.isCustomLibraryRoot) {
        return titles;
      }
      if (!readArchiveUseChapterNumber()) {
        return titles;
      }
      return List<String>.generate(titles.length, (index) {
        final episodeIndex = index < comic.episodesData.length
            ? comic.episodesData[index].index
            : index + 1;
        return _chapterNumberDisplayName(
          index: index,
          episodeIndex: episodeIndex,
          title: titles[index],
        );
      });
    }
    return comic.eps;
  }

  List<Widget> _buildEpisodes(BuildContext context) {
    final comic = _comic;
    if (comic.eps.isEmpty) return const [];
    var length = comic.eps.length;
    if (!_showFullEps) length = math.min(length, 20);
    final LocalLibraryComicItem? archiveComic =
        comic is LocalLibraryComicItem && comic.isArchiveItem ? comic : null;
    final archiveItem = archiveComic != null;
    final canToggleChapterNumber = _canToggleChapterNumber(comic);
    final canToggleFullEps = comic.eps.length > 20;
    final displayNames = _chapterDisplayNamesFor(comic);

    return [
      SliverToBoxAdapter(
        child: Column(
          children: [
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Text(
                          '章节'.tl,
                          style: const TextStyle(
                            fontWeight: FontWeight.w500,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '共${comic.eps.length}章'.tl,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (canToggleChapterNumber) ...[
                    Text('序号'.tl, style: Theme.of(context).textTheme.bodySmall),
                    Transform.scale(
                      scale: 0.8,
                      child: Switch(
                        value: readArchiveUseChapterNumber(),
                        onChanged: (v) async {
                          await writeArchiveUseChapterNumber(v);
                          setState(() {});
                        },
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Tooltip(
                    message: '排序'.tl,
                    child: IconButton(
                      icon: const Icon(Icons.swap_vert),
                      onPressed: () =>
                          setState(() => _reverseEpsOrder = !_reverseEpsOrder),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SliverPadding(padding: EdgeInsets.all(6)),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        sliver: SliverGrid(
          delegate: SliverChildBuilderDelegate(
            childCount: length,
            (context, i) {
              final index = _reverseEpsOrder ? comic.eps.length - i - 1 : i;
              final isDownloaded = archiveItem ||
                  comic.downloadedEps.contains(index) ||
                  !comic.canDelete;
              final readEp = comic.eps.length > 1 ? index + 1 : 0;
              return Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                child: InkWell(
                  borderRadius: const BorderRadius.all(Radius.circular(16)),
                  onTap: isDownloaded ? () => _onRead(ep: readEp) : null,
                  onLongPress: comic.canDelete && !archiveItem && isDownloaded
                      ? () => _onDeleteEpisode(index)
                      : null,
                  child: Material(
                    elevation: 5,
                    color: Theme.of(context).colorScheme.surface,
                    surfaceTintColor: Theme.of(context).colorScheme.surfaceTint,
                    borderRadius: const BorderRadius.all(Radius.circular(12)),
                    shadowColor: Colors.transparent,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: Center(
                        child: Text(
                          index < displayNames.length
                              ? displayNames[index]
                              : comic.eps[index],
                          maxLines: 1,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isDownloaded
                                ? null
                                : Theme.of(context).colorScheme.outline,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 200,
            mainAxisExtent: 48,
          ),
        ),
      ),
      if (canToggleFullEps)
        SliverToBoxAdapter(
          child: Align(
            alignment: Alignment.center,
            child: FilledButton.tonal(
              style: ButtonStyle(
                shape: WidgetStateProperty.all(
                  const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                ),
              ),
              onPressed: () => setState(() => _showFullEps = !_showFullEps),
              child: Text(
                _showFullEps ? '收起'.tl : '${'显示全部'.tl} (${comic.eps.length})',
              ),
            ),
          ),
        ),
    ];
  }

  List<Widget> _buildIntroduction(String? description) {
    if (description == null || description.isEmpty) return const [];
    return [
      const SliverPadding(padding: EdgeInsets.all(5)),
      _sectionHeader('简介'),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
          child: SelectableText(description),
        ),
      ),
      const SliverPadding(padding: EdgeInsets.all(5)),
    ];
  }

  List<Widget> _buildRecommendationSlivers(
    List<_LocalRecommendation> recommendations,
    int total,
  ) {
    if (normalizeLocalDetailRecommendationMode(
          appdata.settings[localDetailRecommendationSettingIndex],
        ) ==
        '5') {
      return const [];
    }
    if (recommendations.isEmpty) {
      return [
        _sectionHeader(
          '相关推荐',
          trailing: IconButton(
            tooltip: '设置'.tl,
            icon: const Icon(Icons.tune),
            onPressed: _showRecommendationSettings,
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            child: Text(
              _comic is RemoteLibraryComicItem
                  ? '暂无可推荐的远程内容'.tl
                  : '暂无可推荐的本地漫画'.tl,
            ),
          ),
        ),
      ];
    }

    return [
      _sectionHeader(
        '相关推荐',
        trailing: IconButton(
          tooltip: '设置'.tl,
          icon: const Icon(Icons.tune),
          onPressed: _showRecommendationSettings,
        ),
      ),
      const SliverPadding(padding: EdgeInsets.all(5)),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        sliver: SliverGrid(
          delegate: SliverChildBuilderDelegate(
            childCount: recommendations.length,
            (context, index) => _recommendationTile(recommendations[index]),
          ),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 520,
            mainAxisExtent: 136,
          ),
        ),
      ),
      if (total > _recommendationPageSize)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: FilledButton.tonalIcon(
                onPressed: () => _showNextRecommendationPage(total),
                icon: const Icon(Icons.keyboard_double_arrow_up),
                label: Text('下一组推荐'.tl),
              ),
            ),
          ),
        ),
    ];
  }
}

class _CoverPreviewPage extends StatelessWidget {
  const _CoverPreviewPage({
    required this.imageProvider,
    required this.heroTag,
  });

  final ImageProvider<Object> imageProvider;
  final String heroTag;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('图片'.tl),
      ),
      body: Hero(
        tag: heroTag,
        child: PhotoView(
          minScale: PhotoViewComputedScale.contained * 0.9,
          imageProvider: imageProvider,
          filterQuality: FilterQuality.medium,
          loadingBuilder: (context, event) {
            return const ColoredBox(
              color: Colors.black,
              child: Center(child: CircularProgressIndicator()),
            );
          },
          errorBuilder: (context, error, stackTrace, retry) {
            return ColoredBox(
              color: Colors.black,
              child: Center(
                child: IconButton(
                  tooltip: '重试'.tl,
                  color: Colors.white,
                  icon: const Icon(Icons.refresh),
                  onPressed: retry,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
