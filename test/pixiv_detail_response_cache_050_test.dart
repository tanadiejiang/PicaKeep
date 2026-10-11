import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/network/res.dart';

void main() {
  PixivDetailSession session({bool Function()? owner}) => PixivDetailSession(
      scope: PixivDetailScope.search, entries: const [], ownerIsCurrent: owner);

  test(
      '050 session shares in-flight and completed responses by account work and kind',
      () async {
    final scope = session();
    addTearDown(scope.dispose);
    var requests = 0;
    final result = Completer<Res<String>>();
    Future<Res<String>> read(String account, String work, String kind) =>
        scope.readResponse(
            account: account,
            workId: work,
            kind: kind,
            load: () {
              requests++;
              return result.future;
            },
            isReusable: (value) => !value.error);
    final first = read('a', '1', 'detail');
    final duplicate = read('a', '1', 'detail');
    expect(requests, 1);
    result.complete(const Res('metadata'));
    expect(await first, same(await duplicate));
    expect(await read('a', '1', 'detail'), same(await first));
    expect(requests, 1);
    await read('b', '1', 'detail');
    await read('a', '2', 'detail');
    await read('a', '1', 'pages');
    expect(requests, 4);
  });

  test('050 errors and rejected values do not block explicit retry', () async {
    final scope = session();
    addTearDown(scope.dispose);
    var requests = 0;
    Future<Res<String>> read() => scope.readResponse(
        account: 'a',
        workId: '1',
        kind: 'detail',
        load: () async {
          requests++;
          return requests == 1 ? const Res.error('failed') : const Res('ok');
        },
        isReusable: (value) => !value.error);
    expect((await read()).error, isTrue);
    expect((await read()).data, 'ok');
    await read();
    expect(requests, 2);
    scope.invalidateResponses(account: 'a', workId: '1');
    await read();
    expect(requests, 3);
    var throws = 0;
    Future<String> throwing() => scope.readResponse(
        account: 'a',
        workId: '2',
        kind: 'detail',
        load: () async {
          throws++;
          throw StateError('fixture');
        },
        isReusable: (_) => true);
    await expectLater(throwing(), throwsStateError);
    await expectLater(throwing(), throwsStateError);
    expect(throws, 2);
  });

  test(
      '050 LRU is limited to 64 lightweight responses and refresh invalidates only target',
      () async {
    final scope = session();
    addTearDown(scope.dispose);
    var requests = 0;
    Future<String> read(String id, {String kind = 'detail'}) =>
        scope.readResponse(
            account: 'a',
            workId: id,
            kind: kind,
            load: () async {
              requests++;
              return id;
            },
            isReusable: (_) => true);
    for (var i = 0; i < 65; i++) {
      await read('$i');
    }
    expect(requests, 65);
    await read('64');
    expect(requests, 65);
    await read('0');
    expect(requests, 66);
    await read('64', kind: 'pages');
    expect(requests, 67);
    scope.invalidateResponses(account: 'a', workId: '64', kind: 'pages');
    await read('64');
    expect(requests, 67);
    await read('64', kind: 'pages');
    expect(requests, 68);
  });

  test('050 owner expiration and dispose release retained responses', () async {
    var current = true;
    final scope = session(owner: () => current);
    var requests = 0;
    Future<String> read() => scope.readResponse(
        account: 'a',
        workId: '1',
        kind: 'detail',
        load: () async {
          requests++;
          return 'ok';
        },
        isReusable: (_) => true);
    await read();
    current = false;
    await read();
    expect(requests, 2);
    scope.dispose();
    current = true;
    await read();
    expect(requests, 3);
  });
}
