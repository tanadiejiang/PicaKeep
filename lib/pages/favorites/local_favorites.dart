import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/components/local_favorite_update_dialog.dart';
import 'package:picakeep/components/scrollable.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_favorites_update.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/pages/download_page.dart';
import 'package:picakeep/pages/local_comic_detail_page.dart';
import 'package:picakeep/pages/local_search_page.dart';
// 本地收藏也承载"网络来源"条目（网络收藏转存 / 在线详情页收藏），这类条目没有
// 本地文件，点击时必须降级到对应源的在线详情页，故需要这四个页面入口。
import 'package:picakeep/pages/online_comic/eh_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/jm_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/nhentai_comic_page_v2.dart';
import 'package:picakeep/pages/online_comic/picacg_comic_page_v2.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';
import 'package:picakeep/tools/read_history_helper.dart';
import 'package:picakeep/tools/tags_translation.dart';
import 'package:picakeep/tools/translations.dart';

// ============================================================
// OpenFavoriteComicHelper — reusable comic opener
// ============================================================

/// 打开本地收藏条目的目标解析结果。
///
/// 本地收藏的卡片承载两类条目：①从本地下载加入的（有本地资源）；②从网络收藏
/// 转存 / 在线详情页收藏的（**没有本地资源**）。后者没有可打开的本地文件，
/// 必须降级到对应源的在线详情页，而不是静默失败。
sealed class FavoriteOpenTarget {
  const FavoriteOpenTarget();
}

/// 本地命中：正常打开本地详情页。
class FavoriteOpenLocal extends FavoriteOpenTarget {
  const FavoriteOpenLocal(this.item);
  final DownloadedItem item;
}

/// 本地未命中：降级到在线详情页。
class FavoriteOpenOnline extends FavoriteOpenTarget {
  const FavoriteOpenOnline(this.page);
  final Widget page;
}

/// 既没有本地资源、也无法确定在线来源（无网络层的源 / id 形态不可用）。
class FavoriteOpenUnavailable extends FavoriteOpenTarget {
  const FavoriteOpenUnavailable(this.reason);
  final String reason;
}

/// 可请求的在线目标：源类型 + 该源接口需要的标识。
class OnlineTargetSpec {
  const OnlineTargetSpec(this.kind, this.id);
  final FavoriteType kind;
  final String id;
}

/// 判断 [target]（`FavoriteItem.target`）能否请求对应源的详情。
///
/// 各源 target 的真实形态（真机 `local_favorite.db` 已验证）：
/// jm/nhentai 为纯数字、picacg 为 ObjectId、ehentai 为完整 URL。
/// 返回 null 表示该组合不可用（含无网络层的源）。
/// 纯函数，便于单测覆盖 U03/U04。
OnlineTargetSpec? resolveOnlineTargetSpec(String target, FavoriteType type) {
  final raw = target.trim();
  if (raw.isEmpty) return null;
  if (type == FavoriteType.jm) {
    final numeric = extractJmNumericId(raw);
    return numeric == null ? null : OnlineTargetSpec(type, numeric);
  }
  if (type == FavoriteType.nhentai) {
    final numeric = extractNhentaiNumericId(raw);
    return numeric == null ? null : OnlineTargetSpec(type, numeric);
  }
  if (type == FavoriteType.picacg) {
    return OnlineTargetSpec(type, raw);
  }
  if (type == FavoriteType.ehentai) {
    // 只接受 e-hentai/exhentai 域名下形如 /g/<gid>/<token> 的完整画廊链接；
    // 历史的 `gid-token` 形态无法直接请求，归为"链接不可用"而不是猜测还原。
    // 域名白名单与 local_comic_detail_page.dart 的 resolveEhGalleryLink 保持一致，
    // 避免把任意外站 URL 当成可请求的画廊。
    final uri = Uri.tryParse(raw);
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
    return OnlineTargetSpec(type, raw);
  }
  // hitomi / htmanga / copyManga / komiic / 自定义源：项目内无网络层。
  return null;
}

/// 由在线目标构造对应的详情页。纯函数，便于单测覆盖 U03/U04。
Widget? buildOnlineComicPage(OnlineTargetSpec spec) {
  if (spec.kind == FavoriteType.jm) return JmComicPageV2(spec.id);
  if (spec.kind == FavoriteType.nhentai) return NhentaiComicPageV2(spec.id);
  if (spec.kind == FavoriteType.picacg) return PicacgComicPageV2(spec.id);
  if (spec.kind == FavoriteType.ehentai) return EhentaiComicPageV2(spec.id);
  return null;
}

/// 本地收藏卡片的封面图片源解析结果。
///
/// 规则（用户实测确立）：**本地取到就用本地，取不到就用网络**。
/// `cover_path` 字段在网络来源条目上恒为网络 URL（真机已验证），而本地下载
/// 条目可能取不到可用封面文件——因此**"是否已下载"不得作为封面来源的判据**，
/// 否则已下载但本地封面缺失的条目会一直显示破图。
class FavoriteCoverSource {
  const FavoriteCoverSource({this.file, this.networkUrl});

  /// 本地封面文件；为空串表示本地未命中。
  final File? file;

  /// 兜底网络封面 URL；为空表示该条目没有可用的网络封面。
  final String? networkUrl;
}

/// 解析封面来源。纯函数，便于单测覆盖 U01/U01b/U01c/U02。
FavoriteCoverSource resolveFavoriteCoverSource({
  required File? localCover,
  required String coverPath,
}) {
  final local = localCover;
  if (local != null && local.path.isNotEmpty) {
    return FavoriteCoverSource(file: local);
  }
  final raw = coverPath.trim();
  if (raw.startsWith('http://') || raw.startsWith('https://')) {
    return FavoriteCoverSource(networkUrl: raw);
  }
  return const FavoriteCoverSource();
}

/// 本地收藏卡片的**网络**封面图 Provider。
///
/// 为什么不用 `NetworkImage`：它只依赖 Flutter 的内存 `ImageCache`，条目滚出
/// 视口被挤出缓存后，再次滚入会**重新发起网络请求并按原图全尺寸解码**，表现
/// 为"每次滚动到该处都卡"。本项目已有带磁盘缓存的网络图设施，这里接上去：
///
/// - 走 [OnlineImageManager]：**磁盘缓存**（`OnlineImageCache`）+ in-flight
///   去重，滚回来不再重新下载；
/// - [targetDecodeWidth] 按封面显示尺寸缩放解码，避免把整张原图解码到内存
///   （原尺寸解码是滚动卡顿的主因之一）；
/// - `cacheRawBytes = false`：已有磁盘缓存兜底，原始压缩字节不再驻留堆上，
///   减少老年代 GC 压力（与 `BaseImageProvider` 的既有约定一致）；
/// - key 为 URL，配合基类基于 key 的 `==`/`hashCode`，相同 URL 稳定命中。
class LocalFavoriteCoverProvider extends StreamImageProvider {
  LocalFavoriteCoverProvider(this.url, {this.headers})
      : super(
          () =>
              OnlineImageManager.instance.getImageBytes(url, headers: headers),
          url,
        );

  final String url;
  final Map<String, String>? headers;

  /// 封面在列表中的显示宽度约 110dp；按最宽设备像素比 3.0 计约 330px，
  /// 取 400 留余量，既显著小于原图（常见 1080px 宽），又不至于糊。
  static const int coverDecodeWidth = 400;

  @override
  int? get targetDecodeWidth => coverDecodeWidth;

  @override
  bool get cacheRawBytes => false;
}

/// 单个标签的翻译（带回退）。**顶层纯函数 + 缓存**，便于单测。
///
/// 缓存必要性：原实现对全部翻译表做线性扫描、每条比较调两次 `toLowerCase()`；
/// profile 实测它是收藏页最大的 CPU 热点（`_translateTag` 12~19% +
/// `toLowerCase` 14~24%）。翻译表是静态数据，同一标签结果恒定，可安全缓存。
final Map<String, String> _tagTranslationCache = {};

@visibleForTesting
String translateFavoriteTag(String tag) {
  final cached = _tagTranslationCache[tag];
  if (cached != null) return cached;
  var result = tag;
  try {
    final lower = tag.toLowerCase();
    outer:
    for (final map in tagTranslations.values) {
      for (final entry in map.entries) {
        if (entry.key.toLowerCase() == lower) {
          result = entry.value.isNotEmpty ? entry.value : tag;
          break outer;
        }
      }
    }
  } catch (_) {}
  // 上限保护：正常浏览远达不到，防止异常数据把缓存撑大。
  if (_tagTranslationCache.length >= 4096) {
    _tagTranslationCache.clear();
  }
  _tagTranslationCache[tag] = result;
  return result;
}

@visibleForTesting
void clearFavoriteTagTranslationCache() => _tagTranslationCache.clear();

/// 整个标签列表的翻译结果缓存（键为原始标签序列）。
final Map<String, List<String>> _generatedTagsCache = {};

@visibleForTesting
void clearGeneratedFavoriteTagsCache() => _generatedTagsCache.clear();

class OpenFavoriteComicHelper {
  static Future<DownloadedItem?> _resolveDownloadedItem(
      FavoriteItem comic) async {
    final candidates = comic.candidateDownloadIds();
    try {
      final localItem =
          await LocalLibraryManager().findByCandidates(candidates);
      if (localItem != null) {
        return localItem;
      }
    } catch (_) {}

    if (!await LocalLibraryManager().shouldUseDirectCurrentDownloadManager()) {
      return null;
    }

    final dm = DownloadManager();
    await dm.init();
    final resolvedId = dm.resolveExistingId(candidates);
    if (resolvedId == null) {
      return null;
    }
    return await dm.getComicOrNullFromCandidates(candidates);
  }

  /// 解析打开目标：本地优先，本地没有则降级到在线详情页。
  ///
  /// **这是本计划的核心分支**：原实现"找不到本地就直接失败"，导致网络来源条目
  /// 点击无反应；现在改为按源打开在线详情页。本地命中时的行为一字未改。
  static Future<FavoriteOpenTarget> resolveOpenTarget(
      FavoriteItem comic) async {
    final local = await _resolveDownloadedItem(comic);
    if (local != null) {
      return FavoriteOpenLocal(local);
    }
    final spec = resolveOnlineTargetSpec(comic.target, comic.type);
    if (spec == null) {
      return FavoriteOpenUnavailable(
        comic.type == FavoriteType.jm ||
                comic.type == FavoriteType.nhentai ||
                comic.type == FavoriteType.picacg ||
                comic.type == FavoriteType.ehentai
            ? '该条目没有本地下载，且在线标识不可用'
            : '该条目没有本地下载，且其来源暂不支持在线打开',
      );
    }
    final page = buildOnlineComicPage(spec);
    if (page == null) {
      return const FavoriteOpenUnavailable('该条目没有本地下载，且其来源暂不支持在线打开');
    }
    return FavoriteOpenOnline(page);
  }

  /// 显示失败/降级提示。
  ///
  /// 走 [App.globalContext]：收藏页与它在同一棵 MaterialApp 下，解析到的是
  /// **同一个** ScaffoldMessenger，因此提示会显示在当前页面上，与传页面
  /// context 行为一致；同时避免 `use_build_context_synchronously`
  /// （本类方法都在 await 之后调用它，传页面 context 必然触发该 lint）。
  static void _notify(String message) {
    final ctx = App.globalContext;
    if (ctx == null || !ctx.mounted) return;
    ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// 打开条目：本地优先；本地未命中则进在线详情页；都不可用才提示。
  static Future<void> open(FavoriteItem comic) async {
    try {
      final target = await resolveOpenTarget(comic);
      switch (target) {
        case FavoriteOpenLocal(:final item):
          App.pushInner(() => LocalComicDetailPage(comic: item));
        case FavoriteOpenOnline(:final page):
          App.pushInner(() => page);
        case FavoriteOpenUnavailable(:final reason):
          _notify(reason);
      }
    } catch (e) {
      _notify('打开失败: $e');
    }
  }

  /// 阅读条目：本地命中则读本地（原行为）；本地未命中时**与点击一致**地进入
  /// 在线详情页（用户可在该页阅读或下载），而不是静默失败。
  static Future<void> read(FavoriteItem comic) async {
    try {
      final target = await resolveOpenTarget(comic);
      switch (target) {
        case FavoriteOpenLocal(:final item):
          await ensureHistoryBeforeRead(
            item,
            legacyTargets: comic.candidateDownloadIds(),
          );
          await item.read();
        case FavoriteOpenOnline(:final page):
          App.pushInner(() => page);
        case FavoriteOpenUnavailable(:final reason):
          _notify(reason);
      }
    } catch (e) {
      _notify('打开失败: $e');
    }
  }
}

// ============================================================
// LocalFavoriteTile — matches PicaComic's LocalFavoriteTile
// ============================================================

class LocalFavoriteTile extends StatelessWidget {
  const LocalFavoriteTile({
    super.key,
    required this.comic,
    required this.folderName,
    required this.onDelete,
    required this.enableLongPressed,
    this.onTap,
    this.onLongPressed,
  });

  final FavoriteItem comic;
  final String folderName;
  final VoidCallback onDelete;
  final bool enableLongPressed;
  final bool Function()? onTap;
  final VoidCallback? onLongPressed;

  static final Map<String, File> _coverCache = {};

  /// 网络封面 provider 缓存：**必须复用同一个 provider 实例**，否则每次
  /// rebuild 都新建 `ImageProvider`，`ImageCache` 的命中与释放都会抖动，
  /// 表现为滚动反复重新加载。上限 128 条（收藏夹通常远小于此）。
  static final Map<String, LocalFavoriteCoverProvider> _networkCoverCache = {};

  static void clearCoverCache() {
    _coverCache.clear();
    _networkCoverCache.clear();
    clearFavoriteTagTranslationCache();
    clearGeneratedFavoriteTagsCache();
  }

  /// 取（并缓存）指定 URL 的网络封面 provider。
  static LocalFavoriteCoverProvider networkCoverProvider(String url) {
    final cached = _networkCoverCache[url];
    if (cached != null) return cached;
    if (_networkCoverCache.length >= 128) {
      _networkCoverCache.remove(_networkCoverCache.keys.first);
    }
    final provider = LocalFavoriteCoverProvider(url);
    _networkCoverCache[url] = provider;
    return provider;
  }

  String get _coverCacheKey => '${comic.type.key}_${comic.target}';

  // ---- badge ----
  bool get _isDownloaded {
    try {
      final candidates = comic.candidateDownloadIds();
      final localItem =
          LocalLibraryManager().findCachedByCandidates(candidates);
      if (localItem != null) {
        return true;
      }
      final dm = DownloadManager();
      return dm.resolveExistingId(candidates) != null;
    } catch (_) {
      return false;
    }
  }

  String? get badge => _isDownloaded ? '已下载'.tl : null;

  String get description => '${comic.time} | ${comic.type.name}';

  String get comicId => comic.toDownloadId();

  // ---- cover image ----
  File get _coverFile {
    final cached = _coverCache[_coverCacheKey];
    if (cached != null) {
      return cached;
    }

    final p = comic.coverPath.trim();
    if (p.isNotEmpty) {
      final f = File(p);
      if (f.existsSync()) {
        _coverCache[_coverCacheKey] = f;
        return f;
      }
    }

    final localItem = LocalLibraryManager()
        .findCachedByCandidates(comic.candidateDownloadIds());
    if (localItem != null) {
      final localCoverPath = localItem.localCoverPath?.trim();
      if (localCoverPath != null && localCoverPath.isNotEmpty) {
        final localCover = File(localCoverPath);
        if (localCover.existsSync()) {
          _coverCache[_coverCacheKey] = localCover;
          return localCover;
        }
      }
    }

    try {
      final file = DownloadManager()
          .getCoverFromCandidates(comic.candidateDownloadIds());
      if (file.path.isNotEmpty) {
        _coverCache[_coverCacheKey] = file;
      }
      return file;
    } catch (_) {
      return File('');
    }
  }

  // ---- tags (Chinese translation) ----
  /// 标签列表翻译。整体结果也缓存（键为原始标签序列），避免每帧重建列表。
  /// 单标签翻译见顶层 [translateFavoriteTag]（那里是本页最大的 CPU 热点）。
  List<String> _generateTags(List<String> tags) {
    if (App.locale.languageCode != 'zh') return tags;
    final cacheKey = tags.join('\u0001');
    final cached = _generatedTagsCache[cacheKey];
    if (cached != null) return cached;
    final res = <String>[];
    final res2 = <String>[];
    for (var tag in tags) {
      if (tag.contains(':')) {
        final splits = tag.split(':');
        const lowLevelKey = ['character', 'artist', 'cosplayer', 'group'];
        if (lowLevelKey.contains(splits[0])) {
          res2.add(translateFavoriteTag(splits[1]));
        } else {
          res.add(translateFavoriteTag(splits[1]));
        }
      } else {
        var name = tag;
        if (name.contains('♀')) {
          name = '${translateFavoriteTag(name.replaceFirst(' ♀', ''))}♀';
        } else if (name.contains('♂')) {
          name = '${translateFavoriteTag(name.replaceFirst(' ♂', ''))}♂';
        } else {
          name = translateFavoriteTag(name);
        }
        res.add(name);
      }
    }
    final result = res + res2;
    if (_generatedTagsCache.length >= 512) {
      _generatedTagsCache.clear();
    }
    _generatedTagsCache[cacheKey] = result;
    return result;
  }

  // ---- open comic ----
  Future<void> _openComic() => OpenFavoriteComicHelper.open(comic);

  Future<void> _read() => OpenFavoriteComicHelper.read(comic);

  // ---- copy to folder ----
  void _copyTo() {
    String? folder;
    showDialog(
      context: App.globalContext!,
      builder: (ctx) => SimpleDialog(
        title: Text('复制到'.tl),
        children: [
          SizedBox(
            width: 280,
            height: 132,
            child: Column(
              children: [
                ListTile(
                  title: Text('收藏夹'.tl),
                  trailing: DropdownButton<String?>(
                    value: folder,
                    hint: const Text('选择文件夹'),
                    items: LocalFavoritesManager()
                        .folderNames
                        .map((f) => DropdownMenuItem(
                              value: f,
                              child: Text(f),
                            ))
                        .toList(),
                    onChanged: (v) {
                      folder = v;
                      (ctx as Element).markNeedsBuild();
                    },
                  ),
                ),
                const Spacer(),
                Center(
                  child: FilledButton(
                    child: Text('确认'.tl),
                    onPressed: () {
                      if (folder != null) {
                        LocalFavoritesManager().addComic(folder!, comic);
                        Navigator.pop(ctx);
                      }
                    },
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- edit tags ----
  void _editTags() {
    showDialog(
      context: App.globalContext!,
      builder: (ctx) {
        var tags = List<String>.from(comic.tags);
        final controller = TextEditingController();
        return StatefulBuilder(
          builder: (context, setState) => SimpleDialog(
            title: Text('编辑标签'.tl),
            children: [
              SizedBox(
                width: 400,
                child: Column(
                  children: [
                    Wrap(
                      children: tags
                          .map((e) => Container(
                                margin: const EdgeInsets.all(4),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .secondaryContainer,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(e),
                                    const SizedBox(width: 4),
                                    InkWell(
                                      borderRadius: BorderRadius.circular(10),
                                      child: const Icon(Icons.close, size: 20),
                                      onTap: () {
                                        tags.remove(e);
                                        setState(() {});
                                      },
                                    ),
                                  ],
                                ),
                              ))
                          .toList(),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 56,
                      child: TextField(
                        controller: controller,
                        decoration: InputDecoration(
                          border: const UnderlineInputBorder(),
                          suffix: IconButton(
                            icon: const Icon(Icons.add),
                            onPressed: () {
                              final value = controller.text;
                              if (value.isNotEmpty) {
                                controller.clear();
                                tags.add(value);
                                setState(() {});
                              }
                            },
                          ),
                        ),
                        onSubmitted: (value) {
                          if (value.isNotEmpty) {
                            tags.add(value);
                            controller.clear();
                            setState(() {});
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: FilledButton(
                        onPressed: () {
                          LocalFavoritesManager()
                              .editTags(comic.target, folderName, tags);
                          Navigator.pop(ctx);
                          onDelete();
                        },
                        child: Text('提交'.tl),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---- long-press dialog (matches PicaComic's showMenu) ----
  void _showLongPressMenu() {
    showDialog(
      context: App.globalContext!,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: SelectableText(
                  comic.name.replaceAll('\n', ''),
                  style: const TextStyle(fontSize: 22),
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.article),
                title: Text('查看详情'.tl),
                onTap: () {
                  Navigator.pop(ctx);
                  _openComic();
                },
              ),
              ListTile(
                leading: const Icon(Icons.bookmark_remove),
                title: Text('取消收藏'.tl),
                onTap: () {
                  Navigator.pop(ctx);
                  LocalFavoritesManager().deleteComic(folderName, comic);
                  onDelete();
                },
              ),
              ListTile(
                leading: const Icon(Icons.chrome_reader_mode_rounded),
                title: Text('阅读'.tl),
                onTap: () {
                  Navigator.pop(ctx);
                  _read();
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy),
                title: Text('复制到'.tl),
                onTap: () {
                  Navigator.pop(ctx);
                  _copyTo();
                },
              ),
              ListTile(
                leading: const Icon(Icons.edit_note),
                title: Text('编辑标签'.tl),
                onTap: () {
                  Navigator.pop(ctx);
                  _editTags();
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  // ---- right-click menu ----
  void _showDesktopMenu(TapDownDetails details) {
    final offset = details.globalPosition;
    showMenu(
      context: App.globalContext!,
      position:
          RelativeRect.fromLTRB(offset.dx, offset.dy, offset.dx, offset.dy),
      items: [
        PopupMenuItem(
          onTap: _read,
          child: Text('阅读'.tl),
        ),
        PopupMenuItem(
          onTap: () {
            LocalFavoritesManager().deleteComic(folderName, comic);
            onDelete();
          },
          child: Text('取消收藏'.tl),
        ),
        PopupMenuItem(
          onTap: _copyTo,
          child: Text('复制到'.tl),
        ),
        PopupMenuItem(
          onTap: _editTags,
          child: Text('编辑标签'.tl),
        ),
      ],
    );
  }

  // ---- onTap ----
  void _handleTap() {
    if (onTap != null) {
      final res = onTap!();
      if (res) return;
    }
    if (appdata.settings[52] == '1') {
      _read();
      return;
    }
    _openComic();
  }

  void openMenu() => _showLongPressMenu();

  // ---- build (matches PicaComic's ComicTile rendering) ----
  @override
  Widget build(BuildContext context) {
    // 封面三级降级：本地封面 → 条目的网络封面 URL → 组件内置占位图标。
    // 不能写成"已下载就用本地、否则用网络"：用户实测已下载的条目本地封面
    // 仍可能取不到（_coverFile 落到 File('')），那样不兜底网络就一直是破图。
    final cached = _coverFile;
    final localCover = cached.path.isNotEmpty && cached.existsSync() ? cached : null;
    final coverSource = resolveFavoriteCoverSource(
      localCover: localCover,
      coverPath: comic.coverPath,
    );
    final networkCover = coverSource.networkUrl;
    // 本地收藏只读「local」这一套（不区分源），页面级配置、不随条目变化。
    final displaySettings = readComicTileDisplaySettings();
    final displayConfig = displaySettings.local;
    // 来源标识号（仅 jm / nhentai 有）：受「显示来源 id」开关控制，关闭时
    // 返回 null，不渲染这一行、也不留占位。
    final sourceIdLabel = favoriteSourceIdLabel(
      typeKey: comic.type.key,
      target: comic.target,
      showId: displayConfig.showId,
    );
    return _LocalFavoriteDownloadedComicTile(
      comicId: comicId,
      cardDisplayConfig: displayConfig,
      // 颜色是整体一份（不按页面/源分），卡片按当前主题解析它。
      idColorKey: displaySettings.idColor,
      name: comic.name,
      author: comic.author,
      imagePath: coverSource.file ?? File(''),
      // 本地已命中时不传网络图源，保持原行为（本地优先）。
      // 未命中时走带磁盘缓存的 provider（而非 NetworkImage），避免每次滚入
      // 都重新下载 + 全尺寸解码。
      imageProvider: networkCover == null
          ? null
          : networkCoverProvider(networkCover),
      type: badge,
      // 「显示标签」关闭时不白跑一遍整表标签翻译（_generateTags 是本页最大的
      // CPU 热点之一）：卡片侧本就不会渲染标签区，结果等价。
      tag: displayConfig.showTags ? _generateTags(comic.tags) : const [],
      onTap: _handleTap,
      size: description,
      descriptionLeading: sourceIdLabel == null
          ? null
          : Text(
              sourceIdLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      onLongTap:
          enableLongPressed ? (onLongPressed ?? _showLongPressMenu) : () {},
      onSecondaryTap: _showDesktopMenu,
    );
  }
}

class _LocalFavoriteDownloadedComicTile extends DownloadedComicTile {
  const _LocalFavoriteDownloadedComicTile({
    required this.comicId,
    required super.name,
    required super.author,
    required super.imagePath,
    // 网络来源条目没有本地封面文件，需要网络图源兜底（详见
    // resolveFavoriteCoverSource 的说明）。
    super.imageProvider,
    super.cardDisplayConfig,
    super.descriptionLeading,
    super.idColorKey,
    required super.type,
    required super.tag,
    required super.size,
    required super.onTap,
    required super.onLongTap,
    required super.onSecondaryTap,
  });

  final String comicId;

  @override
  String? get comicID => comicId;

  @override
  bool get showFavorite => false;
}

/// 「标签显示行数」设为 3 时，卡片需要的高度补偿。
///
/// 基准卡片 164dp 里可用内容高约 148dp；"标题(最多 2 行) + 作者 + 标签 + 来源 id
/// + 日期"在 3 行标签下放不下。实测：164dp 时 3 行档与 2 行档渲染结果**完全相同**
/// （都被可用高度收到 2 行）；190dp 时标签区拿到 `maxHeight = 70.8`，而 3 行需要
/// `3 × 24 = 72`，**只差 1.2dp**。取 30（卡片 194dp）留出余量，避免真机字体
/// 度量略有差异时又差一点。
const localFavoriteThreeTagRowsExtraHeight = 30.0;

/// 本地收藏网格的行高。
///
/// 网格是**定高**的（`childMainAxisExtent`），卡片自己长不高 —— 要让"3 行标签"
/// 生效，只能把行高一起抬上去。其余档位保持基准高度，避免影响观感。
SliverGridDelegateWithComics _localFavoriteGridDelegate() {
  final tagRows = readLocalComicTileDisplayConfig().maxTagRows;
  return SliverGridDelegateWithComics.withExtraHeight(
    tagRows != null && tagRows >= 3 ? localFavoriteThreeTagRowsExtraHeight : 0,
  );
}

// ============================================================
// ComicsPageView — embedded folder content for MainFavoritesPage
// ============================================================

class ComicsPageView extends StatefulWidget {
  const ComicsPageView({
    super.key,
    required this.folder,
    required this.selectedComics,
    this.onClick,
    this.onLongPressed,
    this.onRegisterMenu,
  });

  final String folder;
  final List<FavoriteItem> selectedComics;
  final bool Function(FavoriteItem comic)? onClick;
  final void Function(FavoriteItem comic)? onLongPressed;
  final void Function(FavoriteItem comic, VoidCallback showMenu)?
      onRegisterMenu;

  @override
  State<ComicsPageView> createState() => _ComicsPageViewState();
}

class _ComicsPageViewState extends State<ComicsPageView> {
  final _scrollController = ScrollController();
  List<FavoriteItem> _comics = [];
  bool _loading = true;
  bool _selecting = false;

  @override
  void initState() {
    super.initState();
    _loadComics();
  }

  @override
  void didUpdateWidget(covariant ComicsPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.folder != widget.folder) {
      widget.selectedComics.clear();
      _selecting = false;
      _loadComics();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadComics() async {
    if (!mounted) {
      return;
    }
    await LocalLibraryManager().ensureLoaded();
    LocalFavoriteTile.clearCoverCache();
    setState(() {
      _comics = LocalFavoritesManager().getAllComics(widget.folder);
      _loading = false;
      widget.selectedComics.removeWhere((comic) => !_comics.contains(comic));
      _selecting = widget.selectedComics.isNotEmpty;
    });
  }

  int get _selectedNum => widget.selectedComics.length;

  void _enterSelectMode(FavoriteItem comic) {
    setState(() {
      _selecting = true;
      widget.selectedComics
        ..clear()
        ..add(comic);
    });
  }

  bool _toggleSelected(FavoriteItem comic) {
    if (!_selecting) {
      return false;
    }
    setState(() {
      if (widget.selectedComics.contains(comic)) {
        widget.selectedComics.remove(comic);
      } else {
        widget.selectedComics.add(comic);
      }
      if (widget.selectedComics.isEmpty) {
        _selecting = false;
      }
    });
    return true;
  }

  void _exitSelectMode() {
    setState(() {
      _selecting = false;
      widget.selectedComics.clear();
    });
  }

  void _refreshAfterDelete(FavoriteItem comic) {
    LocalFavoriteTile.clearCoverCache();
    setState(() {
      _comics = LocalFavoritesManager().getAllComics(widget.folder);
    });
    widget.selectedComics.remove(comic);
  }

  void _removeSelected() {
    final toRemove = List<FavoriteItem>.from(widget.selectedComics);
    if (toRemove.isEmpty) {
      return;
    }
    for (final comic in toRemove) {
      LocalFavoritesManager().deleteComic(widget.folder, comic);
    }
    LocalFavoriteTile.clearCoverCache();
    setState(() {
      _comics = LocalFavoritesManager().getAllComics(widget.folder);
      widget.selectedComics.clear();
      _selecting = false;
    });
  }

  void _showRemoveSelectedDialog() {
    if (_selectedNum == 0) {
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除'.tl),
        content: Text(
            '确定要删除选中的 @num 部漫画吗？'.tlParams({'num': _selectedNum.toString()})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _removeSelected();
            },
            child: Text('删除'.tl),
          ),
        ],
      ),
    );
  }

  /// 更新选中的条目（长按多选后的入口，复用「更新卡片信息」的同一套流程）。
  Future<void> _updateSelectedComics() async {
    if (_selectedNum == 0) return;
    final report = await showDialog<LocalFavoriteUpdateReport>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: LocalFavoriteUpdateDialog(
          folder: widget.folder,
          comics: List<FavoriteItem>.of(widget.selectedComics),
        ),
      ),
    );
    if (!mounted) return;
    if (report != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(buildLocalFavoriteUpdateSummary(report).tl)),
      );
    }
    // 已更新条目要立即显示新值；同时退出多选（更新完成即这项操作结束）。
    setState(() {
      _comics = LocalFavoritesManager().getAllComics(widget.folder);
      widget.selectedComics.clear();
      _selecting = false;
    });
  }

  Widget _buildSelectionBar() {
    if (!_selecting) {
      return const SizedBox.shrink();
    }
    return Material(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            IconButton(
              onPressed: _exitSelectMode,
              icon: const Icon(Icons.close),
            ),
            Expanded(
              child: Text(
                '已选择 @num 个项目'.tlParams({'num': _selectedNum.toString()}),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: '更新信息'.tl,
              onPressed: _selectedNum == 0 ? null : _updateSelectedComics,
              icon: const Icon(Icons.cloud_sync_outlined),
            ),
            IconButton(
              tooltip: '删除选中'.tl,
              onPressed: _selectedNum == 0 ? null : _showRemoveSelectedDialog,
              icon: const Icon(Icons.delete_forever_outlined),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid() {
    return DesktopScrollbarDragBehavior(
      child: Scrollbar(
        controller: _scrollController,
        interactive: true,
        child: GridView.builder(
          controller: _scrollController,
          physics: const ClampingScrollPhysics(),
          gridDelegate: _localFavoriteGridDelegate(),
          itemCount: _comics.length,
          padding: const EdgeInsets.only(bottom: 80, left: 4, right: 4, top: 4),
          itemBuilder: (context, index) {
            final comic = _comics[index];
            final selected = widget.selectedComics.contains(comic);
            final tile = LocalFavoriteTile(
              key: ValueKey('${comic.type.key}_${comic.target}'),
              comic: comic,
              folderName: widget.folder,
              onDelete: () => _refreshAfterDelete(comic),
              enableLongPressed: true,
              onTap: () =>
                  _toggleSelected(comic) ||
                  (widget.onClick?.call(comic) ?? false),
              onLongPressed: () {
                if (_selecting) {
                  _toggleSelected(comic);
                } else {
                  _enterSelectMode(comic);
                }
                widget.onLongPressed?.call(comic);
              },
            );
            if (!_selecting) {
              widget.onRegisterMenu?.call(comic, tile.openMenu);
            }

            return AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
              decoration: BoxDecoration(
                color: selected
                    ? Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.14)
                    : null,
                border: selected
                    ? Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.75),
                        width: 1.2,
                      )
                    : null,
                borderRadius: BorderRadius.circular(12),
              ),
              child: tile,
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_comics.isEmpty) {
      return Center(child: Text('这里什么都没有'.tl));
    }

    return Column(
      children: [
        _buildSelectionBar(),
        Expanded(child: _buildGrid()),
      ],
    );
  }
}

// ============================================================
// LocalFavoritesFolder — matches PicaComic's LocalFavoritesFolder
// ============================================================

class LocalFavoritesFolder extends StatefulWidget {
  final String folderName;
  const LocalFavoritesFolder({super.key, required this.folderName});

  @override
  State<LocalFavoritesFolder> createState() => _LocalFavoritesFolderState();
}

enum _SortMode { name, author, time }

class _LocalFavoritesFolderState extends State<LocalFavoritesFolder> {
  final _favManager = LocalFavoritesManager();
  final _scrollController = ScrollController();
  List<FavoriteItem> _comics = [];
  bool _loading = true;
  bool _orderDirty = false;
  bool _selecting = false;
  var _selected = <bool>[];
  _SortMode _sortMode = _SortMode.time;

  @override
  void initState() {
    super.initState();
    App.localDataVersion.addListener(_handleLocalDataRefresh);
    _loadComics();
  }

  @override
  void dispose() {
    App.localDataVersion.removeListener(_handleLocalDataRefresh);
    if (_orderDirty) {
      _favManager.reorder(_comics, widget.folderName);
    }
    _scrollController.dispose();
    super.dispose();
  }

  void _handleLocalDataRefresh() {
    _loadComics();
  }

  Future<void> _loadComics() async {
    await _favManager.init();
    final localLibraryManager = LocalLibraryManager();
    if (await localLibraryManager.shouldUseDirectCurrentDownloadManager()) {
      await DownloadManager().init();
    }
    await localLibraryManager.ensureLoaded();
    final comics = _favManager.getAllComics(widget.folderName);
    _applySort(comics);
    LocalFavoriteTile.clearCoverCache();
    setState(() {
      _comics = comics;
      _loading = false;
      if (_selecting) {
        _selected = List.filled(comics.length, false);
        _selecting = false;
      }
    });
  }

  int get _selectedNum => _selected.where((e) => e).length;

  void _enterSelectMode(int index) {
    setState(() {
      _selecting = true;
      _selected = List.filled(_comics.length, false);
      if (index >= 0 && index < _selected.length) {
        _selected[index] = true;
      }
    });
  }

  void _toggleSelected(int index) {
    if (!_selecting || index < 0 || index >= _selected.length) {
      return;
    }
    setState(() {
      _selected[index] = !_selected[index];
      if (!_selected.any((e) => e)) {
        _selecting = false;
        _selected = [];
      }
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selecting = false;
      _selected = [];
    });
  }

  void _showRemoveSelectedDialog() {
    if (_selectedNum == 0) {
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除'.tl),
        content: Text(
            '确定要删除选中的 @num 部漫画吗？'.tlParams({'num': _selectedNum.toString()})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _removeSelected();
            },
            child: Text('删除'.tl),
          ),
        ],
      ),
    );
  }

  void _applySort(List<FavoriteItem> comics) {
    switch (_sortMode) {
      case _SortMode.name:
        comics.sort((a, b) => a.name.compareTo(b.name));
      case _SortMode.author:
        comics.sort((a, b) => a.author.compareTo(b.author));
      case _SortMode.time:
        break; // keep DB order (time-descending)
    }
  }

  void _removeSelected() {
    final toRemove = <FavoriteItem>[];
    for (var i = 0; i < _comics.length && i < _selected.length; i++) {
      if (_selected[i]) toRemove.add(_comics[i]);
    }
    if (toRemove.isEmpty) {
      return;
    }
    for (final comic in toRemove) {
      _favManager.deleteComic(widget.folderName, comic);
    }
    _loadComics();
    setState(() {
      _selecting = false;
      _selected = [];
    });
  }

  void _toggleSelectMode() {
    setState(() {
      _selecting = !_selecting;
      if (!_selecting) {
        _selected = [];
      } else {
        _selected = List.filled(_comics.length, false);
      }
    });
  }

  void _onDeleteOne() {
    LocalFavoriteTile.clearCoverCache();
    setState(() {
      _comics = _favManager.getAllComics(widget.folderName);
      _orderDirty = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _selecting
            ? Text('已选择 @num 个项目'.tlParams({'num': _selectedNum.toString()}))
            : Text(widget.folderName),
        leading: _selecting
            ? IconButton(
                onPressed: _exitSelectMode,
                icon: const Icon(Icons.close),
              )
            : null,
        actions: [
          if (_selecting)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除选中'.tl,
              onPressed: _selectedNum == 0 ? null : _showRemoveSelectedDialog,
            ),
          if (!_selecting)
            PopupMenuButton<_SortMode>(
              icon: const Icon(Icons.sort),
              tooltip: '排序'.tl,
              onSelected: (mode) {
                setState(() => _sortMode = mode);
                _loadComics();
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: _SortMode.time, child: Text('按时间')),
                const PopupMenuItem(value: _SortMode.name, child: Text('按标题')),
                const PopupMenuItem(
                    value: _SortMode.author, child: Text('按作者')),
              ],
            ),
          if (!_selecting)
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const LocalSearchPage(
                      searchType: LocalSearchType.favoritesOnly,
                    ),
                  ),
                );
              },
            ),
        ],
      ),
      floatingActionButton: _comics.isNotEmpty
          ? FloatingActionButton.small(
              heroTag: 'fav_select',
              onPressed: _toggleSelectMode,
              child: Icon(_selecting ? Icons.close : Icons.checklist),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _comics.isEmpty
              ? const Center(child: Text('暂无漫画'))
              : ReorderableBuilder(
                  scrollController: _scrollController,
                  longPressDelay: const Duration(days: 365),
                  enableDraggable: false,
                  onReorder: (reorderFunc) {
                    if (_selecting) return;
                    setState(() {
                      _orderDirty = true;
                      _comics = reorderFunc(_comics) as List<FavoriteItem>;
                    });
                  },
                  dragChildBoxDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  ),
                  builder: (children) {
                    return DesktopScrollbarDragBehavior(
                      child: Scrollbar(
                        controller: _scrollController,
                        interactive: true,
                        child: GridView(
                          controller: _scrollController,
                          physics: const ClampingScrollPhysics(),
                          padding: const EdgeInsets.only(
                              bottom: 80, left: 4, right: 4, top: 4),
                          gridDelegate: _localFavoriteGridDelegate(),
                          children: children,
                        ),
                      ),
                    );
                  },
                  children: List.generate(
                    _comics.length,
                    (index) {
                      final selected =
                          index < _selected.length && _selected[index];
                      return Padding(
                        key: Key(
                            '${_comics[index].type.key}_${_comics[index].target}'),
                        padding: const EdgeInsets.all(2),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          decoration: BoxDecoration(
                            color: selected
                                ? Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withValues(alpha: 0.14)
                                : null,
                            border: selected
                                ? Border.all(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: 0.75),
                                    width: 1.2,
                                  )
                                : null,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: LocalFavoriteTile(
                            comic: _comics[index],
                            folderName: widget.folderName,
                            onDelete: _onDeleteOne,
                            enableLongPressed: true,
                            onTap: _selecting
                                ? () {
                                    _toggleSelected(index);
                                    return true;
                                  }
                                : null,
                            onLongPressed: () => _enterSelectMode(index),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

// ============================================================
// Folder management dialogs
// ============================================================

class CreateFolderDialog extends StatefulWidget {
  final ValueChanged<String> onCreated;
  const CreateFolderDialog({super.key, required this.onCreated});

  @override
  State<CreateFolderDialog> createState() => _CreateFolderDialogState();
}

class _CreateFolderDialogState extends State<CreateFolderDialog> {
  final controller = TextEditingController();
  FavoriteFolderCreateTarget _target = FavoriteFolderCreateTarget.current;

  bool get _showTargetSelector =>
      normalizeManagedDataSourceMode(
            appdata.settings[managedDataSourceModeSettingIndex],
          ) ==
          managedDataSourceModeCurrentAndOriginal &&
      LocalFavoritesManager().canCreateInOriginalDatabase;

  void _submit() {
    final name = controller.text.trim();
    if (name.isEmpty) {
      return;
    }
    LocalFavoritesManager().createFolder(name, _target);
    Navigator.pop(context);
    widget.onCreated(name);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      title: Text('新建文件夹'.tl),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: '名称'.tl,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ),
        if (_showTargetSelector) ...[
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '新建位置'.tl,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                SegmentedButton<FavoriteFolderCreateTarget>(
                  segments: [
                    ButtonSegment(
                      value: FavoriteFolderCreateTarget.current,
                      label: Text('本应用'.tl),
                    ),
                    ButtonSegment(
                      value: FavoriteFolderCreateTarget.original,
                      label: Text('原应用'.tl),
                    ),
                  ],
                  selected: {_target},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) {
                    setState(() {
                      _target = selection.first;
                    });
                  },
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        Center(
          child: FilledButton(
            onPressed: _submit,
            child: Text('确定'.tl),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class RenameFolderDialog extends StatelessWidget {
  final String oldName;
  final ValueChanged<String> onRenamed;
  const RenameFolderDialog(
      {super.key, required this.oldName, required this.onRenamed});

  @override
  Widget build(BuildContext context) {
    final controller = TextEditingController(text: oldName);
    return SimpleDialog(
      title: Text('重命名'.tl),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: '名称'.tl,
            ),
            onSubmitted: (value) {
              if (value.trim().isNotEmpty) {
                final newName = value.trim();
                LocalFavoritesManager().rename(oldName, newName);
                Navigator.pop(context);
                onRenamed(newName);
              }
            },
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                LocalFavoritesManager().rename(oldName, name);
                Navigator.pop(context);
                onRenamed(name);
              }
            },
            child: Text('确定'.tl),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

void copyAllTo(String source, List<FavoriteItem> comics) {
  String? folder;
  showDialog(
    context: App.globalContext!,
    builder: (ctx) => SimpleDialog(
      title: Text('复制到'.tl),
      children: [
        SizedBox(
          width: 280,
          height: 132,
          child: Column(
            children: [
              ListTile(
                title: Text('收藏夹'.tl),
                trailing: DropdownButton<String?>(
                  value: folder,
                  hint: const Text('选择文件夹'),
                  items: LocalFavoritesManager()
                      .folderNames
                      .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                      .toList(),
                  onChanged: (v) {
                    folder = v;
                    (ctx as Element).markNeedsBuild();
                  },
                ),
              ),
              const Spacer(),
              Center(
                child: FilledButton(
                  child: Text('确认'.tl),
                  onPressed: () {
                    if (folder != null) {
                      for (var comic in comics) {
                        LocalFavoritesManager().addComic(folder!, comic);
                      }
                      Navigator.pop(ctx);
                    }
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ],
    ),
  );
}
