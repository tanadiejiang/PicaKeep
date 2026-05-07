import 'dart:io';

import 'package:flutter/material.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/components/scrollable.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/tools/read_history_helper.dart';
import 'package:picakeep/tools/translations.dart';

class _HistoryDownloadedComicTile extends DownloadedComicTile {
  const _HistoryDownloadedComicTile({
    required this.comicId,
    required super.name,
    required super.author,
    required super.imagePath,
    super.imageProvider,
    required super.type,
    required super.tag,
    required super.size,
    required super.onTap,
    required super.onLongTap,
    required super.onSecondaryTap,
  });

  final String comicId;

  @override
  String? get comicID => comicId.isEmpty ? null : comicId;

  @override
  bool get showFavorite => false;

  @override
  bool get showReadingPosition => false;
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final comics = <History>[];
  final _coverCache = <String, File>{};
  bool searchInit = false;
  bool searchMode = false;
  String keyword = "";
  final results = <History>[];

  @override
  void initState() {
    super.initState();
    comics.addAll(HistoryManager().getAll());
    DownloadManager().init();
    LocalLibraryManager().ensureLoaded().then((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  String _cacheKey(History item) => '${item.type.value}|${item.target}';

  String _typeLabel(History item) {
    if (item.type == HistoryType.localAlbum ||
        item.target.startsWith('local_album::')) {
      return '图集';
    }
    final cover = item.cover.trim();
    if (item.type == HistoryType.other &&
        (cover.startsWith('http://') || cover.startsWith('https://'))) {
      return '远程资源';
    }
    return item.type.name;
  }

  Widget buildTitle() {
    if (searchMode) {
      return TextField(
        autofocus: searchInit,
        decoration:
            InputDecoration(border: InputBorder.none, hintText: "搜索".tl),
        onChanged: (s) {
          setState(() {
            keyword = s.toLowerCase();
          });
        },
      );
    }
    return Text("${"历史记录".tl}(${comics.length})");
  }

  void find() {
    results.clear();
    if (keyword.isEmpty) {
      results.addAll(comics);
    } else {
      for (final element in comics) {
        if (element.title.toLowerCase().contains(keyword) ||
            element.subtitle.toLowerCase().contains(keyword)) {
          results.add(element);
        }
      }
    }
  }

  ImageProvider<Object>? _coverImageProvider(History item) {
    final cover = item.cover.trim();
    if (cover.startsWith('http://') || cover.startsWith('https://')) {
      return NetworkImage(cover);
    }
    if (cover.isNotEmpty && (cover.startsWith('/') || cover.contains(':\\'))) {
      return LocalLibraryManager().imageProviderForLocalPath(cover);
    }
    final localComic =
        LocalLibraryManager().findCachedByCandidates(item.candidateDownloadIds());
    if (localComic != null) {
      final coverPath = resolveLocalComicCoverPath(
        localComic,
        legacyTargets: item.candidateDownloadIds(),
      );
      if (coverPath.isNotEmpty) {
        return LocalLibraryManager().imageProviderForLocalPath(coverPath);
      }
    }
    return null;
  }

  File _coverFile(History item) {
    final key = _cacheKey(item);
    final cached = _coverCache[key];
    if (cached != null) {
      return cached;
    }

    final c = item.cover.trim();
    if (c.isNotEmpty && (c.startsWith('/') || c.contains(':\\'))) {
      final f = File(c);
      _coverCache[key] = f;
      return f;
    }
    try {
      final file =
          DownloadManager().getCoverFromCandidates(item.candidateDownloadIds());
      if (file.existsSync()) {
        _coverCache[key] = file;
        return file;
      }
    } catch (_) {}

    final localComic = LocalLibraryManager()
        .findCachedByCandidates(item.candidateDownloadIds());
    if (localComic != null) {
      final coverPath = resolveLocalComicCoverPath(
        localComic,
        legacyTargets: item.candidateDownloadIds(),
      );
      if (coverPath.isNotEmpty) {
        final file = File(coverPath);
        _coverCache[key] = file;
        return file;
      }
    }

    return File('');
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return "刚刚";
    if (diff.inMinutes < 60) return "${diff.inMinutes}分钟前";
    if (diff.inHours < 24) return "${diff.inHours}小时前";
    if (diff.inDays < 30) return "${diff.inDays}天前";
    if (diff.inDays < 365) return "${(diff.inDays / 30).floor()}个月前";
    return "${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}";
  }

  void _clearAll() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text("清除记录".tl),
        content: Text("要清除历史记录吗?".tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text("取消".tl),
          ),
          TextButton(
            onPressed: () {
              HistoryManager().clearHistory();
              setState(() {
                comics.clear();
              });
              Navigator.of(dialogContext).pop();
            },
            child: Text("清除".tl),
          ),
        ],
      ),
    );
  }

  Future<void> _openComic(History item) async {
    final dm = DownloadManager();
    await dm.init();
    var comic =
        await dm.getComicOrNullFromCandidates(item.candidateDownloadIds());
    comic ??= await LocalLibraryManager()
        .findByCandidates(item.candidateDownloadIds());
    comic ??= await const RemoteLibraryDataSource()
        .findByCandidates(item.candidateDownloadIds());
    if (comic != null) {
      if (!mounted) return;
      await ensureHistoryBeforeRead(
        comic,
        legacyTargets: item.candidateDownloadIds(),
      );
      final coverPath = resolveLocalComicCoverPath(
        comic,
        legacyTargets: item.candidateDownloadIds(),
      );
      final remoteCover =
          comic is RemoteLibraryComicItem ? comic.coverUrl.trim() : '';
      if (!mounted) return;
      setState(() {
        item.target = comic!.id;
        item.title = comic.name;
        item.subtitle = comic.subTitle;
        if (comic is RemoteLibraryComicItem && comic.isCustomLibraryRoot) {
          item.type = HistoryType.localAlbum;
        }
        if (remoteCover.isNotEmpty) {
          item.cover = remoteCover;
        } else if (coverPath.isNotEmpty) {
          item.cover = coverPath;
        }
      });
      await App.openReader(
          () => comic!.createReadingPage(ep: item.ep, page: item.page));
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("未找到该漫画".tl)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (searchMode) {
      find();
      if (searchInit) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => searchInit = false);
        });
      }
    }
    final list = searchMode ? results : comics;
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(
            title: buildTitle(),
            actions: [
              Tooltip(
                message: "清除".tl,
                child: IconButton(
                  icon: const Icon(Icons.delete_forever),
                  onPressed: comics.isEmpty ? null : _clearAll,
                ),
              ),
              Tooltip(
                message: "搜索".tl,
                child: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () {
                    setState(() {
                      searchMode = !searchMode;
                      searchInit = true;
                      if (!searchMode) {
                        keyword = "";
                      }
                    });
                  },
                ),
              ),
            ],
          ),
          if (list.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Center(child: Text("暂无历史记录".tl)),
              ),
            )
          else
            SliverGrid(
              delegate: SliverChildBuilderDelegate(
                childCount: list.length,
                (context, i) {
                  final comic = list[i];
                  final cover = _coverFile(comic);
                  return Padding(
                    padding: const EdgeInsets.all(2),
                    child: _HistoryDownloadedComicTile(
                      comicId: comic.target,
                      name: comic.title,
                      author: comic.subtitle,
                      imagePath: cover,
                      imageProvider: _coverImageProvider(comic),
                      type: _typeLabel(comic),
                      tag: const [],
                      size: _formatTime(comic.time),
                      onTap: () => _openComic(comic),
                      onLongTap: () {
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text("删除".tl),
                            content: Text("要删除这条历史记录吗".tl),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                child: Text("取消".tl),
                              ),
                              TextButton(
                                onPressed: () {
                                  HistoryManager().remove(comic.target);
                                  setState(() {
                                    comics.removeWhere(
                                        (e) => e.target == comic.target);
                                  });
                                  Navigator.of(ctx).pop();
                                },
                                child: Text("删除".tl),
                              ),
                            ],
                          ),
                        );
                      },
                      onSecondaryTap: (_) {},
                    ),
                  );
                },
              ),
              gridDelegate: SliverGridDelegateWithComics(),
            ),
          SliverPadding(
            padding:
                EdgeInsets.only(top: MediaQuery.of(context).padding.bottom),
          ),
        ],
      ),
    );
  }
}
