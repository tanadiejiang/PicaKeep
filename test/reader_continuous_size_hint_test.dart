import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/components/scrollable_list/src/item_positions_listener.dart';
import 'package:picakeep/components/scrollable_list/src/scrollable_positioned_list.dart';
import 'package:picakeep/foundation/image_pipeline/image_work_scheduler.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_raster_backend.dart';
import 'package:picakeep/foundation/image_pipeline/reader_viewport.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/pages/reader/reader_page_image.dart';

// 053: a continuous page rebuilt above the viewport used to lay out at a
// 1.4 placeholder first and shrink a frame later. The forward sliver keeps
// that page's offset, so every visible page moved up and upward drags
// snapped back. A session size hint lays it out at its real height at once.

class _Backend extends ReaderRasterBackend {
  const _Backend();
  static const metadata = ReaderRasterMetadata(
      size: Size(400, 600),
      animated: false,
      format: 'fixture',
      workingBytes: 1);
  @override
  bool get requiresFileBacking => false;
  @override
  Future<ReaderRasterMetadata> probe(File file) async => metadata;
  @override
  Future<ui.Image> decode(File file, ReaderTileDemand demand,
      {required String backingPath,
      required int memoryBudgetBytes,
      required bool Function() isCancelled,
      Future<void>? cancelled}) async {
    if (isCancelled()) throw const ImageWorkCancelled();
    final picture = ui.PictureRecorder();
    Canvas(picture).drawColor(Colors.blue, BlendMode.src);
    final recording = picture.endRecording();
    try {
      return recording.toImageSync(demand.outputWidth, demand.outputHeight);
    } finally {
      recording.dispose();
    }
  }
}

class _Source extends FileReaderPageSource implements RasterReaderPageSource {
  _Source()
      : super(
            identity: const ReaderPageIdentity(
                sourceKey: 'fixture',
                workId: 'hint',
                downloadId: 'hint',
                episode: 1,
                page: 0,
                sourceVersion: '1'),
            file: File('unused-hint'));
  @override
  ReaderRasterBackend get rasterBackend => const _Backend();
  @override
  File get rasterLocator => File('unused-hint');
  @override
  Future<ReaderRasterMetadata> openRasterMetadata() async => _Backend.metadata;
}

Widget _page(Future<ReaderPageSource> Function() load,
        {Size? hint, ValueChanged<Size>? onSize}) =>
    MaterialApp(
        home: Align(
            alignment: Alignment.topLeft,
            child: ReaderPageImage(
                loadSource: load,
                resourceKey: 'hint',
                viewportKey: GlobalKey(),
                transformChanges: ChangeNotifier(),
                mode: ReaderDisplayMode.sharpFirst,
                continuousWidth: 300,
                sizeHint: hint,
                onSourceSize: onSize)));

double _height(WidgetTester tester) =>
    tester.getSize(find.byType(ReaderPageImage)).height;

/// Mimics a continuous reader page: unknown pages start at 1.4w and settle a
/// frame later; with [useHints] a rebuilt page starts at its remembered size.
class _FakePage extends StatefulWidget {
  const _FakePage(this.index, this.hints, this.useHints, {super.key});
  final int index;
  final Map<int, double> hints;
  final bool useHints;
  @override
  State<_FakePage> createState() => _FakePageState();
}

class _FakePageState extends State<_FakePage> {
  static const width = 400.0, real = 0.7 * width;
  late double height =
      (widget.useHints ? widget.hints[widget.index] : null) ?? 1.4 * width;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => height = real);
      widget.hints[widget.index] = real;
    });
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(width: width, height: height, child: Text('p${widget.index}'));
}

void main() {
  testWidgets('size hint lays a continuous page out at its real height',
      (tester) async {
    final never = Completer<ReaderPageSource>();
    await tester.pumpWidget(_page(() => never.future));
    expect(_height(tester), closeTo(300 * 1.4, 0.01),
        reason: 'an unknown page keeps the 1.4 placeholder');

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
        _page(() => never.future, hint: const Size(400, 300)));
    expect(_height(tester), closeTo(225, 0.01),
        reason: 'a remembered page is laid out at its real height first');
  });

  testWidgets('resolved source size is reported for later rebuilds',
      (tester) async {
    final reported = <Size>[];
    await tester.pumpWidget(_page(() async => _Source(), onSize: reported.add));
    for (var i = 0; i < 8 && reported.isEmpty; i++) {
      await tester.pump();
    }
    expect(reported, [const Size(400, 600)]);
    await tester.pump();
    expect(_height(tester), closeTo(450, 0.01));
  });

  Future<List<double>> dragUp(WidgetTester tester, bool useHints) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final hints = <int, double>{};
    final positions = ItemPositionsListener.create();
    final controller = ScrollController();
    await tester.pumpWidget(MaterialApp(
        home: ScrollablePositionedList.builder(
            itemCount: 60,
            scrollController: controller,
            itemPositionsListener: positions,
            physics: const ClampingScrollPhysics(),
            itemBuilder: (_, i) =>
                _FakePage(i, hints, useHints, key: ValueKey(i)))));
    await tester.pump();
    // Read down far enough that the first pages leave the cache extent.
    for (var i = 0; i < 30; i++) {
      controller.jumpTo(controller.offset + 200);
      await tester.pump();
      await tester.pump();
    }
    double anchorTop(int index) =>
        tester.getTopLeft(find.text('p$index')).dy;
    final anchor = positions.itemPositions.value
        .reduce((a, b) => a.index < b.index ? a : b)
        .index + 1;
    var previous = anchorTop(anchor);
    final steps = <double>[];
    final gesture = await tester.startGesture(const Offset(200, 300));
    for (var i = 0; i < 40; i++) {
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump();
      await tester.pump();
      if (find.text('p$anchor').evaluate().isEmpty) break;
      final top = anchorTop(anchor);
      steps.add(top - previous);
      previous = top;
    }
    await gesture.up();
    await tester.pumpAndSettle();
    return steps;
  }

  testWidgets('upward drag without hints is pushed back by shrinking pages',
      (tester) async {
    final steps = await dragUp(tester, false);
    expect(steps.any((d) => d < 0), isTrue,
        reason: 'baseline: the snap-back mechanism reproduces');
  });

  testWidgets('upward drag with hints moves content with the finger',
      (tester) async {
    final steps = await dragUp(tester, true);
    expect(steps, isNotEmpty);
    expect(steps.every((d) => d >= 0), isTrue,
        reason: 'no visible page moves against the finger: $steps');
  });
}
