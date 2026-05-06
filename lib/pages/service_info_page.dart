import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/service_data_source.dart';
import 'package:picakeep/server/local_server_runtime.dart';
import 'package:picakeep/tools/android_foreground_service.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:url_launcher/url_launcher.dart';

class ServiceInfoPage extends StatefulWidget {
  const ServiceInfoPage({super.key, this.standalone = false});

  final bool standalone;

  @override
  State<ServiceInfoPage> createState() => _ServiceInfoPageState();
}

String _buildServerPreviewText(ServerPlatformCapability capability) {
  if (capability.isEnhancedServerTarget) {
    return '${capability.displayName} 服务端已经接到真实本地 HTTP 服务与前台服务常驻链路；通知、后台网页与保活设置会共同参与维持服务端模式。';
  }
  if (capability.isFullServerTarget) {
    return '${capability.displayName} 服务端已经接到真实本地 HTTP 服务，可直接通过独立后台网页查看和管理当前节点。';
  }
  return '当前平台暂不纳入服务端目标；这里先保留管理后台流程预览。';
}

String _buildServerModeDescription(ServerPlatformCapability capability) {
  if (capability.isEnhancedServerTarget) {
    return '当前按服务端模式展示。Android 目标已接到本地 HTTP 服务、前台通知与保活约束适配，可通过后台网页查看状态。';
  }
  if (capability.isFullServerTarget) {
    return '${capability.displayName} 当前属于完整服务端目标，可持续开服，后台网页是主要管理入口。';
  }
  return '当前按服务端模式展示，但当前平台暂不纳入服务端目标。';
}

class _ServiceInfoPageState extends State<ServiceInfoPage> {
  ServiceInfoSnapshot? _snapshot;
  AndroidForegroundServiceSupportState? _androidSupportState;
  bool _loading = true;
  bool _discovering = false;
  bool _loadingAndroidSupportState = false;

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
    if (currentServerPlatformCapability().isEnhancedServerTarget) {
      _reloadAndroidSupportState();
    }
  }

  @override
  void dispose() {
    App.serviceConfigVersion.removeListener(_handleServiceConfigChanged);
    App.serviceRuntimeVersion.removeListener(_handleServiceConfigChanged);
    super.dispose();
  }

  void _handleServiceConfigChanged() {
    _reloadSnapshot();
    if (currentServerPlatformCapability().isEnhancedServerTarget) {
      _reloadAndroidSupportState();
    }
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

  Future<void> _reloadAndroidSupportState() async {
    if (!currentServerPlatformCapability().isEnhancedServerTarget) {
      return;
    }
    if (mounted) {
      setState(() {
        _loadingAndroidSupportState = true;
      });
    }
    final supportState =
        await AndroidForegroundServiceController.instance.readSupportState();
    if (!mounted) {
      return;
    }
    setState(() {
      _androidSupportState = supportState;
      _loadingAndroidSupportState = false;
    });
  }

  Future<void> _requestAndroidNotificationPermission() async {
    final granted = await AndroidForegroundServiceController.instance
        .requestNotificationPermission();
    await _reloadAndroidSupportState();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(granted ? '通知权限已更新'.tl : '通知权限仍未开启'.tl)),
    );
  }

  Future<void> _openAndroidNotificationSettings() async {
    await AndroidForegroundServiceController.instance
        .openNotificationSettings();
    await _reloadAndroidSupportState();
  }

  Future<void> _openAndroidBatteryOptimizationSettings() async {
    await AndroidForegroundServiceController.instance
        .openBatteryOptimizationSettings();
    await _reloadAndroidSupportState();
  }

  Future<void> _editServerAddress() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => _ServerAddressEditorSheet(initialValue: _serverAddress),
    );
    if (!mounted || result == null) {
      return;
    }
    appdata.settings[remoteServerAddressSettingIndex] = result.trim();
    await appdata.updateSettings();
    App.notifyServiceConfigChanged();
  }

  Future<void> _scanLocalNetwork() async {
    if (_discovering) {
      return;
    }
    setState(() {
      _discovering = true;
    });
    try {
      final result = await LocalNetworkServiceDiscovery().scan(
        preferredAddress: _serverAddress,
        fallbackPort: _adminPort,
      );
      if (!mounted) {
        return;
      }
      if (result.candidates.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '未发现可用服务，已扫描 ${result.scannedHostCount} 个地址 / ${result.scannedSubnetCount} 个网段'
                  .tl,
            ),
          ),
        );
        return;
      }

      final selected = result.candidates.length == 1
          ? result.candidates.first
          : await showModalBottomSheet<ServiceDiscoveryCandidate>(
              context: context,
              showDragHandle: true,
              builder: (sheetContext) {
                return SafeArea(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: result.candidates.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final candidate = result.candidates[index];
                      final countText = candidate.comicCount == null
                          ? '--'
                          : candidate.comicCount.toString();
                      return ListTile(
                        leading: const Icon(Icons.router_outlined),
                        title: Text(candidate.address),
                        subtitle: Text(
                          '${candidate.detailText} · 漫画 $countText · ${candidate.latencyMs ?? '--'} ms',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(sheetContext).pop(candidate),
                      );
                    },
                  ),
                );
              },
            );
      if (selected == null || !mounted) {
        return;
      }
      await _applyDiscoveredServer(selected);
    } finally {
      if (mounted) {
        setState(() {
          _discovering = false;
        });
      }
    }
  }

  Future<void> _applyDiscoveredServer(
      ServiceDiscoveryCandidate candidate) async {
    appdata.settings[remoteServerAddressSettingIndex] = candidate.address;
    await appdata.updateSettings();
    App.notifyServiceConfigChanged();
    await _reloadSnapshot();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已切换到 ${candidate.address}'.tl)),
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
                    onPressed: _discovering ? null : _scanLocalNetwork,
                    child: Text(_discovering ? '扫描中...'.tl : '扫描局域网'.tl),
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
                ? '当前会先按已配置地址端口和当前设备所在私网网段，对 /status 接口做快速探测；后续仍可继续补 mDNS / Bonjour。'
                    .tl
                : '当前会按当前私网网段做快速探测；如需更强的零配置发现，后续可继续补 mDNS / Bonjour。'.tl,
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
          if (capability.isEnhancedServerTarget) ...[
            const SizedBox(height: 12),
            _InfoRow(
              label: '通知权限'.tl,
              value: _loadingAndroidSupportState
                  ? '读取中'.tl
                  : _androidSupportState?.notificationsGranted == true
                      ? '已允许'.tl
                      : '未允许'.tl,
            ),
            const SizedBox(height: 8),
            _InfoRow(
              label: '电池优化'.tl,
              value: _loadingAndroidSupportState
                  ? '读取中'.tl
                  : _androidSupportState?.ignoringBatteryOptimizations == true
                      ? '已忽略限制'.tl
                      : '仍受系统限制'.tl,
            ),
          ],
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
              if (capability.isEnhancedServerTarget)
                FilledButton.tonal(
                  onPressed: _loadingAndroidSupportState
                      ? null
                      : _androidSupportState?.notificationsGranted == true
                          ? _openAndroidNotificationSettings
                          : _requestAndroidNotificationPermission,
                  child: Text(
                    _androidSupportState?.notificationsGranted == true
                        ? '通知设置'.tl
                        : '开启通知权限'.tl,
                  ),
                ),
              if (capability.isEnhancedServerTarget)
                FilledButton.tonal(
                  onPressed: _loadingAndroidSupportState
                      ? null
                      : _openAndroidBatteryOptimizationSettings,
                  child: Text(
                    _androidSupportState?.ignoringBatteryOptimizations == true
                        ? '电池优化设置'.tl
                        : '关闭电池优化'.tl,
                  ),
                ),
              if (capability.isEnhancedServerTarget)
                FilledButton.tonal(
                  onPressed: _loadingAndroidSupportState
                      ? null
                      : _reloadAndroidSupportState,
                  child: Text('刷新保活状态'.tl),
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

  List<Widget> _buildPageChildren(ServiceInfoSnapshot snapshot) {
    return [
      _ModeOverviewCard(snapshot: snapshot, loading: _loading),
      const SizedBox(height: 12),
      if (snapshot.isClientMode)
        _buildClientSection(snapshot)
      else
        _buildServerSection(snapshot),
    ];
  }

  Widget _buildEmbeddedPage(ServiceInfoSnapshot snapshot) {
    return SizedBox.expand(
      child: RefreshIndicator(
        onRefresh: _reloadSnapshot,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: _buildPageChildren(snapshot),
        ),
      ),
    );
  }

  Widget _buildStandalonePage(ServiceInfoSnapshot snapshot) {
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _reloadSnapshot,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverAppbar(
              title: Text('服务信息'.tl),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                12,
                12,
                12,
                24 + MediaQuery.of(context).padding.bottom,
              ),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _buildPageChildren(snapshot),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot ?? _placeholderSnapshot();
    if (widget.standalone) {
      return _buildStandalonePage(snapshot);
    }
    return _buildEmbeddedPage(snapshot);
  }
}

class _ServerAddressEditorSheet extends StatefulWidget {
  const _ServerAddressEditorSheet({required this.initialValue});

  final String initialValue;

  @override
  State<_ServerAddressEditorSheet> createState() =>
      _ServerAddressEditorSheetState();
}

class _ServerAddressEditorSheetState extends State<_ServerAddressEditorSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);
  final FocusNode _focusNode = FocusNode();
  bool _pasting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    if (_pasting) {
      return;
    }
    setState(() {
      _pasting = true;
    });
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) {
      return;
    }
    final text = data?.text ?? '';
    if (text.isNotEmpty) {
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    setState(() {
      _pasting = false;
    });
  }

  void _submit() {
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '服务端地址'.tl,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '支持填写完整地址，例如 http://192.168.1.20:9527'.tl,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              hintText: '例如：http://192.168.1.20:9527'.tl,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('取消'.tl),
              ),
              const Spacer(),
              FilledButton.tonal(
                onPressed: _pasting ? null : _pasteFromClipboard,
                child: Text(_pasting ? '读取剪贴板中...'.tl : '粘贴'.tl),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _submit,
                child: Text('保存'.tl),
              ),
            ],
          ),
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
