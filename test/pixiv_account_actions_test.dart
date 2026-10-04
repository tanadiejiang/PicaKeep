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

class _Reply {
  const _Reply(this.body, {this.status = 200, this.failure = false});
  final String body;
  final int status;
  final bool failure;
}

class _Request {
  _Request(this.options, this.body);
  final RequestOptions options;
  final String body;
}

class _OfflineAdapter implements HttpClientAdapter {
  _OfflineAdapter(this.replies, this.requests, {this.onRequest});
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
    if (reply.failure) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'offline connection failed',
      );
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
      '${Platform.pathSeparator}sqlite3.dll',
    ),
  );
  late Directory workspace;
  late CookieJarSql jar;
  late PixivNetwork network;
  late List<ComicSource> sources;
  late bool wasRecording;
  final replies = <_Reply>[];
  final requests = <_Request>[];
  Future<void> Function(RequestOptions)? onRequest;

  setUp(() async {
    sources = List.of(ComicSource.sources);
    ComicSource.sources
      ..clear()
      ..add(ComicSource.named(key: 'pixiv', name: 'Pixiv')
        ..data['userId'] = '99');
    wasRecording = LogManager.recordingEnabled;
    LogManager.recordingEnabled = false;
    workspace = await Directory.systemTemp.createTemp('pixiv_actions_006_');
    jar = CookieJarSql('${workspace.path}/cookies.db');
    jar.saveFromResponse(Uri.parse(PixivNetwork.pixivWebBase), [
      Cookie('PHPSESSID', 'offline-session')
        ..domain = '.pixiv.net'
        ..path = '/',
      Cookie('XSRF-TOKEN', 'offline%2Bcsrf')
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

  void expectWriteHeaders(_Request request, String referer) {
    expect(request.options.headers['Referer'], referer);
    expect(request.options.headers['Origin'], PixivNetwork.pixivWebBase);
    expect(request.options.headers['Cookie'],
        contains('PHPSESSID=offline-session'));
    expect(request.options.headers['X-CSRF-Token'], 'offline+csrf');
    expect(request.options.extra['noRetry'], isTrue);
  }

  for (final bookmarkData in ['{"id":"900"}', 'null']) {
    test('取消收藏读取期间换账号不发写请求（bookmarkData=$bookmarkData）', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      onRequest = (options) async {
        expect(options.method, 'GET');
        started.complete();
        await release.future;
      };
      replies
          .add(_Reply('{"error":false,"body":{"bookmarkData":$bookmarkData}}'));
      final pending = network.setBookmark('41', isAdding: false);
      await started.future;
      await network.setSessionCookie('different-offline-session');
      release.complete();
      final result = await pending;
      expect(result.errorCode, ResErrorCode.loginRequired);
      expect(requests, hasLength(1));
      expect(requests.single.options.method, 'GET');
    });
  }

  group('模型从已有响应读取账号状态', () {
    test('游客/缺字段未收藏，非空对象保留书签 ID，数值 ID 兼容', () {
      for (final body in <Map<String, dynamic>>[
        {'illustId': '41'},
        {'illustId': '41', 'bookmarkData': null},
        {'illustId': '41', 'bookmarkData': 'unexpected'},
      ]) {
        final info = parsePixivComicInfo(body);
        expect(info.isBookmarked, isFalse);
        expect(info.bookmarkId, isNull);
      }
      for (final id in <dynamic>['900', 900]) {
        final info = parsePixivComicInfo({
          'illustId': '41',
          'userId': '42',
          'bookmarkData': {'id': id, 'private': false},
        });
        expect(info.isBookmarked, isTrue);
        expect(info.bookmarkId, '900');
        expect(info.userId, '42', reason: '这是作品作者，不是当前账号');
      }
      final noId = parsePixivComicInfo({'illustId': '41', 'bookmarkData': {}});
      expect(noId.isBookmarked, isTrue);
      expect(noId.bookmarkId, isNull);
    });

    test('关注态与作者关注人数独立，copyWith 保留展示快照', () {
      final author = parsePixivAuthorInfo({
        'userId': '42',
        'name': 'author',
        'following': 426,
        'comment': 'profile',
        'imageBig': 'avatar',
        'isFollowed': true,
      });
      expect(author.isFollowed, isTrue);
      final changed = author.copyWith(isFollowed: false);
      expect(changed.isFollowed, isFalse);
      expect(changed.following, 426);
      expect(changed.id, author.id);
      expect(changed.name, author.name);
      expect(changed.avatar, author.avatar);
      expect(changed.comment, author.comment);
      expect(parsePixivAuthorInfo({'userId': '42'}).isFollowed, isFalse);
      expect(
          parsePixivAuthorInfo({'userId': '42', 'isFollowed': 'true'})
              .isFollowed,
          isTrue);
    });
  });

  test('添加沿用 JSON 路径，真实 adapter 收到整数作品 ID 与写鉴权头', () async {
    replies
        .add(const _Reply('{"error":false,"body":{"last_bookmark_id":"900"}}'));
    final result = await network.setBookmark(' 41 ', isAdding: true);
    expect(result.success, isTrue);
    expect(requests, hasLength(1));
    final request = requests.single;
    expect(request.options.method, 'POST');
    expect(request.options.uri.path, '/ajax/illusts/bookmarks/add');
    expect(jsonDecode(request.body), {
      'comment': '',
      'illust_id': 41,
      'restrict': 0,
      'tags': [],
    });
    expect(request.options.headers['Content-Type'], 'application/json');
    expectWriteHeaders(request, 'https://www.pixiv.net/artworks/41');
  });

  test('连续添加取消取得新书签 ID，取消不是作品 ID 或旧 ID', () async {
    replies.addAll(const [
      _Reply('{"error":false,"body":{"last_bookmark_id":"900"}}'),
      _Reply('{"error":false,"body":{"bookmarkData":{"id":"900"}}}'),
      _Reply('{"error":false}'),
      _Reply('{"error":false,"body":{"last_bookmark_id":"901"}}'),
      _Reply('{"error":false,"body":{"bookmarkData":{"id":901}}}'),
      _Reply('{"error":false}'),
    ]);
    for (var i = 0; i < 2; i++) {
      expect((await network.setBookmark('41', isAdding: true)).success, isTrue);
      expect(
          (await network.setBookmark('41', isAdding: false)).success, isTrue);
    }
    expect(requests, hasLength(6));
    for (final index in [1, 4]) {
      expect(requests[index].options.method, 'GET');
      expect(requests[index].options.uri.path, '/ajax/illust/41');
      expect(requests[index].options.uri.queryParameters['lang'], 'zh');
    }
    for (final pair in [(2, '900'), (5, '901')]) {
      final request = requests[pair.$1];
      expect(request.options.uri.path, '/ajax/illusts/bookmarks/delete');
      expect(Uri.splitQueryString(request.body), {
        'bookmark_id': pair.$2,
      });
      expect(request.options.headers['Content-Type'],
          startsWith('application/x-www-form-urlencoded'));
      expectWriteHeaders(request, 'https://www.pixiv.net/artworks/41');
    }
    expect(replies, isEmpty);
  });

  test('明确无收藏直接完成；收藏状态未知或 ID 缺失不发删除', () async {
    replies.add(const _Reply('{"error":false,"body":{"bookmarkData":null}}'));
    expect((await network.setBookmark('41', isAdding: false)).success, isTrue);
    for (final body in [
      '{}',
      '{"bookmarkData":{}}',
      '{"bookmarkData":"bad"}'
    ]) {
      replies.add(_Reply('{"error":false,"body":$body}'));
      final result = await network.setBookmark('41', isAdding: false);
      expect(result.error, isTrue);
      expect(result.errorCode, ResErrorCode.parse);
    }
    expect(requests, hasLength(4));
    expect(
        requests.every((request) => request.options.method == 'GET'), isTrue);
  });

  test('关注/取关走表单，支持各自成功响应并返回目标态', () async {
    replies.addAll(const [_Reply('[]'), _Reply('{"type":"bookuser"}')]);
    final follow = await network.setFollow('42', isFollowing: true);
    final unfollow = await network.setFollow('42', isFollowing: false);
    expect(follow.data, isTrue);
    expect(unfollow.success, isTrue);
    expect(unfollow.data, isFalse);
    expect(requests[0].options.uri.path, '/bookmark_add.php');
    expect(Uri.splitQueryString(requests[0].body), {
      'mode': 'add',
      'type': 'user',
      'user_id': '42',
      'tag': '',
      'restrict': '0',
      'format': 'json',
    });
    expect(requests[1].options.uri.path, '/rpc_group_setting.php');
    expect(Uri.splitQueryString(requests[1].body), {
      'mode': 'del',
      'type': 'bookuser',
      'id': '42',
    });
    for (final request in requests) {
      expect(request.options.headers['Content-Type'],
          startsWith('application/x-www-form-urlencoded'));
      expectWriteHeaders(request, 'https://www.pixiv.net/users/42');
    }
  });

  test('游客、非法 ID、自关注在本地拒绝，不获取令牌也不发请求', () async {
    expect((await network.setFollow('99', isFollowing: true)).errorCode,
        ResErrorCode.invalidArgument);
    for (final id in ['-1', '0', '42&evil=1', 'abc']) {
      expect((await network.setFollow(id, isFollowing: true)).errorCode,
          ResErrorCode.invalidArgument);
      expect((await network.setBookmark(id, isAdding: true)).errorCode,
          ResErrorCode.invalidArgument);
    }
    await network.logout();
    expect((await network.setFollow('42', isFollowing: true)).errorCode,
        ResErrorCode.loginRequired);
    expect((await network.setBookmark('41', isAdding: false)).errorCode,
        ResErrorCode.loginRequired);
    expect(requests, isEmpty);
  });

  test('关注未知响应、错误对象、HTML、空正文和非成功 HTTP 均拒绝', () async {
    for (final reply in const [
      _Reply('{}'),
      _Reply(''),
      _Reply('<html>blocked</html>'),
      _Reply('{"error":true,"message":"denied"}'),
      _Reply('{"error":"denied"}'),
      _Reply('["unexpected"]'),
      _Reply('[]', status: 400),
      _Reply('{"error":false}', status: 429),
    ]) {
      replies.add(reply);
      final result = await network.setFollow('42', isFollowing: true);
      expect(result.error, isTrue, reason: '${reply.status}/${reply.body}');
    }
    expect(requests, hasLength(8), reason: '未知响应不自动重试写入');
  });

  test('取关错误对象或错误 HTTP 不能因含 type 而成功', () async {
    for (final reply in const [
      _Reply('{"type":"unknown"}'),
      _Reply('[]'),
      _Reply('{"type":"bookuser","error":true}'),
      _Reply('{"type":"bookuser"}', status: 400),
    ]) {
      replies.add(reply);
      expect((await network.setFollow('42', isFollowing: false)).error, isTrue);
    }
    expect(requests, hasLength(4));
  });

  test('取消响应未知/错误 HTTP 不静默成功', () async {
    for (final reply in const [
      _Reply('{}'),
      _Reply('{"error":false}', status: 400),
      _Reply('<html>blocked</html>'),
    ]) {
      replies.addAll([
        const _Reply('{"error":false,"body":{"bookmarkData":{"id":"900"}}}'),
        reply,
      ]);
      expect((await network.setBookmark('41', isAdding: false)).error, isTrue);
    }
    expect(requests, hasLength(6));
  });

  test('JSON 添加同样要求明确成功和成功 HTTP', () async {
    for (final reply in const [
      _Reply('{}'),
      _Reply('{"error":false}', status: 400),
      _Reply('<html>blocked</html>'),
    ]) {
      replies.add(reply);
      expect((await network.setBookmark('41', isAdding: true)).error, isTrue);
    }
    expect(requests, hasLength(3));
  });

  test('仅明确认证拒绝刷新令牌重试一次，第二次失败保持错误', () async {
    replies.addAll(const [
      _Reply('{"error":true,"message":"csrf rejected"}'),
      _Reply('[]'),
    ]);
    expect((await network.setFollow('42', isFollowing: true)).data, isTrue);
    expect(requests, hasLength(2));
    replies.addAll(
        const [_Reply('denied', status: 403), _Reply('denied', status: 403)]);
    final failed = await network.setFollow('42', isFollowing: false);
    expect(failed.errorCode, ResErrorCode.loginRequired);
    expect(requests, hasLength(4));
    expect(replies, isEmpty);
  });

  test('连接失败不重复写，结构化传输错误向上返回', () async {
    replies.add(const _Reply('', failure: true));
    final result = await network.setFollow('42', isFollowing: true);
    expect(result.errorCode, ResErrorCode.network);
    expect(requests, hasLength(1));
    expect(requests.single.options.extra['noRetry'], isTrue);
  });
}
