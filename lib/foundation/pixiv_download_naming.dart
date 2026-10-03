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
/// - `{pages}`  页数，**渲染成 `p3` 这种形态**（见 [renderPixivDirectoryName]）
///
/// 默认勾选标题和作品 ID；已有非空模板保持用户保存的值。
library;

import 'package:picakeep/foundation/template_field_order.dart';

/// `settings[]` 下标：Pixiv 专属下载目录。
///
/// 空串 = 跟随「本应用下载目录」（`settings[22]`）。
///
/// ⚠️ 非空时它是一个**独立的下载根**：写入侧会让 Pixiv 的 `download.db` 落在那里，
/// 因此**读取侧的"有效下载根集合"必须同时包含它**（见
/// `online_download_manager.dart` 的 `_effectiveDownloadRoots()` 与
/// `local_library_scan.dart` 里新增的 Pixiv 源）。少接一处，症状就是
/// **"下载成功、但任何列表里都看不到"** —— 不报错、最难排查。
const int pixivDownloadDirSettingIndex = 152;

/// `settings[]` 下标：Pixiv 下载的目录名模板。
const int pixivDirNameTemplateSettingIndex = 153;

/// `settings[]` 下标：Pixiv 多图打包为压缩包（`'1'` 开 / `'0'` 关，默认关）。
///
/// ⚠️ 它改的是**产物形态**（一个作品是"目录"还是"一个文件"），属于兼容性变更：
/// 老内容是目录形态且**不会被转换**，所以读取链路必须同时认两种形态
/// （见 `local_library_static.dart` 的 `_buildDownloadedEpisodeFilesForEp`）。
/// 默认关，是为了让"没主动开过的用户"与改动前**逐字节一致**。
const int pixivMultiPageZipSettingIndex = 154;

/// [pixivMultiPageZipSettingIndex] 的归一化：只认 `'1'`，其余一律 `'0'`（关）。
///
/// 与 `normalizeAndroidRootMode` 等布尔开关同口径。产物形态是兼容性变更，
/// 任何不能确定的值都保持现状最安全。
String normalizePixivMultiPageZip(String? value) {
  return value == '1' ? '1' : '0';
}

/// 是否开启"多图打包、单图直放"。
bool pixivMultiPageZipEnabled(String? value) =>
    normalizePixivMultiPageZip(value) == '1';

/// 压缩包产物的扩展名。
///
/// ⚠️ 这个字符串会被拼进 `download.db` 的 `directory` 列，改动它等于让
/// 已下载的压缩包"找不到自己"。归档读取侧（`isArchivePath`）只认 `.zip`/`.cbz`，
/// 所以也不能随手换成别的。
const String kPixivArchiveExtension = '.zip';

/// 预览用的固定样例值。
///
/// 刻意用带中文/日文与较长数字 ID 的真实形态：这样"空格会不会被压缩"
/// "中文会不会被截断"在预览里一眼能看出来；用 `foo` / `bar` 之类的样例则看不出来。
const String kPixivDirNamePreviewTitle = '夜の海';
const String kPixivDirNamePreviewAuthor = '久蒼穹';
const String kPixivDirNamePreviewId = '150033282';

/// 预览用的样例页数。
///
/// 取一个 **>1 的数**：`{pages}` 在页数为 0/未知时渲染成空串，用 0 当样例
/// 会让预览里那个字段凭空消失，用户看不出勾了它有什么用。3 页既显示形态
/// （`p3`），也与"多图才会被打包"的语义对得上。
const int kPixivDirNamePreviewPages = 3;

/// 用固定样例渲染目录名预览，走**与落盘完全同一条渲染路径**，
/// 保证用户"看到什么就下载成什么"。
///
/// 空字段列表返回**空串**（调用方显示"未勾选任何字段"的占位）——
/// 不能让它落到 [renderPixivDirectoryName] 的默认模板兜底上：
/// 那个兜底是"模板坏掉时的保险"，与"用户主动一个都没勾"是两回事，混起来会误导人。
String pixivDirNameTemplatePreview(List<String> fields, String separator) {
  if (fields.isEmpty) {
    return '';
  }
  return renderPixivDirectoryName(
    template: buildPixivDirNameTemplate(fields, separator),
    title: kPixivDirNamePreviewTitle,
    author: kPixivDirNamePreviewAuthor,
    id: kPixivDirNamePreviewId,
    pages: kPixivDirNamePreviewPages,
    fallback: kPixivDirNamePreviewId,
  );
}

/// 把 [order] 的第 [oldIndex] 项移动到 [newIndex]，返回新列表。
///
/// 语义与 `ReorderableListView.onReorder` 一致：它给的 `newIndex` 是
/// "**移除该项之前**的目标位置"，所以**向下拖时必须减一**，否则每次都会差一位。
/// 这是该控件最常见的坑，抽成纯函数才有测试守得住 —— 编辑器的 `onReorder`
/// 必须走这里，不要自己写 `removeAt` / `insert`。
///
/// 实现已挪到 [reorderTemplateFieldOrder]：32 号给插画卡片底部信息加了**同一套**
/// 勾选 + 排序交互，算法必须与这里逐字一致，所以留一份共用实现。
/// 本函数保留原名与签名（27 号计划的测试与调用点都不用改），只是转调。
List<String> reorderPixivDirNameFieldOrder(
  List<String> order,
  int oldIndex,
  int newIndex,
) {
  return reorderTemplateFieldOrder(order, oldIndex, newIndex);
}

/// 默认模板：标题在前、作品 ID 在后，沿用默认连字符分隔。
const String kDefaultPixivDirNameTemplate =
    '{title}$kDefaultPixivDirNameSeparator{id}';

/// 归一化模板值：空白（含未设置）一律回落到 [kDefaultPixivDirNameTemplate]。
///
/// 这一层与 [renderPixivDirectoryName] 内部对空模板的兜底**两道都要有**：
/// 前者保证设置数组里不留空白串，后者保证任何调用方直接传空也拿到合理结果。
String normalizePixivDirNameTemplate(String? value) {
  final trimmed = (value ?? '').trim();
  return trimmed.isEmpty ? kDefaultPixivDirNameTemplate : trimmed;
}

/// 模板变量名 → 取值。
const List<String> kPixivDirNameVariables = <String>[
  'title',
  'author',
  'id',
  'pages',
];

/// 可参与目录名的字段，**顺序即设置页弹窗里的初始排列**。
///
/// 与 [kPixivDirNameVariables] 是同一批字段，但语义不同：那个是"渲染时能替换哪些变量"，
/// 这个/以及下面的标签表是"设置页要列出哪些可勾选字段"。加第五个变量时三处要一起改，
/// 所以字段表与标签表都放在本文件，避免 UI 与解析各改一半。
const List<String> kPixivDirNameFieldKeys = <String>[
  'author',
  'title',
  'id',
  'pages',
];

/// 字段 → 设置页展示名。
const Map<String, String> kPixivDirNameFieldLabels = <String, String>{
  'title': '标题',
  'author': '作者',
  'id': '作品 ID',
  'pages': '页数',
};

/// 模板里的变量占位符。**渲染与解析共用同一个正则** —— 两处各写一份的话，
/// 加字段时很容易只改一处，症状是"设置页勾得上、渲染时不生效"。
final RegExp _pixivDirNameVariablePattern =
    RegExp(r'\{(title|author|id|pages)\}');

/// 分隔符默认值。
const String kDefaultPixivDirNameSeparator = '-';

/// 分隔符候选（第一项为默认）。空串 = 字段之间不加任何字符。
const List<String> kPixivDirNameSeparators = <String>['-', '_', ' ', ''];

/// 按 [fields] 的顺序、用 [separator] 连接，生成目录名模板串。
///
/// 空列表返回空串；空模板在 [renderPixivDirectoryName] 里会退回默认模板，
/// 所以调用方若要表达"一个字段都没选"，应自己拦在保存之前（设置页就是这么做的）。
String buildPixivDirNameTemplate(List<String> fields, String separator) {
  return fields.map((key) => '{$key}').join(separator);
}

/// 解析目录名模板 → （勾选的字段按出现顺序、字段间的分隔符）。
///
/// 这是"勾选 + 拖拽排序"能落回**既有持久化格式**的桥：`settings[153]` 里存的仍然是
/// 模板字符串，设置页只是它的另一个编辑入口 —— 因此**不需要数据迁移**，
/// 老值（含用户手写过的模板）也能被还原成勾选与顺序。
///
/// 规则：
/// - 字段按模板里的**出现顺序**返回 —— 这正是"排序"能被保存并还原的关键，
///   不能按固定顺序返回，否则用户排好的顺序一存一读就丢了；
/// - 重复出现的字段**保序去重**（`{title}_{title}` 只算一个 `title`）；
/// - 分隔符取「第一个字段结束 → 第二个字段开始」之间的**原文**；
///   不足两个字段时分隔符无意义，返回 [kDefaultPixivDirNameSeparator]；
/// - **一个字段都解析不出**（例如历史值是 `{foo}`）→ 退回标题 + ID 的默认规格。
///   **不抛错、不返回空** —— 用户不该因为一个坏值看到弹窗变空、或把设置写坏。
({List<String> fields, String separator}) parsePixivDirNameTemplate(
  String template,
) {
  final matches = _pixivDirNameVariablePattern
      .allMatches(template)
      .toList(growable: false);
  final seen = <String>{};
  final fields = <String>[];
  for (final match in matches) {
    final key = match.group(1)!;
    if (seen.add(key)) {
      fields.add(key);
    }
  }
  if (fields.isEmpty) {
    return parsePixivDirNameTemplate(kDefaultPixivDirNameTemplate);
  }
  // 用 matches（而非去重后的 fields）取间隙：`{title}_{title}` 这种重复写法，
  // 间隙仍是 `_`，取它比取"去重后两字段之间的整段"更贴近用户写下的意图。
  final separator = matches.length >= 2
      ? template.substring(matches[0].end, matches[1].start)
      : kDefaultPixivDirNameSeparator;
  return (fields: fields, separator: separator);
}

/// 单个路径段的**字节**上限。
///
/// ext4 / f2fs 是 255 字节；中日文在 UTF-8 下一个字 3 字节，所以中文标题约 85 字
/// 就会超限。超限时系统报错很难懂，这里主动截断。
const int _kMaxSegmentBytes = 255;

/// **页数 → 后缀**的唯一实现（下载目录名模板与插画卡片「页数」字段共用）。
///
/// - `1` 页（单图）→ `p0`；
/// - `n > 1` 页 → `p{n}`；
/// - 未知（`0` / `null` / 负数）→ **空串**（调用方据空串跳过这一项）。
///
/// 为什么单图是 `p0` 而不是 `p1`：这是**用户明确要求的产物命名约定**（真机反馈，
/// 单图产物形如 `..._p0.jpg`）。两套记号刻意不统一 —— `p0` 表示"这一本只有第 0 页"，
/// `p{n}` 表示"共 n 页"。**不要"顺手统一"成 `p$pages`**，那会让单图与用户既有命名不符。
///
/// 为什么未知页数给空串而不是 `p0`：那种情况本来就分不出单图还是多图，瞎猜会让
/// "未知"看起来像"确实是单图"；空串还会顺手把模板里 `{pages}` 前后的那段分隔符
/// 一起吃掉（见 [_joinPixivNameChunks]），避免留下 `作者_标题_id_.zip` 这种尾巴。
///
/// 为什么抽成公共函数：33 号要求插画卡片把 `1 页` 改成同口径的 `p{N}`。
/// 这个三分支是**用户拍板的约定**，两处各写一份的话，改一处漏一处就会让
/// "卡片显示的页数"和"下载目录名里的页数"对不上，而且不会报错。
String pixivPagesSuffix(int? pages) {
  final pageCount = pages ?? 0;
  if (pageCount <= 0) {
    return '';
  }
  return pageCount == 1 ? 'p0' : 'p$pageCount';
}

/// 按 [template] 渲染 Pixiv 下载的目录名（也是产物文件名的**基名**）。
///
/// 渲染顺序：**先替换变量（单遍），再做安全化**。
///
/// ⚠️ 替换必须是**单遍**的。早期实现是"对每个变量各做一次 `replaceAll`"的循环，
/// 那样前一个变量的替换结果会被后一个变量再扫一遍：标题里若含字面量 `{author}`
/// （同人作品名里并不罕见），`{title}` 展开出的 `{author}` 会被作者值吃掉，
/// 且不报错。测试 `test/pixiv_download_naming_test.dart` 锁住这个行为。
///
/// [pages] 是**作品页数**：单图（1 页）渲染成 `p0`，多图渲染成 `p{n}`。
///
/// 为什么由渲染层给 `p` 前缀，而不是让用户在模板里手写：模板 UI 是**勾选式**的
/// （只能选字段、选分隔符），没有"在变量前加字面量"的入口，所以 `p` 必须在这里补。
///
/// 为什么单图是 `p0` 而不是 `p1`：这是**用户明确要求的产物命名约定**（真机反馈，
/// 单图产物形如 `..._p0.jpg`）。两套记号刻意不统一 —— `p0` 表示"这一本只有第 0 页"，
/// `p{n}` 表示"共 n 页"。**不要"顺手统一"成 `p1`**，那会让单图与用户既有命名不符。
///
/// 页数未知（`0` / `null`）时给**空串**而不是 `p0`：那种情况本来就分不出单图还是多图，
/// 瞎猜会让"未知"看起来像"确实是单图"；空串还会顺手把 `{pages}` 前后的那段分隔符
/// 一起吃掉（见 [_joinPixivNameChunks]），避免留下 `作者_标题_id_.zip` 这种尾巴。
///
/// 结果保证：非空、无路径分隔符、无控制字符、字节数不超上限。
/// 全都清理完仍为空时，退回 [fallback]（通常是作品 ID），**绝不返回空串** ——
/// 空目录名会让下载落到根目录里，把别人的文件混进来。
String renderPixivDirectoryName({
  required String template,
  required String title,
  required String author,
  required String id,
  required int? pages,
  String fallback = '',
}) {
  var pattern = template.trim();
  if (pattern.isEmpty) {
    pattern = kDefaultPixivDirNameTemplate;
  }
  // 页数 → 后缀。三分支本体抽到 [pixivPagesSuffix]：插画卡片的「页数」字段
  // （33 号改成同一口径）也调它，两处共用一份，不会分叉。
  final values = <String, String>{
    'title': title.trim(),
    'author': author.trim(),
    'id': id.trim(),
    'pages': pixivPagesSuffix(pages),
  };
  // **单遍替换**：一次正则扫描把 `{变量}` 全部换掉。
  //
  // 不能写成"对每个变量各做一次 `replaceAll`"的循环 —— 那样**前一个变量的替换
  // 结果会被后一个变量的 replaceAll 再扫一遍**。例如标题本身含字面量 `{author}`
  // （同人作品名里并不罕见）时，`{title}` 展开出来的 `{author}` 会被作者值吃掉，
  // 目录名与模板预期不符，而且**不报错**。
  //
  // 这里先把模板切成"字面量段 / 变量段"，拼回时才多一步"空变量连分隔符一起吃掉"
  // 的清理（见 [_joinPixivNameChunks]）。切段时替换结果就已经定死，**单遍语义不变**。
  final chunks = <_PixivNameChunk>[];
  var cursor = 0;
  for (final match in _pixivDirNameVariablePattern.allMatches(pattern)) {
    if (match.start > cursor) {
      chunks.add(_PixivNameChunk.literal(pattern.substring(cursor, match.start)));
    }
    final key = match.group(1)!;
    chunks.add(_PixivNameChunk.variable(key, values[key] ?? match.group(0)!));
    cursor = match.end;
  }
  if (cursor < pattern.length) {
    chunks.add(_PixivNameChunk.literal(pattern.substring(cursor)));
  }
  final substituted = _joinPixivNameChunks(chunks);
  final rendered = sanitizeDirectorySegment(substituted);
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

/// 模板被切成的**最小片段**：`{变量}`，或两个变量之间的字面量（分隔符）。
class _PixivNameChunk {
  const _PixivNameChunk.literal(this.text)
      : isVariable = false,
        key = '';

  const _PixivNameChunk.variable(this.key, this.text) : isVariable = true;

  final bool isVariable;

  /// 变量名；字面量段为空串。
  final String key;

  /// 已渲染好的文本（变量段是取值，字面量段是原文）。
  final String text;
}

/// 把切好的片段拼回一个字符串，顺带清理"渲染成空的 `pages`"留下的分隔符。
///
/// **只对 `pages` 生效**，这是刻意的：
/// - `pages` 是唯一会**合法地**渲染成空的字段（页数未知/为 0），不吃掉分隔符就会
///   留下 `作者_标题_id_.zip` 这种尾巴；
/// - `title`/`author`/`id` 为空属于异常输入，而老模板恰好依赖"分隔符原样保留"
///   （`{title}-{author}` 且作者缺失 → `标题-`）。这条行为是回归红线：**一个字都不能改**。
///
/// 吃哪一段：优先吃**前一段**字面量（`{title}_{pages}` → `title`）；`pages` 在行首时
/// 没有前一段，改吃后一段（`{pages}_{title}` → `title`）。
String _joinPixivNameChunks(List<_PixivNameChunk> chunks) {
  final drop = List<bool>.filled(chunks.length, false);
  for (var i = 0; i < chunks.length; i++) {
    final chunk = chunks[i];
    if (!chunk.isVariable || chunk.key != 'pages' || chunk.text.isNotEmpty) {
      continue;
    }
    drop[i] = true;
    if (i > 0 && !chunks[i - 1].isVariable && !drop[i - 1]) {
      drop[i - 1] = true;
    } else if (i + 1 < chunks.length && !chunks[i + 1].isVariable) {
      drop[i + 1] = true;
    }
  }
  final buffer = StringBuffer();
  for (var i = 0; i < chunks.length; i++) {
    if (!drop[i]) {
      buffer.write(chunks[i].text);
    }
  }
  return buffer.toString();
}

/// 产物文件名 = 渲染出的基名 + 产物扩展名（`.zip` / `.jpg` …）。
///
/// 为什么要单独一个函数：扩展名与基名是**同一个路径段**，而
/// [renderPixivDirectoryName] 已经把基名截到 [_kMaxSegmentBytes] 字节 ——
/// 直接拼 `.zip` 就可能越界，文件系统报错很难懂。这里按"基名 + 扩展名 ≤ 上限"
/// 重新截一次，且复用同一套 UTF-8 截断（**不切碎多字节字符**）。
String buildPixivArtifactFileName({
  required String baseName,
  required String extension,
}) {
  final ext = extension.trim();
  final limit = _kMaxSegmentBytes - _utf8Length(ext);
  final trimmed = _truncateToBytes(baseName.trim(), limit < 1 ? 1 : limit);
  // 基名被截空时给固定名，绝不返回一个只剩扩展名的文件名 ——
  // `.zip` 这种"隐藏文件"在文件管理器里默认看不见。
  return '${trimmed.isEmpty ? 'pixiv' : trimmed}$ext';
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
