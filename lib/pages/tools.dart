import 'package:flutter/material.dart';
import 'package:picakeep/pages/app_capabilities_page.dart';
import 'package:picakeep/pages/local_library_page.dart';
import 'package:picakeep/pages/service_info_page.dart';
import 'package:picakeep/pages/trash_page.dart';
import 'package:picakeep/tools/io_tools.dart';
import 'package:picakeep/tools/translations.dart';

class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('工具'.tl),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          _ToolCard(
            icon: Icons.router_outlined,
            title: '服务信息'.tl,
            subtitle: '查看当前连接状态、扫描局域网并切换远程服务'.tl,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const ServiceInfoPage(standalone: true),
                ),
              );
            },
          ),
          _ToolCard(
            icon: Icons.folder_open,
            title: '本地文件管理'.tl,
            subtitle: '管理本地漫画路径与目录来源'.tl,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const LocalLibraryFilesPage(),
                ),
              );
            },
          ),
          _ToolCard(
            icon: Icons.storage,
            title: '存储空间'.tl,
            subtitle: '查看每个本地路径与图集占用'.tl,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const LocalLibraryStoragePage(),
                ),
              );
            },
          ),
          _ToolCard(
            icon: Icons.photo_library,
            title: '图集'.tl,
            subtitle: '浏览并切换本地 / 聚合 / 远程图集'.tl,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const LocalLibraryPage(
                    albumOnly: true,
                    title: '图集',
                  ),
                ),
              );
            },
          ),
          _ToolCard(
            icon: Icons.cloud_sync_outlined,
            title: 'APP能力'.tl,
            subtitle: '管理客户端 / 服务端运行能力与未来规划'.tl,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AppCapabilitiesPage()),
              );
            },
          ),
          _ToolCard(
            icon: Icons.restore_from_trash_outlined,
            title: '回收站'.tl,
            subtitle: '恢复或彻底删除本地与远程已删除项目'.tl,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TrashPage()),
              );
            },
          ),
          _ToolCard(
            icon: Icons.delete_sweep,
            title: '清理缓存'.tl,
            subtitle: '清理本地缓存数据'.tl,
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              messenger.hideCurrentSnackBar();
              messenger.showSnackBar(
                SnackBar(
                  content: Text('正在清理缓存'.tl),
                  duration: const Duration(seconds: 10),
                ),
              );
              await eraseCache();
              if (!context.mounted) {
                return;
              }
              messenger.hideCurrentSnackBar();
              messenger.showSnackBar(
                SnackBar(
                  content: Text('缓存已清理'.tl),
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

class _ToolCard extends StatelessWidget {
  const _ToolCard({
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
    return Card.outlined(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
