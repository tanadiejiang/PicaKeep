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
