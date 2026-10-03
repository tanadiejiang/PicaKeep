import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/illust_cover_size.dart';
import 'package:picakeep/foundation/illust_page_count_cache.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/foundation/privileged_storage_access.dart';

IllustLibraryEntry _entry({String path = '/work', int? pageCount}) =>
    buildIllustEntries([
      LocalLibraryComicItem(
        itemId: 'local_download::pixiv1',
        originalId: 'pixiv1',
        type: DownloadType.other,
        name: '作品',
        subTitle: '作者',
        tags: [],
        sourceDisplayName: 'Pixiv',
        fileSystemPath: path,
        episodeFiles: {
          0: ['partial.jpg']
        },
        downloadedEps: [0],
        eps: ['全部'],
        localCoverPath: null,
        localStorageExists: true,
        canDelete: false,
        aliases: [],
        sourceRowJson: jsonEncode({
          'sourceKey': 'pixiv',
          'width': 600,
          'height': 800,
          'pageCount': pageCount
        }),
      )
    ]).single;

LocalDirectoryEntry _child(String parent, String name,
        {bool directory = false}) =>
    LocalDirectoryEntry(
        name: name, path: '$parent/$name', isDirectory: directory);

Future<int?> _count(IllustLibraryEntry entry, IllustPageCountCache cache,
        IllustDirectoryLister list,
        {IllustPageCountStampReader? stamp}) async =>
    (await resolveIllustEntryInfo(
            entries: [entry],
            needPageCount: true,
            resolveCoverPath: (_) async =>
                throw StateError('DB has dimensions'),
            listDirectory: list,
            cache: IllustCoverSizeCache.inMemory(),
            pageCountCache: cache,
            readCountStamp: stamp ?? (_) async => 'v1'))[entry.id]
        ?.pageCount;

void main() {
  test('下载数据库已知页数直接使用，不读目录或不完整 episodeFiles', () async {
    expect(
        await _count(_entry(pageCount: 2), IllustPageCountCache.inMemory(),
            (_) async => throw StateError('must not list')),
        2);
  });

  test('旧作品支持一层章节目录，排除封面且不递归更深目录', () async {
    final visited = <String>[];
    final count =
        await _count(_entry(), IllustPageCountCache.inMemory(), (path) async {
      visited.add(path);
      if (path == '/work') {
        return [_child(path, 'cover.jpg'), _child(path, '0', directory: true)];
      }
      if (path == '/work/0') {
        return [
          _child(path, '1.jpg'),
          _child(path, '2.png'),
          _child(path, 'cover.jpg'),
          _child(path, 'nested', directory: true)
        ];
      }
      throw StateError('unexpected recursive scan');
    });
    expect(count, 2);
    expect(visited, ['/work', '/work/0']);
  });

  test('成功缓存跨进程恢复；章节变更、路径迁移和显式清除会失效', () async {
    final dir = await Directory.systemTemp.createTemp('page-count-56-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/counts.json');
    final cache = IllustPageCountCache.atFile(file);
    final stamps = {'/work': 'root1', '/work/0': 'child1'};
    final entry = _entry();
    cache.store(entry, 2, stamps, generation: cache.generation);
    await cache.save();
    final reopened = IllustPageCountCache.atFile(file);
    final hydrated = await hydrateIllustPageCounts([entry],
        cache: reopened, readStamp: (path) async => stamps[path]);
    expect(hydrated.single.pageCount, 2);
    expect(
        await reopened.lookup(_entry(path: '/other'),
            readStamp: (path) async => stamps[path]),
        isNull);
    stamps['/work/0'] = 'child2';
    expect(
        await reopened.lookup(entry, readStamp: (path) async => stamps[path]),
        isNull);
    reopened.store(entry, 3, stamps, generation: reopened.generation);
    final staleGeneration = reopened.generation;
    await reopened.clear();
    reopened.store(entry, 2, stamps, generation: staleGeneration);
    expect(
        await reopened.lookup(entry, readStamp: (path) async => stamps[path]),
        isNull);
  });

  test('warm hit只验证依赖戳，不重新枚举作品目录', () async {
    final entry = _entry(), cache = IllustPageCountCache.inMemory();
    var lists = 0;
    Future<List<LocalDirectoryEntry>> list(String path) async {
      lists++;
      return [_child(path, '1.jpg'), _child(path, '2.jpg')];
    }

    expect(await _count(entry, cache, list), 2);
    expect(await _count(entry, cache, list), 2);
    expect(lists, 1);
  });

  test('子目录读取被拒绝时不发布或缓存部分页数', () async {
    final cache = IllustPageCountCache.inMemory();
    var denied = true;
    Future<List<LocalDirectoryEntry>> list(String path) async {
      if (path == '/work') return [_child(path, '0', directory: true), _child(path, '1', directory: true)];
      if (path == '/work/1' && denied) return [];
      return [_child(path, '1.jpg')];
    }
    expect(await _count(_entry(), cache, list), isNull);
    denied = false;
    expect(await _count(_entry(), cache, list), 2);
  });

  test('失败和无可靠戳不会长期缓存；权限恢复后可重新成功统计', () async {
    final entry = _entry(), cache = IllustPageCountCache.inMemory();
    var attempt = 0;
    Future<List<LocalDirectoryEntry>> list(String path) async {
      attempt++;
      if (attempt == 1) throw const FileSystemException('denied');
      return [_child(path, '1.jpg'), _child(path, '2.jpg')];
    }

    expect(await _count(entry, cache, list), isNull);
    expect(await _count(entry, cache, list, stamp: (_) async => null), 2);
    expect(await _count(entry, cache, list, stamp: (_) async => null), 2);
    expect(attempt, 3);
  });

  test('统计过程中替换来源不发布不一致结果', () async {
    var reads = 0;
    expect(
        await _count(_entry(), IllustPageCountCache.inMemory(),
            (path) async => [_child(path, '1.jpg')],
            stamp: (_) async => 'v${reads++}'),
        isNull);
  });

  test('首帧回填不对未知条目做 stat', () async {
    final entries = [_entry(), _entry(path: '/other')];
    final result = await hydrateIllustPageCounts(entries,
        cache: IllustPageCountCache.inMemory(),
        readStamp: (_) async => throw StateError('no cache => no IO'));
    expect(result, entries);
  });
}
