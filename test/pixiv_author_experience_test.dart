import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/pixiv_author_link.dart';
import 'package:picakeep/pages/online_comic/pixiv_author_page_v2.dart';
import 'package:picakeep/pages/online_comic/pixiv_comic_page_v2.dart';
import 'package:picakeep/pages/online_common/online_waterfall_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

PixivComicInfo _detail({String uid = '42'}) => PixivComicInfo(
      id: '123',
      title: '作品',
      author: '画师',
      authorId: uid,
      coverUrl: '',
      tags: const [],
      description: '',
      pageCount: 2,
      illustType: 0,
      likeCount: 0,
      viewCount: 0,
      width: 100,
      height: 200,
      isOriginal: true,
      createDate: '',
      uploadDate: '',
      userId: uid,
    );

PixivAuthor _author(String name) => PixivAuthor(
      id: '42',
      name: name,
      avatar: '',
      following: 3,
      comment: '画师简介\n第二行\n第三行\n第四行',
    );

PixivComicBrief _work(String id) => PixivComicBrief(
      id: id,
      title: '作品$id',
      cover: '',
      author: '画师',
      tags: const [],
      illustType: 0,
      pageCount: 2,
      width: 100,
      height: 160,
    );

CustomDownloadedItem _download({String? uid, String source = 'pixiv'}) =>
    CustomDownloadedItem(
      downloadedEps: const [0],
      id: 'pixiv123',
      name: '作品',
      subTitle: '画师',
      tags: const [],
      sourceKey: source,
      sourceName: 'Pixiv',
      cover: '',
      comicId: '123',
      authorId: uid,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<ComicSource> sources;
  late List<String> settings;
  setUp(() {
    sources = List.of(ComicSource.sources);
    settings = List.of(appdata.settings);
    ComicSource.sources
      ..clear()
      ..add(ComicSource.named(key: 'pixiv', name: 'Pixiv'));
    appdata.settings[illustWaterfallColumnsSettingIndex] = '2';
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    ComicSource.sources
      ..clear()
      ..addAll(sources);
    appdata.settings
      ..clear()
      ..addAll(settings);
  });

  test('persisted local UID avoids the network, including managed wrappers',
      () async {
    final record = _download(uid: '42');
    final item = LocalLibraryComicItem(
      itemId: 'local::pixiv123',
      originalId: 'pixiv123',
      type: DownloadType.other,
      name: '作品',
      subTitle: '画师',
      tags: const [],
      sourceDisplayName: 'Pixiv',
      fileSystemPath: '',
      episodeFiles: const {},
      downloadedEps: const [0],
      eps: const ['EP 1'],
      localCoverPath: null,
      localStorageExists: true,
      canDelete: false,
      aliases: const [],
      sourceRowJson: jsonEncode(record.toJson()),
    );
    for (final value in [record, item]) {
      final target = PixivAuthorDestination.fromDownloadedItem(value)!;
      final result =
          await target.resolve(loadDetail: (_) => throw StateError('no HTTP'));
      expect(result.data, '42');
    }
    expect(
        PixivAuthorDestination.fromDownloadedItem(_download(source: 'komiic')),
        isNull);
  });

  test('legacy records query only their exact work, no author-name guess',
      () async {
    final queried = <String>[];
    final destination = PixivAuthorDestination.fromDownloadedItem(_download())!;
    final result = await destination.resolve(loadDetail: (id) async {
      queried.add(id);
      return Res(_detail());
    });
    expect(result.data, '42');
    expect(queried, ['123']);
    final missing =
        await const PixivAuthorDestination(authorId: '画师', comicId: 'folder')
            .resolve(
      loadDetail: (_) => throw StateError('invalid ID must not request'),
    );
    expect(missing.errorMessage, contains('有效作品 ID'));
  });

  test('offline, missing UID and source errors are actionable', () async {
    const destination = PixivAuthorDestination(comicId: '123');
    expect(
        (await destination.resolve(
                loadDetail: (_) async => throw StateError('offline')))
            .errorMessage,
        contains('检查网络'));
    expect(
        (await destination.resolve(
                loadDetail: (_) async => Res(_detail(uid: ''))))
            .errorMessage,
        contains('有效作者 ID'));
    expect(
        (await destination.resolve(
                loadDetail: (_) async => const Res.error('作品已不可用')))
            .errorMessage,
        contains('作品已不可用'));
  });

  testWidgets('online detail exposes author entry with known UID',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
      builder: (context) =>
          const PixivComicPageV2('123').buildCustomSection(context, _detail()),
    ))));
    final link = tester.widget<PixivAuthorLink>(find.byType(PixivAuthorLink));
    expect(link.destination.authorId, '42');
    expect(find.text('打开作者页 · 浏览全部作品'), findsOneWidget);
  });

  testWidgets(
      'local entry prevents duplicate lookups and navigates to resolved UID',
      (tester) async {
    final lookup = Completer<Res<PixivComicInfo>>();
    var requests = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PixivAuthorLink(
      destination: const PixivAuthorDestination(comicId: '123'),
      compact: true,
      loadDetail: (_) {
        requests++;
        return lookup.future;
      },
      pageBuilder: (uid) =>
          Scaffold(appBar: AppBar(), body: Text('author:$uid')),
    ))));
    await tester.tap(find.text('作者页'));
    await tester.pump();
    await tester.tap(find.text('正在打开'));
    expect(requests, 1);
    lookup.complete(Res(_detail()));
    await tester.pumpAndSettle();
    expect(find.text('author:42'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('作者页'), findsOneWidget);
  });

  testWidgets('failed author lookup stays on detail and allows retry',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PixivAuthorLink(
      destination: const PixivAuthorDestination(comicId: '123'),
      compact: true,
      loadDetail: (_) async => const Res.error('网络不可用'),
    ))));
    await tester.tap(find.text('作者页'));
    await tester.pumpAndSettle();
    expect(find.text('无法获取作者信息：网络不可用'), findsOneWidget);
    expect(find.text('作者页'), findsOneWidget);
  });

  testWidgets('refresh replaces outstanding first-page and profile requests',
      (tester) async {
    final authors = <Completer<Res<PixivAuthor>>>[];
    final works = <Completer<Res<List<PixivComicBrief>>>>[];
    await tester.pumpWidget(MaterialApp(
        home: PixivAuthorPageV2(
      '42',
      loadAuthor: (_) {
        final c = Completer<Res<PixivAuthor>>();
        authors.add(c);
        return c.future;
      },
      loadWorks: (_, page) {
        expect(page, 1);
        final c = Completer<Res<List<PixivComicBrief>>>();
        works.add(c);
        return c.future;
      },
    )));
    await tester.tap(find.byTooltip('刷新作者页'));
    await tester.pump();
    expect(works, hasLength(2));
    authors[1].complete(Res(_author('新资料')));
    works[1].complete(Res([_work('2')], subData: 1));
    await tester.pumpAndSettle();
    authors[0].complete(Res(_author('旧资料')));
    works[0].complete(Res([_work('1')], subData: 1));
    await tester.pumpAndSettle();
    expect(find.text('新资料'), findsNWidgets(2));
    expect(find.text('旧资料'), findsNothing);
    expect(find.text('作品2'), findsOneWidget);
    expect(find.text('作品1'), findsNothing);
    expect(find.byType(SliverMasonryGrid), findsOneWidget);
  });

  testWidgets('stale next page cannot contaminate refreshed wall',
      (tester) async {
    final stalePage = Completer<Res<List<PixivComicBrief>>>();
    var firstPages = 0;
    var nextPages = 0;
    await tester.pumpWidget(MaterialApp(
        home: PixivAuthorPageV2(
      '42',
      loadAuthor: (_) async => Res(_author('画师')),
      loadWorks: (_, page) async {
        if (page == 2) {
          nextPages++;
          return stalePage.future;
        }
        firstPages++;
        return Res([_work(firstPages == 1 ? '1' : '3')],
            subData: firstPages == 1 ? 2 : 1);
      },
    )));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pump();
    expect(nextPages, 1);
    await tester.tap(find.byTooltip('刷新作者页'));
    await tester.pumpAndSettle();
    stalePage.complete(Res([_work('2')], subData: 2));
    await tester.pumpAndSettle();
    expect(find.text('作品3'), findsOneWidget);
    expect(find.text('作品2'), findsNothing);
  });

  testWidgets(
      'profile failure does not hide works and layout survives large text',
      (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!),
      home: PixivAuthorPageV2(
        '42',
        loadAuthor: (_) async => const Res.error('暂时离线'),
        loadWorks: (_, page) async => Res([_work('1')], subData: 1),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('作者资料加载失败'), findsOneWidget);
    expect(find.byType(OnlineWaterfallCard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('column control persists shared density and introduction expands',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: PixivAuthorPageV2(
        '42',
        loadAuthor: (_) async => Res(_author('画师')),
        loadWorks: (_, page) async => Res([_work('1')], subData: 1),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('展开简介'));
    await tester.pumpAndSettle();
    expect(find.text('收起简介'), findsOneWidget);
    final intro = tester.widget<Text>(find.text(_author('画师').comment));
    expect(intro.maxLines, isNull);
    await tester.tap(find.byTooltip('作品列数'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<int>, '3 列'));
    await tester.pumpAndSettle();
    expect(appdata.settings[illustWaterfallColumnsSettingIndex], '3');
    expect(find.text('3 列'), findsOneWidget);
    expect(
        tester
            .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
            .author,
        isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing author ignores the previous author in-flight result',
      (tester) async {
    final old = Completer<Res<List<PixivComicBrief>>>();
    Widget page(String uid) => MaterialApp(
            home: PixivAuthorPageV2(
          uid,
          loadAuthor: (id) async => Res(_author('画师$id')),
          loadWorks: (id, _) async =>
              id == '42' ? await old.future : Res([_work('99')], subData: 1),
        ));
    await tester.pumpWidget(page('42'));
    await tester.pump();
    await tester.pumpWidget(page('99'));
    await tester.pumpAndSettle();
    old.complete(Res([_work('42')], subData: 1));
    await tester.pumpAndSettle();
    expect(find.text('画师99'), findsNWidgets(2));
    expect(find.text('作品99'), findsOneWidget);
    expect(find.text('作品42'), findsNothing);
  });
}
