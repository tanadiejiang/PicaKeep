import 'package:flutter/material.dart';

class ToolsPage extends StatelessWidget {
  const ToolsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("\u5DE5\u5177"),
      ),
      body: ListView(
        children: const [
          _ToolItem(
            icon: Icons.folder_open,
            title: "\u672C\u5730\u6587\u4EF6\u7BA1\u7406",
            subtitle: "\u7BA1\u7406\u4E0B\u8F7D\u7684\u6F2B\u753B\u6587\u4EF6",
          ),
          Divider(height: 1),
          _ToolItem(
            icon: Icons.storage,
            title: "\u5B58\u50A8\u7A7A\u95F4",
            subtitle:
                "\u67E5\u770B\u672C\u5730\u5B58\u50A8\u4F7F\u7528\u60C5\u51B5",
          ),
          Divider(height: 1),
          _ToolItem(
            icon: Icons.delete_sweep,
            title: "\u6E05\u7406\u7F13\u5B58",
            subtitle: "\u6E05\u7406\u672C\u5730\u7F13\u5B58\u6570\u636E",
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
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("\u5DE5\u5177 \"$title\" \u5F85\u5B9E\u73B0"),
            duration: const Duration(seconds: 1),
          ),
        );
      },
    );
  }
}
