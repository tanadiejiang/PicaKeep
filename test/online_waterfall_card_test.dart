import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/pages/online_common/online_comic_list_item.dart';
import 'package:picakeep/pages/online_common/online_waterfall_card.dart';
import 'package:picakeep/components/comic_tag_wrap.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';

void main() {
  tearDown(clearOnlineCoverProviderCache);

  testWidgets('推荐头像兜底，收藏无底无阴影，独立点击且忙态不进入详情', (tester) async {
    final semantics = tester.ensureSemantics();
    var cards = 0, authors = 0, favorites = 0;
    Future<void> show(
            {bool favorite = false,
            bool busy = false,
            bool supported = true,
            String avatar = '',
            WaterfallFavoriteStyle style = WaterfallFavoriteStyle.defaults}) =>
        tester.pumpWidget(MaterialApp(
          theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 160,
                child: OnlineWaterfallCard(
                  title: '作品',
                  cover: '',
                  imageHeaders: const {'Referer': 'https://www.pixiv.net/'},
                  author: '🙂作者',
                  authorAvatarUrl: avatar,
                  showAuthorAvatar: true,
                  onAuthorTap: () => authors++,
                  onTap: () => cards++,
                  isFavorited: favorite,
                  favoriteBusy: busy,
                  favoriteStyle: style,
                  onToggleFavorite: supported ? () => favorites++ : null,
                ),
              ),
            ),
          ),
        ));
    await show();
    expect(tester.getSize(find.byKey(const ValueKey('waterfall-avatar'))),
        const Size(20, 20));
    expect(find.text('🙂'), findsOneWidget);
    final unselected = tester.widget<Icon>(find.byIcon(Icons.favorite_border));
    expect(unselected.size, 22);
    expect(unselected.color, Colors.white.withValues(alpha: .9));
    expect(tester.getSize(find.byKey(const ValueKey('waterfall-favorite'))),
        const Size(48, 48));
    expect(tester.widget<ClipRRect>(find.byType(ClipRRect).first).borderRadius,
        BorderRadius.circular(onlineWaterfallImageRadius));
    expect(find.byType(Material), findsOneWidget,
        reason: '仅 Scaffold 自带 Material');
    expect(find.byType(Card), findsNothing);
    await tester.tap(find.byKey(const ValueKey('waterfall-author')));
    await tester.tap(find.byKey(const ValueKey('waterfall-favorite')));
    expect(authors, 1);
    expect(favorites, 1);
    expect(cards, 0);
    await show(favorite: true, busy: true);
    expect(tester.widget<Icon>(find.byIcon(Icons.favorite)).color,
        const Color(0xFFE0245E).withValues(alpha: .9));
    expect(find.bySemanticsLabel('正在更新收藏'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('waterfall-favorite')));
    expect(favorites, 1);
    expect(cards, 0);
    await tester.tap(find.text('作品'));
    expect(cards, 1);
    await show(supported: false);
    expect(find.byKey(const ValueKey('waterfall-favorite')), findsNothing);
    await show(
        favorite: true,
        style: const WaterfallFavoriteStyle(color: 'theme', opacity: 50),
        avatar: 'https://example.invalid/avatar.jpg');
    final cardContext = tester.element(find.byType(OnlineWaterfallCard));
    expect(tester.widget<Icon>(find.byIcon(Icons.favorite)).color,
        Theme.of(cardContext).colorScheme.primary.withValues(alpha: .5));
    final image = tester.widget<Image>(find.byType(Image));
    final provider = (image.image as ResizeImage).imageProvider;
    expect(
        provider,
        same(onlineCoverProvider(
            url: 'https://example.invalid/avatar.jpg',
            headers: const {'Referer': 'https://www.pixiv.net/'})));
    expect(
        provider,
        isNot(same(
            onlineCoverProvider(url: 'https://example.invalid/avatar.jpg'))));
    final before = tester.getSize(find.byType(OnlineWaterfallCard));
    await tester.pumpAndSettle();
    expect(find.text('🙂'), findsOneWidget);
    expect(tester.getSize(find.byType(OnlineWaterfallCard)), before);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('不限标签全部换行，封面比例保持稳定', (tester) async {
    Future<void> show(int count) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: SizedBox(
            width: 160,
            child: OnlineWaterfallCard(
              title: '作品',
              cover: '',
              imageHeaders: const {},
              width: 600,
              height: 800,
              onTap: () {},
              tags: List.generate(count, (i) => '特别长的标签-$i'),
              tagConfig:
                  const WaterfallTagDisplayConfig(showTags: true, tagRows: 0),
            ),
          ))),
        ));
    await show(1);
    final one = tester.getSize(find.byType(OnlineWaterfallCard));
    final cover = tester.getSize(find.byType(AspectRatio));
    await show(20);
    expect(find.byType(ComicTagChip), findsNWidgets(20));
    expect(tester.getSize(find.byType(OnlineWaterfallCard)).height,
        greaterThan(one.height));
    expect(tester.getSize(find.byType(AspectRatio)), cover);
    expect(tester.takeException(), isNull);
  });

  testWidgets('标签默认关闭；开启后短、空、多标签保持固定高度与封面比例', (tester) async {
    var taps = 0;
    Future<void> show(List<String> tags, {bool enabled = true}) =>
        tester.pumpWidget(
          MaterialApp(
              home: Scaffold(
                  body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
                width: 160,
                child: OnlineWaterfallCard(
                  title: '作品',
                  cover: '',
                  imageHeaders: const {},
                  width: 600,
                  height: 800,
                  tags: tags,
                  tagConfig:
                      WaterfallTagDisplayConfig(showTags: enabled, tagRows: 3),
                  onTap: () => taps++,
                )),
          ))),
        );
    await show(['一'], enabled: false);
    expect(find.byType(ComicTagWrap), findsNothing);
    final off = tester.getSize(find.byType(OnlineWaterfallCard));
    final cover = tester.getSize(find.byType(AspectRatio));
    await show([]);
    final enabled = tester.getSize(find.byType(OnlineWaterfallCard));
    expect(enabled.height, greaterThan(off.height));
    await show(['一']);
    expect(tester.getSize(find.byType(OnlineWaterfallCard)), enabled);
    await show(List.generate(100, (i) => '非常长的作品标签-$i'));
    expect(tester.getSize(find.byType(OnlineWaterfallCard)), enabled);
    expect(tester.getSize(find.byType(AspectRatio)), cover);
    expect(find.byType(ComicTagChip), findsNWidgets(3));
    expect(find.text('非常长的作品标签-99'), findsNothing);
    await tester.tap(find.byType(ComicTagChip).first);
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'pending cover is visible and failure tries the API thumbnail once',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 180,
          child: OnlineWaterfallCard(
            title: 'Day-37',
            cover: 'https://example.invalid/derived.jpg',
            fallbackCover: 'https://example.invalid/api.jpg',
            imageHeaders: const {},
            width: 1000,
            height: 2000,
            onTap: () {},
          ),
        ),
      ),
    ));
    final initialHeight =
        tester.getSize(find.byType(OnlineWaterfallCard)).height;
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    // Flutter's test HTTP client rejects both requests with HTTP 400. The
    // fallback error must terminate visibly, without looping or resizing.
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(2));
    final fallbackImage = tester.widgetList<Image>(find.byType(Image)).last;
    final provider = (fallbackImage.image as ResizeImage).imageProvider;
    expect((provider as NetworkImage).url, 'https://example.invalid/api.jpg');
    expect(
        tester.getSize(find.byType(OnlineWaterfallCard)).height, initialHeight);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same original URL does not enter a fallback loop',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 180,
          child: OnlineWaterfallCard(
            title: 'unchanged thumbnail',
            cover: 'https://example.invalid/same.jpg',
            fallbackCover: 'https://example.invalid/same.jpg',
            imageHeaders: const {},
            onTap: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
