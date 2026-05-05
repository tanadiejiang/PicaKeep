import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/service_data_source.dart';
import 'package:picakeep/server/local_server_runtime.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:url_launcher/url_launcher.dart';

class ServiceInfoPage extends StatefulWidget {
  const ServiceInfoPage({super.key});

  @override
  State<ServiceInfoPage> createState() => _ServiceInfoPageState();
}

String _buildServerPreviewText(ServerPlatformCapability capability) {
  if (capability.isEnhancedServerTarget) {
    return '${capability.displayName} 服务端更依赖前台服务常驻与后台网页；当前这里先提供管理后台流程预览。';
  }
  if (capability.isFullServerTarget) {
    return '${capability.displayName} 服务端已经接到真实本地 HTTP 服务，可直接通过独立后台网页查看和管理当前节点。';
  }
  return '当前平台暂不纳入服务端目标；这里先保留管理后台流程预览。';
}

String _buildServerModeDescription(ServerPlatformCapability capability) {
  if (capability.isEnhancedServerTarget) {
    return '当前按服务端模式展示。Android 目标是移动增强服务端，主要依赖前台服务常驻与后台网页查看状态。';
  }
  if (capability.isFullServerTarget) {
    return '${capability.displayName} 当前属于完整服务端目标，可持续开服，后台网页是主要管理入口。';
  }
  return '当前按服务端模式展示，但当前平台暂不纳入服务端目标。';
}

class _ServiceInfoPageState extends State<ServiceInfoPage> {
  ServiceInfoSnapshot? _snapshot;
  bool _loading = true;

  String get _serverAddress =>
      appdata.settings[remoteServerAddressSettingIndex].trim();

  String get _adminPort => normalizeServiceAdminPortValue(
        appdata.settings[serviceAdminPortSettingIndex],
      );

  @override
  void initState() {
    super.initState();
    App.serviceConfigVersion.addListener(_handleServiceConfigChanged);
    App.serviceRuntimeVersion.addListener(_handleServiceConfigChanged);
    _reloadSnapshot();
  }

  @override
  void dispose() {
    App.serviceConfigVersion.removeListener(_handleServiceConfigChanged);
    App.serviceRuntimeVersion.removeListener(_handleServiceConfigChanged);
    super.dispose();
  }

  void _handleServiceConfigChanged() {
    _reloadSnapshot();
  }

  ServiceInfoSnapshot _placeholderSnapshot() {
    final mode =
        normalizeAppRuntimeMode(appdata.settings[appRuntimeModeSettingIndex]);
    return ServiceInfoSnapshot(
      mode: mode,
      connectionState: ServiceConnectionState.idle,
      discoveryMode: normalizeServiceDiscoveryMode(
        appdata.settings[serviceDiscoveryModeSettingIndex],
      ),
      addressInput: _serverAddress,
      normalizedAddress: normalizeRemoteServerAddressValue(_serverAddress),
      adminUrl: buildServiceAdminUrl('<当前设备IP>', port: _adminPort),
      statusText: '正在读取',
      detailText: '正在根据当前运行模式刷新服务状态。',
    );
  }

  Future<void> _reloadSnapshot() async {
    if (mounted) {
      setState(() {
        _loading = true;
      });
    }
    final snapshot =
        await RuntimeServiceDataSourceResolver.current().fetchSnapshot();
    if (!mounted) {
      return;
    }
    setState(() {
      _snapshot = snapshot;
      _loading = false;
    });
  }

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
    App.notifyServiceConfigChanged();
  }

  void _showPendingDiscoveryMessage() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('自动发现将优先使用 mDNS / Bonjour，当前还未接入真实扫描逻辑'.tl),
      ),
    );
  }

  Future<void> _copyText(String text, String successMessage) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(successMessage.tl)),
    );
  }

  String _buildLocalServiceUrl(String path) {
    final port = int.tryParse(_adminPort) ?? 9527;
    return Uri(scheme: 'http', host: '127.0.0.1', port: port, path: path)
        .toString();
  }

  Future<void> _copyAdminUrl(ServiceInfoSnapshot snapshot) {
    final url = (snapshot.adminUrl?.trim().isNotEmpty ?? false)
        ? snapshot.adminUrl!.trim()
        : buildServiceAdminUrl('<当前设备IP>', port: _adminPort);
    return _copyText(
      url,
      currentServerPlatformCapability().isFullServerTarget
          ? '已复制后台地址'
          : '已复制后台地址模板',
    );
  }

  Future<void> _openLocalServicePage(String path) async {
    final launched = await launchUrl(
      Uri.parse(_buildLocalServiceUrl(path)),
      mode: LaunchMode.externalApplication,
    );
    if (!mounted || launched) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('无法打开本机后台页面'.tl)),
    );
  }

  Future<void> _runLocalServerAction(
    Future<void> Function() action,
    String successMessage,
  ) async {
    try {
      await action();
      await _reloadSnapshot();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(successMessage.tl)),
      );
    } catch (e) {
      await _reloadSnapshot();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('服务操作失败：$e'.tl)),
      );
    }
  }

  String _formatBytes(int? bytes) {
    if (bytes == null || bytes <= 0) {
      return '--';
    }
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    final fractionDigits = value >= 10 || unitIndex == 0 ? 0 : 1;
    return '${value.toStringAsFixed(fractionDigits)} ${units[unitIndex]}';
  }

  Widget _buildClientSection(ServiceInfoSnapshot snapshot) {
    return Column(
      children: [
        _InfoCard(
          icon: Icons.link,
          title: '客户端连接'.tl,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _InfoRow(
                label: '输入地址'.tl,
                value: snapshot.addressInput.isEmpty
                    ? '未设置'.tl
                    : snapshot.addressInput,
              ),
              const SizedBox(height: 8),
              _InfoRow(
                label: '生效地址'.tl,
                value: snapshot.normalizedAddress.isEmpty
                    ? '--'
                    : snapshot.normalizedAddress,
              ),
              const SizedBox(height: 8),
              _InfoRow(
                label: '状态接口'.tl,
                value: snapshot.statusUrl?.isNotEmpty == true
                    ? snapshot.statusUrl!
                    : '--',
              ),
              const SizedBox(height: 8),
              _InfoRow(
                label: '连接状态'.tl,
                value: _loading ? '刷新中'.tl : snapshot.statusText,
              ),
              const SizedBox(height: 8),
              _InfoRow(
                label: '详细信息'.tl,
                value: snapshot.detailText,
              ),
              const SizedBox(height: 8),
              _InfoRow(
                label: '延迟 / 状态码'.tl,
                value:
                    '${snapshot.latencyMs?.toString() ?? '--'} ms / ${snapshot.httpStatusCode?.toString() ?? '--'}',
              ),
              const SizedBox(height: 8),
              _InfoRow(
                label: '漫画数量 / 连接数'.tl,
                value:
                    '${snapshot.comicCount?.toString() ?? '--'} / ${snapshot.connectionCount?.toString() ?? '--'}',
              ),
              const SizedBox(height: 8),
              _InfoRow(
                label: '资源根 / 总体积'.tl,
                value:
                    '${snapshot.libraryRootCount?.toString() ?? '--'} / ${_formatBytes(snapshot.resourceBytes)}',
              ),
              const SizedBox(height: 8),
              _InfoRow(
                label: '累计请求 / 启动时间'.tl,
                value:
                    '${snapshot.totalRequests?.toString() ?? '--'} / ${snapshot.startedAt ?? '--'}',
              ),
              const SizedBox(height: 8),
              _InfoRow(
                label: '后台地址'.tl,
                value: snapshot.adminUrl?.isNotEmpty == true
                    ? snapshot.adminUrl!
                    : '--',
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
                  FilledButton(
                    onPressed: _loading ? null : _reloadSnapshot,
                    child: Text('刷新状态'.tl),
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
            snapshot.discoveryMode == serviceDiscoveryModeMdns
                ? '当前确定使用 mDNS / Bonjour 作为首选发现方式，比自定义 UDP 广播更收敛，不会对局域网里其他设备做额外噪声扫描。'
                    .tl
                : '当前预留 UDP 广播方案，但默认仍建议优先采用 mDNS / Bonjour。'.tl,
          ),
        ),
      ],
    );
  }

  Widget _buildServerSection(ServiceInfoSnapshot snapshot) {
    final capability = currentServerPlatformCapability();
    return _InfoCard(
      icon: Icons.dns_outlined,
      title: '服务端状态'.tl,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoRow(
            label: '运行状态'.tl,
            value: _loading ? '刷新中'.tl : snapshot.statusText,
          ),
          const SizedBox(height: 8),
          _InfoRow(
            label: '详细信息'.tl,
            value: snapshot.detailText,
          ),
          const SizedBox(height: 8),
          _InfoRow(
            label: '连接数 / 日志'.tl,
            value: '${snapshot.connectionCount?.toString() ?? '0'} / 默认不记录'.tl,
          ),
          const SizedBox(height: 8),
          _InfoRow(
            label: '资源根 / 总体积'.tl,
            value:
                '${snapshot.libraryRootCount?.toString() ?? '--'} / ${_formatBytes(snapshot.resourceBytes)}',
          ),
          const SizedBox(height: 8),
          _InfoRow(
            label: '累计请求 / 启动时间'.tl,
            value:
                '${snapshot.totalRequests?.toString() ?? '--'} / ${snapshot.startedAt ?? '--'}',
          ),
          const SizedBox(height: 8),
          _InfoRow(
            label: '后台地址'.tl,
            value: snapshot.adminUrl ??
                buildServiceAdminUrl('<当前设备IP>', port: _adminPort),
          ),
          if (capability.isFullServerTarget) ...[
            const SizedBox(height: 8),
            _InfoRow(
              label: '本机直连后台'.tl,
              value: _buildLocalServiceUrl('/admin'),
            ),
            const SizedBox(height: 8),
            _InfoRow(
              label: '状态接口'.tl,
              value: _buildLocalServiceUrl('/status'),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            _buildServerPreviewText(capability).tl,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (capability.isFullServerTarget)
                FilledButton(
                  onPressed: _loading
                      ? null
                      : snapshot.connectionState ==
                              ServiceConnectionState.online
                          ? () {
                              _runLocalServerAction(
                                LocalServerRuntime.instance.stop,
                                '服务已停止',
                              );
                            }
                          : () {
                              _runLocalServerAction(
                                LocalServerRuntime.instance.start,
                                '服务已启动',
                              );
                            },
                  child: Text(
                    snapshot.connectionState == ServiceConnectionState.online
                        ? '停止服务'.tl
                        : '启动服务'.tl,
                  ),
                ),
              if (capability.isFullServerTarget)
                FilledButton.tonal(
                  onPressed: _loading
                      ? null
                      : () {
                          _runLocalServerAction(
                            LocalServerRuntime.instance.restart,
                            '服务已重启',
                          );
                        },
                  child: Text('重启服务'.tl),
                ),
              if (capability.isFullServerTarget)
                FilledButton.tonal(
                  onPressed: _loading ||
                          snapshot.connectionState !=
                              ServiceConnectionState.online
                      ? null
                      : () {
                          _openLocalServicePage('/admin');
                        },
                  child: Text('打开管理后台'.tl),
                ),
              if (capability.isFullServerTarget)
                FilledButton.tonal(
                  onPressed: _loading ||
                          snapshot.connectionState !=
                              ServiceConnectionState.online
                      ? null
                      : () {
                          _openLocalServicePage('/status');
                        },
                  child: Text('打开状态接口'.tl),
                ),
              FilledButton.tonal(
                onPressed: () {
                  _copyAdminUrl(snapshot);
                },
                child: Text(
                  capability.isFullServerTarget ? '复制后台地址'.tl : '复制后台地址模板'.tl,
                ),
              ),
              FilledButton.tonal(
                onPressed: _loading ? null : _reloadSnapshot,
                child: Text('刷新状态'.tl),
              ),
              if (!capability.isFullServerTarget)
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot ?? _placeholderSnapshot();
    return SizedBox.expand(
      child: RefreshIndicator(
        onRefresh: _reloadSnapshot,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            _ModeOverviewCard(snapshot: snapshot, loading: _loading),
            const SizedBox(height: 12),
            if (snapshot.isClientMode)
              _buildClientSection(snapshot)
            else
              _buildServerSection(snapshot),
          ],
        ),
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
  const _ModeOverviewCard({required this.snapshot, required this.loading});

  final ServiceInfoSnapshot snapshot;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final modeLabel = snapshot.isServerMode ? '服务端'.tl : '客户端'.tl;
    final capability = currentServerPlatformCapability();
    final description = snapshot.isServerMode
        ? _buildServerModeDescription(capability).tl
        : '当前按客户端模式展示。当前状态已开始根据服务端地址与 /status 接口实时读取。'.tl;
    return _InfoCard(
      icon: Icons.cloud_sync_outlined,
      title: '服务信息'.tl,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoRow(label: '当前运行模式'.tl, value: modeLabel),
          const SizedBox(height: 8),
          _InfoRow(
            label: '当前状态'.tl,
            value: loading ? '刷新中'.tl : snapshot.statusText,
          ),
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
