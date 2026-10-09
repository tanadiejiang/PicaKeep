import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/pixiv_detail_feed_settings.dart';
import 'package:picakeep/pages/online_comic/pixiv_follow_recommendations_sheet.dart';
import 'package:picakeep/components/pixiv_bookmark_button.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
import 'package:picakeep/foundation/pixiv_detail_feeds.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/accounts/accounts_page.dart';
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

// Short details expose the automatic comments loader. Its HTTP transport is
// offline too; a test must never use a real account or open a socket.
class _OfflineHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _OfflineHttpClient();
}

class _OfflineHttpClient implements HttpClient {
  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (method != 'GET' ||
        url.host != 'www.pixiv.net' ||
        url.path != '/ajax/illusts/comments/roots') {
      throw StateError('Unexpected offline request: $method $url');
    }
    return _OfflineHttpRequest();
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _OfflineHttpRequest implements HttpClientRequest {
  @override
  final HttpHeaders headers = _OfflineHttpHeaders();

  @override
  Future<HttpClientResponse> close() async => _OfflineHttpResponse();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _OfflineHttpHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _OfflineHttpResponse extends Stream<List<int>>
    implements HttpClientResponse {
  static final _body =
      utf8.encode('{"error":false,"body":{"comments":[],"hasNext":false}}');

  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => _body.length;

  @override
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  String get reasonPhrase => 'OK';

  @override
  Future<Socket> detachSocket() async => _OfflineSocket();

  @override
  final HttpHeaders headers = _OfflineHttpHeaders();

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream.value(_body).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _OfflineSocket implements Socket {
  @override
  void destroy() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const _author = PixivAuthor(
  id: '42',
  name: 'Fixture author',
  avatar: '',
  comment: '',
  following: 0,
);

PixivComicInfo _info({
  int pageCount = 1,
  bool isBookmarked = false,
  String? description,
  int width = 400,
  int height = 600,
  bool? isBookmarkable = true,
  List<PixivComicBrief> relatedWorks = const [],
}) =>
    PixivComicInfo(
      id: '123',
      title: 'Fixture work',
      author: 'Fixture author',
      authorId: '42',
      coverUrl: '',
      tags: const ['Fixture tag'],
      description: description ??
          List.filled(80, 'Long fixture description.').join('\n'),
      pageCount: pageCount,
      illustType: pixivIllustTypeIllust,
      likeCount: 12,
      viewCount: 34,
      width: width,
      height: height,
      isOriginal: true,
      createDate: '2026-10-05T10:00:00+08:00',
      uploadDate: '2026-10-05T10:00:00+08:00',
      userId: '42',
      isBookmarked: isBookmarked,
      isBookmarkable: isBookmarkable,
      relatedWorks: relatedWorks,
    );

PixivPage _imagePage({int width = 400, int height = 600}) => PixivPage(
      thumbMini: '',
      small: '',
      regular: '',
      original: '',
      width: width,
      height: height,
    );

class _BouncingBehavior extends MaterialScrollBehavior {
  const _BouncingBehavior();
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
}

Widget _page({
  ScrollBehavior? scrollBehavior,
  Future<Res<PixivComicInfo>> Function()? loadDetail,
  Future<Res<List<PixivPage>>> Function(String)? loadPages,
  Future<Res<PixivAuthor>> Function(String)? loadAuthor,
  PixivWorkIdsLoader? loadAuthorWorkIds,
  PixivAuthorPreviewLoader? loadAuthorPreviewWorks,
  PixivRecommendationsLoader? loadRecommendations,
  PixivRecommendationWorksLoader? loadRecommendationWorks,
  Future<void> Function(PixivComicBrief, PixivDetailSession)? onOpenWork,
  Future<Res<bool>> Function(String, {required bool isFollowing})? writeFollow,
  Future<Res<List<PixivRecommendedAuthor>>> Function(String)?
      loadRecommendedAuthors,
  bool Function()? isLoggedIn,
  PixivDetailBookmarkWriter? writeBookmark,
  void Function(BuildContext, PixivComicInfo, int)? onRead,
}) =>
    MaterialApp(
      scrollBehavior: scrollBehavior,
      home: PixivOnlineDetailView(
        comicId: '123',
        loadDetail: loadDetail ?? () async => Res(_info()),
        loadPages: loadPages ?? (_) async => Res([_imagePage()]),
        loadAuthor: loadAuthor ?? (_) async => const Res(_author),
        loadAuthorWorkIds: loadAuthorWorkIds ?? (_) async => const Res([]),
        loadAuthorPreviewWorks:
            loadAuthorPreviewWorks ?? (_, __) async => const Res([]),
        loadRecommendations: loadRecommendations ??
            (_) async =>
                const Res(PixivRecommendationsPage(items: [], nextIds: [])),
        loadRecommendationWorks:
            loadRecommendationWorks ?? (_) async => const Res([]),
        onOpenWork: onOpenWork,
        writeFollow: writeFollow,
        loadRecommendedAuthors:
            loadRecommendedAuthors ?? (_) async => const Res([]),
        isLoggedIn: isLoggedIn,
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
      matching: find.byWidgetPredicate((widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down),
    ))
    .position;

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Finder get _favorite => find.byKey(const ValueKey('pixiv-detail-favorite'));

void _expectFavoriteVisible(WidgetTester tester) {
  expect(
      tester
          .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('pixiv-detail-favorite-opacity')))
          .opacity,
      1);
  expect(
      tester
          .widget<AnimatedScale>(
              find.byKey(const ValueKey('pixiv-detail-favorite-scale')))
          .scale,
      1);
  expect(
      tester
          .widget<IgnorePointer>(
              find.byKey(const ValueKey('pixiv-detail-favorite-hit-test')))
          .ignoring,
      isFalse);
}

PixivComicInfo _shortInfo({bool? isBookmarkable = true}) => _info(
    description: '', width: 800, height: 400, isBookmarkable: isBookmarkable);

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
  late List<String> previousSettings;
  final originalPaths = PathProviderPlatform.instance;
  final originalHttpOverrides = HttpOverrides.current;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('pixiv_detail_scroll_');
    PathProviderPlatform.instance = _FixturePaths(workspace.path);
    HttpOverrides.global = _OfflineHttpOverrides();
    await App.init(dataPathOverride: '${workspace.path}/data');
  });
  tearDownAll(() async {
    PixivNetwork().cookieJar.dispose();
    PathProviderPlatform.instance = originalPaths;
    HttpOverrides.global = originalHttpOverrides;
    await workspace.delete(recursive: true);
  });
  setUp(() {
    PixivBookmarkStateStore.shared.clear();
    previousSources = List.of(ComicSource.sources);
    previousSettings = List.of(appdata.settings);
    appdata.settings[pixivAuthorPreviewCountSettingIndex] = '5';
    appdata.settings[pixivRelatedBatchSizeSettingIndex] = '5';
    appdata.settings[pixivRelatedModeSettingIndex] = pixivRelatedModeCustom;
    ComicSource.sources
      ..clear()
      ..add(ComicSource.named(
        key: 'pixiv',
        name: 'Pixiv',
        data: {'token': 'offline-fixture', 'userId': '99'},
      ));
  });
  tearDown(() {
    appdata.settings = previousSettings;
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

  testWidgets('short landscape initial load exposes actual bookmark command',
      (tester) async {
    _mobileView(tester);
    final detail = Completer<Res<PixivComicInfo>>();
    final write = Completer<Res<bool>>();
    final writes = <(String, bool, bool)>[];
    await tester.pumpWidget(_page(
      loadDetail: () => detail.future,
      loadPages: (_) =>
          throw StateError('Single page must use detail dimensions'),
      writeBookmark: (id, {required isAdding, required isPrivate}) {
        writes.add((id, isAdding, isPrivate));
        return write.future;
      },
    ));
    await _pumpFrames(tester);
    expect(find.byType(PixivDetailShell), findsNothing);
    detail.complete(Res(_shortInfo()));
    await tester.pumpAndSettle();
    expect(_shell(tester).imagesLoading, isFalse);
    expect(_shell(tester).images.single.aspectRatio, 2);
    expect(_position(tester).pixels, 0);
    expect(tester.getTopLeft(find.text('查看个人简介')).dy, lessThan(650));
    _expectFavoriteVisible(tester);
    await tester.tap(_favorite);
    await _pumpFrames(tester);
    expect(writes, [('123', true, false)]);
    expect(_shell(tester).favoriteBusy, isTrue);
    expect(_shell(tester).isFavorited, isFalse);
    expect(_shell(tester).favoriteEvent?.phase, PixivBookmarkPhase.begin);
    expect(_shell(tester).favoriteEvent?.target, isTrue);
    await tester.pump(const Duration(milliseconds: 350));
    expect(_shell(tester).isFavorited, isFalse);
    expect(find.byKey(const ValueKey('pixiv-bookmark-ring')), findsNothing);
    expect(
        tester
            .widget<Icon>(
                find.byKey(const ValueKey('pixiv-bookmark-main-icon')))
            .icon,
        Icons.favorite);
    _expectFavoriteVisible(tester);
    await tester.tap(_favorite, warnIfMissed: false);
    await tester.longPress(_favorite, warnIfMissed: false);
    expect(writes.length, 1);
    write.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(_shell(tester).favoriteBusy, isFalse);
    expect(_shell(tester).isFavorited, isTrue);
    _expectFavoriteVisible(tester);
    expect(find.text('已添加公开收藏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short landscape long press keeps private bookmark semantics',
      (tester) async {
    _mobileView(tester);
    final writes = <(String, bool, bool)>[];
    await tester.pumpWidget(_page(
      loadDetail: () async => Res(_shortInfo()),
      loadPages: (_) async => Res([_imagePage(width: 800, height: 400)]),
      writeBookmark: (id, {required isAdding, required isPrivate}) async {
        writes.add((id, isAdding, isPrivate));
        return const Res(true);
      },
    ));
    await tester.pumpAndSettle();
    _expectFavoriteVisible(tester);
    await tester.longPress(_favorite);
    await tester.pumpAndSettle();
    expect(writes, [('123', true, true)]);
    expect(_shell(tester).isFavorited, isTrue);
    expect(find.text('已添加私密收藏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short landscape failed write restores the unbookmarked action',
      (tester) async {
    _mobileView(tester);
    final write = Completer<Res<bool>>();
    var writes = 0;
    await tester.pumpWidget(_page(
      loadDetail: () async => Res(_shortInfo()),
      loadPages: (_) async => Res([_imagePage(width: 800, height: 400)]),
      writeBookmark: (_, {required isAdding, required isPrivate}) {
        writes++;
        return write.future;
      },
    ));
    await tester.pumpAndSettle();
    await tester.tap(_favorite);
    await _pumpFrames(tester);
    expect(_shell(tester).favoriteBusy, isTrue);
    write.complete(const Res.error('fixture write denied',
        errorCode: ResErrorCode.accessDenied));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(_shell(tester).favoriteBusy, isFalse);
    expect(_shell(tester).isFavorited, isFalse);
    _expectFavoriteVisible(tester);
    expect(
        tester
            .widget<Icon>(
                find.byKey(const ValueKey('pixiv-bookmark-main-icon')))
            .icon,
        Icons.favorite_border);
    expect(find.text('收藏失败：fixture write denied'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final bookmarkable in [false, null]) {
    testWidgets('short landscape visibility retains capability $bookmarkable',
        (tester) async {
      _mobileView(tester);
      var writes = 0;
      await tester.pumpWidget(_page(
        loadDetail: () async => Res(_shortInfo(isBookmarkable: bookmarkable)),
        loadPages: (_) async => Res([_imagePage(width: 800, height: 400)]),
        writeBookmark: (_, {required isAdding, required isPrivate}) async {
          writes++;
          return const Res(true);
        },
      ));
      await tester.pumpAndSettle();
      _expectFavoriteVisible(tester);
      await tester.tap(_favorite);
      await tester.pumpAndSettle();
      expect(writes, 0);
      expect(_shell(tester).isFavorited, isFalse);
      expect(find.text('收藏失败：暂时无法确认此作品可收藏，请刷新'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('short landscape account change refreshes before any write',
      (tester) async {
    _mobileView(tester);
    var reads = 0;
    var writes = 0;
    await tester.pumpWidget(_page(
      loadDetail: () async {
        reads++;
        return Res(_shortInfo());
      },
      loadPages: (_) async => Res([_imagePage(width: 800, height: 400)]),
      writeBookmark: (_, {required isAdding, required isPrivate}) async {
        writes++;
        return const Res(true);
      },
    ));
    await tester.pumpAndSettle();
    ComicSource.require('pixiv').data['token'] = 'changed-offline-fixture';
    await tester.tap(_favorite);
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(writes, 0);
    expect(find.text('收藏失败：账号已变化，请刷新后重新操作'), findsOneWidget);
    _expectFavoriteVisible(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short landscape logged out favorite opens the account route',
      (tester) async {
    _mobileView(tester);
    ComicSource.require('pixiv').data.remove('token');
    final haptics = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    var writes = 0;
    await tester.pumpWidget(_page(
      loadDetail: () async => Res(_shortInfo()),
      loadPages: (_) async => Res([_imagePage(width: 800, height: 400)]),
      writeBookmark: (_, {required isAdding, required isPrivate}) async {
        writes++;
        return const Res(true);
      },
    ));
    await tester.pumpAndSettle();
    _expectFavoriteVisible(tester);
    await tester.tap(_favorite);
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(haptics, isEmpty);
    expect(find.byType(AccountsPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(AccountsPage), findsNothing);
    _expectFavoriteVisible(tester);
    expect(writes, 0);
    expect(haptics, isEmpty);
    expect(find.text('已添加公开收藏'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'author strip fills five, scrolls horizontally and opens author snapshot',
      (tester) async {
    _mobileView(tester);
    final batches = <List<String>>[];
    List<String>? opened;
    PixivDetailScope? scope;
    PixivComicBrief work(String id) => PixivComicBrief(
          id: id,
          title: '作者作品$id',
          author: 'Fixture author',
          authorId: '42',
          cover: '',
          tags: const [],
          illustType: 0,
          pageCount: 1,
        );
    await tester.pumpWidget(_page(
      loadDetail: () async => Res(_info(
          description: '',
          width: 800,
          height: 400,
          relatedWorks: [work('201'), work('202')])),
      loadAuthorWorkIds: (_) async =>
          const Res(['123', '205', '204', '203', '202', '201']),
      loadAuthorPreviewWorks: (_, ids) async {
        batches.add(ids);
        return Res(ids.reversed.map(work).toList());
      },
      onOpenWork: (comic, session) async {
        opened = session.entries.map((e) => e.comicId).toList();
        scope = session.scope;
        expect(comic.id, '203');
        expect(session.hasMore, isFalse);
      },
    ));
    await tester.pumpAndSettle();
    for (var i = 0; i < 8 && batches.isEmpty; i++) {
      _position(tester).jumpTo((_position(tester).pixels + 150)
          .clamp(0, _position(tester).maxScrollExtent));
      await tester.pumpAndSettle();
    }
    expect(batches, [
      ['205', '204', '203']
    ]);
    final strip = find.byKey(const ValueKey('pixiv-author-preview-123'));
    expect(tester.widget<ListView>(strip).semanticChildCount, 5);
    await tester.ensureVisible(strip);
    await tester.pumpAndSettle();
    final verticalBefore = _position(tester).pixels;
    await tester.drag(strip, const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, closeTo(verticalBefore, .01));
    final fifth = find.byKey(const ValueKey('pixiv-author-preview-203'));
    await tester.tap(fifth);
    await tester.pumpAndSettle();
    expect(opened, ['201', '202', '205', '204', '203']);
    expect(scope, PixivDetailScope.author);
    expect(find.byType(PixivCommentsSection), findsOneWidget);
    expect(
        tester
            .widget<PixivCommentsSection>(find.byType(PixivCommentsSection))
            .previewLimit,
        4);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'bottom cards use cross-author feed and related session continues independently',
      (tester) async {
    _mobileView(tester);
    final calls = <List<String>>[];
    var opens = 0;
    PixivComicBrief work(String id, String author) => PixivComicBrief(
          id: id,
          title: '推荐作品$id',
          author: '作者$author',
          authorId: author,
          cover: '',
          tags: const [],
          illustType: 0,
          pageCount: 1,
          width: 1000,
          height: 5000,
        );
    await tester.pumpWidget(_page(
      loadDetail: () async => Res(_info(
          description: '',
          width: 800,
          height: 400,
          relatedWorks: [work('201', '42'), work('202', '42')])),
      loadAuthorWorkIds: (_) async => const Res([]),
      loadRecommendations: (_) async => Res(PixivRecommendationsPage(
          items: [work('301', '7'), work('302', '8')],
          nextIds: const ['303', '304'])),
      loadRecommendationWorks: (ids) async {
        calls.add(ids);
        return Res([work('304', '9'), work('303', '10')]);
      },
      onOpenWork: (comic, session) async {
        opens++;
        expect(comic.id, '301');
        expect(session.scope, PixivDetailScope.related);
        expect(session.entries.map((e) => e.comicId), ['301', '302']);
        expect(session.hasMore, isTrue);
        await session.requestMore();
        expectSync(session.entries.map((e) => e.comicId),
            ['301', '302', '303', '304']);
        expectSync(session.hasMore, isFalse);
      },
    ));
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('pixiv-related-301'));
    for (var i = 0; i < 12 && card.evaluate().isEmpty; i++) {
      _position(tester).jumpTo((_position(tester).pixels + 120)
          .clamp(0, _position(tester).maxScrollExtent));
      await tester.pumpAndSettle();
    }
    expect(card, findsOneWidget);
    expect(calls, isEmpty, reason: 'tail is not yet visible');
    expect(find.text('作者的其他作品'), findsNothing);
    expect(find.text('相关推荐'), findsOneWidget);
    final firstCard = tester.widget<OnlineRecommendationCard>(card);
    expect((firstCard.comic as PixivComicBrief).authorId, '7');
    firstCard.onOpenDetail!();
    await tester.pumpAndSettle();
    expect(opens, 1);
    expect(calls, [
      ['303', '304']
    ]);
    final strip = find.byKey(const ValueKey('pixiv-author-preview-123'));
    expect(tester.widget<ListView>(strip).semanticChildCount, 2);
    expect(_position(tester).pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  for (final bouncing in [false, true]) {
    testWidgets(
        'related lazy loading and one batch per drag, bouncing=$bouncing',
        (tester) async {
      _mobileView(tester);
      var initialReads = 0;
      final batches = <List<String>>[];
      PixivComicBrief work(String id) => PixivComicBrief(
          id: id,
          title: '推荐$id',
          cover: '',
          author: '作者7',
          authorId: '7',
          tags: const [],
          illustType: 0,
          pageCount: 1,
          width: 1000,
          height: 1000);
      await tester.pumpWidget(_page(
        scrollBehavior: bouncing ? const _BouncingBehavior() : null,
        loadRecommendations: (_) async {
          initialReads++;
          return Res(PixivRecommendationsPage(
              items: [work('301'), work('302')],
              nextIds: List.generate(12, (i) => '${i + 400}')));
        },
        loadRecommendationWorks: (ids) async {
          batches.add(ids);
          return Res(ids.map(work).toList());
        },
      ));
      await tester.pumpAndSettle();
      expect(initialReads, 0,
          reason: 'description keeps recommendation outside paint area');
      for (var i = 0; i < 80 && initialReads == 0; i++) {
        _position(tester).jumpTo((_position(tester).pixels + 180)
            .clamp(0, _position(tester).maxScrollExtent));
        await tester.pumpAndSettle();
      }
      expect(initialReads, 1);
      expect(batches, isEmpty,
          reason: 'reaching first batch must not eagerly read tail');
      _position(tester).jumpTo(_position(tester).maxScrollExtent);
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(const Offset(200, 500));
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump();
      expect(batches, isEmpty);
      await gesture.moveBy(const Offset(0, -240));
      await tester.pumpAndSettle();
      expect(batches, [
        ['400', '401', '402', '403', '404']
      ]);
      await gesture.moveBy(const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(batches, hasLength(1), reason: 'one continuation per drag');
      await gesture.up();
      await tester.pumpAndSettle();
      expect(_position(tester).pixels, greaterThan(0));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'two count preferences update feeds without replacing detail or comments',
      (tester) async {
    _mobileView(tester);
    var detailReads = 0;
    var recommendationReads = 0;
    PixivComicBrief work(String id) => PixivComicBrief(
        id: id,
        title: '作品$id',
        author: '作者42',
        authorId: '42',
        cover: '',
        tags: const [],
        illustType: 0,
        pageCount: 1);
    await tester.pumpWidget(_page(
      loadDetail: () async {
        detailReads++;
        return Res(_info(
            description: '',
            width: 800,
            height: 400,
            relatedWorks: List.generate(10, (i) => work('${i + 200}'))));
      },
      loadRecommendations: (_) async {
        recommendationReads++;
        return Res(PixivRecommendationsPage(
            items: List.generate(10, (i) => work('${i + 300}')),
            nextIds: const []));
      },
    ));
    await tester.pumpAndSettle();
    final position = _position(tester);
    expect(
        tester
            .widget<ListView>(
                find.byKey(const ValueKey('pixiv-author-preview-123')))
            .semanticChildCount,
        5);
    appdata.settings[pixivAuthorPreviewCountSettingIndex] = '8';
    appdata.settings[pixivRelatedBatchSizeSettingIndex] = '3';
    App.notifyDisplaySettingsChanged();
    await tester.pumpAndSettle();
    expect(detailReads, 1);
    expect(identical(position, _position(tester)), isTrue);
    expect(
        tester
            .widget<ListView>(
                find.byKey(const ValueKey('pixiv-author-preview-123')))
            .semanticChildCount,
        8);
    for (var i = 0;
        i < 10 &&
            find
                .byKey(const ValueKey('pixiv-related-grid-123'))
                .evaluate()
                .isEmpty;
        i++) {
      position
          .jumpTo((position.pixels + 150).clamp(0, position.maxScrollExtent));
      await tester.pumpAndSettle();
    }
    final grid = tester.widget<SliverMasonryGrid>(
        find.byKey(const ValueKey('pixiv-related-grid-123')));
    expect(grid.delegate.estimatedChildCount, 3);
    expect(recommendationReads, inInclusiveRange(1, 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'confirmed follow opens independent discovery and closing keeps followed state',
      (tester) async {
    _mobileView(tester);
    final writes = <(String, bool)>[];
    var recommendedReads = 0;
    await tester.pumpWidget(_page(
      loadDetail: () async => Res(_shortInfo()),
      isLoggedIn: () => true,
      writeFollow: (id, {required isFollowing}) async {
        writes.add((id, isFollowing));
        return const Res(true);
      },
      loadRecommendedAuthors: (id) async {
        recommendedReads++;
        expectSync(id, '42');
        return const Res([]);
      },
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('加关注'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加关注'));
    await tester.pumpAndSettle();
    expect(writes, [('42', true)]);
    expect(recommendedReads, 1);
    expect(find.byType(PixivFollowRecommendationsSheet), findsOneWidget);
    expect(find.text('发现更多作者'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭作者推荐'));
    await tester.pumpAndSettle();
    expect(find.byType(PixivFollowRecommendationsSheet), findsNothing);
    expect(find.text('已关注'), findsOneWidget);
    await tester.tap(find.text('已关注'));
    await tester.pumpAndSettle();
    expect(writes, [('42', true), ('42', false)]);
    expect(recommendedReads, 1);
    expect(find.byType(PixivFollowRecommendationsSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'refresh rejects stale follow discovery and releases its busy lock',
      (tester) async {
    _mobileView(tester);
    final pending = Completer<Res<bool>>();
    var recommendedReads = 0;
    await tester.pumpWidget(_page(
      loadDetail: () async => Res(_shortInfo()),
      isLoggedIn: () => true,
      writeFollow: (_, {required isFollowing}) => pending.future,
      loadRecommendedAuthors: (_) async {
        recommendedReads++;
        return const Res([]);
      },
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('加关注'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加关注'));
    await tester.pump();
    _shell(tester).onMenu!('refresh');
    await tester.pumpAndSettle();
    pending.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(recommendedReads, 0);
    expect(find.byType(PixivFollowRecommendationsSheet), findsNothing);
    final button =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '加关注'));
    expect(button.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Pixiv default shows full round then a gesture requests another round',
      (tester) async {
    _mobileView(tester);
    appdata.settings[pixivRelatedModeSettingIndex] = pixivRelatedModePixiv;
    var initialReads = 0;
    var detailReads = 0;
    PixivComicBrief work(String id) => PixivComicBrief(
        id: id,
        title: '推荐$id',
        cover: '',
        author: '作者7',
        authorId: '7',
        tags: const [],
        illustType: 0,
        pageCount: 1,
        width: 1000,
        height: 1000);
    await tester.pumpWidget(_page(
      loadRecommendations: (_) async {
        initialReads++;
        return Res(PixivRecommendationsPage(
            items: initialReads == 1
                ? List.generate(7, (i) => work('${i + 300}'))
                : [work('300'), work('400'), work('401')],
            nextIds: const []));
      },
      loadRecommendationWorks: (_) async {
        detailReads++;
        return const Res([]);
      },
    ));
    await tester.pumpAndSettle();
    expect(initialReads, 0);
    for (var i = 0; i < 80 && initialReads == 0; i++) {
      _position(tester).jumpTo((_position(tester).pixels + 180)
          .clamp(0, _position(tester).maxScrollExtent));
      await tester.pumpAndSettle();
    }
    expect(initialReads, 1);
    var grid = tester.widget<SliverMasonryGrid>(
        find.byKey(const ValueKey('pixiv-related-grid-123')));
    expect(grid.delegate.estimatedChildCount, 7);
    expect(detailReads, 0);
    final position = _position(tester);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(initialReads, 1,
        reason: 'seeing the end does not automatically recommend again');
    await tester.drag(find.byKey(const ValueKey('pixiv-detail-page-scroll')),
        const Offset(0, -360));
    await tester.pumpAndSettle();
    expect(initialReads, 2);
    grid = tester.widget<SliverMasonryGrid>(
        find.byKey(const ValueKey('pixiv-related-grid-123')));
    expect(grid.delegate.estimatedChildCount, 9);
    expect(detailReads, 0);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('pixiv-detail-page-scroll')),
        const Offset(0, -360));
    await tester.pumpAndSettle();
    expect(initialReads, 3);
    expect(find.text('本轮没有新的可显示作品，再推荐一轮'), findsOneWidget);
    expect(grid.delegate.estimatedChildCount, 9);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'failed fresh recommendation round retries from the detail status button',
      (tester) async {
    _mobileView(tester);
    appdata.settings[pixivRelatedModeSettingIndex] = pixivRelatedModePixiv;
    var reads = 0;
    PixivComicBrief work(String id) => PixivComicBrief(
        id: id,
        title: '推荐$id',
        cover: '',
        author: '作者7',
        authorId: '7',
        tags: const [],
        illustType: 0,
        pageCount: 1,
        width: 1000,
        height: 1000);
    await tester.pumpWidget(_page(loadRecommendations: (_) async {
      reads++;
      if (reads == 2) return const Res.error('下一轮网络失败');
      return Res(PixivRecommendationsPage(
          items: [work(reads == 1 ? '300' : '400')], nextIds: const []));
    }));
    await tester.pumpAndSettle();
    for (var i = 0; i < 80 && reads == 0; i++) {
      _position(tester).jumpTo((_position(tester).pixels + 180)
          .clamp(0, _position(tester).maxScrollExtent));
      await tester.pumpAndSettle();
    }
    _position(tester).jumpTo(_position(tester).maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('pixiv-detail-page-scroll')),
        const Offset(0, -360));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.text('相关推荐加载失败：下一轮网络失败'), findsOneWidget);
    await tester.ensureVisible(find.text('重试相关推荐'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试相关推荐'));
    await tester.pumpAndSettle();
    expect(reads, 3);
    expect(find.text('相关推荐加载失败：下一轮网络失败'), findsNothing);
    final grid = tester.widget<SliverMasonryGrid>(
        find.byKey(const ValueKey('pixiv-related-grid-123')));
    expect(grid.delegate.estimatedChildCount, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'switching recommendation mode preserves detail and the outer position',
      (tester) async {
    _mobileView(tester);
    var detailReads = 0;
    var recommendationReads = 0;
    PixivComicBrief work(String id) => PixivComicBrief(
        id: id,
        title: '推荐$id',
        cover: '',
        author: '作者7',
        authorId: '7',
        tags: const [],
        illustType: 0,
        pageCount: 1,
        width: 1000,
        height: 1000);
    await tester.pumpWidget(_page(
      loadDetail: () async {
        detailReads++;
        return Res(_info());
      },
      loadRecommendations: (_) async {
        recommendationReads++;
        return Res(PixivRecommendationsPage(
            items: List.generate(9, (i) => work('${i + 300}')),
            nextIds: const []));
      },
    ));
    await tester.pumpAndSettle();
    for (var i = 0; i < 80 && recommendationReads == 0; i++) {
      _position(tester).jumpTo((_position(tester).pixels + 180)
          .clamp(0, _position(tester).maxScrollExtent));
      await tester.pumpAndSettle();
    }
    final position = _position(tester);
    SliverMasonryGrid grid() => tester.widget<SliverMasonryGrid>(
        find.byKey(const ValueKey('pixiv-related-grid-123')));
    expect(grid().delegate.estimatedChildCount, 5);
    appdata.settings[pixivRelatedModeSettingIndex] = pixivRelatedModePixiv;
    App.notifyDisplaySettingsChanged();
    await tester.pumpAndSettle();
    expect(grid().delegate.estimatedChildCount, 9);
    expect(identical(position, _position(tester)), isTrue);
    expect(detailReads, 1);
    expect(recommendationReads, 2);
    appdata.settings[pixivRelatedModeSettingIndex] = pixivRelatedModeCustom;
    appdata.settings[pixivRelatedBatchSizeSettingIndex] = '3';
    App.notifyDisplaySettingsChanged();
    await tester.pumpAndSettle();
    expect(grid().delegate.estimatedChildCount, 3);
    expect(identical(position, _position(tester)), isTrue);
    expect(detailReads, 1);
    expect(recommendationReads, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'multipage starts with pictures and only the panel omits recommendations',
      (tester) async {
    _mobileView(tester);
    var recommendations = 0;
    var readerOpens = 0;
    await tester.pumpWidget(_page(
      loadDetail: () async => Res(_info(
          pageCount: 2,
          description: List.filled(20, 'Fixture description.').join('\n'),
          width: 800,
          height: 1200)),
      loadPages: (_) async => Res([_imagePage(), _imagePage()]),
      onRead: (_, __, ___) => readerOpens++,
      loadRecommendations: (_) async {
        recommendations++;
        return const Res(PixivRecommendationsPage(items: [], nextIds: []));
      },
    ));
    await tester.pumpAndSettle();
    expect(recommendations, 0);
    expect(find.byType(PixivCommentsSection), findsNothing);
    final position = _position(tester);
    await tester.tap(find.byTooltip('展开详情'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('收起详情'), findsOneWidget);
    expect(recommendations, 0);
    expect(find.text('相关推荐'), findsNothing);
    await tester.tap(find.byTooltip('收起详情'));
    await tester.pumpAndSettle();
    expect(identical(position, _position(tester)), isTrue);
    expect(readerOpens, 0);
    expect(recommendations, 0);
    for (var i = 0; i < 30 && recommendations == 0; i++) {
      await tester.drag(find.byKey(const ValueKey('pixiv-detail-page-scroll')),
          const Offset(0, -420));
      await tester.pumpAndSettle();
    }
    expect(recommendations, 1);
    expect(identical(position, _position(tester)), isTrue);
    expect(tester.takeException(), isNull);
  });
}
