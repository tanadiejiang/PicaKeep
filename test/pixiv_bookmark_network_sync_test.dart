import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:sqlite3/open.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
  final Future<String> Function(RequestOptions) reply;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return ResponseBody.fromString(await reply(options), 200, headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    });
  }

  @override
  void close({bool force = false}) {}
}

String _detail({Object? bookmark = const {'id': '900'}, bool include = true}) =>
    jsonEncode({
      'error': false,
      'body': {
        'illustId': '42',
        'illustTitle': '作品',
        'isBookmarkable': true,
        if (include) 'bookmarkData': bookmark,
      },
    });

const _notBookmarked =
    PixivBookmarkState(isBookmarked: false, isBookmarkable: true);
const _bookmarked =
    PixivBookmarkState(isBookmarked: true, isBookmarkable: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open(
          '${Directory.current.path}${Platform.pathSeparator}windows'
          '${Platform.pathSeparator}sqlite3.dll'));

  late Directory workspace;
  late CookieJarSql jar;
  late PixivBookmarkStateStore store;
  late PixivNetwork network;
  late bool recording;
  late Future<String> Function(RequestOptions) reply;
  final requests = <RequestOptions>[];

  setUp(() async {
    recording = LogManager.recordingEnabled;
    LogManager.recordingEnabled = false;
    workspace = await Directory.systemTemp.createTemp('pixiv_bookmark_sync_');
    jar = CookieJarSql('${workspace.path}/cookies.db');
    store = PixivBookmarkStateStore();
    requests.clear();
    reply = (_) async => _detail();
    network = PixivNetwork.forTesting(
      cookieJar: jar,
      bookmarkStore: store,
      dioFactory: () => Dio()
        ..httpClientAdapter = _Adapter((options) {
          requests.add(options);
          return reply(options);
        }),
    );
    await network.saveCookies({
      'PHPSESSID': 'account-A',
      'XSRF-TOKEN': 'offline-csrf',
    });
  });

  tearDown(() async {
    store.dispose();
    jar.dispose();
    await workspace.delete(recursive: true);
    LogManager.recordingEnabled = recording;
  });

  test(
      'strict bookmark read publishes confirmed state and rejects invalid data',
      () async {
    expect((await network.getBookmarkState('42')).success, isTrue);
    expect(store.stateFor('account-A', '42')?.isBookmarked, isTrue);
    final revision = store.revisionFor('account-A', '42');
    reply = (_) async => _detail(bookmark: {'id': 'invalid'});
    expect((await network.getBookmarkState('42')).error, isTrue);
    expect(store.stateFor('account-A', '42')?.isBookmarked, isTrue);
    expect(store.revisionFor('account-A', '42'), revision);
  });

  test('detail only publishes explicit valid bookmark metadata', () async {
    store.confirm('account-A', '42', _bookmarked);
    reply = (_) async => _detail(include: false);
    expect((await network.getComicInfo('42')).success, isTrue);
    expect(store.stateFor('account-A', '42')?.isBookmarked, isTrue);
    reply = (_) async => _detail(bookmark: {'id': 'invalid'});
    expect((await network.getComicInfo('42')).success, isTrue);
    expect(store.stateFor('account-A', '42')?.isBookmarked, isTrue);
    reply = (_) async => _detail(bookmark: null);
    expect((await network.getComicInfo('42')).success, isTrue);
    expect(store.stateFor('account-A', '42')?.isBookmarked, isFalse);
  });

  test('successful add and delete publish public or private confirmed state',
      () async {
    reply = (request) async =>
        request.method == 'POST' ? '{"error":false}' : _detail();
    expect(
        (await network.setBookmark('42',
                isAdding: true, visibility: PixivBookmarkVisibility.private))
            .success,
        isTrue);
    expect(store.stateFor('account-A', '42')?.isBookmarked, isTrue);
    expect(store.stateFor('account-A', '42')?.bookmarkPrivate, isTrue);
    expect((await network.setBookmark('42', isAdding: false)).success, isTrue);
    expect(store.stateFor('account-A', '42')?.isBookmarked, isFalse);
    expect(requests.where((request) => request.method == 'POST'), hasLength(2));
  });

  test('already absent delete confirms false without submitting a POST',
      () async {
    store.confirm('account-A', '42', _bookmarked);
    reply = (_) async => _detail(bookmark: null);
    expect((await network.setBookmark('42', isAdding: false)).success, isTrue);
    expect(store.stateFor('account-A', '42')?.isBookmarked, isFalse);
    expect(requests, hasLength(1));
    expect(requests.single.method, 'GET');
  });

  test('failed write retains the previous confirmed state', () async {
    store.confirm('account-A', '42', _notBookmarked);
    final revision = store.revisionFor('account-A', '42');
    reply = (_) async => '{"error":true,"message":"offline failure"}';
    expect((await network.setBookmark('42', isAdding: true)).error, isTrue);
    expect(store.stateFor('account-A', '42')?.isBookmarked, isFalse);
    expect(store.revisionFor('account-A', '42'), revision);
  });

  for (final detailRead in [false, true]) {
    test('older ${detailRead ? "detail" : "state"} read cannot erase a new add',
        () async {
      final readStarted = Completer<void>();
      final readResponse = Completer<String>();
      reply = (request) async {
        if (request.method == 'GET') {
          readStarted.complete();
          return readResponse.future;
        }
        return '{"error":false}';
      };
      final oldRead = detailRead
          ? network.getComicInfo('42')
          : network.getBookmarkState('42');
      await readStarted.future;
      expect((await network.setBookmark('42', isAdding: true)).success, isTrue);
      readResponse.complete(_detail(bookmark: null));
      await oldRead;
      expect(store.stateFor('account-A', '42')?.isBookmarked, isTrue);
    });
  }

  test('account switch during state read cannot publish into either account',
      () async {
    final started = Completer<void>();
    final response = Completer<String>();
    reply = (_) {
      started.complete();
      return response.future;
    };
    final result = network.getBookmarkState('42');
    await started.future;
    await network.setSessionCookie('account-B');
    response.complete(_detail());
    expect((await result).error, isTrue);
    expect(store.stateFor('account-A', '42'), isNull);
    expect(store.stateFor('account-B', '42'), isNull);
  });

  test('account switch during successful write cannot publish old action state',
      () async {
    final started = Completer<void>();
    final response = Completer<String>();
    reply = (_) {
      started.complete();
      return response.future;
    };
    final result = network.setBookmark('42', isAdding: true);
    await started.future;
    await network.setSessionCookie('account-B');
    response.complete('{"error":false}');
    await result;
    expect(store.stateFor('account-A', '42'), isNull);
    expect(store.stateFor('account-B', '42'), isNull);
  });
}
