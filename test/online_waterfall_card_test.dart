import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/pages/online_common/online_comic_list_item.dart';
import 'package:picakeep/pages/online_common/online_waterfall_card.dart';

void main() {
  tearDown(clearOnlineCoverProviderCache);

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
