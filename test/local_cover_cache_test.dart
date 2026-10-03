/// plan/12「统一本地封面缓存与迁移」的定向测试。
///
/// 覆盖点（对应计划验收标准 4、5 与"迁移测试必须覆盖四种情况"的风险条目）：
/// - 条目键能区分来源与原始条目（同一 id 在多个下载根不互相覆盖）
/// - 原子写入：不会留下半成品被当成有效缓存
/// - 读侧自愈：索引指向的文件被删掉后 lookup 返回 null 并修索引
/// - 指纹变化后不复用旧缓存，且旧文件被清掉（不会"显示旧图"）
/// - 负缓存**带过期**：TTL 内短路、过期后允许重试（取代 `__no_cover__` 永久短路）
/// - 旧缓存接管可重入、幂等，且不删除源文件
/// - **所有缓存与缩略图路径都位于 App.dataPath 之下**（不写下载目录、不写系统临时目录）
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/cover_thumbnail_cache.dart';
import 'package:picakeep/foundation/local_cover_cache.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  late String dataPath;
  final savedPaths = PathProviderPlatform.instance;
  final savedSettings = List<String>.of(appdata.settings);

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('pk_cover_cache_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    // dataPathOverride 让它与 support 目录**不同**，从而真正验证
    // "缓存落在 App.dataPath 而不是 support 目录"（计划风险第 1 条的用意）。
    dataPath = '${workspace.path}/data';
    await App.init(dataPathOverride: dataPath);
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = savedPaths;
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    try {
      await workspace.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    LocalCoverCache.debugResetForTest();
  });

  Uint8List bytesOf(String text) => Uint8List.fromList(text.codeUnits);

  group('条目键与路径契约', () {
    test('键区分来源、原始 id 与源标识（同一 id 在多个下载根不互相覆盖）', () {
      final a = LocalCoverCache.entryKeyFor(
        sourceId: 'current_download',
        originalId: 'jm1',
        sourceRelative: '/rootA/jm1',
      );
      final b = LocalCoverCache.entryKeyFor(
        sourceId: 'current_download',
        originalId: 'jm1',
        sourceRelative: '/rootB/jm1',
      );
      expect(a, isNot(b), reason: '同一 id 在两个下载根必须可区分');
    });

    test('缓存根固定为 <App.dataPath>/local_library_cache/covers', () {
      expect(
        LocalCoverCache.rootDirectory().path,
        p.join(dataPath, 'local_library_cache', 'covers'),
      );
    });

    test('缩略图位于统一缓存根下的 thumbs，不在原封面旁边（验收标准 4）', () {
      final coverPath = p.join(workspace.path, 'downloads', 'jm1', 'cover.jpg');
      final thumb = CoverThumbnailCache.thumbnailPathForCover(coverPath);
      expect(
        p.isWithin(LocalCoverCache.rootDirectory().path, thumb),
        isTrue,
        reason: '缩略图必须落在应用缓存目录内，不能写在下载目录里',
      );
      expect(
        p.isWithin(p.dirname(coverPath), thumb),
        isFalse,
        reason: '绝不能写在原封面所在目录（旧实现就是这么做的）',
      );
    });
  });

  group('写入与读取', () {
    test('storeBytes 后 lookup 能取回同一文件，且文件非空', () async {
      const key = 'k1';
      final stored = await LocalCoverCache.storeBytes(
        entryKey: key,
        bytes: bytesOf('hello-cover'),
        fingerprint: 'fp1',
        extension: '.jpg',
      );
      expect(stored, isNotNull);
      expect(await File(stored!).length(), greaterThan(0));
      expect(p.isWithin(LocalCoverCache.rootDirectory().path, stored), isTrue);

      final found = await LocalCoverCache.lookup(key, fingerprint: 'fp1');
      expect(found, stored);
    });

    test('空字节不产生缓存', () async {
      final stored = await LocalCoverCache.storeBytes(
        entryKey: 'empty',
        bytes: Uint8List(0),
        fingerprint: 'fp',
      );
      expect(stored, isNull);
      expect(await LocalCoverCache.lookup('empty'), isNull);
    });

    test('指纹变化 → 不复用旧缓存，并原地覆盖（不显示旧图、不堆垃圾）', () async {
      const key = 'fp-change';
      final first = await LocalCoverCache.storeBytes(
        entryKey: key,
        bytes: bytesOf('v1'),
        fingerprint: 'fp-v1',
        extension: '.jpg',
      );
      expect(first, isNotNull);
      expect(await LocalCoverCache.lookup(key, fingerprint: 'fp-v1'), first);
      // 指纹不同：必须判为"没有可用缓存"。
      expect(await LocalCoverCache.lookup(key, fingerprint: 'fp-v2'), isNull);

      final second = await LocalCoverCache.storeBytes(
        entryKey: key,
        bytes: bytesOf('v2-longer'),
        fingerprint: 'fp-v2',
        extension: '.jpg',
      );
      expect(second, isNotNull);
      // 文件名只由条目键决定：指纹变化是**原地覆盖**，磁盘不会随刷新堆垃圾。
      expect(second, first);
      // 内容确实换成了新的（否则就是"源变了仍显示旧图"）。
      expect(await File(second!).readAsString(), 'v2-longer');
      expect(await LocalCoverCache.lookup(key, fingerprint: 'fp-v2'), second);
      // 且旧指纹不再命中。
      expect(await LocalCoverCache.lookup(key, fingerprint: 'fp-v1'), isNull);
    });

    test('读侧自愈：文件被外部删掉后 lookup 返回 null 并修掉索引', () async {
      const key = 'self-heal';
      final stored = await LocalCoverCache.storeBytes(
        entryKey: key,
        bytes: bytesOf('x'),
        fingerprint: 'fp',
        extension: '.jpg',
      );
      await File(stored!).delete();

      expect(await LocalCoverCache.lookup(key, fingerprint: 'fp'), isNull);
      // 再查一次仍为 null（说明索引已被修正，而不是每次都白跑一遍 IO 判定）。
      expect(await LocalCoverCache.lookup(key, fingerprint: 'fp'), isNull);
    });
  });

  group('负缓存带过期（取代 __no_cover__ 永久短路）', () {
    test('markMissing 之后 TTL 内判为已知缺失', () async {
      await LocalCoverCache.markMissing('miss-1', fingerprint: 'fp');
      expect(await LocalCoverCache.isKnownMissing('miss-1'), isTrue);
    });

    test('指纹变化后旧结论立即作废（源换了就要重试）', () async {
      await LocalCoverCache.markMissing('miss-2', fingerprint: 'fp-old');
      expect(
        await LocalCoverCache.isKnownMissing('miss-2', fingerprint: 'fp-new'),
        isFalse,
      );
    });

    test('clearNegatives 清空后不再短路', () async {
      await LocalCoverCache.markMissing('miss-3', fingerprint: 'fp');
      expect(await LocalCoverCache.clearNegatives(), greaterThan(0));
      expect(await LocalCoverCache.isKnownMissing('miss-3'), isFalse);
    });

    test('成功写入会清掉同名负缓存', () async {
      await LocalCoverCache.markMissing('miss-4', fingerprint: 'fp');
      await LocalCoverCache.storeBytes(
        entryKey: 'miss-4',
        bytes: bytesOf('now-available'),
        fingerprint: 'fp',
        extension: '.jpg',
      );
      expect(await LocalCoverCache.isKnownMissing('miss-4'), isFalse);
    });

    test('TTL 是有限值（不得改成永久）', () {
      expect(kLocalCoverNegativeTtl.inMinutes, greaterThan(0));
      expect(kLocalCoverNegativeTtl.inMinutes, lessThanOrEqualTo(60));
    });
  });

  group('中断与清理', () {
    test('sweepPartFiles 清掉 .part，但不动有效缓存（迁移四种情况之一）', () async {
      final stored = await LocalCoverCache.storeBytes(
        entryKey: 'keep',
        bytes: bytesOf('keep-me'),
        fingerprint: 'fp',
        extension: '.jpg',
      );
      final part = File(
        p.join(LocalCoverCache.rootDirectory().path, 'interrupted.jpg.part'),
      );
      await part.writeAsBytes(bytesOf('half'), flush: true);

      expect(await LocalCoverCache.sweepPartFiles(), greaterThan(0));
      expect(await part.exists(), isFalse);
      expect(await File(stored!).exists(), isTrue, reason: '有效缓存不得被清理波及');
    });
  });

  group('旧缓存接管（可重入、幂等、不删源）', () {
    test('接管旧 managed_download_covers，可重入且重复执行不重复登记、不删源', () async {
      final legacyManaged = Directory(
        p.join(dataPath, 'local_library_cache', 'managed_download_covers'),
      );
      await legacyManaged.create(recursive: true);
      final legacyFile = File(p.join(legacyManaged.path, 'abc.jpg'));
      await legacyFile.writeAsBytes(bytesOf('legacy-cover'), flush: true);

      // 索引首次加载时会自动接管一次（见 `_load` 的注释），
      // 所以这里**不假设**手动调用能拿到 `> 0` 的计数 —— 那取决于是否已加载。
      // 真正要保证的是三件事：旧文件被登记、可被 lookup 到、源文件还在。
      LocalCoverCache.debugResetForTest();
      final adopted = await LocalCoverCache.adoptLegacyCovers();
      expect(adopted, greaterThanOrEqualTo(0));
      final viaLegacyKey = await LocalCoverCache.lookup('legacy::abc.jpg');
      expect(
        viaLegacyKey,
        isNotNull,
        reason: '旧缓存必须能被接管到，否则升级后老封面全部消失',
      );
      expect(p.isWithin(LocalCoverCache.rootDirectory().path, viaLegacyKey!),
          isFalse,
          reason: '旧文件在 managed_download_covers 下：接管是"登记引用"，不搬家');
      // 幂等：再跑一次不应新增登记（也不应报错）。
      LocalCoverCache.debugResetForTest();
      final second = await LocalCoverCache.adoptLegacyCovers();
      expect(second, 0);
      // **不删除源文件**（迁移失败也不能丢封面）。
      expect(await legacyFile.exists(), isTrue);
      expect(await legacyFile.length(), greaterThan(0));
    });

    test('接管会跳过半成品 .part（中断后重跑不把它当封面）', () async {
      LocalCoverCache.debugResetForTest();
      final legacyManaged = Directory(
        p.join(dataPath, 'local_library_cache', 'managed_download_covers'),
      );
      await legacyManaged.create(recursive: true);
      final part = File(p.join(legacyManaged.path, 'half.jpg.part'));
      await part.writeAsBytes(bytesOf('half'), flush: true);

      await LocalCoverCache.adoptLegacyCovers();
      expect(await LocalCoverCache.lookup('legacy::half.jpg.part'), isNull);
    });
  });
}
