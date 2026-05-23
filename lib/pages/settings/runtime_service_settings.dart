import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/pages/settings/settings_common_widgets.dart';
import 'package:picakeep/server/local_server_runtime_sync.dart';
import 'package:picakeep/tools/translations.dart';

class AppServiceSettingsSection extends StatefulWidget {
  const AppServiceSettingsSection({super.key});

  @override
  State<AppServiceSettingsSection> createState() =>
      _AppServiceSettingsSectionState();
}

class _AppServiceSettingsSectionState extends State<AppServiceSettingsSection> {
  String _mode =
      normalizeAppRuntimeMode(appdata.settings[appRuntimeModeSettingIndex]);

  @override
  void initState() {
    super.initState();
    Future.microtask(_normalizeModeForCurrentPlatform);
  }

  Future<void> _normalizeModeForCurrentPlatform() async {
    if (_mode != appRuntimeModeServer || canUseServerModeOnCurrentPlatform()) {
      return;
    }
    _mode = appRuntimeModeClient;
    appdata.settings[appRuntimeModeSettingIndex] = _mode;
    await appdata.updateSettings();
    App.notifyServiceConfigChanged();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _syncLocalServerRuntime({
    bool restartIfRunning = false,
  }) async {
    if (!canManageLocalServerRuntime()) {
      return;
    }
    try {
      await syncLocalServerRuntimeForCurrentMode(
        restartIfRunning: restartIfRunning,
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('本地服务操作失败：$e'.tl),
        ),
      );
    }
  }

  Future<void> _setMode(String value) async {
    final nextValue = normalizeAppRuntimeMode(value);
    if (nextValue == appRuntimeModeServer &&
        !canUseServerModeOnCurrentPlatform()) {
      final capability = currentServerPlatformCapability();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${capability.displayName} 当前暂不纳入服务端目标，现阶段仅保留客户端模式'.tl,
          ),
        ),
      );
      return;
    }
    setState(() {
      _mode = nextValue;
      appdata.settings[appRuntimeModeSettingIndex] = nextValue;
    });
    await appdata.updateSettings();
    App.notifyServiceConfigChanged();
    await _syncLocalServerRuntime();
  }

  Widget _buildModeOption(
    BuildContext context, {
    required String value,
    required String label,
    required bool selected,
    required bool isFirst,
    required bool isLast,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.only(
      topLeft: isFirst ? const Radius.circular(999) : Radius.zero,
      bottomLeft: isFirst ? const Radius.circular(999) : Radius.zero,
      topRight: isLast ? const Radius.circular(999) : Radius.zero,
      bottomRight: isLast ? const Radius.circular(999) : Radius.zero,
    );
    return Expanded(
      child: InkWell(
        borderRadius: radius,
        onTap: selected ? null : () => _setMode(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 36,
          decoration: BoxDecoration(
            color: selected ? colorScheme.primaryContainer : Colors.transparent,
            border: Border(
              left: isFirst
                  ? BorderSide.none
                  : BorderSide(color: colorScheme.outlineVariant),
            ),
            borderRadius: radius,
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeSelector(
    BuildContext context, {
    required List<String> modeValues,
    required List<String> modeTitles,
    required String currentMode,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colorScheme.outline),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: Row(
          children: [
            for (int i = 0; i < modeValues.length; i++)
              _buildModeOption(
                context,
                value: modeValues[i],
                label: modeTitles[i],
                selected: currentMode == modeValues[i],
                isFirst: i == 0,
                isLast: i == modeValues.length - 1,
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final capability = currentServerPlatformCapability();
    final canUseServerMode = capability.supportsServerMode;
    final currentMode = canUseServerMode ? _mode : appRuntimeModeClient;
    final modeValues = canUseServerMode
        ? const [appRuntimeModeClient, appRuntimeModeServer]
        : const [appRuntimeModeClient];
    final modeTitles = canUseServerMode ? ['客户端'.tl, '服务端'.tl] : ['客户端'.tl];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsTitle('服务'.tl),
        buildResponsiveSettingTile(
          leading: const Icon(Icons.sync_alt),
          title: Text('运行模式'.tl),
          subtitle: Text(
            '当前平台：@a · @b'.tlParams({
              'a': capability.displayName,
              'b': serverPlatformTierLabel(capability.tier),
            }),
          ),
          trailingWidth: 200,
          trailing: _buildModeSelector(
            context,
            modeValues: modeValues,
            modeTitles: modeTitles,
            currentMode: currentMode,
          ),
        ),
        ListTile(
          leading: Icon(
            capability.isFullServerTarget
                ? Icons.dns_outlined
                : capability.isEnhancedServerTarget
                    ? Icons.phone_android_outlined
                    : Icons.block_outlined,
          ),
          title: Text('当前平台服务端能力'.tl),
          subtitle: Text(
            '${capability.summary} ${serverPlatformTierDescription(capability.tier)} ${capability.notes.first}'
                .tl,
          ),
        ),
        const _ServiceDiscoveryStrategyTile(),
        if (currentMode == appRuntimeModeClient)
          const _RemoteServerAddressTile(),
        if (currentMode == appRuntimeModeServer) const _ServiceAdminPortTile(),
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
    App.notifyServiceConfigChanged();
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
    App.notifyServiceConfigChanged();
    try {
      await syncLocalServerRuntimeForCurrentMode(
        restartIfRunning: true,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('本地服务操作失败：$e'.tl),
          ),
        );
      }
    }
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
