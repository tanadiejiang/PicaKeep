import 'package:flutter/foundation.dart';

/// 结构化错误类型。**仅追加**，不改变既有 data/error/subData 语义。
///
/// 字符串错误文案不足以让上层区分"要登录 / 没权限 / 解析失败 / 网络失败"，
/// 之前只能靠猜关键词。这里给出可判定的类型，旧调用方继续只读
/// [Res.errorMessage] 也不受影响。
enum ResErrorCode {
  /// 需要登录（凭据缺失或站点明确判定未登录）。
  loginRequired,

  /// 已登录但无权访问。
  accessDenied,

  /// 传输层失败（连接 / 超时 / DNS / 5xx 等无法进一步归类者）。
  network,

  /// 响应到达但无法解析。
  parse,

  /// 参数非法（缺 ID、越界期号等）。
  invalidArgument,

  /// 该源不支持本次请求。
  unsupported,
}

@immutable
class Res<T> {
  const Res(this._data,
      {this.errorMessage, this.subData, this.errorCode, this.statusCode});

  const Res.error(String err, {this.errorCode, this.statusCode})
      : _data = null,
        subData = null,
        errorMessage = err;

  Res.fromErrorRes(Res another, {this.subData})
      : _data = null,
        errorMessage = another.errorMessageWithoutNull,
        // 转发时**必须**透传错误元信息：否则四源请求层辛苦判定的 loginRequired
        // 会在 `Res.fromErrorRes` 这一跳被抹成"无法判别"。
        errorCode = another.errorCode,
        statusCode = another.statusCode;

  final String? errorMessage;
  final T? _data;
  final dynamic subData;

  /// 结构化错误类型；旧调用方不读它，行为不变。
  final ResErrorCode? errorCode;

  /// 已知的 HTTP 状态码；未知时为空。
  final int? statusCode;

  String get errorMessageWithoutNull => errorMessage ?? 'Unknown Error';

  bool get error => errorMessage != null;

  bool get success => !error;

  T get data => _data ?? (throw Exception(errorMessage));

  T? get dataOrNull => _data;

  @override
  String toString() => _data.toString();
}
