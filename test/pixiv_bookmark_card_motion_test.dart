import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/pixiv_bookmark_button.dart';
import 'package:picakeep/components/pixiv_bookmark_feedback.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';
import 'package:picakeep/pages/online_common/online_waterfall_card.dart';

PixivComicBrief _comic({bool marked = false, bool known = true}) =>
    PixivComicBrief(
      id: '42',
      title: '离线作品',
      author: '画师',
      cover: '',
      tags: const [],
      illustType: 0,
      pageCount: 1,
      width: 120,
      height: 150,
      isBookmarked: marked,
      bookmarkStateKnown: known,
      isBookmarkable: true,
      canLoadBookmarkState: !known,
    );

void main() {
  late RecommendationBookmarkController bookmarks;
  late ComicSource source;
  final boundaryKey = GlobalKey();
  late StateSetter change;
  bool active = true;
  bool reduced = false;
  setUp(() {
    active = true;
    reduced = false;
    bookmarks = RecommendationBookmarkController();
    source = ComicSource.named(
        key: 'pixiv', name: 'Pixiv', data: {'token': 'offline', 'userId': 'A'});
  });
  tearDown(() => bookmarks.dispose());

  Future<void> pump(
    WidgetTester tester, {
    required Future<Res<bool>> Function(String, {required bool isAdding}) write,
    PixivComicBrief? comic,
    Future<Res<PixivBookmarkState>> Function(String)? read,
    bool duplicate = false,
  }) async {
    tester.view.physicalSize = const Size(375, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final effectiveComic = comic ?? _comic();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'VerificationSans'),
      home: RepaintBoundary(
          key: boundaryKey,
          child: Material(
            child: StatefulBuilder(builder: (context, setState) {
              change = setState;
              return MediaQuery(
                data: MediaQueryData(
                    size: const Size(375, 640), disableAnimations: reduced),
                child: PixivBookmarkFeedbackHost(
                  active: active,
                  identity: 'A',
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var index = 0;
                            index < (duplicate ? 2 : 1);
                            index++)
                          SizedBox(
                              width: 180,
                              child: OnlineRecommendationCard(
                                key: ValueKey(index),
                                source: source,
                                comic: effectiveComic,
                                bookmarks: bookmarks,
                                onAccountsChanged: () {},
                                writeBookmark: write,
                                loadBookmarkState: read,
                                feedbackCurrent: active,
                              )),
                      ],
                    ),
                  ),
                ),
              );
            }),
          )),
    ));
    await tester.pumpAndSettle();
  }

  Finder mainIcon(int index) => find.descendant(
      of: find.byType(PixivBookmarkButton).at(index),
      matching: find.byKey(const ValueKey('pixiv-bookmark-main-icon')));
  Finder scale(int index) => find.descendant(
      of: find.byType(PixivBookmarkButton).at(index),
      matching: find.byKey(const ValueKey('pixiv-bookmark-main-scale')));
  IconData? icon(WidgetTester tester, int index) =>
      tester.widget<Icon>(mainIcon(index)).icon;

  for (final delay in [0, 700, 2500]) {
    testWidgets('known add $delay ms starts once and peers only confirm',
        (tester) async {
      final pending = Completer<Res<bool>>();
      var writes = 0;
      await pump(tester, duplicate: true, write: (_, {required isAdding}) {
        writes++;
        expect(isAdding, isTrue);
        return delay == 0 ? Future.value(const Res(true)) : pending.future;
      });
      await tester.tap(find.byKey(const ValueKey('waterfall-favorite')).first);
      await tester.pump();
      expect(
          tester
              .widget<OnlineWaterfallCard>(
                  find.byType(OnlineWaterfallCard).first)
              .favoriteEvent
              ?.phase,
          delay == 0 ? PixivBookmarkPhase.settle : PixivBookmarkPhase.begin);
      await tester.pump(const Duration(milliseconds: 100));
      expect(icon(tester, 0), Icons.favorite);
      expect(tester.widget<Transform>(scale(0)).transform.entry(0, 0),
          closeTo(.1, .001));
      expect(tester.widget<Transform>(scale(1)).transform.entry(0, 0), 1);
      if (delay > 0) {
        expect(icon(tester, 1), Icons.favorite_border);
        await tester.pump(Duration(milliseconds: delay - 100));
        expect(icon(tester, 0), Icons.favorite);
        expect(icon(tester, 1), Icons.favorite_border);
        if (delay > 1200) expect(find.text('正在提交收藏…'), findsOneWidget);
        pending.complete(const Res(true));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 500));
      expect(icon(tester, 0), Icons.favorite);
      expect(icon(tester, 1), Icons.favorite);
      expect(find.byKey(const ValueKey('pixiv-bookmark-ring')), findsNothing);
      expect(tester.widget<Transform>(scale(0)).transform.entry(0, 0), 1);
      expect(writes, 1);
      expect(find.text('已添加公开收藏'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
      'unknown reads true then cancel failure retains newly confirmed heart',
      (tester) async {
    final read = Completer<Res<PixivBookmarkState>>();
    final write = Completer<Res<bool>>();
    var writes = 0;
    await pump(tester,
        comic: _comic(known: false),
        read: (_) => read.future,
        write: (_, {required isAdding}) {
          writes++;
          expect(isAdding, isFalse);
          return write.future;
        });
    await tester.tap(find.byKey(const ValueKey('waterfall-favorite')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(writes, 0);
    expect(
        find.byKey(const ValueKey('pixiv-bookmark-fall-icon')), findsNothing);
    read.complete(const Res(
        PixivBookmarkState(isBookmarked: true, isBookmarkable: true)));
    await tester.pump();
    await tester.pump();
    expect(writes, 1);
    expect(
        find.byKey(const ValueKey('pixiv-bookmark-fall-icon')), findsOneWidget);
    write.complete(const Res.error('离线写入拒绝'));
    await tester.pumpAndSettle();
    expect(icon(tester, 0), Icons.favorite);
    expect(find.text('收藏失败：离线写入拒绝'), findsOneWidget);
    expect(writes, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'inactive and return keep business confirmation but never old pending feedback',
      (tester) async {
    final pending = Completer<Res<bool>>();
    await pump(tester, write: (_, {required isAdding}) => pending.future);
    await tester.tap(find.byKey(const ValueKey('waterfall-favorite')));
    await tester.pump(const Duration(milliseconds: 150));
    change(() => active = false);
    await tester.pump();
    change(() => active = true);
    await tester.pump();
    expect(icon(tester, 0), Icons.favorite_border);
    pending.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(icon(tester, 0), Icons.favorite);
    expect(find.text('已添加公开收藏'), findsNothing);
    expect(find.byKey(const ValueKey('pixiv-bookmark-ring')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final target in [true, false]) {
    testWidgets(
        'real waterfall ${target ? 'add' : 'cancel'} frames retain 48dp target and uncut decoration',
        (tester) async {
      await tester.runAsync(() async {
        for (final font in [
          ('VerificationSans', 'C:/Windows/Fonts/msyh.ttc'),
          (
            'MaterialIcons',
            'build/unit_test_assets/fonts/MaterialIcons-Regular.otf'
          )
        ]) {
          final file = File(font.$2);
          if (file.existsSync()) {
            await (FontLoader(font.$1)
                  ..addFont(Future.value(
                      ByteData.sublistView(await file.readAsBytes()))))
                .load();
          }
        }
      });
      final pending = Completer<Res<bool>>();
      await pump(tester,
          comic: _comic(marked: !target),
          write: (_, {required isAdding}) => pending.future);
      final before =
          tester.getRect(find.byKey(const ValueKey('waterfall-favorite')));
      await tester.tap(find.byKey(const ValueKey('waterfall-favorite')));
      await tester.pump();
      var previousTime = 0;
      for (final ms in [0, 50, 100, 150, 200, 250, 300, 500]) {
        await tester.pump(Duration(milliseconds: ms - previousTime));
        previousTime = ms;
        expect(tester.getRect(find.byKey(const ValueKey('waterfall-favorite'))),
            before);
        expect(before.size, const Size(48, 48));
        expect(icon(tester, 0),
            target && ms >= 100 ? Icons.favorite : Icons.favorite_border);
        await tester.runAsync(() async {
          final boundary = boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = File(
              'docs/verification/pixiv-bookmark-queue-counts-036/${target ? 'add' : 'cancel'}-$ms.png');
          await output.parent.create(recursive: true);
          await output.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      pending.complete(Res(target));
      await tester.pumpAndSettle();
      expect(find.text(target ? '已添加公开收藏' : '已取消收藏'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
