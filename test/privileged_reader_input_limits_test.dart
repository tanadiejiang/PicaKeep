import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_loader/reader_image_limits.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/image_disk_quota.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/privileged_storage_access_flutter.dart'
    as access;
import 'package:picakeep/foundation/privileged_storage_access_io.dart'
    as io_access;

import 'support/image_disk_quota_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('lingxue.picakeep/storage_access');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final savedQuota = ImageDiskQuota.overrideForTesting;
  final savedRoot = appdata.settings[androidRootModeSettingIndex];
  final savedShizuku = appdata.settings[androidShizukuModeSettingIndex];
  final savedPlatform = access.PrivilegedStorageAccess.androidPlatformOverride;
  late Directory root;
  late File original;
  late String hiddenPath;
  late ImageDiskQuota quota;
  final content = Uint8List.fromList(List<int>.generate(2048, (i) => i % 251));
  final digest = sha256.convert(content).toString();
  final calls = <MethodCall>[];
  final destinations = <File>[];
  final writtenCounts = <int>[];
  final reservationAtCopy = <int>[];
  final cancelledIds = <String>[];
  final gates = <Completer<void>>[];
  final drains = <Future<void>>[];
  late Completer<void> entered;
  late Completer<void> cancelSeen;
  Future<void>? copyWait;
  bool failCopy = false, missingStat = false, changedAfterCopy = false;
  bool finishedCopy = false;
  int? statSize, copyLength;

  void mode(String kind) {
    access.PrivilegedStorageAccess.androidPlatformOverride = true;
    appdata.settings[androidRootModeSettingIndex] = kind == 'root' ? '1' : '0';
    appdata.settings[androidShizukuModeSettingIndex] =
        kind == 'shizuku' ? '1' : '0';
  }

  Future<Uint8List?> read(
          {int maximum = 64 << 20,
          bool Function()? isCancelled,
          Future<void>? cancelled}) =>
      runWithReaderImageReadLimits(
          ReaderImageReadLimits(
              maximumBytes: maximum,
              isCancelled: isCancelled,
              cancelled: cancelled),
          () => access.PrivilegedStorageAccess.readFileBytes(hiddenPath));

  void noOwnedCopies() {
    final remaining = Directory(App.cachePath)
        .listSync(recursive: true)
        .whereType<Directory>()
        .where((d) => p.basename(d.path).startsWith('copy-'));
    expect(remaining, isEmpty);
  }

  setUpAll(() async {
    root =
        await Directory.systemTemp.createTemp('privileged_reader_limits_057_');
    App.dataPath = p.join(root.path, 'app');
    App.cachePath = p.join(root.path, 'cache');
    await Directory(App.dataPath).create(recursive: true);
    await Directory(App.cachePath).create(recursive: true);
    original = await File(p.join(root.path, 'user-original.bin'))
        .writeAsBytes(content);
    // The alias is unreadable to dart:io. The mock privileged bridge maps it
    // to our isolated original; no real protected file or platform permission.
    hiddenPath = p.join(root.path, 'restricted-mount', 'page.png');
    quota = installTaskDiskQuota(() => [App.cachePath]);
  });
  setUp(() {
    calls.clear();
    destinations.clear();
    writtenCounts.clear();
    reservationAtCopy.clear();
    cancelledIds.clear();
    entered = Completer<void>();
    cancelSeen = Completer<void>();
    copyWait = null;
    failCopy = false;
    missingStat = false;
    changedAfterCopy = false;
    finishedCopy = false;
    statSize = null;
    copyLength = null;
    mode('root');
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      if (call.method.startsWith('statFile')) {
        expect(arguments['path'], hiddenPath);
        if (missingStat) return null;
        final stat = await original.stat();
        return <String, Object>{
          'size': statSize ?? stat.size,
          'modifiedMillis': stat.modified.millisecondsSinceEpoch +
              (changedAfterCopy && finishedCopy ? 1 : 0)
        };
      }
      if (call.method == 'cancelCopyToManaged') {
        cancelledIds.add(arguments['requestId'] as String);
        if (!cancelSeen.isCompleted) cancelSeen.complete();
        return true;
      }
      if (call.method.startsWith('readFile')) {
        // Legacy non-reader behavior is intentionally retained. Reader tests
        // below assert this full-byte bridge is NEVER selected.
        return content;
      }
      if (call.method.startsWith('copyFileToManaged')) {
        expect(arguments['path'], hiddenPath);
        final maximum = arguments['maxBytes'] as int;
        expect(maximum, lessThanOrEqualTo(64 << 20));
        final target = File(arguments['destination'] as String);
        expect(p.isWithin(App.cachePath, target.path), isTrue);
        expect(target.path, isNot(original.path));
        destinations.add(target);
        reservationAtCopy.add(ImageTemporaryPool.shared.reservedBytes);
        writtenCounts.add(0);
        final slot = writtenCounts.length - 1;
        entered.complete();
        await copyWait;
        // Faithful capped-copy behavior: check the next total BEFORE writing.
        // A gated native operation can still finish late after cancellation.
        final output = await target.open(mode: FileMode.write);
        try {
          final available = copyLength ?? content.length;
          for (var start = 0; start < available; start += 128) {
            final end = start + 128 < available ? start + 128 : available;
            final next = writtenCounts[slot] + end - start;
            if (next > maximum) {
              throw PlatformException(
                  code: 'bounded_copy',
                  message: 'actual bytes exceed reserved maximum');
            }
            await output.writeFrom(content, start, end);
            writtenCounts[slot] = next;
          }
        } finally {
          await output.close();
        }
        finishedCopy = true;
        if (failCopy) throw PlatformException(code: 'copy_failed');
        // This deliberately is not an output path the reader should trust.
        return original.path;
      }
      throw StateError('Unexpected bridge method ${call.method}');
    });
  });
  tearDown(() async {
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    gates.clear();
    await Future.wait(drains);
    drains.clear();
    messenger.setMockMethodCallHandler(channel, null);
    access.PrivilegedStorageAccess.androidPlatformOverride = savedPlatform;
    appdata.settings[androidRootModeSettingIndex] = savedRoot;
    appdata.settings[androidShizukuModeSettingIndex] = savedShizuku;
    await quota.drain();
    expect(ImageTemporaryPool.shared.reservedBytes, 0);
    expect(quota.activeBytes, 0);
    expect(quota.pendingCount, 0);
    noOwnedCopies();
    expect(sha256.convert(await original.readAsBytes()).toString(), digest);
  });
  tearDownAll(() async {
    ImageDiskQuota.overrideForTesting = savedQuota;
    expect(p.basename(root.path), startsWith('privileged_reader_limits_057_'));
    await root.delete(recursive: true);
  });

  for (final entry in <String, Future<Uint8List?> Function(String)>{
    'Flutter': access.PrivilegedStorageAccess.readFileBytes,
    'pure Dart': io_access.PrivilegedStorageAccess.readFileBytes,
  }.entries) {
    test(
        '${entry.key} ordinary reader files are bounded and legacy bytes stay unchanged',
        () async {
      expect(
          await runWithReaderImageReadLimits(
              ReaderImageReadLimits(maximumBytes: content.length),
              () => entry.value(original.path)),
          content);
      await expectLater(
          runWithReaderImageReadLimits(
              ReaderImageReadLimits(maximumBytes: content.length - 1),
              () => entry.value(original.path)),
          throwsA(isA<ReaderImageLimit>()));
      expect(await entry.value(original.path), content);
      expect(calls, isEmpty);
    });
    test(
        '${entry.key} pre-cancelled reader does not read or use an unsafe fallback',
        () async {
      await expectLater(
          runWithReaderImageReadLimits(
              ReaderImageReadLimits(isCancelled: () => true),
              () => entry.value(original.path)),
          throwsStateError);
      expect(calls, isEmpty);
    });
  }

  for (final kind in ['root', 'shizuku']) {
    test(
        '$kind reader retains real capped-copy bridge capability and exact workspace accounting',
        () async {
      mode(kind);
      expect(await read(maximum: content.length), content);
      expect(destinations, hasLength(1));
      expect(writtenCounts, [content.length]);
      expect(reservationAtCopy, [content.length]);
      final copy =
          calls.singleWhere((c) => c.method.startsWith('copyFileToManaged'));
      expect(
          copy.method,
          kind == 'root'
              ? 'copyFileToManagedWithRoot'
              : 'copyFileToManagedWithShizuku');
      expect((copy.arguments as Map)['maxBytes'], content.length);
      expect(calls.where((c) => c.method.startsWith('readFile')), isEmpty);
      expect(await destinations.single.parent.exists(), isFalse);
    });
    test('$kind non-reader legacy bridge remains available unchanged',
        () async {
      mode(kind);
      expect(await access.PrivilegedStorageAccess.readFileBytes(hiddenPath),
          content);
      expect(calls.single.method,
          kind == 'root' ? 'readFileWithRoot' : 'readFileWithShizuku');
      expect(destinations, isEmpty);
    });
  }

  test('oversized privileged stat is rejected before copy or full-byte bridge',
      () async {
    await expectLater(
        read(maximum: content.length - 1), throwsA(isA<ReaderImageLimit>()));
    expect(calls, hasLength(1));
    expect(destinations, isEmpty);
  });

  test(
      'even a wider caller bound cannot reserve more than 64 MiB for privileged staging',
      () async {
    statSize = (64 << 20) + 1;
    await expectLater(
        read(maximum: 128 << 20), throwsA(isA<ReaderImageLimit>()));
    expect(calls, hasLength(1));
    expect(destinations, isEmpty);
  });

  for (final size in [null, 0, -1]) {
    test(
        'unreliable privileged stat $size fails explicitly without a byte fallback',
        () async {
      missingStat = size == null;
      statSize = size;
      await expectLater(read(), throwsA(isA<FileSystemException>()));
      expect(calls, hasLength(1));
      expect(destinations, isEmpty);
    });
  }

  test(
      'actual copy growth is capped before write and partial owned files are removed',
      () async {
    statSize = 256;
    await expectLater(read(), throwsA(isA<PlatformException>()));
    expect(reservationAtCopy, [256]);
    expect(writtenCounts, [256]);
    expect(calls.where((c) => c.method.startsWith('readFile')), isEmpty);
    expect(await destinations.single.parent.exists(), isFalse);
  });

  test(
      'copy failure after writing still removes only owned output and releases quota',
      () async {
    failCopy = true;
    await expectLater(read(), throwsA(isA<PlatformException>()));
    expect(writtenCounts, [content.length]);
    expect(await destinations.single.parent.exists(), isFalse);
    expect(calls.where((c) => c.method.startsWith('readFile')), isEmpty);
  });

  for (final lateFailure in [false, true]) {
    test(
        'cancelled ${lateFailure ? 'failing' : 'successful'} native copy retains ownership until actual late completion',
        () async {
      final release = Completer<void>();
      gates.add(release);
      copyWait = release.future;
      failCopy = lateFailure;
      final signal = Completer<void>();
      var cancelled = false, settled = false;
      final pending =
          read(isCancelled: () => cancelled, cancelled: signal.future)
              .whenComplete(() => settled = true);
      drains.add(
          pending.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      final rejected = expectLater(pending, throwsA(anything));
      await entered.future;
      cancelled = true;
      signal.complete();
      await cancelSeen.future;
      expect(settled, isFalse);
      expect(cancelledIds, hasLength(1));
      expect(ImageTemporaryPool.shared.reservedBytes, content.length);
      expect(quota.activeBytes, content.length);
      expect(await destinations.single.parent.exists(), isTrue);
      release.complete();
      await rejected;
      expect(await destinations.single.parent.exists(), isFalse);
      expect(calls.where((c) => c.method.startsWith('readFile')), isEmpty);
      expect(ImageTemporaryPool.shared.reservedBytes, 0);
    });
  }

  test(
      'source metadata change after copy prevents returning a stale reader result',
      () async {
    changedAfterCopy = true;
    await expectLater(read(), throwsStateError);
    expect(await destinations.single.parent.exists(), isFalse);
  });

  test('inexact native copy length is rejected before aggregating reader bytes',
      () async {
    copyLength = content.length ~/ 2;
    await expectLater(read(), throwsStateError);
    expect(writtenCounts, [content.length ~/ 2]);
    expect(await destinations.single.parent.exists(), isFalse);
  });

  test(
      'temporary budget failure never starts copying or leaks a private directory',
      () async {
    final other = ImageTemporaryPool.shared.reserve(
        ImageTemporaryPool.shared.maximumBytes,
        purpose: 'isolated-test-reservation')!;
    try {
      await expectLater(read(), throwsA(isA<ImageDiskQuotaExceeded>()));
      expect(destinations, isEmpty);
      noOwnedCopies();
    } finally {
      other.release();
    }
  });
}
