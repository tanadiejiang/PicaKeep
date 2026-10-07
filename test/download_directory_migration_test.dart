/// 下载目录迁移的纯 Dart 测试。
///
/// 只依赖 `package:test` + `dart:io`：在真实临时目录上跑真实的文件搬移，
/// 不 import Flutter，可以用 `dart test` 直接运行。
///
/// 迁移语义是「先复制数据库、切到新目录，再一本本搬漫画」，且有两种搬法：
/// - 默认：先全部复制、**一个源都不删**，确认无失败后才清理旧目录；
/// - 存储紧张：搬一本删一本。
///
/// 因此测试重点是三件事：**默认模式中断时源必须完整**、进度可观察、
/// 以及中断留下的半成品不会被误判成"已搬好"。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:picakeep/foundation/download_directory_migration.dart';
import 'package:test/test.dart';

void main() {
  late Directory workspace;
  late String sourcePath;
  late String targetPath;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_migrate_');
    sourcePath = p.join(workspace.path, 'old');
    targetPath = p.join(workspace.path, 'new');
    await Directory(sourcePath).create(recursive: true);
  });

  tearDown(() async {
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  });

  Future<void> writeFile(String root, String relative, String content) async {
    final file = File(p.join(root, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  Future<List<String>> relativeFiles(String root) async {
    final directory = Directory(root);
    if (!await directory.exists()) {
      return const <String>[];
    }
    final result = <String>[];
    await for (final entity
        in directory.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        result.add(p.relative(entity.path, from: root).replaceAll('\\', '/'));
      }
    }
    result.sort();
    return result;
  }

  Future<String> readFile(String root, String relative) =>
      File(p.join(root, relative)).readAsString();

  /// [root] 里所有 `download.db.bak-*` 备份文件（43 号护栏用）。
  List<File> backupsIn(String root) => Directory(root)
      .listSync()
      .whereType<File>()
      .where(
        (file) => p.basename(file.path).startsWith('download.db.bak-'),
      )
      .toList();

  Future<void> seedComics(int count) async {
    for (var i = 0; i < count; i++) {
      await writeFile(sourcePath, 'comic-$i/1.jpg', 'IMG$i');
    }
  }

  group('seedDownloadDatabase', () {
    test('把数据库复制到新目录，且源库保留', () async {
      await writeFile(sourcePath, 'download.db', 'DB');

      final seeded = await seedDownloadDatabase(
        from: sourcePath,
        to: targetPath,
      );

      expect(seeded, isTrue);
      expect(await readFile(targetPath, 'download.db'), 'DB');
      // 关键：源库必须还在，这是"搬失败也不丢记录"的兜底。
      expect(await readFile(sourcePath, 'download.db'), 'DB');
    });

    test('源目录没有数据库时返回 false 且不建目标库', () async {
      final seeded = await seedDownloadDatabase(
        from: sourcePath,
        to: targetPath,
      );
      expect(seeded, isFalse);
      expect(await File(p.join(targetPath, 'download.db')).exists(), isFalse);
    });

    test('源与目标相同时不做任何事', () async {
      await writeFile(sourcePath, 'download.db', 'DB');
      final seeded = await seedDownloadDatabase(
        from: sourcePath,
        to: sourcePath,
      );
      expect(seeded, isFalse);
      expect(await readFile(sourcePath, 'download.db'), 'DB');
    });

    test('目标目录不存在时会被创建', () async {
      await writeFile(sourcePath, 'download.db', 'DB');
      await seedDownloadDatabase(from: sourcePath, to: targetPath);
      expect(await Directory(targetPath).exists(), isTrue);
    });

    test('目标已有 download.db → 覆盖前先改名备份（43 号护栏）', () async {
      // 此前 `File.copy` 是无条件覆盖：目标原有的记录会被**整个抹掉**，
      // 而它的漫画目录还在 ⇒ 内容变孤儿（41 号那个"读不了"故障的镜像版本），
      // 且事前事后都没有任何提示。
      await writeFile(sourcePath, 'download.db', 'SOURCE');
      await writeFile(targetPath, 'download.db', 'TARGET-原内容');
      await writeFile(targetPath, '目标自己的漫画/1.jpg', 'KEEP');

      final seeded = await seedDownloadDatabase(
        from: sourcePath,
        to: targetPath,
      );

      expect(seeded, isTrue);
      // 新库 = 源内容（覆盖照旧发生，但已经留了后路）。
      expect(await readFile(targetPath, 'download.db'), 'SOURCE');
      // 关键：目标原有 db 必须被**改名保留**，而不是丢掉。
      final backups = backupsIn(targetPath);
      expect(backups, hasLength(1), reason: '目标原有 db 必须被改名备份');
      expect(backups.single.readAsStringSync(), 'TARGET-原内容');
      // 它的漫画目录一个都没动（本轮只护栏 db，不碰内容）。
      expect(
        await File(p.join(targetPath, '目标自己的漫画', '1.jpg')).exists(),
        isTrue,
      );
    });

    test('目标没有 db 时不产生备份文件', () async {
      await writeFile(sourcePath, 'download.db', 'SOURCE');
      await seedDownloadDatabase(from: sourcePath, to: targetPath);
      expect(backupsIn(targetPath), isEmpty);
    });

    test('重复执行不会覆盖已有备份（后缀递增）', () async {
      await writeFile(sourcePath, 'download.db', 'SOURCE');
      await writeFile(targetPath, 'download.db', 'T1');
      await seedDownloadDatabase(from: sourcePath, to: targetPath);
      // 再放一份目标 db（模拟用户又往目标目录放了个库），再跑一次。
      await writeFile(targetPath, 'download.db', 'T2');
      await seedDownloadDatabase(from: sourcePath, to: targetPath);

      final backups = backupsIn(targetPath);
      expect(
        backups.length,
        greaterThanOrEqualTo(2),
        reason: '两次备份都要留住 —— 备份的唯一价值就是"还能找回来"',
      );
      final contents = backups.map((file) => file.readAsStringSync()).toSet();
      expect(contents, containsAll(<String>['T1', 'T2']));
    });
  });

  group('migrateDownloadEntries 搬运', () {
    test('漫画目录被递归搬走，内容保持不变', () async {
      await writeFile(sourcePath, 'comic-1/1.jpg', 'IMG1');
      await writeFile(sourcePath, 'comic-2/chapter/1.jpg', 'IMG2');

      final result = await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
      );

      expect(result.movedEntries, 2, reason: result.failures.join('\n'));
      expect(result.skippedEntries, 0);
      expect(result.failures, isEmpty);
      expect(result.stopped, isFalse);
      expect(await relativeFiles(targetPath), [
        'comic-1/1.jpg',
        'comic-2/chapter/1.jpg',
      ]);
      expect(await readFile(targetPath, 'comic-2/chapter/1.jpg'), 'IMG2');
    });

    test('不搬 download.db（它由 seedDownloadDatabase 单独负责）', () async {
      await writeFile(sourcePath, 'download.db', 'DB');
      await writeFile(sourcePath, 'comic-1/1.jpg', 'IMG1');

      final result = await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
      );

      expect(result.movedEntries, 1);
      expect(await File(p.join(targetPath, 'download.db')).exists(), isFalse);
      // 数据库留在原处，没有被这次搬动波及。
      expect(await readFile(sourcePath, 'download.db'), 'DB');
    });

    test('源目录不存在时安静返回 0', () async {
      await Directory(sourcePath).delete(recursive: true);
      final result = await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
      );
      expect(result.movedEntries, 0);
      expect(result.failures, isEmpty);
    });
  });

  group('默认模式：全部复制成功后才清理旧目录', () {
    test('搬完一本不删一本，全部成功后才清理', () async {
      await seedComics(3);

      final phases = <DownloadMigrationPhase>[];
      final result = await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
        onProgress: (progress) => phases.add(progress.phase),
      );

      expect(result.movedEntries, 3);
      expect(result.failures, isEmpty);
      // 先复制 3 个，再清理 3 个。
      expect(phases, [
        DownloadMigrationPhase.copying,
        DownloadMigrationPhase.copying,
        DownloadMigrationPhase.copying,
        DownloadMigrationPhase.cleaningUp,
        DownloadMigrationPhase.cleaningUp,
        DownloadMigrationPhase.cleaningUp,
      ]);
      expect(await relativeFiles(sourcePath), isEmpty);
      expect((await relativeFiles(targetPath)).length, 3);
    });

    test('复制阶段被中断时，旧目录一个条目都不删', () async {
      await seedComics(4);

      var checks = 0;
      final result = await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
        // 第二个条目开始前喊停：只复制了 1 个。
        shouldStop: () => ++checks > 1,
      );

      expect(result.stopped, isTrue);
      expect(result.movedEntries, 1);
      // 这是默认模式存在的意义：源目录必须保持完整。
      expect((await relativeFiles(sourcePath)).length, 4);
      expect((await relativeFiles(targetPath)).length, 1);
      expect(await hasPendingDownloadEntries(sourcePath), isTrue);
    });

    test('中断后再跑一次能接着搬完，且不重复计数', () async {
      await seedComics(4);

      var checks = 0;
      await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
        shouldStop: () => ++checks > 1,
      );

      final second = await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
      );

      expect(second.stopped, isFalse);
      expect(second.movedEntries, 3);
      expect(second.failures, isEmpty);
      expect(await hasPendingDownloadEntries(sourcePath), isFalse);
      expect((await relativeFiles(targetPath)).length, 4);
      expect(await relativeFiles(sourcePath), isEmpty);
    });
  });

  group('存储紧张模式：搬一本删一本', () {
    test('被中断时，已经搬走的那几本已从旧目录消失', () async {
      await seedComics(4);

      var checks = 0;
      final result = await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
        deleteSourceAsWeGo: true,
        shouldStop: () => ++checks > 1,
      );

      expect(result.stopped, isTrue);
      expect(result.movedEntries, 1);
      // 与默认模式相反：搬走的立刻从源里消失，峰值占用最小。
      expect((await relativeFiles(sourcePath)).length, 3);
      expect((await relativeFiles(targetPath)).length, 1);
    });

    test('进度阶段始终是 moving，进度条跑满', () async {
      await seedComics(2);

      final events = <DownloadMigrationProgress>[];
      await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
        deleteSourceAsWeGo: true,
        onProgress: events.add,
      );

      expect(
        events.every((e) => e.phase == DownloadMigrationPhase.moving),
        isTrue,
      );
      expect(events.last.fraction, 1.0);
      expect(await relativeFiles(sourcePath), isEmpty);
    });

    test('中断后继续也能搬完', () async {
      await seedComics(3);

      var checks = 0;
      await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
        deleteSourceAsWeGo: true,
        shouldStop: () => ++checks > 1,
      );
      final second = await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
        deleteSourceAsWeGo: true,
      );

      expect(second.failures, isEmpty);
      expect((await relativeFiles(targetPath)).length, 3);
      expect(await hasPendingDownloadEntries(sourcePath), isFalse);
    });
  });

  group('中断残留的暂存条目不会被误判成已搬好', () {
    test('目标只有半成品时不跳过，而是重新复制一份完整的', () async {
      await writeFile(sourcePath, 'comic-1/1.jpg', 'PAGE1');
      await writeFile(sourcePath, 'comic-1/2.jpg', 'PAGE2');
      // 模拟上次复制到一半被杀：暂存目录里只有一页。
      await writeFile(
        targetPath,
        'comic-1$kDownloadMigrationPartialSuffix/1.jpg',
        'PAGE1',
      );

      final result = await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
      );

      expect(result.skippedEntries, 0);
      expect(result.movedEntries, 1);
      // 目标拿到的是完整副本，而不是那份半成品。
      expect(await relativeFiles(targetPath), [
        'comic-1/1.jpg',
        'comic-1/2.jpg',
      ]);
      // 半成品被清掉，不留垃圾。
      expect(
        (await relativeFiles(targetPath))
            .any((f) => f.contains(kDownloadMigrationPartialSuffix)),
        isFalse,
      );
      // 完整副本就位后源才被清理。
      expect(await relativeFiles(sourcePath), isEmpty);
    });

    test('复制走的是暂存名再改正式名', () async {
      await writeFile(sourcePath, 'comic-1/1.jpg', 'PAGE1');

      await migrateDownloadEntries(from: sourcePath, to: targetPath);

      final names = (await Directory(targetPath)
              .list()
              .map((e) => p.basename(e.path))
              .toList())
          .toList();
      expect(names, ['comic-1']);
    });
  });

  group('进度模型', () {
    test('按条目回调，最后一条到 100%', () async {
      await seedComics(3);

      final events = <DownloadMigrationProgress>[];
      await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
        onProgress: events.add,
      );

      // 3 个复制 + 3 个清理。
      expect(events.length, 6);
      expect(events.map((e) => e.completed).toList(), [1, 2, 3, 1, 2, 3]);
      expect(events.map((e) => e.total).toList(), [3, 3, 3, 3, 3, 3]);
      expect(events.last.fraction, 1.0);
      expect(events.every((e) => e.currentEntry.isNotEmpty), isTrue);
    });

    test('整体进度单调不减，不会在阶段切换时倒退', () async {
      await seedComics(3);

      final fractions = <double>[];
      await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
        onProgress: (progress) => fractions.add(progress.fraction),
      );

      for (var i = 1; i < fractions.length; i++) {
        expect(
          fractions[i],
          greaterThanOrEqualTo(fractions[i - 1]),
          reason: '进度在第 $i 步倒退了：$fractions',
        );
      }
      expect(fractions.last, 1.0);
    });

    test('阶段到比例的映射：复制占前 90%，清理占后 10%', () {
      const copying = DownloadMigrationProgress(
        completed: 1,
        total: 2,
        currentEntry: 'a',
        phase: DownloadMigrationPhase.copying,
      );
      const cleaning = DownloadMigrationProgress(
        completed: 1,
        total: 2,
        currentEntry: 'a',
        phase: DownloadMigrationPhase.cleaningUp,
      );
      const moving = DownloadMigrationProgress(
        completed: 1,
        total: 4,
        currentEntry: 'a',
      );

      expect(copying.fraction, closeTo(0.45, 1e-9));
      expect(cleaning.fraction, closeTo(0.95, 1e-9));
      expect(moving.fraction, closeTo(0.25, 1e-9));
      expect(moving.phase, DownloadMigrationPhase.moving);
    });

    test('没有条目时视为已完成', () {
      const empty = DownloadMigrationProgress(
        completed: 0,
        total: 0,
        currentEntry: '',
      );
      expect(empty.fraction, 1.0);
    });

    test('没有条目时不回调进度', () async {
      final events = <DownloadMigrationProgress>[];
      await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
        onProgress: events.add,
      );
      expect(events, isEmpty);
    });
  });

  group('目标已存在同名条目', () {
    test('默认模式下跳过并清理源，且不覆盖目标已有内容', () async {
      await writeFile(sourcePath, 'comic-1/1.jpg', 'SOURCE');
      await writeFile(targetPath, 'comic-1/1.jpg', 'EXISTING');

      final result = await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
      );

      expect(result.skippedEntries, 1);
      expect(result.movedEntries, 0);
      expect(result.failures, isEmpty);
      expect(await readFile(targetPath, 'comic-1/1.jpg'), 'EXISTING');
      // 目标里那份就是最终副本，源里的同名目录被清理。
      expect(await relativeFiles(sourcePath), isEmpty);
    });

    test('存储紧张模式下同样跳过，并清掉源里多余的副本', () async {
      await writeFile(sourcePath, 'comic-1/1.jpg', 'SOURCE');
      await writeFile(targetPath, 'comic-1/1.jpg', 'EXISTING');

      final result = await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
        deleteSourceAsWeGo: true,
      );

      expect(result.skippedEntries, 1);
      expect(result.movedEntries, 0);
      expect(await readFile(targetPath, 'comic-1/1.jpg'), 'EXISTING');
      expect(await relativeFiles(sourcePath), isEmpty);
    });
  });

  group('拒绝危险目标', () {
    test('目标位于源目录内部 → **允许**，且不会把目标自己搬进去（真机配置）', () async {
      // 真机实证的配置（用户实际踩到的）：
      //   源   `/storage/emulated/0/1/pica`
      //   目标 `/storage/emulated/0/1/pica/picakeep/download`
      //
      // 此前这里直接抛「目标目录不能位于源目录内部」，于是"继续转移下载数据"
      // 每次必失败、续传状态**永远清不掉**（用户在真机上卡了好几天）。
      // 正确做法是允许，但遍历时跳过"通往目标的那条路径"。
      await seedComics(2);
      final nested = p.join(sourcePath, 'picakeep', 'download');
      await Directory(nested).create(recursive: true);
      await writeFile(nested, 'new-comic/1.jpg', 'NEW');

      final result = await migrateDownloadEntries(
        from: sourcePath,
        to: nested,
        deleteSourceAsWeGo: true,
      );

      expect(result.movedEntries, 2);
      expect(result.failures, isEmpty);
      // 旧内容确实搬进来了。
      expect(Directory(p.join(nested, 'comic-0')).existsSync(), isTrue);
      expect(Directory(p.join(nested, 'comic-1')).existsSync(), isTrue);
      // 目标里原有的内容一个没动。
      expect(File(p.join(nested, 'new-comic', '1.jpg')).existsSync(), isTrue);
      // **关键回归**：目标里不能出现自嵌套的一份 `picakeep/`
      // （少了那条路径过滤就会把 `picakeep/` 整个搬进 `picakeep/download/`）。
      expect(
        Directory(p.join(nested, 'picakeep')).existsSync(),
        isFalse,
        reason: '把目标目录自己当成待搬条目 = 自嵌套',
      );
      // 源目录本身也不能被删掉（目标还在它里面）。
      expect(Directory(sourcePath).existsSync(), isTrue);
      expect(Directory(nested).existsSync(), isTrue);
    });

    test('默认复制模式同样跳过目标路径（否则会自我递归复制）', () async {
      await seedComics(1);
      final nested = p.join(sourcePath, 'picakeep', 'download');
      await Directory(nested).create(recursive: true);

      final result = await migrateDownloadEntries(
        from: sourcePath,
        to: nested,
      );

      expect(result.failures, isEmpty);
      expect(Directory(p.join(nested, 'comic-0')).existsSync(), isTrue);
      expect(Directory(p.join(nested, 'picakeep')).existsSync(), isFalse);
      // 默认模式是"全部复制成功后再清理旧目录"，所以收尾阶段**同样会删源**；
      // 但源目录本身必须还在（目标在它里面，不能连它一起删）。
      expect(Directory(p.join(sourcePath, 'comic-0')).existsSync(), isFalse);
      expect(Directory(sourcePath).existsSync(), isTrue);
    });

    test('源目录位于目标内部时抛异常', () async {
      await seedComics(1);

      await expectLater(
        migrateDownloadEntries(from: sourcePath, to: workspace.path),
        throwsA(isA<DownloadMigrationException>()),
      );
      expect(await relativeFiles(sourcePath), ['comic-0/1.jpg']);
    });

    test('源或目标为空串时抛异常', () async {
      await expectLater(
        migrateDownloadEntries(from: '', to: targetPath),
        throwsA(isA<DownloadMigrationException>()),
      );
      await expectLater(
        migrateDownloadEntries(from: sourcePath, to: '  '),
        throwsA(isA<DownloadMigrationException>()),
      );
    });
  });

  group('copyDirectoryContents：只复制、绝不删源', () {
    test('复制完成后源目录必须一个条目都不少', () async {
      await writeFile(sourcePath, 'comic-1/1.jpg', 'IMG1');
      await writeFile(sourcePath, 'comic-2/1.jpg', 'IMG2');
      await writeFile(sourcePath, 'download.db', 'DB');

      final result = await copyDirectoryContents(
        from: sourcePath,
        to: targetPath,
      );

      expect(result.movedEntries, 3);
      expect(result.failures, isEmpty);
      // 关键断言：这是原应用的数据，绝不能动。
      expect(await relativeFiles(sourcePath), [
        'comic-1/1.jpg',
        'comic-2/1.jpg',
        'download.db',
      ]);
      expect(await relativeFiles(targetPath), [
        'comic-1/1.jpg',
        'comic-2/1.jpg',
        'download.db',
      ]);
    });

    test('与迁移不同：download.db 也要复制过来', () async {
      // migrateDownloadEntries 会刻意跳过 download.db（它由 seed 单独处理），
      // 但复制场景下这份库必须一起过来 —— 少了它，本应用不认识这些目录。
      await writeFile(sourcePath, 'download.db', 'DB');
      await writeFile(sourcePath, 'comic-1/1.jpg', 'IMG');

      await copyDirectoryContents(from: sourcePath, to: targetPath);

      expect(await readFile(targetPath, 'download.db'), 'DB');
    });

    test('重复执行会跳过已存在的，不重复占用空间', () async {
      await seedComics(2);

      final first = await copyDirectoryContents(
        from: sourcePath,
        to: targetPath,
      );
      final second = await copyDirectoryContents(
        from: sourcePath,
        to: targetPath,
      );

      expect(first.movedEntries, 2);
      expect(second.movedEntries, 0);
      expect(second.skippedEntries, 2);
      expect((await relativeFiles(targetPath)).length, 2);
      expect((await relativeFiles(sourcePath)).length, 2);
    });

    test('中断后源目录仍然完整，重跑可接着复制', () async {
      await seedComics(4);

      var checks = 0;
      final stopped = await copyDirectoryContents(
        from: sourcePath,
        to: targetPath,
        shouldStop: () => ++checks > 1,
      );
      expect(stopped.stopped, isTrue);
      expect((await relativeFiles(sourcePath)).length, 4, reason: '源必须完整');

      final again = await copyDirectoryContents(
        from: sourcePath,
        to: targetPath,
      );
      expect(again.movedEntries, 3);
      expect((await relativeFiles(targetPath)).length, 4);
    });

    test('进度阶段是 copying', () async {
      await seedComics(2);

      final phases = <DownloadMigrationPhase>[];
      await copyDirectoryContents(
        from: sourcePath,
        to: targetPath,
        onProgress: (p) => phases.add(p.phase),
      );

      expect(phases, everyElement(DownloadMigrationPhase.copying));
    });

    test('源目录不存在时安静返回 0', () async {
      await Directory(sourcePath).delete(recursive: true);
      final result = await copyDirectoryContents(
        from: sourcePath,
        to: targetPath,
      );
      expect(result.movedEntries, 0);
      expect(result.failures, isEmpty);
    });

    test('源与目标相同则不做任何事', () async {
      await seedComics(1);
      final result = await copyDirectoryContents(
        from: sourcePath,
        to: sourcePath,
      );
      expect(result.movedEntries, 0);
      expect((await relativeFiles(sourcePath)).length, 1);
    });
  });

  group('hasPendingDownloadEntries', () {
    test('只有 download.db 时返回 false（记录不算没搬完）', () async {
      await writeFile(sourcePath, 'download.db', 'DB');
      expect(await hasPendingDownloadEntries(sourcePath), isFalse);
    });

    test('还有漫画目录时返回 true', () async {
      await writeFile(sourcePath, 'comic-1/1.jpg', 'IMG');
      expect(await hasPendingDownloadEntries(sourcePath), isTrue);
    });

    test('空目录返回 false', () async {
      expect(await hasPendingDownloadEntries(sourcePath), isFalse);
    });

    test('目录不存在返回 false', () async {
      await Directory(sourcePath).delete(recursive: true);
      expect(await hasPendingDownloadEntries(sourcePath), isFalse);
    });

    test('目标在源目录内部：「只剩通往目标的路径」也算搬完（真机实证）', () async {
      // 真机现场：旧目录 `/storage/emulated/0/1/pica` 里只剩
      // `download.db` 与 `picakeep/`（= 目标的父目录链），
      // 3.7 G 内容其实**已经全部搬进**新目录 —— 完成判定却永远为真，
      // 用户反复看到「转移未完成」，续传记录也永远销不掉。
      final nested = p.join(sourcePath, 'picakeep', 'download');
      await Directory(nested).create(recursive: true);
      await writeFile(sourcePath, 'download.db', 'DB');

      // 不传 `to`：保持既有语义，`picakeep/` 被当成"还有内容"。
      expect(await hasPendingDownloadEntries(sourcePath), isTrue);
      // 传了 `to`：正确判定为"已搬完"。
      expect(
        await hasPendingDownloadEntries(sourcePath, to: nested),
        isFalse,
        reason: '通往目标的路径不该被算成未搬完的内容',
      );
    });

    test('目标在源目录内部：还有真正的漫画目录时仍算未搬完', () async {
      final nested = p.join(sourcePath, 'picakeep', 'download');
      await Directory(nested).create(recursive: true);
      await writeFile(sourcePath, 'comic-0/1.jpg', 'IMG');

      expect(
        await hasPendingDownloadEntries(sourcePath, to: nested),
        isTrue,
        reason: '跳过目标路径不等于把一切都当搬完',
      );
    });
  });

  group('hasMigratableDownloadContent', () {
    test('目录不存在返回 false', () async {
      await Directory(sourcePath).delete(recursive: true);
      expect(await hasMigratableDownloadContent(sourcePath), isFalse);
    });

    test('空路径返回 false', () async {
      expect(await hasMigratableDownloadContent(''), isFalse);
      expect(await hasMigratableDownloadContent('   '), isFalse);
    });

    test('空目录返回 false', () async {
      expect(await hasMigratableDownloadContent(sourcePath), isFalse);
    });

    test('只有 download.db 也算有内容', () async {
      await writeFile(sourcePath, 'download.db', 'DB');
      expect(await hasMigratableDownloadContent(sourcePath), isTrue);
    });

    test('只有子目录时返回 true', () async {
      await Directory(p.join(sourcePath, 'comic-1')).create();
      expect(await hasMigratableDownloadContent(sourcePath), isTrue);
    });
  });

  group('端到端：先切目录再搬的完整序列', () {
    test('复制库 -> 搬漫画 -> 旧目录只剩库', () async {
      await writeFile(sourcePath, 'download.db', 'DB');
      await seedComics(3);

      // 1. 数据库先行，新目录立刻可用。
      expect(
        await seedDownloadDatabase(from: sourcePath, to: targetPath),
        isTrue,
      );
      expect(await readFile(targetPath, 'download.db'), 'DB');

      // 2. 逐个搬漫画（默认模式：全部复制成功后才清理）。
      final result = await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
      );

      expect(result.movedEntries, 3);
      expect(result.failures, isEmpty);
      expect(await hasPendingDownloadEntries(sourcePath), isFalse);
      // 旧目录只剩一份数据库备份，供用户确认后再自行删除。
      expect(await relativeFiles(sourcePath), ['download.db']);
      expect(await relativeFiles(targetPath), [
        'comic-0/1.jpg',
        'comic-1/1.jpg',
        'comic-2/1.jpg',
        'download.db',
      ]);
    });

    test('存储紧张模式的完整序列同样收尾干净', () async {
      await writeFile(sourcePath, 'download.db', 'DB');
      await seedComics(3);

      await seedDownloadDatabase(from: sourcePath, to: targetPath);
      final result = await migrateDownloadEntries(
        from: sourcePath,
        to: targetPath,
        deleteSourceAsWeGo: true,
      );

      expect(result.movedEntries, 3);
      expect(result.failures, isEmpty);
      expect(await relativeFiles(sourcePath), ['download.db']);
      expect(await relativeFiles(targetPath), [
        'comic-0/1.jpg',
        'comic-1/1.jpg',
        'comic-2/1.jpg',
        'download.db',
      ]);
    });
  });
}
