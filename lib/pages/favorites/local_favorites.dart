import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_favorites.dart';
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
  static Future<DownloadedItem?> _resolveDownloadedItem(FavoriteItem comic) async {
    final dm = DownloadManager();
    await dm.init();
    var id = comic.toDownloadId();
    if (!dm.isExists(id) && id != comic.target && dm.isExists(comic.target)) {
      id = comic.target;
    }
    if (!dm.isExists(id)) {
      if (App.globalContext?.mounted ?? false) {
        ScaffoldMessenger.of(App.globalContext!).showSnackBar(
          SnackBar(content: Text('未找到本地下载: $id')),
        );
      }
      return null;
    }
    final dl = await dm.getComicOrNull(id);
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
      await ensureHistoryBeforeRead(dl);
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

  // ---- badge ----
  bool get _isDownloaded {
    try {
      final dm = DownloadManager();
      var id = comic.toDownloadId();
      if (!dm.isExists(id) &&
          id != comic.target &&
          dm.isExists(comic.target)) {
        id = comic.target;
      }
      return dm.isExists(id);
    } catch (_) {
      return false;
    }
  }

  String? get badge => _isDownloaded ? '已下载'.tl : null;

  String get description => '${comic.time} | ${comic.type.name}';

  String get comicId => comic.toDownloadId();

  // ---- cover image ----
  File get _coverFile {
    final p = comic.coverPath.trim();
    if (p.isEmpty) return File('');
    final f = File(p);
    return f.existsSync() ? f : File('');
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
                        LocalFavoritesManager()
                            .addComic(folder!, comic);
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
      position: RelativeRect.fromLTRB(
          offset.dx, offset.dy, offset.dx, offset.dy),
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
      onLongTap: enableLongPressed
          ? (onLongPressed ?? _showLongPressMenu)
          : () {},
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
}

// ============================================================
// ComicsPageView — embedded folder content for MainFavoritesPage
// ============================================================

class ComicsPageView extends StatefulWidget {
  const ComicsPageView({
    super.key,
    required this.folder,
    required this.selectedComics,
    required this.onClick,
    required this.onLongPressed,
    this.onRegisterMenu,
  });

  final String folder;
  final List<FavoriteItem> selectedComics;
  final bool Function(FavoriteItem comic) onClick;
  final void Function(FavoriteItem comic) onLongPressed;
  final void Function(FavoriteItem comic, VoidCallback showMenu)? onRegisterMenu;

  @override
  State<ComicsPageView> createState() => _ComicsPageViewState();
}

class _ComicsPageViewState extends State<ComicsPageView> {
  final _scrollController = ScrollController();
  List<FavoriteItem> _comics = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadComics();
  }

  @override
  void didUpdateWidget(covariant ComicsPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.folder != widget.folder) {
      _loadComics();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadComics() async {
    await LocalFavoritesManager().init();
    if (!mounted) {
      return;
    }
    setState(() {
      _comics = LocalFavoritesManager().getAllComics(widget.folder);
      _loading = false;
    });
  }

  void _refreshAfterDelete(FavoriteItem comic) {
    setState(() {
      _comics = LocalFavoritesManager().getAllComics(widget.folder);
    });
    widget.selectedComics.remove(comic);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_comics.isEmpty) {
      return Center(child: Text('这里什么都没有'.tl));
    }

    return Scrollbar(
      controller: _scrollController,
      interactive: true,
      child: GridView.builder(
        controller: _scrollController,
        gridDelegate: SliverGridDelegateWithComics(),
        itemCount: _comics.length,
        padding: const EdgeInsets.only(bottom: 80, left: 4, right: 4, top: 4),
        itemBuilder: (context, index) {
          final comic = _comics[index];
          final tile = LocalFavoriteTile(
            key: ValueKey('${comic.type.key}_${comic.target}'),
            comic: comic,
            folderName: widget.folder,
            onDelete: () => _refreshAfterDelete(comic),
            enableLongPressed: true,
            onTap: () => widget.onClick(comic),
            onLongPressed: () => widget.onLongPressed(comic),
          );
          widget.onRegisterMenu?.call(comic, tile.openMenu);

          Color? color;
          if (widget.selectedComics.contains(comic)) {
            color = Theme.of(context).colorScheme.surfaceContainerHighest;
          }

          return AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(12),
            ),
            child: tile,
          );
        },
      ),
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
    final comics = _favManager.getAllComics(widget.folderName);
    _applySort(comics);
    setState(() {
      _comics = comics;
      _loading = false;
    });
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
    for (var i = 0; i < _comics.length; i++) {
      if (_selected[i]) toRemove.add(_comics[i]);
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
    setState(() {
      _comics = _favManager.getAllComics(widget.folderName);
      _orderDirty = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.folderName),
        actions: [
          if (_selecting)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除选中'.tl,
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('删除'),
                    content: Text(
                        '确定要删除选中的 ${_selected.where((e) => e).length} 部漫画吗？'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                      TextButton(
                        onPressed: () {
                          _removeSelected();
                          Navigator.pop(ctx);
                        },
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                );
              },
            ),
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
                  longPressDelay: _selecting
                      ? const Duration(days: 365)
                      : App.isDesktop
                          ? const Duration(milliseconds: 100)
                          : const Duration(milliseconds: 500),
                  enableDraggable: !_selecting,
                  onReorder: (reorderFunc) {
                    if (_selecting) return;
                    setState(() {
                      _orderDirty = true;
                      _comics =
                          reorderFunc(_comics) as List<FavoriteItem>;
                    });
                  },
                  dragChildBoxDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHigh,
                  ),
                  builder: (children) {
                    return GridView(
                      controller: _scrollController,
                      padding: const EdgeInsets.only(
                          bottom: 80, left: 4, right: 4, top: 4),
                      gridDelegate: SliverGridDelegateWithComics(),
                      children: children,
                    );
                  },
                  children: List.generate(
                    _comics.length,
                    (index) => Padding(
                      key: Key(
                          '${_comics[index].type.key}_${_comics[index].target}'),
                      padding: const EdgeInsets.all(2),
                      child: Stack(
                        children: [
                          LocalFavoriteTile(
                            comic: _comics[index],
                            folderName: widget.folderName,
                            onDelete: _onDeleteOne,
                            enableLongPressed: !_selecting,
                          ),
                          if (_selecting)
                            Positioned(
                              top: 4,
                              right: 4,
                              child: Checkbox(
                                value: _selected[index],
                                onChanged: (v) {
                                  setState(
                                      () => _selected[index] = v ?? false);
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }
}

// ============================================================
// Folder management dialogs
// ============================================================

class CreateFolderDialog extends StatelessWidget {
  final VoidCallback onCreated;
  const CreateFolderDialog({super.key, required this.onCreated});

  @override
  Widget build(BuildContext context) {
    final controller = TextEditingController();
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
            onSubmitted: (value) {
              if (value.trim().isNotEmpty) {
                LocalFavoritesManager().createFolder(value.trim());
                Navigator.pop(context);
                onCreated();
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
                LocalFavoritesManager().createFolder(name);
                Navigator.pop(context);
                onCreated();
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

class RenameFolderDialog extends StatelessWidget {
  final String oldName;
  final VoidCallback onRenamed;
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
                LocalFavoritesManager().rename(oldName, value.trim());
                Navigator.pop(context);
                onRenamed();
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
                onRenamed();
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
                      .map((f) =>
                          DropdownMenuItem(value: f, child: Text(f)))
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
                        LocalFavoritesManager()
                            .addComic(folder!, comic);
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
