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
import 'package:picakeep/network/res.dart';
import 'package:sqlite3/open.dart';

class _Reply {
  const _Reply(this.body, {this.status = 200, this.fail = false});
  final String body;
  final int status;
  final bool fail;
}

// Every request uses this adapter. No real network/account is accessed.
class _OfflineAdapter implements HttpClientAdapter {
  _OfflineAdapter(this.replies, this.requests, this.onRequest);
  final List<_Reply> replies;
  final List<RequestOptions> requests;
  final Future<void> Function()? onRequest;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    await onRequest?.call();
    if (replies.isEmpty) throw StateError('Unexpected offline request');
    final reply = replies.removeAt(0);
    if (reply.fail) {
      throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          message: 'offline recommendation failure');
    }
    return ResponseBody.fromString(reply.body, reply.status, headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    });
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _work(String id, String uid) => {
      'id': id,
      'title': 'Work $id',
      'userId': uid,
      'url': 'https://i.pximg.net/$id.jpg',
      'isMasked': false,
      'xRestrict': 0,
      'isBookmarkable': false,
    };

Map<String, dynamic> _body({bool empty = false}) => {
      'recommendUsers': empty
          ? []
          : [
              {
                'userId': '50',
                'illustIds': ['9', '100']
              },
              {'userId': '42', 'illustIds': []},
            ],
      'users': empty
          ? []
          : [
              {'userId': '42', 'name': 'Seed'},
              {
                'userId': '50',
                'name': 'Artist',
                'image': 'https://i.pximg.net/50.jpg',
                'isFollowed': true
              },
            ],
      'thumbnails': {
        'illust': empty ? [] : [_work('100', '50'), _work('9', '50')]
      },
    };

_Reply _ok(Object? body) =>
    _Reply(jsonEncode({'error': false, 'message': '', 'body': body}));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
    OperatingSystem.windows,
    () => DynamicLibrary.open(
        '${Directory.current.path}${Platform.pathSeparator}windows'
        '${Platform.pathSeparator}sqlite3.dll'),
  );

  late Directory workspace;
  late CookieJarSql jar;
  late PixivNetwork network;
  late List<ComicSource> oldSources;
  late bool wasRecording;
  final replies = <_Reply>[];
  final requests = <RequestOptions>[];
  Future<void> Function()? onRequest;

  setUp(() async {
    oldSources = List.of(ComicSource.sources);
    ComicSource.sources
      ..clear()
      ..add(ComicSource.named(key: 'pixiv', name: 'Pixiv'));
    wasRecording = LogManager.recordingEnabled;
    LogManager.recordingEnabled = false;
    final tempRoot = Directory('.dart_tool/039-follow-temp');
    await tempRoot.create(recursive: true);
    workspace = await tempRoot.createTemp('offline-recommends-');
    jar = CookieJarSql('${workspace.path}/cookies.db');
    replies.clear();
    requests.clear();
    onRequest = null;
    network = PixivNetwork.forTesting(
      cookieJar: jar,
      dioFactory: () => Dio()
        ..httpClientAdapter = _OfflineAdapter(replies, requests, onRequest),
    );
  });

  tearDown(() async {
    jar.dispose();
    // workspace is the directory returned by this test's createTemp above.
    expect(workspace.absolute.path,
        startsWith(Directory('.dart_tool/039-follow-temp').absolute.path));
    await workspace.delete(recursive: true);
    ComicSource.sources
      ..clear()
      ..addAll(oldSources);
    LogManager.recordingEnabled = wasRecording;
  });

  test('one anonymous GET uses verified seed path and fixed safe parameters',
      () async {
    replies.add(_ok(_body()));
    final result = await network.getRecommendedAuthors(' 42 ');
    expect(result.success, isTrue);
    expect(result.data.single.author.id, '50');
    expect(result.data.single.author.isFollowed, isTrue);
    expect(result.data.single.works.map((work) => work.id), ['9', '100']);
    expect(result.data.single.works.first.isBookmarkable, isFalse);
    expect(result.data.single.works.first.bookmarkStateKnown, isFalse);
    expect(result.data.single.works.first.canLoadBookmarkState, isTrue);
    final request = requests.single;
    expect(request.method, 'GET');
    expect(request.uri.host, 'www.pixiv.net');
    expect(request.uri.path, '/ajax/user/42/recommends');
    expect(request.uri.queryParameters,
        {'userNum': '5', 'workNum': '3', 'isR18': 'false', 'lang': 'zh'});
    expect(request.headers['Cookie'], isNull);
    expect(request.headers['User-Agent'], PixivNetwork.pixivWebUA);
    expect(request.headers['Referer'], 'https://www.pixiv.net/');
    expect(request.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('x-csrf-token')));
    expect(request.data, isNull);
  });

  test('smaller client bounds are sent and enforced on oversized responses',
      () async {
    replies.add(_ok(_body()));
    final result =
        await network.getRecommendedAuthors('42', limit: 1, workLimit: 1);
    expect(result.data, hasLength(1));
    expect(result.data.single.works.single.id, '9');
    expect(requests.single.uri.queryParameters,
        {'userNum': '1', 'workNum': '1', 'isR18': 'false', 'lang': 'zh'});
  });

  test('invalid UID and author/work bounds never create a request', () async {
    for (final uid in ['', '0', '-1', 'bad', '1.5', '42&isR18=true']) {
      expect((await network.getRecommendedAuthors(uid)).errorCode,
          ResErrorCode.invalidArgument);
    }
    for (final limit in [-1, 0, 6]) {
      expect(
          (await network.getRecommendedAuthors('42', limit: limit)).errorCode,
          ResErrorCode.invalidArgument);
    }
    for (final limit in [-1, 0, 4]) {
      expect(
          (await network.getRecommendedAuthors('42', workLimit: limit))
              .errorCode,
          ResErrorCode.invalidArgument);
    }
    expect(requests, isEmpty);
  });

  test('offline session uses isolated jar, without CSRF or follow POST',
      () async {
    await network.saveCookies(
        {'PHPSESSID': 'offline-follow-session', 'extra': 'offline'});
    replies.add(_ok(_body(empty: true)));
    expect((await network.getRecommendedAuthors('42')).success, isTrue);
    final request = requests.single;
    expect(request.method, 'GET');
    expect(request.headers['Cookie'],
        contains('PHPSESSID=offline-follow-session'));
    expect(request.headers['Cookie'], contains('extra=offline'));
    expect(request.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('x-csrf-token')));
  });

  test('requires explicit successful envelope and preserves business failures',
      () async {
    replies.addAll([
      _Reply(jsonEncode({'body': _body(empty: true)})),
      const _Reply('{"error":"denied"}'),
      const _Reply('{"error":true,"message":"Unavailable"}', status: 400),
    ]);
    expect((await network.getRecommendedAuthors('42')).errorCode,
        ResErrorCode.parse);
    expect((await network.getRecommendedAuthors('42')).errorMessage, 'denied');
    final denied = await network.getRecommendedAuthors('42');
    expect(denied.errorMessage, 'Unavailable');
    expect(denied.errorCode, ResErrorCode.accessDenied);
    expect(denied.statusCode, 400);
    expect(requests, hasLength(3));
  });

  test(
      'wrong shape is a parse error while legal empty body is an empty success',
      () async {
    for (final body in [
      null,
      [],
      {},
      {'recommendUsers': []},
      {..._body(), 'users': {}},
      {
        ..._body(),
        'thumbnails': {'illust': {}}
      },
      {
        ..._body(),
        'recommendUsers': [
          {'userId': '50', 'illustIds': null}
        ]
      },
    ]) {
      replies.add(_ok(body));
      expect((await network.getRecommendedAuthors('42')).errorCode,
          ResErrorCode.parse);
    }
    replies.add(_ok(_body(empty: true)));
    final empty = await network.getRecommendedAuthors('42');
    expect(empty.success, isTrue);
    expect(empty.data, isEmpty);
    expect(requests, hasLength(8));
  });

  test('follow POST empty array cannot be reused as recommendation success',
      () async {
    replies.add(_ok([]));
    expect((await network.getRecommendedAuthors('42')).errorCode,
        ResErrorCode.parse);
    expect(requests.single.method, 'GET');
  });

  test('non-JSON retry stays on the same endpoint and never guesses a fallback',
      () async {
    replies.addAll(const [
      _Reply('<html>blocked</html>'),
      _Reply('<html>blocked</html>'),
    ]);
    final result = await network.getRecommendedAuthors('42');
    expect(result.errorCode, ResErrorCode.parse);
    expect(requests, hasLength(2));
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    expect(
        requests
            .every((request) => request.uri.path == '/ajax/user/42/recommends'),
        isTrue);
  });

  test(
      'transport and auth failures preserve classifications without extra reads',
      () async {
    replies.addAll(const [
      _Reply('{"error":true}', status: 403),
      _Reply('', fail: true),
    ]);
    final denied = await network.getRecommendedAuthors('42');
    expect(denied.errorCode, ResErrorCode.loginRequired);
    expect(denied.statusCode, 403);
    final failed = await network.getRecommendedAuthors('42');
    expect(failed.errorCode, ResErrorCode.network);
    expect(failed.errorMessage, 'offline recommendation failure');
    expect(requests, hasLength(2));
  });

  for (final change in ['guest-login', 'switch-account', 'logout']) {
    test('rejects stale recommendation data after $change', () async {
      if (change != 'guest-login') {
        await network.setSessionCookie('offline-old-account');
      }
      final started = Completer<void>();
      final release = Completer<void>();
      onRequest = () async {
        started.complete();
        await release.future;
      };
      replies.add(_ok(_body()));
      final pending = network.getRecommendedAuthors('42');
      await started.future;
      if (change == 'logout') {
        await network.logout();
      } else {
        await network.setSessionCookie('offline-new-account');
      }
      release.complete();
      final result = await pending;
      expect(result.errorCode, ResErrorCode.loginRequired);
      expect(result.errorMessage, contains('账号已变化'));
      expect(requests, hasLength(1));
    });
  }
}
