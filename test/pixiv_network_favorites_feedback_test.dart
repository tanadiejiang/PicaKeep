import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/comic_source/favorite_data.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/components/pixiv_bookmark_feedback.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/pixiv_network/pixiv_models.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/favorites/network_favorites_page.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationCachePath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

// Images may fail to load, but even covers cannot escape to a real network.
class _OfflineHttp extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _OfflineClient();
}

class _OfflineClient implements HttpClient {
  @override
  set autoUncompress(bool value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      throw const SocketException('Offline cover fixture');
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected network call: ${invocation.memberName}');
}

class _Favorites {
  _Favorites({String key = 'pixiv'}) {
    source = ComicSource.named(
      key: key,
      name: '测试$key',
      data: {'token': 'offline-account', 'userId': '99'},
      favoriteData: FavoriteData(
        key: key,
        title: '平台收藏',
        loadComic: (page, [folder]) async {
          loads.add((page, folder));
          return Res<List<BaseComic>>([first, second], subData: 1);
        },
        addOrDelFavorite: (comic, isAdding) {
          writes.add((comic.id, isAdding));
          return pending?.future ?? Future.value(result);
        },
      ),
    );
  }
  final first = const PixivComicBrief(
      id: '123',
      title: '离线收藏作品甲',
      author: '作者甲',
      cover: 'https://offline.invalid/first.png',
      tags: [],
      illustType: pixivIllustTypeIllust,
      pageCount: 1,
      isBookmarked: true);
  final second = const PixivComicBrief(
      id: '456',
      title: '离线收藏作品乙',
      author: '作者乙',
      cover: 'https://offline.invalid/second.png',
      tags: [],
      illustType: pixivIllustTypeIllust,
      pageCount: 1,
      isBookmarked: true);
  late final ComicSource source;
  final loads = <(int, String?)>[];
  final writes = <(String, bool)>[];
  Res<bool> result = const Res(true);
  Completer<Res<bool>>? pending;
}

Finder get _capsule => find.byKey(const ValueKey('pixiv-bookmark-feedback'));

void main() {
  late Directory temp;
  late List<String> settings;
  late List<ComicSource> sources;
  final paths = PathProviderPlatform.instance;
  final savedHttp = HttpOverrides.current;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('pk-platform-feedback-');
    PathProviderPlatform.instance = _Paths(temp.path);
    await App.init(dataPathOverride: temp.path);
  });
  tearDownAll(() async {
    HistoryManager().dispose();
    LocalFavoritesManager().dispose();
    PathProviderPlatform.instance = paths;
    await temp.delete(recursive: true);
  });
  setUp(() {
    settings = List.of(appdata.settings);
    sources = List.of(ComicSource.sources);
    appdata.settings[44] = '1';
    appdata.settings[72] = '0';
    appdata.settings[73] = '0';
    appdata.settings[comicTileDisplayConfigSettingIndex] = '';
    HttpOverrides.global = _OfflineHttp();
  });
  tearDown(() {
    HttpOverrides.global = savedHttp;
    appdata.settings
      ..clear()
      ..addAll(settings);
    ComicSource.sources
      ..clear()
      ..addAll(sources);
  });

  Future<GlobalKey<NavigatorState>> pumpFavorites(
      WidgetTester tester, _Favorites fixture,
      {double textScale = 1}) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    ComicSource.sources
      ..clear()
      ..add(fixture.source);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [NaviObserver()],
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!),
      home: Scaffold(body: NetworkFavoriteWidget(source: fixture.source)),
    ));
    await tester.pumpAndSettle();
    expect(fixture.loads, [(1, null)]);
    expect(find.byType(DownloadedComicTile), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    return navigator;
  }

  Future<void> openConfirmation(WidgetTester tester, _Favorites fixture) async {
    final card = find.byWidgetPredicate((widget) =>
        widget is DownloadedComicTile && widget.name == fixture.first.title);
    await tester.longPress(card);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, '取消收藏'), findsOneWidget);
    expect(fixture.writes, isEmpty);
    await tester.tap(find.widgetWithText(ListTile, '取消收藏'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('确定要取消收藏「${fixture.first.title}」吗？'), findsOneWidget);
    expect(fixture.writes, isEmpty);
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, '确认'));
    await tester.pumpAndSettle();
  }

  void expectCapsule(WidgetTester tester, String text) {
    expect(find.text(text), findsOneWidget);
    expect(_capsule, findsOneWidget);
    final rect = tester.getRect(_capsule);
    final host = tester.getRect(find.byType(NetworkFavoriteWidget));
    expect(rect.left, greaterThanOrEqualTo(host.left));
    expect(rect.right, lessThanOrEqualTo(host.right));
    expect(rect.top, greaterThanOrEqualTo(host.top));
    expect(rect.bottom, lessThanOrEqualTo(host.bottom - 15));
    expect(rect.height, greaterThanOrEqualTo(48));
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  }

  testWidgets('menu and cancelled confirmation make zero bookmark writes',
      (tester) async {
    final fixture = _Favorites();
    await pumpFavorites(tester, fixture);
    await openConfirmation(tester, fixture);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(fixture.writes, isEmpty);
    expect(fixture.loads, [(1, null)]);
    expect(find.byType(DownloadedComicTile), findsNWidgets(2));
    expect(_capsule, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirmed Pixiv removal removes only its item and shows capsule',
      (tester) async {
    final fixture = _Favorites()..pending = Completer<Res<bool>>();
    await pumpFavorites(tester, fixture);
    await openConfirmation(tester, fixture);
    await confirm(tester);
    expect(fixture.writes, [('123', false)]);
    expect(find.byType(DownloadedComicTile), findsNWidgets(2));
    expect(find.text('已取消收藏'), findsNothing);
    fixture.pending!.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadedComicTile), findsOneWidget);
    expect(find.text(fixture.first.title), findsNothing);
    expect(find.text(fixture.second.title), findsOneWidget);
    expectCapsule(tester, '已取消收藏');
    expect(fixture.loads, [(1, null)]);
    expect(fixture.writes, [('123', false)]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pixiv failure keeps item and the complete specific reason',
      (tester) async {
    final fixture = _Favorites()
      ..result = const Res.error('离线权限不足：当前账号不能取消这项收藏，请重新登录。');
    await pumpFavorites(tester, fixture, textScale: 2);
    await openConfirmation(tester, fixture);
    await confirm(tester);
    expect(fixture.writes, [('123', false)]);
    expect(find.byType(DownloadedComicTile), findsNWidgets(2));
    const message = '收藏失败：离线权限不足：当前账号不能取消这项收藏，请重新登录。';
    expectCapsule(tester, message);
    final text = tester.widget<Text>(find.text(message));
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    expect(tester.getRect(find.text(message)).height, greaterThan(56));
    expect(fixture.loads, [(1, null)]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final success in [true, false]) {
    testWidgets(
        'late Pixiv ${success ? "success" : "failure"} stays silent across route',
        (tester) async {
      final fixture = _Favorites()..pending = Completer<Res<bool>>();
      final navigator = await pumpFavorites(tester, fixture);
      await openConfirmation(tester, fixture);
      await confirm(tester);
      navigator.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Center(child: Text('离线详情页')))));
      await tester.pumpAndSettle();
      fixture.pending!
          .complete(success ? const Res(true) : const Res.error('迟到取消失败'));
      await tester.pumpAndSettle();
      expect(_capsule, findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(_capsule, findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      // UI invalidation suppresses feedback; it does not discard business success.
      expect(find.byType(DownloadedComicTile),
          success ? findsOneWidget : findsNWidgets(2));
      expect(fixture.writes, [('123', false)]);
      expect(fixture.loads, [(1, null)]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('other sources retain their original failure SnackBar',
      (tester) async {
    final fixture = _Favorites(key: 'jm')..result = const Res.error('离线其他源原因');
    await pumpFavorites(tester, fixture);
    expect(find.byType(PixivBookmarkFeedbackHost), findsNothing);
    await openConfirmation(tester, fixture);
    await confirm(tester);
    expect(fixture.writes, [('123', false)]);
    expect(find.byType(DownloadedComicTile), findsNWidgets(2));
    expect(_capsule, findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('操作失败：离线其他源原因'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'other source success keeps removal behavior without Pixiv feedback',
      (tester) async {
    final fixture = _Favorites(key: 'jm');
    await pumpFavorites(tester, fixture);
    await openConfirmation(tester, fixture);
    await confirm(tester);
    expect(find.byType(DownloadedComicTile), findsOneWidget);
    expect(find.text(fixture.second.title), findsOneWidget);
    expect(fixture.writes, [('123', false)]);
    expect(_capsule, findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(fixture.loads, [(1, null)]);
    expect(tester.takeException(), isNull);
  });
}
