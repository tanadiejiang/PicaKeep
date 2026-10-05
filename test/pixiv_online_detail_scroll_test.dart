import 'dart:async';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/pixiv_comments_section.dart';
import 'package:picakeep/pages/online_comic/pixiv_detail_shell.dart';
import 'package:picakeep/pages/online_comic/pixiv_online_detail_view.dart';
import 'package:sqlite3/open.dart';

class _FixturePaths extends PathProviderPlatform {
  _FixturePaths(this.root);

  final String root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

const _author = PixivAuthor(
  id: '42',
  name: 'Fixture author',
  avatar: '',
  comment: '',
  following: 0,
);

PixivComicInfo _info({int pageCount = 1, bool isBookmarked = false}) =>
    PixivComicInfo(
      id: '123',
      title: 'Fixture work',
      author: 'Fixture author',
      authorId: '42',
      coverUrl: '',
      tags: const ['Fixture tag'],
      description: List.filled(80, 'Long fixture description.').join('\n'),
      pageCount: pageCount,
      illustType: pixivIllustTypeIllust,
      likeCount: 12,
      viewCount: 34,
      width: 400,
      height: 600,
      isOriginal: true,
      createDate: '2026-10-05T10:00:00+08:00',
      uploadDate: '2026-10-05T10:00:00+08:00',
      userId: '42',
      isBookmarked: isBookmarked,
      isBookmarkable: true,
    );

PixivPage _imagePage({int width = 400, int height = 600}) => PixivPage(
      thumbMini: '',
      small: '',
      regular: '',
      original: '',
      width: width,
      height: height,
    );

Widget _page({
  Future<Res<PixivComicInfo>> Function()? loadDetail,
  Future<Res<List<PixivPage>>> Function(String)? loadPages,
  Future<Res<PixivAuthor>> Function(String)? loadAuthor,
  PixivDetailBookmarkWriter? writeBookmark,
  void Function(BuildContext, PixivComicInfo, int)? onRead,
}) =>
    MaterialApp(
      home: PixivOnlineDetailView(
        comicId: '123',
        loadDetail: loadDetail ?? () async => Res(_info()),
        loadPages: loadPages ?? (_) async => Res([_imagePage()]),
        loadAuthor: loadAuthor ?? (_) async => const Res(_author),
        writeBookmark: writeBookmark ??
            (_, {required isAdding, required isPrivate}) async => Res(isAdding),
        onRead: onRead ?? (_, __, ___) {},
        onDownload: (_, __) {},
        onDownloadLongPress: (_, __) {},
        onTagTap: (_, __, ___) {},
      ),
    );

void _mobileView(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

PixivDetailShell _shell(WidgetTester tester) =>
    tester.widget<PixivDetailShell>(find.byType(PixivDetailShell));

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(
      of: find.byKey(const ValueKey('pixiv-detail-page-scroll')),
      matching: find.byType(Scrollable),
    ))
    .position;

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _revealAuthor(WidgetTester tester) async {
  for (var attempt = 0;
      attempt < 40 && find.text('查看个人简介').evaluate().isEmpty;
      attempt++) {
    final position = _position(tester);
    position.jumpTo((position.pixels + 160).clamp(0, position.maxScrollExtent));
    await _pumpFrames(tester);
  }
  final profileTop = tester.getTopLeft(find.text('查看个人简介')).dy;
  _position(tester).jumpTo(_position(tester).pixels + profileTop - 790);
  await _pumpFrames(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
    OperatingSystem.windows,
    () => DynamicLibrary.open('${Directory.current.path}/windows/sqlite3.dll'),
  );
  late Directory workspace;
  late List<ComicSource> previousSources;
  final originalPaths = PathProviderPlatform.instance;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('pixiv_detail_scroll_');
    PathProviderPlatform.instance = _FixturePaths(workspace.path);
    await App.init(dataPathOverride: '${workspace.path}/data');
  });
  tearDownAll(() async {
    PixivNetwork().cookieJar.dispose();
    PathProviderPlatform.instance = originalPaths;
    await workspace.delete(recursive: true);
  });
  setUp(() {
    previousSources = List.of(ComicSource.sources);
    ComicSource.sources
      ..clear()
      ..add(ComicSource.named(
        key: 'pixiv',
        name: 'Pixiv',
        data: {'token': 'offline-fixture', 'userId': '99'},
      ));
  });
  tearDown(() {
    ComicSource.sources
      ..clear()
      ..addAll(previousSources);
  });

  testWidgets('online work images and details share one vertical position',
      (tester) async {
    _mobileView(tester);
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(_shell(tester).images.single.aspectRatio, closeTo(2 / 3, .001));

    final image = find.byKey(const ValueKey('pixiv-image-123-0'));
    final titleTop = tester.getTopLeft(find.text('Fixture work')).dy;
    final imageTop = tester.getTopLeft(image).dy;
    expect(titleTop, greaterThanOrEqualTo(imageTop + 600));
    _position(tester).jumpTo(100);
    await tester.pump();
    expect(tester.getTopLeft(image).dy, closeTo(imageTop - 100, .1));
    expect(tester.getTopLeft(find.text('Fixture work')).dy,
        closeTo(titleTop - 100, .1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('author read waits for its position and happens once',
      (tester) async {
    _mobileView(tester);
    var reads = 0;
    await tester.pumpWidget(_page(loadAuthor: (id) async {
      expect(id, '42');
      reads++;
      return const Res(_author);
    }));
    await tester.pumpAndSettle();
    expect(reads, 0);
    final slivers = _shell(tester)
        .sliversBuilder(tester.element(find.byType(PixivDetailShell)));
    expect(slivers.whereType<PixivCommentsSection>().single.autoLoad, isTrue);

    await _revealAuthor(tester);
    expect(reads, 1);
    expect(find.text('加关注'), findsOneWidget);
    _position(tester).jumpTo(_position(tester).pixels - 20);
    await _pumpFrames(tester);
    _position(tester).jumpTo(_position(tester).pixels + 20);
    await _pumpFrames(tester);
    expect(reads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh starts new page loading and ignores older page results',
      (tester) async {
    _mobileView(tester);
    final oldPages = Completer<Res<List<PixivPage>>>();
    final newPages = Completer<Res<List<PixivPage>>>();
    var loads = 0;
    var readPage = 0;
    await tester.pumpWidget(_page(
      loadDetail: () async => Res(_info(pageCount: 2)),
      loadPages: (_) => ++loads == 1 ? oldPages.future : newPages.future,
      onRead: (_, __, page) => readPage = page,
    ));
    await _pumpFrames(tester);
    expect(loads, 1);
    expect(_shell(tester).imagesLoading, isTrue);

    _shell(tester).onMenu!('refresh');
    await _pumpFrames(tester);
    expect(loads, 2);
    newPages.complete(Res([
      _imagePage(width: 400, height: 800),
      _imagePage(width: 400, height: 400),
    ]));
    await _pumpFrames(tester);
    expect(_shell(tester).imagesLoading, isFalse);
    expect(_shell(tester).images.map((image) => image.aspectRatio), [.5, 1]);
    _shell(tester).images[1].onRead();
    expect(readPage, 2);

    oldPages.complete(Res([_imagePage(width: 100, height: 100)]));
    await _pumpFrames(tester);
    expect(_shell(tester).images.map((image) => image.aspectRatio), [.5, 1]);
    expect(_shell(tester).imageError, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh can load author while an earlier author read is pending',
      (tester) async {
    _mobileView(tester);
    final oldAuthor = Completer<Res<PixivAuthor>>();
    final newAuthor = Completer<Res<PixivAuthor>>();
    var reads = 0;
    await tester.pumpWidget(_page(
      loadAuthor: (_) => ++reads == 1 ? oldAuthor.future : newAuthor.future,
    ));
    await _pumpFrames(tester);
    await _revealAuthor(tester);
    expect(reads, 1);

    _shell(tester).onMenu!('refresh');
    await _pumpFrames(tester);
    await _revealAuthor(tester);
    expect(reads, 2);
    newAuthor.complete(const Res(_author));
    await _pumpFrames(tester);
    expect(find.text('加关注'), findsOneWidget);

    oldAuthor.complete(Res(_author.copyWith(isFollowed: true)));
    await _pumpFrames(tester);
    expect(find.text('加关注'), findsOneWidget);
    expect(find.text('已关注'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending bookmark survives refresh without stale state or a lock',
      (tester) async {
    _mobileView(tester);
    final oldWrite = Completer<Res<bool>>();
    final newWrite = Completer<Res<bool>>();
    var writes = 0;
    await tester.pumpWidget(_page(
      loadDetail: () async => Res(_info(isBookmarked: true)),
      writeBookmark: (_, {required isAdding, required isPrivate}) {
        expect(isAdding, isFalse);
        return ++writes == 1 ? oldWrite.future : newWrite.future;
      },
    ));
    await _pumpFrames(tester);
    _shell(tester).onFavorite!();
    await _pumpFrames(tester);
    expect(writes, 1);
    expect(_shell(tester).favoriteBusy, isTrue);

    _shell(tester).onMenu!('refresh');
    await _pumpFrames(tester);
    expect(_shell(tester).isFavorited, isTrue);
    expect(_shell(tester).favoriteBusy, isTrue);
    _shell(tester).onFavorite!();
    await _pumpFrames(tester);
    expect(writes, 1);

    oldWrite.complete(const Res(false));
    await _pumpFrames(tester);
    expect(_shell(tester).isFavorited, isTrue);
    expect(_shell(tester).favoriteBusy, isFalse);
    _shell(tester).onFavorite!();
    await _pumpFrames(tester);
    expect(writes, 2);
    newWrite.complete(const Res(false));
    await _pumpFrames(tester);
    expect(_shell(tester).isFavorited, isFalse);
    expect(_shell(tester).favoriteBusy, isFalse);
    expect(tester.takeException(), isNull);
  });
}
