/// Pixiv Web Ajax 响应的**纯 Dart 解析层**。
///
/// 为什么单独成文件：网络层（`pixiv_network.dart`）依赖 `base.dart`（`appdata`）
/// 与 Flutter，一旦解析留在那里，测试就必须拉起整棵 Flutter 依赖树，`dart test`
/// 无法直接跑。本文件只依赖 `dart:convert` 与 `pixiv_models.dart`，
/// **零 Flutter 依赖**，可用 `dart test` 直接对夹具断言。
library;

import 'pixiv_models.dart';

export 'pixiv_models.dart';

// ── 通用取值助手（全部空安全兜底，缺字段给默认值而不抛）────────────────────

/// 把任意值读成字符串并 trim；null / 非字符串一律给空串（不做 `toString` 强转，
/// 避免 Map/List 被塞进展示字段）。
String _str(dynamic value) => value is String ? value.trim() : '';

/// 把任意值读成 int（兼容数字与数字字符串）；解析不出给 [fallback]。
int _int(dynamic value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? fallback;
  return fallback;
}

/// 把任意值读成 bool（兼容 0/1、`"true"`，Pixiv 两种形态都出现过）。
bool _bool(dynamic value, [bool fallback = false]) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final text = value.trim().toLowerCase();
    if (text == 'true' || text == '1') return true;
    if (text == 'false' || text == '0') return false;
  }
  return fallback;
}

/// 把任意值读成** id 字符串**（兼容 JSON 数字与字符串两种形态）。
///
/// 必须区别于 [_str]：Pixiv 各接口对 id 的类型并不统一——搜索结果里是字符串
/// `"123"`，而排行榜 `contents[].illust_id` / `user_id` 是**数字** `81987309`。
/// 只认字符串会让排行榜条目被当成"坏条目"整页丢弃（实测踩到过），
/// 因此这里把 int/num 也正规化成十进制字符串。
String _idStr(dynamic value) {
  if (value == null) return '';
  if (value is String) return value.trim();
  if (value is int) return value.toString();
  if (value is num) {
    // 非整数（理论上不该出现）直接用 toString，交由调用方的数字校验兜底。
    return value.toInt() == value ? value.toInt().toString() : value.toString();
  }
  return '';
}

/// 从多个候选里取**第一个非空字符串**。
///
/// Pixiv 同一语义经常有多个键（`illustId` 与 `id`、`mini` 与 `thumb`），
/// 这里统一按调用方给出的优先级回退，避免各处散落 `??` 链。
String _firstNonEmpty(Iterable<dynamic> candidates) {
  for (final candidate in candidates) {
    final text = _str(candidate);
    if (text.isNotEmpty) return text;
  }
  return '';
}

/// 取出 `Map` 形态的子对象；不是 Map 时返回空 Map（便于继续安全取值）。
Map<String, dynamic> _map(dynamic value) {
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  return const <String, dynamic>{};
}

/// 清洗 Pixiv 简介里的 HTML。
///
/// 作品简介（`illustComment`）是富文本：要么带 `<br>` 换行，要么被 `<a>` 等
/// 标签包裹。这里只做**最小清洗**，不引入 HTML 解析器（纯层零额外依赖）：
/// 1. `<br>` / `<br/>` / `<br />` → `\n`；
/// 2. 其余 `<...>` 标签整体删除；
/// 3. 解码常见实体（`&amp; &lt; &gt; &quot; &#39;`）；
/// 4. 折叠 3 个以上连续换行，并去掉首尾空白。
///
/// 注意：`&#39;` 必须在 `&amp;` **之后**替换吗？不必——但 `&amp;lt;` 这类双重
/// 转义如果先解 `&amp;` 会被二次解析。这里保持"数字实体在前、`&amp;` 最后"
/// 的顺序，避免把用户文本里的字面量 `&lt;` 又变回标签。
String stripPixivHtml(String raw) {
  if (raw.isEmpty) return '';
  var text = raw;
  // 1) 换行标签先转成真换行（尖括号与斜杠之间允许空白）。
  text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  // 2) 去掉剩余标签。
  text = text.replaceAll(RegExp(r'<[^>]*>'), '');
  // 3) 实体解码：数字实体优先，&amp; 放最后（见上方注释）。
  text = text
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
  // 4) 折叠多余空行并 trim。
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return text.trim();
}

/// 解析 Pixiv 标签数组（`tags.tags:[{tag, translation:{en,ja,...}}]`）。
///
/// 展示名决策：**翻译名优先**——Pixiv 中文站会给 `translation.zh` / `translation.en`，
/// 用户看到的是本地化名，搜索命中却是原名；这里统一取翻译名（zh 优先，其次 en），
/// 无翻译时回退 `tag` 原文。同一作品可能同时返回原名与译名，因此按结果去重。
///
/// 返回顺序保持接口原顺序（用户观感更稳定），仅做去重与去空。
List<String> _parseTagsWithTranslation(dynamic rawTags) {
  final wrapper = _map(rawTags);
  final list = wrapper['tags'];
  if (list is! List) return const <String>[];
  final seen = <String>{};
  final result = <String>[];
  for (final item in list) {
    final tag = _map(item);
    final translation = _map(tag['translation']);
    final name = _firstNonEmpty(<dynamic>[
      translation['zh'],
      translation['en'],
      tag['tag'],
    ]);
    if (name.isEmpty) continue;
    if (seen.add(name)) result.add(name);
  }
  return result;
}

/// 解析 Pixiv 搜索列表里的标签（形如 `["tag1", "tag2"]` 或 `[{tag:...}]`）。
///
/// 搜索结果（`/ajax/search/artworks`）与排行榜的 tags 形态不一致：搜索是纯字符串
/// 数组，部分条目仍会带对象。两种都吃，取翻译名/`tag` 字段或字符串本身。
List<String> _parseBriefTags(dynamic rawTags) {
  if (rawTags is! List) return const <String>[];
  final seen = <String>{};
  final result = <String>[];
  for (final item in rawTags) {
    String name;
    if (item is String) {
      name = item.trim();
    } else {
      final tag = _map(item);
      final translation = _map(tag['translation']);
      name = _firstNonEmpty(<dynamic>[
        translation['zh'],
        translation['en'],
        tag['tag'],
        tag['name'],
      ]);
    }
    if (name.isEmpty) continue;
    if (seen.add(name)) result.add(name);
  }
  return result;
}

/// 从 `urls` 子对象里按优先级取第一个非空 URL。
String _pickUrl(dynamic urls, List<String> keys) {
  final map = _map(urls);
  return _firstNonEmpty(keys.map((key) => map[key]));
}

// ── 公开解析函数 ──────────────────────────────────────────────────────────

/// 解析作品详情：入参是 `/ajax/illust/{id}` 响应里的 `body` 对象。
///
/// 字段来源（已对齐 Web 端实际响应）：
/// - id：`illustId`，回退 `id`；
/// - 标题：`illustTitle`，回退 `title`；
/// - 简介：`illustComment`，回退 `description`（再经 [stripPixivHtml] 清洗）；
/// - 封面：`urls.original` → `regular` → `small` → `thumb` → `mini` 逐档回退
///   （详情页要的是大图，但缺原图时也不能显示空白）；
/// - 作者：`userName`；作者 id：`userId`（`userAccount` 是登录账号名，不当作 id）。
///
/// **唯一抛 [FormatException] 的情况**：id 与标题同时缺失——此时这条响应不可能是
/// 有效作品，静默返回空对象只会把坏数据带到上层。其余字段一律兜底为默认值。
PixivComicInfo parsePixivComicInfo(Map<String, dynamic> body) {
  final id = _firstNonEmpty(<dynamic>[body['illustId'], body['id']]);
  final title = _firstNonEmpty(<dynamic>[body['illustTitle'], body['title']]);
  if (id.isEmpty && title.isEmpty) {
    throw const FormatException('Pixiv illust 响应缺少 id 与 title');
  }

  final rawDescription = _firstNonEmpty(<dynamic>[
    body['illustComment'],
    body['description'],
  ]);

  return PixivComicInfo(
    id: id,
    title: title,
    author: _firstNonEmpty(<dynamic>[body['userName'], body['userAccount']]),
    authorId: _str(body['userId']),
    coverUrl: _pickUrl(
      body['urls'],
      const <String>['original', 'regular', 'small', 'thumb', 'mini'],
    ),
    tags: _parseTagsWithTranslation(body['tags']),
    description: stripPixivHtml(rawDescription),
    pageCount: _int(body['pageCount']),
    illustType: _int(body['illustType'], pixivIllustTypeIllust),
    likeCount: _int(body['likeCount']),
    viewCount: _int(body['viewCount']),
    width: _int(body['width']),
    height: _int(body['height']),
    isOriginal: _bool(body['isOriginal']),
    createDate: _str(body['createDate']),
    uploadDate: _str(body['uploadDate']),
    userId: _str(body['userId']),
  );
}

/// 解析作品逐页 URL：入参是 `/ajax/illust/{id}/pages` 响应里的 `body` 数组。
///
/// 每项形如 `{urls:{thumb_mini,small,regular,original}, width, height}`。
/// 非数组（风控 HTML 已被网络层拦掉，这里是结构异常）抛 [FormatException]，
/// 让调用方能明确区分"解析失败"与"作品无页"。
List<PixivPage> parsePixivPages(dynamic body) {
  if (body is! List) {
    throw const FormatException('Pixiv pages 响应不是数组');
  }
  return body.map((item) {
    final page = _map(item);
    final urls = page['urls'];
    return PixivPage(
      thumbMini: _pickUrl(urls, const <String>['thumb_mini', 'thumb']),
      small: _pickUrl(urls, const <String>['small']),
      regular: _pickUrl(urls, const <String>['regular']),
      // original 缺失时回退 regular：宁可给次一档图，也不要空 URL 导致阅读器白屏。
      original: _pickUrl(urls, const <String>['original', 'regular']),
      width: _int(page['width']),
      height: _int(page['height']),
    );
  }).toList(growable: false);
}

/// 解析动图元数据：入参是 `/ajax/illust/{id}/ugoira_meta` 响应里的 `body` 对象。
///
/// 帧字段来自 `frames:[{file,delay}]`，URL 字段注意 `mime_type` 是下划线风格
/// （Pixiv 此处不与驼峰统一，不能写成 `mimeType`）。
/// `frames` 缺失按空列表处理；损坏的帧（缺 file）跳过，避免下游拿到空文件名。
PixivUgoiraMeta parsePixivUgoiraMeta(Map<String, dynamic> body) {
  final rawFrames = body['frames'];
  final frames = <PixivUgoiraFrame>[];
  if (rawFrames is List) {
    for (final item in rawFrames) {
      final frame = _map(item);
      final file = _str(frame['file']);
      if (file.isEmpty) continue;
      frames.add(PixivUgoiraFrame(file: file, delay: _int(frame['delay'])));
    }
  }
  return PixivUgoiraMeta(
    frames: frames,
    mimeType: _str(body['mime_type']),
    originalSrc: _str(body['originalSrc']),
    src: _str(body['src']),
  );
}

/// 把单条搜索/榜单条目解析成 [PixivComicBrief]；`id` 缺失或非数字时返回 null。
///
/// 搜索接口混杂了少量占位条目（含 `isAdContainer` 的推广位、以及 id 为空的
/// 坏条目），id 不是数字一律判坏——这与项目里其它源"坏条目跳过而非塞空 id"的
/// 口径一致。
PixivComicBrief? _parseBriefItem(Map<String, dynamic> item) {
  final id = _idStr(item['id'] ?? item['illustId']);
  if (id.isEmpty || int.tryParse(id) == null) return null;

  // 封面：搜索响应自带 `url`（240x480 缩略图）；部分结构（如排行榜 contents）
  // 用 `urls.thumb` / `urls.mini`。都取不到时留空串（由展示层显示占位），
  // **不要伪造 `/ajax/illust/{id}` 这种非图片地址当封面**。
  final cover = _firstNonEmpty(<dynamic>[
    item['url'],
    _map(item['urls'])['thumb'],
    _map(item['urls'])['mini'],
    _map(item['urls'])['small'],
  ]);

  return PixivComicBrief(
    id: id,
    title: _firstNonEmpty(<dynamic>[item['title'], item['illustTitle']]),
    cover: cover,
    author: _firstNonEmpty(<dynamic>[item['userName'], item['userAccount']]),
    tags: _parseBriefTags(item['tags']),
    illustType: _int(item['illustType'], pixivIllustTypeIllust),
    pageCount: _int(item['pageCount']),
  );
}

/// 解析搜索结果：`body` 里同时有 `illust` 与 `manga` 两个子对象，各含 `data` 数组。
///
/// 关键决策：**两种作品类型都要合并，illust 在前**。Pixiv 会按内容把插画与漫画
/// 分流到不同键，只读 `illust` 会漏掉漫画作品（用户视角里都是"一张一张的图"，
/// 没有理由在搜索列表里丢掉一半结果）。
///
/// 去重按 id 只保留**第一个**：同一作品可能同时出现在两个键下，
/// 保留先出现的（illust 优先）以保证顺序稳定。
List<PixivComicBrief> parsePixivSearchItems(Map<String, dynamic> body) {
  final result = <PixivComicBrief>[];
  final seenIds = <String>{};
  // 顺序即优先级：illust 在前，manga 在后。
  for (final key in const <String>['illust', 'manga']) {
    final data = _map(body[key])['data'];
    if (data is! List) continue;
    for (final item in data) {
      if (item is! Map) continue;
      final brief = _parseBriefItem(_map(item));
      if (brief == null) continue;
      if (seenIds.add(brief.id)) result.add(brief);
    }
  }
  return result;
}

/// 解析书签列表响应（`/ajax/user/{userId}/illusts/bookmarks`）。
///
/// 入参是 Ajax 响应里的 `body` 对象：`{"works":[...], "total":123}`。
/// `works` 的单项字段与搜索项**同构**（`id` / `title` / `url` / `tags` /
/// `illustType` / `pageCount` / `userName`），因此直接复用 [_parseBriefItem]，
/// 不另写一套取值逻辑（字段口径必须与搜索保持一致）。
///
/// 坏条目（id 缺失或非数字）跳过，与 [parsePixivSearchItems] 同口径；
/// `total` 是书签总数（不是页数），故不在此处折算，由网络层交给 [Res.subData]。
List<PixivComicBrief> parsePixivBookmarkItems(Map<String, dynamic> body) {
  final works = body['works'];
  if (works is! List) return const <PixivComicBrief>[];
  final result = <PixivComicBrief>[];
  final seenIds = <String>{};
  for (final item in works) {
    if (item is! Map) continue;
    final brief = _parseBriefItem(_map(item));
    if (brief == null) continue;
    // 书签理论上不会重复，但同一作品可能因多标签命中而重复出现，按 id 去重。
    if (seenIds.add(brief.id)) result.add(brief);
  }
  return result;
}

/// 从搜索结果里推断总页数；找不到返回 null。
///
/// 搜索响应里页数字段在不同版本/灰度下位置会变（`illust.total`、`manga.total`、
/// `illust.lastPage`、以及顶层同名键都出现过），因此这里做**防御式解析**：
/// 逐个位置找候选、取其中最大值，全部找不到时返回 null —— 由调用方退回保守判停
/// （例如"本页不足 N 条即停"）。
///
/// 约定：本函数**绝不抛异常**，结构完全变化时也只是返回 null。
int? parsePixivSearchMaxPage(Map<String, dynamic> body) {
  int? best;

  void consider(dynamic value) {
    final parsed = _int(value, -1);
    if (parsed <= 0) return;
    if (best == null || parsed > best!) best = parsed;
  }

  void considerMap(dynamic node) {
    final map = _map(node);
    // `lastPage` 语义上更接近"最后一页"，与 total 同时存在时取较大者更安全。
    consider(map['lastPage']);
    consider(map['total']);
  }

  for (final key in const <String>['illust', 'manga']) {
    considerMap(body[key]);
    // 部分响应把字段再嵌一层（如 `{illust: {data: [...], total: N}}` 之外的结构）。
    final nested = _map(body[key]);
    considerMap(nested['page']);
    considerMap(nested['pagination']);
  }
  // 顶层同名键（防御结构变化）。
  considerMap(body);

  return best;
}

/// 解析排行榜响应（`/ranking.php?format=json`）。
///
/// 该接口与 Ajax 搜索不同：**`contents` 直接是顶层数组**（不是 `body` 子对象），
/// 条目字段为 `illust_id` / `title` / `url` / `tags` / `illust_type` /
/// `illust_page_count` / `user_id` / `user_name` —— 下划线风格，不能复用搜索的
/// 驼峰取值，这里做字段名映射（源字段名见 Pixiv 排行榜 JSON）。
List<PixivComicBrief> parsePixivRankingItems(Map<String, dynamic> body) {
  final contents = body['contents'];
  if (contents is! List) return const <PixivComicBrief>[];
  final result = <PixivComicBrief>[];
  final seenIds = <String>{};
  for (final item in contents) {
    if (item is! Map) continue;
    final map = _map(item);
    // 注意 `illust_id` 是 JSON 数字（见 `_idStr` 注释），不能用只认字符串的取值器。
    final id = _idStr(map['illust_id'] ?? map['id']);
    if (id.isEmpty || int.tryParse(id) == null) continue;
    // 排行榜的 `url` **就是**封面图直链（`i.pximg.net/c/240x480/...`），
    // 不是作品页链接——这点与搜索结果不同。因此优先取 `url`，再回退 urls 子对象。
    final cover = _firstNonEmpty(<dynamic>[
      map['url'],
      _map(map['urls'])['thumb'],
      _map(map['urls'])['mini'],
      _map(map['urls'])['small'],
      _map(map['urls'])['regular'],
    ]);
    if (!seenIds.add(id)) continue;
    result.add(
      PixivComicBrief(
        id: id,
        title: _firstNonEmpty(<dynamic>[map['title'], map['illust_title']]),
        cover: cover,
        author: _firstNonEmpty(<dynamic>[
          map['user_name'],
          map['userName'],
          map['user_account'],
        ]),
        tags: _parseBriefTags(map['tags']),
        illustType: _int(
          map['illust_type'] ?? map['illustType'],
          pixivIllustTypeIllust,
        ),
        pageCount: _int(
          map['illust_page_count'] ?? map['pageCount'],
        ),
      ),
    );
  }
  return result;
}

// ═══════════════════════════════════════════════════════════════════════════
//  当前登录用户的 uid 提取
// ═══════════════════════════════════════════════════════════════════════════

/// 从 Pixiv 页面 HTML 里解析**当前登录用户**的 uid；解析不到返回 null。
///
/// ## 为什么必须从页面解析，而不是从 cookie 读
///
/// 首版从 cookie 键名猜（`pixiv_uid` / `p_uid` / `uid` / `userId` / `user_id`），
/// 真机反馈该猜测**不成立**——Pixiv 并不把 uid 放在这些 cookie 里。
/// 后果不是"收藏少一点"，而是**整条收藏链不可用**：
/// `getBookmarks` 的路径必须带 uid（`/ajax/user/{uid}/illusts/bookmarks`），
/// uid 为空时只能返回 `loginRequired`，于是已登录用户被反复提示"需要登录"，
/// 而重新登录也没用（登录只是换了 PHPSESSID，uid 依旧取不到）。
///
/// ## 采用的做法
///
/// 与 `pixiv-web-api` 的 `findUserId` 同源：登录后拉一次页面 HTML，
/// 用正则从中取 uid。这里按**可靠性排序**匹配多种形态，
/// 因为该站点不保证 HTML 结构稳定，单一正则一旦失配就会退回"未登录"。
///
/// 匹配顺序（先精确后宽松）：
/// 1. `meta[name=global-data]` 里的 `"userData":{"id":"..."}`——Pixiv 页面把
///    当前用户信息塞在这个 meta 的 JSON 里，是**当前用户**语义最强的一处；
/// 2. `dataLayer` 里的 `user_id: "..."`；
/// 3. GA `_setCustomVar ..., 6, 'user_id', "...", ...`；
/// 4. `qualtrics_user-id` 隐藏 span。
///
/// **只返回纯数字**：以上形态里 uid 都是数字串；若匹配到非数字（例如某些
/// 模板会把 `null` 或空串放进去）一律视为没拿到，避免把垃圾当 uid 存下来。
String? parsePixivUserIdFromHtml(String? html) {
  if (html == null || html.isEmpty) return null;

  const patterns = <String>[
    // 1. global-data meta：{"userData":{"id":"123",...}}
    r'"userData"\s*:\s*\{[^}]*?"id"\s*:\s*"(\d+)"',
    // 2. dataLayer: var dataLayer = [{"user_id": "123", ...}]
    r'user_id"\s*:\s*"(\d+)"',
    r"user_id:\s*'(\d+)'",
    // 3. GA custom var（用三引号包裹：正则里同时含单双引号，
    //    raw string 不处理转义，写成 r"...\"..." 会被内部引号提前终止）
    r'''_setCustomVar',\s*6,\s*'user_id',\s*"(\d+)"''',
    // 4. qualtrics 隐藏 span
    r'qualtrics_user-id"[^>]*>\s*(\d+)\s*<',
  ];

  for (final pattern in patterns) {
    final match = RegExp(pattern).firstMatch(html);
    final value = match?.group(1)?.trim() ?? '';
    if (value.isNotEmpty && _isAllDigits(value)) {
      return value;
    }
  }
  return null;
}

bool _isAllDigits(String value) {
  for (final unit in value.codeUnits) {
    if (unit < 0x30 || unit > 0x39) return false;
  }
  return true;
}

// ═══════════════════════════════════════════════════════════════════════════
//  CSRF token 提取（POST 写操作需要）
// ═══════════════════════════════════════════════════════════════════════════

/// 从 Pixiv 页面 HTML 里解析写操作令牌；解析不到返回 null。
///
/// ## 这个令牌是什么（2026-09 用真机 Cookie 打真实请求实测确认）
///
/// Pixiv 对 `/ajax/...` 的**写操作**（收藏增删等）要求请求头带 `X-CSRF-Token`。
/// 该令牌**不在** `<meta name="csrf-token">` 里，而是内嵌在首页 HTML 中一段
/// **被转义过的 JSON 字符串**里：
///
/// ```text
/// "serverSerializedPreloadedState":"{\"ads\":{…},\"api\":{\"token\":\"<32位十六进制>\",…
/// ```
///
/// 注意引号写作 `\"` —— 这段 JSON 是作为**字符串值**嵌在外层 JSON 中的，
/// 所以按普通的 `"token":"…"` 去找永远匹配不到。这正是先前收藏一直失败的原因。
///
/// 同一份 Cookie 的实测结果：
/// - `GET /ajax/user/extra` → **200**，且响应头带 `x-userid`，**会话完全有效**；
/// - 不带令牌 `POST /ajax/illusts/bookmarks/add` → **400** +
///   「请重新登录。如果出现的问题仍未解决，请重新启动浏览器。」；
/// - 带上令牌（值放进 `X-CSRF-Token`）→ **200** `{"error":false,…}`。
///
/// ⚠️ 那句"请重新登录"是**误导性文案**：服务端并没有把请求当成未登录
/// （否则不会返回 `x-userid`），只是在缺令牌时统一这样回。排查时不要被它
/// 带向"重新登录/重建会话"的方向 —— 会话一直是好的。
///
/// ## 匹配形态
///
/// 按优先级：
/// 1. `<meta name="csrf-token" content="…">`（历史形态，两种属性顺序都认）
/// 2. 转义 JSON 里的 `\"api\":{\"token\":\"…\"}` ← **当前真实生效的形态**
/// 3. `"csrfToken"` / `"csrf_token"`
String? parsePixivCsrfTokenFromHtml(String? html) {
  if (html == null || html.isEmpty) return null;

  const patterns = <String>[
    // meta 标签：**两种属性顺序都要认**——HTML 属性顺序是任意的，
    // 真实页面里 content 在前、name 在后同样常见，只写一种顺序会静默失配。
    r'''<meta[^>]+name=["']csrf-token["'][^>]+content=["']([^"']+)["']''',
    r'''<meta[^>]+content=["']([^"']+)["'][^>]+name=["']csrf-token["']''',
    // 当前生效的形态：token 挂在 `api` 对象下，且整段 JSON 被转义成字符串。
    // `\\?` 让每个引号都能兼容 `"` 与 `\"` 两种写法；
    // `[^{}]{0,160}?` 允许 token 不是 api 对象里的第一个字段，但不跨对象匹配。
    r'\\?"api\\?"\s*:\s*\{[^{}]{0,160}?\\?"token\\?"\s*:\s*\\?"([^"\\]{8,})',
    r'"csrfToken"\s*:\s*"([^"]+)"',
    r'"csrf_token"\s*:\s*"([^"]+)"',
  ];

  for (final pattern in patterns) {
    final match = RegExp(pattern, caseSensitive: false).firstMatch(html);
    final value = match?.group(1)?.trim() ?? '';
    if (value.isNotEmpty) return value;
  }
  return null;
}

/// Pixiv 可能用来下发写操作令牌的 cookie 名。
///
/// 实测结论：**当前的 Pixiv 并不用 cookie 承载它**（真机 Cookie 清单里
/// 只有 `PHPSESSID` 等会话项，没有任何 `*csrf*`/`XSRF*`）。这里保留候选名是
/// 为了兼容部署差异，成本只有一次内存查表；真正的来源见
/// [parsePixivCsrfTokenFromHtml] 第 2 条。
const List<String> pixivCsrfCookieNames = <String>[
  'XSRF-TOKEN',
  'XSRF_TOKEN',
  'csrf_token',
  'csrftoken',
  '_csrf',
  'pixiv_csrf_token',
];
