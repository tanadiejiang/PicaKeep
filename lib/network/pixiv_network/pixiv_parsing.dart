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

/// 解析搜索结果。
///
/// ## 键名在 2026-09 变过（实测）
///
/// - **当前形状**：`body.illustManga.data` —— 插画与漫画已被 Pixiv **合并**成一份
///   列表（同时只有这一个键，`illust` / `manga` 都不再返回）；
/// - **旧形状**：`body.illust.data` + `body.manga.data` 两段分开。
///
/// 两者都吃，且 `illustManga` 排在最前：只认旧键会让搜索结果**恒为空列表**
/// ——而且是静默的（拿不到 `data` 只当"这页没结果"，不报错），
/// 这种"HTTP 200 + 空列表"比报错难查得多。
///
/// 关键决策：**两种作品类型都要合并**。用户视角里插画与漫画都是"一张一张的图"，
/// 没有理由在列表里丢掉一半结果。
///
/// 去重按 id 只保留**第一个**：同一作品可能同时出现在多个键下，
/// 保留先出现的（`illustManga` 优先）以保证顺序稳定。
List<PixivComicBrief> parsePixivSearchItems(Map<String, dynamic> body) {
  final result = <PixivComicBrief>[];
  final seenIds = <String>{};
  // 顺序即优先级：新形状（已合并）在前，旧形状的两键在后。
  for (final key in const <String>['illustManga', 'illust', 'manga']) {
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

/// 解析首页推荐（`/ajax/illust/discovery`）。
///
/// 入参是 Ajax 响应里的 `body`：`{"illusts":[{…}, …]}` —— **直接是数组**，
/// 不像搜索那样嵌在 `illustManga` / `illust` 之下，因此**不能**复用
/// [parsePixivSearchItems]（那个要求再往下一层有 `data`，直接套会恒得空列表）。
///
/// 条目字段与搜索项同构（`id` / `title` / `url` / `tags` / `userName` /
/// `illustType` / `pageCount`），故复用 [_parseBriefItem]，取值口径与搜索一致；
/// `tags` 实测是**纯字符串数组**（`["a","b"]`），[_parseBriefTags] 已兼容。
///
/// 坏条目（id 缺失或非数字）与重复 id 跳过，与其它列表解析同口径。
/// 本函数绝不抛异常：`illusts` 不是数组（结构再变）时返回空列表，
/// 由调用方按"这页没有内容"处理。
List<PixivComicBrief> parsePixivDiscoveryItems(Map<String, dynamic> body) {
  final illusts = body['illusts'];
  if (illusts is! List) return const <PixivComicBrief>[];
  final result = <PixivComicBrief>[];
  final seenIds = <String>{};
  for (final item in illusts) {
    if (item is! Map) continue;
    final brief = _parseBriefItem(_map(item));
    if (brief == null) continue;
    if (seenIds.add(brief.id)) result.add(brief);
  }
  return result;
}

/// 从搜索结果里推断**末页页码**；找不到返回 null。
///
/// 消费端契约：`subData` 放的是**末页页码**（见 `lib/comic_source/built_in/pixiv.dart`
/// 的 `searchPageData` 注释），搜索页据此判停。
///
/// ## 为什么只认 `lastPage`
///
/// 页数字段在不同版本/灰度下位置会变，所以做**防御式解析**（在几个可能的位置找
/// `lastPage`）；当前实测位置是 `body.illustManga.lastPage`（= 10）。
///
/// **`total` 绝不能当页数候选**：它是**总条数**（实测 `illustManga.total = 619617`）。
/// 旧实现把 `total` 与 `lastPage` 放在一起"取最大值"，真取到就会把末页算成
/// 61 万页、让用户永远翻不到底。当时之所以没暴露，只是因为调用方传错了层级
/// （传的是整个响应而不是 `body`），任何键都取不到、恒返回 null —— 修层级时
/// 必须同时修掉这个隐患，否则会把它从"不生效"变成"生效但错得离谱"。
///
/// 约定：本函数**绝不抛异常**，结构完全变化时也只是返回 null
/// ——调用方退回保守判停（"本页不足 N 条即停"）。
int? parsePixivSearchMaxPage(Map<String, dynamic> body) {
  int? best;

  void considerPage(dynamic value) {
    final parsed = _int(value, -1);
    if (parsed <= 0) return;
    if (best == null || parsed > best!) best = parsed;
  }

  void considerMap(dynamic node) {
    final map = _map(node);
    considerPage(map['lastPage']);
    // 部分结构把分页信息再包一层。
    considerPage(_map(map['pagination'])['lastPage']);
  }

  // `illustManga` 是当前形状（合并列表），旧形状的 `illust` / `manga` 一并保留。
  for (final key in const <String>['illustManga', 'illust', 'manga']) {
    considerMap(body[key]);
    considerMap(_map(body[key])['page']);
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

// ═══════════════════════════════════════════════════════════════════════════
//  作者页（App 内）三步链路的解析
//
//  链路（端点依据 PixivFE v3.0.3 的 core/endpoints.go + core/user.go）：
//  1. `GET /ajax/user/{uid}?full=1`            → 作者资料（本文件的 parsePixivAuthorInfo）
//  2. `GET /ajax/user/{uid}/profile/all`       → 全部作品 id（parsePixivUserWorkIds）
//  3. `GET /ajax/user/{uid}/profile/illusts?work_category=illustManga&is_first_page=0
//     &lang=zh&ids[]=<id>…`                    → 这些 id 的作品详情（parsePixivUserWorks）
//
//  ⚠️ 第 3 步的 `ids[]`（复数、GET）**尚未真机验证**：它来自仍在维护的
//  PixivFE 实现，而不是本项目真机实测。因此本文件的解析函数一律
//  **收窄失败面**：形状不符时宁可抛/返回空并让网络层带上形状报错，
//  也不要静默当成"没有作品"（诊断见 [describePixivJsonShape]）。
// ═══════════════════════════════════════════════════════════════════════════

/// 把简介里的 `\r\n` / `\r` 统一成 `\n` 并折叠多余空行。
///
/// Pixiv 的 `comment` 是**纯文本**但换行符是 CRLF（实测样例带 `\r\n`）。
/// 直接交给 `Text` 虽然不会报错，但行高会因残留 `\r` 出现异常，
/// 且这里的折叠规则要与 [stripPixivHtml] 的收尾保持一致（同一份简介，
/// 走纯文本分支与走 HTML 分支应当显示成同一个样子）。
String _normalizePlainComment(String raw) {
  if (raw.isEmpty) return '';
  var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return text.trim();
}

/// 解析作者资料：入参是 `/ajax/user/{uid}?full=1` 响应里的 `body` 对象。
///
/// 字段口径（已对齐样例响应）：
/// - id：`userId`，回退 `id`；
/// - 名：`name`，回退 `userName`；
/// - 头像：`imageBig`（170px）优先，回退 `image`（50px）——
///   作者页头像要显示 48~64dp，50px 会明显糊；
/// - 简介：`comment`（纯文本）优先；为空才用 `commentHtml` 并清洗 HTML；
/// - 关注数：`following`。
///
/// **唯一抛 [FormatException] 的情况**：id 与 name 同时缺失（这条响应不可能是
/// 有效用户）；其余字段一律兜底。
PixivAuthor parsePixivAuthorInfo(Map<String, dynamic> body) {
  final id = _firstNonEmpty(<dynamic>[body['userId'], body['id']]);
  final name = _firstNonEmpty(<dynamic>[body['name'], body['userName']]);
  if (id.isEmpty && name.isEmpty) {
    throw const FormatException('Pixiv user 响应缺少 userId 与 name');
  }
  final plainComment = _str(body['comment']);
  return PixivAuthor(
    id: id,
    name: name,
    avatar: _firstNonEmpty(<dynamic>[body['imageBig'], body['image']]),
    comment: plainComment.isNotEmpty
        ? _normalizePlainComment(plainComment)
        : stripPixivHtml(_str(body['commentHtml'])),
    following: _int(body['following']),
  );
}

/// `profile/all` 里的 id 容器是不是我们认识的形状（诊断用）。
///
/// 认识两种：`{ "123": null }` 这样的 **Map**（当前真实形状），以及某些
/// 版本/代理拍平后的 **List**。`null` 也算"认识"（该用户没有这一类作品）。
/// 其它类型（字符串/数字/布尔）一律视为**形状变化**，由调用方如实报出来。
bool isPixivWorkIdContainer(dynamic raw) =>
    raw == null || raw is Map || raw is List;

/// 解析「该用户的全部作品 id」：入参是 `/ajax/user/{uid}/profile/all` 的 `body`。
///
/// 形状：`body.illusts` 与 `body.manga` 都是 `{ "<id>": null, ... }` 的 **map**
/// ——值恒为 null，**键才是数据**；因此取值走键遍历而不是值遍历（写成
/// `for (final v in map.values)` 会永远拿不到 id）。
///
/// 三个决策：
/// 1. **插画与漫画合并**：与 [parsePixivSearchItems] 的"两类都算作品"一致，
///    用户视角里都是一张一张的图，没理由在作者页丢掉一半；
/// 2. **按 id 数值倒序**输出，**不依赖 map 的键顺序**：JSON 对象顺序在接口版本
///    间变过（老样例是新作在前，但没有契约保证），PixivFE 也是显式排序；
/// 3. 只保留纯数字 id（坏键跳过），与项目"坏条目跳过而非塞空 id"的口径一致。
List<String> parsePixivUserWorkIds(Map<String, dynamic> body) {
  final ids = <String>{};

  void collect(dynamic container) {
    if (container is Map) {
      for (final key in container.keys) {
        final id = _idStr(key);
        if (id.isNotEmpty && int.tryParse(id) != null) ids.add(id);
      }
    } else if (container is List) {
      for (final item in container) {
        // List 形态：可能是 id 数组，也可能是 `{id: ...}` 对象数组。
        final bare = _idStr(item);
        final fromMap = item is Map ? _idStr(_map(item)['id']) : '';
        final id = bare.isNotEmpty ? bare : fromMap;
        if (id.isNotEmpty && int.tryParse(id) != null) ids.add(id);
      }
    }
  }

  collect(body['illusts']);
  collect(body['manga']);

  final result = ids.toList();
  result.sort((a, b) => _compareIdDesc(a, b));
  return result;
}

/// 解析「按 id 批量取回的作品详情」：
/// 入参是 `/ajax/user/{uid}/profile/illusts` 响应里的 `body` 对象。
///
/// 主形状：`body.works` 是 `{ "<id>": {作品对象}, ... }` 的 **map**（不是数组，
/// 这点与搜索/书签的 `data`/`works` **数组**不同——写成数组遍历会一条都拿不到）。
/// 兼容数组形态（个别版本/代理会拍平）；单项字段与搜索项同构，因此复用
/// [_parseBriefItem]，不另写一套取值逻辑。
///
/// 坏条目（id 缺失或非数字）跳过，输出按 id 数值倒序 ——
/// 让"第 N 页"的边界在服务端返回顺序变化时仍保持稳定。
List<PixivComicBrief> parsePixivUserWorks(Map<String, dynamic> body) {
  final works = body['works'];
  final result = <PixivComicBrief>[];
  final seenIds = <String>{};

  void addItem(dynamic item) {
    if (item is! Map) return;
    final brief = _parseBriefItem(_map(item));
    if (brief == null) return;
    if (seenIds.add(brief.id)) result.add(brief);
  }

  if (works is Map) {
    for (final value in works.values) {
      addItem(value);
    }
  } else if (works is List) {
    for (final item in works) {
      addItem(item);
    }
  }

  result.sort((a, b) => _compareIdDesc(a.id, b.id));
  return result;
}

/// 纯数字 id 的**数值**倒序比较（非数字/超长串退回字符串比较，保证全序稳定）。
///
/// 不用字符串比较的原因：`"9" > "10"`，字符串序会把老作品排到前面。
int _compareIdDesc(String a, String b) {
  final left = int.tryParse(a);
  final right = int.tryParse(b);
  if (left != null && right != null) return right.compareTo(left);
  return b.compareTo(a);
}

/// 描述一个 JSON 值**实际长什么样**：类型 + （Map/List 时）键名或长度。
///
/// 只用于**报错文案**，因而必须是纯函数、可单测、且绝不抛。
/// 存在的理由：作者页三步链路里第 3 步未经真机验证，一旦"HTTP 200 但形状变了"，
/// 日志里必须能直接看到"实际拿到的是什么"，否则只剩一句"加载失败"，
/// 排查只能靠猜（见 07 号 Komiic 那次的教训）。
String describePixivJsonShape(dynamic value, {int maxKeys = 10}) {
  if (value == null) return 'null';
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList();
    final shown = keys.take(maxKeys).join(', ');
    final suffix = keys.length > maxKeys ? ', …(+${keys.length - maxKeys})' : '';
    return 'Map(键: $shown$suffix)';
  }
  if (value is List) {
    final head = value.take(2).map(describePixivJsonShape).join(', ');
    return 'List(长度 ${value.length}${value.isEmpty ? '' : '; 首项: $head'})';
  }
  if (value is String) {
    final text = value.trim();
    return 'String("${text.length <= 40 ? text : '${text.substring(0, 40)}…'}")';
  }
  return '${value.runtimeType}';
}

