// 041 originally tested collapsing the gallery to a small cover. The user
// corrected that interpretation in 043: images always keep their natural
// vertical layout; only the detail panel is expanded. These compatibility
// checks replace the obsolete small-cover assertions. Full handoff/panel
// coverage and actual screenshots live in pixiv_detail_panel_handoff_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/pages/online_comic/pixiv_detail_shell.dart';

Widget _shell(
        {bool optIn = true,
        required VoidCallback read,
        required VoidCallback action,
        bool busy = false}) =>
    MaterialApp(
      home: PixivDetailShell(
        title: '作品',
        author: '作者',
        galleryCollapsible: optIn,
        images: [
          for (var index = 0; index < 2; index++)
            PixivDetailImage(
                key: 'image-$index',
                provider: null,
                aspectRatio: index == 0 ? 1 : .5,
                onRead: read)
        ],
        actionLabel: '下载',
        actionIcon: Icons.download_outlined,
        onAction: action,
        actionBusy: busy,
        sliversBuilder: (_) => const [SliverToBoxAdapter(child: Text('作品信息'))],
      ),
    );

void main() {
  testWidgets(
      'opt-in retains full natural images and begins with details deferred',
      (tester) async {
    tester.view.physicalSize = const Size(375, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var reads = 0;
    await tester.pumpWidget(_shell(read: () => reads++, action: () {}));
    await tester.pumpAndSettle();
    expect(find.text('作品信息'), findsNothing);
    expect(find.byKey(const ValueKey('pixiv-gallery-collapsed-cover')),
        findsNothing);
    expect(
        tester
            .getSize(find.byKey(const ValueKey('pixiv-image-image-0')))
            .height,
        375);
    expect(
        tester
            .getSize(find.byKey(const ValueKey('pixiv-image-image-1')))
            .height,
        750);
    expect(find.byKey(const ValueKey('pixiv-author-header-cluster')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pixiv-image-image-0')));
    expect(reads, 1);
  });

  testWidgets('default path keeps inline details and original commands',
      (tester) async {
    tester.view.physicalSize = const Size(375, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var reads = 0, actions = 0;
    await tester.pumpWidget(
        _shell(optIn: false, read: () => reads++, action: () => actions++));
    await tester.pumpAndSettle();
    expect(find.text('作品信息'), findsOneWidget);
    expect(find.byKey(const ValueKey('pixiv-author-header-cluster')),
        findsNothing);
    await tester.tap(find.byKey(const ValueKey('pixiv-image-image-1')));
    await tester.tap(find.byTooltip('下载'));
    expect(reads, 1);
    expect(actions, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail panel preserves gallery sizes and disables busy download',
      (tester) async {
    tester.view.physicalSize = const Size(375, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var actions = 0;
    await tester
        .pumpWidget(_shell(read: () {}, action: () => actions++, busy: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pixiv-author-header-cluster')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pixiv-detail-images')), findsOneWidget);
    expect(
        tester
            .getSize(find.byKey(const ValueKey('pixiv-image-image-0')))
            .height,
        375);
    await tester.tap(find.byTooltip('下载').last);
    expect(actions, 0);
    await tester.tap(find.byKey(const ValueKey('pixiv-detail-panel-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pixiv-detail-panel')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
