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
          message: 'offline failure');
    }
    return ResponseBody.fromString(reply.body, reply.status, headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    });
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _work(String id, {String author = '42'}) => {
      'id': id,
      'title': 'Work $id',
      'userId': author,
      'userName': 'Artist',
      'url': 'https://i.pximg.net/$id.jpg',
      'xRestrict': 0,
      'isMasked': false,
      'isBookmarkable': true,
    };

_Reply _ok(Object body) =>
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
    workspace =
        await Directory.systemTemp.createTemp('pixiv_recommendations_039_');
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
    await workspace.delete(recursive: true);
    ComicSource.sources
      ..clear()
      ..addAll(oldSources);
    LogManager.recordingEnabled = wasRecording;
  });

  test('anonymous init is one read with per-work URL and strict continuation',
      () async {
    replies.add(_ok({
      'illusts': [_work('9', author: '50'), _work('42')],
      'nextIds': ['9', '42', '20', '3', '20'],
    }));
    final result = await network.getWorkRecommendations(' 42 ');
    expect(result.success, isTrue);
    expect(result.data.items.single.authorId, '50');
    expect(result.data.nextIds, ['20', '3']);
    final request = requests.single;
    expect(request.method, 'GET');
    expect(request.uri.path, '/ajax/illust/42/recommend/init');
    expect(request.uri.queryParameters, {'limit': '18', 'lang': 'zh'});
    expect(request.headers['Cookie'], isNull);
    expect(request.headers['User-Agent'], PixivNetwork.pixivWebUA);
    expect(request.headers['Referer'], 'https://www.pixiv.net/');
    expect(request.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('x-csrf-token')));
    expect(request.data, isNull);
  });

  test('null limit preserves every returned item with client preload 18',
      () async {
    final ids = List.generate(23, (index) => '${index + 100}');
    replies.add(_ok({
      'illusts': ids.map(_work).toList(),
      'nextIds': [...ids, '9', '7'],
    }));
    final result = await network.getWorkRecommendations('42', limit: null);
    expect(result.success, isTrue);
    expect(result.data.items.map((work) => work.id), ids);
    expect(result.data.nextIds, ['9', '7']);
    expect(requests.single.uri.queryParameters, {'limit': '18', 'lang': 'zh'});
    expect(requests.single.method, 'GET');
  });

  test('explicit limits 1, 5 and 18 keep their exact GET parameter', () async {
    for (final limit in [1, 5, 18]) {
      replies.add(_ok({
        'illusts': [_work('9'), _work('7')],
        'nextIds': ['100'],
      }));
      final result = await network.getWorkRecommendations('42', limit: limit);
      expect(result.success, isTrue);
      expect(result.data.items.map((work) => work.id), ['9', '7']);
      expect(
          requests.last.uri.queryParameters, {'limit': '$limit', 'lang': 'zh'});
    }
    expect(requests, hasLength(3));
    expect(requests.every((request) => request.method == 'GET'), isTrue);
  });

  test('explicit same-seed init calls re-read and preserve duplicate replies',
      () async {
    for (var round = 0; round < 2; round++) {
      replies.add(_ok({
        'illusts': [_work('9')],
        'nextIds': [],
      }));
    }
    final first = await network.getWorkRecommendations('42');
    expect(requests, hasLength(1));
    final second = await network.getWorkRecommendations('42');
    expect(first.data.items.single.id, '9');
    expect(second.data.items.single.id, '9');
    expect(requests, hasLength(2));
    expect(requests[0].uri, requests[1].uri);
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    expect(requests.last.uri.queryParameters, {'limit': '18', 'lang': 'zh'});
  });

  test('next batch sends repeated IDs once and retains queue ranking',
      () async {
    replies.add(_ok({
      'illusts': [_work('100'), _work('9'), _work('7')]
    }));
    final result = await network.getRecommendationWorks([' 9 ', '100', '9']);
    expect(result.data.map((work) => work.id), ['9', '100']);
    final request = requests.single;
    expect(request.uri.path, '/ajax/illust/recommend/illusts');
    expect(request.uri.queryParametersAll['illust_ids[]'], ['9', '100']);
    expect(request.uri.queryParameters['lang'], 'zh');
    expect(request.method, 'GET');
  });

  test('new reads use the isolated cookie jar without CSRF or a write',
      () async {
    await network
        .saveCookies({'PHPSESSID': 'offline-session', 'extra': 'offline'});
    replies.add(_ok({'illusts': [], 'nextIds': []}));
    expect((await network.getWorkRecommendations('42')).success, isTrue);
    final request = requests.single;
    expect(request.headers['Cookie'], contains('PHPSESSID=offline-session'));
    expect(request.headers['Cookie'], contains('extra=offline'));
    expect(request.method, 'GET');
    expect(request.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('x-csrf-token')));
  });

  test('invalid IDs and out-of-range batches never issue a request', () async {
    for (final id in ['', '0', '-1', '1.5', '1&extra=1', 'bad']) {
      expect((await network.getWorkRecommendations(id)).errorCode,
          ResErrorCode.invalidArgument);
      expect((await network.getRecommendationWorks([id])).errorCode,
          ResErrorCode.invalidArgument);
      expect((await network.getAuthorWorkIds(id)).errorCode,
          ResErrorCode.invalidArgument);
      expect((await network.getAuthorPreviewWorks(id, ['9'])).errorCode,
          ResErrorCode.invalidArgument);
      expect((await network.getAuthorPreviewWorks('42', [id])).errorCode,
          ResErrorCode.invalidArgument);
    }
    for (final limit in [0, -1, 19]) {
      expect(
          (await network.getWorkRecommendations('42', limit: limit)).errorCode,
          ResErrorCode.invalidArgument);
    }
    expect(
        (await network.getRecommendationWorks(
                List.generate(19, (index) => '${index + 1}')))
            .errorCode,
        ResErrorCode.invalidArgument);
    expect(
        (await network.getAuthorPreviewWorks(
                '42', List.generate(6, (index) => '${index + 1}')))
            .errorCode,
        ResErrorCode.invalidArgument);
    expect(requests, isEmpty);
  });

  test('empty batch returns a real empty success without a GET', () async {
    expect((await network.getRecommendationWorks([])).data, isEmpty);
    expect((await network.getAuthorPreviewWorks('42', [])).data, isEmpty);
    expect(requests, isEmpty);
  });

  test(
      'init missing continuation or wrong body is an error, not an empty success',
      () async {
    for (final body in [
      [],
      {},
      {'illusts': []},
      {'illusts': [], 'nextIds': {}},
      {'illusts': {}, 'nextIds': []},
    ]) {
      replies.add(_ok(body));
      expect((await network.getWorkRecommendations('42')).errorCode,
          ResErrorCode.parse);
    }
    expect(requests, hasLength(5));
  });

  test('new read envelope requires error=false and preserves business errors',
      () async {
    replies.addAll([
      const _Reply('{"body":{"illusts":[],"nextIds":[]}}'),
      const _Reply('{"error":"denied"}'),
      const _Reply('{"error":true,"message":"Unavailable"}'),
    ]);
    expect((await network.getWorkRecommendations('42')).errorCode,
        ResErrorCode.parse);
    expect(
        (await network.getRecommendationWorks(['9'])).errorMessage, 'denied');
    expect((await network.getWorkRecommendations('42')).errorMessage,
        'Unavailable');
  });

  test('next body must contain an array; a valid all-filtered batch succeeds',
      () async {
    for (final body in [
      [],
      {},
      {'illusts': {}}
    ]) {
      replies.add(_ok(body));
      expect((await network.getRecommendationWorks(['9'])).errorCode,
          ResErrorCode.parse);
    }
    replies.add(_ok({
      'illusts': [
        {..._work('9'), 'isMasked': true}
      ]
    }));
    final filtered = await network.getRecommendationWorks(['9']);
    expect(filtered.success, isTrue);
    expect(filtered.data, isEmpty);
  });

  test(
      'author ID wrapper combines manga and illust and filters nonpositive IDs',
      () async {
    replies.add(_ok({
      'illusts': {'9': null, '0': null, '-1': null, 'abc': null},
      'manga': [
        '100',
        '9',
        {'id': '3'}
      ],
      'novels': {'500': null},
    }));
    final result = await network.getAuthorWorkIds(' 42 ');
    expect(result.data, ['100', '9', '3']);
    expect(requests.single.uri.path, '/ajax/user/42/profile/all');
    expect(requests.single.uri.queryParameters['lang'], 'zh');
  });

  test('author preview is one bounded profile batch with author and ID checks',
      () async {
    replies.add(_ok({
      'works': {
        '100': _work('100'),
        '9': _work('9'),
        '7': _work('7', author: '43'),
        'outside': _work('20'),
      },
    }));
    final result =
        await network.getAuthorPreviewWorks('42', ['9', '100', '7', '9']);
    expect(result.data.map((work) => work.id), ['9', '100']);
    final request = requests.single;
    expect(request.uri.path, '/ajax/user/42/profile/illusts');
    expect(request.uri.queryParametersAll['ids[]'], ['9', '100', '7']);
    expect(request.uri.queryParameters['work_category'], 'illustManga');
    expect(request.uri.queryParameters['is_first_page'], '0');
    expect(request.uri.queryParameters['lang'], 'zh');
  });

  test(
      'preview empty is valid but legacy author page still reports all-empty error',
      () async {
    replies.add(_ok({'works': []}));
    final preview = await network.getAuthorPreviewWorks('42', ['9']);
    expect(preview.success, isTrue);
    expect(preview.data, isEmpty);
    replies.addAll([
      _ok({
        'illusts': {'9': null},
        'manga': []
      }),
      _ok({'works': []}),
    ]);
    final legacy = await network.getAuthorWorks('42');
    expect(legacy.errorCode, ResErrorCode.parse);
    expect(legacy.errorMessage, contains('一条都没解析出来'));
    expect(requests, hasLength(3));
  });

  test(
      'author preview distinguishes wrong works shape from unavailable candidates',
      () async {
    for (final body in [
      {},
      {'works': null},
      {'works': 'wrong'}
    ]) {
      replies.add(_ok(body));
      expect((await network.getAuthorPreviewWorks('42', ['9'])).errorCode,
          ResErrorCode.parse);
    }
    replies.add(_ok({
      'works': [
        {..._work('9'), 'xRestrict': 1}
      ]
    }));
    expect((await network.getAuthorPreviewWorks('42', ['9'])).data, isEmpty);
  });

  test(
      'transport and permission failure remain classified without extra writes',
      () async {
    replies.addAll(const [
      _Reply('{"error":true}', status: 403),
      _Reply('', fail: true),
    ]);
    final denied = await network.getWorkRecommendations('42');
    expect(denied.errorCode, ResErrorCode.loginRequired);
    expect(denied.statusCode, 403);
    expect((await network.getRecommendationWorks(['9'])).errorCode,
        ResErrorCode.network);
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    expect(requests, hasLength(2));
  });

  for (final name in ['init', 'next', 'authorIds', 'authorPreview']) {
    test('$name rejects a guest-to-account change while its read is pending',
        () async {
      final started = Completer<void>();
      final release = Completer<void>();
      onRequest = () async {
        started.complete();
        await release.future;
      };
      replies.add(_ok(switch (name) {
        'init' => {'illusts': [], 'nextIds': []},
        'next' => {'illusts': []},
        'authorIds' => {'illusts': {}, 'manga': []},
        _ => {'works': []},
      }));
      final Future<Res<dynamic>> pending = switch (name) {
        'init' => network.getWorkRecommendations('42'),
        'next' => network.getRecommendationWorks(['9']),
        'authorIds' => network.getAuthorWorkIds('42'),
        _ => network.getAuthorPreviewWorks('42', ['9']),
      };
      await started.future;
      await network.setSessionCookie('another-offline-account');
      release.complete();
      expect((await pending).errorCode, ResErrorCode.loginRequired);
      expect(requests, hasLength(1));
    });
  }
}
