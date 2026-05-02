
// ignore_for_file: no_leading_underscores_for_local_identifiers, unused_element

part of 'settings_page.dart';

class LocalFavoritesSettings extends StatefulWidget {
  const LocalFavoritesSettings({this.width = 0, super.key});
  final double width;

  @override
  State<LocalFavoritesSettings> createState() => _LocalFavoritesSettingsState();
}

class _LocalFavoritesSettingsState extends State<LocalFavoritesSettings> {
  final LocalFavoritesManager _favManager = LocalFavoritesManager();
  List<String> _folderNames = [];

  @override
  void initState() {
    super.initState();
    _refreshFolders();
  }

  void _refreshFolders() {
    setState(() {
      _folderNames = List<String>.from(_favManager.folderNames);
    });
  }

  @override
  Widget build(BuildContext context) {
    return buildTwoColumnLayout(widget.width, [
      SettingsTitle("本地收藏".tl),
      NewPageSetting(
        title: "收藏夹管理".tl,
        page: const FolderManageSetting(),
      ),
      SelectSetting(
        title: "本地收藏添加位置".tl,
        settingsIndex: 53,
        values: const ["0", "1"],
        titles: ["尾部添加".tl, "首部添加".tl],
      ),
      SelectSetting(
        title: "阅读后移动本地收藏".tl,
        settingsIndex: 54,
        values: const ["0", "1", "2"],
        titles: [
          "不移动".tl,
          "尾部添加".tl,
          "首部添加".tl,
        ],
      ),
      SelectSetting(
        title: "默认收藏夹".tl,
        settingsIndex: 51,
        values: _buildFolderValues(),
        titles: _buildFolderTitles(),
      ),
    ]);
  }

  List<String> _buildFolderValues() {
    var values = <String>[""];
    values.addAll(_folderNames);
    return values;
  }

  List<String> _buildFolderTitles() {
    var titles = <String>["默认".tl];
    titles.addAll(_folderNames);
    return titles;
  }
}

class FolderManageSetting extends StatefulWidget {
  const FolderManageSetting({super.key});

  @override
  State<FolderManageSetting> createState() => _FolderManageSettingState();
}

class _FolderManageSettingState extends State<FolderManageSetting> {
  final LocalFavoritesManager _favManager = LocalFavoritesManager();
  late TextEditingController _controller;
  List<String> _folderNames = [];

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _refreshFolders();
  }

  void _refreshFolders() {
    setState(() {
      _folderNames = List<String>.from(_favManager.folderNames);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "收藏夹管理".tl,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: "新建收藏夹".tl,
                    ),
                    onSubmitted: (value) {
                      _addFolder(value);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    _addFolder(_controller.text);
                  },
                  child: Text("添加".tl),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _folderNames.length,
              itemBuilder: (context, index) {
                return ListTile(
                  title: Text(_folderNames[index]),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () {
                      _removeFolder(index);
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _addFolder(String name) {
    if (name.trim().isEmpty) return;
    if (_folderNames.contains(name.trim())) return;
    try {
      _favManager.createFolder(name.trim());
    } catch (_) {
      return;
    }
    _controller.clear();
    _refreshFolders();
  }

  void _removeFolder(int index) {
    final name = _folderNames[index];
    _favManager.deleteFolder(name);
    _refreshFolders();
  }
}
