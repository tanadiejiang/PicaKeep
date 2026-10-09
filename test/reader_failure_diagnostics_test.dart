import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_failure_diagnostics.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep_image_engine/picakeep_image_engine.dart';

class _FileSnapshot implements FileStat {
  _FileSnapshot(
      {this.size = 123,
      int modifiedMicros = 1000,
      int changedMicros = 2000,
      int accessedMicros = 3000,
      this.type = FileSystemEntityType.file})
      : modified =
            DateTime.fromMicrosecondsSinceEpoch(modifiedMicros, isUtc: true),
        changed =
            DateTime.fromMicrosecondsSinceEpoch(changedMicros, isUtc: true),
        accessed =
            DateTime.fromMicrosecondsSinceEpoch(accessedMicros, isUtc: true);
  @override
  final int size;
  @override
  final DateTime modified, changed, accessed;
  @override
  final FileSystemEntityType type;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => LogManager.recordingEnabled = true);
  tearDown(() => LogManager.recordingEnabled = true);

  test(
      'logical page survives source changes and source failure before selection',
      () {
    final lines = <String>[];
    final session = ReaderFailureDiagnosticsSession(writer: lines.add);
    final page = session.page(
        logicalIdentity: 'secret-work',
        chapter: 2,
        page: 3,
        readingMode: 'continuous');
    final first = page.beginAttempt(generation: 0, qualityMode: 'sharpFirst');
    first.failure(
        stage: 'loadSource',
        error: const FileSystemException(
            'https://secret.test/page?token=secret', 'C:/private/page.webp'));
    final next = page.beginAttempt(
        generation: 1, qualityMode: 'previewFirst', explicitRetry: true);
    next.updateSource(
        sourceVersion: 'C:/private/page:100:200',
        sourceType: 'FileReaderPageSource',
        fileLength: 100);
    next.recovered();
    final events = lines.map((line) => jsonDecode(line) as Map).toList();
    expect(events.map((event) => event['pageKey']).toSet(), {page.pageKey});
    expect(events.map((event) => event['event']),
        ['failure', 'explicitRetry', 'recovered']);
    expect(events.last['attempt'], 2);
    expect(events.last['snapshot']['sourceVersionHash'], isNotEmpty);
    expect(lines.join(), isNot(contains('secret')));
    expect(lines.join(), isNot(contains('private')));
    expect(events.first['reason'], 'fileIO');
    expect(
        session.page(
            logicalIdentity: 'secret-work',
            chapter: 2,
            page: 3,
            readingMode: 'horizontal'),
        same(page));
    expect(page.readingMode, 'horizontal');
    session.dispose();
  });

  test('dimension and resident limits retain accurate typed details', () {
    final lines = <String>[];
    final session = ReaderFailureDiagnosticsSession(writer: lines.add);
    final attempt = session
        .page(
            logicalIdentity: 'page',
            chapter: 1,
            page: 0,
            readingMode: 'continuous')
        .beginAttempt(generation: 0, qualityMode: 'sharpFirst');
    attempt.failure(
        stage: 'decode',
        error: const ReaderRasterDimensionMismatch(
            expectedSize: Size(300, 400), actualSize: Size(400, 300)));
    attempt.failure(
        stage: 'residentAdmission',
        error: ReaderResidentBudgetExceeded(
            requestBytes: 100,
            availableBytes: 50,
            snapshot: {
              'requestBytes': 100,
              'currentUsage': 950,
              'limitBytes': 1000,
              'availableBytes': 50,
              'localExceeded': true,
              'globalExceeded': false,
            }));
    final events = lines.map((line) => jsonDecode(line) as Map).toList();
    expect(events[0]['reason'], 'dimensionMismatch');
    expect(events[0]['snapshot']['expectedWidth'], 300);
    expect(events[1]['reason'], 'residentBudget');
    expect(events[1]['snapshot']['requestBytes'], 100);
    expect(events[1]['snapshot']['currentUsage'], 950);
    expect(events[1]['snapshot']['availableBytes'], 50);
    session.dispose();
  });

  test('source snapshot logs each comparison with safe microsecond precision',
      () {
    final lines = <String>[];
    final session = ReaderFailureDiagnosticsSession(writer: lines.add);
    final attempt = session
        .page(
            logicalIdentity: 'private-source',
            chapter: 1,
            page: 0,
            readingMode: 'continuous')
        .beginAttempt(generation: 0, qualityMode: 'sharpFirst');
    final error = ReaderSourceSnapshotMismatch(
        expected: _FileSnapshot(),
        current: _FileSnapshot(changedMicros: 2001, accessedMicros: 3010),
        sourceIdentityMatches: true);
    attempt.failure(stage: 'sourceValidation', error: error);
    final event = jsonDecode(lines.single) as Map;
    final snapshot = event['snapshot'] as Map;
    expect(event['reason'], 'sourceChanged');
    expect(event['errorType'], 'ReaderSourceSnapshotMismatch');
    expect(snapshot['fileTypeMatches'], isTrue);
    expect(snapshot['currentIsFile'], isTrue);
    expect(snapshot['fileSizeMatches'], isTrue);
    expect(snapshot['modifiedMatches'], isTrue);
    expect(snapshot['changedMatches'], isFalse);
    expect(snapshot['accessedMatches'], isFalse);
    expect(snapshot['sourceIdentityMatches'], isTrue);
    expect(snapshot['expectedChangedMicros'], 2000);
    expect(snapshot['currentChangedMicros'], 2001);
    expect(snapshot['expectedAccessedMicros'], 3000);
    expect(snapshot['currentAccessedMicros'], 3010);
    expect(snapshot['expectedModifiedMicros'], 1000);
    expect(snapshot['currentModifiedMicros'], 1000);
    expect(lines.single, isNot(contains('private')));
    expect(lines.single.length, lessThanOrEqualTo(3000));
    final changed = ReaderSourceSnapshotMismatch(
        expected: _FileSnapshot(),
        current: _FileSnapshot(
            size: 456,
            modifiedMicros: 9999,
            type: FileSystemEntityType.notFound),
        sourceIdentityMatches: false);
    expect(changed.snapshot['fileTypeMatches'], isFalse);
    expect(changed.snapshot['fileSizeMatches'], isFalse);
    expect(changed.snapshot['modifiedMatches'], isFalse);
    expect(changed.snapshot['sourceIdentityMatches'], isFalse);
    session.dispose();
  });

  for (final sample in <({
    String name,
    int localUsage,
    int globalUsage,
    bool alreadyPending,
    int available,
    int currentUsage,
    int limit
  })>[
    (
      name: 'global tighter',
      localUsage: 60,
      globalUsage: 191,
      alreadyPending: false,
      available: 1,
      currentUsage: 191,
      limit: 192
    ),
    (
      name: 'local tighter',
      localUsage: 63,
      globalUsage: 188,
      alreadyPending: false,
      available: 1,
      currentUsage: 63,
      limit: 64
    ),
    (
      name: 'tie chooses local',
      localUsage: 60,
      globalUsage: 188,
      alreadyPending: false,
      available: 4,
      currentUsage: 60,
      limit: 64
    ),
    (
      name: 'pending global tighter',
      localUsage: 68,
      globalUsage: 199,
      alreadyPending: true,
      available: 1,
      currentUsage: 191,
      limit: 192
    ),
    (
      name: 'pending local tighter',
      localUsage: 71,
      globalUsage: 196,
      alreadyPending: true,
      available: 1,
      currentUsage: 63,
      limit: 64
    ),
  ]) {
    test('resident usage uses one consistent tighter side: ${sample.name}', () {
      const unit = 1 << 20;
      final error = ReaderResidentBudgetExceeded.fromUsage(
          requestBytes: 8 * unit,
          localUsage: sample.localUsage * unit,
          globalUsage: sample.globalUsage * unit,
          localLimit: 64 * unit,
          globalLimit: 192 * unit,
          alreadyPending: sample.alreadyPending);
      expect(error.requestedBytes, 8 * unit);
      expect(error.budgetBytes, sample.available * unit);
      expect(error.snapshot['availableBytes'], error.budgetBytes);
      expect(error.snapshot['currentUsage'], sample.currentUsage * unit);
      expect(error.snapshot['limitBytes'], sample.limit * unit);
      expect((error.snapshot['currentUsage'] as int) + error.budgetBytes,
          error.snapshot['limitBytes']);
      expect(error.snapshot['localExceeded'], isTrue);
      expect(error.snapshot['globalExceeded'], isTrue);
      expect(error.snapshot['alreadyPending'], sample.alreadyPending);
    });
  }

  test(
      'partial source updates preserve previously observed source and metadata',
      () {
    final lines = <String>[];
    final session = ReaderFailureDiagnosticsSession(writer: lines.add);
    final attempt = session
        .page(
            logicalIdentity: 'page',
            chapter: 1,
            page: 0,
            readingMode: 'continuous')
        .beginAttempt(generation: 0, qualityMode: 'sharpFirst');
    attempt.updateSource(
        sourceVersion: 'private-source-version',
        sourceType: 'FileReaderPageSource');
    attempt.updateSource(fileLength: 321, fileModifiedMillis: 456);
    attempt.updateSource(
        backendType: 'FlutterReaderRasterBackend',
        width: 320,
        height: 480,
        format: 'png');
    attempt.updateSource(
        sourceType: 'FileReaderPageSource',
        backendType: 'FlutterReaderRasterBackend');
    attempt.failure(stage: 'decode', error: StateError('test'));
    final snapshot = (jsonDecode(lines.single) as Map)['snapshot'] as Map;
    expect(snapshot['sourceVersionHash'], matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(snapshot['sourceType'], 'FileReaderPageSource');
    expect(snapshot['fileLength'], 321);
    expect(snapshot['fileModifiedMillis'], 456);
    expect(snapshot['backendType'], 'FlutterReaderRasterBackend');
    expect(snapshot['width'], 320);
    expect(snapshot['height'], 480);
    expect(snapshot['format'], 'png');
    session.dispose();
  });

  test('cancel and normal prepared miss are not image failures', () {
    final lines = <String>[];
    final session = ReaderFailureDiagnosticsSession(writer: lines.add);
    final attempt = session
        .page(
            logicalIdentity: 'page',
            chapter: 1,
            page: 0,
            readingMode: 'continuous')
        .beginAttempt(generation: 0, qualityMode: 'sharpFirst');
    for (final error in <Object>[
      const ImageWorkCancelled(),
      const ImageEngineException(2, 'cancelled'),
      const ReaderPreparedReadMiss()
    ]) {
      attempt.failure(stage: 'decode', error: error);
    }
    attempt.recovered();
    expect(lines, isEmpty);
    attempt.failure(
        stage: 'probe',
        error: const ImageEngineException(3, 'hard memory limit'));
    expect((jsonDecode(lines.single) as Map)['reason'], 'nativeResourceLimit');
    session.dispose();
  });

  test('local retry preserves source context and closes obsolete callbacks',
      () {
    final lines = <String>[];
    final session = ReaderFailureDiagnosticsSession(writer: lines.add);
    final old = session
        .page(
            logicalIdentity: 'page',
            chapter: 1,
            page: 0,
            readingMode: 'continuous')
        .beginAttempt(generation: 0, qualityMode: 'previewFirst');
    old.updateSource(
        sourceVersion: 'path:1', sourceType: 'FileReaderPageSource');
    old.rendererPath('surface');
    old.failure(stage: 'decode', error: StateError('test'));
    old.updateQualityMode('sharpFirst');
    final next = old.explicitRetry(generation: 1);
    old.failure(stage: 'decode', error: StateError('obsolete'));
    old.recovered();
    next.recovered();
    final events = lines.map((line) => jsonDecode(line) as Map).toList();
    expect(events.map((event) => event['event']),
        ['failure', 'explicitRetry', 'recovered']);
    expect(events[1]['rendererPath'], 'surface');
    expect(events[1]['qualityMode'], 'sharpFirst');
    expect(events[1]['snapshot']['sourceVersionHash'],
        events[0]['snapshot']['sourceVersionHash']);
    session.dispose();
  });

  test('events stay bounded, valid JSON and exclude raw paths and text', () {
    final lines = <String>[];
    final session = ReaderFailureDiagnosticsSession(writer: lines.add);
    final attempt = session
        .page(
            logicalIdentity: 'page',
            chapter: 1,
            page: 0,
            readingMode: 'continuous')
        .beginAttempt(generation: 0, qualityMode: 'sharpFirst');
    for (var i = 0; i < 1000; i++) {
      attempt.failure(
          stage: 'decode',
          error: StateError('token=private-secret-$i'),
          stackTrace: StackTrace.fromString(
              '#0 Codec.decode (C:/private/token.dart:1)\n' * 1000),
          snapshot: {
            'url': 'https://private',
            'fileLength': 123,
            'format': 'https://private?token=secret'
          });
      attempt.retry(stage: 'decode', retry: i);
    }
    attempt.close();
    expect(lines.length, lessThanOrEqualTo(18));
    for (final line in lines) {
      expect(line.length, lessThanOrEqualTo(3000));
      expect(jsonDecode(line), isA<Map>());
      expect(line, isNot(contains('private')));
      expect(line, isNot(contains('token')));
    }
    expect((jsonDecode(lines.last) as Map)['failureCount'], 1000);
    session.dispose();
  });

  test('disabled logging and throwing writers cannot affect reading', () {
    final lines = <String>[];
    final session = ReaderFailureDiagnosticsSession(writer: lines.add);
    final attempt = session
        .page(
            logicalIdentity: 'page',
            chapter: 1,
            page: 0,
            readingMode: 'continuous')
        .beginAttempt(generation: 0, qualityMode: 'sharpFirst');
    LogManager.recordingEnabled = false;
    attempt.failure(stage: 'decode', error: StateError('test'));
    expect(lines, isEmpty);
    session.dispose();
    LogManager.recordingEnabled = true;
    final throwing = ReaderFailureDiagnosticsSession(
        writer: (_) => throw StateError('sink'));
    expect(
        () => throwing
            .page(
                logicalIdentity: 'page',
                chapter: 1,
                page: 0,
                readingMode: 'continuous')
            .beginAttempt(generation: 0, qualityMode: 'sharpFirst')
            .failure(stage: 'decode', error: StateError('test')),
        returnsNormally);
    throwing.dispose();
  });
}
