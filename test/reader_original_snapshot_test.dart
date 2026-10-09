import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/image_pipeline/reader_failure_diagnostics.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';
import 'package:picakeep/pages/reader/reader_page_image.dart';

class _Snapshot implements FileStat {
  _Snapshot(
      {this.size = 100,
      int modified = 1000,
      int changed = 2000,
      this.type = FileSystemEntityType.file})
      : modified = DateTime.fromMicrosecondsSinceEpoch(modified, isUtc: true),
        changed = DateTime.fromMicrosecondsSinceEpoch(changed, isUtc: true);
  @override
  final int size;
  @override
  final FileSystemEntityType type;
  @override
  final DateTime modified, changed;
  @override
  DateTime get accessed =>
      DateTime.fromMicrosecondsSinceEpoch(3000, isUtc: true);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReadHandle implements RandomAccessFile {
  _ReadHandle(this.owner);
  final _SnapshotFile owner;
  int closes = 0;
  final reads = <int>[];
  @override
  Future<Uint8List> read(int bytes) async {
    reads.add(bytes);
    owner.events.add('read:$bytes');
    if (owner.readFailure != null) throw owner.readFailure!;
    owner.didRead = true;
    return Uint8List.fromList(owner.readBytes);
  }

  @override
  Future<void> close() async {
    closes++;
    owner.events.add('close');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    fail(
        'Snapshot acquisition must not call RandomAccessFile.${invocation.memberName}');
  }
}

class _SnapshotFile implements File {
  _SnapshotFile({FileStat? before, FileStat? after})
      : before = before ?? _Snapshot(),
        after = after ?? _Snapshot(changed: 2001) {
    handle = _ReadHandle(this);
  }
  final FileStat before, after;
  FileStat? next;
  late final _ReadHandle handle;
  bool didRead = false;
  int opens = 0, stats = 0;
  Object? openFailure, readFailure, beforeStatFailure, afterStatFailure;
  List<int> readBytes = [42];
  final modes = <FileMode>[];
  final events = <String>[];
  @override
  String get path => 'test-snapshot-original';
  @override
  File get absolute => this;
  @override
  Future<FileStat> stat() async {
    stats++;
    events.add('stat');
    if (!didRead && beforeStatFailure != null) throw beforeStatFailure!;
    if (didRead && afterStatFailure != null) throw afterStatFailure!;
    return next ?? (didRead ? after : before);
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    opens++;
    modes.add(mode);
    events.add('open');
    if (openFailure != null) throw openFailure!;
    return handle;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    fail('Snapshot acquisition must not call File.${invocation.memberName}');
  }
}

void main() {
  test(
      'first byte establishes refreshed ctime before the strict reader baseline',
      () async {
    final file = _SnapshotFile();
    final leases = ReaderPageFileLease.activeLeaseCount;
    final snapshot = await captureReaderOriginalSnapshot(file);
    expect(snapshot, same(file.after));
    expect(snapshot.changed.microsecondsSinceEpoch, 2001);
    expect(file.events, ['stat', 'open', 'read:1', 'stat', 'close']);
    expect(file.modes, [FileMode.read]);
    expect(file.handle.reads, [1]);
    expect(file.handle.closes, 1);
    expect(ReaderPageFileLease.activeLeaseCount, leases,
        reason: 'The caller owns the lease; capture does not acquire one');
    final source = FileReaderPageSource(
        identity: const ReaderPageIdentity(
            sourceKey: 'fixture',
            workId: 'fixture',
            downloadId: 'fixture',
            episode: 1,
            page: 0,
            sourceVersion: '1'),
        file: file);
    final resolved = ReaderResolvedOriginal(
        source: source,
        file: file,
        metadata: const ReaderRasterMetadata(
            size: Size(10, 10),
            animated: false,
            format: 'png',
            workingBytes: 400),
        fileSnapshot: snapshot);
    await resolved.verifyCurrent();
    file.next = _Snapshot(changed: 2002);
    await expectLater(
        resolved.verifyCurrent(),
        throwsA(isA<ReaderSourceSnapshotMismatch>().having(
            (error) => error.snapshot['changedMatches'],
            'ctime still strict',
            false)));
    expect(file.opens, 1);
    expect(file.handle.reads, [1]);
  });

  for (final change in ['size', 'modified', 'type']) {
    test('$change changes during first read are rejected and close the handle',
        () async {
      final file = _SnapshotFile(
          after: switch (change) {
        'size' => _Snapshot(size: 101),
        'modified' => _Snapshot(modified: 1001),
        _ => _Snapshot(type: FileSystemEntityType.notFound),
      });
      await expectLater(captureReaderOriginalSnapshot(file),
          throwsA(isA<ReaderSourceSnapshotMismatch>()));
      expect(file.events, ['stat', 'open', 'read:1', 'stat', 'close']);
      expect(file.handle.closes, 1);
      expect(file.modes, [FileMode.read]);
    });
  }

  test('empty first byte fails instead of publishing a warm snapshot',
      () async {
    final file = _SnapshotFile()..readBytes = [];
    await expectLater(captureReaderOriginalSnapshot(file),
        throwsA(isA<FileSystemException>()));
    expect(file.events, ['stat', 'open', 'read:1', 'close']);
    expect(file.stats, 1);
    expect(file.handle.reads, [1]);
    expect(file.handle.closes, 1);
    expect(file.modes, [FileMode.read]);
  });

  for (final failureStage in ['beforeStat', 'open', 'read', 'afterStat']) {
    test(
        '$failureStage failure preserves caller lease and closes only acquired handles',
        () async {
      final failure = FileSystemException('Injected $failureStage failure');
      final file = _SnapshotFile();
      switch (failureStage) {
        case 'beforeStat':
          file.beforeStatFailure = failure;
        case 'open':
          file.openFailure = failure;
        case 'read':
          file.readFailure = failure;
        case 'afterStat':
          file.afterStatFailure = failure;
      }
      final baselineLeases = ReaderPageFileLease.activeLeaseCount;
      final release = ReaderPageFileLease.acquire(file);
      try {
        await expectLater(
            captureReaderOriginalSnapshot(file), throwsA(same(failure)));
        expect(ReaderPageFileLease.activeLeaseCount, baselineLeases + 1);
        expect(file.handle.closes,
            failureStage == 'read' || failureStage == 'afterStat' ? 1 : 0);
        expect(file.opens, failureStage == 'beforeStat' ? 0 : 1);
        expect(
            file.handle.reads,
            failureStage == 'read' || failureStage == 'afterStat'
                ? [1]
                : isEmpty);
        expect(file.modes.every((mode) => mode == FileMode.read), isTrue);
      } finally {
        release();
      }
      expect(ReaderPageFileLease.activeLeaseCount, baselineLeases);
    });
  }
}
