// Render the production card with the user's existing local preview assets.
// Run explicitly; no live API or image request is made.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
import 'package:picakeep/pages/online_common/online_waterfall_card.dart';

class _Headers extends Fake implements HttpHeaders {
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.bytes);
  final Uint8List bytes;
  @override
  final HttpHeaders headers = _Headers();
  @override
  Future<HttpClientResponse> close() async => _Response(bytes);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.bytes);
  final Uint8List bytes;
  @override
  int get statusCode => 200;
  @override
  int get contentLength => bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      Stream<List<int>>.value(bytes).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends Fake implements HttpClient {
  _Client(this.images);
  final Map<String, Uint8List> images;
  @override
  set autoUncompress(bool value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _Request(images[url.path]!);
}

class _Overrides extends HttpOverrides {
  _Overrides(this.images);
  final Map<String, Uint8List> images;
  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client(images);
}

void main() {
  testWidgets('production recommendation waterfall render', (tester) async {
    const assetRoot = 'Z-plan/新需求-主线-第十九轮/006-附件-推荐页瀑布流预览';
    const covers = [
      'cover1_snowbird.png',
      'cover2_nmk.png',
      'cover3_oc.png',
      'cover4_untitled.png'
    ];
    const titles = ['雪鳥の花嫁', 'n m k', 'OC', '無題'];
    const authors = ['torino', '七緒錬', '上天入地小白狼', '生桃仁'];
    const ratios = [.676, .78, .60, .74];
    const tags = [
      ['原神', 'GenshinImpact', 'オデット', 'Odette', 'ウェディングドレス', 'オデット(原神)'],
      ['SummerPockets', '野村美希'],
      ['OC', '黑丝', '女の子', '苏筱白', '黒スト', '長手袋'],
      ['白丝', '足裏', '白タイツ', 'ふとももの罠', 'タイツ越しのパンツ', 'ソックス足裏']
    ];
    final images = <String, Uint8List>{};
    await tester.runAsync(() async {
      for (final name in [...covers, 'avatar_torino.png']) {
        images['/$name'] = await File('$assetRoot/$name').readAsBytes();
      }
      for (final item in [
        ('PreviewChinese', 'C:/Windows/Fonts/msyh.ttc'),
        (
          'MaterialIcons',
          'E:/SDK/flutter_windows_3.38.5-stable/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'
        )
      ]) {
        final bytes = await File(item.$2).readAsBytes();
        await (FontLoader(item.$1)
              ..addFont(Future.value(ByteData.sublistView(bytes))))
            .load();
      }
    });
    HttpOverrides.global = _Overrides(images);
    addTearDown(() {
      HttpOverrides.global = null;
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 1120);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final columns in [2, 3]) {
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                  useMaterial3: true,
                  fontFamily: 'PreviewChinese',
                  colorScheme:
                      ColorScheme.fromSeed(seedColor: const Color(0xff73548f))),
              home: Scaffold(
                  appBar: AppBar(title: Text('推荐 · $columns 列')),
                  body: MasonryGridView.count(
                      crossAxisCount: columns,
                      padding: const EdgeInsets.all(6),
                      itemCount: 8,
                      itemBuilder: (_, index) {
                        final i = index % 4;
                        return OnlineWaterfallCard(
                          title: titles[i],
                          cover: 'https://preview.invalid/${covers[i]}',
                          imageHeaders: const {},
                          author: authors[i],
                          authorAvatarUrl: i == 0
                              ? 'https://preview.invalid/avatar_torino.png'
                              : '',
                          showAuthorAvatar: true,
                          onAuthorTap: () {},
                          width: (ratios[i] * 1000).round(),
                          height: 1000,
                          tags: tags[i],
                          tagConfig: WaterfallTagDisplayConfig(
                              showTags: true, tagRows: columns == 2 ? 2 : 1),
                          isFavorited: i.isEven,
                          onToggleFavorite: () {},
                          onTap: () {},
                        );
                      })))));
      await tester.runAsync(() async {
        for (final element in find.byType(Image).evaluate()) {
          await precacheImage((element.widget as Image).image, element);
        }
      });
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
      expect(tester.takeException(), isNull);
      final boundary = boundaryKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final picture = await boundary.toImage(pixelRatio: 2);
        final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
        final output = File(
            'docs/verification/recommend-waterfall-009/production-$columns-col.png');
        await output.writeAsBytes(bytes!.buffer.asUint8List());
        picture.dispose();
      });
    }
  });
}
