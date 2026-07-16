import 'dart:io';

/// The host classes used by the remote-service proxy policy.
enum RemoteServiceHostKind {
  loopback,
  lan,
  linkLocal,
  ipv6,
  hostname,
  publicIp,
  invalid,
}

/// A descriptive alias for callers that prefer "category" terminology.
typedef RemoteServiceHostCategory = RemoteServiceHostKind;

enum RemoteServiceProxySource {
  manualProxy,
  environment,
  directFallback,
}

typedef RemoteServiceNetworkRoute = RemoteServiceProxySource;

typedef RemoteServiceNetworkPolicyLogger = void Function(String message);
typedef RemoteServiceNetworkDecisionLogger = void Function(
  RemoteServiceProxyDecision decision,
  Uri uri,
);

/// The result of selecting a route for one remote-service request.
///
/// [proxyAddress] and [proxyRule] are request values and should not be written
/// to logs. [toString] deliberately omits them for that reason.
class RemoteServiceProxyDecision {
  const RemoteServiceProxyDecision({
    required this.hostKind,
    required this.source,
    this.proxyAddress,
    this.proxyRule,
    this.environmentVariable,
  });

  final RemoteServiceHostKind hostKind;
  final RemoteServiceProxySource source;
  final String? proxyAddress;
  final String? proxyRule;
  final String? environmentVariable;

  bool get usesProxy => proxyRule != null && proxyRule != 'DIRECT';

  String get findProxyRule => proxyRule ?? 'DIRECT';

  RemoteServiceProxySource get route => source;

  // Compatibility with code that uses the shorter name for the endpoint.
  String? get proxy => proxyAddress;

  @override
  String toString() {
    return 'RemoteServiceProxyDecision('
        'hostKind: ${hostKind.name}, '
        'source: ${source.name}, '
        'route: ${usesProxy ? 'proxy' : 'direct'})';
  }
}

/// Selects how a remote service is reached and installs that selection on an
/// [HttpClient].
///
/// Local IP targets are direct by default. This is important for a service
/// discovered on the same network: sending a 192.168.x.x or link-local target
/// through a public proxy is usually both slower and unable to work. A manual
/// proxy has precedence over environment proxy variables for non-local
/// targets. If neither is usable, the policy returns `DIRECT`.
class RemoteServiceNetworkPolicy {
  RemoteServiceNetworkPolicy({
    String? manualProxy,
    Map<String, String>? environment,
    this.bypassLocalAddresses = true,
    this.forceDirect = false,
    this.logger,
  })  : manualProxy = manualProxy?.trim(),
        environment = Map.unmodifiable(
          environment ?? Platform.environment,
        );

  final String? manualProxy;
  final Map<String, String> environment;
  final bool bypassLocalAddresses;
  final bool forceDirect;
  final RemoteServiceNetworkPolicyLogger? logger;

  static RemoteServiceHostKind classifyHost(String host) {
    return classifyRemoteServiceHost(host);
  }

  static RemoteServiceHostKind classifyUri(Uri uri) {
    return classifyRemoteServiceHost(uri.host);
  }

  /// Compatibility factory for the remote service data sources.
  static HttpClient createClient({
    String? manualProxy,
    Map<String, String>? environment,
    Duration? connectionTimeout,
    Duration? idleTimeout,
    int? maxConnectionsPerHost,
    bool forceDirect = false,
    RemoteServiceNetworkDecisionLogger? onDecision,
  }) {
    final policy = RemoteServiceNetworkPolicy(
      manualProxy: manualProxy,
      environment: environment,
    );
    final client = HttpClient();
    if (connectionTimeout != null) {
      client.connectionTimeout = connectionTimeout;
    }
    if (idleTimeout != null) {
      client.idleTimeout = idleTimeout;
    }
    if (maxConnectionsPerHost != null) {
      client.maxConnectionsPerHost = maxConnectionsPerHost;
    }
    client.findProxy = (uri) {
      final decision = policy.resolveProxy(uri, forceDirect: forceDirect);
      if (onDecision != null) {
        try {
          onDecision(decision, uri);
        } catch (_) {
          // A diagnostics callback must never change the network outcome.
        }
      }
      return decision.findProxyRule;
    };
    return client;
  }

  /// Resolves the route without performing DNS or network I/O.
  RemoteServiceProxyDecision resolveProxy(Uri uri, {bool? forceDirect}) {
    final hostKind = classifyUri(uri);

    if (hostKind == RemoteServiceHostKind.invalid) {
      return _decision(
        hostKind: hostKind,
        source: RemoteServiceProxySource.directFallback,
      );
    }

    if ((forceDirect ?? this.forceDirect) ||
        (bypassLocalAddresses && _isLocalHostKind(hostKind))) {
      return _decision(
        hostKind: hostKind,
        source: RemoteServiceProxySource.directFallback,
      );
    }

    final manual = _parseProxy(manualProxy);
    if (manual != null) {
      return _decision(
        hostKind: hostKind,
        source: RemoteServiceProxySource.manualProxy,
        endpoint: manual,
      );
    }

    final noProxy = _readEnvironment(const ['NO_PROXY', 'no_proxy']);
    if (noProxy != null && _matchesNoProxy(uri, noProxy)) {
      return _decision(
        hostKind: hostKind,
        source: RemoteServiceProxySource.directFallback,
      );
    }

    final environmentProxy = _environmentProxy(uri);
    if (environmentProxy != null) {
      return _decision(
        hostKind: hostKind,
        source: RemoteServiceProxySource.environment,
        endpoint: environmentProxy.endpoint,
        environmentVariable: environmentProxy.variable,
      );
    }

    return _decision(
      hostKind: hostKind,
      source: RemoteServiceProxySource.directFallback,
    );
  }

  /// Callback suitable for [HttpClient.findProxy].
  String findProxy(Uri uri, {bool? forceDirect}) =>
      resolveProxy(uri, forceDirect: forceDirect).findProxyRule;

  /// Installs this policy on an existing client and returns that client.
  HttpClient configureHttpClient(
    HttpClient client, {
    bool? forceDirect,
  }) {
    client.findProxy = (uri) => findProxy(uri, forceDirect: forceDirect);
    return client;
  }

  /// Creates a client with this policy already installed.
  HttpClient createHttpClient({
    Duration? connectionTimeout,
    Duration? idleTimeout,
    int? maxConnectionsPerHost,
    bool? forceDirect,
  }) {
    final client = HttpClient();
    if (connectionTimeout != null) {
      client.connectionTimeout = connectionTimeout;
    }
    if (idleTimeout != null) {
      client.idleTimeout = idleTimeout;
    }
    if (maxConnectionsPerHost != null) {
      client.maxConnectionsPerHost = maxConnectionsPerHost;
    }
    return configureHttpClient(client, forceDirect: forceDirect);
  }

  RemoteServiceProxyDecision _decision({
    required RemoteServiceHostKind hostKind,
    required RemoteServiceProxySource source,
    _ProxyEndpoint? endpoint,
    String? environmentVariable,
  }) {
    final decision = RemoteServiceProxyDecision(
      hostKind: hostKind,
      source: source,
      proxyAddress: endpoint?.address,
      proxyRule: endpoint?.rule ?? 'DIRECT',
      environmentVariable: environmentVariable,
    );
    final log = logger;
    if (log != null) {
      // Do not include the URI, proxy endpoint, or environment value. Host
      // names can also be sensitive, so only stable classification is logged.
      try {
        log(
          'hostKind=${hostKind.name} source=${source.name} '
          'route=${decision.usesProxy ? 'proxy' : 'direct'}',
        );
      } catch (_) {
        // A logging failure must never change the selected network route.
      }
    }
    return decision;
  }

  _EnvironmentProxy? _environmentProxy(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    final keys = <String>[
      if (scheme == 'https') ...[
        'HTTPS_PROXY',
        'https_proxy',
      ],
      'HTTP_PROXY',
      'http_proxy',
      'ALL_PROXY',
      'all_proxy',
    ];
    for (final key in keys) {
      final value = _readEnvironment(<String>[key]);
      final endpoint = _parseProxy(value);
      if (endpoint != null) {
        return _EnvironmentProxy(endpoint, key);
      }
    }
    return null;
  }

  String? _readEnvironment(List<String> keys) {
    for (final key in keys) {
      final directValue = environment[key];
      if (directValue != null && directValue.trim().isNotEmpty) {
        return directValue.trim();
      }
    }
    for (final key in keys) {
      for (final entry in environment.entries) {
        if (entry.key.toLowerCase() == key.toLowerCase() &&
            entry.value.trim().isNotEmpty) {
          return entry.value.trim();
        }
      }
    }
    return null;
  }

  bool _matchesNoProxy(Uri uri, String value) {
    final host = _normalizeHost(uri.host);
    if (host.isEmpty) return false;
    final port = uri.hasPort ? uri.port : _defaultPort(uri.scheme);
    for (final rawToken in value.split(RegExp(r'[\s,]+'))) {
      final token = rawToken.trim();
      if (token.isEmpty) continue;
      if (token == '*') return true;

      final parsed = _parseNoProxyToken(token);
      if (parsed == null) continue;
      if (parsed.port != null && parsed.port != port) continue;

      if (parsed.host.contains('/')) {
        if (_matchesCidr(host, parsed.host)) return true;
        continue;
      }

      final tokenHost = _normalizeHost(parsed.host);
      if (tokenHost.isEmpty) continue;
      final suffixHost = tokenHost.startsWith('*.')
          ? tokenHost.substring(2)
          : tokenHost.startsWith('.')
              ? tokenHost.substring(1)
              : tokenHost;
      if (host == suffixHost || host.endsWith('.$suffixHost')) return true;
    }
    return false;
  }

  _NoProxyToken? _parseNoProxyToken(String token) {
    var host = token;
    int? port;
    if (token.startsWith('[')) {
      final close = token.indexOf(']');
      if (close < 0) return null;
      host = token.substring(1, close);
      final suffix = token.substring(close + 1);
      if (suffix.isNotEmpty) {
        if (!suffix.startsWith(':')) return null;
        port = int.tryParse(suffix.substring(1));
        if (!_isValidPort(port)) return null;
      }
    } else if (':'.allMatches(token).length == 1) {
      final separator = token.lastIndexOf(':');
      final candidatePort = int.tryParse(token.substring(separator + 1));
      if (candidatePort != null) {
        host = token.substring(0, separator);
        port = candidatePort;
        if (!_isValidPort(port)) return null;
      }
    }
    return _NoProxyToken(host: host, port: port);
  }

  bool _matchesCidr(String host, String cidr) {
    final separator = cidr.lastIndexOf('/');
    if (separator <= 0 || separator == cidr.length - 1) return false;
    final network = InternetAddress.tryParse(
      _normalizeHost(cidr.substring(0, separator)),
    );
    final target = InternetAddress.tryParse(host);
    final prefixLength = int.tryParse(cidr.substring(separator + 1));
    if (network == null || target == null || prefixLength == null) {
      return false;
    }
    final networkBytes = network.rawAddress;
    final targetBytes = target.rawAddress;
    if (networkBytes.length != targetBytes.length) return false;
    final maxPrefix = networkBytes.length * 8;
    if (prefixLength < 0 || prefixLength > maxPrefix) return false;

    var remaining = prefixLength;
    for (var i = 0; i < networkBytes.length && remaining > 0; i++) {
      final bits = remaining >= 8 ? 8 : remaining;
      final mask = (0xff << (8 - bits)) & 0xff;
      if ((networkBytes[i] & mask) != (targetBytes[i] & mask)) return false;
      remaining -= bits;
    }
    return true;
  }
}

/// Classifies a host without DNS resolution.
RemoteServiceHostKind classifyRemoteServiceHost(String host) {
  final normalized = _normalizeHost(host);
  if (normalized.isEmpty) return RemoteServiceHostKind.invalid;

  if (normalized == 'localhost' ||
      normalized.endsWith('.localhost') ||
      normalized == 'localhost.localdomain') {
    return RemoteServiceHostKind.loopback;
  }

  final address = InternetAddress.tryParse(normalized);
  if (address != null) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return _classifyIpv4(bytes);
    }
    final mappedIpv4 = _mappedIpv4Bytes(bytes);
    if (mappedIpv4 != null) return _classifyIpv4(mappedIpv4);
    if (_isIpv6Loopback(bytes)) return RemoteServiceHostKind.loopback;
    if (_isIpv6LinkLocal(bytes)) return RemoteServiceHostKind.linkLocal;
    if (_isIpv6Lan(bytes)) return RemoteServiceHostKind.lan;
    return RemoteServiceHostKind.ipv6;
  }

  // A malformed numeric address should not be treated as a DNS hostname.
  if (_looksLikeNumericIpv4(normalized) ||
      normalized.contains(':') ||
      normalized.contains(RegExp(r'[\s/@?#]'))) {
    return RemoteServiceHostKind.invalid;
  }

  // Single-label and .local names are commonly used by LAN discovery and
  // should remain direct without attempting DNS resolution.
  if (normalized == 'local' ||
      normalized.endsWith('.local') ||
      !normalized.contains('.')) {
    return RemoteServiceHostKind.loopback;
  }

  final labels = normalized.split('.');
  final validHostname = normalized.length <= 253 &&
      labels.every(
        (label) =>
            label.isNotEmpty &&
            label.length <= 63 &&
            !label.startsWith('-') &&
            !label.endsWith('-') &&
            RegExp(r'^[a-z0-9_-]+$', caseSensitive: false).hasMatch(label),
      );
  return validHostname
      ? RemoteServiceHostKind.hostname
      : RemoteServiceHostKind.invalid;
}

RemoteServiceHostKind classifyRemoteServiceUri(Uri uri) {
  return classifyRemoteServiceHost(uri.host);
}

bool _isLocalHostKind(RemoteServiceHostKind kind) {
  return kind == RemoteServiceHostKind.loopback ||
      kind == RemoteServiceHostKind.lan ||
      kind == RemoteServiceHostKind.linkLocal;
}

RemoteServiceHostKind _classifyIpv4(List<int> bytes) {
  if (bytes.length != 4) return RemoteServiceHostKind.invalid;
  final first = bytes[0];
  final second = bytes[1];
  if (first == 127) return RemoteServiceHostKind.loopback;
  if (first == 169 && second == 254) {
    return RemoteServiceHostKind.linkLocal;
  }
  if (first == 10 ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168)) {
    return RemoteServiceHostKind.lan;
  }
  return RemoteServiceHostKind.publicIp;
}

List<int>? _mappedIpv4Bytes(List<int> bytes) {
  if (bytes.length != 16 ||
      bytes.take(10).any((byte) => byte != 0) ||
      bytes[10] != 0xff ||
      bytes[11] != 0xff) {
    return null;
  }
  return bytes.sublist(12);
}

bool _isIpv6Loopback(List<int> bytes) {
  return bytes.length == 16 &&
      bytes.take(15).every((byte) => byte == 0) &&
      bytes[15] == 1;
}

bool _isIpv6LinkLocal(List<int> bytes) {
  return bytes.length >= 2 && bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
}

bool _isIpv6Lan(List<int> bytes) {
  return bytes.isNotEmpty && (bytes[0] & 0xfe) == 0xfc;
}

String _normalizeHost(String host) {
  var value = host.trim();
  if (value.startsWith('[') && value.endsWith(']')) {
    value = value.substring(1, value.length - 1);
  }
  if (value.contains(':')) {
    final zoneSeparator = value.indexOf('%');
    if (zoneSeparator >= 0) value = value.substring(0, zoneSeparator);
  }
  return value.toLowerCase().replaceFirst(RegExp(r'\.+$'), '');
}

bool _looksLikeNumericIpv4(String value) {
  return value.contains('.') && RegExp(r'^[0-9.]+$').hasMatch(value);
}

bool _isValidPort(int? port) => port != null && port >= 1 && port <= 65535;

int _defaultPort(String scheme) => scheme.toLowerCase() == 'https' ? 443 : 80;

_ProxyEndpoint? _parseProxy(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty || value == '0' || value.contains(RegExp(r'\s'))) {
    return null;
  }

  final hasScheme =
      RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false).hasMatch(value);
  if (!hasScheme) {
    final endpoint = _parseHostPort(value);
    return endpoint == null ? null : _ProxyEndpoint('PROXY', endpoint.value);
  }

  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasAuthority || uri.userInfo.isNotEmpty) return null;
  if (uri.path.isNotEmpty && uri.path != '/') return null;
  if (uri.hasQuery || uri.hasFragment || uri.host.isEmpty) return null;
  if (classifyRemoteServiceHost(uri.host) == RemoteServiceHostKind.invalid) {
    return null;
  }
  if (classifyRemoteServiceHost(uri.host) == RemoteServiceHostKind.invalid) {
    return null;
  }
  final scheme = uri.scheme.toLowerCase();
  final rule = switch (scheme) {
    'http' || 'https' => 'PROXY',
    'socks' => 'SOCKS',
    'socks5' => 'SOCKS5',
    _ => null,
  };
  if (rule == null) return null;
  final port = uri.hasPort ? uri.port : _defaultPort(scheme);
  if (!_isValidPort(port)) return null;
  final address = _formatProxyAddress(uri.host, port);
  return _ProxyEndpoint(rule, address);
}

_ProxyAddress? _parseHostPort(String value) {
  if (value.isEmpty || value.contains(RegExp(r'[\s/@?#]'))) return null;
  String host;
  String portText;
  if (value.startsWith('[')) {
    final close = value.indexOf(']');
    if (close < 0 || close == value.length - 1 || value[close + 1] != ':') {
      return null;
    }
    host = value.substring(1, close);
    portText = value.substring(close + 2);
  } else {
    if (':'.allMatches(value).length != 1) return null;
    final separator = value.lastIndexOf(':');
    host = value.substring(0, separator);
    portText = value.substring(separator + 1);
  }
  final port = int.tryParse(portText);
  if (classifyRemoteServiceHost(host) == RemoteServiceHostKind.invalid ||
      !_isValidPort(port)) {
    return null;
  }
  return _ProxyAddress(_formatProxyAddress(host, port!));
}

String _formatProxyAddress(String host, int port) {
  final normalizedHost = _normalizeHost(host);
  return normalizedHost.contains(':')
      ? '[$normalizedHost]:$port'
      : '$normalizedHost:$port';
}

class _ProxyAddress {
  const _ProxyAddress(this.value);

  final String value;
}

class _ProxyEndpoint {
  const _ProxyEndpoint(this.ruleType, this.address);

  final String ruleType;
  final String address;

  String get rule => '$ruleType $address';
}

class _EnvironmentProxy {
  const _EnvironmentProxy(this.endpoint, this.variable);

  final _ProxyEndpoint endpoint;
  final String variable;
}

class _NoProxyToken {
  const _NoProxyToken({required this.host, this.port});

  final String host;
  final int? port;
}
