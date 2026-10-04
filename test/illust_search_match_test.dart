/// 插画搜索的关键词匹配（19 号）：标题 / 作者恒匹配，标签按开关可选。
///
/// 抽成纯函数的原因与 `filterIllustEntriesByTags` 一致：这条判据错了不会抛异常，
/// 只会"搜不到东西"或"搜出不该有的东西"，必须由测试盯住，而不是靠肉眼看 UI。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';

/// 造一条插画条目（字段形态与 `test/local_library_illust_view_test.dart` 的辅助一致）。
IllustLibraryEntry _entry({
  required String id,
  String name = '作品',
  String author = '作者',
  List<String> tags = const <String>[],
}) {
  return IllustLibraryEntry(
    item: LocalLibraryComicItem(
      itemId: 'local_download::current_download::$id',
      originalId: id,
      type: DownloadType.other,
      name: name,
      subTitle: author,
      tags: tags,
      sourceDisplayName: 'Pixiv',
      fileSystemPath: '/tmp/$id',
      episodeFiles: const <int, List<String>>{},
      downloadedEps: const <int>[0],
      eps: const <String>['全部'],
      localCoverPath: null,
      localStorageExists: true,
      canDelete: false,
      aliases: <String>[id],
      sourceRowJson: '{}',
    ),
    aspectRatio: 3 / 4,
    tags: tags,
    width: 1000,
    height: 1400,
  );
}

void main() {
  group('空关键词 = 未筛选', () {
    test('空串与纯空白都恒命中（开关打开时也一样）', () {
      final entry = _entry(id: 'pixiv1', tags: const ['风景']);
      expect(illustEntryMatchesKeyword(entry, ''), isTrue);
      expect(illustEntryMatchesKeyword(entry, '   '), isTrue);
      expect(illustEntryMatchesKeyword(entry, '', matchTags: true), isTrue);
    });
  });

  group('开关关闭（默认）：只匹配标题与作者', () {
    final entry = _entry(
      id: 'pixiv1',
      name: '夏日的口袋',
      author: 'Vodyanitsa',
      tags: const ['Genshin Impact', '白裤袜'],
    );

    test('命中标题，大小写不敏感', () {
      expect(illustEntryMatchesKeyword(entry, '夏日'), isTrue);
      expect(
        illustEntryMatchesKeyword(
            _entry(id: 'pixiv2', name: 'SummerPockets'), 'summerpockets'),
        isTrue,
      );
    });

    test('命中作者，大小写不敏感', () {
      expect(illustEntryMatchesKeyword(entry, 'vodyanitsa'), isTrue);
      expect(illustEntryMatchesKeyword(entry, 'VODY'), isTrue);
    });

    test('只命中标签不算命中', () {
      expect(illustEntryMatchesKeyword(entry, 'genshin'), isFalse);
      expect(illustEntryMatchesKeyword(entry, '白裤袜'), isFalse);
    });

    test('毫不相关的词不命中', () {
      expect(illustEntryMatchesKeyword(entry, '不存在的词'), isFalse);
    });
  });

  group('开关打开：标签也参与（子串、大小写不敏感）', () {
    final entry = _entry(
      id: 'pixiv1',
      name: '夏日的口袋',
      author: 'Vodyanitsa',
      tags: const ['Genshin Impact', '白裤袜'],
    );

    test('标签整体命中', () {
      expect(
        illustEntryMatchesKeyword(entry, '白裤袜', matchTags: true),
        isTrue,
      );
    });

    test('标签子串命中，且大小写不敏感', () {
      expect(
        illustEntryMatchesKeyword(entry, 'genshin', matchTags: true),
        isTrue,
      );
      expect(
        illustEntryMatchesKeyword(entry, 'IMPACT', matchTags: true),
        isTrue,
      );
    });

    test('打开开关不会破坏标题 / 作者的既有命中', () {
      expect(illustEntryMatchesKeyword(entry, '夏日', matchTags: true), isTrue);
      expect(
        illustEntryMatchesKeyword(entry, 'vodyanitsa', matchTags: true),
        isTrue,
      );
    });

    test('毫无关系的词仍然不命中（不是"打开就全过"）', () {
      expect(
        illustEntryMatchesKeyword(entry, '不存在的词', matchTags: true),
        isFalse,
      );
    });
  });

  group('设置项（settings[163]，19 号）', () {
    test('下标只能追加在既有插画设置之后', () {
      expect(illustSearchMatchTagsSettingIndex, 163);
      expect(
        illustSearchMatchTagsSettingIndex,
        greaterThan(illustViewSwitcherPositionSettingIndex),
      );
    });

    test('下标真的落在 settings 数组里（漏加数组项会在这里炸）', () {
      // 只加常量、忘了往 `lib/base.dart` 的数组里补一项的话，`settings[163]`
      // 会越界 —— 而症状是启动时 readSettings 抛异常，离"加了个设置项"很远。
      expect(
        appdata.settings.length,
        greaterThan(illustSearchMatchTagsSettingIndex),
        reason: 'illustSearchMatchTagsSettingIndex 必须小于 settings 的长度',
      );
      expect(
        appdata.settings[illustSearchMatchTagsSettingIndex],
        '0',
        reason: '默认关：保持 56 号"只按标题/作者搜"的结果不变',
      );
    });

    test('归一化只认 1，其余回落 0', () {
      expect(normalizeIllustSearchMatchTags('1'), '1');
      expect(normalizeIllustSearchMatchTags('0'), '0');
      expect(normalizeIllustSearchMatchTags(null), '0');
      expect(normalizeIllustSearchMatchTags('true'), '0');
      expect(illustSearchMatchesTags('1'), isTrue);
      expect(illustSearchMatchesTags('0'), isFalse);
      expect(illustSearchMatchesTags(null), isFalse);
    });
  });
}
