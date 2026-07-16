part of 'settings_page.dart';

/// 网络设置分组（位于「APP」与「下载」之间）。
///
/// 目前承载代理地址设置 settings[8]：填写后在线源、WebView 和公网远程服务
/// 使用该 HTTP 代理；局域网远程服务仍按策略直连。留空时各网络栈回退到自身环境规则。
Widget buildNetworkSettings(double width, BuildContext context) {
  return buildTwoColumnLayout(width, [
    SettingsTitle('代理'.tl),
    const _ProxyAddressTile(),
  ]);
}

/// 代理地址设置项：读写 settings[8]（host:port，可空）。
///
/// Android WebView 与 Dart 网络栈的环境代理来源不同；手填代理后两者都会使用它。
class _ProxyAddressTile extends StatefulWidget {
  const _ProxyAddressTile();

  @override
  State<_ProxyAddressTile> createState() => _ProxyAddressTileState();
}

class _ProxyAddressTileState extends State<_ProxyAddressTile> {
  // 形如 host:port，host 不含空白与冒号，port 为数字。
  static final _proxyReg = RegExp(r'^[^:\s]+:\d+$');

  Future<void> _saveProxy(String value) async {
    final normalized = value.trim();
    if (appdata.settings[8].trim() == normalized) {
      return;
    }
    appdata.settings[8] = normalized;
    await appdata.updateSettings();
    RemoteLibraryClient.rebuildAllTransports();
    App.notifyServiceConfigChanged();
  }

  void _editProxy() {
    final ctrl = TextEditingController(text: appdata.settings[8]);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('代理地址'.tl),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                hintText: '127.0.0.1:7890',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _confirm(ctx, ctrl),
            ),
            const SizedBox(height: 8),
            Text(
              '格式 host:port（仅 HTTP 代理）。留空则跟随系统代理。'.tl,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消'.tl),
          ),
          FilledButton(
            onPressed: () => _confirm(ctx, ctrl),
            child: Text('保存'.tl),
          ),
        ],
      ),
    );
  }

  Future<void> _confirm(BuildContext ctx, TextEditingController ctrl) async {
    final val = ctrl.text.trim();
    // 允许空串（=不使用手动代理）；非空时校验 host:port 格式。
    if (val.isNotEmpty && !_proxyReg.hasMatch(val)) {
      _showSettingMessage(context, '代理地址格式应为 host:port'.tl);
      return;
    }
    await _saveProxy(val);
    if (ctx.mounted) Navigator.of(ctx).pop();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final addr = appdata.settings[8].trim();
    final display = addr.isEmpty ? '未设置（按各网络栈规则）'.tl : addr;
    return ListTile(
      leading: const Icon(Icons.vpn_key_outlined),
      title: Text('代理地址'.tl),
      subtitle: Text(
        display,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: addr.isEmpty
          ? null
          : IconButton(
              tooltip: '清除'.tl,
              icon: const Icon(Icons.clear),
              onPressed: () async {
                await _saveProxy('');
                if (mounted) setState(() {});
              },
            ),
      onTap: _editProxy,
    );
  }
}
