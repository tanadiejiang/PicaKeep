import 'package:flutter/material.dart';
import 'package:picakeep/foundation/local_favorites.dart';

/// Returns true only when the user explicitly chooses the platform action.
Future<bool> choosePlatformFavorite(
  BuildContext context,
  FavoriteItem item,
) async {
  final choice = await showModalBottomSheet<bool>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.bookmark_add_outlined),
          title: const Text('本地收藏夹'),
          onTap: () => Navigator.pop(sheetContext, false),
        ),
        ListTile(
          leading: const Icon(Icons.cloud_outlined),
          title: const Text('平台收藏'),
          onTap: () => Navigator.pop(sheetContext, true),
        ),
      ]),
    ),
  );
  if (choice == false && context.mounted) {
    await showLocalFavoriteFolders(context, item);
  }
  return choice == true && context.mounted;
}

bool isLocallyFavorited(FavoriteItem item) {
  return isLocalFavoriteTarget(item.target, item.type);
}

bool isLocalFavoriteTarget(String target, FavoriteType type) {
  final manager = LocalFavoritesManager();
  return manager.folderNames.any(
    (folder) => manager.comicExists(folder, target, type.key),
  );
}

Future<void> showLocalFavoriteFolders(
  BuildContext context,
  FavoriteItem item,
) =>
    showDialog<void>(
      context: context,
      builder: (_) => _LocalFavoriteFolders(item: item),
    );

class _LocalFavoriteFolders extends StatefulWidget {
  const _LocalFavoriteFolders({required this.item});
  final FavoriteItem item;

  @override
  State<_LocalFavoriteFolders> createState() => _LocalFavoriteFoldersState();
}

class _LocalFavoriteFoldersState extends State<_LocalFavoriteFolders> {
  final _name = TextEditingController();
  final _manager = LocalFavoritesManager();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _change(void Function() action) {
    try {
      action();
      setState(() => _error = null);
    } catch (_) {
      setState(() => _error = '收藏操作失败，请检查收藏夹后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final folders = _manager.folderNames;
    return AlertDialog(
      title: const Text('本地收藏夹'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (folders.isEmpty) const Text('暂无收藏夹，请先新建'),
            for (final folder in folders)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(folder),
                value: _manager.comicExists(folder, item.target, item.type.key),
                onChanged: (selected) => _change(() {
                  if (selected == true) {
                    _manager.addComic(folder, item);
                  } else {
                    _manager.deleteComicWithTarget(
                        folder, item.target, item.type);
                  }
                }),
              ),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '新收藏夹名称'),
            ),
            TextButton.icon(
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('新建并收藏'),
              onPressed: () {
                final name = _name.text.trim();
                if (name.isEmpty) {
                  setState(() => _error = '请输入收藏夹名称');
                  return;
                }
                _change(() {
                  if (!_manager.folderNames.contains(name)) {
                    _manager.createFolder(name);
                  }
                  _manager.addComic(name, item);
                  _name.clear();
                });
              },
            ),
            if (_error != null)
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('完成'))
      ],
    );
  }
}
