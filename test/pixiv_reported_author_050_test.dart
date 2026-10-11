import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';
import 'package:picakeep/network/res.dart';
import 'package:sqlite3/open.dart';

// Synthetic response variants tied to the reported request ID, not an archive
// of this artwork's real Pixiv response. There is no network or real account.
const _reportedWork = '150343763';
const _profileId = '1960050';

class _Reply {
  const _Reply(this.body, {this.status = 200, this.transportFailure = false});
  final String body;
  final int status;
  final bool transportFailure;
}

class _OfflineAdapter implements HttpClientAdapter {
  _OfflineAdapter(this.replies, this.requests, this.onRequest);
  final List<_Reply> replies;
  final List<RequestOptions> requests;
  final Future<void> Function(RequestOptions)? onRequest;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    await onRequest?.call(options);
    if (replies.isEmpty) throw StateError('Unexpected offline request');
    final reply = replies.removeAt(0);
    if (reply.transportFailure) {
      throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          message: 'offline transport');
    }
    return ResponseBody.fromString(reply.body, reply.status, headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    });
  }

  @override
  void close({bool force = false}) {}
}

String _envelope(Object body) => jsonEncode({'error': false, 'body': body});
String _comments(int count) => _envelope({
      'comments': List.generate(
          count,
          (index) => {
                'id': '${1000 + index}',
                'userId': '7',
                'userName': 'offline',
                'comment': 'comment $index',
              }),
      'hasNext': count > 0,
    });

Map<String, Object?> _detail({String id = _reportedWork}) => {
      'illustId': id,
      'illustTitle': '',
      'userId': 1960050,
      'userName': '',
      'urls': {'regular': 'https://fixture.invalid/high.jpg'},
      'pageCount': 1,
      'createDate': '2026-10-01T16:43:00+09:00',
      'viewCount': 1735,
      'likeCount': 84,
      'bookmarkData': null,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
      OperatingSystem.windows,
      () =>
          DynamicLibrary.open('${Directory.current.path}/windows/sqlite3.dll'));

  late Directory workspace;
  late CookieJarSql jar;
  late PixivNetwork network;
  late List<ComicSource> oldSources;
  late bool wasRecording;
  final replies = <_Reply>[];
  final requests = <RequestOptions>[];
  Future<void> Function(RequestOptions)? onRequest;

  setUp(() async {
    oldSources = List.of(ComicSource.sources);
    ComicSource.sources
      ..clear()
      ..add(ComicSource.named(key: 'pixiv', name: 'Offline Pixiv'));
    wasRecording = LogManager.recordingEnabled;
    LogManager.recordingEnabled = false;
    workspace = await Directory.systemTemp.createTemp('pixiv_reported_050_');
    jar = CookieJarSql('${workspace.path}/cookies.db');
    replies.clear();
    requests.clear();
    onRequest = null;
    network = PixivNetwork.forTesting(
        cookieJar: jar,
        bookmarkStore: PixivBookmarkStateStore(),
        dioFactory: () => Dio()
          ..httpClientAdapter = _OfflineAdapter(replies, requests, onRequest));
  });

  tearDown(() async {
    jar.dispose();
    // This Directory is the unique temporary fixture captured in setUp.
    expect(workspace.path, contains('pixiv_reported_050_'));
    await workspace.delete(recursive: true);
    ComicSource.sources
      ..clear()
      ..addAll(oldSources);
    LogManager.recordingEnabled = wasRecording;
  });

  test('numeric profile UID is not dropped while display fields remain honest',
      () {
    final profile = parsePixivAuthorInfo({
      'userId': 1960050,
      'name': 'Offline artist',
      'imageBig': 'https://fixture.invalid/avatar.jpg',
    });
    expect(profile.id, _profileId);
    expect(profile.name, 'Offline artist');
    expect(profile.avatar, 'https://fixture.invalid/avatar.jpg');
    expect(parsePixivAuthorInfo({'id': 1960050}).id, _profileId);
    expect(parsePixivAuthorInfo({'userId': 1960050}).name, isEmpty);
  });

  test('profile GET normalizes UID and retains missing redundant requested ID',
      () async {
    replies.addAll([
      _Reply(_envelope({'userId': 1960050, 'name': 'Offline artist'})),
      _Reply(_envelope({'name': 'No redundant ID', 'image': null})),
    ]);
    expect((await network.getAuthorInfo(' 1960050 ')).data.id, _profileId);
    final partial = await network.getAuthorInfo(_profileId);
    expect(partial.success, isTrue);
    expect(partial.data.id, _profileId);
    expect(partial.data.name, 'No redundant ID');
    expect(partial.data.avatar, isEmpty);
    expect(requests.every((r) => r.uri.path == '/ajax/user/1960050'), isTrue);
    expect(requests.first.uri.queryParameters, {'full': '1', 'lang': 'zh'});
    expect(requests.first.headers['Cookie'], isNull);
  });

  test('explicit different profile and unusable profile are parse errors',
      () async {
    replies.addAll([
      _Reply(_envelope({'userId': '7', 'name': 'Wrong artist'})),
      _Reply(_envelope({'following': 10})),
    ]);
    final mismatch = await network.getAuthorInfo(_profileId);
    expect(mismatch.errorCode, ResErrorCode.parse);
    expect(mismatch.errorMessage, contains('UID 与请求不一致'));
    expect((await network.getAuthorInfo(_profileId)).errorCode,
        ResErrorCode.parse);
  });

  test(
      'same work preserves blank server display fields without borrowing another work',
      () async {
    replies.add(_Reply(_envelope({
      ..._detail(),
      'userIllusts': {
        '7': {
          'id': '7',
          'title': 'Unrelated title',
          'userName': 'Unrelated artist'
        },
      }
    })));
    final detail = await network.getComicInfo(' $_reportedWork ');
    expect(detail.success, isTrue);
    expect(detail.data.id, _reportedWork);
    expect(detail.data.authorId, _profileId);
    expect(detail.data.title, isEmpty);
    expect(detail.data.author, isEmpty);
    expect(detail.data.viewCount, 1735);
    expect(detail.data.likeCount, 84);
    expect(requests.single.uri.path, '/ajax/illust/$_reportedWork');
  });

  test('different work JSON cannot return as requested detail', () async {
    replies.add(_Reply(_envelope(_detail(id: '42'))));
    final detail = await network.getComicInfo(_reportedWork);
    expect(detail.errorCode, ResErrorCode.parse);
    expect(detail.errorMessage, contains('ID 与请求不一致'));
    expect(requests, hasLength(1));
  });

  for (final author in [false, true]) {
    test(
        '${author ? 'author' : 'detail'} read rejects a late changed-account result',
        () async {
      final started = Completer<void>();
      final release = Completer<void>();
      onRequest = (_) async {
        started.complete();
        await release.future;
      };
      replies.add(_Reply(
          _envelope(author ? {'userId': _profileId, 'name': 'A'} : _detail())));
      final pending = author
          ? network.getAuthorInfo(_profileId)
          : network.getComicInfo(_reportedWork);
      await started.future;
      await network.setSessionCookie('another-offline-account');
      release.complete();
      expect((await pending).errorCode, ResErrorCode.loginRequired);
      expect(requests, hasLength(1));
    });
  }

  test('invalid work or author IDs never issue an offline request', () async {
    for (final id in ['', '0', '-7', '3&extra=1', '1.5']) {
      expect((await network.getComicInfo(id)).errorCode,
          ResErrorCode.invalidArgument);
      expect((await network.getAuthorInfo(id)).errorCode,
          ResErrorCode.invalidArgument);
    }
    expect(requests, isEmpty);
  });

  for (final limit in [3, 4]) {
    test('successful small preview limit $limit is unchanged and not retried',
        () async {
      replies.add(_Reply(_comments(limit)));
      final result =
          await network.getComments(_reportedWork, offset: 12, limit: limit);
      expect(result.success, isTrue);
      expect(result.data.originalCount, limit);
      expect(requests, hasLength(1));
      expect(requests.single.uri.queryParameters, {
        'illust_id': _reportedWork,
        'offset': '12',
        'limit': '$limit',
        'lang': 'zh',
      });
    });
  }

  for (final status in [200, 400]) {
    test(
        'invalid-request business status $status retries standard page once at same offset',
        () async {
      replies.addAll([
        _Reply('{"error":true,"message":"不正确的请求。"}', status: status),
        _Reply(_comments(20)),
      ]);
      final result =
          await network.getComments(_reportedWork, offset: 12, limit: 4);
      expect(result.success, isTrue);
      expect(result.data.originalCount, 20);
      expect(requests, hasLength(2));
      expect(requests.map((r) => r.uri.queryParameters['limit']), ['4', '20']);
      expect(
          requests.every((r) =>
              r.uri.queryParameters['illust_id'] == _reportedWork &&
              r.uri.queryParameters['offset'] == '12'),
          isTrue);
      expect(
          requests
              .every((r) => r.method == 'GET' && r.headers['Cookie'] == null),
          isTrue);
    });
  }

  test('second failure remains visible and standard-page refusal never loops',
      () async {
    replies.addAll(const [
      _Reply('{"error":true,"message":"不正确的请求。"}', status: 400),
      _Reply('{"error":true,"message":"second business failure"}', status: 400),
      _Reply('{"error":true,"message":"不正确的请求。"}', status: 400),
    ]);
    final second = await network.getComments(_reportedWork, limit: 4);
    expect(second.errorMessage, 'second business failure');
    expect(second.statusCode, 400);
    expect(requests, hasLength(2));
    expect((await network.getComments(_reportedWork)).errorMessage, '不正确的请求。');
    expect(requests, hasLength(3));
  });

  for (final status in [401, 403, 404, 429]) {
    test('HTTP $status is not a preview-compatibility retry', () async {
      replies.add(_Reply('{"error":true,"message":"不正确的请求。"}', status: status));
      expect(
          (await network.getComments(_reportedWork, limit: 4)).error, isTrue);
      expect(requests, hasLength(1));
    });
  }

  test('generic HTTP400 business refusal is not a page-size fallback',
      () async {
    replies.addAll(const [
      _Reply('{"error":true,"message":"not available","body":[]}', status: 400),
      _Reply('{"error":false,"body":{"comments":[],"hasNext":false}}'),
    ]);
    final result = await network.getComments(_reportedWork, limit: 4);
    expect(result.error, isTrue);
    expect(result.errorMessage, 'not available');
    expect(result.statusCode, 400);
    expect(requests, hasLength(1));
    expect(replies, hasLength(1));
  });

  for (final status in [200, 400]) {
    test('two invalid-request refusals at HTTP$status retain the second error',
        () async {
      replies.addAll([
        _Reply('{"error":true,"message":"不正确的请求。","body":[]}', status: status),
        _Reply('{"error":true,"message":"不正确的请求。","body":[]}', status: status),
      ]);
      final result = await network.getComments(_reportedWork, limit: 4);
      expect(result.error, isTrue);
      expect(result.errorMessage, '不正确的请求。');
      expect(result.statusCode, status);
      expect(requests.map((r) => r.uri.queryParameters['limit']), ['4', '20']);
    });
  }

  test(
      'generic business denial, malformed body and transport do not retry a larger page',
      () async {
    replies.addAll(const [
      _Reply('{"error":true,"message":"not available"}'),
      _Reply('{"error":false,"body":{"hasNext":false}}'),
      _Reply('', transportFailure: true),
    ]);
    expect((await network.getComments(_reportedWork, limit: 4)).errorMessage,
        'not available');
    expect((await network.getComments(_reportedWork, limit: 4)).errorCode,
        ResErrorCode.parse);
    expect((await network.getComments(_reportedWork, limit: 4)).errorCode,
        ResErrorCode.network);
    expect(requests, hasLength(3));
  });

  test(
      'malformed JSON HTTP 400 has only existing same-URL parse retry, no limit20 fallback',
      () async {
    replies.addAll(const [
      _Reply('invalid json', status: 400),
      _Reply('invalid json', status: 400)
    ]);
    expect((await network.getComments(_reportedWork, limit: 4)).errorCode,
        ResErrorCode.parse);
    expect(requests.map((r) => r.uri.queryParameters['limit']), ['4', '4']);
  });

  test(
      'account change while first invalid preview is pending suppresses fallback',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    onRequest = (_) async {
      started.complete();
      await release.future;
    };
    replies
        .add(const _Reply('{"error":true,"message":"不正确的请求。"}', status: 400));
    final pending = network.getComments(_reportedWork, limit: 4);
    await started.future;
    await network.setSessionCookie('another-offline-account');
    release.complete();
    expect((await pending).errorCode, ResErrorCode.loginRequired);
    expect(requests, hasLength(1));
  });
}
