/// 历史记录封面的鉴权头解析。
///
/// ## 为什么需要它
///
/// 真机反馈：历史记录里 **Pixiv 的封面只有占位图**，而 Komiic 的正常。
/// 原因是历史页与「我」页面加载网络封面时走的是**裸 `NetworkImage`**：
/// 不带任何请求头，也不走磁盘缓存。
///
/// Pixiv 的 `i.pximg.net` 有严格防盗链 —— 缺 `Referer` 直接 403，
/// 所以封面永远加载不出来；Komiic 校验宽松，因此看起来"没问题"。
/// 在线列表（搜索页 / 探索页）早就通过 `ComicSource.imageHeadersBuilder`
/// 解决了这件事，历史记录一直没接上这条通道。
library;

import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/def.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/network/base_comic.dart';

/// 已知 [HistoryType] 与 [ComicSource.key] 的对应关系。
///
/// 这些类型用的是**固定编号**（见 `history.dart` 里 `HistoryType` 的静态
/// getter），不是 `sourceKey.hashCode`，所以必须逐个显式列出。
///
/// 没有列出的：`hitomi` / `htmanga` 目前没有内置源实现；
/// `other` / `localAlbum` 不是在线漫画。
String? _sourceKeyForKnownHistoryType(HistoryType type) {
  if (type == HistoryType.picacg) return 'picacg';
  if (type == HistoryType.ehentai) return 'ehentai';
  if (type == HistoryType.jmComic) return 'jm';
  if (type == HistoryType.nhentai) return 'nhentai';
  if (type == HistoryType.pixiv) return 'pixiv';
  return null;
}

/// [History] 条目所属的在线源；本地条目或未知源返回 `null`。
ComicSource? comicSourceForHistory(History item) {
  final knownKey = _sourceKeyForKnownHistoryType(item.type);
  if (knownKey != null) {
    return ComicSource.find(knownKey);
  }
  if (item.type == HistoryType.other || item.type == HistoryType.localAlbum) {
    return null;
  }
  // 自定义源（含 Komiic）：HistoryType 由 `sourceKey.hashCode` 构造
  // （见 `read_history_helper.dart` 的 `_historyTypeForDownload`）。
  //
  // 历史/下载侧的 sourceKey 大小写**不一定**等于 `ComicSource.key`：
  // Komiic 在那边写作 `'Komiic'`、注册表里是 `'komiic'`，hashCode 完全不同，
  // 所以首字母大写的变体也要试一遍。
  for (final key in builtInSources) {
    final candidates = <String>[
      key,
      if (key.isNotEmpty) '${key[0].toUpperCase()}${key.substring(1)}',
    ];
    for (final candidate in candidates) {
      if (HistoryType(candidate.hashCode) == item.type) {
        return ComicSource.find(key);
      }
    }
  }
  return null;
}

/// 历史条目的网络封面鉴权头；源未提供钩子时返回空表（调用方回退裸加载）。
Map<String, String> historyCoverHeaders(History item) {
  final source = comicSourceForHistory(item);
  final builder = source?.imageHeadersBuilder;
  if (source == null || builder == null) {
    return const <String, String>{};
  }
  // 现有所有 `imageHeadersBuilder` 实现都**不使用**传入的 comic
  // （Pixiv / Komiic / nhentai / picacg 是常量，EH 用全局会话，JM 调全局取头），
  // 所以这里用一个只携带封面信息的轻量实体即可。
  return builder(
        CustomComic(
          item.title,
          item.subtitle,
          item.cover,
          item.target,
          const <String>[],
          '',
          source.key,
        ),
      ) ??
      const <String, String>{};
}
