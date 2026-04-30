import 'package:flutter/material.dart';
import 'package:picakeep/foundation/local_favorites.dart';
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
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '请输入文件夹名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                _favManager.createFolder(name);
                _loadFolders();
                Navigator.pop(ctx);
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _renameFolder(int index) {
    final controller = TextEditingController(text: _folders[index]);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名文件夹'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '请输入新名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                _favManager.rename(_folders[index], name);
                _loadFolders();
                Navigator.pop(ctx);
              }
            },
            child: const Text('确定'),
          ),
        ],
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
              child: const Text('删除')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('收藏'),
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
                      const Text('暂无收藏文件夹'),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _createFolder,
                        icon: const Icon(Icons.add),
                        label: const Text('新建文件夹'),
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
                                break;
                              case 'delete':
                                _deleteFolder(index);
                                break;
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
                                  LocalFavoritesPage(folderName: folder),
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
