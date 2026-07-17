import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/nhentai_network/models.dart';
import 'package:picakeep/pages/online_search/online_search_result_page.dart';

void main() {
  test('EH search briefs preserve namespace tags and operation identity', () {
    final item = EhGalleryBrief(
      'title',
      'manga',
      'time',
      'uploader',
      'cover',
      0,
      'https://e-hentai.org/g/123/abc/',
      ['artist:unknown', 'female:unknown'],
    );

    final observations = buildOnlineSearchTagObservations(
      sourceKey: 'ehentai',
      items: [item],
      operationId: 'search-1',
    );

    expect(observations, hasLength(1));
    expect(observations.single.source, 'ehentai');
    expect(observations.single.comicId, item.id);
    expect(observations.single.flatTags, item.tags);
    expect(observations.single.operationId, 'search-1');
    expect(observations.single.context, 'online-search');
  });

  test('NH search briefs retain flat tags and skip empty/non-NH items', () {
    const item = NhentaiComicBrief(
      'title',
      'cover',
      '456',
      '中文',
      ['artist name', 'unknown tag'],
    );
    const empty = NhentaiComicBrief('empty', 'cover', '789', '中文', []);

    final observations = buildOnlineSearchTagObservations(
      sourceKey: 'nhentai',
      items: [item, empty],
      operationId: 'search-2',
    );

    expect(observations, hasLength(1));
    expect(observations.single.source, 'nhentai');
    expect(observations.single.comicId, '456');
    expect(observations.single.flatTags, item.tags);
    expect(
        buildOnlineSearchTagObservations(
          sourceKey: 'jm',
          items: [item],
          operationId: 'ignored',
        ),
        isEmpty);
  });
}
