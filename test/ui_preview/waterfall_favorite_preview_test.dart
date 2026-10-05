import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;
import 'package:picakeep/pages/online_common/online_waterfall_card.dart';

class _FixtureHttpOverrides extends HttpOverrides {
  _FixtureHttpOverrides(this.bytes);
  final Map<String, Uint8List> bytes;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FixtureClient(bytes);
}

class _FixtureClient implements HttpClient {
  _FixtureClient(this.bytes);
  final Map<String, Uint8List> bytes;
  @override
  bool autoUncompress = true;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _FixtureRequest(bytes[url.path]!);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('HttpClient.${invocation.memberName}');
}

class _FixtureRequest implements HttpClientRequest {
  _FixtureRequest(this.bytes);
  final Uint8List bytes;
  @override
  final HttpHeaders headers = _FixtureHeaders();
  @override
  Future<HttpClientResponse> close() async => _FixtureResponse(bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('HttpClientRequest.${invocation.memberName}');
}

class _FixtureHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FixtureResponse implements HttpClientResponse {
  _FixtureResponse(this.bytes);
  final Uint8List bytes;
  @override
  int get statusCode => HttpStatus.ok;
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
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('HttpClientResponse.${invocation.memberName}');
}

Future<bool> _loadFont(String family, Iterable<String> paths) async {
  for (final path in paths) {
    try {
      final bytes = await File(path).readAsBytes();
      await (FontLoader(family)
            ..addFont(Future.value(ByteData.sublistView(bytes))))
          .load();
      return true;
    } catch (_) {
      // A preview remains useful for icon shape even without the optional font.
    }
  }
  return false;
}

void main() {
  testWidgets('renders favorite states on white and dark offline cover images',
      (tester) async {
    tester.view.physicalSize = const Size(540, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final previousHttp = HttpOverrides.current;
    final covers = <String, Uint8List>{};
    for (final item in <(String, int)>[('white', 255), ('dark', 25)]) {
      final canvas = raster.Image(width: 160, height: 220)
        ..clear(raster.ColorRgba8(item.$2, item.$2, item.$2, 255));
      covers['/${item.$1}.png'] = Uint8List.fromList(raster.encodePng(canvas));
    }
    HttpOverrides.global = _FixtureHttpOverrides(covers);
    addTearDown(() {
      HttpOverrides.global = previousHttp;
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });
    final windows = Platform.environment['WINDIR'];
    var textFontLoaded = false;
    await tester.runAsync(() async {
      await _loadFont('MaterialIcons', const [
        'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
        'build/flutter_assets/fonts/MaterialIcons-Regular.otf',
      ]);
      if (windows != null) {
        textFontLoaded =
            await _loadFont('PreviewSans', ['$windows/Fonts/segoeui.ttf']);
      }
    });
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: textFontLoaded ? 'PreviewSans' : null),
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: ColoredBox(
              color: const Color(0xFFF3F3F3),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final cover in ['white', 'dark'])
                    Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final state in [
                            'unselected',
                            'waiting',
                            'saved'
                          ])
                            SizedBox(
                              width: 170,
                              child: OnlineWaterfallCard(
                                title: '$cover / $state',
                                cover: 'https://fixture.invalid/$cover.png',
                                imageHeaders: const {},
                                width: 160,
                                height: 220,
                                onTap: () {},
                                onToggleFavorite: () {},
                                favoriteBusy: state == 'waiting',
                                isFavorited: state == 'saved',
                              ),
                            ),
                        ]),
                ]),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.runAsync(() async {
      for (final image in tester.widgetList<Image>(find.byType(Image))) {
        await precacheImage(
            image.image, tester.element(find.byType(Image).first));
      }
    });
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
    expect(find.byIcon(Icons.favorite_border), findsNWidgets(2));
    expect(find.byIcon(Icons.favorite), findsNWidgets(4));
    await tester.runAsync(() async {
      final boundary = boundaryKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      expect(bytes, isNotNull);
      final output = File(
          'build/verification/pixiv-detail-018/waterfall-favorite-white-dark.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull);
  });
}
