import 'dart:io';

import 'package:flutter/services.dart';

/// 读取 Android 系统 HTTP 代理（host:port）。
///
/// 用途：Android 系统 WebView 不会自动读取 dart:io 所用的系统代理，导致
/// picacg/jm（走 dio）能联网、而 WebView 内的 forums.e-hentai.org 等被墙站点
/// 卡在 Cloudflare 验证。本函数经原生 channel 取系统代理，交给
/// flutter_inappwebview 的 ProxyController 让 WebView 跟随系统代理。
///
/// 无代理 / 非 Android / 调用失败时返回 null（调用方降级为直连）。
Future<String?> getSystemProxy() async {
  if (!Platform.isAndroid) return null;
  try {
    final res = await const MethodChannel('lingxue.picakeep/system_proxy')
        .invokeMethod<String>('get');
    final v = res?.trim();
    return (v == null || v.isEmpty) ? null : v;
  } catch (_) {
    return null;
  }
}
