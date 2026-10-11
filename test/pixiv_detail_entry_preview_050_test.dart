import 'dart:async';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
import 'package:picakeep/foundation/pixiv_detail_preview.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/pixiv_detail_shell.dart';
import 'package:picakeep/pages/online_comic/pixiv_online_detail_view.dart';
import 'package:picakeep/pages/online_common/online_comic_list_item.dart';
import 'package:sqlite3/open.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';
  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

class _Image extends ImageProvider<_Image> {
  final frame = Completer<ImageInfo>();
  @override
  Future<_Image> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(_Image key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(frame.future);
}

const _author =
    PixivAuthor(id: '42', name: '050作者', avatar: '', comment: '', following: 0);
PixivComicInfo _info(
        {int pages = 2,
        String regular = '',
        String avatar = '',
        String title = '050权威作品标题',
        String authorName = '050作者',
        bool? commentsDisabled,
        String? description}) =>
    PixivComicInfo(
        id: '123',
        title: title,
        author: authorName,
        authorId: '42',
        coverUrl: '',
        regularUrl: regular,
        authorAvatar: avatar,
        tags: const [],
        description:
            description ?? List.filled(80, 'Fixture description.').join('\n'),
        commentsDisabled: commentsDisabled,
        pageCount: pages,
        illustType: pixivIllustTypeIllust,
        likeCount: 0,
        viewCount: 0,
        width: 400,
        height: 600,
        isOriginal: false,
        createDate: '',
        uploadDate: '',
        userId: '42',
        isBookmarkable: true);
PixivPage _imagePage({String regular = ''}) => PixivPage(
    thumbMini: '',
    small: '',
    regular: regular,
    original: '',
    width: 400,
    height: 600);
Widget _page(
    {PixivDetailPreview? preview,
    Future<Res<PixivComicInfo>> Function()? detail,
    Future<Res<List<PixivPage>>> Function(String)? pages,
    Future<Res<PixivAuthor>> Function(String)? author,
    String Function()? account,
    VoidCallback? authorFeed,
    VoidCallback? relatedFeed,
    VoidCallback? comments,
    PixivDetailEntry? entry,
    PixivDetailSession? session}) {
  final view = PixivOnlineDetailView(
    comicId: '123',
    initialPreview: preview,
    accountIdentity: account ?? () => 'account-a',
    loadDetail: detail ?? () async => Res(_info()),
    loadPages: pages ?? (_) async => Res([_imagePage(), _imagePage()]),
    loadAuthor: author ?? (_) async => const Res(_author),
    loadAuthorWorkIds: (_) async {
      authorFeed?.call();
      return const Res([]);
    },
    loadAuthorPreviewWorks: (_, __) async => const Res([]),
    loadRecommendations: (_) async {
      relatedFeed?.call();
      return const Res(PixivRecommendationsPage(items: [], nextIds: []));
    },
    loadRecommendationWorks: (_) async => const Res([]),
    loadCommentRoots: (_, __, ___) async {
      comments?.call();
      return const Res(
          PixivCommentPage(comments: [], hasNext: false, originalCount: 0));
    },
    loadCommentReplies: (_, __) async => const Res(
        PixivCommentPage(comments: [], hasNext: false, originalCount: 0)),
    writeBookmark: (_, {required isAdding, required isPrivate}) async =>
        Res(isAdding),
    onRead: (_, __, ___) {},
    onDownload: (_, __) {},
    onDownloadLongPress: (_, __) {},
    onTagTap: (_, __, ___) {},
  );
  final child =
      entry == null ? view : PixivDetailEntryScope(entry: entry, child: view);
  return MaterialApp(
      home: session == null
          ? child
          : PixivDetailSessionScope(session: session, child: child));
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

PixivDetailShell _shell(WidgetTester tester) =>
    tester.widget<PixivDetailShell>(find.byType(PixivDetailShell));
Future<ui.Image> _image(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 40, 60), Paint()..color = Colors.indigo);
      final picture = recorder.endRecording();
      final image = await picture.toImage(40, 60);
      picture.dispose();
      return image;
    }))!;
PixivDetailPreview _seed(ImageProvider<Object> provider,
        {String id = '123',
        String account = 'account-a',
        bool Function()? owner}) =>
    PixivDetailPreview(
        workId: id,
        provider: provider,
        aspectRatio: 2 / 3,
        aspectRatioKnown: true,
        pageCount: 2,
        accountIdentity: account,
        ownerIsCurrent: owner);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
      OperatingSystem.windows,
      () =>
          DynamicLibrary.open('${Directory.current.path}/windows/sqlite3.dll'));
  late Directory workspace;
  final originalPaths = PathProviderPlatform.instance;
  late List<ComicSource> oldSources;
  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('pixiv050_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: '${workspace.path}/data');
  });
  tearDownAll(() async {
    PixivNetwork().cookieJar.dispose();
    PathProviderPlatform.instance = originalPaths;
    await workspace.delete(recursive: true);
  });
  setUp(() {
    oldSources = List.of(ComicSource.sources);
    ComicSource.sources
      ..clear()
      ..add(ComicSource.named(
          key: 'pixiv', name: 'Pixiv', data: {'token': 'account-a'}));
    PixivBookmarkStateStore.shared.clear();
  });
  tearDown(() {
    ComicSource.sources
      ..clear()
      ..addAll(oldSources);
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  testWidgets(
      '050 metadata preview is immediate and has no authoritative actions',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final detail = Completer<Res<PixivComicInfo>>();
    final pages = Completer<Res<List<PixivPage>>>();
    final provider = _Image();
    final image = await _image(tester);
    provider.frame.complete(ImageInfo(image: image.clone()));
    await tester.pumpWidget(_page(
        preview: _seed(provider),
        detail: () => detail.future,
        pages: (_) => pages.future));
    await _frames(tester);
    expect(
        find.byKey(ValueKey<(String, ImageProvider<Object>)>(
            ('pixiv-metadata-preview', provider))),
        findsOneWidget);
    expect(find.byType(RawImage), findsOneWidget);
    expect(find.byType(PixivDetailShell), findsNothing);
    expect(find.text('050权威作品标题'), findsNothing);
    expect(find.byTooltip('下载'), findsNothing);
    expect(find.byKey(const ValueKey('pixiv-detail-favorite')), findsNothing);
    expect(find.byKey(const ValueKey('pixiv-image-counter')), findsNothing);
    expect(find.byTooltip('返回'), findsOneWidget);
    detail.complete(Res(_info()));
    await _frames(tester);
    expect(_shell(tester).imagesLoading, isTrue);
    expect(_shell(tester).images.single.previewProvider, same(provider));
    expect(_shell(tester).images.single.provider, isNull);
    expect(find.text('高清图片加载失败'), findsNothing);
    expect(
        tester
            .widget<Opacity>(
                find.byKey(const ValueKey('pixiv-header-ready-opacity-main')))
            .opacity,
        1);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('pixiv-image-counter')))
            .data,
        '…');
    pages.complete(Res([_imagePage(), _imagePage()]));
    await _frames(tester);
    expect(_shell(tester).images.length, 2);
    expect(_shell(tester).images[0].previewProvider, same(provider));
    expect(_shell(tester).images[1].previewProvider, isNull);
    expect(_shell(tester).images[1].previewFallbackProvider, isNull);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('pixiv-image-counter')))
            .data,
        '1 / 2');
    image.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '050 session scope supplies cover when widget has no explicit seed',
      (tester) async {
    final provider = _Image();
    final image = await _image(tester);
    provider.frame.complete(ImageInfo(image: image.clone()));
    final detail = Completer<Res<PixivComicInfo>>();
    final entry = PixivDetailEntry(
        key: 'pixiv123',
        comicId: '123',
        preview: _seed(provider),
        builder: (_) => const SizedBox());
    await tester.pumpWidget(_page(entry: entry, detail: () => detail.future));
    await _frames(tester);
    expect(
        find.byKey(ValueKey<(String, ImageProvider<Object>)>(
            ('pixiv-metadata-preview', provider))),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    detail.complete(Res(_info()));
    await _frames(tester);
    image.dispose();
    expect(tester.takeException(), isNull);
  });

  for (final invalid in ['work', 'account', 'owner']) {
    testWidgets('050 rejects $invalid mismatched cover before metadata',
        (tester) async {
      final provider = _Image();
      final detail = Completer<Res<PixivComicInfo>>();
      final preview = _seed(provider,
          id: invalid == 'work' ? '456' : '123',
          account: invalid == 'account' ? 'account-b' : 'account-a',
          owner: () => invalid != 'owner');
      await tester
          .pumpWidget(_page(preview: preview, detail: () => detail.future));
      await _frames(tester);
      expect(
          find.byKey(ValueKey<(String, ImageProvider<Object>)>(
              ('pixiv-metadata-preview', provider))),
          findsNothing);
      expect(find.byType(Image), findsNothing);
      await tester.pumpWidget(const SizedBox());
      detail.complete(Res(_info()));
      await _frames(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      '050 missing single avatar reads once without author feed related feed or comments',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var profile = 0;
    var authors = 0;
    var related = 0;
    var comments = 0;
    await tester.pumpWidget(_page(
        detail: () async => Res(_info(pages: 1)),
        author: (_) async {
          profile++;
          return const Res(_author);
        },
        authorFeed: () => authors++,
        relatedFeed: () => related++,
        comments: () => comments++));
    await _frames(tester);
    await _frames(tester);
    expect(_shell(tester).showSingleAuthorAvatar, isTrue);
    expect(_shell(tester).galleryCollapsible, isFalse);
    expect(profile, 1);
    expect(authors, 0);
    expect(related, 0);
    expect(comments, 0);
    expect(find.byKey(const ValueKey('pixiv-single-author-avatar')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '050 known single avatar paints cached pixels without profile fetch',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const url = 'https://fixture.invalid/known-single-avatar.png';
    final avatar = onlineCoverProvider(url: url, headers: const {
      'Referer': 'https://www.pixiv.net/',
      'User-Agent': PixivNetwork.pixivWebUA,
    });
    final image = await _image(tester);
    imageCache.putIfAbsent(
        await avatar.obtainKey(ImageConfiguration.empty),
        () => OneFrameImageStreamCompleter(
            Future.value(ImageInfo(image: image.clone()))));
    var profiles = 0;
    await tester.pumpWidget(_page(
        detail: () async => Res(_info(pages: 1, avatar: url)),
        author: (_) async {
          profiles++;
          return const Res(_author);
        }));
    await _frames(tester);
    final slot = find.byKey(const ValueKey('pixiv-single-author-avatar'));
    expect(tester.getSize(slot), const Size.square(48));
    expect(find.descendant(of: slot, matching: find.byType(RawImage)),
        findsOneWidget);
    expect(_shell(tester).authorAvatarUrl, url);
    expect(profiles, 0);
    image.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('050 failed single avatar only retries after explicit request',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var profiles = 0;
    var feeds = 0;
    await tester.pumpWidget(_page(
        detail: () async => Res(_info(pages: 1)),
        author: (_) async {
          profiles++;
          return profiles == 1
              ? const Res<PixivAuthor>(null,
                  errorMessage: 'offline avatar failure')
              : const Res(_author);
        },
        authorFeed: () => feeds++,
        relatedFeed: () => feeds++,
        comments: () => feeds++));
    await _frames(tester);
    await _frames(tester);
    expect(profiles, 1);
    expect(
        _shell(tester).authorAvatarError, contains('offline avatar failure'));
    _shell(tester).onRetryAuthorAvatar!();
    await _frames(tester);
    await _frames(tester);
    expect(profiles, 2);
    expect(feeds, 0);
    expect(_shell(tester).authorAvatarError, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '050 evicted production detail reuses completed detail and page responses until explicit refresh',
      (tester) async {
    final session =
        PixivDetailSession(scope: PixivDetailScope.search, entries: const []);
    addTearDown(session.dispose);
    var details = 0;
    var pages = 0;
    Widget host() => _page(
        session: session,
        detail: () async {
          details++;
          return Res(_info());
        },
        pages: (_) async {
          pages++;
          return Res([_imagePage(), _imagePage()]);
        });
    await tester.pumpWidget(host());
    await _frames(tester);
    expect(details, 1);
    expect(pages, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pumpWidget(host());
    await _frames(tester);
    expect(details, 1);
    expect(pages, 1);
    _shell(tester).onMenu!('refresh');
    await _frames(tester);
    expect(details, 2);
    expect(pages, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '050 empty detail title and author have honest labels then profile name fills header',
      (tester) async {
    final profile = Completer<Res<PixivAuthor>>();
    await tester.pumpWidget(_page(
        detail: () async => Res(_info(pages: 1, title: ' ', authorName: ' ')),
        author: (_) => profile.future));
    await _frames(tester);
    expect(_shell(tester).title, '作品 123');
    expect(_shell(tester).author, '作者 42');
    profile.complete(const Res(_author));
    await _frames(tester);
    expect(_shell(tester).author, '050作者');
    expect(tester.takeException(), isNull);
  });

  for (final disabled in <bool?>[true, false, null]) {
    testWidgets(
        '051 real View commentOff=$disabled reaches the comment section',
        (tester) async {
      var requests = 0;
      await tester.pumpWidget(_page(
        detail: () async => Res(_info(
            pages: 1,
            commentsDisabled: disabled,
            description: '051 offline detail fixture')),
        comments: () => requests++,
      ));
      await _frames(tester);
      final target = find.text(disabled == true ? '作者已关闭评论区' : '评论');
      await tester.scrollUntilVisible(target, 200,
          scrollable: find.byType(Scrollable).first);
      await _frames(tester);
      if (disabled == true) {
        expect(find.text('作者已关闭评论区'), findsOneWidget);
        expect(find.byTooltip('重试'), findsNothing);
        expect(requests, 0);
      } else {
        expect(find.text('作者已关闭评论区'), findsNothing);
        expect(find.text('暂无评论'), findsOneWidget);
        expect(requests, 1);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      '050 account change drops pending page result and expired preview',
      (tester) async {
    var account = 'account-a';
    final pages = Completer<Res<List<PixivPage>>>();
    final provider = _Image();
    final image = await _image(tester);
    provider.frame.complete(ImageInfo(image: image.clone()));
    final preview = _seed(provider);
    await tester.pumpWidget(_page(
        preview: preview, account: () => account, pages: (_) => pages.future));
    await _frames(tester);
    expect(_shell(tester).images.single.previewProvider, same(provider));
    account = 'account-b';
    await tester.pumpWidget(_page(
        preview: preview, account: () => account, pages: (_) => pages.future));
    pages.complete(Res([_imagePage(), _imagePage()]));
    await _frames(tester);
    expect(_shell(tester).images, isEmpty);
    expect(_shell(tester).imagesLoading, isTrue);
    image.dispose();
    expect(tester.takeException(), isNull);
  });
}
