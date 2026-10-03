import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/pixiv_library.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory workspace;
  late PixivLibrary library;
  setUpAll(() {
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows,
          () => DynamicLibrary.open(
              p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
    }
  });
  setUp(() async {
    PixivLibrary.rootWriteBlocked = null;
    PixivLibrary.hasPendingDownloads = null;
    workspace = await Directory.systemTemp.createTemp('pk48_journals_');
    library = PixivLibrary(p.join(workspace.path, 'library'));
    await library.initialize();
  });
  tearDown(() async {
    PixivLibrary.rootWriteBlocked = null;
    PixivLibrary.hasPendingDownloads = null;
    await workspace.delete(recursive: true);
  });

  List<Map<String, Object?>> rows() {
    final db = sqlite3.open(library.dbPath, mode: OpenMode.readOnly);
    try {
      return db
          .select('SELECT * FROM pixiv_operations ORDER BY rowid')
          .map((r) => Map<String, Object?>.from(r))
          .toList();
    } finally {
      db.dispose();
    }
  }

  void journal(String id, String kind, Object payload,
      {String stage = 'complete', String? error}) {
    final db = sqlite3.open(library.dbPath);
    try {
      db.execute('INSERT OR REPLACE INTO pixiv_operations VALUES(?,?,?,?,?)', [
        id,
        kind,
        payload is String ? payload : jsonEncode(payload),
        stage,
        error
      ]);
    } finally {
      db.dispose();
    }
  }

  Map<String, Object?> legacyTransfer(String id, {int size = 8000}) => {
        'sourceFolder': 'root',
        'sourceRoot': library.root,
        'sourcePath': '/legacy',
        'targetFolder': 'old-target',
        'name': '$id.png',
        'move': false,
        'row': {'id': id, 'json': 'x' * size},
        'snapshot': {
          'files': {
            '': {'size': 1, 'sha256': 'a' * 64}
          }
        },
      };

  void legacyHistory(int count, {int size = 8000}) {
    final db = sqlite3.open(library.dbPath);
    try {
      db.execute('BEGIN IMMEDIATE');
      for (var i = 0; i < count; i++) {
        db.execute('INSERT INTO pixiv_operations VALUES(?,?,?,?,NULL)', [
          'legacy-$i',
          'transfer',
          jsonEncode(legacyTransfer('pixiv$i', size: size)),
          'complete'
        ]);
      }
      db.execute('COMMIT');
    } finally {
      db.dispose();
    }
  }

  Future<PixivRecord> seed(PixivFolder folder, String id) async {
    await File(p.join(folder.path, '$id.png')).writeAsString('bytes:$id');
    final db = PixivLibrary.openDownloads(folder.path);
    try {
      db.execute('INSERT INTO download VALUES(?,?,?,?,?,?,?)', [
        id,
        '作品 $id',
        '作者',
        1,
        '$id.png',
        1.0,
        jsonEncode({'id': id, 'metadata': 'z' * 4000})
      ]);
    } finally {
      db.dispose();
    }
    return library.find(folder.id, id)!;
  }

  void expectReceipt(Map<String, Object?> row) {
    final data = jsonDecode(row['payload'] as String) as Map;
    expect(data['summaryVersion'], 1);
    for (final key in [
      'row',
      'json',
      'snapshot',
      'items',
      'sourcePath',
      'quarantine'
    ]) {
      expect(data.containsKey(key), isFalse, reason: key);
    }
  }

  test('copy and move automatically compact without altering works or identity',
      () async {
    final a = await library.createFolder('A'),
        b = await library.createFolder('B');
    final source = await seed(a, 'pixiv1');
    final sourceDb = File(p.join(a.path, 'download.db')).readAsBytesSync();
    final copied = await library.transfer(source, b.id, move: false);
    expectReceipt(rows().singleWhere((row) => row['id'] == copied.id));
    expect(File(p.join(a.path, 'download.db')).readAsBytesSync(), sourceDb);
    final second = await seed(a, 'pixiv2');
    await library.transfer(second, b.id, move: true);
    expect(library.find(a.id, second.id), isNull);
    expect(
        library.records(b).map((r) => r.id), containsAll(['pixiv1', 'pixiv2']));
    expect(File(library.find(b.id, second.id)!.path).readAsStringSync(),
        'bytes:pixiv2');
    expect(library.folder(a.id).libraryId, a.libraryId);
    for (final row in rows()) {
      expectReceipt(row);
    }
  });

  test('batch compacts only at completion and repeated execution is harmless',
      () async {
    final a = await library.createFolder('A'),
        b = await library.createFolder('B');
    final first = await seed(a, 'pixiv1'), second = await seed(a, 'pixiv2');
    await library.transfer(first, b.id, move: false);
    final id = library.createBatch([first, second], b.id, move: true);
    await library.runBatch(id);
    final data = jsonDecode(
            rows().singleWhere((row) => row['id'] == id)['payload'] as String)
        as Map;
    expect(data['total'], 2);
    expect(data['succeeded'], 1);
    expect(data['skipped'], 1);
    for (final row in rows()) {
      expectReceipt(row);
    }
    final before = rows();
    await library.runBatch(id);
    expect(rows(), before);
    expect(library.records(b).length, 2);
    expect(library.find(a.id, first.id), isNotNull);
  });

  test(
      'legacy journals compact on reopen, cap at 100, shrink and stay idempotent',
      () async {
    final a = await library.createFolder('A');
    final work = await seed(a, 'pixiv1');
    final childDb = File(p.join(a.path, 'download.db')).readAsBytesSync();
    legacyHistory(130);
    final beforeBytes = File(library.dbPath).lengthSync();
    final payloadBefore =
        rows().fold<int>(0, (n, row) => n + (row['payload'] as String).length);
    await PixivLibrary(library.root).initialize();
    final completed = rows();
    expect(completed.length, 100);
    expect(completed.any((row) => row['id'] == 'legacy-129'), isTrue);
    expect(completed.any((row) => row['id'] == 'legacy-0'), isFalse);
    for (final row in completed) {
      expectReceipt(row);
    }
    final payloadAfter = completed.fold<int>(
        0, (n, row) => n + (row['payload'] as String).length);
    final afterBytes = File(library.dbPath).lengthSync();
    expect(payloadAfter, lessThan(payloadBefore ~/ 10));
    expect(afterBytes, lessThan(beforeBytes));
    expect(File(p.join(a.path, 'download.db')).readAsBytesSync(), childDb);
    expect(File(work.path).readAsStringSync(), 'bytes:pixiv1');
    final db = sqlite3.open(library.dbPath);
    try {
      expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
      expect(db.select('SELECT * FROM download'), isEmpty);
      expect(
          db.select('SELECT id FROM pixiv_library').single['id'], a.libraryId);
    } finally {
      db.dispose();
    }
    final again = await library.maintain();
    expect(again.compacted, 0);
    expect(again.pruned, 0);
    expect(again.vacuumed, isFalse);
    expect(rows(), completed);
    // Captured in the verification log; these are synthetic fixtures, not phone data.
    print(
        '48 fixture: DB $beforeBytes -> $afterBytes bytes; payload $payloadBefore -> $payloadAfter bytes');
  });

  for (final stage in ['prepared', 'published', 'committed', 'cleaning']) {
    test('maintenance preserves interrupted $stage move and recovery',
        () async {
      final a = await library.createFolder('A'),
          b = await library.createFolder('B');
      final source = await seed(a, 'pixiv1');
      final broken = PixivLibrary(library.root, afterStage: (_, s) {
        if (s == stage) throw StateError('shutdown');
      });
      await expectLater(
          broken.transfer(source, b.id, move: true), throwsStateError);
      final before = rows();
      expect((await library.maintain()).deferredReason, 'pending-operation');
      expect(rows(), before);
      await library.resume(library.pending().single['id'] as String);
      expect(library.pending(), isEmpty);
      expect(library.find(a.id, source.id), isNull);
      expect(library.records(b).length, 1);
      expect(File(library.find(b.id, source.id)!.path).readAsStringSync(),
          'bytes:pixiv1');
    });
  }

  test(
      'completed child survives parent accounting gap, then batch resumes once',
      () async {
    final a = await library.createFolder('A'),
        b = await library.createFolder('B');
    final first = await seed(a, 'pixiv1'), second = await seed(a, 'pixiv2');
    final batch = library.createBatch([first, second], b.id, move: true);
    var stop = false;
    await library.runBatch(batch,
        shouldStop: () => stop,
        onProgress: (_, __, ___, ____, _____) {
          stop = true;
        });
    final parent = rows().singleWhere((row) => row['id'] == batch);
    final data = jsonDecode(parent['payload'] as String) as Map;
    final firstItem = (data['items'] as List).first as Map;
    final childId = firstItem['operation'];
    // Reproduce kill after durable child completion but before parent write.
    firstItem['status'] = 'pending';
    journal(batch, 'batch', data, stage: 'pending');
    legacyHistory(130);
    final before = rows();
    expect((await library.maintain()).deferredReason, 'pending-operation');
    expect(rows(), before);
    expect(
        jsonDecode(rows().singleWhere((r) => r['id'] == childId)['payload']
            as String)['row'],
        isNotNull);
    expect(File(first.path).existsSync(), isFalse);
    await PixivLibrary(library.root).resume(batch);
    expect(library.pending(), isEmpty);
    expect(library.records(b).length, 2);
    expect(library.records(a), isEmpty);
    expect(rows().length, 100);
    for (final row in rows()) {
      expectReceipt(row);
    }
  });

  test('running batch defers maintenance across async file work', () async {
    final a = await library.createFolder('A'),
        b = await library.createFolder('B');
    final source = await seed(a, 'pixiv1');
    final second = await seed(a, 'pixiv2');
    Future<PixivMaintenanceResult>? attempt;
    final observed = PixivLibrary(library.root, afterStage: (_, stage) {
      if (stage == 'prepared') attempt ??= library.maintain();
    });
    final batch = observed.createBatch([source, second], b.id, move: true);
    await observed.runBatch(batch);
    expect((await attempt!).deferredReason, 'active-writer');
    expect(library.records(b).length, 2);
  });

  test('trash payload survives cleanup and restores stable folder and work',
      () async {
    final a = await library.createFolder('Trash');
    await seed(a, 'pixiv1');
    await library.removeFolder(a.id, keepWorks: false, useTrash: true);
    final trash = library.trashedFolders().single;
    legacyHistory(120);
    await library.maintain();
    expect(library.trashedFolders().single, trash);
    expect(rows().where((r) => r['stage'] == 'complete').length, 100);
    await library.restoreFolder(trash['id'] as String);
    expect(library.folder(a.id).libraryId, a.libraryId);
    expect(File(library.find(a.id, 'pixiv1')!.path).readAsStringSync(),
        'bytes:pixiv1');
  });

  for (final invalid in [
    'unknown',
    'json',
    'batch',
    'error',
    'future-summary',
    'invalid-summary'
  ]) {
    test('protects $invalid history without partial cleanup', () async {
      journal('valid', 'transfer', legacyTransfer('pixiv1'));
      switch (invalid) {
        case 'unknown':
          journal('bad', 'future-operation', {'folderId': 'x'});
        case 'json':
          journal('bad', 'transfer', '{broken');
        case 'batch':
          journal('bad', 'batch', {
            'target': 'root',
            'move': true,
            'items': [
              {'status': 'success', 'operation': 'missing'}
            ]
          });
        case 'error':
          journal('bad', 'transfer', legacyTransfer('pixiv2'),
              error: 'failure');
        case 'future-summary':
          journal('bad', 'create', {'summaryVersion': 2, 'folderId': 'x'});
        case 'invalid-summary':
          journal('bad', 'batch', {
            'summaryVersion': 1,
            'compactedAtMs': 1,
            'targetFolder': 'root',
            'move': true,
            'total': 2,
            'succeeded': 0,
            'skipped': 0,
          });
      }
      final before = rows();
      expect((await library.maintain()).deferredReason, isNotNull);
      expect(rows(), before);
    });
  }

  test('leases, download queue and root migration each defer all maintenance',
      () async {
    journal('legacy', 'transfer', legacyTransfer('pixiv1'));
    final before = rows();
    final lease = library.acquireLease('root');
    try {
      expect((await library.maintain()).deferredReason, 'active-writer');
    } finally {
      PixivLibrary.releaseLease(lease);
    }
    PixivLibrary.hasPendingDownloads = (_) => true;
    expect((await library.maintain()).deferredReason, 'download-queue');
    PixivLibrary.hasPendingDownloads = null;
    PixivLibrary.rootWriteBlocked = (_) => true;
    expect((await library.maintain()).deferredReason, 'root-migration');
    PixivLibrary.rootWriteBlocked = null;
    expect(rows(), before);
    expect((await library.maintain()).compacted, 1);
  });

  test(
      'SQLite contention defers and does not turn successful action into failure',
      () async {
    journal('legacy', 'transfer', legacyTransfer('pixiv1'));
    final before = rows();
    final lock = sqlite3.open(library.dbPath);
    try {
      lock.execute('BEGIN IMMEDIATE');
      expect((await library.maintain()).error, isNotNull);
      expect(await library.exclusive(() async => 'success'), 'success');
    } finally {
      lock.execute('ROLLBACK');
      lock.dispose();
    }
    expect(rows(), before);
    expect((await library.maintain()).compacted, 1);
  });

  test('maintenance transaction failure rolls back earlier compactions',
      () async {
    journal('first', 'transfer', legacyTransfer('pixiv1'));
    journal('second', 'transfer', legacyTransfer('pixiv2'));
    final db = sqlite3.open(library.dbPath);
    db.execute(
        "CREATE TRIGGER reject_cleanup BEFORE UPDATE ON pixiv_operations WHEN OLD.id='first' BEGIN SELECT RAISE(ABORT,'simulated write failure'); END");
    final before = rows();
    final failed = await library.maintain();
    expect(failed.error, contains('simulated write failure'));
    expect(failed.compacted, 0);
    expect(rows(), before);
    db.execute('DROP TRIGGER reject_cleanup');
    db.dispose();
    expect((await library.maintain()).compacted, 2);
  });

  test('small DB avoids VACUUM, big DB only compacts, retry obeys cooldown',
      () async {
    journal('small', 'transfer', legacyTransfer('pixiv0', size: 1));
    expect((await library.maintain()).vacuumed, isFalse);
    // Free a >16 MiB synthetic row: physical shrinking must remain bounded.
    final db = sqlite3.open(library.dbPath);
    db.execute('INSERT INTO download(id,json) VALUES(?,?)',
        ['fixture', 'x' * (17 * 1024 * 1024)]);
    db.execute("DELETE FROM download WHERE id='fixture'");
    journal('big', 'transfer', legacyTransfer('pixiv1'));
    final big = await library.maintain();
    expect(big.compacted, 1);
    expect(big.vacuumed, isFalse);
    db.execute(
        'VACUUM'); // Isolated fixture setup, outside automatic maintenance.
    db.dispose();
    journal('eligible', 'transfer', legacyTransfer('pixiv2', size: 300000));
    expect((await library.maintain()).vacuumed, isTrue);
    journal('cooldown', 'transfer', legacyTransfer('pixiv3', size: 300000));
    final cooling = await library.maintain();
    expect(cooling.compacted, 1);
    expect(cooling.vacuumed, isFalse);
  });
}
