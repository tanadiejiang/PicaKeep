import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/foundation/service_data_source.dart';
import 'package:picakeep/pages/app_capabilities_page.dart';
import 'package:picakeep/pages/settings/runtime_service_settings.dart';
import 'package:picakeep/server/local_server_runtime.dart';
import 'package:picakeep/tools/android_foreground_service.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:url_launcher/url_launcher.dart';

class ServiceInfoPage extends StatefulWidget {
  const ServiceInfoPage({
    super.key,
    this.standalone = false,
    this.dataSource,
    this.enableInlineAutoDiscovery = true,
  });

  final bool standalone;
  final RuntimeServiceDataSource? dataSource;

  /// Widget 测试可关，避免无地址态自动扫网留下 pending Timer。
  final bool enableInlineAutoDiscovery;

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

class _ServiceInfoPageState extends State<ServiceInfoPage> {
  ServiceInfoSnapshot? _snapshot;
  AndroidForegroundServiceSupportState? _androidSupportState;
  bool _loading = true;
  bool _discovering = false;
  bool _loadingAndroidSupportState = false;
  bool _refreshingServiceState = false;
  bool _refreshingStats = false;
  int _snapshotReloadGeneration = 0;
  int _discoveryGeneration = 0;
  DiscoverySession? _discoverySession;
  StreamSubscription<DiscoveryProgress>? _discoveryProgressSubscription;
  DiscoveryProgress? _discoveryProgress;
  String? _discoveryError;
  DateTime? _lastSnapshotRefreshAt;

  /// 无地址态自动发现是否已启动过（断开后地址变空时重置）。
  bool _autoDiscoveryStarted = false;

  /// 用户在发现区点击某候选后，结果处理应跳过弹窗/自动连与取消 SnackBar。
  bool _discoveryConnectInFlight = false;
  List<ServiceDiscoveryCandidate> _liveDiscoveryCandidates =
      const <ServiceDiscoveryCandidate>[];

  String get _discoveryMode => normalizeServiceDiscoveryMode(
        appdata.settings[serviceDiscoveryModeSettingIndex],
      );

  String get _discoveryActionLabel =>
      _discoveryMode == serviceDiscoveryModeMdns ? 'mDNS 发现' : '网段扫描';

  String get _serverAddress =>
      appdata.settings[remoteServerAddressSettingIndex].trim();

  /// 无已保存地址 → 显示内联发现区（第一次 / 主动断开）。
  bool get _showInlineDiscoveryZone => _serverAddress.isEmpty;

  RuntimeServiceDataSource get _dataSource =>
      widget.dataSource ?? RuntimeServiceDataSourceResolver.current();

  String get _adminPort => normalizeServiceAdminPortValue(
        appdata.settings[serviceAdminPortSettingIndex],
      );

  List<int> get _effectiveScanPorts => effectiveServiceScanPorts(
        appdata.settings[serviceScanCustomPortsSettingIndex],
      );

  @override
  void initState() {
    super.initState();
    App.serviceConfigVersion.addListener(_handleServiceConfigChanged);
    App.serviceRuntimeVersion.addListener(_handleServiceRuntimeChanged);
    App.serviceStatsVersion.addListener(_handleServiceStatsChanged);
    _reloadSnapshot();
    if (currentServerPlatformCapability().isEnhancedServerTarget) {
      _reloadAndroidSupportState();
    }
  }

  @override
  void dispose() {
    App.serviceConfigVersion.removeListener(_handleServiceConfigChanged);
    App.serviceRuntimeVersion.removeListener(_handleServiceRuntimeChanged);
    App.serviceStatsVersion.removeListener(_handleServiceStatsChanged);
    final progressSubscription = _discoveryProgressSubscription;
    if (progressSubscription != null) {
      unawaited(progressSubscription.cancel());
    }
    final discoverySession = _discoverySession;
    if (discoverySession != null) {
      unawaited(discoverySession.cancel());
    }
    super.dispose();
  }

  void _handleServiceConfigChanged() {
    unawaited(_cancelDiscovery());
    // 只在「有地址 → 无地址」的真实断开跳变时才重置自动扫状态；
    // 切 mDNS 开关等其他配置变更不应在无地址态重复触发自动扫。
    final hadAddress = _snapshot?.addressInput.trim().isNotEmpty ?? false;
    if (hadAddress && _serverAddress.isEmpty) {
      // 主动断开：展示发现区但不自动开扫，用户可手动点「重新扫描」。
      // 设为 true 让 _maybeStartInlineAutoDiscovery 跳过触发。
      _autoDiscoveryStarted = true;
      _liveDiscoveryCandidates = const <ServiceDiscoveryCandidate>[];
      _discoveryConnectInFlight = false;
    }
    _reloadSnapshot();
    if (currentServerPlatformCapability().isEnhancedServerTarget) {
      _reloadAndroidSupportState();
    }
  }

  void _handleServiceRuntimeChanged() {
    _reloadSnapshot();
    if (currentServerPlatformCapability().isEnhancedServerTarget) {
      _reloadAndroidSupportState();
    }
  }

  void _handleServiceStatsChanged() {
    _reloadStatsSnapshot();
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
    final generation = ++_snapshotReloadGeneration;
    if (mounted) {
      setState(() {
        _loading = true;
      });
    }
    final snapshot = await _dataSource.fetchSnapshot();
    if (!mounted || generation != _snapshotReloadGeneration) {
      return;
    }
    setState(() {
      _snapshot = snapshot;
      _loading = false;
      _lastSnapshotRefreshAt = DateTime.now();
    });
    _maybeStartInlineAutoDiscovery();
  }

  /// 无地址态进入页面 / 断开后：自动开扫一次。
  void _maybeStartInlineAutoDiscovery() {
    if (!mounted ||
        !widget.enableInlineAutoDiscovery ||
        !_showInlineDiscoveryZone) {
      return;
    }
    if (_autoDiscoveryStarted || _discovering || _loading) {
      return;
    }
    _autoDiscoveryStarted = true;
    unawaited(_scanLocalNetwork(fromInlineZone: true));
  }

  Future<void> _reloadStatsSnapshot() async {
    if (_refreshingStats || _loading) {
      return;
    }
    _refreshingStats = true;
    final generation = _snapshotReloadGeneration;
    try {
      final snapshot = await _dataSource.fetchSnapshot();
      if (!mounted || generation != _snapshotReloadGeneration || _loading) {
        return;
      }
      final current = _snapshot;
      if (current != null && _sameServiceStats(current, snapshot)) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
      });
    } finally {
      _refreshingStats = false;
    }
  }

  bool _sameServiceStats(
    ServiceInfoSnapshot previous,
    ServiceInfoSnapshot next,
  ) {
    return previous.mode == next.mode &&
        previous.connectionState == next.connectionState &&
        previous.discoveryMode == next.discoveryMode &&
        previous.addressInput == next.addressInput &&
        previous.normalizedAddress == next.normalizedAddress &&
        previous.statusText == next.statusText &&
        previous.detailText == next.detailText &&
        previous.statusUrl == next.statusUrl &&
        previous.adminUrl == next.adminUrl &&
        previous.httpStatusCode == next.httpStatusCode &&
        previous.comicCount == next.comicCount &&
        previous.connectionCount == next.connectionCount &&
        previous.libraryRootCount == next.libraryRootCount &&
        previous.resourceBytes == next.resourceBytes &&
        previous.librarySignature == next.librarySignature &&
        previous.totalRequests == next.totalRequests &&
        previous.startedAt == next.startedAt &&
        previous.deviceSystem == next.deviceSystem &&
        previous.deviceName == next.deviceName;
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

  void _openPortManagement() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AppCapabilitiesPage()),
    );
  }

  Future<void> _cancelDiscovery() async {
    final session = _discoverySession;
    final progressSubscription = _discoveryProgressSubscription;
    if (session == null && progressSubscription == null) {
      return;
    }
    _discoveryGeneration++;
    _discoverySession = null;
    _discoveryProgressSubscription = null;
    await progressSubscription?.cancel();
    await session?.cancel();
    if (mounted) {
      setState(() {
        _discovering = false;
        _discoveryProgress = null;
      });
    }
  }

  String _discoveryStatsText(LocalNetworkServiceDiscoveryResult result) {
    return '主机 ${result.scannedHostCount} · 端口 ${result.scannedPortCount} · '
        '端点 ${result.scannedEndpointCount}/${result.plannedEndpointCount}';
  }

  Future<void> _scanLocalNetwork({bool fromInlineZone = false}) async {
    if (_discovering) {
      return;
    }
    await _cancelDiscovery();
    final generation = ++_discoveryGeneration;
    final mode = _discoveryMode;
    final effectivePorts = List<int>.unmodifiable(_effectiveScanPorts);
    final fallbackToSubnetScan = isServiceDiscoveryMdnsFallbackEnabled(
      appdata.settings[serviceDiscoveryMdnsFallbackSettingIndex],
    );
    final session = LocalNetworkServiceDiscovery().createSession(
      mode: mode,
      preferredAddress: _serverAddress,
      effectiveScanPorts: effectivePorts,
      fallbackToSubnetScan: fallbackToSubnetScan,
      generation: generation,
    );
    _discoverySession = session;
    _discoveryConnectInFlight = false;
    _discoveryProgressSubscription = session.progress.listen((progress) {
      if (!mounted ||
          generation != _discoveryGeneration ||
          !identical(_discoverySession, session)) {
        return;
      }
      setState(() {
        _discoveryProgress = progress;
        if (progress.candidates.isNotEmpty) {
          _liveDiscoveryCandidates = progress.candidates;
        }
      });
    });
    if (mounted) {
      setState(() {
        _discovering = true;
        _discoveryProgress = null;
        _discoveryError = null;
        if (fromInlineZone || _showInlineDiscoveryZone) {
          _liveDiscoveryCandidates = const <ServiceDiscoveryCandidate>[];
        }
      });
    }
    try {
      final result = await session.result;
      if (!mounted || generation != _discoveryGeneration) {
        return;
      }
      // 用户在发现区点击连接后会 cancel：跳过后续自动连 / 弹窗 / 取消提示。
      if (_discoveryConnectInFlight) {
        return;
      }
      if (result.cancelled) {
        if (!fromInlineZone && !_showInlineDiscoveryZone) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已取消服务发现。'.tl)),
          );
        }
        return;
      }
      if (result.timedOut) {
        if (result.candidates.isNotEmpty) {
          setState(() {
            _liveDiscoveryCandidates = result.candidates;
          });
        }
        if (_showInlineDiscoveryZone || fromInlineZone) {
          // 发现区超时：有唯一候选仍自动连，多台只展示列表。
          if (result.candidates.length == 1) {
            await _applyDiscoveredServer(result.candidates.first);
          }
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('服务发现超时，请缩小网络范围后重试。'.tl)),
        );
        if (result.candidates.isEmpty) {
          return;
        }
      }
      if (result.candidates.isEmpty) {
        if (_showInlineDiscoveryZone || fromInlineZone) {
          setState(() {
            _liveDiscoveryCandidates = const <ServiceDiscoveryCandidate>[];
          });
          return;
        }
        final stats = _discoveryStatsText(result);
        final message = result.fellBackToSubnetScan
            ? '已并行补扫网段，仍未发现可用服务。$stats / 网段 ${result.scannedSubnetCount}'
            : mode == serviceDiscoveryModeMdns
                ? '未通过 mDNS 发现可用服务；请确认服务端已启动，且两端在同一局域网并允许组播。$stats'
                : '未发现可用服务。$stats / 网段 ${result.scannedSubnetCount}';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message.tl)),
        );
        return;
      }

      // 发现区：多台只更新列表；唯一台自动连（用户未中途点击）。
      if (_showInlineDiscoveryZone || fromInlineZone) {
        setState(() {
          _liveDiscoveryCandidates = result.candidates;
        });
        if (result.candidates.length == 1) {
          await _applyDiscoveredServer(result.candidates.first);
        }
        return;
      }

      final selected = result.candidates.length == 1
          ? result.candidates.first
          : await _showDiscoveryCandidateSheet(result);
      if (!mounted) {
        return;
      }
      if (result.fellBackToSubnetScan &&
          result.candidates.length == 1 &&
          result.candidates.first.sourceMode ==
              serviceDiscoveryModeSubnetScan) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已通过网段补扫发现服务端。'.tl)),
        );
      }
      if (selected == null) {
        return;
      }
      await _applyDiscoveredServer(selected);
    } catch (e) {
      if (mounted &&
          generation == _discoveryGeneration &&
          !_discoveryConnectInFlight) {
        _discoveryError = '服务发现失败：$e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_discoveryError!.tl)),
        );
      }
    } finally {
      if (identical(_discoverySession, session)) {
        _discoverySession = null;
        final progressSubscription = _discoveryProgressSubscription;
        _discoveryProgressSubscription = null;
        await progressSubscription?.cancel();
      }
      if (mounted && generation == _discoveryGeneration) {
        setState(() {
          _discovering = false;
        });
      }
    }
  }

  /// 发现区点击候选：中断扫描并连接，避免与唯一自动连竞态。
  Future<void> _connectFromInlineDiscovery(
    ServiceDiscoveryCandidate candidate,
  ) async {
    if (_discoveryConnectInFlight) {
      return;
    }
    _discoveryConnectInFlight = true;
    try {
      // 先置位再取消：扫描结果处理看到 in-flight 后跳过自动连/弹窗。
      // 注意 _cancelDiscovery 会 ++generation，不能用 cancel 前后 generation 相等作守卫。
      if (_discovering) {
        await _cancelDiscovery();
      }
      if (!mounted) {
        return;
      }
      await _applyDiscoveredServer(candidate);
    } finally {
      _discoveryConnectInFlight = false;
    }
  }

  Future<ServiceDiscoveryCandidate?> _showDiscoveryCandidateSheet(
    LocalNetworkServiceDiscoveryResult result,
  ) {
    return showModalBottomSheet<ServiceDiscoveryCandidate>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            itemCount: result.candidates.length + 1,
            separatorBuilder: (_, index) => index == 0
                ? const SizedBox(height: 8)
                : const Divider(height: 1),
            itemBuilder: (context, index) {
              if (index == 0) {
                return _DiscoveryCandidateSheetHeader(result: result);
              }
              final candidate = result.candidates[index - 1];
              return _DiscoveryCandidateTile(
                candidate: candidate,
                onTap: () => Navigator.of(sheetContext).pop(candidate),
              );
            },
          ),
        );
      },
    );
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

  Future<void> _refreshServiceState() async {
    if (_refreshingServiceState) {
      return;
    }
    setState(() {
      _refreshingServiceState = true;
    });
    try {
      final mode =
          normalizeAppRuntimeMode(appdata.settings[appRuntimeModeSettingIndex]);
      if (mode == appRuntimeModeClient) {
        final normalizedAddress =
            normalizeRemoteServerAddressValue(_serverAddress);
        if (normalizedAddress.isNotEmpty) {
          await RemoteLibraryClient.fromCurrentSettings().rescanLibrary();
        }
        App.notifyServiceRuntimeChanged();
      } else {
        await LocalServerRuntime.instance.refreshResourceState();
      }
      await _reloadSnapshot();
    } catch (e) {
      await _reloadSnapshot();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('刷新失败：$e'.tl)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _refreshingServiceState = false;
        });
      }
    }
  }

  Future<void> _confirmDisconnectRemoteServer() async {
    final shouldDisconnect = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('断开当前服务'.tl),
        content: Text('断开后将清除当前客户端服务地址，之后需要重新填写或发现服务。'.tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text('取消'.tl),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('断开连接'.tl),
          ),
        ],
      ),
    );
    if (mounted && shouldDisconnect == true) {
      await _disconnectRemoteServer();
    }
  }

  Future<void> _disconnectRemoteServer() async {
    if (_serverAddress.trim().isEmpty) {
      return;
    }
    appdata.settings[remoteServerAddressSettingIndex] = '';
    await appdata.updateSettings();
    App.notifyServiceConfigChanged();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已断开当前服务连接'.tl)),
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
    final statusUrl = snapshot.statusUrl?.trim() ?? '';
    final adminUrl = snapshot.adminUrl?.trim() ?? '';
    final showDiscovery = snapshot.addressInput.trim().isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InfoCard(
          icon: Icons.link,
          title: '客户端连接'.tl,
          outlined: false,
          titleTrailing:
              showDiscovery ? null : _buildDisconnectAction(snapshot),
          child: showDiscovery
              ? _buildInlineDiscoveryZone()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildClientOverview(snapshot),
                    const SizedBox(height: 12),
                    _buildTechnicalDetails(
                      snapshot,
                      statusUrl: statusUrl,
                      adminUrl: adminUrl,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.tonal(
                          key: const ValueKey<String>(
                              'service-discovery-action'),
                          onPressed:
                              _discovering ? null : () => _scanLocalNetwork(),
                          child: _ActionButtonLabel(
                            label:
                                '${_discoveryActionLabel.tl}（${_effectiveScanPorts.length}）',
                            loading: _discovering,
                          ),
                        ),
                        FilledButton(
                          key: const ValueKey<String>(
                              'service-edit-address-action'),
                          onPressed: _editServerAddress,
                          child: Text('填写地址'.tl),
                        ),
                        FilledButton(
                          key: const ValueKey<String>('service-refresh-action'),
                          onPressed: (_loading || _refreshingServiceState)
                              ? null
                              : _refreshServiceState,
                          child: _ActionButtonLabel(
                            label: '刷新状态'.tl,
                            loading: _refreshingServiceState,
                            indicatorColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
        ),
        const Divider(height: 1),
        _InfoCard(
          icon: Icons.wifi_tethering,
          title: '自动发现'.tl,
          outlined: false,
          titleTrailing: ServiceDiscoveryModeSelector(
            onChanged: (_) {
              if (mounted) {
                setState(() {});
              }
            },
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                serviceDiscoveryModeDescription(_discoveryMode).tl,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              ServiceScanPortsEditor(
                compact: true,
                onManage: _openPortManagement,
              ),
              if (_discoveryError != null) ...[
                const SizedBox(height: 4),
                Text(
                  _discoveryError!.tl,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
              // 有地址态（信息卡）才在「自动发现」卡片里显示进度；
              // 无地址态（发现区）进度块已在内联发现区显示，这里不重复。
              if (!showDiscovery &&
                  (_discovering || _discoveryProgress != null)) ...[
                const SizedBox(height: 8),
                _DiscoveryProgressPanel(
                  progress: _discoveryProgress,
                  portCount: _effectiveScanPorts.length,
                  onCancel: _discovering ? _cancelDiscovery : null,
                ),
              ],
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text('mDNS 并行补扫'.tl),
                subtitle: Text(
                  serviceDiscoveryMdnsFallbackDescription(
                    isServiceDiscoveryMdnsFallbackEnabled(
                      appdata
                          .settings[serviceDiscoveryMdnsFallbackSettingIndex],
                    )
                        ? '1'
                        : '0',
                  ).tl,
                ),
                value: isServiceDiscoveryMdnsFallbackEnabled(
                  appdata.settings[serviceDiscoveryMdnsFallbackSettingIndex],
                ),
                onChanged: (value) async {
                  appdata.settings[serviceDiscoveryMdnsFallbackSettingIndex] =
                      value ? '1' : '0';
                  await appdata.updateSettings();
                  App.notifyServiceConfigChanged();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInlineDiscoveryZone() {
    final candidates = _liveDiscoveryCandidates;
    final discovering = _discovering;
    final empty = candidates.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '局域网发现'.tl,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          '自动扫描同一局域网内的 PicaKeep 服务，点选即可连接。'.tl,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (_discoveryError != null) ...[
          const SizedBox(height: 8),
          Text(
            _discoveryError!.tl,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (discovering || _discoveryProgress != null) ...[
          const SizedBox(height: 8),
          _DiscoveryProgressPanel(
            progress: _discoveryProgress,
            portCount: _effectiveScanPorts.length,
            onCancel: discovering ? _cancelDiscovery : null,
          ),
        ],
        const SizedBox(height: 8),
        if (empty && discovering)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '正在发现可用服务…'.tl,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          )
        else if (empty && !discovering)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '未发现可用服务。可重新扫描，或手动填写地址。'.tl,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: candidates.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final candidate = candidates[index];
              return _DiscoveryCandidateTile(
                candidate: candidate,
                onTap: _discoveryConnectInFlight
                    ? () {}
                    : () {
                        unawaited(_connectFromInlineDiscovery(candidate));
                      },
              );
            },
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonal(
              key: const ValueKey<String>('service-inline-rescan-action'),
              onPressed: discovering
                  ? null
                  : () {
                      _autoDiscoveryStarted = true;
                      unawaited(_scanLocalNetwork(fromInlineZone: true));
                    },
              child: _ActionButtonLabel(
                label: '重新扫描'.tl,
                loading: discovering,
              ),
            ),
            FilledButton(
              key: const ValueKey<String>('service-inline-edit-address-action'),
              onPressed: _editServerAddress,
              child: Text('填写地址'.tl),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDisconnectAction(ServiceInfoSnapshot snapshot) {
    final enabled = snapshot.addressInput.trim().isNotEmpty;
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final compact = MediaQuery.sizeOf(context).width < 430 ||
            textScale > 1.45 ||
            constraints.maxWidth < 132;
        if (compact) {
          return IconButton(
            key: const ValueKey<String>('service-disconnect-action'),
            tooltip: '断开连接'.tl,
            onPressed: enabled ? _confirmDisconnectRemoteServer : null,
            icon: const Icon(Icons.link_off_outlined),
            color: Theme.of(context).colorScheme.error,
          );
        }
        return OutlinedButton.icon(
          key: const ValueKey<String>('service-disconnect-action'),
          onPressed: enabled ? _confirmDisconnectRemoteServer : null,
          icon: const Icon(Icons.link_off_outlined),
          label: Text('断开连接'.tl),
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      },
    );
  }

  /// 左侧竖排指标（约 2/5）+ 右侧竖向节点信息（约 3/5）。
  /// 窄屏或大字号时回退为上下排列，避免挤压。
  Widget _buildClientOverview(ServiceInfoSnapshot snapshot) {
    final isStack = MediaQuery.sizeOf(context).width < 320 ||
        MediaQuery.textScalerOf(context).scale(1) > 1.5;
    final metrics = _buildClientMetrics(snapshot);
    final node = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '节点信息'.tl,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        _buildNodeIdentity(snapshot),
      ],
    );
    if (isStack) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          metrics,
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 12),
          node,
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 2, child: metrics),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: VerticalDivider(
              width: 1,
              thickness: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          Expanded(flex: 3, child: node),
        ],
      ),
    );
  }

  Widget _buildNodeIdentity(ServiceInfoSnapshot snapshot) {
    final system = snapshot.deviceSystem?.trim().isNotEmpty == true
        ? snapshot.deviceSystem!.trim()
        : '--';
    final name = snapshot.deviceName?.trim().isNotEmpty == true
        ? snapshot.deviceName!.trim()
        : snapshot.deviceSummary.trim();
    // 此方法仅在 IntrinsicHeight 子树中调用（_buildClientOverview 宽屏分支）。
    // _InfoRow 内部含 LayoutBuilder，放入 IntrinsicHeight 会触发固有尺寸断言，
    // 故此处直接内联无 LayoutBuilder 的横向双列布局（两列各自 label+value 堆叠），
    // 令两个 label 处于同一行顶部，满足测试 systemLabel.top ≈ nameLabel.top 的断言。
    final labelStyle = TextStyle(
      color: Theme.of(context).colorScheme.primary,
      fontWeight: FontWeight.w600,
    );
    Widget fieldColumn(String label, String value) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: labelStyle),
            const SizedBox(height: 4),
            SelectableText(value),
          ],
        );
    return KeyedSubtree(
      key: const ValueKey<String>('service-device-identity-fields'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: fieldColumn('设备系统'.tl, system)),
          const SizedBox(width: 12),
          Expanded(child: fieldColumn('设备名称'.tl, name)),
        ],
      ),
    );
  }

  Widget _buildClientMetrics(ServiceInfoSnapshot snapshot) {
    final metrics = [
      _MetricValue(
        icon: Icons.speed_outlined,
        label: '延迟'.tl,
        value: snapshot.latencyMs == null ? '--' : '${snapshot.latencyMs} ms',
      ),
      _MetricValue(
        icon: Icons.menu_book_outlined,
        label: '漫画'.tl,
        value: snapshot.comicCount?.toString() ?? '--',
      ),
      _MetricValue(
        icon: Icons.people_outline,
        label: '连接'.tl,
        value: snapshot.connectionCount?.toString() ?? '--',
      ),
      _MetricValue(
        icon: Icons.storage_outlined,
        label: '资源体积'.tl,
        value: _formatBytes(snapshot.resourceBytes),
      ),
    ];
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < metrics.length; i++) ...[
          if (i > 0)
            Divider(height: 1, thickness: 1, color: colors.outlineVariant),
          _MetricTile(metric: metrics[i]),
        ],
      ],
    );
  }

  Widget _buildTechnicalDetails(
    ServiceInfoSnapshot snapshot, {
    required String statusUrl,
    required String adminUrl,
  }) {
    final expanded = MediaQuery.of(context).size.width >= 600;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      initiallyExpanded: expanded,
      title: Text('技术详情'.tl),
      subtitle: Text('地址、状态接口和服务运行信息'.tl),
      children: [
        _InfoRow(
          label: '生效地址'.tl,
          value: snapshot.normalizedAddress.isEmpty
              ? '--'
              : snapshot.normalizedAddress,
          copy: snapshot.normalizedAddress.isEmpty
              ? null
              : () => _copyText(snapshot.normalizedAddress, '已复制服务地址'),
        ),
        const SizedBox(height: 8),
        _InfoRow(
          label: '状态接口'.tl,
          value: statusUrl.isEmpty ? '--' : statusUrl,
          copy:
              statusUrl.isEmpty ? null : () => _copyText(statusUrl, '已复制状态接口'),
        ),
        const SizedBox(height: 8),
        _InfoRow(
          label: '后台地址'.tl,
          value: adminUrl.isEmpty ? '--' : adminUrl,
          copy: adminUrl.isEmpty ? null : () => _copyText(adminUrl, '已复制后台地址'),
        ),
        const SizedBox(height: 8),
        _InfoRow(
          label: '状态码'.tl,
          value: snapshot.httpStatusCode?.toString() ?? '--',
        ),
        const SizedBox(height: 8),
        _InfoRow(
          label: '累计请求'.tl,
          value: snapshot.totalRequests?.toString() ?? '--',
        ),
        const SizedBox(height: 8),
        _InfoRow(
          label: '启动时间'.tl,
          value: snapshot.startedAt ?? '--',
        ),
      ],
    );
  }

  Widget _buildServerSection(ServiceInfoSnapshot snapshot) {
    final capability = currentServerPlatformCapability();
    return _InfoCard(
      icon: Icons.dns_outlined,
      title: '服务端状态'.tl,
      outlined: false,
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
                onPressed: _loading ? null : _refreshServiceState,
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
      _ModeOverviewCard(
        snapshot: snapshot,
        loading: _loading,
        refreshedAt: _lastSnapshotRefreshAt,
      ),
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
        onRefresh: _refreshServiceState,
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
        onRefresh: _refreshServiceState,
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

class _ServiceDiscoveryStrategySummary extends StatefulWidget {
  const _ServiceDiscoveryStrategySummary();

  @override
  State<_ServiceDiscoveryStrategySummary> createState() =>
      _ServiceDiscoveryStrategySummaryState();
}

class _ServiceDiscoveryStrategySummaryState
    extends State<_ServiceDiscoveryStrategySummary> {
  String get _mode => normalizeServiceDiscoveryMode(
        appdata.settings[serviceDiscoveryModeSettingIndex],
      );

  bool get _mdnsFallbackEnabled => isServiceDiscoveryMdnsFallbackEnabled(
        appdata.settings[serviceDiscoveryMdnsFallbackSettingIndex],
      );

  Future<void> _setMdnsFallbackEnabled(bool value) async {
    final nextValue = value ? '1' : '0';
    if (nextValue ==
        appdata.settings[serviceDiscoveryMdnsFallbackSettingIndex]) {
      return;
    }
    appdata.settings[serviceDiscoveryMdnsFallbackSettingIndex] = nextValue;
    await appdata.updateSettings();
    App.notifyServiceConfigChanged();
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final mdnsFallbackEnabled = _mdnsFallbackEnabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          serviceDiscoveryModeDescription(_mode).tl,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text('mDNS 并行补扫'.tl),
          subtitle: Text(
            serviceDiscoveryMdnsFallbackDescription(
              mdnsFallbackEnabled ? '1' : '0',
            ).tl,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          value: mdnsFallbackEnabled,
          onChanged: _setMdnsFallbackEnabled,
        ),
      ],
    );
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

class _MetricValue {
  const _MetricValue({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.metric});

  final _MetricValue metric;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.onSurfaceVariant,
          fontSize: 11,
          height: 1.1,
        );
    final valueStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 13,
          height: 1.15,
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(
        children: [
          Icon(metric.icon, size: 16, color: colors.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(metric.label, style: labelStyle),
                const SizedBox(height: 1),
                Text(
                  metric.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: valueStyle,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.6;
    return Container(
      width: largeText ? double.infinity : null,
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: colors.onSecondaryContainer),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              softWrap: true,
              style: TextStyle(
                color: colors.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiscoveryProgressPanel extends StatelessWidget {
  const _DiscoveryProgressPanel({
    required this.progress,
    required this.portCount,
    required this.onCancel,
  });

  final DiscoveryProgress? progress;
  final int portCount;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final current = progress;
    final stage = current?.stage ?? DiscoveryProgressStage.subnetScan;
    final stageLabel = switch (stage) {
      DiscoveryProgressStage.mdns => '正在通过 mDNS 验证服务'.tl,
      DiscoveryProgressStage.subnetScan => '正在补扫网段'.tl,
      DiscoveryProgressStage.completed => '服务发现已完成'.tl,
      DiscoveryProgressStage.cancelled => '服务发现已取消'.tl,
      DiscoveryProgressStage.timedOut => '服务发现已超时'.tl,
      DiscoveryProgressStage.failed => '服务发现失败'.tl,
    };
    final planned = current?.plannedEndpoints ?? 0;
    final completed = current?.completedEndpoints ?? 0;
    final effectivePortCount = current?.portCount ?? portCount;
    final progressValue =
        planned == 0 ? null : (completed / planned).clamp(0.0, 1.0).toDouble();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  stageLabel,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (onCancel != null)
                TextButton.icon(
                  onPressed: onCancel,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: Text('取消'.tl),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            planned == 0
                ? '已使用 SRV 宣告端口验证，端口数：$effectivePortCount'.tl
                : '已探测 $completed / $planned 个端点 · 端口 $effectivePortCount'.tl,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progressValue),
          if (current?.currentHost?.isNotEmpty == true) ...[
            const SizedBox(height: 6),
            SelectableText(
              '当前主机：${current!.currentHost}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _DiscoveryCandidateSheetHeader extends StatelessWidget {
  const _DiscoveryCandidateSheetHeader({required this.result});

  final LocalNetworkServiceDiscoveryResult result;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final fallbackText =
        result.fellBackToSubnetScan ? '本轮已并行补扫网段并与 mDNS 结果合并。'.tl : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '选择服务端'.tl,
            style: textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            '发现 @a 个可用服务，请选择要连接的节点。'.tlParams({
              'a': result.candidates.length.toString(),
            }),
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            '已验证主机 ${result.scannedHostCount} · 端口 ${result.scannedPortCount} · '
            '端点 ${result.scannedEndpointCount}/${result.plannedEndpointCount}',
            style: textTheme.bodySmall,
          ),
          if (fallbackText != null) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.alt_route_outlined,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    fallbackText,
                    style: textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DiscoveryCandidateTile extends StatelessWidget {
  const _DiscoveryCandidateTile({required this.candidate, required this.onTap});

  final ServiceDiscoveryCandidate candidate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final countText =
        candidate.comicCount == null ? '--' : candidate.comicCount.toString();
    final latencyText =
        candidate.latencyMs == null ? null : '${candidate.latencyMs} ms';
    final addressText = latencyText == null
        ? candidate.address
        : '${candidate.address} · $latencyText';
    final metaText =
        '${candidate.sourceLabel} · 端口 ${candidate.port} · 漫画 $countText';
    final showName = candidate.displayName != candidate.address;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.router_outlined),
      title: Text(
        showName ? candidate.displayName : addressText,
        softWrap: true,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showName) SelectableText(addressText),
          Text(metaText.tl),
          Text(candidate.deviceSummary),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
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
  const _ModeOverviewCard({
    required this.snapshot,
    required this.loading,
    this.refreshedAt,
  });

  final ServiceInfoSnapshot snapshot;
  final bool loading;
  final DateTime? refreshedAt;

  IconData _statusIcon() {
    if (loading) {
      return Icons.sync_outlined;
    }
    return switch (snapshot.connectionState) {
      ServiceConnectionState.online => Icons.check_circle_outline,
      ServiceConnectionState.notConfigured => Icons.edit_location_alt_outlined,
      ServiceConnectionState.invalidAddress => Icons.error_outline,
      ServiceConnectionState.offline => Icons.cloud_off_outlined,
      ServiceConnectionState.idle => Icons.pause_circle_outline,
    };
  }

  @override
  Widget build(BuildContext context) {
    final modeLabel = snapshot.isServerMode ? '服务端'.tl : '客户端'.tl;
    final address = snapshot.isClientMode
        ? snapshot.normalizedAddress
        : snapshot.adminUrl ?? '';
    final refreshLabel = refreshedAt == null
        ? '最近刷新：--'.tl
        : '最近刷新：@a'.tlParams({
            'a': refreshedAt!.toLocal().toString().substring(0, 19),
          });
    return _InfoCard(
      icon: _statusIcon(),
      title: '服务信息'.tl,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _StatusBadge(
                icon: _statusIcon(),
                label: loading ? '刷新中'.tl : snapshot.statusText,
              ),
              Chip(
                avatar: Icon(
                  snapshot.isServerMode
                      ? Icons.dns_outlined
                      : Icons.devices_outlined,
                  size: 18,
                ),
                label: Text(modeLabel),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _InfoRow(
            label: snapshot.isServerMode ? '本机后台'.tl : '当前地址'.tl,
            value: address.isEmpty ? '--' : address,
          ),
          const SizedBox(height: 8),
          Text(
            snapshot.detailText,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Text(
            refreshLabel,
            style: Theme.of(context).textTheme.bodySmall,
          ),
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
    this.titleTrailing,
    this.outlined = true,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? titleTrailing;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: EdgeInsets.only(
        top: outlined ? 16 : 8,
        bottom: outlined ? 16 : 12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (titleTrailing != null) ...[
                const SizedBox(width: 12),
                Flexible(child: titleTrailing!),
              ],
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
    if (!outlined) {
      return content;
    }
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: content,
      ),
    );
  }
}

class _ActionButtonLabel extends StatelessWidget {
  const _ActionButtonLabel({
    required this.label,
    required this.loading,
    this.indicatorColor,
  });

  final String label;
  final bool loading;
  final Color? indicatorColor;

  @override
  Widget build(BuildContext context) {
    final baseStyle = DefaultTextStyle.of(context).style;
    final textColor =
        baseStyle.color ?? Theme.of(context).colorScheme.onSurface;
    return Stack(
      alignment: Alignment.center,
      children: [
        AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: loading ? 0.45 : 1,
          child: Text(label),
        ),
        IgnorePointer(
          child: SizedBox(
            width: 16,
            height: 16,
            child: loading
                ? CircularProgressIndicator(
                    strokeWidth: 2,
                    color: indicatorColor ?? textColor,
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.copy});

  final String label;
  final String value;
  final VoidCallback? copy;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 420 ||
            MediaQuery.textScalerOf(context).scale(1) > 1.25;
        final labelStyle = TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        );
        final valueWidget = SelectableText(value);
        final valueWithAction = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: valueWidget),
            if (copy != null)
              IconButton(
                tooltip: '复制'.tl,
                onPressed: copy,
                icon: const Icon(Icons.copy_outlined),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                padding: EdgeInsets.zero,
              ),
          ],
        );
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: labelStyle),
              const SizedBox(height: 4),
              valueWithAction,
            ],
          );
        }
        final labelWidth = (constraints.maxWidth * 0.28).clamp(96.0, 160.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: labelWidth, child: Text(label, style: labelStyle)),
            const SizedBox(width: 12),
            Expanded(child: valueWithAction),
          ],
        );
      },
    );
  }
}
