import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/comic_source/built_in/pixiv.dart' as built_in;
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/pixiv_detail_preview.dart';
import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';
import 'package:picakeep/pages/online_comic/pixiv_comic_page_v2.dart';
import 'package:picakeep/pages/online_common/online_comic_list_item.dart';
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';
import 'package:picakeep/pages/online_common/online_waterfall_card.dart';

const _id = '150120670';
const _cover = 'https://i.pximg.net/c/250x250_80_a2/img-master/img/'
    '2026/09/26/11/42/32/${_id}_p0_square1200.jpg';
const _headers = <String, String>{
  'Referer': 'https://www.pixiv.net/',
  'User-Agent': 'fixture',
};

PixivComicBrief _comic({
  String id = _id,
  String cover = _cover,
  int? width = 600,
  int? height = 1200,
  String avatar = '',
}) =>
    PixivComicBrief(
      id: id,
      title: 'preview',
      cover: cover,
      author: 'artist',
      tags: const <String>[],
      illustType: 0,
      pageCount: 2,
      width: width,
      height: height,
      authorId: '7',
      authorAvatar: avatar,
    );

ComicSource _source({
  String account = 'account-a',
  String key = 'pixiv',
  Map<String, String> headers = _headers,
}) =>
    ComicSource.named(
      key: key,
      name: key,
      data: {'token': account},
      imageHeadersBuilder: (_) => headers,
      comicPageBuilder: (_) => const Text('mock detail builder'),
    );

ImageProvider<Object> _display(String url, int cacheWidth,
        {Map<String, String> headers = const {}}) =>
    ResizeImage.resizeIfNeeded(
        cacheWidth, null, onlineCoverProvider(url: url, headers: headers));

Future<void> _cacheFrame(
    WidgetTester tester, ImageProvider<Object> provider) async {
  final image = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 24, 48),
        ui.Paint()..color = const Color(0xFF2468AC));
    final picture = recorder.endRecording();
    final image = await picture.toImage(24, 48);
    picture.dispose();
    return image;
  });
  final key = await provider.obtainKey(ImageConfiguration.empty);
  PaintingBinding.instance.imageCache.putIfAbsent(
    key,
    () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image!))),
  );
  await tester.pump();
}

Widget _host(Widget child, {double dpr = 1}) => MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(devicePixelRatio: dpr),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 180, child: child),
          ),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    PixivDetailPreviewRegistry.shared.clear();
    clearOnlineCoverProviderCache();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });
  tearDown(() => PixivDetailPreviewRegistry.shared.clear());

  group('bounded rendition shape (not live CDN pixel evidence)', () {
    test('default helper remains 360 and cold candidates retain original', () {
      final small = pixivProportionalThumbUrl(_cover);
      expect(small, contains('/c/$kPixivProportionalThumbFrame/'));
      expect(pixivWaterfallThumbUrls(_cover), [small, _cover]);
      expect(kPixivProportionalThumbFrame, '360x360_70');
    });

    test('physical-longest-edge buckets, infinity and invalid budget bounded',
        () {
      for (final (budget, edge) in <(double, int)>[
        (-1, 540),
        (0, 540),
        (300, 540),
        (540, 540),
        (540.1, 720),
        (720, 720),
        (720.1, 1200),
        (5000, 1200),
        (double.infinity, 1200),
        (double.nan, 540),
      ]) {
        final candidates =
            pixivWaterfallThumbUrls(_cover, targetLongestEdge: budget);
        expect(candidates, hasLength(3));
        expect(candidates.first, contains('/c/${edge}x${edge}_80/'));
        expect(candidates.first, endsWith('_p0_master1200.jpg'));
        expect(candidates[1], pixivProportionalThumbUrl(_cover));
        expect(candidates.last, _cover);
      }
    });

    test('custom directory and suffix change together, query remains intact',
        () {
      const custom = 'https://i.pximg.net/c/128x128/custom-thumb/img/'
          '2021/01/31/20/35/53/87426718_p0_custom1200.jpg'
          '?token=_square1200.jpg#reference';
      final candidates =
          pixivWaterfallThumbUrls(custom, targetLongestEdge: 700);
      expect(
          Uri.parse(candidates.first).path,
          '/c/720x720_80/img-master/img/2021/01/31/20/35/53/'
          '87426718_p0_master1200.jpg');
      expect(Uri.parse(candidates.first).query, 'token=_square1200.jpg');
      expect(Uri.parse(candidates.first).fragment, 'reference');
      expect(candidates.last, custom);
    });

    test('unknown host/path/raw resource untouched; no invented original', () {
      for (final url in [
        'https://example.com/c/250x250_80_a2/img-master/img/'
            '2026/09/26/11/42/32/${_id}_p0_square1200.jpg',
        _cover.replaceFirst('i.pximg.net', 'i.pximg.net.example.com'),
        _cover.replaceFirst('https:', 'http:'),
        _cover.replaceFirst('i.pximg.net', 'user@i.pximg.net'),
        _cover.replaceFirst('i.pximg.net', 'i.pximg.net:8080'),
        _cover.replaceFirst('/img-master/', '/unknown-assets/'),
        _cover.replaceFirst('_square1200.jpg', '_unknown1200.jpg'),
        _cover.replaceFirst('/c/250x250_80_a2/', '/'),
        'https://i.pximg.net/img-original/img/2026/09/26/image.png',
      ]) {
        expect(
            pixivWaterfallThumbUrls('  $url  ', targetLongestEdge: 900), [url]);
      }
      expect(pixivWaterfallThumbUrls('  '), isEmpty);
    });

    test('known CDN host variants work, duplicate candidates are removed', () {
      for (final host in ['i.pximg.net', 'i-cf.pximg.net', 'i-f.pximg.net']) {
        final candidates = pixivWaterfallThumbUrls(
            _cover.replaceFirst('i.pximg.net', host),
            targetLongestEdge: 700);
        expect(Uri.parse(candidates.first).host, host);
        expect(candidates.first, contains('/c/720x720_80/'));
      }
      final small = pixivProportionalThumbUrl(_cover);
      expect(pixivWaterfallThumbUrls(small), [small]);
      expect(
          pixivWaterfallThumbUrls(small, targetLongestEdge: 720), hasLength(2));
    });
  });

  group('real entry factory', () {
    test(
        'cold seed preserves metadata and fit-bounds both thumbnail candidates',
        () {
      final source = _source();
      final seed = onlinePixivDetailPreview(
          source, _comic(avatar: 'https://i.pximg.net/avatar.jpg'))!;
      expect(seed.workId, _id);
      expect(seed.aspectRatio, .5);
      expect(seed.aspectRatioKnown, isTrue);
      expect(seed.pageCount, 2);
      expect(seed.authorAvatarUrl, 'https://i.pximg.net/avatar.jpg');
      expect(seed.accountIdentity, 'account-a');
      expect(seed.isCurrent, isTrue);
      final cold = seed.provider as ResizeImage;
      expect((cold.width, cold.height, cold.policy, cold.allowUpscaling),
          (360, 360, ResizeImagePolicy.fit, false));
      expect(
          cold.imageProvider,
          same(onlineCoverProvider(
              url: pixivProportionalThumbUrl(_cover), headers: _headers)));
      expect((seed.fallbackProvider! as ResizeImage).imageProvider,
          same(onlineCoverProvider(url: _cover, headers: _headers)));
      source.data['token'] = 'account-b';
      expect(seed.isCurrent, isFalse);
    });

    test('exact ready resize key is carried without fullscreen re-wrapping',
        () async {
      final source = _source();
      final provider = _display(
          pixivWaterfallThumbUrls(_cover, targetLongestEdge: 700).first, 235,
          headers: _headers);
      PixivDetailPreviewRegistry.shared.rememberReady(
        workId: _id,
        coverUrl: _cover,
        headers: _headers,
        accountIdentity: 'account-a',
        provider: provider,
      );
      final seed = onlinePixivDetailPreview(source, _comic())!;
      expect(seed.provider, same(provider));
      expect(await seed.provider.obtainKey(ImageConfiguration.empty),
          await provider.obtainKey(ImageConfiguration.empty));
      expect((seed.provider as ResizeImage).width, 235);
      expect(
          onlinePixivDetailPreview(_source(account: 'account-b'), _comic())!
              .provider,
          isNot(same(provider)));
      expect(
          onlinePixivDetailPreview(
                  _source(headers: const {
                    'Referer': 'https://www.pixiv.net/',
                    'User-Agent': 'other-fixture',
                  }),
                  _comic())!
              .provider,
          isNot(same(provider)));
      expect(onlinePixivDetailPreview(source, _comic(id: '9'))!.provider,
          isNot(same(provider)));
      expect(
          onlinePixivDetailPreview(
                  source, _comic(cover: _cover.replaceFirst('_p0_', '_p1_')))!
              .provider,
          isNot(same(provider)));
    });

    test('entry works with mock builder, production constructor receives seed',
        () {
      final entry = onlinePixivDetailEntry(_source(), _comic());
      expect(entry.key, 'online:$_id');
      expect(entry.comicId, _id);
      expect(entry.preview!.workId, _id);
      final page =
          built_in.pixiv.comicPageBuilder!(_comic()) as PixivComicPageV2;
      expect(page.comicId, _id);
      expect(page.initialPreview, isNotNull);
      expect(page.initialPreview!.workId, _id);
      expect(page.initialPreview!.aspectRatio, .5);
    });

    test(
        'non-Pixiv/empty inputs skipped; missing dimensions use honest fallback',
        () {
      expect(onlinePixivDetailPreview(_source(key: 'jm'), _comic()), isNull);
      expect(onlinePixivDetailPreview(_source(), _comic(cover: ' ')), isNull);
      expect(onlinePixivDetailPreview(_source(), _comic(id: '')), isNull);
      final seed = onlinePixivDetailPreview(
          _source(), _comic(width: null, height: null))!;
      expect(seed.aspectRatio, .75);
      expect(seed.aspectRatioKnown, isFalse);
    });

    test('raw model cover remains its provided URL with bounded decode', () {
      const raw = 'https://i.pximg.net/img-original/img/2026/09/26/image.png';
      final source = _source();
      final seed = onlinePixivDetailPreview(source, _comic(cover: raw))!;
      final provider = seed.provider as ResizeImage;
      expect(provider.imageProvider,
          same(onlineCoverProvider(url: raw, headers: _headers)));
      expect(provider.policy, ResizeImagePolicy.fit);
      expect(seed.fallbackProvider, isNull);
    });
  });

  testWidgets(
      'portrait budget includes actual inner width, DPR clamp and long edge',
      (tester) async {
    double? budget;
    await tester.pumpWidget(_host(
        OnlineWaterfallCard(
          title: 'preview',
          cover: pixivProportionalThumbUrl(_cover),
          imageHeaders: const {},
          width: 600,
          height: 1200,
          coverCandidatesBuilder: (edge) {
            budget = edge;
            return pixivWaterfallThumbUrls(_cover, targetLongestEdge: edge);
          },
          onTap: () {},
        ),
        dpr: 5));
    final image = tester.widget<Image>(find.byType(Image).first);
    final display = image.image as ResizeImage;
    expect(display.width, 705); // 174 inner dp × capped DPR3 × 1.35.
    expect(budget, closeTo(1409.4, .001)); // portrait 1:2 long edge.
    expect((display.imageProvider as NetworkImage).url,
        contains('/c/1200x1200_80/'));
    expect(image.fit, BoxFit.contain);
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    final finalImages = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(finalImages, hasLength(3));
    expect(
        finalImages.map((image) =>
            ((image.image as ResizeImage).imageProvider as NetworkImage).url),
        pixivWaterfallThumbUrls(_cover, targetLongestEdge: budget));
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'landscape uses width budget and generic default remains one fallback',
      (tester) async {
    double? budget;
    await tester.pumpWidget(_host(
        OnlineWaterfallCard(
          title: 'preview',
          cover: 'https://example.invalid/a.jpg',
          imageHeaders: const {},
          width: 1200,
          height: 600,
          coverCandidatesBuilder: (edge) {
            budget = edge;
            return const ['https://example.invalid/a.jpg'];
          },
          onTap: () {},
        ),
        dpr: 2));
    expect(budget, closeTo(469.8, .001));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_host(OnlineWaterfallCard(
      title: 'generic',
      cover: 'https://example.invalid/a.jpg',
      fallbackCover: 'https://example.invalid/b.jpg',
      imageHeaders: const {},
      onTap: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'real first-frame callback remembers exact painted resize provider',
      (tester) async {
    final source = _source(headers: const {});
    final bookmarks = RecommendationBookmarkController();
    addTearDown(bookmarks.dispose);
    final url = pixivWaterfallThumbUrls(_cover, targetLongestEdge: 469.8).first;
    await _cacheFrame(tester, _display(url, 235));
    await tester.pumpWidget(_host(OnlineRecommendationCard(
      source: source,
      comic: _comic(),
      bookmarks: bookmarks,
      onAccountsChanged: () {},
    )));
    await tester.pump();
    final image = tester.widget<Image>(find.byType(Image).first);
    final seed = onlinePixivDetailPreview(source, _comic())!;
    expect(seed.provider, same(image.image));
    expect(await seed.provider.obtainKey(ImageConfiguration.empty),
        await image.image.obtainKey(ImageConfiguration.empty));
    expect(find.byIcon(Icons.image_outlined), findsNothing);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('finite errors fall back to a ready API provider and remember it',
      (tester) async {
    final source = _source(headers: const {});
    final bookmarks = RecommendationBookmarkController();
    addTearDown(bookmarks.dispose);
    await _cacheFrame(tester, _display(_cover, 235));
    await tester.pumpWidget(_host(OnlineRecommendationCard(
      source: source,
      comic: _comic(),
      bookmarks: bookmarks,
      onAccountsChanged: () {},
    )));
    await tester.pumpAndSettle();
    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images, hasLength(3));
    final finalProvider = images.last.image;
    expect(((finalProvider as ResizeImage).imageProvider as NetworkImage).url,
        _cover);
    expect(onlinePixivDetailPreview(source, _comic())!.provider,
        same(finalProvider));
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'online list carries its real raw warm provider, not a new cold resize',
      (tester) async {
    final favoriteSetting = appdata.settings[72];
    final layoutSetting = appdata.settings[44];
    appdata.settings[72] =
        '0'; // No fixture may construct the real favorites DB.
    appdata.settings[44] = '0';
    addTearDown(() {
      appdata.settings[72] = favoriteSetting;
      appdata.settings[44] = layoutSetting;
    });
    final source = _source(headers: const {});
    final comic = _comic();
    final raw = onlineComicCoverProvider(source: source, comic: comic);
    await _cacheFrame(tester, raw);
    await tester.pumpWidget(_host(OnlineComicListItem(
      source: source,
      comic: comic,
      onTap: () {},
    )));
    await tester.pump();
    final image = tester.widget<Image>(find.byType(Image).first);
    expect(image.image, same(raw));
    final seed = onlinePixivDetailPreview(source, comic)!;
    expect(seed.provider, same(raw));
    expect(await seed.provider.obtainKey(ImageConfiguration.empty),
        await raw.obtainKey(ImageConfiguration.empty));
    expect(tester.takeException(), isNull);
  });

  testWidgets('owner, account and disabled actions reject late registration',
      (tester) async {
    final source = _source(headers: const {});
    final bookmarks = RecommendationBookmarkController();
    addTearDown(bookmarks.dispose);
    var current = true;
    await tester.pumpWidget(_host(OnlineRecommendationCard(
      source: source,
      comic: _comic(),
      bookmarks: bookmarks,
      onAccountsChanged: () {},
      ownerIsCurrent: () => current,
    )));
    final callback = tester
        .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
        .onCoverReady!;
    final marker = _display(_cover, 235);
    current = false;
    callback(marker);
    expect(PixivDetailPreviewRegistry.shared.length, 0);
    current = true;
    source.data['token'] = 'account-b';
    callback(marker);
    expect(PixivDetailPreviewRegistry.shared.length, 0);
    await tester.pumpWidget(_host(OnlineRecommendationCard(
      source: source,
      comic: _comic(),
      bookmarks: bookmarks,
      onAccountsChanged: () {},
      actionsEnabled: false,
    )));
    expect(
        tester
            .widget<OnlineWaterfallCard>(find.byType(OnlineWaterfallCard))
            .onCoverReady,
        isNull);
    callback(marker);
    expect(PixivDetailPreviewRegistry.shared.length, 0);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
