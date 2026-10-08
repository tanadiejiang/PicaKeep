import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/pixiv_bookmark_button.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
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
}
