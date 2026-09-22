import 'package:picakeep/network/jm_network/jm_parsing.dart';
import 'package:test/test.dart';

Map<String, Object?> _comic(int id) => {
      'id': id,
      'name': 'Sample $id',
      'description': 'Sample description',
    };

void main() {
  const host = 'https://covers.example';
  String coverUrl(String id) => '$host/media/albums/${id}_3x4.jpg';

  test('JM 推荐各分区将封面域注入到条目，不生成空封面', () {
    final sections = parseJmPromoteSections(
      [
        {
          'title': 'Featured',
          'type': 'promote',
          'id': 7,
          'content': [_comic(101), _comic(102)],
        },
        {
          'title': 'Category',
          'type': 'category_id',
          'slug': 'sample',
          'content': [_comic(103)],
        },
      ],
      coverUrlBuilder: coverUrl,
    );

    expect(
      sections.expand((section) => section.comics).map((comic) => comic.cover),
      [coverUrl('101'), coverUrl('102'), coverUrl('103')],
    );
  });

  test('JM 推荐更多保留封面，同时按原始记录计数推进分页', () {
    final page = parseJmPromoteList(
      '7',
      {
        'total': 8,
        'list': [
          _comic(201),
          {'id': null},
          _comic(202)
        ],
      },
      page: 1,
      coverUrlBuilder: coverUrl,
    );

    expect(page.comics.map((comic) => comic.cover),
        [coverUrl('201'), coverUrl('202')]);
    expect(page.loaded, 3);
    expect(page.hasMore, isTrue);
  });

  for (final field in ['list', 'content']) {
    test('JM 每周推荐 $field 容器同时保留封面与简介', () {
      final comics = parseJmWeekComics(
        {
          field: [_comic(301)],
        },
        coverUrlBuilder: coverUrl,
      );

      expect(comics.single.cover, coverUrl('301'));
      expect(comics.single.desc, 'Sample description');
    });
  }
}
