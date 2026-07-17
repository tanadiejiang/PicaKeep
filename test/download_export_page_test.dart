import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_export/download_export_core.dart';
import 'package:picakeep/foundation/download_export/download_export_models.dart';
import 'package:picakeep/foundation/download_export/download_export_page.dart';

void main() {
  testWidgets('field page defaults, all/reset and empty submit state',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final request = DownloadExportRequest(
      descriptor: DownloadExportDescriptor(title: '测试漫画'),
      source: const DownloadExportUnsupportedSource('widget test'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadExportFieldConfigPage(requests: [request]),
      ),
    );

    expect(_checkboxValue(tester, '标题'), isTrue);
    expect(_checkboxValue(tester, '作者/画师'), isTrue);
    expect(_checkboxValue(tester, 'ID'), isTrue);
    expect(_checkboxValue(tester, '链接'), isFalse);
    expect(_checkboxValue(tester, '本地路径'), isFalse);
    expect(find.text('可能暴露设备目录信息'), findsNWidgets(2));

    await tester.tap(find.text('全选字段'));
    await tester.pump();
    for (final field in DownloadExportField.values) {
      expect(_checkboxValue(tester, field.label), isTrue);
    }

    await tester.tap(find.text('恢复默认'));
    await tester.pump();
    expect(_checkboxValue(tester, '标题'), isTrue);
    expect(_checkboxValue(tester, '链接'), isFalse);

    await tester.tap(find.widgetWithText(CheckboxListTile, '标题'));
    await tester.tap(find.widgetWithText(CheckboxListTile, '作者/画师'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'ID'));
    await tester.pump();
    expect(find.text('至少选择一项'), findsOneWidget);
    final submit = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '生成并分享清单'),
    );
    expect(submit.onPressed, isNull);
    final copy = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '复制到剪贴板'),
    );
    expect(copy.onPressed, isNull);
  });

  testWidgets('copy stays on the page and does not deliver an artifact',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final observer = _RecordingNavigatorObserver();
    final service = _RecordingExportService();
    final sink = _RecordingSink();
    final clipboardDone = Completer<void>();
    String? copiedText;
    final request = _request();

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: DownloadExportFieldConfigPage(
          requests: [request],
          service: service,
          sink: sink,
          clipboardWriter: (text) async {
            copiedText = text;
            await clipboardDone.future;
          },
        ),
      ),
    );
    final pushesBeforeCopy = observer.pushes;

    await tester.tap(find.widgetWithText(OutlinedButton, '复制到剪贴板'));
    await tester.pump();

    expect(service.buildManifestCalls, 1);
    expect(service.exportAndDeliverCalls, 0);
    expect(sink.deliverCalls, 0);
    expect(observer.pushes, pushesBeforeCopy);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, '生成并分享清单'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, '复制到剪贴板'),
          )
          .onPressed,
      isNull,
    );

    clipboardDone.complete();
    await tester.pumpAndSettle();

    expect(copiedText, contains('=== 测试漫画 ==='));
    expect(find.text('已复制到剪贴板'), findsOneWidget);
  });

  testWidgets('copy failure is reported without calling delivery',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _RecordingExportService(
      buildError: StateError('manifest unavailable'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DownloadExportFieldConfigPage(
          requests: [_request()],
          service: service,
          clipboardWriter: (_) async {},
        ),
      ),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, '复制到剪贴板'));
    await tester.pumpAndSettle();

    expect(find.textContaining('复制清单失败'), findsOneWidget);
    expect(service.exportAndDeliverCalls, 0);
  });

  testWidgets('sharing pushes progress page and invokes export service',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final observer = _RecordingNavigatorObserver();
    final service = _RecordingExportService();

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: DownloadExportFieldConfigPage(
          requests: [_request()],
          service: service,
        ),
      ),
    );
    final pushesBeforeShare = observer.pushes;

    await tester.tap(find.widgetWithText(FilledButton, '生成并分享清单'));
    await tester.pump();

    expect(observer.pushes, pushesBeforeShare + 1);

    for (var attempt = 0;
        attempt < 20 && service.exportAndDeliverCalls == 0;
        attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(service.exportAndDeliverCalls, 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('导出完成'), findsOneWidget);
  });
}

bool _checkboxValue(WidgetTester tester, String label) {
  final tile = tester.widget<CheckboxListTile>(
    find.widgetWithText(CheckboxListTile, label),
  );
  return tile.value ?? false;
}

DownloadExportRequest _request() {
  return DownloadExportRequest(
    descriptor: DownloadExportDescriptor(title: '测试漫画'),
    source: const DownloadExportUnsupportedSource('widget test'),
  );
}

class _RecordingNavigatorObserver extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<void> route, Route<void>? previousRoute) {
    pushes++;
    super.didPush(route, previousRoute);
  }
}

class _RecordingSink implements DownloadExportArtifactSink {
  int deliverCalls = 0;

  @override
  Future<DownloadExportDeliveryOutcome> deliver(
    DownloadExportArtifact artifact,
  ) async {
    deliverCalls++;
    return const DownloadExportDeliveryOutcome.delivered();
  }
}

class _RecordingExportService extends DownloadExportService {
  _RecordingExportService({this.buildError});

  final Object? buildError;
  int buildManifestCalls = 0;
  int exportAndDeliverCalls = 0;

  @override
  Future<String> buildManifestText({
    required List<DownloadExportRequest> requests,
    required DownloadExportFieldConfiguration fields,
    DownloadExportCancellationToken? cancellation,
    DownloadExportProgressCallback? onProgress,
    bool omitEmptyOptionalFields = false,
  }) async {
    buildManifestCalls++;
    if (buildError != null) throw buildError!;
    return '=== 测试漫画 ===\n标题: 测试漫画\n';
  }

  @override
  Future<DownloadExportResult> exportAndDeliver({
    required List<DownloadExportRequest> requests,
    required DownloadExportFieldConfiguration fields,
    required bool includeContent,
    required DownloadExportArtifactSink sink,
    DownloadExportCancellationToken? cancellation,
    DownloadExportProgressCallback? onProgress,
    String? suggestedName,
    Directory? tempRoot,
  }) async {
    exportAndDeliverCalls++;
    return DownloadExportResult(
      status: DownloadExportResultStatus.success,
      processed: requests.length,
      total: requests.length,
    );
  }
}
