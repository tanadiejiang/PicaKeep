/// `Res` → 探索结构化错误的转换。
///
/// 放在探索包内而不是 `res.dart`：`Res` 属于应用层网络底座，探索契约层不认识它；
/// 反过来，适配器（应用运行时）需要这一层薄转换，把字符串错误补齐类型。
library;

import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/network/res.dart';

/// 把 [Res] 的失败转成 [ExploreError]。
///
/// 优先级：`Res.errorCode`（请求层已明确判定）> HTTP 状态码推断 > [network] 兜底。
/// **绝不**把任意 403 猜成登录失败：只有请求层明确给出 `loginRequired` 才这么归类。
ExploreError exploreErrorFromRes(Res<Object?> res, {String? fallbackMessage}) {
  // 用**可空的** errorMessage 判断，而不是 errorMessageWithoutNull：
  // 后者在空文案时会回退成 'Unknown Error'（恒非空），会让 fallbackMessage
  // 永远用不上、兜底形同虚设。
  final raw = res.errorMessage?.trim() ?? '';
  final message =
      raw.isNotEmpty ? raw : (fallbackMessage ?? res.errorMessageWithoutNull);
  final code = _codeOf(res.errorCode, res.statusCode);
  return ExploreError(
    code,
    message,
    statusCode: res.statusCode,
  );
}

ExploreErrorCode _codeOf(ResErrorCode? code, int? statusCode) {
  switch (code) {
    case ResErrorCode.loginRequired:
      return ExploreErrorCode.loginRequired;
    case ResErrorCode.accessDenied:
      return ExploreErrorCode.accessDenied;
    case ResErrorCode.parse:
      return ExploreErrorCode.parse;
    case ResErrorCode.invalidArgument:
      return ExploreErrorCode.invalidArgument;
    case ResErrorCode.unsupported:
      return ExploreErrorCode.unsupported;
    case ResErrorCode.network:
      return ExploreErrorCode.network;
    case null:
      break;
  }
  if (statusCode == null) return ExploreErrorCode.network;
  return switch (statusCode) {
    401 => ExploreErrorCode.loginRequired,
    403 => ExploreErrorCode.accessDenied,
    >= 500 => ExploreErrorCode.network,
    _ => ExploreErrorCode.network,
  };
}

/// 在适配器解析边界捕获到的异常 → parse 错误。
ExploreError exploreParseError(Object error) => ExploreError(
      ExploreErrorCode.parse,
      '解析失败：$error',
    );
