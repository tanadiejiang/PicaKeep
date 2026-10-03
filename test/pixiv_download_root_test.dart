/// Pixiv 下载根的解析契约（36 号）。
///
/// ## 背景
///
/// 用户要求 Pixiv 的下载内容"别再裸露在 `download` 里"，改为放在同级的
/// `download_pixiv`。这里钉住三条最容易在重构里被改回原样的性质：
///
/// 1. 默认位置与「本应用下载目录」**同级**（父目录相同）；
/// 2. `settings[152]` 为空 = 用默认位置（**不再**是"跟随 download"）；
/// 3. 旧根仍然是 `download` —— 迁移功能靠它找老内容，改错了就一条都搬不动。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/pixiv_download_naming.dart';
import 'package:picakeep/foundation/pixiv_download_root.dart';

/// `App.init` 会走 path_provider 取 cache / support 目录，
/// 测试里必须换成临时目录（否则 `MissingPluginException`）。
class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final Directory root;

  Future<String> _dir(String name) async =>
      (await Directory(p.join(root.path, name)).create(recursive: true)).path;

  @override
  Future<String?> getApplicationCachePath() => _dir('cache');

  @override
  Future<String?> getApplicationSupportPath() => _dir('support');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  late List<String> savedSettings;
  late PathProviderPlatform savedPaths;

  setUpAll(() async {
    savedSettings = List.of(appdata.settings);
    savedPaths = PathProviderPlatform.instance;
    workspace = await Directory.systemTemp.createTemp('picakeep_pixiv_root_');
    PathProviderPlatform.instance = _Paths(workspace);
    await App.init(dataPathOverride: p.join(workspace.path, 'data'));
  });

  tearDownAll(() async {
    appdata.settings
      ..clear()
      ..addAll(savedSettings);
    PathProviderPlatform.instance = savedPaths;
    try {
      await workspace.delete(recursive: true);
    } catch (_) {}
  });

  test('默认根与「本应用下载目录」同级，目录名是 download_pixiv', () {
    final path = defaultPixivDownloadPath();
    expect(p.basename(path), kDefaultPixivDownloadDirName);
    expect(kDefaultPixivDownloadDirName, 'download_pixiv');
    // "同级" = 父目录就是应用数据目录本身（`download` 也在那一层）。
    expect(p.dirname(path), App.dataPath);
    expect(path, '${App.dataPath}${Platform.pathSeparator}download_pixiv');
  });

  test('settings[152] 为空 → 生效值是默认位置（不再跟随 download）', () {
    appdata.settings[pixivDownloadDirSettingIndex] = '';
    expect(effectivePixivDownloadRoot(), defaultPixivDownloadPath());
    expect(pixivDownloadRootIsDefault(), isTrue);
    // 关键回归：默认根**不等于**旧根，否则 Pixiv 又会混进 download 里。
    expect(effectivePixivDownloadRoot(), isNot(legacyPixivDownloadPath()));
  });

  test('只有空白也算"用默认"（写入侧可能留下脏值）', () {
    appdata.settings[pixivDownloadDirSettingIndex] = '   ';
    expect(effectivePixivDownloadRoot(), defaultPixivDownloadPath());
    expect(pixivDownloadRootIsDefault(), isTrue);
  });

  test('settings[152] 非空 → 以用户指定的位置为准', () {
    appdata.settings[pixivDownloadDirSettingIndex] = '/custom/pixiv';
    expect(effectivePixivDownloadRoot(), '/custom/pixiv');
    expect(pixivDownloadRootIsDefault(), isFalse);
  });

  test('旧根就是默认下载目录（36 号之前 Pixiv 落在这里）', () {
    expect(
      legacyPixivDownloadPath(),
      '${App.dataPath}${Platform.pathSeparator}download',
    );
  });

  group('pixivRelocationSourceRoots · 归位要检查哪些源根', () {
    test('只设了默认根时：候选就是默认根，且不含生效的 Pixiv 根', () {
      appdata.settings[pixivDownloadDirSettingIndex] = '';
      appdata.settings[22] = '';
      final roots = pixivRelocationSourceRoots();
      expect(roots, contains(legacyPixivDownloadPath()));
      expect(
        roots,
        isNot(contains(effectivePixivDownloadRoot())),
        reason: '不把自己当归位源，否则会自己搬自己',
      );
    });

    test('回归：自定义下载目录里的 Pixiv 也要被数到（真机踩过）', () {
      // 真机经过：下载目录还是默认根时下了 Pixiv → 之后改到自定义位置 →
      // "换下载目录"的迁移把 Pixiv 一起搬了过去 ⇒ 它在 settings[22] 里。
      // 只查默认根会**永远数不到、也搬不走**（用户反馈"怎么还是丢在这里"）。
      appdata.settings[pixivDownloadDirSettingIndex] = '';
      appdata.settings[22] = '/custom/downloads';
      expect(pixivRelocationSourceRoots(), contains('/custom/downloads'));
    });

    test('生效的 Pixiv 根自身永远不在源根里', () {
      appdata.settings[22] = '/custom/downloads';
      appdata.settings[pixivDownloadDirSettingIndex] = '/custom/downloads';
      final roots = pixivRelocationSourceRoots();
      expect(roots, isNot(contains('/custom/downloads')));
      // 默认根仍然要在（它跟 Pixiv 根不是同一个）。
      expect(roots, contains(legacyPixivDownloadPath()));
    });

    test('settings[22] 有脏值（空白）时不会混进一个空串源根', () {
      appdata.settings[22] = '   ';
      appdata.settings[pixivDownloadDirSettingIndex] = '';
      expect(
        pixivRelocationSourceRoots().where((root) => root.trim().isEmpty),
        isEmpty,
      );
    });

    test('回归：Pixiv 默认位置也要算源根（用户改过 settings[152] 时）', () {
      // `settings[152]` 为空时生效根 = 默认位置；一旦用户把它设到别处，
      // 之前落在默认位置的那些就**扫描不到了** —— 既不属于当前下载目录、
      // 也不属于新的 Pixiv 根（真机实证：`files/download_pixiv` 里躺着 3 张）。
      appdata.settings[22] = '/custom/downloads';
      appdata.settings[pixivDownloadDirSettingIndex] = '/custom/pixiv';
      expect(
        pixivRelocationSourceRoots(),
        contains(defaultPixivDownloadPath()),
      );
    });

    test('生效根恰好是默认位置时，默认位置不再作为源根（避免自己搬自己）', () {
      appdata.settings[22] = '';
      appdata.settings[pixivDownloadDirSettingIndex] = '';
      expect(
        pixivRelocationSourceRoots(),
        isNot(contains(defaultPixivDownloadPath())),
      );
      expect(pixivRelocationSourceRoots(), contains(legacyPixivDownloadPath()));
    });
  });
}
