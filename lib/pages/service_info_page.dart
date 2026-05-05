import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/tools/translations.dart';

class ServiceInfoPage extends StatefulWidget {
  const ServiceInfoPage({super.key});

  @override
  State<ServiceInfoPage> createState() => _ServiceInfoPageState();
}

class _ServiceInfoPageState extends State<ServiceInfoPage> {
  String get _mode =>
      normalizeAppRuntimeMode(appdata.settings[appRuntimeModeSettingIndex]);

  String get _serverAddress =>
      appdata.settings[remoteServerAddressSettingIndex].trim();

  String get _adminPort => normalizeServiceAdminPortValue(
        appdata.settings[serviceAdminPortSettingIndex],
      );

  Future<void> _editServerAddress() async {
    final controller = TextEditingController(text: _serverAddress);
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

  void _showPendingDiscoveryMessage() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('自动发现将优先使用 mDNS / Bonjour，当前还未接入真实扫描逻辑'.tl),
      ),
    );
  }

  Future<void> _copyAdminUrl() async {
    final url = buildServiceAdminUrl('<当前设备IP>', port: _adminPort);
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制后台地址模板'.tl)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          _ModeOverviewCard(mode: _mode),
          const SizedBox(height: 12),
          if (_mode == appRuntimeModeClient) ...[
            _InfoCard(
              icon: Icons.link,
              title: '客户端连接'.tl,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _InfoRow(
                    label: '当前地址'.tl,
                    value: _serverAddress.isEmpty ? '未设置'.tl : _serverAddress,
                  ),
                  const SizedBox(height: 8),
                  _InfoRow(
                    label: '连接状态'.tl,
                    value: '未连接（远程数据源尚未接入）'.tl,
                  ),
                  const SizedBox(height: 8),
                  _InfoRow(
                    label: '延迟 / 漫画数量'.tl,
                    value: '-- / --',
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonal(
                        onPressed: _editServerAddress,
                        child: Text('填写地址'.tl),
                      ),
                      FilledButton.tonal(
                        onPressed: _showPendingDiscoveryMessage,
                        child: Text('扫描局域网'.tl),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _InfoCard(
              icon: Icons.wifi_tethering,
              title: '自动发现策略'.tl,
              child: Text(
                '当前确定使用 mDNS / Bonjour 作为首选发现方式，比自定义 UDP 广播更收敛，不会对局域网里其他设备做额外噪声扫描。'
                    .tl,
              ),
            ),
          ] else ...[
            _InfoCard(
              icon: Icons.dns_outlined,
              title: '服务端状态'.tl,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _InfoRow(
                    label: '运行状态'.tl,
                    value: '未启动（服务端进程尚未接入）'.tl,
                  ),
                  const SizedBox(height: 8),
                  _InfoRow(
                    label: '连接数 / 日志'.tl,
                    value: '0 / 默认不记录'.tl,
                  ),
                  const SizedBox(height: 8),
                  _InfoRow(
                    label: '后台地址模板'.tl,
                    value: buildServiceAdminUrl('<当前设备IP>', port: _adminPort),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Linux 服务端实际无屏运行时，请通过独立后台网页查看相关内容；当前这里先提供管理后台流程预览。'.tl,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonal(
                        onPressed: _copyAdminUrl,
                        child: Text('复制后台地址模板'.tl),
                      ),
                      FilledButton(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const AdminLoginPreviewPage(),
                            ),
                          );
                        },
                        child: Text('后台登录预览'.tl),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class AdminLoginPreviewPage extends StatefulWidget {
  const AdminLoginPreviewPage({super.key});

  @override
  State<AdminLoginPreviewPage> createState() => _AdminLoginPreviewPageState();
}

class _AdminLoginPreviewPageState extends State<AdminLoginPreviewPage> {
  double _sliderValue = 0;
  bool _loggedIn = false;

  void _handleSliderEnd(double value) {
    if (value >= 0.95) {
      setState(() {
        _loggedIn = true;
        _sliderValue = 1;
      });
      return;
    }
    setState(() {
      _sliderValue = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('后台登录预览'.tl),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          _InfoCard(
            icon: _loggedIn ? Icons.verified_user_outlined : Icons.lock_outline,
            title: _loggedIn ? '已进入后台'.tl : '滑动登录'.tl,
            child: !_loggedIn
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('当前先使用滑动成功即登录的占位方案，后续再替换成真正的后台认证流程。'.tl),
                      const SizedBox(height: 16),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 48,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 14,
                          ),
                        ),
                        child: Slider(
                          value: _sliderValue,
                          onChanged: (value) {
                            setState(() {
                              _sliderValue = value;
                            });
                          },
                          onChangeEnd: _handleSliderEnd,
                        ),
                      ),
                      Center(
                        child: Text('向右滑动完成登录'.tl),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _InfoRow(label: '服务状态', value: '在线（预览态）'),
                      const SizedBox(height: 8),
                      const _InfoRow(label: '连接数', value: '0'),
                      const SizedBox(height: 8),
                      const _InfoRow(label: '最近日志', value: '当前暂无日志输出'),
                      const SizedBox(height: 12),
                      FilledButton.tonal(
                        onPressed: () {
                          setState(() {
                            _loggedIn = false;
                            _sliderValue = 0;
                          });
                        },
                        child: Text('退出预览'.tl),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _ModeOverviewCard extends StatelessWidget {
  const _ModeOverviewCard({required this.mode});

  final String mode;

  @override
  Widget build(BuildContext context) {
    final modeLabel = mode == appRuntimeModeServer ? '服务端'.tl : '客户端'.tl;
    final description = mode == appRuntimeModeServer
        ? '当前按服务端模式展示。真实 Linux 无屏环境将主要通过后台网页查看状态。'.tl
        : '当前按客户端模式展示。后续会在这里查看远程连接状态与自动发现结果。'.tl;
    return _InfoCard(
      icon: Icons.cloud_sync_outlined,
      title: '服务信息'.tl,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoRow(label: '当前运行模式'.tl, value: modeLabel),
          const SizedBox(height: 8),
          Text(description),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(value)),
      ],
    );
  }
}
