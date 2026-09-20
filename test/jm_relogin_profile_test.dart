import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/built_in/jm.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';

/// A07：JM 手动重登后的资料回填。
///
/// 网络登录本身不在这里驱动（那需要真实站点）；这里锁定的是重登成功后
/// "name/uid 与数据文件一致"以及"拿不到新值时不清空既有资料"这两条语义。

class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final String root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  final PathProviderPlatform originalPaths = PathProviderPlatform.instance;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_jm_relogin_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: '${workspace.path}/data');
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    try {
      if (await workspace.exists()) {
        await workspace.delete(recursive: true);
      }
    } catch (_) {
      // 临时目录清理失败不影响断言。
    }
  });

  group('A07 JM 重登资料回填', () {
    test('成功后 name/uid 落盘，从文件读回一致', () async {
      await ComicSource.init();
      final source = ComicSource.require('jm');
      source.data
        ..clear()
        ..addAll(<String, dynamic>{'name': '旧名字', 'uid': '111'});
      await source.saveData();

      await applyJmReloginProfile(source, name: '新名字', uid: '222');

      expect(source.data['name'], '新名字');
      expect(source.data['uid'], '222');
      expect(source.data['token'], 'logged_in');

      final fresh = ComicSource.named(key: 'jm', name: 'jm');
      await fresh.loadData();
      expect(
        fresh.data['name'],
        '新名字',
        reason: '资料必须真正落盘，而不只是改了内存',
      );
      expect(fresh.data['uid'], '222');
    });

    test('源没有返回新值时保留既有资料，不清成空', () async {
      await ComicSource.init();
      final source = ComicSource.require('jm');
      source.data
        ..clear()
        ..addAll(<String, dynamic>{'name': '真名', 'uid': '4215436'});
      await source.saveData();

      await applyJmReloginProfile(source, name: '', uid: '   ');

      expect(source.data['name'], '真名', reason: '拿不到新名字不能把已有真名清掉');
      expect(source.data['uid'], '4215436');
      expect(source.data['token'], 'logged_in');
    });

    test('落盘失败向上抛出，调用方据此不显示完整成功', () async {
      await ComicSource.init();
      final source = ComicSource.require('jm');
      var saveCalled = false;

      await expectLater(
        applyJmReloginProfile(
          source,
          name: '新名字',
          uid: '222',
          save: () async {
            saveCalled = true;
            throw StateError('disk-full');
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(saveCalled, isTrue);
    });
  });
}
