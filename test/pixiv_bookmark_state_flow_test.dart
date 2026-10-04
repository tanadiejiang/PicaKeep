import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/state_controller.dart';
import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/online_comic_page_components.dart';
import 'package:picakeep/pages/online_comic/online_comic_page_logic.dart';
import 'package:picakeep/pages/online_comic/pixiv_comic_page_v2.dart';

class _Page extends PixivComicPageV2 {
  const _Page(this.writer) : super('41');
  final Future<Res<bool>> Function(bool target) writer;

  @override
  Future<Res<bool>> writeBookmark(String id, {required bool isAdding}) =>
      writer(isAdding);
}

class _InteractivePage extends PixivComicPageV2 {
  const _InteractivePage(this.data, this.writer) : super('41');

  final PixivComicInfo data;
  final Future<Res<bool>> Function(bool target) writer;

  @override
  Future<Res<PixivComicInfo>> loadData() async => Res(data);

  @override
  Future<Res<bool>> writeBookmark(String id, {required bool isAdding}) =>
      writer(isAdding);

  @override
  Widget? buildSectionAfterDescription(
          BuildContext context, PixivComicInfo data) =>
      const SizedBox.shrink();
}

PixivComicInfo _info({bool bookmarked = false}) => parsePixivComicInfo({
      'illustId': '41',
      'illustTitle': '作品',
      'bookmarkData': bookmarked ? {'id': '900'} : null,
    });

Future<OnlineComicPageLogic<PixivComicInfo>> _pumpActions(
  WidgetTester tester,
  _Page page,
  PixivComicInfo data,
) async {
  final logic = OnlineComicPageLogic<PixivComicInfo>(
    loadData: () async => Res(data),
    loadFavoriteState: page.loadFavoriteState,
  );
  await tester.pumpWidget(MaterialApp(
    home: StateBuilder<OnlineComicPageLogic<PixivComicInfo>>(
      init: logic,
      tag: page.tag,
      builder: (logic) {
        logic.startLoadingIfNeeded();
        return Scaffold(
          body: Builder(
              builder: (context) => Column(children: [
                    Icon(logic.favorite
                        ? Icons.bookmark
                        : Icons.bookmark_border),
                    TextButton(
                      key: const Key('toggle'),
                      onPressed: () => page.onFavorite(context, data),
                      child: const Text('收藏操作'),
                    ),
                    TextButton(
                      key: const Key('cancel'),
                      onPressed: () => page.onCancelPlatformFavorite!(
                          context, data, logic.favorite),
                      child: const Text('长按取消入口'),
                    ),
                  ])),
        );
      },
    ),
  ));
  await tester.pumpAndSettle();
  return logic;
}

void main() {
  tearDown(() {
    for (final logic
        in StateController.findAll<OnlineComicPageLogic<PixivComicInfo>>()) {
      logic.dispose();
    }
  });

  testWidgets('首次与销毁后重开从详情恢复收藏，游客空状态为未收藏', (tester) async {
    final targets = <bool>[];
    final page = _Page((target) async {
      targets.add(target);
      return const Res(true);
    });
    await _pumpActions(tester, page, _info(bookmarked: true));
    expect(find.byIcon(Icons.bookmark), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpActions(tester, page, _info(bookmarked: true));
    expect(find.byIcon(Icons.bookmark), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpActions(tester, page, _info());
    expect(find.byIcon(Icons.bookmark_border), findsOneWidget);
    expect(targets, isEmpty, reason: '初始化不产生账号写入');
  });

  testWidgets('连续添加/取消用确认状态切换，失败保留图标', (tester) async {
    final targets = <bool>[];
    var shouldFail = false;
    final page = _Page((target) async {
      targets.add(target);
      return shouldFail ? const Res.error('offline rejected') : const Res(true);
    });
    final logic = await _pumpActions(tester, page, _info());
    for (final expected in [true, false, true, false]) {
      await tester.tap(find.byKey(const Key('toggle')));
      await tester.pumpAndSettle();
      expect(logic.favorite, expected);
      expect(find.byIcon(expected ? Icons.bookmark : Icons.bookmark_border),
          findsOneWidget);
    }
    shouldFail = true;
    await tester.tap(find.byKey(const Key('toggle')));
    await tester.pumpAndSettle();
    expect(logic.favorite, isFalse);
    expect(find.text('操作失败：offline rejected'), findsOneWidget);
    expect(targets, [true, false, true, false, true]);
  });

  testWidgets('详情页收藏按钮点击可取消已收藏作品', (tester) async {
    final pendingCancel = Completer<Res<bool>>();
    final targets = <bool>[];
    await tester.pumpWidget(MaterialApp(
      home: _InteractivePage(_info(bookmarked: true), (target) async {
        targets.add(target);
        if (!target) return pendingCancel.future;
        return const Res(true);
      }),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(OnlineComicIconAction), findsWidgets);
    expect(find.byIcon(Icons.bookmark), findsOneWidget);
    expect(find.text('取消收藏'), findsOneWidget);
    final action = find.byKey(const Key('online-comic-favorite-action'));
    await tester.tap(action);
    await tester.pump();
    expect(find.byKey(const Key('online-comic-favorite-progress')),
        findsOneWidget);
    expect(find.text('正在取消'), findsOneWidget);
    await tester.tap(action);
    expect(targets, [false], reason: '请求处理中忽略重复点击');
    pendingCancel.complete(const Res(true));
    await tester.pumpAndSettle();

    expect(targets, [false]);
    expect(find.byIcon(Icons.bookmark_border), findsOneWidget);
    expect(find.byIcon(Icons.bookmark), findsNothing);
    expect(find.text('收藏'), findsOneWidget);

    final addAction = find.ancestor(
      of: find.byIcon(Icons.bookmark_border),
      matching: find.byType(OnlineComicIconAction),
    );
    await tester.tap(addAction);
    await tester.pumpAndSettle();
    expect(targets, [false, true]);
    expect(find.byIcon(Icons.bookmark), findsOneWidget);
    expect(find.text('取消收藏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('toggle写中重复点击和长按入口共用锁', (tester) async {
    final pending = Completer<Res<bool>>();
    final targets = <bool>[];
    final page = _Page((target) {
      targets.add(target);
      return pending.future;
    });
    final logic = await _pumpActions(tester, page, _info(bookmarked: true));
    await tester.tap(find.byKey(const Key('toggle')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('toggle')));
    await tester.tap(find.byKey(const Key('cancel')));
    await tester.pump();
    expect(targets, [false]);
    expect(find.byType(AlertDialog), findsNothing);
    expect(logic.favorite, isTrue, reason: '成功确认前保留原态');
    pending.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(logic.favorite, isFalse);
  });

  testWidgets('确认弹窗期间阻止并发toggle，取消不写，确认后再允许下一动作', (tester) async {
    final targets = <bool>[];
    final page = _Page((target) async {
      targets.add(target);
      return const Res(true);
    });
    final data = _info(bookmarked: true);
    final logic = await _pumpActions(tester, page, data);
    await tester.tap(find.byKey(const Key('cancel')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    final context = tester.element(find.byKey(const Key('toggle')));
    await page.onFavorite(context, data);
    expect(targets, isEmpty);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(logic.favorite, isTrue);
    expect(targets, isEmpty);
    await tester.tap(find.byKey(const Key('cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(targets, [false]);
    expect(logic.favorite, isFalse);
    await tester.tap(find.byKey(const Key('toggle')));
    await tester.pumpAndSettle();
    expect(targets, [false, true]);
    expect(logic.favorite, isTrue);
  });

  testWidgets('取消失败保留已收藏，下一次动作可重试', (tester) async {
    var calls = 0;
    final page = _Page((target) async {
      calls++;
      return calls == 1 ? const Res.error('denied') : const Res(true);
    });
    final logic = await _pumpActions(tester, page, _info(bookmarked: true));
    await tester.tap(find.byKey(const Key('cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(logic.favorite, isTrue);
    expect(find.text('取消网络收藏失败：denied'), findsOneWidget);
    await tester.tap(find.byKey(const Key('toggle')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(logic.favorite, isFalse);
  });

  testWidgets('旧页面写结果不会覆盖销毁后重开页面', (tester) async {
    final pending = Completer<Res<bool>>();
    final page = _Page((target) => pending.future);
    await _pumpActions(tester, page, _info());
    await tester.tap(find.byKey(const Key('toggle')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    final fresh = await _pumpActions(tester, page, _info());
    pending.complete(const Res(true));
    await tester.pumpAndSettle();
    expect(fresh.favorite, isFalse);
    expect(find.byIcon(Icons.bookmark_border), findsOneWidget);
    expect(find.text('已收藏'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
