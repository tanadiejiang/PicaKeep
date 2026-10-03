import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/ai/ai_tool_plugin_store.dart';
import 'package:picakeep/pages/ai/ai_tool_plugins_page.dart';

/// UI contract fake. Atomic file persistence and validation are covered by the
/// store/runtime tests; these tests exercise visible actions and failure states.
class _Store extends AiToolPluginStore {
  _Store() : super.atFile(File('not-used-by-ui-test'));
  AiToolPluginRecord entry = AiToolPluginRecord(builtinImageSearchPlugin());
  final calls = <String>[];
  bool maintenance = false;
  bool failImport = false;

  @override
  Future<void> load() async {}
  @override
  List<AiToolPluginRecord> get records => [entry];
  @override
  AiToolPluginRecord? record(String id) => id == entry.plugin.id ? entry : null;
  @override
  bool get maintenanceEnabled => maintenance;
  @override
  Future<void> importManifest(String text, {bool fromAi = false}) async {
    calls.add('import');
    if (failImport) throw const FormatException('插件存储失败');
    entry = AiToolPluginRecord(AiToolPlugin.fromJson(jsonDecode(text)),
        previous: entry.plugin);
    notifyListeners();
  }

  @override
  Future<void> setEnabled(String id, bool enabled) async {
    calls.add('enabled:$enabled');
    entry = AiToolPluginRecord(entry.plugin,
        enabled: enabled, previous: entry.previous);
    notifyListeners();
  }

  @override
  Future<void> setMaintenanceEnabled(bool enabled) async {
    calls.add('maintenance:$enabled');
    maintenance = enabled;
    notifyListeners();
  }

  @override
  Future<void> rollback(String id, {bool fromAi = false}) async {
    calls.add('rollback');
    entry = AiToolPluginRecord(entry.previous!, previous: entry.plugin);
    notifyListeners();
  }

  @override
  Future<void> restoreBuiltin() async {
    calls.add('builtin');
    entry =
        AiToolPluginRecord(builtinImageSearchPlugin(), previous: entry.plugin);
    notifyListeners();
  }

  @override
  String exportManifest(String id) => jsonEncode(entry.plugin.toJson());
}

String _update() => jsonEncode(
    builtinImageSearchPlugin().toJson()..['version'] = 'new-version');

void main() {
  Future<void> mount(WidgetTester tester, _Store store,
      {String? manifest,
      Future<Map<String, Object?>> Function(String)? diagnose}) async {
    await tester.pumpWidget(MaterialApp(
        home: AiToolPluginsPage(
      store: store,
      pickManifest: () async => manifest,
      diagnose: diagnose,
    )));
    await tester.pumpAndSettle();
  }

  testWidgets('import previews version and network target before applying',
      (tester) async {
    final store = _Store();
    addTearDown(store.dispose);
    await mount(tester, store, manifest: _update());
    await tester.tap(find.text('从文件导入'));
    await tester.pumpAndSettle();
    expect(find.text('更新工具插件'), findsOneWidget);
    expect(find.text('https://soutubot.moe/api/search'), findsOneWidget);
    expect(store.calls, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.calls, isEmpty);
    await tester.tap(find.text('从文件导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新'));
    await tester.pumpAndSettle();
    expect(store.calls, ['import']);
    expect(find.text('以图搜源 · new-version'), findsOneWidget);
  });

  testWidgets(
      'invalid or failed import stays on current version and allows retry',
      (tester) async {
    final store = _Store();
    addTearDown(store.dispose);
    await mount(tester, store, manifest: '{}');
    await tester.tap(find.text('从文件导入'));
    await tester.pumpAndSettle();
    expect(find.text('不支持的插件格式版本'), findsOneWidget);
    expect(store.calls, isEmpty);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '从文件导入'))
            .onPressed,
        isNotNull);
    store.failImport = true;
    await mount(tester, store, manifest: _update());
    await tester.tap(find.text('从文件导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新'));
    await tester.pumpAndSettle();
    expect(find.text('插件存储失败'), findsOneWidget);
    expect(store.entry.plugin.version, builtinImageSearchPlugin().version);
  });

  testWidgets(
      'enabled and AI maintenance controls call separate store policies',
      (tester) async {
    final store = _Store();
    addTearDown(store.dispose);
    await mount(tester, store);
    final pluginSwitch = find.byType(Switch).first;
    await tester.tap(pluginSwitch);
    await tester.pumpAndSettle();
    expect(find.text('已停用'), findsOneWidget);
    final maintenance = find.widgetWithText(SwitchListTile, '允许 AI 维护工具');
    await tester.ensureVisible(maintenance);
    await tester.tap(maintenance);
    await tester.pumpAndSettle();
    expect(store.calls, ['enabled:false', 'maintenance:true']);
  });

  testWidgets('diagnosis shows progress and result without importing anything',
      (tester) async {
    final store = _Store();
    addTearDown(store.dispose);
    final pending = Completer<Map<String, Object?>>();
    final requests = <String>[];
    await mount(tester, store, diagnose: (id) {
      requests.add(id);
      return pending.future;
    });
    await tester.tap(find.byTooltip('搜图 Bot操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('诊断连接'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(requests, [builtinImagePluginId]);
    pending.complete({'http_ok': true, 'note': '未发送图片'});
    await tester.pumpAndSettle();
    expect(find.text('搜图 Bot · 诊断'), findsOneWidget);
    expect(find.textContaining('未发送图片'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(store.calls, isEmpty);
  });

  testWidgets(
      'export and recover actions remain accessible on narrow dark screens',
      (tester) async {
    final store = _Store();
    addTearDown(store.dispose);
    await store.importManifest(_update());
    store.calls.clear();
    tester.view.physicalSize = const Size(360, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!),
      home: AiToolPluginsPage(store: store),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜图 Bot操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出清单'));
    await tester.pumpAndSettle();
    expect(find.textContaining('new-version'), findsWidgets);
    expect(find.text('复制'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜图 Bot操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复上一版本 ${builtinImageSearchPlugin().version}'));
    await tester.pumpAndSettle();
    expect(store.calls, ['rollback']);
    expect(tester.takeException(), isNull);
  });
}
