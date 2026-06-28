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
    const Divider(),
    SettingsTitle('禁漫 (jm) 网络'.tl),
    const _JmApiDomainsTile(),
  ]);
}

/// jm API 域名设置：自动更新（拉 bytepluses）+ 手填兜底 + API 分流选择
class _JmApiDomainsTile extends StatefulWidget {
  const _JmApiDomainsTile();

  @override
  State<_JmApiDomainsTile> createState() => _JmApiDomainsTileState();
}

class _JmApiDomainsTileState extends State<_JmApiDomainsTile> {
  bool _busy = false;

  List<String> get _domains => appdata.settings[85]
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  Future<void> _updateDomains() async {
    setState(() => _busy = true);
    try {
      final ok = await JmNetwork().getApiDomains();
      if (!mounted) return;
      setState(() {});
      final domains = appdata.settings[85];
      if (ok) {
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('更新成功'),
            content: Text('已获取域名：\n$domains'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('确定'),
              ),
            ],
          ),
        );
      } else {
        _showSettingMessage(context, '域名获取失败，仍使用当前域名');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _editDomains() {
    final ctrl = TextEditingController(text: appdata.settings[85]);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手填 jm API 域名'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            hintText: 'domain1.com,domain2.com',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final val = ctrl.text.trim();
              if (val.isNotEmpty) {
                appdata.settings[85] = val;
                await appdata.updateSettings();
                await JmNetwork().selectDomain();
              }
              if (ctx.mounted) Navigator.of(ctx).pop();
              if (mounted) {
                setState(() {});
                _showSettingMessage(context, '域名已保存');
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final domains = _domains;
    final idx = (int.tryParse(appdata.settings[17]) ?? 0)
        .clamp(0, domains.isEmpty ? 0 : domains.length - 1);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('jm API 域名'),
          subtitle: Text(
            appdata.settings[85],
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          trailing: _busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Wrap(
                  spacing: 0,
                  children: [
                    TextButton(
                      onPressed: _updateDomains,
                      child: const Text('自动更新'),
                    ),
                    TextButton(
                      onPressed: _editDomains,
                      child: const Text('手填'),
                    ),
                  ],
                ),
        ),
        if (domains.length > 1)
          buildResponsiveSettingTile(
            leading: const Icon(Icons.alt_route),
            title: const Text('API 分流'),
            subtitle: const Text('手动选择使用第几个 API 域名'),
            trailingWidth: 150,
            trailing: Select(
              width: 150,
              initialValue: idx.toString(),
              values: [for (var i = 0; i < domains.length; i++) i.toString()],
              titles: [for (var i = 0; i < domains.length; i++) '分流${i + 1}'],
              onChanged: (value) {
                appdata.settings[17] = value;
                appdata.updateSettings();
              },
            ),
          ),
      ],
    );
  }
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
