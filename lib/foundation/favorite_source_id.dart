/// 本地收藏 / 下载条目的「来源标识（target）」解析与校验。
///
/// 放在 foundation 层的原因：这些是**纯字符串规则**，同时被两个方向使用——
/// - 页面层（本地详情页的"更新信息"、本地收藏的"更新卡片信息"入口）；
/// - 来源层（各源 `FavoriteData.loadComicInfo` 实现，见 `comic_source/built_in/`）。
///
/// 来源层不能依赖页面文件，所以规则必须留在两者都能引用的地方。页面层原有的
/// 同名函数（`extractJmNumericId` 等）继续保留其签名与语义，内部与本模块一致：
/// 同一套 id 形态判断不允许出现两种口径。
library;

/// JM 的数值 id；非纯数字（含 `jm` 前缀的历史形态可接受）返回 null。
///
/// 返回 null 表示"这条记录的 id 不可用"，调用方必须**拦截并不发起请求** ——
/// 直接把空/非法 id 打到服务端会命中通用兜底错误，文案对用户毫无意义。
String? extractJmNumericId(String rawId) {
  final id = rawId.trim();
  final numericId = id.startsWith('jm') ? id.substring(2) : id;
  if (numericId.isEmpty || !RegExp(r'^\d+$').hasMatch(numericId)) {
    return null;
  }
  return numericId;
}

/// NHentai 的数值 id；非纯数字（含 `nhentai` 前缀的历史形态可接受）返回 null。
String? extractNhentaiNumericId(String rawId) {
  final id = rawId.trim();
  final numericId = id.startsWith('nhentai') ? id.substring(7) : id;
  if (numericId.isEmpty || !RegExp(r'^\d+$').hasMatch(numericId)) {
    return null;
  }
  return numericId;
}

/// 从 Pixiv 的 target / 下载 id / 链接里提取纯数字 illust ID。
///
/// 支持形态：
/// - `12345678`（裸 ID）
/// - `pixiv12345678`（下载 id 前缀形态）
/// - `https://www.pixiv.net/artworks/12345678`（作品页链接）
/// - `https://www.pixiv.net/en/artworks/12345678`（带语言段的链接）
/// - `https://www.pixiv.net/artworks/12345678#1`（带页锚点）
/// 返回 null 表示提取不到。
///
/// 与 [extractJmNumericId] / [extractNhentaiNumericId] 的差别：Pixiv 的本地
/// 条目既可能是裸 id，也可能是从 Web 复制来的**完整作品链接**（用户分享链接、
/// 浏览器收藏等），因此这里比另外两个多一条"链接里挖 artworks/id"的规则。
String? extractPixivNumericId(String? target) {
  final text = target?.trim() ?? '';
  if (text.isEmpty) return null;

  // 整体形态：裸 id 或 `pixiv` 前缀的下载 id。大小写不敏感，
  // 因为下载 id 由不同入口生成，出现过 `Pixiv123` 这样的写法。
  final bare =
      RegExp(r'^(?:pixiv)?(\d+)$', caseSensitive: false).firstMatch(text);
  if (bare != null) return bare.group(1);

  // 链接形态：`artworks/{数字}`。不锚定路径首段——Pixiv 会在语言段
  // （`/en/artworks/...`）后再拼路径，锚首段会漏掉这类链接。
  final inPath =
      RegExp(r'artworks/(\d+)', caseSensitive: false).firstMatch(text);
  if (inPath != null) return inPath.group(1);

  // 锚点形态：`...#1`（阅读器页锚点）会挡住上面的匹配吗？不会——正则本身
  // 不锚定结尾。这里再兜一次是因为 `#` 之后**也可能**跟着 artworks 片段
  // （少见但合法），去掉锚点后重跑上面两条规则。
  final hashIndex = text.indexOf('#');
  if (hashIndex > 0) {
    return extractPixivNumericId(text.substring(0, hashIndex));
  }

  return null;
}

/// 校验一个字符串是不是合法的 E-Hentai / ExHentai 画廊链接。
///
/// 合法则原样返回（去掉首尾空白），否则返回 null。
///
/// 为什么不接受 `gid-token` 形态：那串本地 id 缺少域名，无法反向拼出可请求的
/// 链接，猜测域名会把请求打到不存在的地址。调用方应把它归类为"链接不可用"。
///
/// 白名单与本地详情页 `resolveEhGalleryLink` 的判定一致（同一套规则）。
String? normalizeEhGalleryLink(String rawLink) {
  final link = rawLink.trim();
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
