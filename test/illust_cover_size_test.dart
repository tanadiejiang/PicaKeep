/// 插画封面尺寸补齐链路的测试：**真实比例**的取值、缓存、降级与幂等。
///
/// ## 为什么必须测这些
///
/// 32 号计划「验收标准 2」的第一条：给定带宽高的记录用真实比例；给定缺宽高的
/// 记录走读头路径拿到真实比例；两者都拿不到才降级到占位比例（且比例恒为正有限、
/// 夹在合理区间）。这三档**都不能靠肉眼看 UI**：
///
/// - 走错了档不会报错 —— 症状只是"每条一样高"（用户最初报的问题）；
/// - 缓存键写错不会报错 —— 症状只是"慢"；
/// - 降级漏了会算出 `Infinity` 高度，布局直接崩。
///
/// 所有 IO 都通过注入口子（读头 / 读时间戳 / 列目录）替换掉，因此本文件
/// **不碰真实文件系统**（除了缓存落盘与有界读那两组，它们用临时目录，
/// 因为往返与"只读前 N 字节"本身就是被测对象）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/illust_cover_size.dart';
import 'package:picakeep/foundation/image_header_size.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/foundation/privileged_storage_access.dart';

/// 真机实测的一条 Pixiv 记录的形态：`638×1200`（`Vodyanitsa🎨/1.jpg` 与
/// 其 `cover.jpg` 的比例一致，0.53167 / 0.53128）。
const int _realWidth = 638;
const int _realHeight = 1200;

/// 造一条插画条目（json 列的形态与 `CustomDownloadedItem.toJson()` 一致）。
LocalLibraryComicItem _item({
  required String id,
  int? width,
  int? height,
  String fileSystemPath = '/tmp/cover',
}) {
  final json = '{"id":"$id","name":"作品","subTitle":"作者",'
      '"tags":[],"sourceKey":"pixiv","sourceName":"Pixiv","cover":"",'
      '"comicId":"$id","width":${width ?? 'null'},"height":${height ?? 'null'}}';
  return LocalLibraryComicItem(
    itemId: 'local_download::current_download::$id',
    originalId: id,
    type: DownloadType.other,
    name: '作品',
    subTitle: '作者',
    tags: const <String>[],
    sourceDisplayName: 'Pixiv',
    fileSystemPath: fileSystemPath,
    episodeFiles: const <int, List<String>>{},
    downloadedEps: const <int>[0],
    eps: const <String>['全部'],
    localCoverPath: null,
    localStorageExists: true,
    canDelete: false,
    aliases: <String>[id],
    sourceRowJson: json,
  );
}

/// 一段"能被解析成 `width`×`height`"的 PNG 头。
Uint8List _coverHeader(int width, int height) {
  return Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0, 0, 0, 13,
    0x49, 0x48, 0x44, 0x52,
    (width >> 24) & 0xFF, (width >> 16) & 0xFF, (width >> 8) & 0xFF,
    width & 0xFF,
    (height >> 24) & 0xFF, (height >> 16) & 0xFF, (height >> 8) & 0xFF,
    height & 0xFF,
    0x08, 0x06, 0x00, 0x00, 0x00, 0, 0, 0, 0,
  ]);
}

/// 一个"目录里有一张正文图 + 一张封面"的列表（单图作品的标准形态）。
const List<LocalDirectoryEntry> _onePageWithCover = <LocalDirectoryEntry>[
  LocalDirectoryEntry(name: '1.jpg', path: '/tmp/1.jpg', isDirectory: false),
  LocalDirectoryEntry(
      name: 'cover.jpg', path: '/tmp/cover.jpg', isDirectory: false),
];

/// 页面在 `_loadIllust` 之后**逐字**照这个顺序做：
/// 回填页数 → 挑目标 → `resolveIllustEntryInfo` → `applyIllustResolvedInfo`
/// → setState。这里把整条编排抽成一个函数，覆盖"用户可见的完整工作流"。
Future<List<IllustLibraryEntry>> _runPageFlow(
  List<IllustLibraryEntry> entries, {
  required bool needPageCount,
  required IllustCoverPathResolver resolveCoverPath,
  IllustHeadReader? readHead,
  IllustDirectoryLister? listDirectory,
  IllustCoverSizeCache? cache,
  IllustPageCountMemo? pageCountMemo,
}) async {
  final targets = illustEntriesNeedingResolution(
    entries,
    wantPageCount: needPageCount,
    pageCountMemo: pageCountMemo,
  );
  final resolved = await resolveIllustEntryInfo(
    entries: targets,
    resolveCoverPath: resolveCoverPath,
    needPageCount: needPageCount,
    readHead: readHead,
    readStamp: (_) async => 'm1',
    listDirectory: listDirectory,
    cache: cache ?? IllustCoverSizeCache.inMemory(),
  );
  if (needPageCount) {
    for (final entry in targets) {
      pageCountMemo?.record(entry.id, resolved[entry.id]?.pageCount);
    }
  }
  return applyIllustResolvedInfo(entries, resolved);
}

void main() {
  setUp(resetSharedIllustCoverSizeCacheForTest);

  group('真实比例：缺宽高的老记录走"读封面头"路径', () {
    test('读到尺寸后比例变成真实的（不再是 3:4 占位）', () async {
      final entry = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixiv1'),
      ]).single;
      // 前置：老记录先落到占位比例（这正是用户看到"每条等高"的原因）。
      expect(entry.width, isNull);
      expect(entry.height, isNull);
      expect(entry.aspectRatio, illustFallbackAspectRatio);
      expect(entry.needsSizeResolution, isTrue);

      final readPaths = <String>[];
      final resolved = await resolveIllustEntryInfo(
        entries: <IllustLibraryEntry>[entry],
        resolveCoverPath: (_) async => '/tmp/cover.jpg',
        readHead: (path, maxBytes) async {
          readPaths.add(path);
          expect(maxBytes, illustHeaderReadBytes);
          return _coverHeader(_realWidth, _realHeight);
        },
        readStamp: (_) async => 'm1000',
        cache: IllustCoverSizeCache.inMemory(),
      );

      expect(readPaths, <String>['/tmp/cover.jpg']);
      final info = resolved[entry.id];
      expect(info, isNotNull);
      expect(info!.width, _realWidth);
      expect(info.height, _realHeight);

      final upgraded = entry.withResolvedInfo(
        width: info.width,
        height: info.height,
      );
      expect(upgraded.hasRealSize, isTrue);
      expect(upgraded.needsSizeResolution, isFalse);
      expect(
        upgraded.aspectRatio,
        closeTo(_realWidth / _realHeight, 0.000001),
      );
      // 与占位比例**确实不同** —— 否则测试可能在"没生效"的情况下也是绿的。
      expect(upgraded.aspectRatio, isNot(illustFallbackAspectRatio));
    });

    test('带宽高的记录不读文件，直接用 db 值（零 IO）', () async {
      final entry = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivNew', width: 856, height: 1200),
      ]).single;
      expect(entry.needsSizeResolution, isFalse);

      var readCount = 0;
      var resolveCoverCount = 0;
      final resolved = await resolveIllustEntryInfo(
        entries: <IllustLibraryEntry>[entry],
        resolveCoverPath: (_) async {
          resolveCoverCount++;
          return '/tmp/cover.jpg';
        },
        readHead: (_, __) async {
          readCount++;
          return _coverHeader(1, 1);
        },
        readStamp: (_) async => 'm1',
        cache: IllustCoverSizeCache.inMemory(),
      );

      // 调用方本就不该把这种条目传进来（页面按 needsSizeResolution 过滤），
      // 这里再兜一层：即便传进来也不做 IO。
      expect(resolveCoverCount, 0);
      expect(readCount, 0);
      expect(resolved[entry.id]?.width, 856);
      expect(entry.aspectRatio, closeTo(856 / 1200, 0.000001));
    });

    test('withResolvedInfo 只补空缺：db 已有的宽高不会被封面读数覆盖', () {
      final entry = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivNew', width: 856, height: 1200),
      ]).single;
      final patched = entry.withResolvedInfo(width: 10, height: 10);
      expect(patched.width, 856);
      expect(patched.height, 1200);
      expect(patched.aspectRatio, closeTo(856 / 1200, 0.000001));
      // 值没变时返回同一个实例（避免无谓重建与 setState）。
      expect(identical(patched, entry), isTrue);
    });

    test('只缺一维也要补（缺一维时算不出比例）', () {
      final entry = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivHalf', width: 856),
      ]).single;
      expect(entry.needsSizeResolution, isTrue);
      final patched = entry.withResolvedInfo(width: 999, height: 1200);
      expect(patched.width, 856, reason: '已有的那一维不能被改');
      expect(patched.height, 1200);
    });
  });

  group('三档降级：都拿不到时才用占位比例，且比例恒为正有限', () {
    test('封面路径解析不出 → 保持占位，条目不出现在结果里', () async {
      final entry = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivNoCover'),
      ]).single;
      final resolved = await resolveIllustEntryInfo(
        entries: <IllustLibraryEntry>[entry],
        resolveCoverPath: (_) async => null,
        readHead: (_, __) async => _coverHeader(10, 10),
        readStamp: (_) async => 'm1',
        cache: IllustCoverSizeCache.inMemory(),
      );
      expect(resolved, isEmpty);
      expect(entry.aspectRatio, illustFallbackAspectRatio);
    });

    test('读字节失败（null / 空）→ 保持占位', () async {
      final entry = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivReadFail'),
      ]).single;
      for (final failure in <Uint8List?>[null, Uint8List(0)]) {
        final resolved = await resolveIllustEntryInfo(
          entries: <IllustLibraryEntry>[entry],
          resolveCoverPath: (_) async => '/tmp/cover.jpg',
          readHead: (_, __) async => failure,
          readStamp: (_) async => 'm1',
          cache: IllustCoverSizeCache.inMemory(),
        );
        expect(resolved, isEmpty);
      }
    });

    test('字节读到了但认不出格式（例如根本不是图片）→ 保持占位', () async {
      final entry = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivGarbage'),
      ]).single;
      final resolved = await resolveIllustEntryInfo(
        entries: <IllustLibraryEntry>[entry],
        resolveCoverPath: (_) async => '/tmp/cover.bin',
        readHead: (_, __) async =>
            Uint8List.fromList(List<int>.generate(64, (i) => i)),
        readStamp: (_) async => 'm1',
        cache: IllustCoverSizeCache.inMemory(),
      );
      expect(resolved, isEmpty);
    });

    test('路径解析抛异常 → 只影响这一条，其它条目照常补齐', () async {
      final ok = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivOk'),
      ]).single;
      final bad = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivThrow'),
      ]).single;

      final resolved = await resolveIllustEntryInfo(
        entries: <IllustLibraryEntry>[bad, ok],
        resolveCoverPath: (item) async {
          if (item.originalId == 'pixivThrow') {
            throw StateError('privileged channel failed');
          }
          return '/tmp/cover.jpg';
        },
        readHead: (_, __) async => _coverHeader(_realWidth, _realHeight),
        readStamp: (_) async => 'm1',
        cache: IllustCoverSizeCache.inMemory(),
      );

      expect(resolved.keys, <String>[ok.id]);
    });

    test('极长条的比例被夹在合理区间（1:5 ~ 5:1）', () async {
      final entry = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivLong'),
      ]).single;
      final resolved = await resolveIllustEntryInfo(
        entries: <IllustLibraryEntry>[entry],
        resolveCoverPath: (_) async => '/tmp/cover.jpg',
        // 1 x 20000：真实存在但会让卡片高得离谱
        readHead: (_, __) async => _coverHeader(1, 20000),
        readStamp: (_) async => 'm1',
        cache: IllustCoverSizeCache.inMemory(),
      );
      final patched = entry.withResolvedInfo(
        width: resolved[entry.id]!.width,
        height: resolved[entry.id]!.height,
      );
      expect(patched.aspectRatio, 1 / 5);
      expect(patched.aspectRatio.isFinite, isTrue);
      expect(patched.aspectRatio, greaterThan(0));
    });
  });

  group('缓存：按「路径 + 时间戳」命中，避免重复读文件头', () {
    test('同一路径同一时间戳第二次不再读头', () async {
      final cache = IllustCoverSizeCache.inMemory();
      var readCount = 0;
      Future<Map<String, IllustResolvedInfo>> run(String id) {
        final entry = buildIllustEntries(<LocalLibraryComicItem>[
          _item(id: id),
        ]).single;
        return resolveIllustEntryInfo(
          entries: <IllustLibraryEntry>[entry],
          resolveCoverPath: (_) async => '/tmp/cover.jpg',
          readHead: (_, __) async {
            readCount++;
            return _coverHeader(_realWidth, _realHeight);
          },
          readStamp: (_) async => 'm1000',
          cache: cache,
        );
      }

      await run('pixivA');
      await run('pixivB');
      expect(readCount, 1, reason: '第二次应命中缓存');
      expect(cache.length, 1);
    });

    test('时间戳变了就重新读（封面被换过不能沿用旧比例）', () async {
      final cache = IllustCoverSizeCache.inMemory();
      var readCount = 0;
      var stamp = 'm1000';
      Future<ImageHeaderSize?> run() async {
        final entry = buildIllustEntries(<LocalLibraryComicItem>[
          _item(id: 'pixivA'),
        ]).single;
        final resolved = await resolveIllustEntryInfo(
          entries: <IllustLibraryEntry>[entry],
          resolveCoverPath: (_) async => '/tmp/cover.jpg',
          readHead: (_, __) async {
            readCount++;
            return _coverHeader(readCount == 1 ? 100 : 200, 400);
          },
          readStamp: (_) async => stamp,
          cache: cache,
        );
        final info = resolved[entry.id];
        return info == null ? null : ImageHeaderSize(info.width!, info.height!);
      }

      expect(await run(), const ImageHeaderSize(100, 400));
      stamp = 'm2000';
      expect(await run(), const ImageHeaderSize(200, 400));
      expect(readCount, 2);
      expect(cache.length, 2);
    });

    test('拿不到时间戳时退化为"只用路径"作键（仍然能命中）', () async {
      final cache = IllustCoverSizeCache.inMemory();
      var readCount = 0;
      for (var i = 0; i < 2; i++) {
        final entry = buildIllustEntries(<LocalLibraryComicItem>[
          _item(id: 'pixivA'),
        ]).single;
        await resolveIllustEntryInfo(
          entries: <IllustLibraryEntry>[entry],
          resolveCoverPath: (_) async => '/tmp/cover.jpg',
          readHead: (_, __) async {
            readCount++;
            return _coverHeader(10, 20);
          },
          readStamp: (_) async => null,
          cache: cache,
        );
      }
      expect(readCount, 1);
    });

    test('落盘往返：格式坏了当空缓存，不抛异常', () async {
      final dir = await Directory.systemTemp.createTemp('pk_cover_cache');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}sizes.json');

      final first = IllustCoverSizeCache.atFile(file);
      await first.load();
      first.store('/tmp/a.jpg::m1', const ImageHeaderSize(638, 1200));
      first.store('/tmp/b.jpg::m2', const ImageHeaderSize(2000, 3500));
      await first.save();

      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(raw['version'], illustCoverSizeCacheVersion);

      final second = IllustCoverSizeCache.atFile(file);
      await second.load();
      expect(second.length, 2);
      expect(
          second.lookup('/tmp/a.jpg::m1'), const ImageHeaderSize(638, 1200));

      // 版本不符 → 整份作废（格式变了不能拿旧值当新值用）。
      await file.writeAsString(jsonEncode(<String, Object>{
        'version': illustCoverSizeCacheVersion + 1,
        'sizes': <String, Object>{
          '/tmp/a.jpg::m1': <int>[1, 1],
        },
      }));
      final third = IllustCoverSizeCache.atFile(file);
      await third.load();
      expect(third.length, 0);

      // 坏 JSON → 当空缓存（缓存是可丢的加速层，不能让它把功能带崩）。
      await file.writeAsString('{not json');
      final fourth = IllustCoverSizeCache.atFile(file);
      await fourth.load();
      expect(fourth.length, 0);
    });

    test('没有改动时 save 不写盘（不产生无谓 IO）', () async {
      final dir = await Directory.systemTemp.createTemp('pk_cover_cache_noop');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}sizes.json');
      final cache = IllustCoverSizeCache.atFile(file);
      await cache.load();
      await cache.save();
      expect(file.existsSync(), isFalse);
    });
  });

  group('页数：目录里的图片张数（排除封面）', () {
    test('countIllustPageImages 排除 cover.*，只数正文', () {
      expect(
        countIllustPageImages(<String>['1.jpg', 'cover.jpg']),
        1,
        reason: '单图作品的目录是 1.jpg + cover.jpg，数成 2 页就错了',
      );
      expect(
        countIllustPageImages(
          <String>['1.jpg', '2.png', '3.webp', 'cover.jpg', 'cover.png'],
        ),
        3,
      );
      expect(countIllustPageImages(<String>['readme.txt', 'cover.jpg']), 0);
      // 大小写与子路径（列目录给的是文件名，但两种输入都该稳）
      expect(countIllustPageImages(<String>['COVER.JPG', '01.JPEG']), 1);
    });

    test('isIllustImageFileName 只认项目口径的图片扩展名', () {
      expect(isIllustImageFileName('/a/b/1.jpg'), isTrue);
      expect(isIllustImageFileName('/a/b/1.webp'), isTrue);
      expect(isIllustImageFileName('/a/b/1.avif'), isFalse);
      expect(isIllustImageFileName('/a/b/1.zip'), isFalse);
    });

    test('needPageCount=false 时不去列目录', () async {
      final entry = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixiv1', fileSystemPath: '/tmp/anything'),
      ]).single;
      var listCount = 0;
      final resolved = await resolveIllustEntryInfo(
        entries: <IllustLibraryEntry>[entry],
        resolveCoverPath: (_) async => '/tmp/cover.jpg',
        readHead: (_, __) async => _coverHeader(10, 20),
        readStamp: (_) async => 'm1',
        listDirectory: (_) async {
          listCount++;
          return const <LocalDirectoryEntry>[];
        },
        cache: IllustCoverSizeCache.inMemory(),
      );
      expect(listCount, 0);
      expect(resolved[entry.id]?.pageCount, isNull);
    });

    test('needPageCount=true 时列目录数图片（并保留宽高结果）', () async {
      final entry = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixiv1', fileSystemPath: '/tmp/pagecount'),
      ]).single;
      final listedPaths = <String>[];
      final resolved = await resolveIllustEntryInfo(
        entries: <IllustLibraryEntry>[entry],
        needPageCount: true,
        resolveCoverPath: (_) async => '/tmp/pagecount/cover.jpg',
        readHead: (_, __) async => _coverHeader(_realWidth, _realHeight),
        readStamp: (_) async => 'm1',
        listDirectory: (path) async {
          listedPaths.add(path);
          return const <LocalDirectoryEntry>[
            LocalDirectoryEntry(
                name: '1.jpg',
                path: '/tmp/pagecount/1.jpg',
                isDirectory: false),
            LocalDirectoryEntry(
                name: '2.jpg',
                path: '/tmp/pagecount/2.jpg',
                isDirectory: false),
            LocalDirectoryEntry(
                name: '3.jpg',
                path: '/tmp/pagecount/3.jpg',
                isDirectory: false),
            LocalDirectoryEntry(
                name: 'cover.jpg',
                path: '/tmp/pagecount/cover.jpg',
                isDirectory: false),
            LocalDirectoryEntry(
                name: 'sub', path: '/tmp/pagecount/sub', isDirectory: true),
          ];
        },
        cache: IllustCoverSizeCache.inMemory(),
      );
      expect(listedPaths, <String>['/tmp/pagecount']);
      final info = resolved[entry.id]!;
      expect(info.pageCount, 3);
      expect(info.width, _realWidth);
      expect(info.height, _realHeight);
    });

    test('压缩包形态给不出页数 → null（不瞎猜，也不去列目录）', () async {
      for (final path in <String>['/tmp/a.zip', '/tmp/a.cbz']) {
        final entry = buildIllustEntries(<LocalLibraryComicItem>[
          _item(id: 'pixivZip', fileSystemPath: path),
        ]).single;
        var listCount = 0;
        final resolved = await resolveIllustEntryInfo(
          entries: <IllustLibraryEntry>[entry],
          needPageCount: true,
          resolveCoverPath: (_) async => '/tmp/cover.jpg',
          readHead: (_, __) async => _coverHeader(10, 20),
          readStamp: (_) async => 'm1',
          listDirectory: (_) async {
            listCount++;
            return const <LocalDirectoryEntry>[];
          },
          cache: IllustCoverSizeCache.inMemory(),
        );
        expect(listCount, 0);
        expect(resolved[entry.id]?.pageCount, isNull);
      }
    });

    test('单文件形态恒为 1 页', () async {
      final entry = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivSingle', fileSystemPath: '/tmp/a/作品_p0.jpg'),
      ]).single;
      final resolved = await resolveIllustEntryInfo(
        entries: <IllustLibraryEntry>[entry],
        needPageCount: true,
        resolveCoverPath: (_) async => '/tmp/cover.jpg',
        readHead: (_, __) async => _coverHeader(10, 20),
        readStamp: (_) async => 'm1',
        listDirectory: (_) async => const <LocalDirectoryEntry>[],
        cache: IllustCoverSizeCache.inMemory(),
      );
      expect(resolved[entry.id]?.pageCount, 1);
    });

    test('列目录抛异常 → 页数为 null，但宽高仍然补齐', () async {
      final entry = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivListFail', fileSystemPath: '/tmp/x'),
      ]).single;
      final resolved = await resolveIllustEntryInfo(
        entries: <IllustLibraryEntry>[entry],
        needPageCount: true,
        resolveCoverPath: (_) async => '/tmp/cover.jpg',
        readHead: (_, __) async => _coverHeader(_realWidth, _realHeight),
        readStamp: (_) async => 'm1',
        listDirectory: (_) async => throw StateError('no access'),
        cache: IllustCoverSizeCache.inMemory(),
      );
      final info = resolved[entry.id]!;
      expect(info.pageCount, isNull);
      expect(info.width, _realWidth);
    });
  });

  group('批量与并发', () {
    test('空列表直接返回，不建缓存也不报错', () async {
      final resolved = await resolveIllustEntryInfo(
        entries: const <IllustLibraryEntry>[],
        resolveCoverPath: (_) async => '/tmp/cover.jpg',
      );
      expect(resolved, isEmpty);
    });

    test('并发上限被遵守，且所有条目都被处理到', () async {
      final entries = <IllustLibraryEntry>[
        for (var i = 0; i < 12; i++)
          buildIllustEntries(<LocalLibraryComicItem>[_item(id: 'pixiv$i')])
              .single,
      ];
      var inFlight = 0;
      var peak = 0;
      final seen = <String>[];
      final resolved = await resolveIllustEntryInfo(
        entries: entries,
        concurrency: 3,
        resolveCoverPath: (item) async => '/tmp/${item.originalId}.jpg',
        readHead: (path, _) async {
          inFlight++;
          peak = inFlight > peak ? inFlight : peak;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          seen.add(path);
          inFlight--;
          return _coverHeader(_realWidth, _realHeight);
        },
        readStamp: (_) async => 'm1',
        cache: IllustCoverSizeCache.inMemory(),
      );
      expect(peak, lessThanOrEqualTo(3));
      expect(seen.length, 12);
      expect(resolved.length, 12);
    });

    test('concurrency < 1 也能跑（不会一条都不处理）', () async {
      final entries = <IllustLibraryEntry>[
        for (var i = 0; i < 3; i++)
          buildIllustEntries(<LocalLibraryComicItem>[_item(id: 'pixiv$i')])
              .single,
      ];
      final resolved = await resolveIllustEntryInfo(
        entries: entries,
        concurrency: 0,
        resolveCoverPath: (_) async => '/tmp/c.jpg',
        readHead: (_, __) async => _coverHeader(10, 20),
        readStamp: (_) async => 'm1',
        cache: IllustCoverSizeCache.inMemory(),
      );
      expect(resolved.length, 3);
    });
  });

  group('页面集成契约：挑谁去补 / 补完怎么合回去', () {
    test('缺宽高的老记录该被选中；宽高齐全且不需要页数的不该被选中', () {
      final old = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivOld'),
      ]).single;
      final fresh = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivNew', width: 856, height: 1200),
      ]).single;

      final targets = illustEntriesNeedingResolution(
        <IllustLibraryEntry>[old, fresh],
        wantPageCount: false,
      );
      expect(targets.map((e) => e.id).toList(), <String>[old.id]);
    });

    test('勾了「页数」时，宽高齐全的条目也会被选中（它只缺页数）', () {
      final fresh = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivNew', width: 856, height: 1200),
      ]).single;
      final targets = illustEntriesNeedingResolution(
        <IllustLibraryEntry>[fresh],
        wantPageCount: true,
      );
      expect(targets.map((e) => e.id).toList(), <String>[fresh.id]);
    });

    test('端到端：三条真机形态的记录补齐后**高度互不相等**（用户报的症状）',
        () async {
      // 真机实测的三条 Pixiv 记录（封面原图尺寸）
      const realSizes = <String, ({int w, int h})>{
        'pixiv79837313': (w: 2000, h: 3500), // 是色兔子peko
        'pixiv150033282': (w: 1489, h: 2088), // 完全で瀟洒な従者
        'pixiv150034783': (w: 1070, h: 2014), // Vodyanitsa🎨
      };
      final entries = buildIllustEntries(<LocalLibraryComicItem>[
        for (final id in realSizes.keys) _item(id: id),
      ]);
      // 前置：三条全是占位比例 → 完全等高（这就是用户看到的"每条等高"）
      expect(
        entries.map((e) => e.aspectRatio).toSet(),
        <double>{illustFallbackAspectRatio},
      );

      final merged = await _runPageFlow(
        entries,
        needPageCount: false,
        resolveCoverPath: (item) async => '/tmp/${item.originalId}/cover.jpg',
        readHead: (path, _) async {
          final id = path.split('/')[2];
          final size = realSizes[id]!;
          return _coverHeader(size.w, size.h);
        },
      );

      final ratios = merged.map((e) => e.aspectRatio).toList();
      // 三条比例两两不同 → 瀑布流里每条高度都不一样
      expect(ratios.toSet().length, 3);
      expect(ratios, isNot(contains(illustFallbackAspectRatio)));
      // 与实际比例一致
      expect(ratios[0], closeTo(2000 / 3500, 0.0001));
      expect(ratios[1], closeTo(1489 / 2088, 0.0001));
      expect(ratios[2], closeTo(1070 / 2014, 0.0001));
      // 顺序与条目数都不能变
      expect(
          merged.map((e) => e.id).toList(), entries.map((e) => e.id).toList());
    });

    test('部分失败：读不到的条目保持占位，其它条目照常升级', () async {
      final ok = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivOk'),
      ]).single;
      final bad = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivBad'),
      ]).single;

      final merged = await _runPageFlow(
        <IllustLibraryEntry>[ok, bad],
        needPageCount: false,
        resolveCoverPath: (item) async =>
            item.originalId == 'pixivOk' ? '/tmp/ok/cover.jpg' : null,
        readHead: (_, __) async => _coverHeader(_realWidth, _realHeight),
      );

      expect(merged.length, 2);
      expect(merged[0].aspectRatio, closeTo(_realWidth / _realHeight, 0.0001));
      expect(merged[1].aspectRatio, illustFallbackAspectRatio);
      // 顺序不变
      expect(merged.map((e) => e.id).toList(), <String>[ok.id, bad.id]);
    });

    test('applyIllustResolvedInfo：结果为空时返回原列表（不做无谓重建）', () {
      final entries = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixiv1'),
      ]);
      expect(
        identical(
          applyIllustResolvedInfo(
              entries, const <String, IllustResolvedInfo>{}),
          entries,
        ),
        isTrue,
      );
    });

    test('applyIllustResolvedInfo：只改命中的条目，未命中的保持同一实例', () {
      final hit = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivHit'),
      ]).single;
      final miss = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixivMiss'),
      ]).single;
      final merged = applyIllustResolvedInfo(
        <IllustLibraryEntry>[hit, miss],
        <String, IllustResolvedInfo>{
          hit.id: const IllustResolvedInfo(
              width: 638, height: 1200, pageCount: 1),
        },
      );
      expect(merged[0].width, 638);
      expect(merged[0].pageCount, 1);
      expect(identical(merged[1], miss), isTrue);
    });

    test('二次补齐是幂等的：再跑一遍结果不再变化', () async {
      final entries = buildIllustEntries(<LocalLibraryComicItem>[
        _item(id: 'pixiv1'),
      ]);
      Future<List<IllustLibraryEntry>> once(List<IllustLibraryEntry> input) {
        return _runPageFlow(
          input,
          needPageCount: true,
          resolveCoverPath: (_) async => '/tmp/cover.jpg',
          readHead: (_, __) async => _coverHeader(_realWidth, _realHeight),
          listDirectory: (_) async => _onePageWithCover,
        );
      }

      final first = await once(entries);
      final second = await once(first);
      expect(second.first.width, first.first.width);
      expect(second.first.height, first.first.height);
      expect(second.first.pageCount, first.first.pageCount);
      expect(second.first.aspectRatio, first.first.aspectRatio);
    });
  });

  group('页数记忆：跨重新取数保住页数，且不反复列目录', () {
    IllustLibraryEntry plain(String id) =>
        buildIllustEntries(<LocalLibraryComicItem>[_item(id: id)]).single;

    test('页数被记住后，重建的条目会被**回填**（否则刷新一次页数就消失）', () {
      final memo = IllustPageCountMemo();
      final remembered = plain('pixiv1');
      // ⚠️ 记忆的键是**条目的 `id`**（`local_download::current_download::pixiv1`
      // 这种复合 id），不是 `originalId`。页面两处都用 `entry.id`；
      // 键不一致的后果是"记了但永远命中不了"，且不报任何错。
      memo.record(remembered.id, 3);

      // `_loadIllust` 每次都用 buildIllustEntries 重建条目：页数恒为 null
      final rebuilt = <IllustLibraryEntry>[plain('pixiv1')];
      expect(rebuilt.single.pageCount, isNull);
      expect(rebuilt.single.id, remembered.id);

      final filled = memo.apply(rebuilt);
      expect(filled.single.pageCount, 3);
      // 没有记录的不动、且返回**同一实例**（不做无谓重建）
      final other = plain('pixiv2');
      expect(
        identical(memo.apply(<IllustLibraryEntry>[other]).single, other),
        isTrue,
      );
    });

    test('记住后不再被选中（不反复列目录）；试过但数不出来的也不再选中', () {
      final memo = IllustPageCountMemo();
      memo.record(plain('pixivOk').id, 3);
      memo.record(plain('pixivZip').id, null); // 压缩包形态：试过，数不出来

      final targets = illustEntriesNeedingResolution(
        <IllustLibraryEntry>[plain('pixivOk'), plain('pixivZip')],
        wantPageCount: true,
        pageCountMemo: memo,
      );
      // 两者的宽高都缺 → 仍会被选中（补比例），但都不再需要数页数
      expect(targets.length, 2);
      expect(
        targets.any((e) => memo.needsCount(e.id)),
        isFalse,
        reason: '两条都已经处理过页数（一条数出来、一条试过），不该再触发列目录',
      );
    });

    test('用户后勾上「页数」时仍然能补（没有"本页补过就不补"的全局标志）', () {
      final memo = IllustPageCountMemo();
      // 第一次进视图时没勾「页数」：不选中页数、也不记任何东西
      final firstPass = illustEntriesNeedingResolution(
        <IllustLibraryEntry>[plain('pixiv1')],
        wantPageCount: false,
        pageCountMemo: memo,
      );
      expect(firstPass.length, 1);
      expect(
        memo.needsCount(firstPass.single.id),
        isTrue,
        reason: '先前的视图没勾页数，不该把这个条目标成"已处理"',
      );
      // 之后勾上：仍然可补
      expect(
        illustEntriesNeedingResolution(
          <IllustLibraryEntry>[plain('pixiv1')],
          wantPageCount: true,
          pageCountMemo: memo,
        ).length,
        1,
      );
    });

    test('record 只接受正数（数出 0 页等于没数出来）', () {
      final memo = IllustPageCountMemo();
      memo.record('a', 0);
      memo.record('b', -1);
      memo.record('c', 5);
      expect(memo.countFor('a'), isNull);
      expect(memo.countFor('b'), isNull);
      expect(memo.countFor('c'), 5);
      expect(memo.rememberedCount, 1);
      // 三个都算"试过"
      for (final id in <String>['a', 'b', 'c']) {
        expect(memo.needsCount(id), isFalse);
      }
    });

    test('apply 只在有记录时才重建列表（空记忆直接返回原列表）', () {
      final memo = IllustPageCountMemo();
      final entries = <IllustLibraryEntry>[plain('pixiv1')];
      expect(identical(memo.apply(entries), entries), isTrue);
    });

    test('端到端：刷新一次（重新取数）后页数仍在', () async {
      final memo = IllustPageCountMemo();
      Future<List<IllustLibraryEntry>> load() async {
        // 模拟 `_loadIllust`：重建条目 → 回填页数 → 补齐
        return _runPageFlow(
          memo.apply(<IllustLibraryEntry>[plain('pixiv1')]),
          needPageCount: true,
          resolveCoverPath: (_) async => '/tmp/cover.jpg',
          readHead: (_, __) async => _coverHeader(_realWidth, _realHeight),
          listDirectory: (_) async => _onePageWithCover,
          pageCountMemo: memo,
        );
      }

      final first = await load();
      expect(first.single.pageCount, 1);
      // 第二次：条目是新实例（页数 null），但记忆把它填回来了
      final second = await load();
      expect(second.single.pageCount, 1);
      expect(second.single.width, _realWidth);
    });
  });

  group('有界读文件头 readFileHeadBytes', () {
    test('只读前 maxBytes 字节（不整读大文件）', () async {
      final dir = await Directory.systemTemp.createTemp('pk_head_read');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}big.bin');
      await file.writeAsBytes(
        Uint8List.fromList(List<int>.generate(5000, (i) => i % 251)),
      );

      final head = await readFileHeadBytes(file.path, 100);
      expect(head, isNotNull);
      expect(head!.length, 100);
      expect(head[7], 7);
    });

    test('文件比上限短时返回全部', () async {
      final dir = await Directory.systemTemp.createTemp('pk_head_short');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}small.bin');
      await file.writeAsBytes(Uint8List.fromList(<int>[1, 2, 3]));
      final head = await readFileHeadBytes(file.path, 4096);
      expect(head, <int>[1, 2, 3]);
    });

    test('不存在的路径 → null（且不抛异常）', () async {
      expect(await readFileHeadBytes('/definitely/not/here.jpg', 64), isNull);
    });

    test('maxBytes <= 0 → null', () async {
      final dir = await Directory.systemTemp.createTemp('pk_head_zero');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}a.bin');
      await file.writeAsBytes(Uint8List.fromList(<int>[1, 2, 3]));
      expect(await readFileHeadBytes(file.path, 0), isNull);
    });

    test('真实文件：读到头就能解析出尺寸（端到端串起来）', () async {
      final dir = await Directory.systemTemp.createTemp('pk_head_png');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}cover.png');
      await file.writeAsBytes(_coverHeader(_realWidth, _realHeight));

      final head = await readFileHeadBytes(file.path, illustHeaderReadBytes);
      expect(head, isNotNull);
      expect(parseImageHeaderSize(head!),
          const ImageHeaderSize(_realWidth, _realHeight));
      expect(await readFileStamp(file.path), startsWith('m'));
    });

    test('readFileStamp 对不存在的文件返回 null', () async {
      expect(await readFileStamp('/definitely/not/here.jpg'), isNull);
    });
  });
}

