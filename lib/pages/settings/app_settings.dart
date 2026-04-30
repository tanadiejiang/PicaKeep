// ignore_for_file: no_leading_underscores_for_local_identifiers, unused_element

part of 'settings_page.dart';

Widget buildAppSettings(double width, BuildContext context) {
  return buildTwoColumnLayout(width, [
    SettingsTitle("APP".tl),
    NewPageSetting(
      title: "日志".tl,
      page: const LogSetting(),
    ),
    NewPageSetting(
      title: "数据管理".tl,
      page: DataManageSetting(),
    ),
    SelectSetting(
      title: "语言".tl,
      settingsIndex: 50,
      values: const ["", "cn", "tw", "en"],
      titles: [
        "跟随系统".tl,
        "中文".tl,
        "繁体中文".tl,
        "英文".tl,
      ],
    ),
    const _DownloadDirTile(),
    ListTile(
      title: Text("缓存大小限制".tl),
      subtitle: Text(
        "${(int.tryParse(appdata.settings[35]) ?? 500)} MB".tl,
      ),
      trailing: SizedBox(
        width: 120,
        child: Select(
          initialValue: appdata.settings[35],
          values: const ["100", "200", "500", "1000", "2000", "5000", "10000"],
          titles: const [
            "100 MB",
            "200 MB",
            "500 MB",
            "1 GB",
            "2 GB",
            "5 GB",
            "10 GB"
          ],
          onChanged: (value) {
            appdata.settings[35] = value;
            appdata.updateSettings();
          },
        ),
      ),
    ),
    NewPageSetting(
      title: "权限管理".tl,
      page: const PermissionSetting(),
    ),
  ]);
}

class _DownloadDirTile extends StatefulWidget {
  const _DownloadDirTile();

  @override
  State<_DownloadDirTile> createState() => _DownloadDirTileState();
}

class _DownloadDirTileState extends State<_DownloadDirTile> {
  Future<String?> _pickFolder() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath();
      return result;
    } catch (e) {
      return null;
    }
  }

  void _openCurrentDirectory(String path) {
    if (Platform.isWindows) {
      Process.run('explorer', [path]);
    } else if (Platform.isMacOS) {
      Process.run('open', [path]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [path]);
    }
  }

  void _showBrowseDialog() {
    final controller = TextEditingController(text: appdata.settings[22]);
    final isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("设置下载目录".tl),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    decoration: InputDecoration(
                      hintText: "请输入下载目录路径".tl,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () async {
                    final picked = await _pickFolder();
                    if (picked != null) {
                      controller.text = picked;
                    }
                  },
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: Text("浏览".tl),
                ),
              ],
            ),
            if (isDesktop && controller.text.isNotEmpty) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    _openCurrentDirectory(controller.text.trim());
                  },
                  icon: const Icon(Icons.launch, size: 18),
                  label: Text("打开当前目录".tl),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("取消".tl),
          ),
          TextButton(
            onPressed: () {
              final newPath = controller.text.trim();
              appdata.settings[22] = newPath;
              appdata.updateSettings();
              setState(() {});
              Navigator.of(ctx).pop();
            },
            child: Text("确定".tl),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final path = appdata.settings[22];
    final display = path.isEmpty ? "未设置".tl : path;
    return ListTile(
      title: Text("下载目录".tl),
      trailing: GestureDetector(
        onTap: _showBrowseDialog,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 160),
          height: 40,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Theme.of(context).colorScheme.outline),
          ),
          child: Text(
            display,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14),
          ),
        ),
      ),
    );
  }
}

class DataManageSetting extends StatelessWidget {
  DataManageSetting({super.key});

  final LocalFavoritesManager _favManager = LocalFavoritesManager();

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "数据管理".tl,
      child: ListView(
        children: [
          ListTile(
            title: Text("刷新数据".tl),
            onTap: () async {
              await appdata.readData();
              await _favManager.init();
              if (context.mounted) {
                context.pop();
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('重新扫描磁盘'),
            subtitle: const Text('从下载目录重新扫描漫画文件并更新数据库'),
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('重新扫描'),
                  content: const Text('此操作将清空现有下载数据库并重新扫描磁盘。确定继续吗？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('确定'),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;

              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('正在扫描...')),
                );
              }

              await DownloadManager().init();
              final count = DownloadManager().scanDirectoryForComics();

              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('扫描完成，共发现 $count 个漫画')),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

class LogSetting extends StatelessWidget {
  const LogSetting({super.key});

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "日志".tl,
      child: const Center(
        child: Text("暂无日志"),
      ),
    );
  }
}

class PermissionSetting extends StatefulWidget {
  const PermissionSetting({super.key});

  @override
  State<PermissionSetting> createState() => _PermissionSettingState();
}

class _PermissionSettingState extends State<PermissionSetting> {
  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "权限管理".tl,
      child: ListView(
        children: [
          SettingsTitle("隐私".tl),
          SwitchSetting(
            title: "阻止屏幕截图".tl,
            settingsIndex: 12,
          ),
          SwitchSetting(
            title: "需要生物识别".tl,
            settingsIndex: 13,
          ),
        ],
      ),
    );
  }
}
