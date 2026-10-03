/// soutubot.moe 搜索响应模型与 AiResultItem 形状映射（第十五轮 05 计划步骤 3）。
///
/// 映射契约（点卡片能打开正确页面的关键）：
/// - nhentai：AiResultItem.id 是纯数字画廊号（`NhentaiComicPageV2(item.id)` 契约），
///   从 subjectPath 用 `/g/(\d+)` 抠取；抠不到按 panda 同法降级。
/// - ehentai：AiResultItem.id 是画廊完整 URL（`EhGalleryBrief.id => link`、
///   `EhentaiComicPageV2(link)` 直接 GET 该 URL 的契约），且 subjectPath 必须
///   gid+token 齐全（缺 token 的 URL 打开必 404），否则降级。
/// - panda 及其他未知来源：source 置空串（normalizeAiSource 不认识的源落 ''，
///   条目保留不丢弃），availability.webUrl 是唯一可打开出口。
///   严禁把 panda 映射成 ehentai：chaika 归档 ID 与 eh gallery ID 不同构，
///   映射会打开错误页面。
library;

/// 链接拼法常量（逆向自站点前端）。
const soutubotNhentaiBase = 'https://nhentai.net';
const soutubotEhentaiBase = 'https://e-hentai.org';
const soutubotPandaBase = 'https://panda.chaika.moe';

String _asString(Object? value) => value?.toString() ?? '';

String _scalarString(Object? value) =>
    value is String || value is num ? value.toString() : '';

Object? _at(Object? value, String path) {
  for (final key in path.split('.')) {
    if (value is! Map) return null;
    value = value[key];
  }
  return value;
}

const _defaultFieldPaths = <String, List<String>>{
  'source': ['metadata.source.key', 'metadata.post.source_key', 'source_key'],
  'sourceId': ['metadata.source.id', 'metadata.post.post_id', 'external_id'],
  'title': ['metadata.title.primary', 'metadata.title'],
  'url': ['source_url', 'links.source_url'],
  'thumbnail': ['thumbnail_url', 'links.thumbnail_url'],
  'page': ['page_no'],
  'language': ['metadata.language', 'metadata.facts.language', 'language'],
};

/// 可配置路径只读取 JSON 字段，不执行表达式；缺失路径按备选顺序查找。
Object? _field(Map value, String field, Map? configuration) {
  final paths = configuration?[field] ?? _defaultFieldPaths[field];
  if (paths is! List) return null;
  for (final path in paths.whereType<String>()) {
    final found = _at(value, path);
    if (found is String && found.isNotEmpty || found is num && found.isFinite) {
      return found;
    }
  }
  return null;
}

String _safeUrl(String? raw, {String base = ''}) {
  if (raw == null || raw.trim().isEmpty) return '';
  final value = raw.trim();
  final parsed = Uri.tryParse(value);
  if (parsed == null) return '';
  final uri = parsed.hasScheme
      ? parsed
      : base.isEmpty
          ? null
          : Uri.parse(base).resolveUri(parsed);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return '';
  }
  return uri.toString();
}

double _asDouble(Object? value) {
  final parsed = value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '');
  return parsed?.isFinite == true ? parsed! : 0;
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.isFinite ? value.toInt() : 0;
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

/// 单条搜索结果条目。
class SoutubotSearchItem {
  const SoutubotSearchItem({
    required this.source,
    required this.page,
    required this.title,
    required this.language,
    required this.pagePath,
    required this.subjectPath,
    required this.previewImageUrl,
    required this.similarity,
    this.sourceId = '',
  });

  factory SoutubotSearchItem.fromJson(Map<String, Object?> json) {
    return SoutubotSearchItem(
      source: _asString(json['source']),
      page: _asInt(json['page']),
      title: _asString(json['title']),
      language: _asString(json['language']),
      pagePath: json['pagePath']?.toString(),
      subjectPath: json['subjectPath']?.toString(),
      previewImageUrl: _asString(json['previewImageUrl']),
      similarity: _asDouble(json['similarity']),
    );
  }

  factory SoutubotSearchItem.fromSegment(Map<String, Object?> segment,
      {required double score, Map? fieldPaths}) {
    final source = _scalarString(_field(segment, 'source', fieldPaths));
    final sourceId = _scalarString(_field(segment, 'sourceId', fieldPaths));
    final title = _scalarString(_field(segment, 'title', fieldPaths));
    final sourceUrl = _scalarString(_field(segment, 'url', fieldPaths));
    if (source.isEmpty && sourceId.isEmpty && title.isEmpty && sourceUrl.isEmpty) {
      throw const FormatException('soutubot path segment contains no recognizable metadata');
    }
    final rawPage = _asInt(_field(segment, 'page', fieldPaths));
    // 当前接口的部分 Pixiv 未导入路径把作品 ID 填进 page_no；这不是页号，
    // 明确标为未知，不猜测 0/1 起始页，也不把作品号展示成命中页数。
    final page = source.toLowerCase() == 'pixiv' && rawPage > 0 &&
        rawPage.toString() == sourceId ? 0 : rawPage;
    return SoutubotSearchItem(
      source: source.toLowerCase(),
      sourceId: sourceId,
      page: page,
      title: title.isNotEmpty
          ? title
          : '${source.isEmpty ? '未知来源' : source} #${sourceId.isEmpty ? '未知作品' : sourceId}',
      language: _scalarString(_field(segment, 'language', fieldPaths)),
      pagePath:
          _scalarString(segment['page_url'] ?? _at(segment, 'links.page_url')),
      subjectPath: sourceUrl,
      previewImageUrl: _safeUrl(
          _scalarString(_field(segment, 'thumbnail', fieldPaths)),
          base: 'https://soutubot.moe'),
      similarity: score,
    );
  }

  /// `"nhentai"` | `"ehentai"` | `"panda"`（原样保留未知值）。
  final String source;
  final String sourceId;

  /// 命中的页码。
  final int page;

  final String title;

  /// `cn` | `jp` | `gb` 等。
  final String language;

  /// 命中页链接路径；source == panda 时为 null。
  final String? pagePath;

  /// 画廊/本子链接路径，如 `/g/480041`。
  final String? subjectPath;

  final String previewImageUrl;

  /// 相似度，百分数（如 97.5 表示 97.5%）。
  final double similarity;

  String get _sourceBase {
    switch (source) {
      case 'nhentai':
        return soutubotNhentaiBase;
      case 'ehentai':
        return soutubotEhentaiBase;
      case 'panda':
        return soutubotPandaBase;
      default:
        return '';
    }
  }

  /// 条目的原站可打开链接。
  String get subjectUrl => _safeUrl(subjectPath, base: _sourceBase);

  static final _nhentaiIdPattern = RegExp(r'^/g/(\d+)(?:/|$)');

  /// eh 画廊路径必须 gid + token 齐全（如 `/g/2837167/f9a0a17b17`）。
  static final _ehGalleryPattern = RegExp(r'^/g/\d+/[a-z0-9]+/?$');

  /// 映射为 AiResultItem 形状（进 `{'items': [...]}` 工具结果）。
  Map<String, Object?> toAiResultItemJson() {
    var mappedSource = '';
    var id = (subjectPath?.isNotEmpty ?? false)
        ? subjectPath!
        : sourceId.isNotEmpty
            ? sourceId
            : title;
    final link = Uri.tryParse(subjectUrl);
    final path = link?.path ?? '';
    if (source == 'nhentai' && link?.host == 'nhentai.net') {
      final match = _nhentaiIdPattern.firstMatch(path);
      if (match != null) {
        mappedSource = 'nhentai';
        id = match.group(1)!;
      }
    } else if (source == 'ehentai' &&
        ['e-hentai.org', 'exhentai.org'].contains(link?.host)) {
      if (_ehGalleryPattern.hasMatch(path)) {
        mappedSource = 'ehentai';
        id = subjectUrl;
      }
    } else if (source == 'pixiv' &&
        ['pixiv.net', 'www.pixiv.net'].contains(link?.host)) {
      final match =
          RegExp(r'^/(?:[a-z]{2}/)?artworks/(\d+)/?$').firstMatch(path);
      if (match != null) {
        mappedSource = 'pixiv';
        id = match.group(1)!;
      }
    } else if (const ['jmcomic', '18comic', '18', 'jm'].contains(source)) {
      // JM 站点存在多个镜像域名；明确来源 + 本子路径才可路由，photo/章节号不当成本子号。
      final match = RegExp(r'^/album/(\d+)(?:/|$)').firstMatch(path);
      final knownMirror = RegExp(r'^(?:www\.)?(?:18comic|18-comic|jmcomic|jm-comic)\.[a-z0-9.-]+$')
          .hasMatch(link?.host ?? '');
      if (knownMirror && subjectUrl.isNotEmpty && match != null) {
        mappedSource = 'jm';
        id = match.group(1)!;
      }
    }
    return {
      'id': id,
      'title': title,
      'author': '',
      'coverUrl': _safeUrl(previewImageUrl, base: 'https://soutubot.moe'),
      'source': mappedSource,
      'tags': const <String>[],
      'availability': {
        'similarity': similarity,
        'language': language,
        if (page > 0) 'matchedPage': page,
        'webUrl': subjectUrl,
      },
    };
  }
}

/// 搜索响应顶层结构。
class SoutubotSearchResult {
  const SoutubotSearchResult({
    required this.items,
    required this.id,
    required this.factor,
    required this.imageUrl,
    required this.searchOption,
    required this.executionTime,
  });

  factory SoutubotSearchResult.fromJson(Map<String, Object?> json,
      {Map<String, Object?>? response}) {
    final format = response?['format']?.toString() ?? 'soutubot_v2';
    if (!const ['soutubot_v2', 'legacy'].contains(format)) {
      throw const FormatException('Unsupported soutubot response format');
    }
    final resultsPath = response?['resultsPath']?.toString() ??
        (format == 'legacy' ? 'data' : 'results');
    final configured = _at(json, resultsPath);
    final legacy =
        format == 'legacy' || configured == null && json['data'] is List;
    final data = legacy && configured == null ? json['data'] : configured;
    if (data is! List) {
      throw const FormatException('soutubot response results must be a list');
    }
    if (data.length > 2000) {
      throw const FormatException('soutubot response has too many results');
    }
    final items = <SoutubotSearchItem>[];
    for (final entry in data) {
      if (entry is! Map) {
        throw const FormatException('soutubot result must be an object');
      }
      final value = entry.map((key, value) => MapEntry(key.toString(), value));
      if (legacy) {
        items.add(SoutubotSearchItem.fromJson(value));
      } else {
        final segments = _at(
            value, response?['segmentsPath']?.toString() ?? 'path_segments');
        if (segments is! List) {
          throw const FormatException(
              'soutubot result path_segments must be a list');
        }
        final score = _asDouble(
            _at(value, response?['scorePath']?.toString() ?? 'score'));
        for (final segment in segments) {
          if (segment is! Map) {
            throw const FormatException(
                'soutubot path segment must be an object');
          }
          if (items.length >= 2000) {
            throw const FormatException('soutubot response has too many paths');
          }
          items.add(SoutubotSearchItem.fromSegment(
              segment.map((key, value) => MapEntry(key.toString(), value)),
              score: score,
              fieldPaths: response?['fieldPaths'] as Map?));
        }
      }
    }
    return SoutubotSearchResult(
      items: items,
      id: _asString(_at(json,
          response?['idPath']?.toString() ?? (legacy ? 'id' : 'result_id')) ?? (legacy ? json['id'] : null)),
      factor: _asDouble(
          json['factor'] ?? _at(json, 'query.requested_params.factor')),
      imageUrl: _safeUrl(
          _scalarString(json['imageUrl'] ?? _at(json, 'query.image_url')),
          base: 'https://soutubot.moe'),
      searchOption: json['searchOption'],
      executionTime: json['executionTime'] == null
          ? _asDouble(_at(json, 'timing.total_ms')) / 1000
          : _asDouble(json['executionTime']),
    );
  }

  final List<SoutubotSearchItem> items;

  /// 搜索记录 id，如 `"2025102006392555"`（`GET /api/results/{id}` 可取历史）。
  final String id;

  final double factor;

  final String imageUrl;

  /// 站点返回的搜索选项，形状未锁定，原样透传。
  final Object? searchOption;

  final double executionTime;
}
