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

/// Detect the upload type from bytes, never a caller-supplied file extension.
/// The current service rejects the legacy application/octet-stream file part.
/// This only identifies the container; attachment import validates decoding.
({String extension, String mime})? detectSoutubotImageType(List<int> bytes) {
  bool matches(List<int> prefix, [int offset = 0]) {
    if (bytes.length < offset + prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[offset + i] != prefix[i]) return false;
    }
    return true;
  }

  if (matches(const [0xff, 0xd8, 0xff])) {
    return (extension: 'jpg', mime: 'image/jpeg');
  }
  if (matches(const [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10])) {
    return (extension: 'png', mime: 'image/png');
  }
  if (matches(const [71, 73, 70, 56, 55, 97]) ||
      matches(const [71, 73, 70, 56, 57, 97])) {
    return (extension: 'gif', mime: 'image/gif');
  }
  if (matches(const [82, 73, 70, 70]) && matches(const [87, 69, 66, 80], 8)) {
    return (extension: 'webp', mime: 'image/webp');
  }
  if (matches(const [66, 77])) {
    return (extension: 'bmp', mime: 'image/bmp');
  }
  return null;
}

/// 手工拼 multipart/form-data，文件 part 与当前浏览器 File 上传协议一致。
/// 固定安全文件名不泄露原始附件名；MIME 与扩展名由图片签名确定。
Uint8List buildSoutubotMultipartBody({
  required List<int> imageBytes,
  required String boundary,
  String factor = '1.2',
  String fileField = 'file',
  Map<String, String>? fields,
}) {
  final imageType = detectSoutubotImageType(imageBytes);
  if (imageType == null) {
    throw const FormatException('Unsupported image upload format');
  }
  final effectiveFields = fields ?? {'factor': factor};
  final fieldName = RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$');
  if (!fieldName.hasMatch(fileField) ||
      effectiveFields.keys
          .any((key) => !fieldName.hasMatch(key) || key == fileField)) {
    throw const FormatException('Invalid multipart field name');
  }
  final header = '--$boundary\r\n'
      'Content-Disposition: form-data; name="$fileField"; filename="image.${imageType.extension}"\r\n'
      'Content-Type: ${imageType.mime}\r\n'
      '\r\n';
  final tail = StringBuffer('\r\n');
  for (final entry in effectiveFields.entries) {
    tail.write('--$boundary\r\n'
        'Content-Disposition: form-data; name="${entry.key}"\r\n'
        '\r\n${entry.value}\r\n');
  }
  tail.write('--$boundary--\r\n');
  return Uint8List.fromList(
      [...utf8.encode(header), ...imageBytes, ...utf8.encode(tail.toString())]);
}
