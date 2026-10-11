import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/pages/online_comic/pixiv_detail_shell.dart';

class _DelayedImageProvider extends ImageProvider<_DelayedImageProvider> {
  final _image = Completer<ImageInfo>();
  void complete(ui.Image image) =>
      _image.complete(ImageInfo(image: image.clone()));
  void fail() => _image.completeError(StateError('offline image failure'));
  @override
  Future<_DelayedImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
          _DelayedImageProvider key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_image.future);
}

Future<ui.Image> _solidImage(WidgetTester tester, Color color,
        {int width = 40, int height = 40}) async =>
    (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
          Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          Paint()..color = color);
      final picture = recorder.endRecording();
      final image = await picture.toImage(width, height);
      picture.dispose();
      return image;
    }))!;

const _captureKey = ValueKey('050-capture');
Widget _shell(
        {required List<PixivDetailImage> images,
        bool loading = false,
        bool defer = false,
        bool singleAvatar = false,
        bool gallery = true,
        bool shortDetails = false,
        Object? identity,
        String? error,
        VoidCallback? retry,
        VoidCallback? action,
        ThemeData? theme,
        double scale = 1,
        bool reduceMotion = false,
        double bottomInset = 0}) =>
    MaterialApp(
        theme: (theme ?? ThemeData()).copyWith(
          textTheme: (theme ?? ThemeData())
              .textTheme
              .apply(fontFamily: 'PixivCapture050'),
          primaryTextTheme: (theme ?? ThemeData())
              .primaryTextTheme
              .apply(fontFamily: 'PixivCapture050'),
        ),
        home: Builder(
            builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(scale),
                      disableAnimations: reduceMotion,
                      padding: EdgeInsets.only(bottom: bottomInset)),
                  child: RepaintBoundary(
                      key: _captureKey,
                      child: PixivDetailShell(
                        title: '050延迟标题',
                        author: '050作者',
                        images: images,
                        imagesLoading: loading,
                        deferHeaderUntilImageReady: defer,
                        showSingleAuthorAvatar: singleAvatar,
                        galleryCollapsible: gallery,
                        showDetailsForShortGallery: shortDetails,
                        imageReadinessIdentity: identity,
                        imageError: error,
                        onRetryImages: retry,
                        actionLabel: '下载',
                        actionIcon: Icons.download_outlined,
                        onAction: action ?? () {},
                        sliversBuilder: (_) => const [
                          SliverToBoxAdapter(
                              child: SizedBox(
                                  height: 480,
                                  child: Align(
                                      alignment: Alignment.topLeft,
                                      child: Text('050短图集正文'))))
                        ],
                      )),
                )));
Finder _headerOpacity() =>
    find.byKey(const ValueKey('pixiv-header-ready-opacity-main'));
Finder _headerCluster() =>
    find.byKey(const ValueKey('pixiv-author-header-cluster'));
PixivDetailImage _detail(String key, ImageProvider<Object>? high,
        {ImageProvider<Object>? preview,
        Object? identity,
        bool known = true}) =>
    PixivDetailImage(
        key: key,
        provider: high,
        previewProvider: preview,
        contentIdentity: identity,
        aspectRatio: 1,
        aspectRatioKnown: known,
        onRead: () {});
void _mobile(WidgetTester tester, [Size size = const Size(400, 800)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump();
  }
}

Future<void> _capture(WidgetTester tester, String name,
    {Color? expectedCenter}) async {
  final ready = tester.widget<Opacity>(_headerOpacity()).opacity;
  final sizes = tester
      .widgetList<RawImage>(find.byType(RawImage))
      .where((w) => w.image != null)
      .map((w) => [w.image!.width, w.image!.height])
      .toList();
  final avatar = find.byKey(const ValueKey('pixiv-single-author-avatar'));
  final avatarSize = avatar.evaluate().isEmpty ? null : tester.getSize(avatar);
  await tester.runAsync(() async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final x = image.width ~/ 2;
    final y = (image.width ~/ 2).clamp(0, image.height - 1);
    final offset = (y * image.width + x) * 4;
    final pixel = List.generate(4, (i) => rgba!.getUint8(offset + i));
    if (expectedCenter != null) {
      final argb = expectedCenter.toARGB32();
      expect(pixel, [
        (argb >> 16) & 255,
        (argb >> 8) & 255,
        argb & 255,
        (argb >> 24) & 255
      ]);
    }
    final folder = Directory('docs/verification/pixiv-ui-050');
    await folder.create(recursive: true);
    await File('${folder.path}/$name.png')
        .writeAsBytes(data!.buffer.asUint8List());
    await File('${folder.path}/$name.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert({
      'evidence':
          'offline Flutter rendering; synthetic image pixels; no live CDN or device',
      'viewport': [image.width, image.height],
      'headerOpacity': ready,
      'renderedImageSizes': sizes,
      'samplePosition': [x, y],
      'sampleRGBA': pixel,
      'singleAvatarSlot':
          avatarSize == null ? null : [avatarSize.width, avatarSize.height],
    }));
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final font in [
      ('PixivCapture050', 'C:/Windows/Fonts/msyh.ttc'),
      (
        'MaterialIcons',
        'build/unit_test_assets/fonts/MaterialIcons-Regular.otf'
      ),
    ]) {
      final file = File(font.$2);
      if (!await file.exists()) continue;
      final bytes = await file.readAsBytes();
      await (FontLoader(font.$1)
            ..addFont(Future.value(ByteData.sublistView(bytes))))
          .load();
    }
  });
  tearDown(() {
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  testWidgets(
      '050 delayed known-ratio high hides entire header until first pixel',
      (tester) async {
    _mobile(tester);
    final semantics = tester.ensureSemantics();
    final delayed = _DelayedImageProvider();
    var actions = 0;
    await tester.pumpWidget(_shell(
        images: [_detail('delayed', delayed)],
        defer: true,
        identity: const ('account', 'work', 1),
        action: () => actions++));
    await _frames(tester);
    expect(tester.widget<Opacity>(_headerOpacity()).opacity, 0);
    expect(
        tester
            .widget<IgnorePointer>(
                find.byKey(const ValueKey('pixiv-header-ready-hit-test-main')))
            .ignoring,
        isTrue);
    expect(find.bySemanticsLabel(RegExp('050延迟标题')), findsNothing);
    final headerRect =
        tester.getRect(find.byKey(const ValueKey('pixiv-gallery-header')));
    await tester.tapAt(headerRect.center);
    await _frames(tester);
    expect(actions, 0);
    expect(find.byKey(const ValueKey('pixiv-detail-panel')), findsNothing);
    await _capture(tester, 'loading-header-hidden');
    final image = await _solidImage(tester, Colors.teal);
    delayed.complete(image);
    await _frames(tester);
    expect(tester.widget<Opacity>(_headerOpacity()).opacity, 1);
    expect(tester.getRect(find.byKey(const ValueKey('pixiv-gallery-header'))),
        headerRect);
    expect(find.bySemanticsLabel(RegExp('050延迟标题')), findsOneWidget);
    await _capture(tester, 'first-frame-header-visible');
    semantics.dispose();
    image.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '050 exact resized preview key and pixels persist until high first frame',
      (tester) async {
    _mobile(tester);
    final high = _DelayedImageProvider();
    final cover = _DelayedImageProvider();
    final preview = ResizeImage(cover, width: 120);
    final previewImage =
        await _solidImage(tester, Colors.indigo, width: 16, height: 16);
    cover.complete(previewImage);
    // Warm the same key that a list cover painted; detail must not resize it again.
    final stream = preview.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) => info.dispose());
    stream.addListener(listener);
    await _frames(tester);
    await tester.pumpWidget(_shell(
        images: [_detail('preview', high, preview: preview)], defer: true));
    await _frames(tester);
    final renderedPreview = tester.widget<Image>(find.byKey(
        ValueKey<(String, ImageProvider<Object>)>(
            ('pixiv-detail-preview', preview))));
    expect(identical(renderedPreview.image, preview), isTrue);
    expect(await renderedPreview.image.obtainKey(ImageConfiguration.empty),
        await preview.obtainKey(ImageConfiguration.empty));
    expect(tester.widget<Opacity>(_headerOpacity()).opacity, 1);
    expect(
        find
            .byType(RawImage)
            .evaluate()
            .map((e) => (e.widget as RawImage).image?.width),
        contains(16));
    await _capture(tester, 'preview-before-high',
        expectedCenter: Colors.indigo);
    final highImage =
        await _solidImage(tester, Colors.deepPurple, width: 32, height: 32);
    high.complete(highImage);
    await _frames(tester);
    expect(
        find.byKey(ValueKey<(String, ImageProvider<Object>)>(
            ('pixiv-detail-preview', preview))),
        findsNothing);
    expect(
        find
            .byType(RawImage)
            .evaluate()
            .map((e) => (e.widget as RawImage).image?.width),
        contains(32));
    expect(tester.widget<Opacity>(_headerOpacity()).opacity, 1);
    await _capture(tester, 'high-first-frame',
        expectedCenter: Colors.deepPurple);
    stream.removeListener(listener);
    previewImage.dispose();
    highImage.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '050 high failure retains preview and 48dp retry then recovers in same scroll',
      (tester) async {
    _mobile(tester);
    final cover = _DelayedImageProvider();
    final image = await _solidImage(tester, Colors.orange);
    cover.complete(image);
    final failed = _DelayedImageProvider();
    var retries = 0;
    await tester.pumpWidget(_shell(
        images: [_detail('failure', failed, preview: cover)],
        defer: true,
        retry: () => retries++));
    await _frames(tester);
    failed.fail();
    await _frames(tester);
    expect(find.text('高清图片加载失败'), findsOneWidget);
    expect(
        find.byKey(ValueKey<(String, ImageProvider<Object>)>(
            ('pixiv-detail-preview', cover))),
        findsOneWidget);
    final retry = find.byTooltip('重试高清图片');
    expect(tester.getSize(retry).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
    final position = tester
        .state<ScrollableState>(find.descendant(
            of: find.byKey(const ValueKey('pixiv-detail-page-scroll')),
            matching: find.byType(Scrollable)))
        .position;
    await tester.tap(retry);
    expect(retries, 1);
    final replacement = _DelayedImageProvider();
    await tester.pumpWidget(_shell(
        images: [_detail('failure', replacement, preview: cover, identity: 2)],
        defer: true));
    await _frames(tester);
    replacement.complete(image);
    await _frames(tester);
    expect(find.text('高清图片加载失败'), findsNothing);
    expect(
        identical(
            position,
            tester
                .state<ScrollableState>(find.descendant(
                    of: find.byKey(const ValueKey('pixiv-detail-page-scroll')),
                    matching: find.byType(Scrollable)))
                .position),
        isTrue);
    image.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('050 stale work stream never opens replacement work header',
      (tester) async {
    _mobile(tester);
    final old = _DelayedImageProvider();
    final current = _DelayedImageProvider();
    await tester.pumpWidget(_shell(
        images: [_detail('work-a', old)], defer: true, identity: ('a', 1)));
    await _frames(tester);
    await tester.pumpWidget(_shell(
        images: [_detail('work-b', current)], defer: true, identity: ('b', 2)));
    final image = await _solidImage(tester, Colors.teal);
    old.complete(image);
    await _frames(tester);
    expect(tester.widget<Opacity>(_headerOpacity()).opacity, 0);
    current.complete(image);
    await _frames(tester);
    expect(tester.widget<Opacity>(_headerOpacity()).opacity, 1);
    image.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '050 pages pending gates header, explicit page error recovers and legacy is compatible',
      (tester) async {
    _mobile(tester);
    await tester
        .pumpWidget(_shell(images: const [], loading: true, defer: true));
    await _frames(tester);
    expect(tester.widget<Opacity>(_headerOpacity()).opacity, 0);
    await tester.pumpWidget(
        _shell(images: const [], defer: true, error: 'offline pages failure'));
    await _frames(tester);
    expect(tester.widget<Opacity>(_headerOpacity()).opacity, 1);
    await tester.pumpWidget(_shell(images: const [], loading: true));
    await _frames(tester);
    expect(_headerOpacity(), findsNothing);
    expect(_headerCluster(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '050 short multipage gallery reveals body without an impossible scroll',
      (tester) async {
    _mobile(tester);
    final first = _DelayedImageProvider();
    final second = _DelayedImageProvider();
    final images = [
      for (final (index, provider) in [first, second].indexed)
        PixivDetailImage(
            key: 'short-$index',
            provider: provider,
            aspectRatio: 2,
            aspectRatioKnown: true,
            onRead: () {}),
    ];
    await tester
        .pumpWidget(_shell(images: images, shortDetails: true, defer: true));
    await _frames(tester);
    expect(find.text('050短图集正文'), findsNothing);
    final image = await _solidImage(tester, Colors.teal, width: 40, height: 20);
    first.complete(image);
    second.complete(image);
    await _frames(tester);
    await _frames(tester);
    expect(find.byKey(const ValueKey('pixiv-inline-details')), findsOneWidget);
    expect(find.text('050短图集正文'), findsOneWidget);
    final scroll = tester
        .state<ScrollableState>(find.descendant(
            of: find.byKey(const ValueKey('pixiv-detail-page-scroll')),
            matching: find.byType(Scrollable)))
        .position;
    expect(scroll.pixels, 0);
    final header =
        tester.getRect(find.byKey(const ValueKey('pixiv-gallery-header')));
    expect(header.top, 400);
    await _capture(tester, 'short-multipage-body-visible');
    image.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '050 tall gallery keeps details deferred and default short shell remains compatible',
      (tester) async {
    _mobile(tester);
    final provider = _DelayedImageProvider();
    final image = await _solidImage(tester, Colors.teal);
    provider.complete(image);
    await tester.pumpWidget(_shell(
        images: [_detail('tall1', provider), _detail('tall2', provider)],
        shortDetails: true,
        defer: true));
    await _frames(tester);
    await _frames(tester);
    expect(find.text('050短图集正文'), findsNothing);
    await tester.pumpWidget(_shell(images: [
      PixivDetailImage(
          key: 'short1',
          provider: null,
          aspectRatio: 4,
          aspectRatioKnown: true,
          onRead: () {})
    ], defer: true));
    await _frames(tester);
    await _frames(tester);
    expect(find.text('050短图集正文'), findsNothing);
    image.dispose();
    expect(tester.takeException(), isNull);
  });

  for (final variant in [
    (const Size(240, 640), 2.0, Brightness.light),
    (const Size(375, 812), 1.0, Brightness.dark),
    (const Size(812, 375), 1.0, Brightness.light)
  ]) {
    testWidgets(
        '050 single avatar responsive ${variant.$1.width} scale ${variant.$2} ${variant.$3.name}',
        (tester) async {
      _mobile(tester, variant.$1);
      await tester.pumpWidget(_shell(
          images: [_detail('single', null)],
          gallery: false,
          singleAvatar: true,
          defer: true,
          scale: variant.$2,
          theme: ThemeData(brightness: variant.$3),
          reduceMotion: true,
          bottomInset: 24));
      await _frames(tester);
      final position = tester
          .state<ScrollableState>(find.descendant(
              of: find.byKey(const ValueKey('pixiv-detail-page-scroll')),
              matching: find.byType(Scrollable)))
          .position;
      position.jumpTo(variant.$1.width.clamp(0.0, position.maxScrollExtent));
      await _frames(tester);
      final avatar = find.byKey(const ValueKey('pixiv-single-author-avatar'));
      expect(tester.getSize(avatar), const Size.square(48));
      expect(find.byKey(const ValueKey('pixiv-gallery-author-avatar')),
          findsNothing);
      expect(_headerCluster(), findsNothing);
      expect(tester.widget<Opacity>(_headerOpacity()).opacity, 1);
      await _capture(
          tester, 'single-${variant.$1.width.toInt()}-${variant.$3.name}');
      expect(tester.takeException(), isNull);
    });
  }
}
