import 'package:flutter/material.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/tools/translations.dart';
import 'local_favorites.dart';

class MainFavoritesPage extends StatefulWidget {
  const MainFavoritesPage({super.key});

  @override
  State<MainFavoritesPage> createState() => _MainFavoritesPageState();
}

class _MainFavoritesPageState extends State<MainFavoritesPage> {
  final _favManager = LocalFavoritesManager();
  List<String> _folders = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadFolders();
  }

  Future<void> _loadFolders() async {
    await _favManager.init();
    setState(() {
      _folders = _favManager.folderNames;
      _loading = false;
    });
  }

  void _createFolder() {
    showDialog(
      context: context,
      builder: (_) => CreateFolderDialog(onCreated: _loadFolders),
    );
  }

  void _renameFolder(int index) {
    showDialog(
      context: context,
      builder: (_) => RenameFolderDialog(
        oldName: _folders[index],
        onRenamed: _loadFolders,
      ),
    );
  }

  void _deleteFolder(int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文件夹'),
        content: Text('确定要删除文件夹 "${_folders[index]}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              _favManager.deleteFolder(_folders[index]);
              _loadFolders();
              Navigator.pop(ctx);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('收藏'.tl),
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder),
            onPressed: _createFolder,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _folders.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.folder_off,
                          size: 64, color: Colors.grey),
                      const SizedBox(height: 16),
                      Text('暂无收藏文件夹'.tl),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _createFolder,
                        icon: const Icon(Icons.add),
                        label: Text('新建文件夹'.tl),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _folders.length,
                  itemBuilder: (context, index) {
                    final folder = _folders[index];
                    final comics = _favManager.getAllComics(folder);
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.folder, size: 40),
                        title: Text(folder),
                        subtitle: Text('${comics.length} 部漫画'),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) {
                            switch (value) {
                              case 'rename':
                                _renameFolder(index);
                              case 'delete':
                                _deleteFolder(index);
                            }
                          },
                          itemBuilder: (ctx) => [
                            const PopupMenuItem(
                                value: 'rename', child: Text('重命名')),
                            const PopupMenuItem(
                                value: 'delete', child: Text('删除')),
                          ],
                        ),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  LocalFavoritesFolder(folderName: folder),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
    );
  }
}
