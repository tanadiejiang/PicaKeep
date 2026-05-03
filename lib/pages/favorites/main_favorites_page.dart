import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/tools/translations.dart';

import '../local_search_page.dart';
import 'local_favorites.dart';

class MainFavoritesPage extends StatefulWidget {
  const MainFavoritesPage({super.key});

  @override
  State<MainFavoritesPage> createState() => _MainFavoritesPageState();
}

class _MainFavoritesPageState extends State<MainFavoritesPage> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    App.localDataVersion.addListener(_handleLocalDataRefresh);
    _loadFolders();
  }

  @override
  void dispose() {
    App.localDataVersion.removeListener(_handleLocalDataRefresh);
    super.dispose();
  }

  void _handleLocalDataRefresh() {
    _refresh();
  }

  Future<void> _loadFolders() async {
    await LocalFavoritesManager().init();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
    });
  }

  Future<void> _refresh() async {
    await LocalFavoritesManager().init();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
    });
  }

  void _createFolder() {
    showDialog(
      context: context,
      builder: (_) => CreateFolderDialog(
        onCreated: () {
          _refresh();
        },
      ),
    );
  }

  void _renameFolder(String folder) {
    showDialog(
      context: context,
      builder: (_) => RenameFolderDialog(
        oldName: folder,
        onRenamed: () {
          _refresh();
        },
      ),
    );
  }

  Future<void> _deleteFolder(String folder) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('删除文件夹'.tl),
            content: Text('确定要删除文件夹 "$folder" 吗？'.tl),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('取消'.tl),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('删除'.tl),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) {
      return;
    }
    LocalFavoritesManager().deleteFolder(folder);
    _refresh();
  }

  Future<void> _showFolderMenu(String folder, Offset position) async {
    final action = await showMenu<_FolderMenuAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem(
          value: _FolderMenuAction.rename,
          child: Text('重命名'.tl),
        ),
        PopupMenuItem(
          value: _FolderMenuAction.delete,
          child: Text('删除'.tl),
        ),
      ],
    );

    if (!mounted || action == null) {
      return;
    }

    switch (action) {
      case _FolderMenuAction.rename:
        _renameFolder(folder);
      case _FolderMenuAction.delete:
        _deleteFolder(folder);
    }
  }

  void _openFolder(String folder) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => LocalFavoritesFolder(folderName: folder),
          ),
        )
        .then((_) => _refresh());
  }

  void _openFavoritesSearch() {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => const LocalSearchPage(
              searchType: LocalSearchType.favoritesOnly,
            ),
          ),
        )
        .then((_) => _refresh());
  }

  void _openDownloadedSearch() {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => const LocalSearchPage(
              searchType: LocalSearchType.downloadsOnly,
            ),
          ),
        )
        .then((_) => _refresh());
  }

  void _openReorderPage() {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => _FoldersReorderPage(
              folders: List<String>.from(LocalFavoritesManager().folderNames),
            ),
          ),
        )
        .then((_) => _refresh());
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final folders = LocalFavoritesManager().folderNames;

    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 12),
            child: Text(
              '本地'.tl,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ActionItem(
                  icon: Icons.create_new_folder_outlined,
                  label: '新建'.tl,
                  onTap: _createFolder,
                ),
                _ActionItem(
                  icon: Icons.search,
                  label: '搜索收藏'.tl,
                  onTap: _openFavoritesSearch,
                ),
                _ActionItem(
                  icon: Icons.manage_search,
                  label: '搜索全部'.tl,
                  onTap: _openDownloadedSearch,
                ),
                _ActionItem(
                  icon: Icons.reorder,
                  label: '排序'.tl,
                  onTap: _openReorderPage,
                ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        if (folders.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text('这里什么都没有'.tl),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 360,
                mainAxisExtent: 72,
                mainAxisSpacing: 8,
                crossAxisSpacing: 16,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final folder = folders[index];
                  return _FolderTile(
                    folder: folder,
                    count: LocalFavoritesManager().count(folder),
                    onTap: () => _openFolder(folder),
                    onMenu: (position) => _showFolderMenu(folder, position),
                  );
                },
                childCount: folders.length,
              ),
            ),
          ),
      ],
    );
  }
}

enum _FolderMenuAction { rename, delete }

class _ActionItem extends StatelessWidget {
  const _ActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: SizedBox(
        width: 72,
        height: 82,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 28,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 10),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.folder,
    required this.count,
    required this.onTap,
    required this.onMenu,
  });

  final String folder;
  final int count;
  final VoidCallback onTap;
  final void Function(Offset position) onMenu;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (details) => onMenu(details.globalPosition),
      onSecondaryTapDown: (details) => onMenu(details.globalPosition),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Icon(
                Icons.folder,
                size: 34,
                color: Theme.of(context).colorScheme.secondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  folder,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 18),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                constraints: const BoxConstraints(minWidth: 34),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FoldersReorderPage extends StatefulWidget {
  const _FoldersReorderPage({required this.folders});

  final List<String> folders;

  @override
  State<_FoldersReorderPage> createState() => _FoldersReorderPageState();
}

class _FoldersReorderPageState extends State<_FoldersReorderPage> {
  late List<String> folders = List<String>.from(widget.folders);
  final _scrollController = ScrollController();
  bool changed = false;

  void _saveOrder() {
    if (!changed) {
      return;
    }
    final order = <String, int>{};
    for (int i = 0; i < folders.length; i++) {
      order[folders[i]] = i;
    }
    LocalFavoritesManager().updateOrder(order);
    changed = false;
  }

  @override
  void dispose() {
    _saveOrder();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('排序'.tl),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            _saveOrder();
            Navigator.of(context).pop();
          },
        ),
      ),
      body: ReorderableBuilder(
        scrollController: _scrollController,
        longPressDelay: const Duration(milliseconds: 150),
        onReorder: (reorderFunc) {
          changed = true;
          setState(() {
            folders = reorderFunc(folders) as List<String>;
          });
        },
        dragChildBoxDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        builder: (children) {
          return GridView(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 360,
              mainAxisExtent: 64,
              mainAxisSpacing: 8,
              crossAxisSpacing: 16,
            ),
            children: children,
          );
        },
        children: List.generate(
          folders.length,
          (index) => Material(
            key: ValueKey(folders[index]),
            color: Colors.transparent,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Icon(
                  Icons.folder,
                  color: Theme.of(context).colorScheme.secondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    folders[index],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}