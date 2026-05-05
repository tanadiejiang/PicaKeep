part of 'settings_page.dart';

class _AppServiceSettingsSection extends StatefulWidget {
  const _AppServiceSettingsSection();

  @override
  State<_AppServiceSettingsSection> createState() =>
      _AppServiceSettingsSectionState();
}

class _AppServiceSettingsSectionState
    extends State<_AppServiceSettingsSection> {
  String _mode =
      normalizeAppRuntimeMode(appdata.settings[appRuntimeModeSettingIndex]);

  Future<void> _setMode(String value) async {
    final nextValue = normalizeAppRuntimeMode(value);
    setState(() {
      _mode = nextValue;
      appdata.settings[appRuntimeModeSettingIndex] = nextValue;
    });
    await appdata.updateSettings();
    App.updater?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsTitle('服务'.tl),
        buildResponsiveSettingTile(
          leading: const Icon(Icons.sync_alt),
          title: Text('运行模式'.tl),
          subtitle: Text('当前先在客户端设置页中切换客户端 / 服务端模式'.tl),
          trailingWidth: 140,
          trailing: Select(
            width: 140,
            initialValue: _mode,
            values: const [appRuntimeModeClient, appRuntimeModeServer],
            titles: ['客户端'.tl, '服务端'.tl],
            onChanged: (value) {
              _setMode(value);
            },
          ),
        ),
        const _ServiceDiscoveryStrategyTile(),
        if (_mode == appRuntimeModeClient) const _RemoteServerAddressTile(),
        if (_mode == appRuntimeModeServer) const _ServiceAdminPortTile(),
        ListTile(
          leading: const Icon(Icons.monitor_heart_outlined),
          title: Text('服务信息入口'.tl),
          subtitle: Text('底部 / 侧边导航中的“服务信息”页可查看当前模式与后续服务状态'.tl),
        ),
      ],
    );
  }
}

class _ServiceDiscoveryStrategyTile extends StatelessWidget {
  const _ServiceDiscoveryStrategyTile();

  @override
  Widget build(BuildContext context) {
    return buildResponsiveSettingTile(
      leading: const Icon(Icons.wifi_tethering),
      title: Text('局域网发现方式'.tl),
      subtitle: Text('当前优先采用 mDNS / Bonjour，较 UDP 广播更收敛，不主动打扰局域网内其他设备'.tl),
      trailingWidth: 90,
      trailing: Text(
        'mDNS',
        style: Theme.of(context).textTheme.titleSmall,
      ),
    );
  }
}

class _RemoteServerAddressTile extends StatefulWidget {
  const _RemoteServerAddressTile();

  @override
  State<_RemoteServerAddressTile> createState() =>
      _RemoteServerAddressTileState();
}

class _RemoteServerAddressTileState extends State<_RemoteServerAddressTile> {
  String get _address =>
      appdata.settings[remoteServerAddressSettingIndex].trim();

  Future<void> _editAddress() async {
    final controller = TextEditingController(text: _address);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('服务端地址'.tl),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '例如：http://192.168.1.20:9527'.tl,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: Text('保存'.tl),
          ),
        ],
      ),
    );
    if (!mounted || result == null) {
      return;
    }
    appdata.settings[remoteServerAddressSettingIndex] = result.trim();
    await appdata.updateSettings();
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final address = _address;
    return ListTile(
      leading: const Icon(Icons.link),
      title: Text('服务端地址'.tl),
      subtitle: Text(
        address.isEmpty ? '未设置。客户端模式下连接远程服务前需要先填写地址'.tl : address,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: _editAddress,
    );
  }
}

class _ServiceAdminPortTile extends StatefulWidget {
  const _ServiceAdminPortTile();

  @override
  State<_ServiceAdminPortTile> createState() => _ServiceAdminPortTileState();
}

class _ServiceAdminPortTileState extends State<_ServiceAdminPortTile> {
  String get _port => normalizeServiceAdminPortValue(
        appdata.settings[serviceAdminPortSettingIndex],
      );

  Future<void> _editPort() async {
    final controller = TextEditingController(text: _port);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('后台端口'.tl),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: defaultServiceAdminPort,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext)
                .pop(normalizeServiceAdminPortValue(controller.text)),
            child: Text('保存'.tl),
          ),
        ],
      ),
    );
    if (!mounted || result == null) {
      return;
    }
    appdata.settings[serviceAdminPortSettingIndex] =
        normalizeServiceAdminPortValue(result);
    await appdata.updateSettings();
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final port = _port;
    return ListTile(
      leading: const Icon(Icons.admin_panel_settings_outlined),
      title: Text('后台端口'.tl),
      subtitle: Text(
        '服务端模式下管理后台默认地址模板：@a'.tlParams({
          'a': buildServiceAdminUrl('<当前设备IP>', port: port),
        }),
      ),
      trailing: Text(port),
      onTap: _editPort,
    );
  }
}
