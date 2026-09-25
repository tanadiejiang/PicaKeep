import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/archive/archive_reading_service.dart';
import 'package:picakeep/foundation/archive/archive_registry.dart';
import 'package:picakeep/foundation/pixiv_artifact.dart';

/// 28 号计划：Pixiv 多图打包为 zip、单图直放。
///
/// 这一组盯的是**产物形态**那条最危险的规矩：
/// 先确认 zip 写成功（能被归档服务打开），**再**删原图。
/// 打包函数本身**从不删原目录** —— 删是调用方在校验通过之后才做的事，
/// 所以下面用"打包完原图还在"来把这条红线钉死在单测里。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(ArchiveRegistry.initDefaults);

  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('pk-pixiv-artifact-test');
  });

  tearDown(() async {
    try {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    } catch (_) {}
  });

  Future<Directory> buildSourceDir(List<String> names) async {
    final dir = Directory('${tempRoot.path}${Platform.pathSeparator}src');
    await dir.create(recursive: true);
    for (var i = 0; i < names.length; i++) {
      // 内容各不相同且够明显：便于断言"字节原样进包、没有被压缩过又还原错"。
      await File('${dir.path}${Platform.pathSeparator}${names[i]}')
          .writeAsBytes(List<int>.generate(64, (n) => (n + i * 7) % 251));
    }
    return dir;
  }

  File targetFile(String name) =>
      File('${tempRoot.path}${Platform.pathSeparator}$name');

  group('resolvePixivArtifactForm · 开关 × 页数', () {
    test('开关关闭时永远是目录形态（与改动前逐字节一致）', () {
      for (final pageCount in <int>[0, 1, 2, 47]) {
        expect(
          resolvePixivArtifactForm(zipEnabled: false, pageCount: pageCount),
          PixivArtifactForm.directory,
          reason: 'pageCount=$pageCount',
        );
      }
    });

    test('开关打开：多图打包、单图直放', () {
      expect(
        resolvePixivArtifactForm(zipEnabled: true, pageCount: 2),
        PixivArtifactForm.archive,
      );
      expect(
        resolvePixivArtifactForm(zipEnabled: true, pageCount: 1),
        PixivArtifactForm.singleImage,
      );
    });

    test('页数未知（0）时不猜：保持目录形态，避免把多图裁成单图', () {
      expect(
        resolvePixivArtifactForm(zipEnabled: true, pageCount: 0),
        PixivArtifactForm.directory,
      );
      expect(
        resolvePixivArtifactForm(zipEnabled: true, pageCount: -1),
        PixivArtifactForm.directory,
      );
    });
  });

  group('pixivArtifactFileName · 产物名', () {
    test('目录形态返回 null（目录名不加任何后缀）', () {
      expect(
        pixivArtifactFileName(
          form: PixivArtifactForm.directory,
          baseName: 'a_b_p3',
        ),
        isNull,
      );
    });

    test('压缩包形态加 .zip，单图形态用图片自己的扩展名', () {
      expect(
        pixivArtifactFileName(
          form: PixivArtifactForm.archive,
          baseName: '電瘋扇_シグニット_82074457_p3',
        ),
        '電瘋扇_シグニット_82074457_p3.zip',
      );
      expect(
        pixivArtifactFileName(
          form: PixivArtifactForm.singleImage,
          baseName: '電瘋扇_シグニット_82074457_p1',
          imageExtension: '.png',
        ),
        '電瘋扇_シグニット_82074457_p1.png',
      );
    });

    test('单图拿不到扩展名时回退 .jpg，绝不产出无扩展名文件', () {
      expect(
        pixivArtifactFileName(
          form: PixivArtifactForm.singleImage,
          baseName: 'x',
        ),
        'x.jpg',
      );
    });
  });

  group('packagePixivDirectoryToStoreZip · 产物本身', () {
    test('打出的 zip 能被归档服务打开，且条目数与源文件数一致', () async {
      final dir = await buildSourceDir(<String>['1.jpg', '2.jpg', '10.jpg']);
      final target = targetFile('book.zip');

      await packagePixivDirectoryToStoreZip(sourceDir: dir, target: target);

      expect(await target.exists(), isTrue);
      final index = await ArchiveReadingService.instance.getIndex(
        target.path,
        forceRefresh: true,
      );
      expect(index.imageEntries.length, 3);
      expect(
        index.imageEntries.map((e) => e.path).toList(),
        <String>['1.jpg', '2.jpg', '10.jpg'],
      );
    });

    test('**仅存储不加密**：压缩方法号是 0（store），不是 8（deflate）', () async {
      final dir = await buildSourceDir(<String>['cover.jpg', '1.jpg', '2.jpg']);
      final target = targetFile('store.zip');

      await packagePixivDirectoryToStoreZip(sourceDir: dir, target: target);

      // 直接读第一个条目的**本地文件头**：偏移 8..9 是压缩方法号。
      // 这一条不经过任何解码器的映射，最贴近"文件里到底写了什么"。
      final bytes = await target.readAsBytes();
      expect(bytes[0], 0x50); // 'P'
      expect(bytes[1], 0x4b); // 'K'
      expect(bytes[8] | (bytes[9] << 8), 0, reason: '必须是 store，不能是 deflate(8)');

      // 解码侧同样应当看到 store：压缩后大小 == 原始大小（无 deflate 包装开销）。
      final archive = ZipDecoder().decodeBytes(bytes);
      final files = archive.files.where((f) => f.isFile).toList();
      expect(files, isNotEmpty);
      for (final file in files) {
        expect(
          file.compression,
          CompressionType.none,
          reason: '${file.name} 应当是 store（仅存储），不能是 deflate',
        );
        expect(file.rawContent, isA<ZipFile>());
        final raw = file.rawContent as ZipFile;
        expect(raw.compressedSize, raw.uncompressedSize, reason: file.name);
      }
      final index = await ArchiveReadingService.instance.getIndex(
        target.path,
        forceRefresh: true,
      );
      expect(index.isEncrypted, isFalse);
    });

    test('条目名与目录内文件一致，封面排最前、其余按自然序', () async {
      final dir = await buildSourceDir(
        <String>['10.jpg', '2.jpg', '1.jpg', 'cover.jpg'],
      );
      final target = targetFile('order.zip');

      await packagePixivDirectoryToStoreZip(sourceDir: dir, target: target);

      final archive = ZipDecoder().decodeBytes(await target.readAsBytes());
      expect(
        archive.files.where((f) => f.isFile).map((f) => f.name).toList(),
        <String>['cover.jpg', '1.jpg', '2.jpg', '10.jpg'],
      );
    });

    test('字节原样进包（store 模式不做任何变换）', () async {
      final dir = await buildSourceDir(<String>['1.jpg']);
      final target = targetFile('bytes.zip');
      final expected =
          await File('${dir.path}${Platform.pathSeparator}1.jpg').readAsBytes();

      await packagePixivDirectoryToStoreZip(sourceDir: dir, target: target);

      final archive = ZipDecoder().decodeBytes(await target.readAsBytes());
      final entry = archive.files.firstWhere((f) => f.isFile);
      expect(entry.content as List<int>, expected);
    });

    test('非图片文件不进包（zip 里只有页面与封面）', () async {
      final dir = await buildSourceDir(<String>['1.jpg', '2.jpg']);
      await File('${dir.path}${Platform.pathSeparator}note.txt')
          .writeAsString('not an image');
      final target = targetFile('filtered.zip');

      await packagePixivDirectoryToStoreZip(sourceDir: dir, target: target);

      final archive = ZipDecoder().decodeBytes(await target.readAsBytes());
      expect(
        archive.files.where((f) => f.isFile).map((f) => f.name).toList(),
        <String>['1.jpg', '2.jpg'],
      );
    });

    test('不加密：无密码即可逐条读取（打包不写任何校验口令）', () async {
      final dir = await buildSourceDir(<String>['1.jpg']);
      final target = targetFile('plain.zip');

      await packagePixivDirectoryToStoreZip(sourceDir: dir, target: target);

      final bytes = await ArchiveReadingService.instance.readEntryBytes(
        target.path,
        '1.jpg',
      );
      expect(bytes, isNotEmpty);
    });
  });

  group('packagePixivDirectoryToStoreZip · 红线与降级', () {
    test('打包只写 zip，**绝不动原图**（删原图必须在调用方校验通过之后）', () async {
      final dir = await buildSourceDir(<String>['1.jpg', '2.jpg']);
      final target = targetFile('keepsource.zip');

      await packagePixivDirectoryToStoreZip(sourceDir: dir, target: target);

      expect(dir.existsSync(), isTrue);
      expect(
        dir.listSync().whereType<File>().map((f) => f.uri.pathSegments.last),
        unorderedEquals(<String>['1.jpg', '2.jpg']),
      );
    });

    test('没有可打包的图片时抛错，且不产出 zip 文件', () async {
      final dir = await buildSourceDir(<String>[]);
      final target = targetFile('empty.zip');

      await expectLater(
        packagePixivDirectoryToStoreZip(sourceDir: dir, target: target),
        throwsA(isA<StateError>()),
      );
      expect(await target.exists(), isFalse);
    });

    test('打包失败时不留下半成品 zip（连上一次的坏包也清掉）', () async {
      // 最容易被忽略的残留场景：目标位置已有一个"上一次的"坏包。
      // 失败后这里必须什么都不剩 —— 否则阅读侧会把它当成真产物。
      final dir = await buildSourceDir(<String>[]);
      final target = targetFile('stale.zip');
      await target.writeAsBytes(<int>[1, 2, 3, 4]);

      await expectLater(
        packagePixivDirectoryToStoreZip(sourceDir: dir, target: target),
        throwsA(anything),
      );
      expect(await target.exists(), isFalse);
    });

    test('源目录不存在时抛错，不产出 zip', () async {
      final missing = Directory('${tempRoot.path}${Platform.pathSeparator}gone');
      final target = targetFile('missing.zip');

      await expectLater(
        packagePixivDirectoryToStoreZip(sourceDir: missing, target: target),
        throwsA(anything),
      );
      expect(await target.exists(), isFalse);
    });
  });

  group('firstPixivPageFile · 单图产物取哪一张', () {
    test('跳过封面，取第一张正文页', () async {
      final dir = await buildSourceDir(<String>['cover.jpg', '1.jpg']);
      final page = await firstPixivPageFile(dir);
      expect(page, isNotNull);
      expect(page!.uri.pathSegments.last, '1.jpg');
    });

    test('有多张残页时按页码取最小，不按字典序（10 < 2 是坑）', () async {
      final dir = await buildSourceDir(<String>['10.jpg', '2.jpg']);
      final page = await firstPixivPageFile(dir);
      expect(page!.uri.pathSegments.last, '2.jpg');
    });

    test('目录不存在 / 没有正文图时返回 null（调用方据此保持目录形态）', () async {
      expect(
        await firstPixivPageFile(
          Directory('${tempRoot.path}${Platform.pathSeparator}nope'),
        ),
        isNull,
      );
      final onlyCover = await buildSourceDir(<String>['cover.jpg']);
      expect(await firstPixivPageFile(onlyCover), isNull);
    });
  });

  group('pixivExtensionOf', () {
    test('取小写扩展名（含点）', () {
      expect(pixivExtensionOf('/a/b/1.JPG'), '.jpg');
      expect(pixivExtensionOf(r'C:\a\b\2.png'), '.png');
    });

    test('没有扩展名 / 点开头时返回空串', () {
      expect(pixivExtensionOf('/a/b/1'), '');
      expect(pixivExtensionOf('/a/b/1.'), '');
      expect(pixivExtensionOf('/a/b/.hidden'), '');
    });
  });
}
