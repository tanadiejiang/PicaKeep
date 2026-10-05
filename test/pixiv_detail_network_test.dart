import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/comic_source/built_in/pixiv.dart';
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

class _Request {
  const _Request(this.options, this.body);
  final RequestOptions options;
  final String body;
}

class _OfflineAdapter implements HttpClientAdapter {
  _OfflineAdapter(this.replies, this.requests, this.onRequest);
  final List<_Reply> replies;
  final List<_Request> requests;
  final Future<void> Function(RequestOptions)? onRequest;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    requests.add(_Request(options, utf8.decode(bytes)));
    await onRequest?.call(options);
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
  final requests = <_Request>[];
  Future<void> Function(RequestOptions)? onRequest;

  setUp(() async {
    oldSources = List.of(ComicSource.sources);
    ComicSource.sources
      ..clear()
      ..add(ComicSource.named(key: 'pixiv', name: 'Pixiv')
        ..data['userId'] = '99');
    wasRecording = LogManager.recordingEnabled;
    LogManager.recordingEnabled = false;
    workspace = await Directory.systemTemp.createTemp('pixiv_detail_013_');
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

  Future<void> loginOffline() => network.saveCookies({
        'PHPSESSID': 'offline-session',
        'XSRF-TOKEN': 'offline%2Bcsrf',
      });

  test(
      'anonymous roots GET preserves raw pagination count and fixed parameters',
      () async {
    replies
        .add(const _Reply('{"error":false,"body":{"comments":[null,{"id":"10"},'
            '{"id":"10"},{"id":"bad"}],"hasNext":true}}'));
    final page = await network.getComments(' 42 ', offset: 20);
    expect(page.success, isTrue);
    expect(page.data.originalCount, 4);
    expect(page.data.comments, hasLength(1));
    expect(page.data.hasNext, isTrue);
    final request = requests.single;
    expect(request.options.method, 'GET');
    expect(request.options.uri.path, '/ajax/illusts/comments/roots');
    expect(request.options.uri.queryParameters, {
      'illust_id': '42',
      'offset': '20',
      'limit': '20',
      'lang': 'zh',
    });
    expect(request.options.headers['Cookie'], isNull);
    expect(request.options.headers['Referer'], 'https://www.pixiv.net/');
    expect(request.options.headers['User-Agent'], PixivNetwork.pixivWebUA);
    expect(request.body, isEmpty);
  });

  test('replies GET starts at page 1 and tolerates real nullable fields',
      () async {
    replies.add(_Reply(File(
            'docs/verification/pixiv-detail-013/comments-replies-235308916.json')
        .readAsStringSync()));
    final page = await network.getCommentReplies('235308916');
    expect(page.success, isTrue);
    expect(page.data.comments.single.replyToUserName, isNull);
    expect(page.data.comments.single.hasReplies, isNull);
    expect(requests.single.options.method, 'GET');
    expect(requests.single.options.uri.path, '/ajax/illusts/comments/replies');
    expect(requests.single.options.uri.queryParameters, {
      'comment_id': '235308916',
      'page': '1',
      'lang': 'zh',
    });
  });

  test('invalid IDs, offsets, page and limit cause no request', () async {
    for (final id in ['', '0', '-1', '1&extra=1', '1.5', 'not-an-id']) {
      expect((await network.getComments(id)).errorCode,
          ResErrorCode.invalidArgument);
      expect((await network.getCommentReplies(id)).errorCode,
          ResErrorCode.invalidArgument);
    }
    expect((await network.getComments('42', offset: -1)).errorCode,
        ResErrorCode.invalidArgument);
    for (final limit in [0, 21, 1000]) {
      expect((await network.getComments('42', limit: limit)).errorCode,
          ResErrorCode.invalidArgument);
    }
    expect((await network.getCommentReplies('10', page: 0)).errorCode,
        ResErrorCode.invalidArgument);
    expect(requests, isEmpty);
  });

  test('malformed body, business denial and network failure remain distinct',
      () async {
    replies.addAll(const [
      _Reply('{"error":false,"body":{"hasNext":false}}'),
      _Reply('{"error":true,"message":"not available"}'),
      _Reply('', fail: true),
    ]);
    expect((await network.getComments('42')).errorCode, ResErrorCode.parse);
    final denied = await network.getCommentReplies('10');
    expect(denied.error, isTrue);
    expect(denied.errorMessage, 'not available');
    expect((await network.getComments('42')).errorCode, ResErrorCode.network);
    expect(
        requests.every((request) => request.options.method == 'GET'), isTrue);
  });

  test('account changed during comment read cannot return stale account data',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    onRequest = (_) async {
      started.complete();
      await release.future;
    };
    replies.add(
        const _Reply('{"error":false,"body":{"comments":[],"hasNext":false}}'));
    final pending = network.getComments('42');
    await started.future;
    await network.setSessionCookie('another-offline-account');
    release.complete();
    expect((await pending).errorCode, ResErrorCode.loginRequired);
    expect(requests, hasLength(1));
  });

  test(
      'comment permission failure retains HTTP status and offers login handling',
      () async {
    replies.add(const _Reply('{"error":true}', status: 403));
    final result = await network.getComments('42');
    expect(result.errorCode, ResErrorCode.loginRequired);
    expect(result.statusCode, 403);
    expect(requests, hasLength(1));
  });

  for (final visibility in PixivBookmarkVisibility.values) {
    test(
        '${visibility.name} add writes only requested visibility with integer ID',
        () async {
      await loginOffline();
      replies.add(
          const _Reply('{"error":false,"body":{"last_bookmark_id":"300"}}'));
      final result = await network.setBookmark('42',
          isAdding: true, visibility: visibility);
      expect(result.success, isTrue);
      final request = requests.single;
      expect(request.options.method, 'POST');
      expect(request.options.uri.path, '/ajax/illusts/bookmarks/add');
      expect(jsonDecode(request.body), {
        'comment': '',
        'illust_id': 42,
        'restrict': visibility.restrict,
        'tags': [],
      });
      expect(request.options.headers['X-CSRF-Token'], 'offline+csrf');
      expect(request.options.headers['Referer'],
          'https://www.pixiv.net/artworks/42');
      expect(request.options.extra['noRetry'], isTrue);
    });
  }

  for (final privacy in ['true', 'false', 'null']) {
    test(
        'cancel privacy=$privacy refreshes current ID without converting visibility',
        () async {
      await loginOffline();
      replies.addAll([
        _Reply('{"error":false,"body":{"bookmarkData":'
            '{"id":"301","private":$privacy}}}'),
        const _Reply('{"error":false}'),
      ]);
      final result = await network.setBookmark('42',
          isAdding: false, visibility: PixivBookmarkVisibility.private);
      expect(result.success, isTrue);
      expect(requests, hasLength(2));
      expect(requests.first.options.method, 'GET');
      expect(requests.first.options.uri.path, '/ajax/illust/42');
      expect(requests.last.options.method, 'POST');
      expect(requests.last.options.uri.path, '/ajax/illusts/bookmarks/delete');
      expect(Uri.splitQueryString(requests.last.body), {'bookmark_id': '301'});
    });
  }

  test('private add requires login and never emits a write on missing session',
      () async {
    final result = await network.setBookmark('42',
        isAdding: true, visibility: PixivBookmarkVisibility.private);
    expect(result.errorCode, ResErrorCode.loginRequired);
    expect(requests, isEmpty);
  });

  test(
      'private write failure never pretends success or retries transport errors',
      () async {
    await loginOffline();
    replies.addAll(const [
      _Reply('{"error":true,"message":"denied"}'),
      _Reply('', fail: true),
    ]);
    expect(
        (await network.setBookmark('42',
                isAdding: true, visibility: PixivBookmarkVisibility.private))
            .error,
        isTrue);
    expect(
        (await network.setBookmark('42',
                isAdding: true, visibility: PixivBookmarkVisibility.private))
            .errorCode,
        ResErrorCode.network);
    expect(requests, hasLength(2));
  });

  group('only Pixiv favorite adapter converts record totals', () {
    test(
        'source favorite wiring converts total, while raw network keeps records',
        () async {
      replies
          .add(const _Reply('{"error":false,"body":{"works":[],"total":97}}'));
      final raw = await network.getBookmarks(2);
      expect(raw.subData, 97);
      final adapted = pixivBookmarkResultForSource(raw);
      expect(adapted.subData, 3);
      expect((adapted as PixivBookmarkSourceResult).totalCount, 97);
      expect(requests.single.options.uri.queryParameters['offset'], '48');
      expect(requests.single.options.uri.queryParameters['rest'], 'show');
    });

    for (final pair in [(49, 2), (96, 2), (97, 3), (0, 0)]) {
      test('${pair.$1} records becomes ${pair.$2} pages and retains true total',
          () {
        final raw = Res<List<PixivComicBrief>>(const [], subData: pair.$1);
        final adapted = pixivBookmarkResultForSource(raw);
        expect(adapted.subData, pair.$2);
        expect((adapted as PixivBookmarkSourceResult).totalCount, pair.$1);
        expect(raw.subData, pair.$1);
      });
    }
    test('unknown and invalid totals stay unknown; error identity is preserved',
        () {
      for (final total in [null, -1, '97']) {
        final adapted = pixivBookmarkResultForSource(
            Res<List<PixivComicBrief>>(const [], subData: total));
        expect(adapted.subData, isNull);
        expect((adapted as PixivBookmarkSourceResult).totalCount, isNull);
      }
      final failure = pixivBookmarkResultForSource(const Res.error('login',
          errorCode: ResErrorCode.loginRequired, statusCode: 403));
      expect(failure.errorCode, ResErrorCode.loginRequired);
      expect(failure.statusCode, 403);
    });
  });
}
