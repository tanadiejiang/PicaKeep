import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// 复现 JS Number.prototype.toString() 语义。
/// 关键：必须用 double 运算 + double.toString()，不能用 int 精确运算，
/// 也不能用 toStringAsFixed(0)/toInt()/BigInt —— 那三者都与 JS 结果不同
/// （详见第十五轮 05 计划「诊断思路与关键结论」的实测对照表）。
String jsNumberToString(double v) {
  var s = v.toString();
  if (s.endsWith('.0')) s = s.substring(0, s.length - 2);
  return s;
}

/// soutubot X-Api-Key：base64(String(unix秒² + UA长度² + m)) 整串反转、去掉全部 '='。
/// 算法逆向自站点前端 JS（2025 版，含 + m 项；2023 版无 m，算法在演进）。
String calcSoutubotApiKey(int unixSec, int uaLen, int m) {
  final sum = unixSec.toDouble() * unixSec.toDouble() +
      uaLen.toDouble() * uaLen.toDouble() +
      m.toDouble();
  final raw = jsNumberToString(sum);
  return base64
      .encode(utf8.encode(raw))
      .split('')
      .reversed
      .join()
      .replaceAll('=', '');
}

/// 从主页 HTML 提取 window.GLOBAL.m；提取失败返回 null。
/// 优先在 GLOBAL 对象字面量内匹配，降低误匹配其他 "m:" 的概率。
int? extractSoutubotGlobalM(String html) {
  final scoped = RegExp(r'GLOBAL\s*=\s*\{[^{}]*?\bm:\s*(-?\d+)', dotAll: true)
      .firstMatch(html);
  final match = scoped ?? RegExp(r'\bm:\s*(-?\d+)\s*[,}]').firstMatch(html);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// 仿浏览器 boundary：----WebKitFormBoundary + 16 位随机字母数字。
String randomWebKitBoundary([Random? random]) {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final rng = random ?? Random();
  final suffix =
      List.generate(16, (_) => chars[rng.nextInt(chars.length)]).join();
  return '----WebKitFormBoundary$suffix';
}

/// 手工拼 multipart/form-data 请求体。
/// 不用 dio 的 FormData：项目锁定 dio 5.4.1，FormData 不支持自定义 boundary
/// （boundaryName 参数 5.4.2 才加入），且需要精确控制 part 头形状：
/// file 部分必须是 name="file"; filename="image" + Content-Type: application/octet-stream。
Uint8List buildSoutubotMultipartBody({
  required List<int> imageBytes,
  required String boundary,
  String factor = '1.2',
}) {
  final header = '--$boundary\r\n'
      'Content-Disposition: form-data; name="file"; filename="image"\r\n'
      'Content-Type: application/octet-stream\r\n'
      '\r\n';
  final tail = '\r\n'
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="factor"\r\n'
      '\r\n'
      '$factor\r\n'
      '--$boundary--\r\n';
  return Uint8List.fromList(
      [...utf8.encode(header), ...imageBytes, ...utf8.encode(tail)]);
}
