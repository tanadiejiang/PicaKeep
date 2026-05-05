import 'package:flutter/foundation.dart';

String normalizeAppRuntimeMode(String value) {
  return switch (value.trim()) {
    appRuntimeModeServer => appRuntimeModeServer,
    _ => appRuntimeModeClient,
  };
}

String normalizeServiceDiscoveryMode(String value) {
  return switch (value.trim().toLowerCase()) {
    serviceDiscoveryModeUdp => serviceDiscoveryModeUdp,
    _ => serviceDiscoveryModeMdns,
  };
}

String normalizeServiceAdminPortValue(String value) {
  final port = int.tryParse(value.trim());
  if (port == null || port < 1 || port > 65535) {
    return defaultServiceAdminPort;
  }
  return port.toString();
}

String normalizeRemoteServerAddressValue(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  final withScheme = trimmed.startsWith('http://') || trimmed.startsWith('https://')
      ? trimmed
      : 'http://$trimmed';
  final uri = Uri.tryParse(withScheme);
  if (uri == null || !uri.hasAuthority || uri.host.trim().isEmpty) {
    return '';
  }
  final normalizedPath = uri.path == '/' ? '' : uri.path.replaceFirst(RegExp(r'/+$'), '');
  return Uri(
    scheme: uri.scheme.isEmpty ? 'http' : uri.scheme,
    userInfo: uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: normalizedPath,
    query: uri.hasQuery ? uri.query : null,
  ).toString();
}

Uri? tryParseRemoteServerUri(String value) {
  final normalized = normalizeRemoteServerAddressValue(value);
  if (normalized.isEmpty) {
    return null;
  }
  return Uri.tryParse(normalized);
}

String buildRemoteServiceStatusUrl(String value) {
  final uri = tryParseRemoteServerUri(value);
  if (uri == null) {
    return '';
  }
  return uri.resolve('/status').toString();
}

String buildServiceAdminUrl(String host, {String? port}) {
  final safeHost = host.trim().isEmpty ? '<host>' : host.trim();
  final safePort = normalizeServiceAdminPortValue(port ?? defaultServiceAdminPort);
  return 'http://$safeHost:$safePort/admin';
}

ServerPlatformCapability currentServerPlatformCapability() {
  if (kIsWeb) {
    return webServerPlatformCapability;
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows => windowsServerPlatformCapability,
    TargetPlatform.linux => linuxServerPlatformCapability,
    TargetPlatform.macOS => macosServerPlatformCapability,
    TargetPlatform.android => androidServerPlatformCapability,
    TargetPlatform.iOS => iosServerPlatformCapability,
    TargetPlatform.fuchsia => fuchsiaServerPlatformCapability,
  };
}

List<ServerPlatformCapability> serverPlatformCapabilityMatrix() {
  return const [
    windowsServerPlatformCapability,
    linuxServerPlatformCapability,
    macosServerPlatformCapability,
    androidServerPlatformCapability,
    iosServerPlatformCapability,
    webServerPlatformCapability,
  ];
}

String serverPlatformTierLabel(String tier) {
  return switch (tier) {
    serverPlatformTierFull => '完整服务端',
    serverPlatformTierEnhanced => '移动增强服务端',
    _ => '暂不纳入当前服务端目标',
  };
}

String serverPlatformTierDescription(String tier) {
  return switch (tier) {
    serverPlatformTierFull => '支持本地资源扫描、HTTP 服务、后台管理页与持续开服目标。',
    serverPlatformTierEnhanced => '支持服务端模式目标，但需要接受移动端前台服务、保活和权限约束。',
    _ => '当前阶段不作为服务端平台推进，只保留客户端或后续扩展空间。',
  };
}

bool canUseServerModeOnCurrentPlatform() {
  return currentServerPlatformCapability().supportsServerMode;
}

class ServerPlatformCapability {
  const ServerPlatformCapability({
    required this.platformId,
    required this.displayName,
    required this.tier,
    required this.supportsServerMode,
    required this.summary,
    required this.notes,
  });

  final String platformId;
  final String displayName;
  final String tier;
  final bool supportsServerMode;
  final String summary;
  final List<String> notes;

  bool get isFullServerTarget => tier == serverPlatformTierFull;
  bool get isEnhancedServerTarget => tier == serverPlatformTierEnhanced;
}

const appRuntimeModeClient = 'client';
const appRuntimeModeServer = 'server';
const appRuntimeModeSettingIndex = 97;
const remoteServerAddressSettingIndex = 98;
const serviceDiscoveryModeSettingIndex = 99;
const serviceAdminPortSettingIndex = 100;

const serviceDiscoveryModeMdns = 'mdns';
const serviceDiscoveryModeUdp = 'udp';
const defaultServiceAdminPort = '9527';

const serverPlatformTierFull = 'full';
const serverPlatformTierEnhanced = 'enhanced';
const serverPlatformTierUnsupported = 'unsupported';

const windowsServerPlatformCapability = ServerPlatformCapability(
  platformId: 'windows',
  displayName: 'Windows',
  tier: serverPlatformTierFull,
  supportsServerMode: true,
  summary: '桌面端完整服务端目标。',
  notes: [
    '允许持续开服，适合作为局域网服务节点。',
    '可直接承载后台网页、状态接口和本地资源扫描。',
  ],
);

const linuxServerPlatformCapability = ServerPlatformCapability(
  platformId: 'linux',
  displayName: 'Linux',
  tier: serverPlatformTierFull,
  supportsServerMode: true,
  summary: '桌面 / NAS / 小主机优先支持的完整服务端目标。',
  notes: [
    '优先保证原生 Linux 可直接运行。',
    '后续可继续承接 systemd、Docker 等部署方式。',
  ],
);

const macosServerPlatformCapability = ServerPlatformCapability(
  platformId: 'macos',
  displayName: 'macOS',
  tier: serverPlatformTierFull,
  supportsServerMode: true,
  summary: '桌面端完整服务端目标。',
  notes: [
    '支持本地资源扫描与后台网页。',
    '适合作为开发、调试和轻量局域网节点。',
  ],
);

const androidServerPlatformCapability = ServerPlatformCapability(
  platformId: 'android',
  displayName: 'Android',
  tier: serverPlatformTierEnhanced,
  supportsServerMode: true,
  summary: '移动增强服务端目标。',
  notes: [
    '需要前台服务、常驻通知和电池优化白名单等配合。',
    '可提供服务端模式，但持续保活能力弱于桌面端。',
  ],
);

const iosServerPlatformCapability = ServerPlatformCapability(
  platformId: 'ios',
  displayName: 'iOS / iPadOS',
  tier: serverPlatformTierUnsupported,
  supportsServerMode: false,
  summary: '当前阶段不纳入服务端目标。',
  notes: [
    '系统后台执行和常驻联网限制过强。',
    '后续如需支持，也更适合做前台临时服务而不是持续开服。',
  ],
);

const webServerPlatformCapability = ServerPlatformCapability(
  platformId: 'web',
  displayName: 'Web',
  tier: serverPlatformTierUnsupported,
  supportsServerMode: false,
  summary: '网页端不作为本地服务端目标。',
  notes: [
    '浏览器环境无法稳定承担本地 HTTP 服务。',
    '更适合作为客户端或管理端访问已有服务。',
  ],
);

const fuchsiaServerPlatformCapability = ServerPlatformCapability(
  platformId: 'fuchsia',
  displayName: 'Fuchsia',
  tier: serverPlatformTierUnsupported,
  supportsServerMode: false,
  summary: '当前未纳入服务端规划。',
  notes: ['暂无对应服务端落地计划。'],
);
