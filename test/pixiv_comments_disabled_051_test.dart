import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/online_comic/pixiv_comments_section.dart';

const _frame = Duration(milliseconds: 16);
const _output = 'docs/verification/pixiv-comments-051';
final _captureKey = GlobalKey();
const _empty = PixivCommentPage(comments: [], hasNext: false, originalCount: 0);
const _root = PixivComment(
    id: '700',
    userId: '100',
    userName: '051 fixture',
    avatarUrl: '',
    comment: 'offline root',
    commentDate: '',
    hasReplies: true);
const _rootPage =
    PixivCommentPage(comments: [_root], hasNext: false, originalCount: 1);

Widget _host(
        {required bool disabled,
        required PixivCommentRootsLoader roots,
        PixivCommentRepliesLoader? replies,
        bool autoLoad = true,
        double scale = 1,
        Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: ThemeData(
          brightness: brightness,
          textTheme: ThemeData(brightness: brightness)
              .textTheme
              .apply(fontFamily: '051Chinese')),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale), disableAnimations: true),
          child: child!),
      home: RepaintBoundary(
          key: _captureKey,
          child: Scaffold(
            body: SafeArea(
                child: CustomScrollView(slivers: [
              PixivCommentsSection(
                  key: const ValueKey('051-comments'),
                  illustId: '150343763',
                  commentsDisabled: disabled,
                  autoLoad: autoLoad,
                  previewLimit: 4,
                  loadRoots: roots,
                  loadReplies: replies ?? (_, __) async => const Res(_empty)),
            ])),
          )),
    );

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(_frame);
  }
}

void _assertDisabled() {
  expect(find.text('作者已关闭评论区'), findsOneWidget);
  expect(find.text('暂无评论'), findsNothing);
  expect(find.text('不正确的请求。'), findsNothing);
  expect(find.text('展开更多评论'), findsNothing);
  expect(find.byTooltip('重试'), findsNothing);
  expect(find.byType(CircularProgressIndicator), findsNothing);
  expect(
      find.byWidgetPredicate((w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>)
              .value
              .startsWith('pixiv-comments-placeholder-')),
      findsNothing);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (font.existsSync()) {
      final bytes = font.readAsBytesSync();
      final loader = FontLoader('051Chinese')
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
    }
  });

  for (final autoLoad in [true, false]) {
    testWidgets(
        'closed comments have a semantic notice and zero requests autoLoad=$autoLoad',
        (tester) async {
      var roots = 0;
      var replies = 0;
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_host(
          disabled: true,
          autoLoad: autoLoad,
          roots: (_, __, ___) async {
            roots++;
            return const Res(_empty);
          },
          replies: (_, __) async {
            replies++;
            return const Res(_empty);
          }));
      await _frames(tester);
      _assertDisabled();
      expect(find.bySemanticsLabel('作者已关闭评论区'), findsOneWidget);
      expect(roots, 0);
      expect(replies, 0);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }

  testWidgets('enabled comments with zero items are empty, not disabled',
      (tester) async {
    var requests = 0;
    await tester.pumpWidget(_host(
        disabled: false,
        roots: (_, __, ___) async {
          requests++;
          return const Res(_empty);
        }));
    await _frames(tester);
    expect(requests, 1);
    expect(find.text('暂无评论'), findsOneWidget);
    expect(find.text('作者已关闭评论区'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing while a root error is pending rejects the stale error',
      (tester) async {
    var requests = 0;
    final pending = Completer<Res<PixivCommentPage>>();
    Future<Res<PixivCommentPage>> roots(String id, int offset, int limit) {
      requests++;
      return pending.future;
    }

    await tester.pumpWidget(_host(disabled: false, roots: roots));
    await _frames(tester);
    expect(requests, 1);
    await tester.pumpWidget(_host(disabled: true, roots: roots));
    pending.complete(const Res.error('不正确的请求。'));
    await _frames(tester);
    _assertDisabled();
    expect(requests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopening starts a fresh read and ignores the old pending epoch',
      (tester) async {
    var requests = 0;
    final old = Completer<Res<PixivCommentPage>>();
    Future<Res<PixivCommentPage>> roots(String id, int offset, int limit) {
      requests++;
      return requests == 1 ? old.future : Future.value(const Res(_rootPage));
    }

    await tester.pumpWidget(_host(disabled: false, roots: roots));
    await _frames(tester);
    await tester.pumpWidget(_host(disabled: true, roots: roots));
    await _frames(tester);
    _assertDisabled();
    await tester.pumpWidget(_host(disabled: false, roots: roots));
    await _frames(tester);
    old.complete(const Res.error('old root must not return'));
    await _frames(tester);
    expect(requests, 2);
    expect(find.text('offline root'), findsOneWidget);
    expect(find.text('old root must not return'), findsNothing);
    expect(find.text('作者已关闭评论区'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing removes loaded roots and ignores pending replies',
      (tester) async {
    var rootRequests = 0;
    var replyRequests = 0;
    final pending = Completer<Res<PixivCommentPage>>();
    Future<Res<PixivCommentPage>> roots(
        String id, int offset, int limit) async {
      rootRequests++;
      return const Res(_rootPage);
    }

    Future<Res<PixivCommentPage>> replies(String id, int page) {
      replyRequests++;
      return pending.future;
    }

    await tester
        .pumpWidget(_host(disabled: false, roots: roots, replies: replies));
    await _frames(tester);
    await tester.tap(find.textContaining('回复').last);
    await _frames(tester);
    expect(replyRequests, 1);
    await tester
        .pumpWidget(_host(disabled: true, roots: roots, replies: replies));
    pending.complete(const Res.error('stale reply must not return'));
    await _frames(tester);
    _assertDisabled();
    expect(find.text('offline root'), findsNothing);
    expect(find.text('stale reply must not return'), findsNothing);
    expect(rootRequests, 1);
    expect(replyRequests, 1);
    expect(tester.takeException(), isNull);
  });

  for (final spec in <(int, int, double, Brightness)>[
    (375, 812, 1, Brightness.light),
    (240, 800, 2, Brightness.dark),
    (812, 375, 1, Brightness.light),
  ]) {
    testWidgets('closed state capture ${spec.$1}x${spec.$2} scale${spec.$3}',
        (tester) async {
      tester.view.physicalSize = Size(spec.$1.toDouble(), spec.$2.toDouble());
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var requests = 0;
      await tester.pumpWidget(_host(
          disabled: true,
          scale: spec.$3,
          brightness: spec.$4,
          roots: (_, __, ___) async {
            requests++;
            return const Res(_empty);
          }));
      await _frames(tester);
      _assertDisabled();
      final rect = tester.getRect(find.text('作者已关闭评论区'));
      expect(rect.left, greaterThanOrEqualTo(16));
      expect(rect.right, lessThanOrEqualTo(spec.$1 - 16));
      expect(requests, 0);
      expect(tester.takeException(), isNull);
      final boundary =
          tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          return await image.toByteData(format: ui.ImageByteFormat.png);
        } finally {
          image.dispose();
        }
      });
      final folder = Directory(_output)..createSync(recursive: true);
      final basename = 'disabled-${spec.$1}-${spec.$4.name}';
      File('${folder.path}/$basename.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
      File('${folder.path}/$basename.json')
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
        'evidence':
            'offline Flutter rendering; synthetic metadata; not a live Pixiv response or device',
        'viewport': [spec.$1, spec.$2],
        'textScale': spec.$3,
        'disabledMessage': '作者已关闭评论区',
        'rootRequests': requests,
        'messageRect': [rect.left, rect.top, rect.right, rect.bottom],
      }));
    });
  }
}
