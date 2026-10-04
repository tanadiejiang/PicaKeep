import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';
import 'package:picakeep/network/res.dart';
import 'package:sqlite3/open.dart';

class _OfflineAdapter implements HttpClientAdapter {
  _OfflineAdapter(this.replies, this.requests, {this.onRequest});

  final List<String> replies;
  final List<RequestOptions> requests;
  final Future<void> Function(RequestOptions)? onRequest;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    await onRequest?.call(options);
    if (replies.isEmpty) throw StateError('Unexpected offline request');
    return ResponseBody.fromString(replies.removeAt(0), 200, headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
    OperatingSystem.windows,
    () => DynamicLibrary.open(
      '${Directory.current.path}${Platform.pathSeparator}windows'
      '${Platform.pathSeparator}sqlite3.dll',
    ),
  );

  group('榜单快捷收藏使用严格的作品收藏状态', () {
    test('明确 null 才能确认未收藏，并保留明确的添加能力', () {
      for (final capability in <dynamic>[true, 1, '1']) {
        final state = parsePixivBookmarkState({
          'bookmarkData': null,
          'isBookmarkable': capability,
        });
        expect(state.isBookmarked, isFalse);
        expect(state.isBookmarkable, isTrue);
      }
    });

    test('正数字书签 ID 确认已收藏，支持字符串和 JSON 数字', () {
      for (final id in <dynamic>['900', 900]) {
        final state = parsePixivBookmarkState({
          'bookmarkData': {'id': id, 'private': false},
          'isBookmarkable': false,
        });
        expect(state.isBookmarked, isTrue);
        expect(state.isBookmarkable, isFalse, reason: '已经收藏与是否允许添加是两个独立字段');
      }
    });

    test('能力缺失、明确禁用或未知值都不开放添加', () {
      expect(
        parsePixivBookmarkState({'bookmarkData': null}).isBookmarkable,
        isFalse,
      );
      for (final capability in <dynamic>[
        null,
        false,
        0,
        '0',
        2,
        -1,
        'true',
        'unexpected',
        <String, dynamic>{},
        <dynamic>[],
      ]) {
        final state = parsePixivBookmarkState({
          'bookmarkData': null,
          'isBookmarkable': capability,
        });
        expect(state.isBookmarked, isFalse);
        expect(state.isBookmarkable, isFalse, reason: '$capability');
      }
    });

    test('缺少 bookmarkData 或异常类型不能伪装成未收藏', () {
      for (final body in <Map<String, dynamic>>[
        {},
        {'isBookmarkable': true},
        {'bookmarkData': 'unexpected', 'isBookmarkable': true},
        {'bookmarkData': false, 'isBookmarkable': true},
        {'bookmarkData': 0, 'isBookmarkable': true},
        {'bookmarkData': <dynamic>[], 'isBookmarkable': true},
      ]) {
        expect(() => parsePixivBookmarkState(body),
            throwsA(isA<FormatException>()),
            reason: '$body');
      }
    });

    test('收藏对象缺少有效正数字 ID 时拒绝整个状态', () {
      final malformed = <Map<String, dynamic>>[
        {},
        for (final id in <dynamic>[
          null,
          '',
          'abc',
          '900&other=1',
          '+900',
          '1.5',
          1.5,
          0,
          '0',
          -1,
          '-1',
          true,
          <String, dynamic>{},
        ])
          {'id': id},
      ];
      for (final data in malformed) {
        expect(
          () => parsePixivBookmarkState({
            'bookmarkData': data,
            'isBookmarkable': true,
          }),
          throwsA(isA<FormatException>()),
          reason: '$data',
        );
      }
    });
  });

  group('收藏状态查询只读并绑定发起时的账号', () {
    late Directory workspace;
    late CookieJarSql jar;
    late PixivNetwork network;
    late List<ComicSource> sources;
    late bool wasRecording;
    final replies = <String>[];
    final requests = <RequestOptions>[];
    Future<void> Function(RequestOptions)? onRequest;

    setUp(() async {
      sources = List.of(ComicSource.sources);
      ComicSource.sources
        ..clear()
        ..add(ComicSource.named(key: 'pixiv', name: 'Pixiv')
          ..data['userId'] = '99');
      wasRecording = LogManager.recordingEnabled;
      LogManager.recordingEnabled = false;
      workspace =
          await Directory.systemTemp.createTemp('pixiv_ranking_bookmark_');
      jar = CookieJarSql('${workspace.path}/cookies.db');
      jar.saveFromResponse(Uri.parse(PixivNetwork.pixivWebBase), [
        Cookie('PHPSESSID', 'offline-session')
          ..domain = '.pixiv.net'
          ..path = '/',
      ]);
      replies.clear();
      requests.clear();
      onRequest = null;
      network = PixivNetwork.forTesting(
        cookieJar: jar,
        dioFactory: () => Dio()
          ..httpClientAdapter =
              _OfflineAdapter(replies, requests, onRequest: onRequest),
      );
    });

    tearDown(() async {
      jar.dispose();
      await workspace.delete(recursive: true);
      ComicSource.sources
        ..clear()
        ..addAll(sources);
      LogManager.recordingEnabled = wasRecording;
    });

    test('已登录时只 GET 指定作品，返回已确认的状态', () async {
      for (final bookmarkData in <dynamic>[
        null,
        {'id': '900'},
      ]) {
        replies.add(jsonEncode({
          'error': false,
          'body': {'bookmarkData': bookmarkData, 'isBookmarkable': true},
        }));
        final result = await network.getBookmarkState(' 41 ');
        expect(result.success, isTrue);
        expect(result.data.isBookmarked, bookmarkData != null);
        expect(result.data.isBookmarkable, isTrue);
      }
      expect(requests, hasLength(2));
      for (final request in requests) {
        expect(request.method, 'GET');
        expect(request.uri.path, '/ajax/illust/41');
        expect(request.uri.queryParameters, {'lang': 'zh'});
        expect(
            request.headers['Cookie'], contains('PHPSESSID=offline-session'));
        expect(request.headers['User-Agent'], PixivNetwork.pixivWebUA);
        expect(request.headers.containsKey('X-CSRF-Token'), isFalse,
            reason: '只读确认不获取写入令牌或发起收藏写操作');
      }
      expect(replies, isEmpty);
    });

    test('未登录和无效作品 ID 在本地拒绝，不发 GET', () async {
      for (final id in ['', '-1', '0', 'abc', '41&other=1', '1.5']) {
        final result = await network.getBookmarkState(id);
        expect(result.errorCode, ResErrorCode.invalidArgument, reason: id);
        expect(result.dataOrNull, isNull);
      }
      await network.logout();
      final result = await network.getBookmarkState('41');
      expect(result.errorCode, ResErrorCode.loginRequired);
      expect(result.dataOrNull, isNull);
      expect(requests, isEmpty);
    });

    test('body 不是对象或状态损坏时返回解析错误，不提供伪造状态', () async {
      final responses = <Map<String, dynamic>>[
        {'error': false},
        for (final body in <dynamic>[null, 'unexpected', false, 1, <dynamic>[]])
          {'error': false, 'body': body},
        for (final body in <Map<String, dynamic>>[
          {},
          {'isBookmarkable': true},
          {'bookmarkData': 'unexpected', 'isBookmarkable': true},
          {'bookmarkData': <String, dynamic>{}, 'isBookmarkable': true},
          {
            'bookmarkData': {'id': 0},
            'isBookmarkable': true,
          },
        ])
          {'error': false, 'body': body},
      ];
      for (final response in responses) {
        replies.add(jsonEncode(response));
        final result = await network.getBookmarkState('41');
        expect(result.errorCode, ResErrorCode.parse, reason: '$response');
        expect(result.dataOrNull, isNull);
      }
      expect(requests, hasLength(responses.length));
      expect(requests.every((request) => request.method == 'GET'), isTrue);
      expect(replies, isEmpty);
    });

    for (final logOut in [false, true]) {
      test('GET 尚未完成时${logOut ? '退出登录' : '切换账号'}，拒绝旧账号的有效状态', () async {
        final started = Completer<void>();
        final release = Completer<void>();
        onRequest = (options) async {
          expect(options.method, 'GET');
          expect(
              options.headers['Cookie'], contains('PHPSESSID=offline-session'));
          started.complete();
          await release.future;
        };
        replies.add(jsonEncode({
          'error': false,
          'body': {
            'bookmarkData': {'id': '900'},
            'isBookmarkable': true,
          },
        }));
        final pending = network.getBookmarkState('41');
        await started.future;
        try {
          if (logOut) {
            await network.logout();
          } else {
            await network.setSessionCookie('different-offline-session');
          }
        } finally {
          release.complete();
        }
        final result = await pending;
        expect(result.errorCode, ResErrorCode.loginRequired);
        expect(result.dataOrNull, isNull, reason: '查询前捕获的账号已失效，不能把返回状态应用到新账号');
        expect(requests, hasLength(1));
        expect(requests.single.method, 'GET');
        expect(replies, isEmpty);
      });
    }
  });
}
