import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/pixiv_author_page_v2.dart';
import 'package:picakeep/pages/online_common/online_waterfall_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef _SetFollow = Future<Res<bool>> Function(String uid,
    {required bool isFollowing});

PixivAuthor _author(String uid, {bool followed = false}) => PixivAuthor(
      id: uid,
      name: '画师$uid',
      avatar: '',
      comment: '',
      following: 426,
      isFollowed: followed,
    );

final _follow = find.byKey(const ValueKey('pixiv-author-follow'));

Finder _followLabel(String value) =>
    find.descendant(of: _follow, matching: find.text(value));

Widget _page({
  String uid = '42',
  bool followed = false,
  Future<Res<PixivAuthor>> Function(String)? loadAuthor,
  Future<Res<List<PixivComicBrief>>> Function(String, int)? loadWorks,
  _SetFollow? setFollow,
  bool Function()? isLoggedIn,
  String Function()? currentUserId,
  Future<void> Function(BuildContext)? manageAccounts,
  Future<void> Function(BuildContext)? openTagSettings,
}) =>
    MaterialApp(
      home: PixivAuthorPageV2(
        uid,
        loadAuthor:
            loadAuthor ?? (id) async => Res(_author(id, followed: followed)),
        loadWorks: loadWorks ?? (_, __) async => const Res([], subData: 0),
        setFollow: setFollow,
        isLoggedIn: isLoggedIn,
        currentUserId: currentUserId,
        manageAccounts: manageAccounts,
        openTagSettings: openTagSettings,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<ComicSource> sources;
  late List<String> settings;
  late Directory tempRoot;

  setUpAll(() async {
    tempRoot = await Directory.systemTemp.createTemp('pk-author-follow-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => tempRoot.path);
    await App.init(dataPathOverride: tempRoot.path);
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    await tempRoot.delete(recursive: true);
  });

  setUp(() {
    sources = List.of(ComicSource.sources);
    settings = List.of(appdata.settings);
    final pixiv = ComicSource.named(key: 'pixiv', name: 'Pixiv');
    pixiv.data['token'] = 'test-session';
    pixiv.data['userId'] = '99';
    ComicSource.sources
      ..clear()
      ..add(pixiv);
    appdata.settings[comicTileDisplayConfigSettingIndex] = '';
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

  testWidgets('initial and reopened author pages use server follow state',
      (tester) async {
    var reads = 0;
    Future<Res<PixivAuthor>> load(String uid) async {
      reads++;
      return Res(_author(uid, followed: true));
    }

    await tester.pumpWidget(_page(loadAuthor: load));
    await tester.pumpAndSettle();
    expect(_followLabel('已关注'), findsOneWidget);
    expect(find.text('uid 42 · 426 关注'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_page(loadAuthor: load));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(_followLabel('已关注'), findsOneWidget);
  });

  testWidgets('follow writes are serial, block refresh and preserve following',
      (tester) async {
    final results = <Completer<Res<bool>>>[];
    final targets = <bool>[];
    var reads = 0;
    var works = 0;
    await tester.pumpWidget(_page(
      loadAuthor: (uid) async {
        reads++;
        return Res(_author(uid));
      },
      loadWorks: (_, __) async {
        works++;
        return const Res([], subData: 0);
      },
      setFollow: (uid, {required isFollowing}) {
        expect(uid, '42');
        targets.add(isFollowing);
        final result = Completer<Res<bool>>();
        results.add(result);
        return result.future;
      },
    ));
    await tester.pumpAndSettle();
    await tester.tap(_follow);
    await tester.pump();
    await tester.tap(_follow);
    expect(targets, [true]);
    expect(tester.widget<FilledButton>(_follow).onPressed, isNull);
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '刷新作者页'))
            .onPressed,
        isNull);
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    expect(reads, 1);
    expect(works, 1);
    results[0].complete(const Res(true));
    await tester.pumpAndSettle();
    expect(_followLabel('已关注'), findsOneWidget);
    expect(find.text('uid 42 · 426 关注'), findsOneWidget);
    await tester.tap(_follow);
    await tester.pump();
    expect(targets, [true, false]);
    results[1].complete(const Res(false));
    await tester.pumpAndSettle();
    expect(_followLabel('关注'), findsOneWidget);
    expect(find.text('uid 42 · 426 关注'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed follow and unfollow retain state and allow retry',
      (tester) async {
    var attempts = 0;
    final targets = <bool>[];
    await tester.pumpWidget(_page(
      followed: true,
      setFollow: (_, {required isFollowing}) async {
        targets.add(isFollowing);
        attempts++;
        if (attempts == 1) return const Res.error('没有权限');
        if (attempts == 2) throw StateError('offline');
        return Res(isFollowing);
      },
    ));
    await tester.pumpAndSettle();
    await tester.tap(_follow);
    await tester.pumpAndSettle();
    expect(_followLabel('已关注'), findsOneWidget);
    expect(find.text('操作失败：没有权限'), findsOneWidget);
    await tester.tap(_follow);
    await tester.pumpAndSettle();
    expect(_followLabel('已关注'), findsOneWidget);
    expect(tester.widget<FilledButton>(_follow).onPressed, isNotNull);
    await tester.tap(_follow);
    await tester.pumpAndSettle();
    expect(targets, [false, false, false]);
    expect(_followLabel('关注'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('login returns to fresh profile without automatically following',
      (tester) async {
    var loggedIn = false;
    var reads = 0;
    var accountOpens = 0;
    var writes = 0;
    final account = Completer<void>();
    await tester.pumpWidget(_page(
      isLoggedIn: () => loggedIn,
      loadAuthor: (uid) async {
        reads++;
        return Res(_author(uid, followed: loggedIn));
      },
      manageAccounts: (_) {
        accountOpens++;
        return account.future;
      },
      setFollow: (_, {required isFollowing}) async {
        writes++;
        return Res(isFollowing);
      },
    ));
    await tester.pumpAndSettle();
    expect(_followLabel('登录后关注'), findsOneWidget);
    await tester.tap(_follow);
    await tester.pump();
    await tester.tap(_follow);
    expect(accountOpens, 1);
    expect(writes, 0);
    loggedIn = true;
    account.complete();
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(writes, 0);
    expect(_followLabel('已关注'), findsOneWidget);
    await tester.tap(_follow);
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(_followLabel('关注'), findsOneWidget);
  });

  testWidgets(
      'a follow failure immediately replaces an earlier success message',
      (tester) async {
    var attempts = 0;
    await tester.pumpWidget(_page(
      setFollow: (_, {required isFollowing}) async {
        attempts++;
        return attempts == 1 ? Res(isFollowing) : const Res.error('暂不可用');
      },
    ));
    await tester.pumpAndSettle();
    await tester.tap(_follow);
    await tester.pumpAndSettle();
    expect(
        find.descendant(of: find.byType(SnackBar), matching: find.text('已关注')),
        findsOneWidget);
    await tester.tap(_follow);
    await tester.pumpAndSettle();
    expect(_followLabel('已关注'), findsOneWidget);
    expect(find.text('操作失败：暂不可用'), findsOneWidget);
    expect(
        find.descendant(of: find.byType(SnackBar), matching: find.text('已关注')),
        findsNothing);
  });

  testWidgets('own profile uses account UID and cannot follow itself',
      (tester) async {
    ComicSource.require('pixiv').data['userId'] = '42';
    var writes = 0;
    await tester.pumpWidget(_page(
      setFollow: (_, {required isFollowing}) async {
        writes++;
        return Res(isFollowing);
      },
    ));
    await tester.pumpAndSettle();
    expect(_followLabel('这是你自己'), findsOneWidget);
    expect(tester.widget<FilledButton>(_follow).onPressed, isNull);
    await tester.tap(_follow);
    expect(writes, 0);
  });

  testWidgets('author change cannot receive an earlier author follow result',
      (tester) async {
    final old = Completer<Res<bool>>();
    Future<Res<bool>> write(String uid, {required bool isFollowing}) {
      expect(uid, '42');
      return old.future;
    }

    await tester.pumpWidget(_page(setFollow: write));
    await tester.pumpAndSettle();
    await tester.tap(_follow);
    await tester.pump();
    await tester.pumpWidget(_page(uid: '43', setFollow: write));
    await tester.pumpAndSettle();
    expect(_followLabel('关注'), findsOneWidget);
    old.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(find.text('画师43'), findsNWidgets(2));
    expect(_followLabel('关注'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposed follow and account operations ignore late completion',
      (tester) async {
    final old = Completer<Res<bool>>();
    await tester.pumpWidget(
        _page(setFollow: (_, {required isFollowing}) => old.future));
    await tester.pumpAndSettle();
    await tester.tap(_follow);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    old.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final login = Completer<void>();
    var reads = 0;
    await tester.pumpWidget(_page(
      isLoggedIn: () => false,
      loadAuthor: (uid) async {
        reads++;
        return Res(_author(uid));
      },
      manageAccounts: (_) => login.future,
    ));
    await tester.pumpAndSettle();
    await tester.tap(_follow);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    login.complete();
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile refresh disables writes until fresh state arrives',
      (tester) async {
    final refresh = Completer<Res<PixivAuthor>>();
    var reads = 0;
    final targets = <bool>[];
    await tester.pumpWidget(_page(
      loadAuthor: (uid) {
        reads++;
        return reads == 1 ? Future.value(Res(_author(uid))) : refresh.future;
      },
      setFollow: (_, {required isFollowing}) async {
        targets.add(isFollowing);
        return Res(isFollowing);
      },
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('刷新作者页'));
    await tester.pump();
    expect(tester.widget<FilledButton>(_follow).onPressed, isNull);
    await tester.tap(_follow);
    expect(targets, isEmpty);
    refresh.complete(Res(_author('42', followed: true)));
    await tester.pumpAndSettle();
    expect(_followLabel('已关注'), findsOneWidget);
    await tester.tap(_follow);
    await tester.pumpAndSettle();
    expect(targets, [false]);
  });

  testWidgets('account changes during a write trigger fresh account state',
      (tester) async {
    final write = Completer<Res<bool>>();
    var accountUid = '99';
    var reads = 0;
    await tester.pumpWidget(_page(
      currentUserId: () => accountUid,
      loadAuthor: (uid) async {
        reads++;
        return Res(_author(uid));
      },
      setFollow: (_, {required isFollowing}) => write.future,
    ));
    await tester.pumpAndSettle();
    await tester.tap(_follow);
    await tester.pump();
    accountUid = '100';
    write.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(_followLabel('关注'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('author card tags update immediately without profile reload',
      (tester) async {
    var reads = 0;
    var works = 0;
    await tester.pumpWidget(_page(
      loadAuthor: (uid) async {
        reads++;
        return Res(_author(uid));
      },
      loadWorks: (_, __) async {
        works++;
        return const Res([
          PixivComicBrief(
            id: '1',
            title: '作品',
            cover: '',
            author: '画师',
            tags: ['猫', '风景'],
            illustType: 0,
            pageCount: 1,
            width: 100,
            height: 160,
          ),
        ], subData: 1);
      },
    ));
    await tester.pumpAndSettle();
    var card =
        tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
    expect(card.tags, ['猫', '风景']);
    expect(card.tagConfig.showTags, isFalse);
    await tester.tap(find.byTooltip('瀑布流标签设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
        find.byKey(const ValueKey('waterfall-pixivAuthor-switch')));
    await tester
        .tap(find.byKey(const ValueKey('waterfall-pixivAuthor-switch')));
    await tester.pump();
    await tester.ensureVisible(
        find.byKey(const ValueKey('waterfall-pixivAuthor-row-1')));
    await tester.tap(find.byKey(const ValueKey('waterfall-pixivAuthor-row-1')));
    await tester.pump();
    final version = App.displaySettingsVersion.value;
    await tester.runAsync(() async {
      final saved = Completer<void>();
      void onSaved() {
        if (App.displaySettingsVersion.value != version && !saved.isCompleted) {
          saved.complete();
        }
      }

      App.displaySettingsVersion.addListener(onSaved);
      try {
        await tester.tap(find.widgetWithText(FilledButton, '确定'));
        await saved.future.timeout(const Duration(seconds: 10));
      } finally {
        App.displaySettingsVersion.removeListener(onSaved);
      }
    });
    await tester.pumpAndSettle();
    card = tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
    expect(card.tagConfig.showTags, isTrue);
    expect(card.tagConfig.maxTagRows, 1);
    expect(reads, 1);
    expect(works, 1);
    expect(readComicTileDisplaySettings().localIllustTags.showTags, isFalse);
    final stored =
        jsonDecode(appdata.settings[comicTileDisplayConfigSettingIndex])
            as Map<String, dynamic>;
    expect((stored['waterfall'] as Map)['pixivAuthor'],
        {'showTags': true, 'tagRows': 1});
    final diskSettings = await tester.runAsync(() async =>
        jsonDecode(await File('${tempRoot.path}/settings').readAsString())
            as List<dynamic>);
    expect(diskSettings![comicTileDisplayConfigSettingIndex],
        appdata.settings[comicTileDisplayConfigSettingIndex]);
    // The notifier also refreshes an already visible wall after another page
    // changes its display settings.
    appdata.settings[comicTileDisplayConfigSettingIndex] = '';
    App.notifyDisplaySettingsChanged();
    await tester.pumpAndSettle();
    card = tester.widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard));
    expect(card.tagConfig.showTags, isFalse);
    expect(reads, 1);
    expect(works, 1);
  });

  testWidgets('follow control fits narrow screens and large text while busy',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final write = Completer<Res<bool>>();
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.8)),
        child: child!,
      ),
      home: PixivAuthorPageV2(
        '42',
        isLoggedIn: () => true,
        currentUserId: () => '99',
        loadAuthor: (uid) async => Res(_author(uid, followed: true)),
        loadWorks: (_, __) async => const Res([], subData: 0),
        setFollow: (_, {required isFollowing}) => write.future,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(_follow);
    await tester.pump();
    expect(_followLabel('正在取消关注…'), findsOneWidget);
    expect(tester.takeException(), isNull);
    write.complete(const Res(false));
    await tester.pumpAndSettle();
    expect(_followLabel('关注'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
