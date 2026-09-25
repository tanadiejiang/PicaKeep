/// 把底层网络异常翻成**可操作的中文提示**。
///
/// ## 为什么需要它
///
/// 真机反馈：Komiic 登录失败时，界面上直接显示了 dio 的原始英文异常：
///
/// ```text
/// The connection errored: Connection reset by peer
/// This indicates an error which most likely cannot be solved by the library.
/// ```
///
/// 这段话对用户没有任何帮助 —— 既没说清"发生了什么"，也没说"下一步做什么"。
/// 实际原因是设备到 `komiic.com` 的链路被中断（该站点在 Cloudflare 后面，
/// 直连不通时需要走代理），而应用内的代理设置是空的。
///
/// 这里把常见异常映射成"发生了什么 + 该怎么办"，并**保留原始信息**用于排查
/// （原始文本仍会进日志，只是不再直接丢给用户看）。
library;

import 'dart:io';

import 'package:dio/dio.dart';

/// 把 [error] 描述成面向用户的中文提示。
///
/// [host] 是目标主机名（如 `komiic.com`），用于把提示说得更具体。
String describeNetworkError(Object error, {String? host}) {
  final raw = networkErrorRawMessage(error);
  final target = (host == null || host.trim().isEmpty) ? '目标站点' : host.trim();
  final lower = raw.toLowerCase();

  // **先按 dio 的结构化类型判定**，再退回文本匹配。
  //
  // 顺序不能反：文本匹配不可靠 —— `connectionTimeout` 的实际消息是
  // "The request connection took longer than 0:00:15"，里面**没有** "timeout"
  // 字样，只靠关键词会漏判（这一点是被测试抓出来的）。
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时：访问 $target 没有在预期时间内完成。'
            '请检查当前网络，或改用代理后重试。';
      case DioExceptionType.badCertificate:
        return '证书校验失败：与 $target 的安全连接不被信任，'
            '常见于代理做了中间人拦截。';
      case DioExceptionType.badResponse:
        final status = error.response?.statusCode;
        return '服务端返回异常状态${status == null ? '' : '（HTTP $status）'}：$raw';
      case DioExceptionType.cancel:
        return '请求已取消。';
      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        // 交给下面的文本细分，判断是重置、拒绝还是不可达。
        break;
    }
  }

  // 按"用户能采取什么行动"分类，而不是按异常类型罗列。
  if (lower.contains('connection reset') ||
      lower.contains('connectionreset') ||
      lower.contains('broken pipe')) {
    return '连接被中断（Connection reset）：到 $target 的连接被对端重置。'
        '常见原因是网络阻断或代理未生效 —— 可在「设置 → 网络 → 代理」'
        '填写可用代理后重试。';
  }
  if (lower.contains('timed out') ||
      lower.contains('timeout') ||
      lower.contains('took longer than')) {
    return '连接超时：访问 $target 没有在预期时间内完成。'
        '请检查当前网络，或改用代理后重试。';
  }
  if (lower.contains('failed host lookup') ||
      lower.contains('nodename nor servname') ||
      lower.contains('name or service not known')) {
    return '域名解析失败：无法解析 $target。请检查网络与 DNS 设置。';
  }
  if (lower.contains('handshake') ||
      lower.contains('certificate') ||
      lower.contains('tls')) {
    return '安全连接建立失败：与 $target 的 TLS 握手未完成，'
        '常见于代理拦截或证书异常。';
  }
  if (lower.contains('network is unreachable') ||
      lower.contains('no route to host') ||
      lower.contains('network is down')) {
    return '网络不可达：当前网络无法访问 $target。';
  }
  if (lower.contains('connection refused')) {
    return '连接被拒绝：$target 拒绝了连接，通常是代理地址或端口填错了。';
  }

  if (error is DioException) {
    return '网络请求失败（${_describeDioType(error.type)}）：$raw';
  }
  return '网络请求失败：$raw';
}

/// 取出异常里**最有信息量**的原始文本（用于日志与兜底展示）。
///
/// `DioException.message` 往往只是"The connection errored: …"这类包装文案，
/// 真正的原因在被包住的 [SocketException] 里，所以优先取内层。
String networkErrorRawMessage(Object error) {
  if (error is DioException) {
    final inner = error.error;
    if (inner is SocketException) {
      final message = inner.message.trim();
      return message.isEmpty ? inner.toString().trim() : message;
    }
    if (inner is HttpException) {
      final message = inner.message.trim();
      if (message.isNotEmpty) return message;
    }
    final message = error.message?.trim() ?? '';
    if (message.isNotEmpty) return message;
  }
  if (error is SocketException) {
    final message = error.message.trim();
    return message.isEmpty ? error.toString().trim() : message;
  }
  return error.toString().trim();
}

String _describeDioType(DioExceptionType type) => switch (type) {
      DioExceptionType.connectionTimeout => '连接超时',
      DioExceptionType.sendTimeout => '发送超时',
      DioExceptionType.receiveTimeout => '接收超时',
      DioExceptionType.badCertificate => '证书校验失败',
      DioExceptionType.badResponse => '服务端返回异常状态',
      DioExceptionType.cancel => '请求已取消',
      DioExceptionType.connectionError => '无法建立连接',
      DioExceptionType.unknown => '未知错误',
    };
