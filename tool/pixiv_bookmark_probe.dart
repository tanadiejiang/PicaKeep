/// Pixiv 写操作（收藏增删）诊断探针。
///
/// ## 什么时候用它
///
/// 真机上"收藏点了没反应 / 提示需要登录"时，应用日志只会给出
/// 「400 + 请重新登录」。这句文案**有误导性**：服务端在缺少写操作令牌时
/// 也这么回，而会话其实一直有效。这个探针用真机上的 Cookie 直接打真实请求，
/// 把下面几件事一次问清楚：
///
/// 1. 会话到底有没有效？（`GET /ajax/user/extra`，看状态码与 `x-userid` 响应头）
/// 2. 页面里的写操作令牌在哪？（当前是 `serverSerializedPreloadedState` 里的 `api.token`）
/// 3. 带上这个令牌 POST 能不能成功？
///
/// ## 用法
///
/// ```text
/// # 1. 从设备取出 Cookie 库（base64 避免二进制被 shell 破坏）
/// adb shell run-as <包名> base64 files/comic_source/pixiv_cookies.db > cookies.b64
///
/// # 2. 解码后运行
/// dart run tool/pixiv_bookmark_probe.dart cookies.db [illust_id]
/// ```
///
/// 需要网络能直连 pixiv（国内环境要先开代理）。
///
/// ## 安全约定
///
/// 只打印 Cookie 与令牌的**名称和长度**，绝不输出任何值，也不写任何文件。
/// 用完请把取出的 Cookie 库删掉。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

const String _base = 'https://www.pixiv.net';
const String _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      '用法: dart run tool/pixiv_bookmark_probe.dart <cookies.db> [illust_id]',
    );
    exit(2);
  }
  final dbPath = args.first;
  final illustId = args.length > 1 ? args[1] : '147110730';

  open.overrideFor(
    OperatingSystem.windows,
    () => DynamicLibrary.open(
      p.join(Directory.current.path, 'windows', 'sqlite3.dll'),
    ),
  );

  final cookies = _readCookies(dbPath);
  if (cookies.isEmpty) {
    stderr.writeln('Cookie 库里没有可用于 pixiv.net 的条目。');
    exit(1);
  }
  final cookieHeader =
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  print('Cookie 名称（共 ${cookies.length} 个）：${cookies.keys.join(', ')}');

  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 25),
  ));

  // ── 1. 会话有效性 ─────────────────────────────────────────────────────
  print('\n=== 1. 会话有效性 GET /ajax/user/extra ===');
  final session = await _get(
    dio,
    '$_base/ajax/user/extra',
    headers: {
      'Referer': '$_base/',
      'User-Agent': _ua,
      'Accept': 'application/json',
      'Cookie': cookieHeader,
    },
  );
  print('HTTP ${session.status}');
  print('响应: ${_clip(session.body)}');
  final userId = session.headers['x-userid']?.join(',');
  print('响应头 x-userid: ${userId ?? "无"}');
  print(userId == null
      ? '   ⚠️ 没有 x-userid —— 会话可能真的无效，先解决登录。'
      : '   ✅ 服务端认得这个用户：会话有效，后续失败与"未登录"无关。');

  // ── 2. 页面里的写操作令牌 ──────────────────────────────────────────────
  print('\n=== 2. 首页里的写操作令牌 ===');
  final home = await _get(
    dio,
    '$_base/',
    headers: {
      'Referer': '$_base/',
      'User-Agent': _ua,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Cookie': cookieHeader,
    },
  );
  print('HTTP ${home.status}  HTML 长度 ${home.body.length}');
  final token = _extractWriteToken(home.body);
  print(token == null
      ? '   没找到写操作令牌（api.token / meta csrf-token）'
      : '   找到令牌，长度 ${token.length}（值不打印）');

  if (token == null) {
    print('\n没有令牌就没法继续测 POST —— 请确认首页 HTML 结构是否变了。');
    return;
  }

  // ── 3. 带令牌的写操作 ─────────────────────────────────────────────────
  print('\n=== 3. POST /ajax/illusts/bookmarks/add（illust_id=$illustId）===');
  final added = await _post(
    dio,
    '$_base/ajax/illusts/bookmarks/add',
    {
      'comment': '',
      'illust_id': illustId,
      'restrict': 0,
      'tags': <String>[],
    },
    headers: {
      'Content-Type': 'application/json',
      'Origin': _base,
      'Referer': '$_base/artworks/$illustId',
      'User-Agent': _ua,
      'Accept': 'application/json, text/plain, */*',
      'Cookie': cookieHeader,
      'X-CSRF-Token': token,
    },
  );
  print('${added.status == 200 ? "✅" : "❌"} HTTP ${added.status}');
  print('响应: ${_clip(added.body)}');
  if (added.status == 200) {
    print('\n结论：令牌 + X-CSRF-Token 组合有效，收藏已写入。');
    print('（想撤销就跑一次 delete：把 URL 换成 bookmarks/delete、body 只留 illust_id。）');
  } else {
    print('\n结论：令牌不是问题所在，需要继续排查其它请求特征。');
  }
}

/// 按优先级从页面 HTML 里取写操作令牌。
///
/// 顺序与 `parsePixivCsrfTokenFromHtml` 保持一致，便于对照应用行为。
String? _extractWriteToken(String html) {
  final patterns = <RegExp>[
    RegExp(
      r'''<meta[^>]+name=["']csrf-token["'][^>]+content=["']([^"']+)["']''',
      caseSensitive: false,
    ),
    RegExp(
      r'''<meta[^>]+content=["']([^"']+)["'][^>]+name=["']csrf-token["']''',
      caseSensitive: false,
    ),
    RegExp(
      r'\\?"api\\?"\s*:\s*\{[^{}]{0,160}?\\?"token\\?"\s*:\s*\\?"([^"\\]{8,})',
      caseSensitive: false,
    ),
    RegExp(r'"csrfToken"\s*:\s*"([^"]+)"', caseSensitive: false),
  ];
  for (final pattern in patterns) {
    final value = pattern.firstMatch(html)?.group(1)?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

Map<String, String> _readCookies(String dbPath) {
  final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  try {
    final rows = db.select('select name, value, domain from cookies');
    final result = <String, String>{};
    for (final row in rows) {
      final domain = (row['domain'] as String? ?? '').trim();
      if (!domain.contains('pixiv')) continue;
      final name = (row['name'] as String? ?? '').trim();
      final value = (row['value'] as String? ?? '').trim();
      if (name.isEmpty || value.isEmpty) continue;
      result[name] = value;
    }
    return result;
  } finally {
    db.dispose();
  }
}

class _ProbeResponse {
  const _ProbeResponse(this.status, this.body, this.headers);
  final int status;
  final String body;
  final Map<String, List<String>> headers;
}

Future<_ProbeResponse> _get(
  Dio dio,
  String url, {
  required Map<String, String> headers,
}) async {
  try {
    final response = await dio.get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        headers: headers,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    return _ProbeResponse(
      response.statusCode ?? 0,
      response.data ?? '',
      response.headers.map,
    );
  } catch (e) {
    return _ProbeResponse(0, '请求异常: $e', const {});
  }
}

Future<_ProbeResponse> _post(
  Dio dio,
  String url,
  Map<String, dynamic> body, {
  required Map<String, String> headers,
}) async {
  try {
    final response = await dio.post<String>(
      url,
      data: jsonEncode(body),
      options: Options(
        responseType: ResponseType.plain,
        headers: headers,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    return _ProbeResponse(
      response.statusCode ?? 0,
      response.data ?? '',
      response.headers.map,
    );
  } catch (e) {
    return _ProbeResponse(0, '请求异常: $e', const {});
  }
}

String _clip(String text, [int max = 220]) {
  final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return normalized.length <= max
      ? normalized
      : '${normalized.substring(0, max)}…';
}
