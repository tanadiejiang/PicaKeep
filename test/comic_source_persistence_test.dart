import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app.dart';

/// A19：ComicSource 持久化的完成与错误语义。
///
/// setUpAll 内一次性初始化临时 App 路径（App.dataPath 是 late final，
/// 不能在用例之间重复初始化）。

class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final String root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  final PathProviderPlatform originalPaths = PathProviderPlatform.instance;

  setUpAll(() async {
    workspace = await Directory.systemTemp.createTemp('picakeep_persist_');
    PathProviderPlatform.instance = _Paths(workspace.path);
    await App.init(dataPathOverride: '${workspace.path}/data');
  });

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPaths;
    try {
      if (await workspace.exists()) {
        await workspace.delete(recursive: true);
      }
    } catch (_) {
      // 临时目录清理失败不影响断言结果。
    }
  });

  ComicSource buildSource(String key, Map<String, dynamic> data) =>
      ComicSource.named(key: key, name: key, data: data);

  test('A19 同步 writer 失败后释放保存任务，后续可以重试', () async {
    final source = buildSource('sync_failure', {'token': 'test-token'});
    source.writeDataFile = (_, __) => throw StateError('sync-write-failure');
    await expectLater(source.saveData(), throwsA(isA<StateError>()));

    final writes = <String>[];
    source.writeDataFile = (_, contents) async => writes.add(contents);
    await source.saveData();
    expect(writes, hasLength(1));
    expect(jsonDecode(writes.single)['token'], 'test-token');
  });

  test('A19 序列化同步失败后修正数据可以重试', () async {
    final source = buildSource('encode_failure', {'invalid': Object()});
    final writes = <String>[];
    source.writeDataFile = (_, contents) async => writes.add(contents);
    await expectLater(
        source.saveData(), throwsA(isA<JsonUnsupportedObjectError>()));

    source.data['invalid'] = 'valid';
    await source.saveData();
    expect(writes, hasLength(1));
    expect(jsonDecode(writes.single)['invalid'], 'valid');
  });

  test('A19 保存期间的新修改不会提前返回，最后一轮落盘包含该修改', () async {
    final source = buildSource('persist_a', <String, dynamic>{'token': 'v1'});
    final writes = <String>[];
    final firstRoundGate = Completer<void>();
    var round = 0;
    source.writeDataFile = (path, contents) async {
      writes.add(contents);
      round++;
      if (round == 1) {
        await firstRoundGate.future;
      }
    };

    final first = source.saveData();
    // 让第一轮真正进入写入挂起状态
    await Future<void>.delayed(Duration.zero);
    expect(writes, hasLength(1));

    // 保存进行中修改数据，再次保存：这一次必须等到补写轮结束
    source.data['token'] = 'v2';
    var secondCompleted = false;
    final second = source.saveData().then((_) => secondCompleted = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      secondCompleted,
      isFalse,
      reason: '合并调用必须等待包含自己修改的那一轮写入完成',
    );

    firstRoundGate.complete();
    await Future.wait(<Future<void>>[first, second]);

    expect(writes, hasLength(2));
    expect(jsonDecode(writes.first)['token'], 'v1');
    expect(
      jsonDecode(writes.last)['token'],
      'v2',
      reason: '最后一轮必须写出新快照',
    );
  });

  test('A19 多轮期间的多次调用只在最终轮之后一起返回', () async {
    final source = buildSource('persist_b', <String, dynamic>{'n': 0});
    final writes = <String>[];
    final gate = Completer<void>();
    var round = 0;
    source.writeDataFile = (path, contents) async {
      writes.add(contents);
      round++;
      if (round <= 2) {
        await gate.future;
      }
    };

    final futures = <Future<void>>[source.saveData()];
    await Future<void>.delayed(Duration.zero);
    source.data['n'] = 1;
    futures.add(source.saveData());
    source.data['n'] = 2;
    futures.add(source.saveData());

    await Future<void>.delayed(const Duration(milliseconds: 30));
    gate.complete();
    await Future.wait(futures);

    expect(writes.length, greaterThanOrEqualTo(2));
    expect(jsonDecode(writes.last)['n'], 2);
  });

  test('A19 首轮失败向同轮所有等待者传播，且之后仍可成功保存', () async {
    final source = buildSource('persist_c', <String, dynamic>{'token': 'x'});
    final writes = <String>[];
    var shouldFail = true;
    source.writeDataFile = (path, contents) async {
      if (shouldFail) {
        throw StateError('write-boom');
      }
      writes.add(contents);
    };

    final first = source.saveData();
    final second = source.saveData();

    final errors = <Object>[];
    await Future.wait(<Future<void>>[
      first.catchError((Object e) {
        errors.add(e);
      }),
      second.catchError((Object e) {
        errors.add(e);
      }),
    ]);

    expect(errors, hasLength(2), reason: '同轮的两个等待者都应收到失败');
    expect(errors.first, isA<StateError>());
    expect(writes, isEmpty);

    // 任务状态已释放：重试可以成功并真正落盘
    shouldFail = false;
    await source.saveData();
    expect(writes, hasLength(1));
    expect(jsonDecode(writes.single)['token'], 'x');
  });

  test('A19 补写轮失败同样传播，后续保存可恢复', () async {
    final source = buildSource('persist_d', <String, dynamic>{'v': 1});
    final writes = <String>[];
    final gate = Completer<void>();
    var round = 0;
    source.writeDataFile = (path, contents) async {
      round++;
      if (round == 1) {
        await gate.future;
        writes.add(contents);
        return;
      }
      throw StateError('second-round-boom');
    };

    final first = source.saveData();
    await Future<void>.delayed(Duration.zero);
    source.data['v'] = 2;
    final errors = <Object>[];
    final second = source.saveData().catchError((Object e) => errors.add(e));

    gate.complete();
    await first.catchError((Object e) => errors.add(e));
    await second;

    expect(writes, hasLength(1));
    expect(errors, isNotEmpty, reason: '补写轮失败必须被观察到');

    // 失败后任务释放，下一次保存成功
    source.writeDataFile = (path, contents) async => writes.add(contents);
    await source.saveData();
    expect(jsonDecode(writes.last)['v'], 2);
  });
}
