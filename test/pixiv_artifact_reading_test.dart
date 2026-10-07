import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/archive/archive_models.dart';
import 'package:picakeep/foundation/archive/archive_registry.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/def.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/pixiv_artifact.dart';

/// 28 号计划：**阅读链路必须同时认两种产物形态**。
///
/// - 老内容（一个作品一个目录）与图集等路径的行为**一个字节都不能变**；
/// - 新内容（压缩包文件 / 单图文件）必须能列出页面并读出字节。
///
/// 这里全部走**用户真正会走的那条路**：`LocalPathReadingData.loadEp` /
/// `loadImage` —— 也就是阅读页拿页列表与拿页字节的两个入口，
/// 而不是直接调内部函数。`_buildDownloadedEpisodeFilesForEp` 是私有的，
/// 通过这两个公开入口测反而更接近真机行为。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(ArchiveRegistry.initDefaults);

  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('pk-pixiv-reading-test');
  });

  tearDown(() async {
    try {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    } catch (_) {}
  });

  String pathIn(String name) =>
      '${tempRoot.path}${Platform.pathSeparator}$name';

  /// 页面内容各不相同，便于断言"读出来的就是那一页"。
  List<int> pageBytes(int page) =>
      List<int>.generate(48, (i) => (i * 3 + page * 11) % 251);

  Future<Directory> writeFlatWork({
    required String dirName,
    bool withCover = true,
    List<int> pages = const <int>[1, 2, 3],
  }) async {
    final dir = Directory(pathIn(dirName));
    await dir.create(recursive: true);
    if (withCover) {
      await File('${dir.path}${Platform.pathSeparator}cover.jpg')
          .writeAsBytes(pageBytes(99));
    }
    for (final page in pages) {
      await File('${dir.path}${Platform.pathSeparator}$page.jpg')
          .writeAsBytes(pageBytes(page));
    }
    return dir;
  }

  LocalPathReadingData readingDataFor(
    String directoryPath, {
    bool hasEp = false,
  }) {
    return LocalPathReadingData(
      title: 't',
      id: '1',
      downloadId: '1',
      sourceKey: 'pixiv',
      directoryPath: directoryPath,
      hasEp: hasEp,
      eps: hasEp ? const <String, String>{'1': '第1话', '2': '第2话'} : null,
      comicType: ComicType.pixiv,
      // 空 episodeFiles = 逼 `loadEp` 走"现场按路径列页"这条路，
      // 也就是本次改造真正改到的那一段。
      episodeFiles: const <int, List<String>>{},
      downloadedEpisodeIndexes: const <int>[0, 1],
      // 关掉"按设置排序"：这一组测的是**列页结果**，排序是另一个开关的事。
      supportsImageSort: false,
    );
  }

  List<String> entryNamesOf(List<String> archiveUris) => archiveUris
      .map((uri) => parseArchiveUri(uri)?.entryPath ?? uri)
      .toList(growable: false);

  group('压缩包产物 · 能列页、能读页', () {
    test('列页返回按页序的 archive URI，且不含封面（否则整本错位一页）', () async {
      final dir = await writeFlatWork(dirName: '電瘋扇_シグニット_82074457_p3');
      final zip = File(pathIn('電瘋扇_シグニット_82074457_p3.zip'));
      await packagePixivDirectoryToStoreZip(sourceDir: dir, target: zip);
      await dir.delete(recursive: true);

      final files = await readingDataFor(zip.path).loadEp(0);

      expect(files.length, 3, reason: 'cover.jpg 不能混进页面列表');
      expect(entryNamesOf(files), <String>['1.jpg', '2.jpg', '3.jpg']);
      for (final uri in files) {
        expect(isArchiveUri(uri), isTrue);
        expect(parseArchiveUri(uri)!.archivePath, zip.path);
      }
    });

    test('两位数页码按自然序，不是字典序（10 不能排到 2 前面）', () async {
      final dir = await writeFlatWork(
        dirName: 'many',
        pages: <int>[1, 2, 10, 11, 20],
      );
      final zip = File(pathIn('many.zip'));
      await packagePixivDirectoryToStoreZip(sourceDir: dir, target: zip);

      final files = await readingDataFor(zip.path).loadEp(0);

      expect(
        entryNamesOf(files),
        <String>['1.jpg', '2.jpg', '10.jpg', '11.jpg', '20.jpg'],
      );
    });

    test('每页读出来的字节就是放进包里的那一页', () async {
      final dir = await writeFlatWork(dirName: 'bytes');
      final zip = File(pathIn('bytes.zip'));
      await packagePixivDirectoryToStoreZip(sourceDir: dir, target: zip);

      final data = readingDataFor(zip.path);
      final files = await data.loadEp(0);
      for (var i = 0; i < files.length; i++) {
        final bytes = await data.loadImage(0, i, files[i]).first;
        expect(bytes, pageBytes(i + 1), reason: '第 ${i + 1} 页');
      }
    });

    test('原文件页按成员实际长度计费，使用中保护，释放后删除临时成员', () async {
      final dir = await writeFlatWork(dirName: 'original-source');
      final zip = File(pathIn('original-source.zip'));
      await packagePixivDirectoryToStoreZip(sourceDir: dir, target: zip);
      final data = readingDataFor(zip.path);
      final pages = await data.loadEp(0);
      final baseline = ImageTemporaryPool.shared.reservedBytes;
      final source = await data.resolvePageSource(0, 1, pages[1]);
      final original = await source.openOriginalFile();
      expect(await original.readAsBytes(), pageBytes(2));
      expect(source.identity.page, 1);
      expect(source.identity.sourceKey, 'pixiv');
      expect(ImageTemporaryPool.shared.reservedBytes,
          baseline + pageBytes(2).length);
      final release = ReaderPageFileLease.acquire(original);
      final disposal = source.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(await original.exists(), isTrue);
      expect(ImageTemporaryPool.shared.reservedBytes,
          baseline + pageBytes(2).length);
      release();
      await disposal;
      expect(await original.exists(), isFalse);
      expect(await zip.exists(), isTrue);
      expect(ImageTemporaryPool.shared.reservedBytes, baseline);
    });

    test('选择后 ZIP 被替换会明确失败，不导出新版本成员', () async {
      final dir = await writeFlatWork(dirName: 'replaced-source');
      final zip = File(pathIn('replaced-source.zip'));
      await packagePixivDirectoryToStoreZip(sourceDir: dir, target: zip);
      final data = readingDataFor(zip.path);
      final pages = await data.loadEp(0);
      final source = await data.resolvePageSource(0, 0, pages[0]);
      final baseline = ImageTemporaryPool.shared.reservedBytes;
      await zip.writeAsBytes([1, 2, 3]);
      await expectLater(source.openOriginalFile(), throwsStateError);
      await source.dispose();
      expect(ImageTemporaryPool.shared.reservedBytes, baseline);
    });

    test('压缩包的图片 key 带包指纹（换包不会命中旧缓存）', () async {
      final dir = await writeFlatWork(dirName: 'keys');
      final zip = File(pathIn('keys.zip'));
      await packagePixivDirectoryToStoreZip(sourceDir: dir, target: zip);

      final data = readingDataFor(zip.path);
      final files = await data.loadEp(0);
      final key = data.buildImageKey(0, 0, files.first);
      expect(key, startsWith('archive::'));
      expect(key, contains(zip.path));
      expect(key, contains('1.jpg'));
    });

    test('包损坏 / 打不开时返回空列表，不把异常抛进阅读页', () async {
      final broken = File(pathIn('broken.zip'));
      await broken.writeAsBytes(<int>[1, 2, 3, 4, 5]);

      expect(await readingDataFor(broken.path).loadEp(0), isEmpty);
    });

    test('页号越界返回空列表（有章节语义时）', () async {
      final dir = await writeFlatWork(dirName: 'ep-oob');
      final zip = File(pathIn('ep-oob.zip'));
      await packagePixivDirectoryToStoreZip(sourceDir: dir, target: zip);

      expect(await readingDataFor(zip.path, hasEp: true).loadEp(5), isEmpty);
    });

    test('无章节作品（hasEp=false）：任何 ep 都落到 key 0，与目录形态同语义', () async {
      final dir = await writeFlatWork(dirName: 'no-ep');
      final zip = File(pathIn('no-ep.zip'));
      await packagePixivDirectoryToStoreZip(sourceDir: dir, target: zip);

      final data = readingDataFor(zip.path);
      final at0 = await data.loadEp(0);
      expect(at0, isNotEmpty);
      expect(await data.loadEp(3), at0);
    });
  });

  group('单图产物 · 一个作品就是一个图片文件', () {
    test('列页返回该文件本身，并能读出字节', () async {
      final file = File(pathIn('電瘋扇_シグニット_82074457_p1.jpg'));
      await file.writeAsBytes(pageBytes(7));

      final data = readingDataFor(file.path);
      final files = await data.loadEp(0);

      expect(files, <String>[file.path]);
      expect(await data.loadImage(0, 0, files.first).first, pageBytes(7));
    });

    test('原文件资源释放不会删除用户单图，也不占临时预算', () async {
      final file =
          await File(pathIn('single-original.jpg')).writeAsBytes(pageBytes(8));
      final data = readingDataFor(file.path);
      final source = await data.resolvePageSource(0, 0, file.path);
      final baseline = ImageTemporaryPool.shared.reservedBytes;
      expect((await source.openOriginalFile()).path, file.path);
      await source.dispose();
      expect(await file.readAsBytes(), pageBytes(8));
      expect(ImageTemporaryPool.shared.reservedBytes, baseline);
    });

    test('页号不是 0/1 时返回空列表（有章节语义时）', () async {
      final file = File(pathIn('single_p1.jpg'));
      await file.writeAsBytes(pageBytes(7));

      expect(await readingDataFor(file.path, hasEp: true).loadEp(2), isEmpty);
    });

    test('文件不存在时返回空列表（内容被删掉的场景）', () async {
      expect(
        await readingDataFor(pathIn('已删除_p1.jpg')).loadEp(0),
        isEmpty,
      );
    });
  });

  group('回归 · 目录形态行为与改动前完全一致', () {
    test('平铺目录：自然序、剔除封面', () async {
      final dir = await writeFlatWork(
        dirName: 'flat',
        pages: <int>[1, 2, 10],
      );

      final files = await readingDataFor(dir.path).loadEp(0);

      expect(
        files,
        <String>[
          '${dir.path}${Platform.pathSeparator}1.jpg',
          '${dir.path}${Platform.pathSeparator}2.jpg',
          '${dir.path}${Platform.pathSeparator}10.jpg',
        ],
      );
    });

    test('多章节目录：ep=1/2 取到对应章节目录，ep 超界为空', () async {
      final root = Directory(pathIn('chapters'));
      final ch1 = Directory('${root.path}${Platform.pathSeparator}1');
      final ch2 = Directory('${root.path}${Platform.pathSeparator}2');
      await ch1.create(recursive: true);
      await ch2.create(recursive: true);
      await File('${ch1.path}${Platform.pathSeparator}1.jpg')
          .writeAsBytes(pageBytes(1));
      await File('${ch2.path}${Platform.pathSeparator}1.jpg')
          .writeAsBytes(pageBytes(2));
      await File('${ch2.path}${Platform.pathSeparator}2.jpg')
          .writeAsBytes(pageBytes(3));

      final data = readingDataFor(root.path, hasEp: true);
      expect(
        (await data.loadEp(1)).map((p) => p.split(Platform.pathSeparator).last),
        <String>['1.jpg'],
      );
      expect(
        (await data.loadEp(2)).map((p) => p.split(Platform.pathSeparator).last),
        <String>['1.jpg', '2.jpg'],
      );
      expect(await data.loadEp(9), isEmpty);
    });

    test('目录里只有封面时仍返回封面（老行为：全被剔光则回退原列表）', () async {
      final dir = await writeFlatWork(dirName: 'cover-only', pages: <int>[]);

      final files = await readingDataFor(dir.path).loadEp(0);

      expect(
        files,
        <String>['${dir.path}${Platform.pathSeparator}cover.jpg'],
      );
    });

    test('目录不存在时返回空列表', () async {
      expect(await readingDataFor(pathIn('不存在')).loadEp(0), isEmpty);
    });
  });
}
