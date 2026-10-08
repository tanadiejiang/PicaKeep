import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:picakeep/pages/online_comic/pixiv_detail_shell.dart';

const _favoriteKey = ValueKey('pixiv-detail-favorite');
const _authorKey = ValueKey('short-work-author');

Widget _shortWork({
  required VoidCallback onFavorite,
  VoidCallback? onFavoriteLongPress,
  bool busy = false,
  bool saved = false,
  List<PixivDetailImage>? images,
  TextScaler textScaler = TextScaler.noScaling,
  double ratio = 2,
  double tailHeight = 1000,
  TargetPlatform platform = TargetPlatform.android,
}) =>
    MaterialApp(
      theme: ThemeData(platform: platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: PixivDetailShell(
        title: 'Short landscape work',
        author: 'Fixture author',
        images: images ??
            [
              PixivDetailImage(
                key: 'landscape',
                provider: null,
                aspectRatio: ratio,
                onRead: () {},
              ),
            ],
        actionLabel: '下载',
        actionIcon: Icons.download_outlined,
        onFavorite: onFavorite,
        onFavoriteLongPress: onFavoriteLongPress,
        favoriteBusy: busy,
        isFavorited: saved,
        sliversBuilder: (_) => [
          const SliverToBoxAdapter(child: Text('Short description')),
          const PixivDetailFavoriteBoundary(),
          const SliverToBoxAdapter(
            child: SizedBox(
              key: _authorKey,
              height: 160,
              child: Text('Visible author'),
            ),
          ),
          SliverToBoxAdapter(child: SizedBox(height: tailHeight)),
        ],
      ),
    );

void _view(WidgetTester tester,
    {Size size = const Size(400, 800), double dpr = 1}) {
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(
      of: find.byKey(const ValueKey('pixiv-detail-page-scroll')),
      matching: find.byType(Scrollable),
    ))
    .position;

void _expectVisible(WidgetTester tester, bool visible) {
  expect(
    tester
        .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('pixiv-detail-favorite-opacity')))
        .opacity,
    visible ? 1 : 0,
  );
  expect(
    tester
        .widget<AnimatedScale>(
            find.byKey(const ValueKey('pixiv-detail-favorite-scale')))
        .scale,
    visible ? 1 : 0,
  );
  expect(
    tester
        .widget<IgnorePointer>(
            find.byKey(const ValueKey('pixiv-detail-favorite-hit-test')))
        .ignoring,
    !visible,
  );
}

bool _hasFavoriteSemantics(WidgetTester tester) {
  var found = false;
  void visit(SemanticsNode node) {
    if (node.getSemanticsData().label.contains('收藏')) found = true;
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(tester.getSemantics(find.byType(PixivDetailShell)));
  return found;
}

void main() {
  testWidgets('short landscape has reachable favorite before any scrolling',
      (tester) async {
    _view(tester);
    var taps = 0;
    var longPresses = 0;
    await tester.pumpWidget(_shortWork(
      onFavorite: () => taps++,
      onFavoriteLongPress: () => longPresses++,
    ));
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, 0);
    final image = find.descendant(
      of: find.byKey(const ValueKey('pixiv-image-landscape')),
      matching: find.byType(AspectRatio),
    );
    expect(tester.getSize(image), const Size(400, 200));
    expect(tester.getTopLeft(find.byKey(_authorKey)).dy,
        lessThan(tester.getTopLeft(find.byKey(_favoriteKey)).dy));
    _expectVisible(tester, true);
    await tester.tap(find.byKey(_favoriteKey));
    await tester.longPress(find.byKey(_favoriteKey));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(longPresses, 1);
    expect(tester.takeException(), isNull);
  });

  for (final spec in [
    (name: 'tall phone', size: const Size(400, 1200), dpr: 1.0, ratio: 2.0),
    (name: 'landscape', size: const Size(800, 400), dpr: 1.0, ratio: 8.0),
    (name: 'high DPR', size: const Size(400, 800), dpr: 2.75, ratio: 2.0),
  ]) {
    testWidgets('${spec.name} keeps a short first screen actionable',
        (tester) async {
      _view(tester, size: spec.size, dpr: spec.dpr);
      var taps = 0;
      await tester
          .pumpWidget(_shortWork(ratio: spec.ratio, onFavorite: () => taps++));
      await tester.pumpAndSettle();
      expect(_position(tester).pixels, 0);
      expect(tester.getTopLeft(find.byKey(_authorKey)).dy,
          lessThan(tester.getTopLeft(find.byKey(_favoriteKey)).dy));
      _expectVisible(tester, true);
      await tester.tap(find.byKey(_favoriteKey));
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('safe areas and large text leave the favorite reachable',
      (tester) async {
    _view(tester, dpr: 2);
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 68);
    addTearDown(tester.view.resetPadding);
    var taps = 0;
    await tester.pumpWidget(_shortWork(
      onFavorite: () => taps++,
      textScaler: const TextScaler.linear(2),
    ));
    await tester.pumpAndSettle();
    _expectVisible(tester, true);
    final rect = tester.getRect(find.byKey(_favoriteKey));
    expect(rect.top, greaterThanOrEqualTo(24));
    expect(rect.bottom, lessThanOrEqualTo(800 - 34));
    await tester.tap(find.byKey(_favoriteKey));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a non-scrollable short work retains its initial action',
      (tester) async {
    _view(tester);
    var taps = 0;
    await tester.pumpWidget(_shortWork(
      onFavorite: () => taps++,
      tailHeight: 0,
    ));
    await tester.pumpAndSettle();
    expect(_position(tester).maxScrollExtent, 0);
    _expectVisible(tester, true);
    await tester.tap(find.byKey(_favoriteKey));
    expect(taps, 1);
  });

  testWidgets('one held pointer crosses author boundary and restores at top',
      (tester) async {
    _view(tester);
    await tester.pumpWidget(_shortWork(onFavorite: () {}));
    await tester.pumpAndSettle();
    _expectVisible(tester, true);
    final position = _position(tester);
    final gesture = await tester.startGesture(const Offset(120, 450));
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(position.pixels, greaterThan(60));
    _expectVisible(tester, false);
    final hiddenOffset = position.pixels;
    await gesture.moveBy(const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 16));
    expect(position.pixels, greaterThan(hiddenOffset + 150));
    await gesture.moveBy(const Offset(0, 450));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(position.pixels, position.minScrollExtent);
    _expectVisible(tester, true);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('top bouncing overscroll does not hide the action',
      (tester) async {
    _view(tester);
    await tester.pumpWidget(
        _shortWork(onFavorite: () {}, platform: TargetPlatform.iOS));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(const Offset(120, 350));
    await gesture.moveBy(const Offset(0, 140));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(
        _position(tester).pixels, lessThan(_position(tester).minScrollExtent));
    _expectVisible(tester, true);
    await gesture.up();
    await tester.pumpAndSettle();
    _expectVisible(tester, true);
  });

  testWidgets('details without images still restore on returning to top',
      (tester) async {
    _view(tester);
    var taps = 0;
    await tester
        .pumpWidget(_shortWork(images: const [], onFavorite: () => taps++));
    await tester.pumpAndSettle();
    _expectVisible(tester, true);
    _position(tester).jumpTo(80);
    await tester.pumpAndSettle();
    _expectVisible(tester, false);
    _position(tester).jumpTo(0);
    await tester.pumpAndSettle();
    _expectVisible(tester, true);
    await tester.tap(find.byKey(_favoriteKey));
    expect(taps, 1);
  });

  for (final saved in [false, true]) {
    testWidgets('busy completion preserves actual saved state $saved',
        (tester) async {
      _view(tester);
      var taps = 0;
      var longPresses = 0;
      Widget work({required bool busy}) => _shortWork(
            busy: busy,
            saved: saved,
            onFavorite: () => taps++,
            onFavoriteLongPress: () => longPresses++,
          );
      await tester.pumpWidget(work(busy: true));
      await tester.pumpAndSettle();
      _position(tester).jumpTo(80);
      await tester.pumpAndSettle();
      _expectVisible(tester, true);
      final icon = tester.widget<Icon>(find.descendant(
          of: find.byKey(_favoriteKey), matching: find.byIcon(Icons.favorite)));
      expect(icon.color?.a, closeTo(.5, .02));
      await tester.tap(find.byKey(_favoriteKey), warnIfMissed: false);
      await tester.longPress(find.byKey(_favoriteKey), warnIfMissed: false);
      expect(taps + longPresses, 0);
      await tester.pumpWidget(work(busy: false));
      await tester.pumpAndSettle();
      _expectVisible(tester, false);
      _position(tester).jumpTo(0);
      await tester.pumpAndSettle();
      _expectVisible(tester, true);
      expect(
          find.descendant(
              of: find.byKey(_favoriteKey),
              matching:
                  find.byIcon(saved ? Icons.favorite : Icons.favorite_border)),
          findsOneWidget);
      await tester.tap(find.byKey(_favoriteKey));
      await tester.longPress(find.byKey(_favoriteKey));
      expect(taps, 1);
      expect(longPresses, 1);
    });
  }

  testWidgets('hidden favorite removes hit and accessibility actions',
      (tester) async {
    _view(tester);
    final semantics = tester.ensureSemantics();
    try {
      var calls = 0;
      await tester.pumpWidget(_shortWork(
        onFavorite: () => calls++,
        onFavoriteLongPress: () => calls++,
      ));
      await tester.pumpAndSettle();
      expect(_hasFavoriteSemantics(tester), isTrue);
      _position(tester).jumpTo(80);
      await tester.pumpAndSettle();
      _expectVisible(tester, false);
      expect(_hasFavoriteSemantics(tester), isFalse);
      await tester.tap(find.byKey(_favoriteKey), warnIfMissed: false);
      await tester.longPress(find.byKey(_favoriteKey), warnIfMissed: false);
      expect(calls, 0);
      _position(tester).jumpTo(0);
      await tester.pumpAndSettle();
      expect(_hasFavoriteSemantics(tester), isTrue);
      await tester.tap(find.byKey(_favoriteKey));
      expect(calls, 1);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
      'latest ratio and rotation recompute visibility at current offset',
      (tester) async {
    _view(tester);
    await tester.pumpWidget(_shortWork(onFavorite: () {}));
    await tester.pumpAndSettle();
    _position(tester).jumpTo(100);
    await tester.pumpAndSettle();
    _expectVisible(tester, false);
    await tester.pumpWidget(_shortWork(ratio: .5, onFavorite: () {}));
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, closeTo(100, .1));
    _expectVisible(tester, true);
    await tester.pumpWidget(_shortWork(onFavorite: () {}));
    await tester.pumpAndSettle();
    _expectVisible(tester, false);
    tester.view.physicalSize = const Size(800, 400);
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, closeTo(100, .1));
    _expectVisible(tester, true);
    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpAndSettle();
    _expectVisible(tester, false);
    _position(tester).jumpTo(0);
    await tester.pumpAndSettle();
    _expectVisible(tester, true);
    _position(tester).jumpTo(80);
    _position(tester).jumpTo(0);
    await tester.pumpAndSettle();
    _expectVisible(tester, true);
    _position(tester).jumpTo(80);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('decoded landscape geometry does not hide a first-screen action',
      (tester) async {
    _view(tester);
    final provider =
        MemoryImage(image.encodePng(image.Image(width: 80, height: 40)));
    var taps = 0;
    await tester.pumpWidget(_shortWork(
      onFavorite: () => taps++,
      images: [
        PixivDetailImage(
          key: 'decoded',
          provider: provider,
          aspectRatio: .5,
          aspectRatioKnown: false,
          onRead: () {},
        ),
      ],
    ));
    await tester.runAsync(() =>
        precacheImage(provider, tester.element(find.byType(PixivDetailShell))));
    await tester.pumpAndSettle();
    final aspect = find.descendant(
        of: find.byKey(const ValueKey('pixiv-image-decoded')),
        matching: find.byType(AspectRatio));
    expect(tester.getSize(aspect), const Size(400, 200));
    expect(_position(tester).pixels, 0);
    _expectVisible(tester, true);
    await tester.tap(find.byKey(_favoriteKey));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });
}
