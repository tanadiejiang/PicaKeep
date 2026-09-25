/// Komiic GraphQL 响应的**纯 Dart 解析层（零 Flutter 依赖）**。
///
/// 单独成文件的理由与 jm/picacg 的 `*_parsing.dart` 相同：网络层 import Flutter、
/// `comic_source` 与 `dio`，一旦把解析写在那里，`dart test` 就拉不起整棵依赖树。
/// 这里的每个函数都对缺失 / 类型不符的字段给默认值，**任何输入都不抛异常**：
/// Komiic 的 GraphQL 字段可能因服务端调整而缺席，整页崩掉远比空字段糟糕。
library;

import 'dart:convert';

import 'komiic_models.dart';

/// 图片直链前缀（`GET /api/image/{kid}`）。
const String komiicImageBase = 'https://komiic.com/api/image';

/// 从 `/api/login` 的响应正文里提取 token；识别不出返回 null。
///
/// 之所以做得容错而不是只认 `{"token": "..."}`：本站登录接口的确切响应形态
/// **未经真机验证**（调研取自第三方实现），真机实测已出现"HTTP 200 但按原假设
/// 解析不出来"的情况。与其在单一假设上反复试错，不如把已知的几种合理形态都接住。
///
/// 支持的形态：
/// - `{"token": "..."}`（Venera 参考实现读的就是这个键）
/// - `{"access_token": "..."}` / `{"accessToken": "..."}`
/// - `{"data": {"token": "..."}}` / `{"result": {...}}`（网关再包一层）
/// - 裸 JSON 字符串 `"eyJhbGci..."`（后端直接返回字符串时）
///
/// **两道刻意的保守**（都是为了不把非凭据的东西当 token 存下来）：
/// 1. 非 JSON 正文一律返回 null 而不猜 —— 那更可能是 HTML 风控页或错误页；
/// 2. 包装层（`data` / `result`）**只在它是对象时**才下钻，且裸字符串必须通过
///    [looksLikeKomiicToken] 的形态过滤 —— 否则 `{"result":"success"}` 这种
///    "网关回了个状态词"会被当成 token 写进源数据，之后每个请求都带着假 token
///    失败，比直接报错难查得多。
String? parseKomiicLoginToken(String? body) {
  if (body == null) return null;
  final raw = body.trim();
  if (raw.isEmpty) return null;
  final dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  return _tokenFromDecoded(decoded);
}

/// 裸字符串是否"像凭据"。
///
/// 只做最保守的形态过滤：真实 token 不会短于 8 字符、不含空白，也不是
/// `success` / `ok` 这类状态词。目的是挡住网关的**状态响应**被误当凭据。
///
/// 注意：**只在"裸字符串"这条路径上使用**。带明确键名的（`token` /
/// `access_token`）不做此过滤——键名本身已经表达了语义，再加形态限制反而会
/// 误杀服务端未来换用短 token 的情况。
bool looksLikeKomiicToken(String value) {
  final trimmed = value.trim();
  if (trimmed.length < 8) return false;
  if (trimmed.contains(RegExp(r'\s'))) return false;
  const statusWords = <String>{
    'success',
    'successful',
    'ok',
    'true',
    'false',
    'error',
    'failed',
    'fail',
    'none',
    'null',
    'unauthorized',
  };
  return !statusWords.contains(trimmed.toLowerCase());
}

String? _tokenFromDecoded(dynamic decoded) {
  if (decoded is String) {
    // 整个正文就是一个裸字符串：只有在它"像凭据"时才接受。
    return looksLikeKomiicToken(decoded) ? decoded.trim() : null;
  }
  if (decoded is Map) {
    for (final key in const <String>['token', 'access_token', 'accessToken']) {
      final value = decoded[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    for (final key in const <String>['data', 'result']) {
      final nested = decoded[key];
      // **只在对象时下钻**：`{"result": "success"}` 的字符串是操作状态，
      // 不是凭据包装，递归下去就会把它当 token。
      if (nested is Map) {
        final value = _tokenFromDecoded(nested);
        if (value != null) return value;
      }
    }
  }
  return null;
}

/// 把任意值安全转成字符串（null → 空串，其它走 toString）。
String _str(Object? value) => value?.toString() ?? '';

/// 把任意值安全转成 int（数字直接取，字符串尝试解析，失败 → 0）。
int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(_str(value)) ?? 0;
}

/// 可空 int：**解析失败返回 null 而不是 0**（用于 size 这类"未知 ≠ 0"的字段）。
int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// ISO 时间字符串 → `yyyy-MM-dd`；解析失败返回空串。
///
/// 只用 `DateTime.tryParse`，不做本地时区换算（Komiic 下发的是 UTC ISO 串，
/// 展示层只需要日期粒度，换时区反而可能让"今天更新"跳到昨天）。
String _formatDate(Object? value) {
  final raw = _str(value).trim();
  if (raw.isEmpty) return '';
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return '';
  final month = parsed.month.toString().padLeft(2, '0');
  final day = parsed.day.toString().padLeft(2, '0');
  return '${parsed.year}-$month-$day';
}

/// 取 `authors[0].name`（缺失 → 空串）。
String _firstAuthorName(Object? authors) {
  if (authors is! List || authors.isEmpty) return '';
  final first = authors.first;
  if (first is Map) return _str(first['name']);
  return _str(first);
}

/// 取 `categories[].name`，过滤空值并保序去重。
List<String> _categoryNames(Object? categories) {
  if (categories is! List) return const <String>[];
  final names = <String>[];
  for (final category in categories) {
    final name = category is Map ? _str(category['name']).trim() : '';
    if (name.isEmpty || names.contains(name)) continue;
    names.add(name);
  }
  return names;
}

/// 单条漫画对象 → [KomiicComicBrief]；非 Map 输入返回 null（调用方跳过坏条目）。
KomiicComicBrief? parseKomiicComicBrief(dynamic comic) {
  if (comic is! Map) return null;
  final id = _str(comic['id']).trim();
  if (id.isEmpty) return null;
  return KomiicComicBrief(
    id: id,
    title: _str(comic['title']),
    cover: _str(comic['imageUrl']),
    author: _firstAuthorName(comic['authors']),
    tags: _categoryNames(comic['categories']),
    status: _str(comic['status']),
    year: _str(comic['year']),
    updateTime: _formatDate(comic['dateUpdated']),
    views: _int(comic['views']),
    favoriteCount: _int(comic['favoriteCount']),
  );
}

/// 漫画对象数组 → brief 列表；**按 id 去重（保留首个）**。
///
/// 去重是必需的：`comicByIds` 遇到重复输入、分页边界重叠时都会下发重复条目，
/// 直接透传会让列表页出现同一本书两次（并让 key 冲突）。
List<KomiicComicBrief> parseKomiicComicList(dynamic list) {
  if (list is! List) return const <KomiicComicBrief>[];
  final comics = <KomiicComicBrief>[];
  final seenIds = <String>{};
  for (final item in list) {
    final comic = parseKomiicComicBrief(item);
    if (comic == null) continue;
    if (!seenIds.add(comic.id)) continue;
    comics.add(comic);
  }
  return comics;
}

/// 原始条数（**去重前**），用于"是否还有下一页"的判停。
///
/// 判停必须看服务端真实返回条数：满页（== limit）说明后面可能还有，
/// 若用去重后的长度判断，一条重复条目就会被误判成末页而提前截断列表。
int parseKomiicRawCount(dynamic list) => list is List ? list.length : 0;

/// `comicByIds` 的单条漫画对象 + 外部拼装的章节 / 推荐 → [KomiicComicInfo]。
KomiicComicInfo parseKomiicComicInfo(
  Map<String, dynamic> comic, {
  List<KomiicChapter> chapters = const <KomiicChapter>[],
  List<KomiicComicBrief> recommendations = const <KomiicComicBrief>[],
}) {
  final authors = <String>[];
  final rawAuthors = comic['authors'];
  if (rawAuthors is List) {
    for (final author in rawAuthors) {
      final name = author is Map ? _str(author['name']).trim() : '';
      if (name.isEmpty || authors.contains(name)) continue;
      authors.add(name);
    }
  }
  return KomiicComicInfo(
    id: _str(comic['id']),
    title: _str(comic['title']),
    coverUrl: _str(comic['imageUrl']),
    authors: authors,
    tags: _categoryNames(comic['categories']),
    description: _str(comic['description']),
    status: _str(comic['status']),
    year: _str(comic['year']),
    updateTime: _formatDate(comic['dateUpdated']),
    views: _int(comic['views']),
    monthViews: _int(comic['monthViews']),
    favoriteCount: _int(comic['favoriteCount']),
    chapters: chapters,
    recommendations: recommendations,
  );
}

/// 章节数组解析；**过滤 `serial` 为空的项**（无序号章节在半成品数据里没有意义，
/// 展示成空白条目会污染目录）。按 id 去重，同样保留首个。
List<KomiicChapter> parseKomiicChapters(dynamic list) {
  if (list is! List) return const <KomiicChapter>[];
  final chapters = <KomiicChapter>[];
  final seenIds = <String>{};
  for (final item in list) {
    if (item is! Map) continue;
    final serial = _str(item['serial']).trim();
    if (serial.isEmpty) continue;
    final id = _str(item['id']).trim();
    if (id.isNotEmpty && !seenIds.add(id)) continue;
    chapters.add(
      KomiicChapter(
        id: id,
        serial: serial,
        type: _str(item['type']).trim(),
        size: _intOrNull(item['size']),
        dateUpdated: _formatDate(item['dateUpdated']),
      ),
    );
  }
  return chapters;
}

/// `imagesByChapterId` 数组 → 图片 URL 列表；过滤空 kid。
List<String> parseKomiicImageUrls(dynamic list) {
  if (list is! List) return const <String>[];
  final urls = <String>[];
  for (final item in list) {
    final kid = item is Map ? _str(item['kid']).trim() : '';
    if (kid.isEmpty) continue;
    urls.add('$komiicImageBase/$kid');
  }
  return urls;
}

/// `folders` 数组 → [KomiicFolder] 列表。
List<KomiicFolder> parseKomiicFolders(dynamic folders) {
  if (folders is! List) return const <KomiicFolder>[];
  final result = <KomiicFolder>[];
  for (final item in folders) {
    if (item is! Map) continue;
    result.add(
      KomiicFolder(
        id: _str(item['id']).trim(),
        key: _str(item['key']),
        name: _str(item['name']),
        comicCount: _int(item['comicCount']),
      ),
    );
  }
  return result;
}

/// String / num 混合数组 → String 列表（去掉空值，保序去重）。
///
/// Komiic 的 id 在 GraphQL 里是 `ID` 标量，同一字段不同接口会下发 `"12"` 或
/// `12`，这里统一收口，避免上层到处 `?.toString() ?? ''`。
List<String> parseKomiicStringIds(dynamic list) {
  if (list is! List) return const <String>[];
  final ids = <String>[];
  for (final item in list) {
    if (item == null) continue;
    final id = item.toString().trim();
    if (id.isEmpty || ids.contains(id)) continue;
    ids.add(id);
  }
  return ids;
}
