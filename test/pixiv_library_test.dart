import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/pixiv_library.dart';
import 'package:sqlite3/open.dart';

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
    workspace = await Directory.systemTemp.createTemp('pk46_library_');
    library = PixivLibrary(p.join(workspace.path, 'library'));
    await library.initialize();
  });
  tearDown(() async {
    await workspace.delete(recursive: true);
  });

  Future<PixivRecord> seed(PixivFolder folder,
      {String id = 'pixiv1',
      String name = '作品_1.png',
      String data = 'original',
      bool directory = false}) async {
    final path = p.join(folder.path, name);
    if (directory) {
      await Directory(path).create();
      await File(p.join(path, '1.png')).writeAsString(data);
    } else {
      await File(path).writeAsString(data);
    }
    final db = PixivLibrary.openDownloads(folder.path);
    try {
      db.execute('INSERT INTO download VALUES(?,?,?,?,?,?,?)', [
        id,
        '作品',
        '作者',
        1,
        name,
        1.0,
        jsonEncode({'sourceKey': 'pixiv', 'id': id})
      ]);
    } finally {
      db.dispose();
    }
    return library.find(folder.id, id)!;
  }

  test(
      'folder name is the physical name; stable IDs, default and sorting survive reopen',
      () async {
    final a = await library.createFolder('壁纸 🌅');
    final b = await library.createFolder('風景');
    await library.setDefault(a.id);
    await library.reorder([b.id, 'root', a.id]);
    await library.rename(a.id, '壁纸 新');
    final reopened = PixivLibrary(library.root);
    expect(reopened.folders().map((f) => f.id), [b.id, 'root', a.id]);
    expect(reopened.defaultFolder.id, a.id);
    expect(Directory(reopened.folder(a.id).path).existsSync(), isTrue);
    expect(reopened.folder(a.id).libraryId, a.libraryId);
  });
  test('existing paths and traversal are rejected without overwriting',
      () async {
    await library.createFolder('A');
    await expectLater(library.createFolder('A'), throwsStateError);
    for (final name in ['../escape', 'a/b', '.', 'download.db', 'CON', '']) {
      await expectLater(library.createFolder(name), throwsArgumentError);
    }
    expect(library.folders().length, 2);
  });
  test(
      'copy retains original bytes and independent rows; repeated target is idempotent',
      () async {
    final a = await library.createFolder('A'),
        b = await library.createFolder('B');
    final source = await seed(a);
    await library.transfer(source, b.id, move: false);
    expect(File(source.path).readAsStringSync(), 'original');
    expect(library.copiesOf(source.id).length, 2);
    final repeated = await library.transfer(source, b.id, move: true);
    expect(repeated.skipped, isTrue);
    expect(File(source.path).existsSync(), isTrue,
        reason: 'a new move to an already existing target must not delete A');
  });
  test('move publishes target bytes and record before removing source',
      () async {
    final a = await library.createFolder('A'),
        b = await library.createFolder('B');
    final source = await seed(a);
    final observed = PixivLibrary(library.root, afterStage: (_, stage) {
      if (stage == 'committed') {
        expect(File(source.path).existsSync(), isTrue);
        expect(library.find(b.id, source.id), isNotNull);
      }
    });
    await observed.transfer(source, b.id, move: true);
    expect(library.find(a.id, source.id), isNull);
    expect(File(source.path).existsSync(), isFalse);
    expect(File(library.find(b.id, source.id)!.path).readAsStringSync(),
        'original');
  });
  for (final stage in ['prepared', 'published', 'committed', 'cleaning']) {
    test('move recovers after interruption at $stage', () async {
      final a = await library.createFolder('A'),
          b = await library.createFolder('B');
      final source = await seed(a, directory: true, name: 'old_work');
      final interrupted = PixivLibrary(library.root, afterStage: (_, s) {
        if (s == stage) throw StateError('simulated shutdown');
      });
      await expectLater(
          interrupted.transfer(source, b.id, move: true), throwsStateError);
      final pending = library.pending().single;
      await PixivLibrary(library.root).resume(pending['id'] as String);
      expect(library.pending(), isEmpty);
      expect(library.find(a.id, source.id), isNull);
      expect(
          File(p.join(library.find(b.id, source.id)!.path, '1.png'))
              .readAsStringSync(),
          'original');
    });
  }
  test('same work with different target content is never overwritten',
      () async {
    final a = await library.createFolder('A'),
        b = await library.createFolder('B');
    final source = await seed(a);
    final other = await seed(b, data: 'different');
    await expectLater(
        library.transfer(source, b.id, move: true), throwsStateError);
    expect(File(other.path).readAsStringSync(), 'different');
    expect(library.copiesOf(source.id).length, 2);
  });
  test(
      'new source files stop cleanup instead of deleting untransferred content',
      () async {
    final a = await library.createFolder('A'),
        b = await library.createFolder('B');
    final source = await seed(a, directory: true, name: 'old_work');
    final changed = PixivLibrary(library.root, afterStage: (_, stage) {
      if (stage == 'committed') {
        File(p.join(source.path, 'new.png')).writeAsStringSync('new');
      }
    });
    await expectLater(
        changed.transfer(source, b.id, move: true), throwsStateError);
    expect(File(p.join(source.path, 'new.png')).readAsStringSync(), 'new');
    expect(File(p.join(source.path, '1.png')).existsSync(), isTrue);
    expect(library.find(a.id, source.id), isNotNull);
  });
  test('keep contents moves to main root then removes empty folder', () async {
    final a = await library.createFolder('A');
    await seed(a);
    await library.setDefault(a.id);
    await library.removeFolder(a.id, keepWorks: true, useTrash: true);
    expect(library.find('root', 'pixiv1'), isNotNull);
    expect(library.folders().length, 1);
    expect(library.defaultFolder.isRoot, isTrue);
    expect(Directory(a.path).existsSync(), isFalse);
  });
  test('unknown files prevent removal of folder after works returned',
      () async {
    final a = await library.createFolder('A');
    await seed(a);
    await File(p.join(a.path, 'notes.txt')).writeAsString('keep me');
    await expectLater(
        library.removeFolder(a.id, keepWorks: true, useTrash: true),
        throwsStateError);
    expect(File(p.join(a.path, 'notes.txt')).readAsStringSync(), 'keep me');
    expect(library.folder(a.id).id, a.id);
  });
  test('whole folder trash and restore retain DB and folder ID', () async {
    final a = await library.createFolder('A');
    await seed(a);
    await library.removeFolder(a.id, keepWorks: false, useTrash: true);
    expect(Directory(a.path).existsSync(), isFalse);
    final trashed = library.trashedFolders().single;
    await library.restoreFolder(trashed['id'] as String);
    expect(library.folder(a.id).libraryId, a.libraryId);
    expect(File(library.find(a.id, 'pixiv1')!.path).readAsStringSync(),
        'original');
  });
  test('root deletion and leased folder mutation are refused', () async {
    await expectLater(
        library.removeFolder('root', keepWorks: false, useTrash: false),
        throwsStateError);
    final a = await library.createFolder('A');
    final lease = library.acquireLease(a.id);
    try {
      await expectLater(library.rename(a.id, 'B'), throwsStateError);
    } finally {
      PixivLibrary.releaseLease(lease);
    }
    expect(Directory(a.path).existsSync(), isTrue);
  });
  test('corrupt database is preserved on open failure', () async {
    final root = await Directory(p.join(workspace.path, 'broken')).create();
    final db = File(p.join(root.path, 'download.db'));
    await db.writeAsString('valuable broken data');
    expect(() => PixivLibrary.openDownloads(root.path), throwsA(anything));
    expect(db.readAsStringSync(), 'valuable broken data');
  });
  test(
      'batch persists unstarted work and resumes without repeating completed items',
      () async {
    final a = await library.createFolder('batch A');
    final b = await library.createFolder('batch B');
    final first = await seed(a, id: 'pixiv101', name: 'first.png');
    final second = await seed(a, id: 'pixiv102', name: 'second.png');
    final batch = library.createBatch([first, second], b.id, move: false);
    var stop = false;
    await library.runBatch(batch,
        shouldStop: () => stop,
        onProgress: (_, __, ___, ____, _____) {
          stop = true;
        });
    expect(library.find(b.id, first.id), isNotNull);
    expect(library.find(b.id, second.id), isNull);
    await PixivLibrary(library.root).resume(batch);
    expect(library.find(b.id, second.id), isNotNull);
    expect(library.records(b).length, 2);
    expect(library.records(a).length, 2);
    expect(library.pending(), isEmpty);
  });
  test(
      'folder creation recovers after persisted intent without losing its identity',
      () async {
    final interrupted = PixivLibrary(library.root, afterStage: (_, stage) {
      if (stage == 'prepared') throw StateError('shutdown');
    });
    await expectLater(interrupted.createFolder('Recover'), throwsStateError);
    final operation = library.pending().single;
    await library.resume(operation['id'] as String);
    expect(library.folders().any((f) => f.name == 'Recover'), isTrue);
    expect(library.pending(), isEmpty);
  });
  test('whole-folder trash recovers after quarantine commit', () async {
    final a = await library.createFolder('Trash');
    await seed(a);
    final interrupted = PixivLibrary(library.root, afterStage: (_, stage) {
      if (stage == 'quarantined') throw StateError('shutdown');
    });
    await expectLater(
        interrupted.removeFolder(a.id, keepWorks: false, useTrash: true),
        throwsStateError);
    await library.resume(library.pending().single['id'] as String);
    expect(library.trashedFolders(), hasLength(1));
    await library
        .restoreFolder(library.trashedFolders().single['id'] as String);
    expect(library.find(a.id, 'pixiv1'), isNotNull);
  });
  test(
      'recreating a deleted folder name never overwrites its recoverable old identity',
      () async {
    final a = await library.createFolder('Same');
    await seed(a);
    await library.removeFolder(a.id, keepWorks: false, useTrash: true);
    final b = await library.createFolder('Same');
    expect(b.id, isNot(a.id));
    await expectLater(
        library.restoreFolder(library.trashedFolders().single['id'] as String),
        throwsStateError);
    expect(library.folder(b.id).id, b.id);
    expect(library.trashedFolders(), hasLength(1));
  });

  test('copied child database with another folder identity is rejected', () async {
    final a = await library.createFolder('A');
    final b = await library.createFolder('B');
    await File(p.join(a.path, 'download.db')).copy(p.join(b.path, 'download.db'));
    expect(() => library.folder(b.id), throwsStateError);
    expect(library.folder(a.id).id, a.id);
  });
  test('return-to-root cleanup resumes after metadata stage interruption', () async {
    final a = await library.createFolder('Return'); await seed(a);
    final interrupted = PixivLibrary(library.root, afterStage: (_, stage) {
      if (stage == 'metadata') throw StateError('shutdown');
    });
    await expectLater(interrupted.removeFolder(a.id, keepWorks: true, useTrash: true), throwsStateError);
    final operation = library.pending().single;
    await library.resume(operation['id'] as String);
    expect(library.find('root', 'pixiv1'), isNotNull);
    expect(Directory(a.path).existsSync(), isFalse);
    expect(library.pending(), isEmpty);
  });
  test('rename recovers from intent and preserves stable identity', () async {
    final a = await library.createFolder('Old'); await seed(a);
    final interrupted = PixivLibrary(library.root, afterStage: (_, stage) {
      if (stage == 'prepared') throw StateError('shutdown');
    });
    await expectLater(interrupted.rename(a.id, 'New'), throwsStateError);
    await library.resume(library.pending().single['id'] as String);
    expect(library.folder(a.id).name, 'New');
    expect(File(library.find(a.id, 'pixiv1')!.path).readAsStringSync(), 'original');
  });

  test('both invalid policies default to ask independently', () {
    expect(normalizePixivTransferPolicy('delete'), 'ask');
    expect(normalizePixivFolderDeletePolicy('copy'), 'ask');
    expect(normalizePixivTransferPolicy('move'), 'move');
    expect(normalizePixivFolderDeletePolicy('keep'), 'keep');
  });
}
