// This validates delegation/audit boundaries, not native UI acceptance.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

import '../tools/image_pipeline_022_normal_ui_observer.dart';
import '../tools/image_pipeline_022_task_storage.dart';

class _Delegate extends SharePlatform {
  final result = const ShareResult('', ShareResultStatus.dismissed);
  bool fail = false;
  int calls = 0;
  List<XFile>? received;
  String? receivedText;
  Rect? receivedOrigin;
  @override
  Future<ShareResult> shareXFiles(List<XFile> files,
      {String? subject, String? text, Rect? sharePositionOrigin}) async {
    calls++;
    received = files;
    receivedText = text;
    receivedOrigin = sharePositionOrigin;
    if (fail) throw StateError('native-cancel-failure');
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory parent;
  late ImagePipelineTaskStorage storage;
  late ImagePipelineNormalUiObserver observer;
  late File file;
  final previous = SharePlatform.instance;
  setUp(() async {
    parent = await Directory.systemTemp.createTemp('normal-ui-observer-');
    storage = await ImagePipelineTaskStorage.prepare(
        p.join(parent.path, 'normal-ui-022-observer'));
    observer = ImagePipelineNormalUiObserver(storage);
    file = await File(p.join(storage.library, 'original.png'))
        .writeAsBytes([137, 80, 78, 71, 1, 2, 3]);
  });
  tearDown(() async {
    SharePlatform.instance = previous;
    await parent.delete(recursive: true);
  });

  Future<List<Map<String, dynamic>>> records() async => [
        for (final line
            in await File(p.join(storage.root, 'normal-ui-audit.jsonl'))
                .readAsLines())
          jsonDecode(line) as Map<String, dynamic>
      ];

  test(
      'a registered delegate receives unchanged arguments and its cancelled result is retained',
      () async {
    final delegate = _Delegate();
    SharePlatform.instance = TaskNativeShareAudit(delegate, observer);
    final files = [XFile(file.path, mimeType: 'image/png')];
    const origin = Rect.fromLTWH(10, 20, 30, 40);
    final result = await SharePlatform.instance
        .shareXFiles(files, text: 'task', sharePositionOrigin: origin);
    expect(result, same(delegate.result));
    expect(delegate.calls, 1);
    expect(delegate.received, same(files));
    expect(delegate.receivedText, 'task');
    expect(delegate.receivedOrigin, origin);
    final audit = await records();
    expect(audit.map((record) => record['event']),
        ['native-share-start', 'native-share-return']);
    final evidence = (audit.first['files'] as List).single as Map;
    expect(evidence['sha256'],
        sha256.convert(await file.readAsBytes()).toString());
    expect(evidence['sourceStable'], true);
    expect(audit.last['status'], 'dismissed');
  });

  test(
      'native failures propagate and an outside-task input is never hashed by the observer',
      () async {
    final delegate = _Delegate()..fail = true;
    SharePlatform.instance = TaskNativeShareAudit(delegate, observer);
    final outside = File(p.join(parent.path, 'outside.png'));
    final files = [XFile(outside.path, mimeType: 'image/png')];
    await expectLater(
        SharePlatform.instance.shareXFiles(files), throwsStateError);
    expect(delegate.calls, 1);
    final audit = await records();
    final evidence = (audit.first['files'] as List).single as Map;
    expect(evidence['auditError'], contains('outside the verification task'));
    expect(evidence.containsKey('sha256'), false);
    expect(audit.last['event'], 'native-share-error');
    expect(audit.last['error'], contains('native-cancel-failure'));
    expect(await outside.exists(), false);
  });
}
