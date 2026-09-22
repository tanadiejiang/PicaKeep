/// 在线列表卡片的公共展示组件（搜索页与探索页共用）。
///
/// 只抽**展示**：封面、标题、作者、标签、来源 id、详情打开。不抽搜索查询状态，
/// 也不新增第二套"按源 if/switch 跳详情"的分支 —— 详情打开统一走
/// [ComicSource.comicPageBuilder]。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';

/// 在线列表卡片的固定高度（164dp 基线，与搜索页/网络收藏页一致）。
const double onlineComicListItemHeight = 164;

/// 封面 provider 实例缓存。
///
/// **必须复用同一实例**：`ImageCache` 以 provider 的 `obtainKey()` 为键，实例抖动
/// 会让缓存命中与释放都不稳定，表现为滚动时反复重新下载与解码 —— 无异常、无日志，
/// 只有体感（这是项目在本地收藏页已经确立的契约，见 `local_favorites.dart` 的
/// `networkCoverProvider`）。键里带 headers 摘要：同一 URL 用不同鉴权头请求在语义上
/// 是不同资源（EH 的表站/里站、不同账号 Cookie 不能互相命中）。
final Map<String, ImageProvider> _coverProviderCache =
    <String, ImageProvider>{};

const int _coverProviderCacheLimit = 128;

/// 测试用：清空封面 provider 缓存。
@visibleForTesting
void clearOnlineCoverProviderCache() => _coverProviderCache.clear();

String _headersKey(Map<String, String> headers) {
  final entries = headers.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join('&')
      .hashCode
      .toString();
}

ImageProvider _cachedCoverProvider(String key, ImageProvider Function() build) {
  final cached = _coverProviderCache[key];
  if (cached != null) return cached;
  // 上限保护：正常浏览远达不到，避免异常数据把缓存撑大。
  if (_coverProviderCache.length >= _coverProviderCacheLimit) {
    _coverProviderCache.remove(_coverProviderCache.keys.first);
  }
  final provider = build();
  _coverProviderCache[key] = provider;
  return provider;
}

/// 封面 imageProvider 构造（带实例缓存）。
///
/// - 源未提供 [ComicSource.imageHeadersBuilder] → 裸 `NetworkImage`；
/// - 钩子返回 `null` 或空 header → 同样回退 `NetworkImage`；
/// - 钩子返回非空 header → 带 header 的 `StreamImageProvider`（走
///   `OnlineImageManager` 的磁盘缓存与 in-flight 去重）。
///
/// 鉴权按**条目自身**构造（EH 用图片链接生成的 headers），不按页面当前源配置
/// 覆盖旧条目的域名。
ImageProvider onlineComicCoverProvider({
  required ComicSource source,
  required BaseComic comic,
}) {
  final url = comic.cover;
  final builder = source.imageHeadersBuilder;
  final headers = builder?.call(comic);
  if (headers == null || headers.isEmpty) {
    return _cachedCoverProvider('plain|$url', () => NetworkImage(url));
  }
  final key = 'auth|$url|${_headersKey(headers)}';
  return _cachedCoverProvider(
    key,
    () => StreamImageProvider.withProgress(
      () => OnlineImageManager.instance.getImage(url, headers: headers),
      url,
    ),
  );
}

/// 在线列表条目卡片。搜索页与探索页共用同一实现，保证两处观感与跳转一致。
class OnlineComicListItem extends StatelessWidget {
  const OnlineComicListItem({
    super.key,
    required this.source,
    required this.comic,
    this.onTap,
    this.trailing,
    this.highlighted = false,
  });

  final ComicSource source;
  final BaseComic comic;

  /// 自定义点击行为；为空时默认打开该源详情页。
  final void Function()? onTap;

  /// 卡片右侧附加内容（探索页用于"已屏蔽"占位说明）。
  final Widget? trailing;

  /// 是否处于高亮态（探索页用于"已屏蔽"占位）。
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final cardConfig = readSearchComicTileDisplayConfig(source.key);
    final authors = resolveSourceAuthors(
      source: source.key,
      flatTags: comic.tags,
      fallbackAuthor: comic.subTitle,
    ).join(', ');
    final infoLine = displaySourceInfoLine(
      source: source.key,
      comicId: comic.id,
      description: comic.description,
      showId: cardConfig.showId && source.key != 'nhentai',
    );

    return SizedBox(
      height: onlineComicListItemHeight,
      // 「已屏蔽」才套一层降低不透明度；未屏蔽时不额外产生合成层
      // （搜索页每个条目都会走到这里，无谓的 Opacity 是纯开销）。
      child: highlighted
          ? Opacity(
              opacity: 0.45,
              child: _buildTile(context, cardConfig, authors, infoLine),
            )
          : _buildTile(context, cardConfig, authors, infoLine),
    );
  }

  Widget _buildTile(
    BuildContext context,
    ComicTileDisplayConfig cardConfig,
    String authors,
    String infoLine,
  ) {
    final tile = DownloadedComicTile(
      favoriteTarget: comic.id,
      favoriteType: switch (source.key) {
        'picacg' => FavoriteType.picacg,
        'jm' => FavoriteType.jm,
        'ehentai' => FavoriteType.ehentai,
        'nhentai' => FavoriteType.nhentai,
        _ => FavoriteType(source.key.hashCode),
      },
      cardDisplayConfig: cardConfig,
      idColorKey: readComicTileDisplaySettings().idColor,
      name: comic.title,
      author: authors,
      imagePath: File(''),
      imageProvider: onlineComicCoverProvider(source: source, comic: comic),
      type: null,
      tag: comic.tags,
      size: infoLine,
      descriptionLeading: source.key == 'nhentai' && cardConfig.showId
          ? Text('ID: ${comic.id}')
          : null,
      onTap: onTap ?? () => openOnlineComic(context, source, comic),
      onLongTap: () {},
      onSecondaryTap: (_) {},
    );
    final trailingWidget = trailing;
    if (trailingWidget == null) return tile;
    // [trailing] 必须**真的渲染**：卡片本身没有该插槽，靠 Stack 叠一个角标。
    // 放在右上角是为了不遮标题/标签/描述/id 这些既有信息位。
    return Stack(
      children: <Widget>[
        tile,
        Positioned(
          top: 4,
          right: 6,
          child: DefaultTextStyle.merge(
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.error,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: trailingWidget,
          ),
        ),
      ],
    );
  }
}

/// 打开在线详情页：统一走源注册的 [ComicSource.comicPageBuilder]。
///
/// 探索页**不得**另写一套按源 switch 的跳详情代码；搜索页与探索页共用本函数。
///
/// 转场统一用 [AppPageRoute]（与搜索页改造前一致）：它有项目统一的滑动转场与
/// 桌面/移动端一致的边缘返回手势；换成 `MaterialPageRoute` 会静默丢掉这两项。
void openOnlineComic(
    BuildContext context, ComicSource source, BaseComic comic) {
  final builder = source.comicPageBuilder;
  if (builder == null) return;
  Navigator.of(context).push(AppPageRoute(builder: (_) => builder(comic)));
}

/// 关键词屏蔽匹配（探索列表展示层用）。
///
/// 语义对照原项目 `comic_tile.dart: isBlocked`：
/// 标题 / 副标题 / 描述 contains，原标签与去 namespace 标签精确匹配，
/// 启用翻译的标签还可匹配译名。
///
/// 返回命中的第一个关键词；未命中返回 null。
String? findBlockingKeyword(
  BaseComic comic, {
  required List<String> keywords,
  String Function(String tag)? translateTag,
}) {
  if (keywords.isEmpty) return null;
  for (final word in keywords) {
    if (word.isEmpty) continue;
    if (comic.title.contains(word)) return word;
    if (comic.subTitle.contains(word)) return word;
    if (comic.description.contains(word)) return word;
    for (var tag in comic.tags) {
      if (tag == word) return word;
      final separator = tag.indexOf(':');
      if (separator > 0) {
        tag = tag.substring(separator + 1);
        if (tag == word) return word;
      }
      if (comic.enableTagsTranslation && translateTag != null) {
        if (translateTag(tag) == word) return word;
      }
    }
  }
  return null;
}

/// 读取当前屏蔽词设置。
List<String> readBlockingKeywords() =>
    List<String>.from(appdata.blockingKeyword);

/// 「完全隐藏屏蔽的作品」开关（settings[83]）。
bool readHideBlockedComics() {
  final settings = appdata.settings;
  if (83 >= settings.length) return false;
  return settings[83] == '1';
}
