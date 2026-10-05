import 'dart:convert';

import 'package:test/test.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_selection_state.dart';

const _descriptor = ExploreSourceDescriptor(
  sourceKey: 'pixiv',
  name: 'Pixiv',
  requiresLogin: false,
  entries: <ExploreEntry>[
    ExploreEntry(
      id: 'pixiv.recommended',
      label: '推荐',
      kind: ExploreSectionKind.recommend,
    ),
    ExploreEntry(
      id: 'pixiv.bookmarks',
      label: '我的收藏',
      kind: ExploreSectionKind.recommend,
    ),
    ExploreEntry(
      id: 'pixiv.ranking',
      label: '排行榜',
      kind: ExploreSectionKind.ranking,
      options: <ExploreOption>[
        ExploreOption(id: 'daily', label: '今日'),
        ExploreOption(id: 'weekly', label: '本周'),
      ],
      defaultOptionId: 'daily',
    ),
  ],
);

void main() {
  test('空值与非法 JSON 回到推荐/默认榜期', () {
    for (final raw in <String?>[null, '', '{bad']) {
      final state = selectionForDescriptor(
        sourceKey: 'pixiv',
        descriptor: _descriptor,
        raw: raw,
      );
      expect(state.kind, exploreSelectionKindRecommend);
      expect(state.entryId, 'pixiv.recommended');
      expect(state.rankingOption, 'daily');
    }
  });

  test('合法状态恢复收藏与榜期，未知值分别回退', () {
    final raw = jsonEncode({
      'version': 1,
      'bySource': {
        'pixiv': {
          'kind': 'ranking',
          'entry': 'pixiv.bookmarks',
          'rankingOption': 'weekly',
        },
      },
    });
    final state = selectionForDescriptor(
      sourceKey: 'pixiv',
      descriptor: _descriptor,
      raw: raw,
    );
    expect(state.kind, exploreSelectionKindRanking);
    expect(state.entryId, 'pixiv.ranking');
    expect(state.rankingOption, 'weekly');

    final invalid = selectionForDescriptor(
      sourceKey: 'pixiv',
      descriptor: _descriptor,
      raw: jsonEncode({
        'bySource': {
          'pixiv': {
            'kind': 'ranking',
            'entry': 'pixiv.removed',
            'rankingOption': 'removed',
          },
        },
      }),
    );
    expect(invalid.kind, exploreSelectionKindRanking);
    expect(invalid.entryId, 'pixiv.ranking');
    expect(invalid.rankingOption, 'daily');
  });

  test('更新 Pixiv 不丢失其它源，输出格式稳定', () {
    final raw = jsonEncode({
      'version': 1,
      'bySource': {
        'jm': {'kind': 'recommend', 'entry': 'jm.home'},
      },
    });
    final output = updateExploreSelectionJson(
      raw: raw,
      sourceKey: 'pixiv',
      state: const ExploreSelectionState(
        kind: exploreSelectionKindRecommend,
        entryId: 'pixiv.bookmarks',
        rankingOption: 'daily',
      ),
    );
    final decoded = jsonDecode(output) as Map<String, dynamic>;
    expect(decoded['version'], 1);
    expect(decoded['bySource']['jm']['entry'], 'jm.home');
    expect(decoded['bySource']['pixiv']['entry'], 'pixiv.bookmarks');
    expect(normalizeExploreSelectionJson(output), output);
  });
}
