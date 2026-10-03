import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/local_trash_store.dart';
import 'package:picakeep/foundation/pixiv_library.dart';
import 'package:picakeep/foundation/pixiv_library_locations.dart';
import 'package:sqlite3/open.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final provider = PathProviderPlatform.instance;
  late Directory workspace;
  late PixivLibrary library;
  late PixivFolder folder;
  late String target;
  var fixture = 0;

  setUpAll(() async {
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows,
          () => DynamicLibrary.open(
              p.join(Directory.current.path, 'windows', 'sqlite3.dll')));
    }
    workspace = await Directory.systemTemp.createTemp('pk47_root_recovery_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: p.join(workspace.path, 'app'));
  });
  setUp(() async {
    for (final name in [
      'pixiv_root_move.json',
      'pixiv_library_locations.json'
    ]) {
      final file = File(p.join(App.dataPath, name));
      if (file.existsSync()) await file.delete();
    }
    library = PixivLibrary(p.join(workspace.path, 'source_${fixture++}'));
    target = p.join(workspace.path, 'target_$fixture');
    await library.initialize();
    folder = await library.createFolder('壁纸');
    await File(p.join(folder.path, 'work.png')).writeAsString('complete bytes');
    final db = PixivLibrary.openDownloads(folder.path);
    try {
      db.execute('INSERT INTO download VALUES (?,?,?,?,?,?,?)',
          ['pixiv1', '作品', '作者', 1, 'work.png', 1, '{}']);
    } finally {
      db.dispose();
    }
  });
  tearDownAll(() async {
    PixivLibrary.rootWriteBlocked = null;
    LocalTrashStore.instance.dispose();
    PathProviderPlatform.instance = provider;
    await workspace.delete(recursive: true);
  });

  for (final stage in [
    'preparing',
    'copy',
    'published',
    'cleaning',
    'cleaned',
    'rebased'
  ]) {
    test(
        'root relocation resumes after $stage without losing identity or files',
        () async {
      await expectLater(
          relocatePixivLibrary(library.root, target, afterStage: (value) {
            if (value == stage) throw StateError('interrupted');
          }),
          throwsStateError);
      expect(hasPendingPixivRootMove, isTrue);
      final existingDatabases = [library.dbPath, p.join(target, 'download.db')]
          .where((path) => File(path).existsSync());
      final beforeMaintenance = {
        for (final path in existingDatabases)
          path: File(path).readAsBytesSync(),
      };
      expect((await library.maintain()).deferredReason, 'root-migration');
      expect((await PixivLibrary(target).maintain()).deferredReason,
          'root-migration');
      for (final entry in beforeMaintenance.entries) {
        expect(File(entry.key).readAsBytesSync(), entry.value);
      }
      await resumePixivRootMove();
      final moved = PixivLibrary(target).folder(folder.id);
      expect(moved.libraryId, folder.libraryId);
      expect(File(p.join(moved.path, 'work.png')).readAsStringSync(),
          'complete bytes');
      expect(Directory(library.root).existsSync(), isFalse);
      expect(hasPendingPixivRootMove, isFalse);
      expect(resolvePixivLibraryRoot(library.root), target);
    });
  }

  test('damaged target on cleanup resume preserves the complete source',
      () async {
    await expectLater(
        relocatePixivLibrary(library.root, target, afterStage: (stage) {
          if (stage == 'cleaning') throw StateError('interrupted');
        }),
        throwsStateError);
    final damaged = File(p.join(target, folder.relativePath, 'work.png'));
    await damaged.writeAsString('partial');
    await expectLater(resumePixivRootMove(), throwsStateError);
    expect(File(p.join(folder.path, 'work.png')).readAsStringSync(),
        'complete bytes');
    expect(File(library.dbPath).existsSync(), isTrue);
    expect(hasPendingPixivRootMove, isTrue);
    await damaged.writeAsString('complete bytes');
    await resumePixivRootMove();
    expect(hasPendingPixivRootMove, isFalse);
  });

  test('migration blocks mutations and download leases on both roots',
      () async {
    await expectLater(
        relocatePixivLibrary(library.root, target, afterStage: (stage) {
          if (stage == 'preparing') throw StateError('interrupted');
        }),
        throwsStateError);
    await expectLater(library.createFolder('New'), throwsStateError);
    await expectLater(library.setDefault(folder.id), throwsStateError);
    await expectLater(library.reorder([folder.id, 'root']), throwsStateError);
    await expectLater(PixivLibrary(target).initialize(), throwsStateError);
    expect(() => library.acquireLease(folder.id), throwsStateError);
    expect(() => PixivLibrary(target).acquireLease('root'), throwsStateError);
    // Browsing and unrelated libraries remain available.
    expect(library.folders().length, 2);
    await PixivLibrary(p.join(workspace.path, 'unrelated')).initialize();
    await resumePixivRootMove();
    final lease = PixivLibrary(target).acquireLease(folder.id);
    PixivLibrary.releaseLease(lease);
  });

  test(
      'recovery after journal rebasing does not revalidate against old DB bytes',
      () async {
    await library.rename(folder.id, '新名字');
    // Completed rename receipts no longer retain paths; a transfer receipt
    // still carries sourceRoot, so rebasing must continue to update DB bytes.
    await library.transfer(library.find(folder.id, 'pixiv1')!, 'root',
        move: false);
    final before = await PixivLibrary.snapshotOf(library.root);
    await expectLater(
        relocatePixivLibrary(library.root, target, afterStage: (stage) {
          if (stage == 'rebased') throw StateError('interrupted');
        }),
        throwsStateError);
    expect(await PixivLibrary.matchesSnapshot(target, before), isFalse,
        reason: 'transfer receipt sourceRoot was rebased inside download.db');
    await resumePixivRootMove();
    expect(PixivLibrary(target).folder(folder.id).name, '新名字');
    expect(hasPendingPixivRootMove, isFalse);
  });

  test('invalid saved stage fails without removing the source', () async {
    await expectLater(
        relocatePixivLibrary(library.root, target, afterStage: (stage) {
          if (stage == 'copy') throw StateError('interrupted');
        }),
        throwsStateError);
    final journal = File(p.join(App.dataPath, 'pixiv_root_move.json'));
    final data = jsonDecode(journal.readAsStringSync()) as Map;
    data['stage'] = 'unknown';
    journal.writeAsStringSync(jsonEncode(data));
    await expectLater(resumePixivRootMove(), throwsStateError);
    expect(File(p.join(folder.path, 'work.png')).readAsStringSync(),
        'complete bytes');
  });
  test(
      'new source content while interrupted stops cleanup before removing originals',
      () async {
    await expectLater(
        relocatePixivLibrary(library.root, target, afterStage: (stage) {
          if (stage == 'cleaning') throw StateError('interrupted');
        }),
        throwsStateError);
    final added = File(p.join(library.root, 'new_note.txt'));
    await added.writeAsString('not copied');
    await expectLater(resumePixivRootMove(), throwsStateError);
    expect(added.readAsStringSync(), 'not copied');
    expect(File(library.dbPath).existsSync(), isTrue);
    expect(File(p.join(folder.path, 'work.png')).existsSync(), isTrue);
  });
  test('root relocation preserves empty directories too', () async {
    await Directory(p.join(library.root, 'empty', 'nested'))
        .create(recursive: true);
    await relocatePixivLibrary(library.root, target);
    expect(Directory(p.join(target, 'empty', 'nested')).existsSync(), isTrue);
  });

  test('legacy completion and trash migrate, compact and restore together',
      () async {
    await library.removeFolder(folder.id, keepWorks: false, useTrash: true);
    final trashId = library.trashedFolders().single['id'] as String;
    final db = PixivLibrary.openDownloads(library.root);
    try {
      db.execute('INSERT INTO pixiv_operations VALUES(?,?,?,?,NULL)', [
        'legacy-rename',
        'rename',
        jsonEncode({
          'folderId': folder.id,
          'name': folder.name,
          'from': p.join(library.root, 'old'),
          'to': folder.path,
        }),
        'complete',
      ]);
    } finally {
      db.dispose();
    }
    await relocatePixivLibrary(library.root, target);
    final relocated = PixivLibrary(target);
    await relocated.initialize();
    expect(relocated.trashedFolders().single['id'], trashId);
    final updated = PixivLibrary.openDownloads(target);
    try {
      final payload = jsonDecode(updated
          .select(
              "SELECT payload FROM pixiv_operations WHERE id='legacy-rename'")
          .single['payload'] as String) as Map;
      expect(payload['summaryVersion'], 1);
      expect(payload.containsKey('from'), isFalse);
    } finally {
      updated.dispose();
    }
    await relocated.restoreFolder(trashId);
    expect(relocated.folder(folder.id).libraryId, folder.libraryId);
    expect(File(relocated.find(folder.id, 'pixiv1')!.path).readAsStringSync(),
        'complete bytes');
  });
}
