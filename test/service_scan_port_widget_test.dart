import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/foundation/service_data_source.dart';
import 'package:picakeep/pages/service_info_page.dart';
import 'package:picakeep/pages/settings/runtime_service_settings.dart';

int _visualOrder(Rect rect) {
  return rect.top.round() * 1000 + rect.left.round();
}

void _restoreClientSettings({
  required String oldMode,
  required String oldAddress,
  required String oldDiscoveryMode,
  required String oldCustomPorts,
}) {
  appdata.settings[appRuntimeModeSettingIndex] = oldMode;
  appdata.settings[remoteServerAddressSettingIndex] = oldAddress;
  appdata.settings[serviceDiscoveryModeSettingIndex] = oldDiscoveryMode;
  appdata.settings[serviceScanCustomPortsSettingIndex] = oldCustomPorts;
}

class _StaticServiceDataSource implements RuntimeServiceDataSource {
  const _StaticServiceDataSource(this.snapshot);

  final ServiceInfoSnapshot snapshot;

  @override
  Future<ServiceInfoSnapshot> fetchSnapshot() async => snapshot;
}

void main() {
  testWidgets('compact editor shows built-in ports and quota', (tester) async {
    final oldValue = appdata.settings[serviceScanCustomPortsSettingIndex];
    appdata.settings[serviceScanCustomPortsSettingIndex] = '[]';
    addTearDown(() {
      appdata.settings[serviceScanCustomPortsSettingIndex] = oldValue;
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ServiceScanPortsEditor(compact: true),
        ),
      ),
    );

    expect(find.textContaining('9527'), findsOneWidget);
    expect(find.textContaining('8080'), findsOneWidget);
    expect(find.text('2 个'), findsOneWidget);
    expect(find.byTooltip('添加端口'), findsOneWidget);
  });

  testWidgets('full editor shows custom quota and restore control',
      (tester) async {
    final oldValue = appdata.settings[serviceScanCustomPortsSettingIndex];
    appdata.settings[serviceScanCustomPortsSettingIndex] =
        encodeServiceScanCustomPorts(
      List<int>.generate(maxServiceScanCustomPorts, (index) => 3000 + index),
    );
    addTearDown(() {
      appdata.settings[serviceScanCustomPortsSettingIndex] = oldValue;
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ServiceScanPortsEditor(),
        ),
      ),
    );

    expect(find.textContaining('8/8'), findsOneWidget);
    expect(find.text('恢复默认'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
  });

  testWidgets('service page keeps recovery actions on a narrow viewport',
      (tester) async {
    final oldMode = appdata.settings[appRuntimeModeSettingIndex];
    final oldAddress = appdata.settings[remoteServerAddressSettingIndex];
    appdata.settings[appRuntimeModeSettingIndex] = appRuntimeModeClient;
    appdata.settings[remoteServerAddressSettingIndex] = '';
    addTearDown(() {
      appdata.settings[appRuntimeModeSettingIndex] = oldMode;
      appdata.settings[remoteServerAddressSettingIndex] = oldAddress;
    });

    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: ServiceInfoPage(
          standalone: true,
          enableInlineAutoDiscovery: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('填写地址'), findsOneWidget);
    expect(find.text('自动发现'), findsOneWidget);
    expect(find.text('局域网发现'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('service-inline-rescan-action')),
        findsOneWidget);
    expect(find.textContaining('9527'), findsOneWidget);
  });

  testWidgets('empty address shows inline discovery zone instead of info card',
      (tester) async {
    final oldMode = appdata.settings[appRuntimeModeSettingIndex];
    final oldAddress = appdata.settings[remoteServerAddressSettingIndex];
    final oldDiscoveryMode = appdata.settings[serviceDiscoveryModeSettingIndex];
    final oldCustomPorts = appdata.settings[serviceScanCustomPortsSettingIndex];
    appdata.settings[appRuntimeModeSettingIndex] = appRuntimeModeClient;
    appdata.settings[remoteServerAddressSettingIndex] = '';
    appdata.settings[serviceDiscoveryModeSettingIndex] =
        serviceDiscoveryModeMdns;
    appdata.settings[serviceScanCustomPortsSettingIndex] = '[]';
    addTearDown(
      () => _restoreClientSettings(
        oldMode: oldMode,
        oldAddress: oldAddress,
        oldDiscoveryMode: oldDiscoveryMode,
        oldCustomPorts: oldCustomPorts,
      ),
    );

    await tester.binding.setSurfaceSize(const Size(360, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: ServiceInfoPage(
          standalone: true,
          enableInlineAutoDiscovery: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PopupMenuButton<String>), findsNothing);
    expect(find.text('局域网发现'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('service-inline-rescan-action')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey<String>('service-inline-edit-address-action')),
        findsOneWidget);
    // 无地址态不展示信息卡操作与断开。
    expect(find.byKey(const ValueKey<String>('service-discovery-action')),
        findsNothing);
    expect(find.byKey(const ValueKey<String>('service-refresh-action')),
        findsNothing);
    expect(find.byKey(const ValueKey<String>('service-disconnect-action')),
        findsNothing);
    expect(find.text('设备系统'), findsNothing);
  });

  testWidgets('configured address keeps info card actions ordered',
      (tester) async {
    const address = 'http://192.168.5.6:8080';
    const dataSource = _StaticServiceDataSource(
      ServiceInfoSnapshot(
        mode: appRuntimeModeClient,
        connectionState: ServiceConnectionState.offline,
        discoveryMode: serviceDiscoveryModeMdns,
        addressInput: address,
        normalizedAddress: address,
        statusText: '离线',
        detailText: '无法连接',
        deviceSystem: 'Linux',
        deviceName: 'NAS',
      ),
    );
    final oldMode = appdata.settings[appRuntimeModeSettingIndex];
    final oldAddress = appdata.settings[remoteServerAddressSettingIndex];
    final oldDiscoveryMode = appdata.settings[serviceDiscoveryModeSettingIndex];
    final oldCustomPorts = appdata.settings[serviceScanCustomPortsSettingIndex];
    appdata.settings[appRuntimeModeSettingIndex] = appRuntimeModeClient;
    appdata.settings[remoteServerAddressSettingIndex] = address;
    appdata.settings[serviceDiscoveryModeSettingIndex] =
        serviceDiscoveryModeMdns;
    appdata.settings[serviceScanCustomPortsSettingIndex] = '[]';
    addTearDown(
      () => _restoreClientSettings(
        oldMode: oldMode,
        oldAddress: oldAddress,
        oldDiscoveryMode: oldDiscoveryMode,
        oldCustomPorts: oldCustomPorts,
      ),
    );

    await tester.binding.setSurfaceSize(const Size(360, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: ServiceInfoPage(
          standalone: true,
          dataSource: dataSource,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('局域网发现'), findsNothing);
    expect(find.text('mDNS 发现（2）'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('service-discovery-action')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('service-refresh-action')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('service-edit-address-action')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('service-disconnect-action')),
        findsOneWidget);

    final discoveryRect = tester.getRect(
      find.byKey(const ValueKey<String>('service-discovery-action')),
    );
    final refreshRect = tester.getRect(
      find.byKey(const ValueKey<String>('service-refresh-action')),
    );
    final editRect = tester.getRect(
      find.byKey(const ValueKey<String>('service-edit-address-action')),
    );
    final disconnectRect = tester.getRect(
      find.byKey(const ValueKey<String>('service-disconnect-action')),
    );
    expect(_visualOrder(discoveryRect), lessThan(_visualOrder(editRect)));
    expect(_visualOrder(editRect), lessThan(_visualOrder(refreshRect)));
    expect(disconnectRect.top, lessThan(discoveryRect.top));

    final systemLabel = tester.getRect(find.text('设备系统'));
    final nameLabel = tester.getRect(find.text('设备名称'));
    expect(systemLabel.top, closeTo(nameLabel.top, 0.1));
  });

  testWidgets('discovery action follows the selected mode', (tester) async {
    final oldMode = appdata.settings[appRuntimeModeSettingIndex];
    final oldAddress = appdata.settings[remoteServerAddressSettingIndex];
    final oldDiscoveryMode = appdata.settings[serviceDiscoveryModeSettingIndex];
    final oldCustomPorts = appdata.settings[serviceScanCustomPortsSettingIndex];
    appdata.settings[appRuntimeModeSettingIndex] = appRuntimeModeClient;
    // 有地址才显示信息卡上的发现按钮（无地址为内联发现区）。
    appdata.settings[remoteServerAddressSettingIndex] =
        'http://192.168.5.6:8080';
    appdata.settings[serviceScanCustomPortsSettingIndex] = '[]';
    addTearDown(
      () => _restoreClientSettings(
        oldMode: oldMode,
        oldAddress: oldAddress,
        oldDiscoveryMode: oldDiscoveryMode,
        oldCustomPorts: oldCustomPorts,
      ),
    );

    for (final entry in <String, String>{
      serviceDiscoveryModeMdns: 'mDNS 发现（2）',
      serviceDiscoveryModeSubnetScan: '网段扫描（2）',
    }.entries) {
      appdata.settings[serviceDiscoveryModeSettingIndex] = entry.key;
      await tester.pumpWidget(
        MaterialApp(
          home: ServiceInfoPage(
            key: ValueKey<String>(entry.key),
            standalone: true,
            dataSource: _StaticServiceDataSource(
              ServiceInfoSnapshot(
                mode: appRuntimeModeClient,
                connectionState: ServiceConnectionState.offline,
                discoveryMode: entry.key,
                addressInput: 'http://192.168.5.6:8080',
                normalizedAddress: 'http://192.168.5.6:8080',
                statusText: '离线',
                detailText: 'test',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
      expect(find.textContaining('mDNS 发现（'),
          findsNWidgets(entry.key == serviceDiscoveryModeMdns ? 1 : 0));
      expect(find.textContaining('网段扫描（'),
          findsNWidgets(entry.key == serviceDiscoveryModeSubnetScan ? 1 : 0));
    }
  });

  testWidgets('client status and disconnect retain their existing flow',
      (tester) async {
    const address = 'http://service.test';
    const dataSource = _StaticServiceDataSource(
      ServiceInfoSnapshot(
        mode: appRuntimeModeClient,
        connectionState: ServiceConnectionState.online,
        discoveryMode: serviceDiscoveryModeMdns,
        addressInput: address,
        normalizedAddress: address,
        statusUrl: '$address/status',
        statusText: '在线',
        detailText: '服务端状态正常',
        httpStatusCode: 200,
        comicCount: 12,
        connectionCount: 2,
        deviceSystem: 'Linux',
        deviceName: '节点-客厅',
      ),
    );

    final oldMode = appdata.settings[appRuntimeModeSettingIndex];
    final oldAddress = appdata.settings[remoteServerAddressSettingIndex];
    final oldDiscoveryMode = appdata.settings[serviceDiscoveryModeSettingIndex];
    final oldCustomPorts = appdata.settings[serviceScanCustomPortsSettingIndex];
    appdata.settings[appRuntimeModeSettingIndex] = appRuntimeModeClient;
    appdata.settings[remoteServerAddressSettingIndex] = address;
    appdata.settings[serviceDiscoveryModeSettingIndex] =
        serviceDiscoveryModeMdns;
    appdata.settings[serviceScanCustomPortsSettingIndex] = '[]';
    addTearDown(
      () => _restoreClientSettings(
        oldMode: oldMode,
        oldAddress: oldAddress,
        oldDiscoveryMode: oldDiscoveryMode,
        oldCustomPorts: oldCustomPorts,
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: ServiceInfoPage(
          standalone: true,
          dataSource: dataSource,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('在线'), findsOneWidget);
    expect(find.text('Linux'), findsOneWidget);
    expect(find.text('节点-客厅'), findsOneWidget);
    expect(find.text('连接状态'), findsNothing);

    final disconnect =
        find.byKey(const ValueKey<String>('service-disconnect-action'));
    await tester.ensureVisible(disconnect);
    await tester.pumpAndSettle();
    await tester.tap(disconnect);
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text('断开当前服务')),
        findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text('断开连接')),
        findsOneWidget);

    await tester.tap(find.descendant(of: dialog, matching: find.text('取消')));
    await tester.pumpAndSettle();
    expect(appdata.settings[remoteServerAddressSettingIndex], address);
  });

  testWidgets('invalid but non-empty address remains clearable',
      (tester) async {
    const invalidAddress = 'not-a-service-address';
    const dataSource = _StaticServiceDataSource(
      ServiceInfoSnapshot(
        mode: appRuntimeModeClient,
        connectionState: ServiceConnectionState.invalidAddress,
        discoveryMode: serviceDiscoveryModeMdns,
        addressInput: invalidAddress,
        normalizedAddress: '',
        statusText: '地址格式无效',
        detailText: '当前地址无法解析为可访问的 HTTP 服务地址。',
      ),
    );

    final oldMode = appdata.settings[appRuntimeModeSettingIndex];
    final oldAddress = appdata.settings[remoteServerAddressSettingIndex];
    final oldDiscoveryMode = appdata.settings[serviceDiscoveryModeSettingIndex];
    final oldCustomPorts = appdata.settings[serviceScanCustomPortsSettingIndex];
    appdata.settings[appRuntimeModeSettingIndex] = appRuntimeModeClient;
    appdata.settings[remoteServerAddressSettingIndex] = invalidAddress;
    appdata.settings[serviceDiscoveryModeSettingIndex] =
        serviceDiscoveryModeMdns;
    appdata.settings[serviceScanCustomPortsSettingIndex] = '[]';
    addTearDown(
      () => _restoreClientSettings(
        oldMode: oldMode,
        oldAddress: oldAddress,
        oldDiscoveryMode: oldDiscoveryMode,
        oldCustomPorts: oldCustomPorts,
      ),
    );

    await tester.binding.setSurfaceSize(const Size(360, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: ServiceInfoPage(
          standalone: true,
          dataSource: dataSource,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Keep persistence inside the ignored build directory. Some Windows test
    // environments block Directory.systemTemp.createTemp indefinitely.
    App.dataPath = '${Directory.current.path}\\build';

    final disconnect =
      find.byKey(const ValueKey<String>('service-disconnect-action'));
    expect(disconnect, findsOneWidget);
    final disconnectWidget = tester.widget<Widget>(disconnect);
    expect((disconnectWidget as dynamic).onPressed, isNotNull);

    await tester.tap(disconnect);
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    await tester.tap(
      find.descendant(of: dialog, matching: find.text('断开连接')),
    );
    await tester.pumpAndSettle();

    expect(appdata.settings[remoteServerAddressSettingIndex], isEmpty);
  });

  testWidgets('client page remains scrollable without overflow at large text',
      (tester) async {
    const address = 'http://192.168.5.6:8080';
    const dataSource = _StaticServiceDataSource(
      ServiceInfoSnapshot(
        mode: appRuntimeModeClient,
        connectionState: ServiceConnectionState.offline,
        discoveryMode: serviceDiscoveryModeMdns,
        addressInput: address,
        normalizedAddress: address,
        statusText: '离线',
        detailText: 'test',
        deviceSystem: 'Linux',
        deviceName: 'NAS',
      ),
    );
    final oldMode = appdata.settings[appRuntimeModeSettingIndex];
    final oldAddress = appdata.settings[remoteServerAddressSettingIndex];
    final oldDiscoveryMode = appdata.settings[serviceDiscoveryModeSettingIndex];
    final oldCustomPorts = appdata.settings[serviceScanCustomPortsSettingIndex];
    appdata.settings[appRuntimeModeSettingIndex] = appRuntimeModeClient;
    appdata.settings[remoteServerAddressSettingIndex] = address;
    appdata.settings[serviceDiscoveryModeSettingIndex] =
        serviceDiscoveryModeMdns;
    appdata.settings[serviceScanCustomPortsSettingIndex] = '[]';
    addTearDown(
      () => _restoreClientSettings(
        oldMode: oldMode,
        oldAddress: oldAddress,
        oldDiscoveryMode: oldDiscoveryMode,
        oldCustomPorts: oldCustomPorts,
      ),
    );

    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(
          textScaler: TextScaler.linear(2),
        ),
        child: MaterialApp(
          home: ServiceInfoPage(
            standalone: true,
            dataSource: dataSource,
            enableInlineAutoDiscovery: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey<String>('service-device-identity-fields')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('service-discovery-action')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('service-refresh-action')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('service-edit-address-action')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('service-disconnect-action')),
        findsOneWidget);
  });

  testWidgets('client status shows an offline response without duplicate state',
      (tester) async {
    const address = 'http://service.test';
    const dataSource = _StaticServiceDataSource(
      ServiceInfoSnapshot(
        mode: appRuntimeModeClient,
        connectionState: ServiceConnectionState.offline,
        discoveryMode: serviceDiscoveryModeMdns,
        addressInput: address,
        normalizedAddress: address,
        statusUrl: '$address/status',
        statusText: '服务有响应，但状态异常',
        detailText: '服务端暂不可用',
        httpStatusCode: 503,
      ),
    );

    final oldMode = appdata.settings[appRuntimeModeSettingIndex];
    final oldAddress = appdata.settings[remoteServerAddressSettingIndex];
    final oldDiscoveryMode = appdata.settings[serviceDiscoveryModeSettingIndex];
    final oldCustomPorts = appdata.settings[serviceScanCustomPortsSettingIndex];
    appdata.settings[appRuntimeModeSettingIndex] = appRuntimeModeClient;
    appdata.settings[remoteServerAddressSettingIndex] = address;
    appdata.settings[serviceDiscoveryModeSettingIndex] =
        serviceDiscoveryModeMdns;
    appdata.settings[serviceScanCustomPortsSettingIndex] = '[]';
    addTearDown(
      () => _restoreClientSettings(
        oldMode: oldMode,
        oldAddress: oldAddress,
        oldDiscoveryMode: oldDiscoveryMode,
        oldCustomPorts: oldCustomPorts,
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: ServiceInfoPage(
          standalone: true,
          dataSource: dataSource,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('服务有响应，但状态异常'), findsOneWidget);
    expect(find.text('连接状态'), findsNothing);
  });
}
