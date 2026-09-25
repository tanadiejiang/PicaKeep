/// Pixiv 下载的**目录名称模板**与**下载根目录**解析。
///
/// ## 为什么单独成文件
///
/// 命名模板是纯字符串处理，但规则不少（变量替换、非法字符、长度上限），
/// 而且**目录名一旦写进 download.db 就成了记录的一部分** —— 改错了会让已下载
/// 的内容"找不到"。所以把它抽成纯函数 + 独立测试，而不是塞在下载器里。
///
/// ## 模板变量
///
/// - `{title}`  作品标题
/// - `{author}` 作者
/// - `{id}`     作品 ID
///
/// 默认模板 `{title}`，与引入本功能之前的行为一致（那时目录名固定取标题）。
library;

/// 默认模板：与改动前的行为一致。
const String kDefaultPixivDirNameTemplate = '{title}';

/// 模板变量名 → 取值。
const List<String> kPixivDirNameVariables = <String>['title', 'author', 'id'];

/// 单个路径段的**字节**上限。
///
/// ext4 / f2fs 是 255 字节；中日文在 UTF-8 下一个字 3 字节，所以中文标题约 85 字
/// 就会超限。超限时系统报错很难懂，这里主动截断。
const int _kMaxSegmentBytes = 255;

/// 按 [template] 渲染 Pixiv 下载的目录名。
///
/// 渲染顺序：**先替换变量，再做安全化**。
/// 反过来的话，变量值里的 `{title}` 之类字面量会被二次替换 —— 标题里出现这种
/// 花括号并不罕见（例如同人作品名）。
///
/// 结果保证：非空、无路径分隔符、无控制字符、字节数不超上限。
/// 全都清理完仍为空时，退回 [fallback]（通常是作品 ID），**绝不返回空串** ——
/// 空目录名会让下载落到根目录里，把别人的文件混进来。
String renderPixivDirectoryName({
  required String template,
  required String title,
  required String author,
  required String id,
  String fallback = '',
}) {
  var pattern = template.trim();
  if (pattern.isEmpty) {
    pattern = kDefaultPixivDirNameTemplate;
  }
  final values = <String, String>{
    'title': title.trim(),
    'author': author.trim(),
    'id': id.trim(),
  };
  var rendered = pattern;
  for (final entry in values.entries) {
    rendered = rendered.replaceAll('{${entry.key}}', entry.value);
  }
  rendered = sanitizeDirectorySegment(rendered);
  if (rendered.isNotEmpty) {
    return rendered;
  }
  // 变量全为空 / 模板只剩分隔符时，退回兜底值。
  final safeFallback = sanitizeDirectorySegment(fallback.trim());
  if (safeFallback.isNotEmpty) {
    return safeFallback;
  }
  // 连兜底都没有：给一个固定名，避免把下载写进根目录。
  return 'pixiv';
}

/// 把任意文本清洗成**可用作单个路径段**的名字。
///
/// - 路径分隔符 `/` `\` 换成 `_`（否则会在下载根下建出意料之外的层级）
/// - 控制字符与 `:` `*` `?` `"` `<` `>` `|` 去掉（跨平台非法）
/// - 前后空白与结尾的点去掉（Windows 不允许以点结尾，且 `.`/`..` 有特殊含义）
/// - 连续空白压成一个空格（模板拼接常留下多余空格）
/// - 按 UTF-8 字节截断到 [_kMaxSegmentBytes] 以内，且**不切碎多字节字符**
String sanitizeDirectorySegment(String value) {
  var result = value
      .replaceAll(RegExp(r'[/\\]'), '_')
      .replaceAll(RegExp(r'[:\*\?"<>\|]'), '')
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  // 结尾的点要去掉；但整串就是 "." / ".." 时下面会一并处理成空。
  while (result.endsWith('.')) {
    result = result.substring(0, result.length - 1).trimRight();
  }
  if (result == '.' || result == '..') {
    return '';
  }
  return _truncateToBytes(result, _kMaxSegmentBytes);
}

/// 按 UTF-8 字节数截断，且不切断多字节字符。
String _truncateToBytes(String value, int maxBytes) {
  if (value.codeUnits.isEmpty) {
    return value;
  }
  // 先做一次快速判断：绝大多数名字不会超。
  if (_utf8Length(value) <= maxBytes) {
    return value;
  }
  final buffer = StringBuffer();
  var used = 0;
  // 按 rune 迭代而不是 code unit —— 否则会把代理对（emoji）劈成两半。
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    final size = _utf8Length(char);
    if (used + size > maxBytes) {
      break;
    }
    used += size;
    buffer.write(char);
  }
  return buffer.toString().trim();
}

int _utf8Length(String value) {
  var length = 0;
  for (final rune in value.runes) {
    if (rune <= 0x7f) {
      length += 1;
    } else if (rune <= 0x7ff) {
      length += 2;
    } else if (rune <= 0xffff) {
      length += 3;
    } else {
      length += 4;
    }
  }
  return length;
}
