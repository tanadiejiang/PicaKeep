/// `Res` 追加错误元信息后的**兼容性**测试。
///
/// 计划要求："现有 Res 只保留字符串，须为其构造器兼容追加可选 `errorCode`、
/// `statusCode`，`Res.fromErrorRes` 透传；原 data/error/subData 语义不变"，并且
/// "新增测试证明旧 Res 调用仍兼容且错误元信息不会在转发中丢失"。
///
/// 这里用 `package:test` 覆盖纯逻辑；`Res` 只依赖 `flutter/foundation` 的
/// `@immutable`，因此走 `flutter test` 运行。文件放在 `test/explore/` 下。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/explore/explore_error_mapping.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/network/res.dart';

void main() {
  group('Res 旧调用兼容（改造前写法必须行为不变）', () {
    test('const Res(data) 与 Res(data, subData:) 语义不变', () {
      const ok = Res<int>(1, subData: 5);
      expect(ok.error, isFalse);
      expect(ok.success, isTrue);
      expect(ok.data, 1);
      expect(ok.dataOrNull, 1);
      expect(ok.subData, 5);
      expect(ok.errorMessage, isNull);
      expect(ok.errorMessageWithoutNull, 'Unknown Error');
      // 新增字段在旧写法下为空，旧调用方读不到它们也不会改变行为。
      expect(ok.errorCode, isNull);
      expect(ok.statusCode, isNull);
    });

    test('const Res.error(msg) 仍然只靠字符串判错', () {
      const bad = Res<int>.error('boom');
      expect(bad.error, isTrue);
      expect(bad.success, isFalse);
      expect(bad.errorMessage, 'boom');
      expect(bad.errorMessageWithoutNull, 'boom');
      expect(bad.dataOrNull, isNull);
      expect(bad.errorCode, isNull);
      expect(bad.statusCode, isNull);
      // 失败时取 data 仍抛异常（既有契约）。
      expect(() => bad.data, throwsException);
    });

    test('Res(null, errorMessage:) 命名参数写法不变', () {
      const bad = Res<String>(null, errorMessage: 'nope');
      expect(bad.error, isTrue);
      expect(bad.errorMessage, 'nope');
      expect(bad.dataOrNull, isNull);
    });
  });

  group('Res.fromErrorRes 转发', () {
    test('旧行为：只转发 errorMessage，data 仍为空', () {
      const source = Res<int>.error('original');
      final forwarded = Res<String>.fromErrorRes(source);
      expect(forwarded.error, isTrue);
      expect(forwarded.errorMessage, 'original');
      expect(forwarded.dataOrNull, isNull);
    });

    test('错误元信息（errorCode / statusCode）在转发中不丢失', () {
      const source = Res<int>.error(
        'need login',
        errorCode: ResErrorCode.loginRequired,
        statusCode: 401,
      );
      final forwarded = Res<String>.fromErrorRes(source);
      expect(forwarded.errorCode, ResErrorCode.loginRequired);
      expect(forwarded.statusCode, 401);
    });

    test('fromErrorRes 可覆盖 subData 且不影响错误元信息', () {
      const source = Res<int>.error(
        'bad',
        errorCode: ResErrorCode.parse,
        statusCode: 500,
      );
      final forwarded = Res<List<String>>.fromErrorRes(source, subData: 7);
      expect(forwarded.subData, 7);
      expect(forwarded.errorCode, ResErrorCode.parse);
      expect(forwarded.statusCode, 500);
    });

    test('多级转发后元信息仍在（链式 fromErrorRes）', () {
      const source = Res<int>.error(
        'denied',
        errorCode: ResErrorCode.accessDenied,
        statusCode: 403,
      );
      final second = Res<String>.fromErrorRes(source);
      final third = Res<double>.fromErrorRes(second);
      expect(third.errorCode, ResErrorCode.accessDenied);
      expect(third.statusCode, 403);
      expect(third.errorMessage, 'denied');
    });

    test('errorMessage 为空时转发成 Unknown Error（既有行为）', () {
      const source = Res<int>(null);
      final forwarded = Res<String>.fromErrorRes(source);
      expect(forwarded.error, isTrue);
      expect(forwarded.errorMessageWithoutNull, 'Unknown Error');
      expect(forwarded.errorCode, isNull);
    });
  });

  group('Res → ExploreError 映射', () {
    test('请求层已明确的类型优先，不被状态码推翻', () {
      const source = Res<int>.error(
        'nope',
        errorCode: ResErrorCode.unsupported,
        statusCode: 403,
      );
      final mapped = exploreErrorFromRes(source);
      expect(mapped.code, ExploreErrorCode.unsupported);
      expect(mapped.statusCode, 403);
    });

    test('无类型时按状态码推断：401 登录、403 无权、其它 network', () {
      expect(
        exploreErrorFromRes(const Res<int>.error('a', statusCode: 401)).code,
        ExploreErrorCode.loginRequired,
      );
      expect(
        exploreErrorFromRes(const Res<int>.error('b', statusCode: 403)).code,
        ExploreErrorCode.accessDenied,
      );
      expect(
        exploreErrorFromRes(const Res<int>.error('c', statusCode: 500)).code,
        ExploreErrorCode.network,
      );
      expect(
        exploreErrorFromRes(const Res<int>.error('d')).code,
        ExploreErrorCode.network,
      );
    });

    test('parse / invalidArgument 类型不被状态码覆盖', () {
      expect(
        exploreErrorFromRes(const Res<int>.error('p',
                errorCode: ResErrorCode.parse, statusCode: 401))
            .code,
        ExploreErrorCode.parse,
      );
      expect(
        exploreErrorFromRes(const Res<int>.error('i',
                errorCode: ResErrorCode.invalidArgument))
            .code,
        ExploreErrorCode.invalidArgument,
      );
    });

    test('文案原样保留，空文案回退到兜底', () {
      expect(exploreErrorFromRes(const Res<int>.error('keep me')).message,
          'keep me');
      expect(
        exploreErrorFromRes(const Res<int>(null), fallbackMessage: '兜底')
            .message,
        '兜底',
      );
    });
  });
}
