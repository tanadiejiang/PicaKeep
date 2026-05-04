import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/components/scrollable.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/pages/download_page.dart';
import 'package:picakeep/pages/local_comic_detail_page.dart';
import 'package:picakeep/pages/local_search_page.dart';
import 'package:picakeep/tools/read_history_helper.dart';
import 'package:picakeep/tools/tags_translation.dart';
import 'package:picakeep/tools/translations.dart';

// ============================================================
// OpenFavoriteComicHelper — reusable comic opener
// ============================================================

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

    final dm = DownloadManager();
    await dm.init();
    final resolvedId = dm.resolveExistingId(candidates);
    if (resolvedId == null) {
      if (App.globalContext?.mounted ?? false) {
        ScaffoldMessenger.of(App.globalContext!).showSnackBar(
          SnackBar(content: Text('未找到本地下载: ${candidates.first}')),
        );
      }
      return null;
    }
    final dl = await dm.getComicOrNullFromCandidates(candidates);
    if (dl == null) {
      if (App.globalContext?.mounted ?? false) {
        ScaffoldMessenger.of(App.globalContext!).showSnackBar(
          const SnackBar(content: Text('无法打开该漫画')),
        );
      }
      return null;
    }
    return dl;
  }

  static Future<void> open(FavoriteItem comic) async {
    try {
      final dl = await _resolveDownloadedItem(comic);
      if (dl == null) {
        return;
      }
      App.pushInner(() => LocalComicDetailPage(comic: dl));
    } catch (e) {
      if (App.globalContext?.mounted ?? false) {
        ScaffoldMessenger.of(App.globalContext!).showSnackBar(
          SnackBar(content: Text('打开失败: $e')),
        );
      }
    }
  }

  static Future<void> read(FavoriteItem comic) async {
    try {
      final dl = await _resolveDownloadedItem(comic);
      if (dl == null) {
        return;
      }
      await ensureHistoryBeforeRead(
        dl,
        legacyTargets: comic.candidateDownloadIds(),
      );
      await dl.read();
    } catch (e) {
      if (App.globalContext?.mounted ?? false) {
        ScaffoldMessenger.of(App.globalContext!).showSnackBar(
          SnackBar(content: Text('打开失败: $e')),
        );
      }
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

  static void clearCoverCache() {
    _coverCache.clear();
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
  List<String> _generateTags(List<String> tags) {
    if (App.locale.languageCode != 'zh') return tags;
    final res = <String>[];
    final res2 = <String>[];
    for (var tag in tags) {
      if (tag.contains(':')) {
        final splits = tag.split(':');
        const lowLevelKey = ['character', 'artist', 'cosplayer', 'group'];
        if (lowLevelKey.contains(splits[0])) {
          res2.add(_translateTag(splits[1]));
        } else {
          res.add(_translateTag(splits[1]));
        }
      } else {
        var name = tag;
        if (name.contains('♀')) {
          name = '${_translateTag(name.replaceFirst(' ♀', ''))}♀';
        } else if (name.contains('♂')) {
          name = '${_translateTag(name.replaceFirst(' ♂', ''))}♂';
        } else {
          name = _translateTag(name);
        }
        res.add(name);
      }
    }
    return res + res2;
  }

  String _translateTag(String tag) {
    try {
      for (final map in tagTranslations.values) {
        for (final entry in map.entries) {
          if (entry.key.toLowerCase() == tag.toLowerCase()) {
            return entry.value.isNotEmpty ? entry.value.first : tag;
          }
        }
      }
    } catch (_) {}
    return tag;
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
    final cover = _coverFile;
    return _LocalFavoriteDownloadedComicTile(
      comicId: comicId,
      name: comic.name,
      author: comic.author,
      imagePath: cover.path.isNotEmpty ? cover : File(''),
      type: badge,
      tag: _generateTags(comic.tags),
      onTap: _handleTap,
      size: description,
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
          gridDelegate: SliverGridDelegateWithComics(),
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
                    ? Theme.of(context).colorScheme.surfaceContainerHighest
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
    await DownloadManager().init();
    await LocalLibraryManager().ensureLoaded();
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
                          gridDelegate: SliverGridDelegateWithComics(),
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
                                    .surfaceContainerHighest
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
