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

String buildServiceAdminUrl(String host, {String? port}) {
  final safeHost = host.trim().isEmpty ? '<host>' : host.trim();
  final safePort =
      normalizeServiceAdminPortValue(port ?? defaultServiceAdminPort);
  return 'http://$safeHost:$safePort/admin';
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
