part of 'settings_page.dart';

Widget _buildDownloadSettings(double width) {
  return buildTwoColumnLayout(width, [
    const SelectSetting(
      leading: Icon(Icons.download_outlined),
      title: '并发下载数',
      settingsIndex: 79,
      values: ['1', '2', '4', '6', '8', '16'],
      titles: ['1', '2', '4', '6（默认）', '8', '16'],
      controlWidth: 120,
      tailing: Icon(Icons.arrow_drop_down),
    ),
    const Divider(),
    const _FixDirectoryNamesTile(),
  ]);
}

class _FixDirectoryNamesTile extends StatefulWidget {
  const _FixDirectoryNamesTile();

  @override
  State<_FixDirectoryNamesTile> createState() => _FixDirectoryNamesTileState();
}

class _FixDirectoryNamesTileState extends State<_FixDirectoryNamesTile> {
  bool _running = false;

  Future<void> _run() async {
    setState(() => _running = true);
    try {
      final result =
          await OnlineDownloadManager.instance.fixDirectoryNames();
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('修正完成'),
          content: Text(
            '已修正：${result.fixed} 个\n'
            '已跳过：${result.skipped} 个\n'
            '失败：${result.failed} 个',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _running
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.drive_file_rename_outline),
      title: const Text('修正已下载文件夹名'),
      subtitle: const Text('将旧的纯 ID 文件夹改为"标题_ID"格式'),
      trailing: _running ? null : const Icon(Icons.arrow_right),
      onTap: _running ? null : _run,
    );
  }
}
