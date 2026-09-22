import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_registry.dart';
import 'package:picakeep/foundation/explore/providers/jm_explore_provider.dart';
import 'package:picakeep/foundation/explore/providers/picacg_explore_provider.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';
import 'package:picakeep/network/res.dart';

JmComicBrief _jm(String id) => JmComicBrief(
    id: id, title: 'Sample', author: '', tags: const [], coverUrl: '');

class _Jm extends Fake implements JmNetwork {
  final pages = <int>[];
  final periods = <String>[];
  bool repeated = false;
  String? category;
  final categoryPages = <int>[];
  bool repeatedCategory = false;

  @override
  Future<Res<JmPromoteList>> getPromoteList(String id, int page) async {
    pages.add(page);
    return Res(JmPromoteList(
      id: id,
      comics: [_jm(repeated ? '100' : '${100 + page}')],
      total: 5,
      loaded: page < 2 ? 2 : 1,
      page: page,
    ));
  }

  @override
  Future<Res<List<JmPromoteSection>>> getPromoteSections() async => Res([
        JmPromoteSection(
            title: 'Category',
            type: 'category_id',
            id: 'sample',
            slug: 'sample',
            comics: [_jm('100')]),
        JmPromoteSection(
            title: 'Promote',
            type: 'promote',
            id: '7',
            slug: '',
            comics: [_jm('101')]),
        JmPromoteSection(
            title: 'Unknown',
            type: 'other',
            id: '8',
            slug: '',
            comics: [_jm('102')]),
      ]);

  @override
  Future<Res<List<JmComicBrief>>> getCategoryComics(
      String slug, JmComicsOrder order, int page) async {
    category = slug;
    categoryPages.add(page);
    return Res([_jm(repeatedCategory ? '200' : '${200 + page}')],
        subData: {'total': 100, 'rawCount': page == 1 ? 80 : 20});
  }

  @override
  Future<Res<List<JmWeekPeriod>>> getWeekPeriods() async => const Res([
        JmWeekPeriod(id: 'new', time: 'New period'),
        JmWeekPeriod(id: 'old', time: 'Old period'),
      ]);

  @override
  Future<Res<List<JmComicBrief>>> getWeekComics(
      String id, JmWeekType type) async {
    periods.add('$id/${type.value}');
    return Res([_jm('300')]);
  }
}

class _Pica extends Fake implements PicacgNetwork {
  int calls = 0;
  @override
  Future<Res<List<PicacgCollection>>> getCollections() async {
    calls++;
    return Res([
      PicacgCollection(title: 'Collection $calls', id: 'collection-0', comics: [
        PicacgComicItemBrief.fromApi({'_id': 'item-$calls', 'title': 'Sample'})
      ]),
    ]);
  }
}

void main() {
  late _Jm jm;
  late ExploreRegistry registry;
  late String session;

  setUp(() {
    jm = _Jm();
    registry = ExploreRegistry()
      ..register(JmExploreProvider(
        isLoggedInGetter: () => true,
        contextFingerprintGetter: () => 'test',
        network: jm,
      ));
    session = registry.createSession();
  });

  ExploreRequest request(String entry, {ExploreCategoryTarget? category}) =>
      ExploreRequest(
          sessionId: session,
          sourceKey: 'jm',
          entryId: entry,
          category: category);

  test('JM promote pages advance 0,1,2 and stop by cumulative raw records',
      () async {
    final base = request(JmExploreEntries.promoteMore,
        category: const ExploreCategoryTarget(kind: 'section', value: '7'));
    var page = (await registry.loadComics(base)).dataOrNull!;
    expect(page.items.single.id, '100');
    expect(page.hasMore, isTrue);
    page =
        (await registry.loadComics(base.copyWith(continuation: page.nextToken)))
            .dataOrNull!;
    expect(page.items.single.id, '101');
    page =
        (await registry.loadComics(base.copyWith(continuation: page.nextToken)))
            .dataOrNull!;
    expect(page.items.single.id, '102');
    expect(page.hasMore, isFalse);
    expect(jm.pages, [0, 1, 2]);
  });

  test('JM repeated promote page is an error, not infinite duplicate append',
      () async {
    jm.repeated = true;
    final base = request(JmExploreEntries.promoteMore,
        category: const ExploreCategoryTarget(kind: 'section', value: '7'));
    final first = (await registry.loadComics(base)).dataOrNull!;
    final result =
        await registry.loadComics(base.copyWith(continuation: first.nextToken));
    expect(result.errorOrNull?.code, ExploreErrorCode.parse);
  });

  test('JM category 80 + 20 raw rows ends on page two despite invalid rows',
      () async {
    final base = request(JmExploreEntries.categories,
        category: const ExploreCategoryTarget(kind: 'native', value: 'sample'));
    final first = (await registry.loadComics(base)).dataOrNull!;
    expect(first.hasMore, isTrue);
    final last = (await registry
            .loadComics(base.copyWith(continuation: first.nextToken)))
        .dataOrNull!;
    expect(last.hasMore, isFalse);
    expect(jm.categoryPages, [1, 2]);
  });

  test('JM ranking repeated terminal page stops with a parse error', () async {
    jm.repeatedCategory = true;
    final base = request(JmExploreEntries.ranking);
    final first = (await registry.loadComics(base)).dataOrNull!;
    final repeated =
        await registry.loadComics(base.copyWith(continuation: first.nextToken));
    expect(repeated.errorOrNull?.code, ExploreErrorCode.parse);
    expect(jm.category, '0');
    expect(jm.categoryPages, [1, 2]);
  });

  test(
      'JM overview category more preserves native slug and unknown has no target',
      () async {
    final sections =
        (await registry.loadOverview(request(JmExploreEntries.home)))
            .dataOrNull!
            .sections;
    expect(sections.first.moreEntryId, JmExploreEntries.categories);
    expect(sections.first.moreTarget,
        const ExploreCategoryTarget(kind: 'native', value: 'sample'));
    final result = await registry.loadComics(request(
        sections.first.moreEntryId!,
        category: sections.first.moreTarget));
    expect(result.errorOrNull, isNull);
    expect(jm.category, 'sample');
    expect(sections.last.moreEntryId, isNull);
  });

  test(
      'JM period directory opens requested old period and rejects stale period',
      () async {
    final directory =
        (await registry.loadDirectory(request(JmExploreEntries.week)))
            .dataOrNull!;
    final target = directory.groups.single.items.last.route!;
    final result = await registry.loadComics(
        request(JmExploreEntries.week, category: target)
            .copyWith(options: ExploreOptions.single('manga')));
    expect(result.errorOrNull, isNull);
    expect(jm.periods, ['old/manga']);
    final stale = await registry.loadComics(request(JmExploreEntries.week,
        category: const ExploreCategoryTarget(kind: 'week', value: 'missing')));
    expect(stale.errorOrNull?.code, ExploreErrorCode.invalidArgument);
    expect(jm.periods, hasLength(1));
  });

  test(
      'Pica old collection keeps its snapshot after reorder and parent release',
      () async {
    final pica = _Pica();
    var context = 'account-a';
    registry.register(PicacgExploreProvider(
        isLoggedInGetter: () => true,
        contextFingerprintGetter: () => context,
        network: pica));
    final base = ExploreRequest(
        sessionId: session,
        sourceKey: 'picacg',
        entryId: PicacgExploreEntries.collections);
    final first =
        (await registry.loadOverview(base)).dataOrNull!.sections.single;
    await registry.loadOverview(base);
    registry.releaseSession(session);
    final detail = ExploreRequest(
        sessionId: registry.createSession(),
        sourceKey: 'picacg',
        entryId: first.moreEntryId!,
        category: first.moreTarget);
    final result = await registry.loadComics(detail);
    expect(result.dataOrNull!.items.single.id, 'item-1');
    expect(pica.calls, 2);
    expect(
        () => first.moreTarget!.snapshotItems!.clear(), throwsUnsupportedError);
    context = 'account-b';
    final stale = await registry.loadComics(detail);
    expect(stale.errorOrNull?.code, ExploreErrorCode.invalidArgument);
  });
}
