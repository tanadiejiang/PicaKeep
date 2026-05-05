import 'package:flutter/material.dart';
import 'package:picakeep/pages/app_capabilities_page.dart';
import 'package:picakeep/pages/local_library_page.dart';
import 'package:picakeep/tools/translations.dart';

class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("工具".tl),
      ),
      body: ListView(
        children: [
          _ToolItem(
            icon: Icons.folder_open,
            title: "本地文件管理".tl,
            subtitle: "管理本地漫画路径与目录来源".tl,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const LocalLibraryFilesPage()),
              );
            },
          ),
          const Divider(height: 1),
          _ToolItem(
            icon: Icons.storage,
            title: "存储空间".tl,
            subtitle: "查看每个本地路径与图集占用".tl,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const LocalLibraryStoragePage()),
              );
            },
          ),
          const Divider(height: 1),
          _ToolItem(
            icon: Icons.photo_library,
            title: "本地图集".tl,
            subtitle: "浏览聚合后的本地漫画与图集".tl,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LocalLibraryPage()),
              );
            },
          ),
          const Divider(height: 1),
          _ToolItem(
            icon: Icons.cloud_sync_outlined,
            title: "APP能力".tl,
            subtitle: "查看云端 / NAS 一体化扩展规划与后续入口".tl,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AppCapabilitiesPage()),
              );
            },
          ),
          const Divider(height: 1),
          _ToolItem(
            icon: Icons.delete_sweep,
            title: "清理缓存".tl,
            subtitle: "清理本地缓存数据".tl,
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('工具 "${"清理缓存".tl}" 待实现'.tl),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ToolItem extends StatelessWidget {
  const _ToolItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
