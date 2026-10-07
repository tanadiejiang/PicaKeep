import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/tools/save_image.dart';
// The real share_plus implementation is retained; only the system dialog is mocked.
// ignore: depend_on_referenced_packages
import 'package:share_plus_platform_interface/method_channel/method_channel_share.dart';
// ignore: depend_on_referenced_packages
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory task;
  late File source;
  late ImageDiskQuota quota;
  final previousQuota = ImageDiskQuota.overrideForTesting;
  final previousShare = SharePlatform.instance;
  const contents = [137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3];
  var available = 1 << 30;
  final admittedTargets = <String>[];
  Future<void> Function()? onSpaceQuery;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    task = await Directory.systemTemp.createTemp('022-export-quota-');
    source = await File('${task.path}/source.bin').writeAsBytes(contents);
    available = 1 << 30;
    admittedTargets.clear();
    onSpaceQuery = null;
    quota = ImageDiskQuota(
        roots: () => [task.path],
        idleLimitBytes: () => 500 << 20,
        headroomBytes: 1,
        space: (path) async {
          admittedTargets.add(path);
          await onSpaceQuery?.call();
          return ImageDiskSpace(available, 'task');
        });
    ImageDiskQuota.overrideForTesting = quota;
    SharePlatform.instance = MethodChannelShare();
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(MethodChannelShare.channel, null);
    await quota.drain();
    expect(quota.pendingCount, 0);
    expect(ImageTemporaryPool.shared.reservedBytes, 0);
    expect(ReaderPageFileLease.activeLeaseCount, 0);
    for (final target in admittedTargets) {
      expect(await File(target).exists(), isFalse);
      expect(await File(target).parent.exists(), isFalse);
    }
    ImageDiskQuota.overrideForTesting = previousQuota;
    SharePlatform.instance = previousShare;
    await task.delete(recursive: true);
  });

  test('disk refusal never copies or opens the share dialog', () async {
    available = 0;
    var shared = false;
    messenger.setMockMethodCallHandler(MethodChannelShare.channel, (_) async {
      shared = true;
      return 'dismissed';
    });
    await expectLater(
        shareImage(source), throwsA(isA<ImageDiskQuotaExceeded>()));
    expect(shared, isFalse);
    expect(admittedTargets, isNotEmpty);
    expect(await source.readAsBytes(), contents);
  });

  test('cancelled share keeps its exact file and lease until platform returns',
      () async {
    final invoked = Completer<File>();
    final dismiss = Completer<void>();
    messenger.setMockMethodCallHandler(MethodChannelShare.channel,
        (call) async {
      expect(call.method, 'shareFilesWithResult');
      final file = File(((call.arguments as Map)['paths'] as List).single);
      invoked.complete(file);
      await dismiss.future;
      return 'dev.fluttercommunity.plus/share/dismissed';
    });
    final sharing = shareImage(source);
    final exported = await invoked.future;
    expect(exported.path, endsWith('.png'));
    expect(await exported.readAsBytes(), contents);
    expect(quota.pendingCount, 1);
    expect(ImageTemporaryPool.shared.reservedBytes, contents.length);
    expect(ReaderPageFileLease.activeLeaseCount, 1);
    expect(await source.readAsBytes(), contents);
    dismiss.complete();
    await sharing;
    await quota.drain();
    expect(await exported.exists(), isFalse);
  });

  test('platform failure removes its copy and returns all reservations',
      () async {
    messenger.setMockMethodCallHandler(MethodChannelShare.channel, (_) async {
      throw PlatformException(code: 'share-rejected');
    });
    await expectLater(shareImage(source), throwsA(isA<PlatformException>()));
    expect(await source.readAsBytes(), contents);
  });

  test('source growth after admission cannot write beyond its exact bound',
      () async {
    onSpaceQuery = () async {
      onSpaceQuery = null;
      await source.writeAsBytes([...contents, 4, 5, 6]);
    };
    var shared = false;
    messenger.setMockMethodCallHandler(MethodChannelShare.channel, (_) async {
      shared = true;
      return 'dismissed';
    });
    await expectLater(shareImage(source), throwsStateError);
    expect(shared, isFalse);
    expect(await source.readAsBytes(), [...contents, 4, 5, 6]);
  });
}
