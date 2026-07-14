import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/pages/local_comic_detail_page.dart';
import 'package:picakeep/tools/tags_translation.dart';

LocalDetailTagDisplayGroup _groupFor(
  List<LocalDetailTagDisplayGroup> groups,
  String namespace,
) {
  return groups.singleWhere((group) => group.rawNamespace == namespace);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Local detail source-aware tag display', () {
    test('EH splits only the first colon and preserves original search fields',
        () async {
      final beforeLoad = buildLocalDetailTagDisplayGroups(
        source: DownloadType.ehentai,
        flatTags: const ['female:fox girl', 'unknown:value:with:colon'],
        languageCode: 'zh',
      );
      final beforeFox = _groupFor(beforeLoad, 'female').values.single;
      expect(beforeFox.displayText, 'fox girl');
      expect(beforeFox.rawText, 'female:fox girl');
      expect(beforeFox.rawNamespace, 'female');
      expect(beforeFox.rawValue, 'fox girl');

      await loadTagTranslations();
      final groups = buildLocalDetailTagDisplayGroups(
        source: DownloadType.ehentai,
        flatTags: const ['female:fox girl', 'unknown:value:with:colon'],
        languageCode: 'zh',
      );

      final female = _groupFor(groups, 'female');
      expect(female.displayName, '女性');
      expect(female.values.single.displayText, '狐女');

      final unknown = _groupFor(groups, 'unknown');
      expect(unknown.displayName, 'unknown');
      expect(unknown.values.single.displayText, 'value:with:colon');
      expect(unknown.values.single.rawText, 'unknown:value:with:colon');
      expect(unknown.values.single.rawValue, 'value:with:colon');
    });

    test('non-Chinese EH details keep original namespace and value text', () {
      final groups = buildLocalDetailTagDisplayGroups(
        source: DownloadType.ehentai,
        flatTags: const ['female:fox girl', 'parody:azur lane'],
        languageCode: 'en',
      );

      final female = _groupFor(groups, 'female');
      expect(female.displayName, 'female');
      expect(female.values.single.displayText, 'fox girl');
      expect(female.values.single.rawText, 'female:fox girl');
      expect(
          _groupFor(groups, 'parody').values.single.displayText, 'azur lane');
    });

    test('Chinese EH translates parody values and preserves gender suffixes',
        () async {
      await loadTagTranslations();
      final groups = buildLocalDetailTagDisplayGroups(
        source: DownloadType.ehentai,
        flatTags: const [
          'parody:azur lane',
          'female:unmapped suffix ♀',
          'male:unmapped suffix ♂',
        ],
        languageCode: 'zh',
      );

      expect(_groupFor(groups, 'parody').displayName, '原作');
      expect(_groupFor(groups, 'parody').values.single.displayText, '碧蓝航线');
      expect(
        _groupFor(groups, 'female').values.single.displayText,
        'unmapped suffix ♀',
      );
      expect(
        _groupFor(groups, 'male').values.single.displayText,
        'unmapped suffix ♂',
      );
    });

    test('unknown namespaces keep their category while sharing value fallback',
        () async {
      await loadTagTranslations();
      final groups = buildLocalDetailTagDisplayGroups(
        source: DownloadType.ehentai,
        flatTags: const ['unknown:fox girl'],
        languageCode: 'zh',
      );

      final unknown = _groupFor(groups, 'unknown');
      expect(unknown.displayName, 'unknown');
      // 与在线详情完全一致：tagTranslateWithNs 为 NH 的 Tags 桶跨分类回退，
      // 因此已知 value 仍可翻译；未知 namespace 标题本身保持原样。
      expect(unknown.values.single.displayText, '狐女');
      expect(unknown.values.single.rawText, 'unknown:fox girl');
    });

    test(
        'NH categorized tags take priority and translate both bucket and value',
        () async {
      await loadTagTranslations();
      final groups = buildLocalDetailTagDisplayGroups(
        source: DownloadType.nhentai,
        flatTags: const ['female:flat duplicate', 'flat-only'],
        categorizedTags: const {
          'Parodies': ['azur lane'],
          'Tags': ['fox girl'],
        },
        languageCode: 'zh',
      );

      expect(
        groups.map((group) => group.rawNamespace).toList(),
        ['Parodies', 'Tags'],
      );
      final parody = _groupFor(groups, 'Parodies');
      expect(parody.displayName, '原作');
      expect(parody.values.single.displayText, '碧蓝航线');
      expect(parody.values.single.rawText, 'azur lane');
      expect(parody.values.single.rawNamespace, 'Parodies');

      final tags = _groupFor(groups, 'Tags');
      expect(tags.displayName, '标签');
      expect(tags.values.single.displayText, '狐女');
      expect(
        groups.expand((group) => group.values).map((value) => value.rawText),
        isNot(contains('female:flat duplicate')),
      );
      expect(
        groups.expand((group) => group.values).map((value) => value.rawText),
        isNot(contains('flat-only')),
      );
    });

    test('NH empty categorized buckets fall back to legacy flat tags',
        () async {
      await loadTagTranslations();
      final groups = buildLocalDetailTagDisplayGroups(
        source: DownloadType.nhentai,
        flatTags: const ['female:fox girl'],
        categorizedTags: const {'Tags': []},
        languageCode: 'zh',
      );

      final female = _groupFor(groups, 'female');
      expect(female.displayName, '女性');
      expect(female.values.single.displayText, '狐女');
      expect(female.values.single.rawText, 'female:fox girl');
    });

    test('legacy NH flat tags remain visible and namespace-aware', () async {
      await loadTagTranslations();
      final groups = buildLocalDetailTagDisplayGroups(
        source: DownloadType.nhentai,
        flatTags: const ['character:asanagi', 'plain tag'],
        languageCode: 'zh',
      );

      final character = _groupFor(groups, 'character');
      expect(character.displayName, '角色');
      expect(character.values.single.displayText, '朝凪');
      expect(character.values.single.rawText, 'character:asanagi');
      expect(_groupFor(groups, '').values.single.displayText, 'plain tag');
    });

    test('non-EH/NH sources keep their flat labels unchanged', () {
      final groups = buildLocalDetailTagDisplayGroups(
        source: DownloadType.jm,
        flatTags: const ['female:fox girl'],
        languageCode: 'zh',
      );

      expect(groups, hasLength(1));
      expect(groups.single.displayName, '标签');
      expect(groups.single.values.single.displayText, 'female:fox girl');
      expect(groups.single.values.single.rawText, 'female:fox girl');
    });

    test('translation policy only enables EH/NH in Chinese locales', () {
      expect(
        shouldTranslateLocalDetailTags(DownloadType.ehentai, 'zh'),
        isTrue,
      );
      expect(
        shouldTranslateLocalDetailTags(DownloadType.nhentai, 'zh'),
        isTrue,
      );
      expect(
        shouldTranslateLocalDetailTags(DownloadType.ehentai, 'en'),
        isFalse,
      );
      expect(
        shouldTranslateLocalDetailTags(DownloadType.jm, 'zh'),
        isFalse,
      );
    });
  });
}
