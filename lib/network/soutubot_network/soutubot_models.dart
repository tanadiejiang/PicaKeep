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

double _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
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

  /// `"nhentai"` | `"ehentai"` | `"panda"`（原样保留未知值）。
  final String source;

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
  String get subjectUrl => _sourceBase + (subjectPath ?? '');

  static final _nhentaiIdPattern = RegExp(r'/g/(\d+)');

  /// eh 画廊路径必须 gid + token 齐全（如 `/g/2837167/f9a0a17b17`）。
  static final _ehGalleryPattern = RegExp(r'^/g/\d+/[a-z0-9]+');

  /// 映射为 AiResultItem 形状（进 `{'items': [...]}` 工具结果）。
  Map<String, Object?> toAiResultItemJson() {
    var mappedSource = '';
    var id = subjectPath ?? title;
    if (source == 'nhentai') {
      final match = _nhentaiIdPattern.firstMatch(subjectPath ?? '');
      if (match != null) {
        mappedSource = 'nhentai';
        id = match.group(1)!;
      }
    } else if (source == 'ehentai') {
      final path = subjectPath ?? '';
      if (_ehGalleryPattern.hasMatch(path)) {
        mappedSource = 'ehentai';
        id = soutubotEhentaiBase + path;
      }
    }
    return {
      'id': id,
      'title': title,
      'author': '',
      'coverUrl': previewImageUrl,
      'source': mappedSource,
      'tags': const <String>[],
      'availability': {
        'similarity': similarity,
        'language': language,
        'matchedPage': page,
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

  factory SoutubotSearchResult.fromJson(Map<String, Object?> json) {
    final data = json['data'];
    return SoutubotSearchResult(
      items: [
        if (data is List)
          for (final entry in data)
            if (entry is Map)
              SoutubotSearchItem.fromJson(
                entry.map((key, value) => MapEntry(key.toString(), value)),
              ),
      ],
      id: _asString(json['id']),
      factor: _asDouble(json['factor']),
      imageUrl: _asString(json['imageUrl']),
      searchOption: json['searchOption'],
      executionTime: _asDouble(json['executionTime']),
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
