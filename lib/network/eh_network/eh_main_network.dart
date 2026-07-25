import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/app_dio.dart';
import 'package:picakeep/network/cookie_jar.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/eh_network/get_gallery_id.dart';
import 'package:picakeep/network/eh_network/js.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/tools/extensions.dart';

/// e-hentai / exhentai 站点的全部 HTTP 交互单例。
///
/// 移植自上游 PicaComic 的 `EhNetwork`，按 PicaKeep 网络骨架（logDio +
/// 自实现 CookieJarSql + Res<T>）重写，并解耦了上游对 `ehentai` comic_source
/// 对象的依赖（源注册归 08 计划）。HTML 解析逻辑与容错 try/catch 逐行照搬。
class EhNetwork {
  factory EhNetwork() => _cache ??= EhNetwork._create();

  static EhNetwork? _cache;

  EhNetwork._create() {
    folderNames = List.generate(10, (index) => 'Favorite $index');
    getCookies(true);
  }

  /// 收藏夹名（运行期由收藏夹页解析回填；08 接入源后可改为持久化）。
  late List<String> folderNames;

  /// 站点根 URL：settings[20]=='0' 普通站，否则里站（公共契约）。
  String get ehBaseUrl => appdata.settings[20] == '0'
      ? 'https://e-hentai.org'
      : 'https://exhentai.org';

  /// api.php 地址（随站点切换）。
  String get ehApiUrl => appdata.settings[20] == '0'
      ? 'https://api.e-hentai.org/api.php'
      : 'https://exhentai.org/api.php';

  /// ehentai 全链路统一 User-Agent：取 Webview 登录时抓到并回填的真实 UA
  /// （appdata.implicitData[3]，默认值即 const webUA）。
  /// 抓 cookie 与后续 API/图片请求必须用同一 UA，否则里站 / imagedispatch
  /// 解密可能因 UA 不一致被风控拒绝。网络层与详情页/阅读器/下载器都应取此值。
  static String get ehUA {
    final ua = appdata.implicitData[3];
    return ua.isNotEmpty ? ua : webUA;
  }

  /// 独立 CookieJar（公共契约铁律：禁用 SingleInstanceCookieJar，避免多源串库）。
  final cookieJar = CookieJarSql(
    '${App.dataPath}${Platform.pathSeparator}comic_source'
    '${Platform.pathSeparator}eh_cookies.db',
  );

  /// 给图片加载 / api.php 手动塞 Header 用的 Cookie 字符串。
  String cookiesStr = '';

  // 账号详情页面显示用（04 登录后回填）。
  String id = '';
  String hash = '';
  String igneous = '';

  /// 是否已登录：cookieJar 中存在 ipb_member_id 即视为已登录。
  ///
  /// 注：源级登录态（data['token']）由 08 接入 comic_source 后统一判定，
  /// 本计划网络层仅按 cookie 存在性做自洽判断。
  bool get isLogin {
    final cookies = cookieJar.loadForRequest(Uri.parse(ehBaseUrl));
    return cookies.any((c) => c.name == 'ipb_member_id' && c.value.isNotEmpty);
  }

  /// 读取 / 刷新当前身份 cookie，拼成 [cookiesStr]。
  ///
  /// [setNW] 决定是否写入 nw=1（绕过 Content Warning）。
  Future<String> getCookies(bool setNW, [String? url]) async {
    url ??= ehBaseUrl;

    var shouldAdd = <Cookie>[
      if (setNW) Cookie('nw', '1') else Cookie('nw', '0'),
      if (appdata.settings[75] != '' && appdata.settings[75] != '0')
        Cookie('sp', appdata.settings[75]),
    ];
    cookieJar.saveFromResponse(Uri.parse(url), shouldAdd);

    var cookies = cookieJar.loadForRequest(Uri.parse(url));

    var res = '';
    for (var cookie in cookies) {
      res += '${cookie.name}=${cookie.value}; ';
      if (cookie.name == 'ipb_member_id') {
        id = cookie.value;
      } else if (cookie.name == 'ipb_pass_hash') {
        hash = cookie.value;
      } else if (cookie.name == 'igneous') {
        igneous = cookie.value;
      }
    }
    if (res.length < 2) {
      cookiesStr = '';
      return '';
    }
    cookiesStr = res.substring(0, res.length - 2);
    return cookiesStr;
  }

  /// 页 HTML 内存缓存：仅供 [useCache] 显式开启的调用方使用。
  ///
  /// 【安全约束】只能缓存列表/画廊列表类只读页。取 showKey/imgKey/api 等鉴权
  /// 相关请求绝不能传 useCache=true——EH 的 showKey/imgKey 有时效，缓存这类
  /// 页面会导致复用过期 key 而下载失败。key = 请求 URL，value = 响应体 +
  /// 写入时刻，TTL 5 分钟，容量上限 [_htmlCacheMaxSize]，超出按最旧淘汰。
  final Map<String, ({DateTime at, String body})> _htmlCache = {};

  static const Duration _htmlCacheTtl = Duration(minutes: 5);
  static const int _htmlCacheMaxSize = 64;

  void _putHtmlCache(String url, String body) {
    if (_htmlCache.length >= _htmlCacheMaxSize &&
        !_htmlCache.containsKey(url)) {
      String? oldestKey;
      DateTime? oldestAt;
      for (final entry in _htmlCache.entries) {
        if (oldestAt == null || entry.value.at.isBefore(oldestAt)) {
          oldestAt = entry.value.at;
          oldestKey = entry.key;
        }
      }
      if (oldestKey != null) {
        _htmlCache.remove(oldestKey);
      }
    }
    _htmlCache[url] = (at: DateTime.now(), body: body);
  }

  /// 共享下载 dio 的首次初始化参数（[sharedDownloadDio] 的 options 仅首次生效）。
  ///
  /// dio 5.x 的 per-request [Options] 不含 connectTimeout，该字段只能配在
  /// BaseOptions 上，而共享实例被「EH 页 HTML 请求」与「图片字节下载」共用，
  /// 故取两者折中的 15s：比 EH 页原先的 8s 略宽松，但对原本完全没有连接超时
  /// 的字节下载是收紧。online_download_manager.dart 的调用点必须传相同值，
  /// 这样无论哪一侧先触发初始化，最终配置都一致。
  static BaseOptions sharedDownloadBaseOptions() =>
      BaseOptions(connectTimeout: const Duration(seconds: 15));

  /// 从 url 获取 HTML 文本，请求时设置 cookie。
  ///
  /// 失效判定覆盖：空数据 / bounce_login / IP ban / redirect loop。
  ///
  /// [useCache] 默认关闭；仅列表/画廊列表类只读页可显式传 true 走内存缓存
  /// （见 [_htmlCache] 文档的安全约束），其余调用方（尤其取 showKey/imgKey/
  /// api 的请求）必须保持默认值，禁止缓存鉴权相关页面。
  Future<Res<String>> request(
    String url, {
    Map<String, String>? headers,
    bool setNW = true,
    bool useCache = false,
  }) async {
    if (useCache) {
      final cached = _htmlCache[url];
      if (cached != null &&
          DateTime.now().difference(cached.at) < _htmlCacheTtl) {
        return Res(cached.body);
      }
    }
    await getCookies(setNW, url);
    // 共享下载 dio：复用连接池/keep-alive，避免每页 HTML 都重新 TLS 握手。
    // 注意不能往共享实例上 add(CookieManagerSql)——共享 dio 被多源下载复用，
    // 挂拦截器既会随每次调用无界累积，也会把其它源响应的 set-cookie 写进 EH
    // 库（违反「禁用共享 cookieJar」契约）。故这里把拦截器的两步（请求前注入
    // cookie header、响应后落库 set-cookie）就地内联，语义与原先一致。
    final dio = sharedDownloadDio(options: sharedDownloadBaseOptions());
    final requestUri = Uri.parse(url);
    final cookieHeader = cookieJar.loadForRequestCookieHeader(requestUri);
    try {
      var res = await dio.get<String>(
        url,
        options: Options(
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
          followRedirects: true,
          responseType: ResponseType.plain,
          headers: {
            'user-agent': ehUA,
            ...?headers,
            'host': requestUri.host,
            if (cookieHeader.isNotEmpty) 'cookie': cookieHeader,
          },
        ),
      );
      cookieJar.saveFromResponseCookieHeader(
        res.requestOptions.uri,
        res.headers['set-cookie'] ?? const <String>[],
      );
      var data = res.data ?? '';
      if (data.isEmpty) {
        throw Exception('Empty Data. '
            'No permission to access this page.\n'
            'Please check your account and cookie.');
      }

      if (res.realUri.toString().contains('bounce_login.php')) {
        throw Exception('未登录或登录到期');
      }

      await getCookies(true);
      if (data.length >= 4 && data.substring(0, 4) == 'Your') {
        return const Res(null,
            errorMessage: 'Your IP address has been temporarily banned');
      }
      if (useCache) {
        _putHtmlCache(url, data);
      }
      return Res(data);
    } on DioException catch (e) {
      String? message;
      if (e.type != DioExceptionType.unknown) {
        message = e.message ?? '未知';
      } else {
        message = e.toString().split('\n').elementAtOrNull(1);
      }
      return Res(null, errorMessage: message ?? 'Network Error');
    } catch (e) {
      String? message;
      if (e.toString() != 'null') {
        message = e.toString();
      }
      if (message?.contains('Redirect loop') ?? false) {
        message = 'Redirect loop: No permission to view this page. \n'
            'Check your account and cookie.';
      }
      return Res(null, errorMessage: message ?? 'Network Error');
    }
  }

  /// ehentai api.php 请求（POST JSON）。
  ///
  /// api.php 不走自动 cookieJar 注入，需在 Header 里手填 [cookiesStr]。
  Future<Res<String>> apiRequest(
    Map<String, dynamic> data, {
    Map<String, String>? headers,
  }) async {
    await getCookies(false, ehApiUrl);
    var dio = logDio(BaseOptions());
    try {
      var res = await dio.post<String>(
        ehApiUrl,
        data: data,
        options: Options(headers: {
          'user-agent': ehUA,
          ...?headers,
          'host': Uri.parse(ehBaseUrl).host,
          'Cookie': cookiesStr,
        }),
      );
      return Res(res.data);
    } on DioException catch (e) {
      String? message;
      if (e.type != DioExceptionType.unknown) {
        message = e.message ?? '未知';
      } else {
        message = e.toString().split('\n').elementAtOrNull(1);
      }
      return Res(null, errorMessage: message ?? 'Network Error');
    } catch (e) {
      String? message;
      if (e.toString() != 'null') {
        message = e.toString();
      }
      return Res(null, errorMessage: message ?? 'Network Error');
    }
  }

  /// 表单 POST，接受 302 重定向，挂 CookieManagerSql 让响应 set-cookie 落库。
  Future<Res<String>> post(
    String url,
    dynamic data, {
    Map<String, String>? headers,
  }) async {
    await getCookies(true, url);
    var options = BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      sendTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      receiveDataWhenStatusError: true,
      validateStatus: (status) => status == 200 || status == 302,
      responseType: ResponseType.plain,
      headers: {'user-agent': ehUA, ...?headers},
    );
    var dio = logDio(options)..interceptors.add(CookieManagerSql(cookieJar));
    try {
      var res = await dio.post<String>(url, data: data);
      return Res(res.data ?? '');
    } on DioException catch (e) {
      String? message;
      if (e.type != DioExceptionType.unknown) {
        message = e.message ?? '未知';
      } else {
        message = e.toString().split('\n').elementAtOrNull(1);
      }
      return Res(null, errorMessage: message ?? 'Network Error');
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'Network', '$e\n$s');
      String? message;
      if (e.toString() != 'null') {
        message = e.toString();
      }
      return Res(null, errorMessage: message ?? 'Network Error');
    }
  }

  /// 校验当前 cookie 是否构成有效登录态（供 04 登录链路使用）。
  ///
  /// GET home.php 且 `followRedirects: false`：已登录返回 200，未登录会 302
  /// 跳回登录页。解耦了上游对 ehentai comic_source 的依赖（仅返回 bool）。
  /// 抓取当前登录用户名。
  ///
  /// 移植自上游：请求 forums.e-hentai.org 首页，解析 div#userlinks > p.home > b > a。
  /// 返回真实用户名；失败或解析不到返回 null（调用方决定是否写入 source.data，
  /// 网络层不依赖 comic_source 以保持解耦）。
  Future<String?> getUserName() async {
    const url = 'https://forums.e-hentai.org/';
    final options = BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      sendTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      validateStatus: (status) => true,
      responseType: ResponseType.plain,
      headers: {
        'referer': 'https://forums.e-hentai.org/index.php?',
        'accept-language': 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7',
        'user-agent': ehUA,
      },
    );
    final dio = logDio(options)..interceptors.add(CookieManagerSql(cookieJar));
    try {
      final res = await dio.get<String>(url);
      if (res.statusCode != 200 || res.data == null) {
        return null;
      }
      final html = parse(res.data);
      final name = html.querySelector('div#userlinks > p.home > b > a');
      final text = name?.text.trim() ?? '';
      return text.isEmpty ? null : text;
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'Network', '$e\n$s');
      return null;
    }
  }

  Future<bool> validateCookies() async {
    final url = '$ehBaseUrl/home.php';
    await getCookies(false, url);
    final options = BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      sendTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      followRedirects: false,
      validateStatus: (status) => true,
      responseType: ResponseType.plain,
      headers: {'user-agent': ehUA},
    );
    final dio = logDio(options)..interceptors.add(CookieManagerSql(cookieJar));
    try {
      final res = await dio.get<String>(url);
      return res.statusCode == 200;
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'Network', '$e\n$s');
      return false;
    }
  }

  /// 解析星星 html 元素的位置属性，返回评分。
  double getStarsFromPosition(String position) {
    int i = 0;
    while (position[i] != ';') {
      i++;
      if (i == position.length) {
        break;
      }
    }
    switch (position.substring(0, i)) {
      case 'background-position:0px -1px':
        return 5;
      case 'background-position:0px -21px':
        return 4.5;
      case 'background-position:-16px -1px':
        return 4;
      case 'background-position:-16px -21px':
        return 3.5;
      case 'background-position:-32px -1px':
        return 3;
      case 'background-position:-32px -21px':
        return 2.5;
      case 'background-position:-48px -1px':
        return 2;
      case 'background-position:-48px -21px':
        return 1.5;
      case 'background-position:-64px -1px':
        return 1;
      case 'background-position:-64px -21px':
        return 0.5;
    }
    return 0.5;
  }

  /// 从一个列表页链接中获取所有画廊，同时获得下一页游标。
  ///
  /// 支持四种排版：compact(gltc) / thumbnail(gl1t) / extended(glte) / minimal(gltm)。
  Future<Res<Galleries>> getGalleries(
    String url, {
    bool favoritePage = false,
  }) async {
    var res = await request(url);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var galleries = <EhGalleryBrief>[];

      // compact mode
      for (var item
          in document.querySelectorAll('table.itg.gltc > tbody > tr')) {
        try {
          var type = item.children[0].children[0].text;
          var time = item.children[1].children[2].children[0].text;
          var stars = getStarsFromPosition(
              item.children[1].children[2].children[1].attributes['style']!);
          var cover = item.children[1].children[1].children[0].children[0]
              .attributes['src'];
          if (cover![0] == 'd') {
            cover = item.children[1].children[1].children[0].children[0]
                .attributes['data-src'];
          }
          var title = item.children[2].children[0].children[0].text;
          var link = item.children[2].children[0].attributes['href'];
          String uploader = '';
          int? pages;
          try {
            uploader = item.children[3].children[0].children[0].text;
            pages = int.parse(item.children[3].children[1].text.nums);
          } catch (e) {
            // 收藏夹页没有 uploader
          }
          var tags = <String>[];
          for (var node in item.children[2].children[0].children[1].children) {
            tags.add(node.attributes['title']!);
          }

          galleries.add(EhGalleryBrief(
              title, type, time, uploader, cover!, stars, link!, tags,
              pages: pages));
        } catch (e) {
          // 表格中存在空行或者被屏蔽
          continue;
        }
      }

      // Thumbnail mode
      for (var item in document.querySelectorAll('div.gl1t')) {
        try {
          final title = item.querySelector('a')?.text ?? 'Unknown';
          final type =
              item.querySelector('div.gl5t > div > div.cs')?.text ?? 'Unknown';
          final time = item
                  .querySelectorAll('div.gl5t > div > div')
                  .firstWhereOrNull(
                      (element) => DateTime.tryParse(element.text) != null)
                  ?.text ??
              'Unknown';
          final coverPath = item.querySelector('img')?.attributes['src'] ?? '';
          final stars = getStarsFromPosition(item
                  .querySelector('div.gl5t > div > div.ir')
                  ?.attributes['style'] ??
              '');
          final link = item.querySelector('a')?.attributes['href'] ?? '';
          final pages = int.tryParse(item
                  .querySelectorAll('div.gl5t > div > div')
                  .firstWhereOrNull((element) => element.text.contains('pages'))
                  ?.text
                  .nums ??
              '');
          galleries.add(EhGalleryBrief(
              title, type, time, '', coverPath, stars, link, [],
              pages: pages));
        } catch (e) {
          // 忽视
        }
      }

      // Extended mode
      for (var item
          in document.querySelectorAll('table.itg.glte > tbody > tr')) {
        try {
          final title =
              item.querySelector('td.gl2e > div > a > div > div.glink')?.text ??
                  'Unknown';
          final type =
              item.querySelector('td.gl2e > div > div.gl3e > div.cn')?.text ??
                  'Unknown';
          final time = item
                  .querySelectorAll('td.gl2e > div > div.gl3e > div')
                  .firstWhereOrNull(
                      (element) => DateTime.tryParse(element.text) != null)
                  ?.text ??
              'Unknown';
          final uploader =
              item.querySelector('td.gl2e > div > div.gl3e > div > a')?.text ??
                  'Unknown';
          final coverPath = item
                  .querySelector('td.gl1e > div > a > img')
                  ?.attributes['src'] ??
              '';
          final stars = getStarsFromPosition(item
                  .querySelector('td.gl2e > div > div.gl3e > div.ir')
                  ?.attributes['style'] ??
              '');
          final link =
              item.querySelector('td.gl1e > div > a')?.attributes['href'] ?? '';
          final tags = item
              .querySelectorAll('div.gt, div.gtl')
              .map((e) => e.attributes['title'] ?? '')
              .toList();
          final pages = int.tryParse(item
                  .querySelectorAll('td.gl2e > div > div.gl3e > div')
                  .firstWhereOrNull((element) => element.text.contains('pages'))
                  ?.text
                  .nums ??
              '');
          galleries.add(EhGalleryBrief(
              title, type, time, uploader, coverPath, stars, link, tags,
              pages: pages));
        } catch (e) {
          // 忽视
        }
      }

      // minimal mode
      for (var item
          in document.querySelectorAll('table.itg.gltm > tbody > tr')) {
        try {
          final title =
              item.querySelector('td.gl3m > a > div.glink')?.text ?? 'Unknown';
          final type =
              item.querySelector('td.gl1m > div.cs')?.text ?? 'Unknown';
          final time = item
                  .querySelectorAll('td.gl2m > div')
                  .firstWhereOrNull(
                      (element) => DateTime.tryParse(element.text) != null)
                  ?.text ??
              'Unknown';
          final uploader =
              item.querySelector('td.gl5m > div > a')?.text ?? 'Unknown';
          var coverPath = item
              .querySelector('td.gl2m > div > div > img')
              ?.attributes['src'];
          final link =
              item.querySelector('td.gl3m > a')?.attributes['href'] ?? '';
          final stars = getStarsFromPosition(
              item.querySelector('td.gl4m > div.ir')?.attributes['style'] ??
                  '');
          galleries.add(EhGalleryBrief(
              title, type, time, uploader, coverPath ?? '', stars, link, []));
        } catch (e) {
          // 忽视
        }
      }

      var g = Galleries();
      var nextButton = document.getElementById('dnext');
      if (nextButton == null) {
        g.next = null;
      } else {
        g.next = nextButton.attributes['href'];
      }
      g.galleries = galleries;

      // 获取收藏夹名称
      if (favoritePage && isLogin) {
        var names = <String>[];
        try {
          var folderDivs = document.querySelectorAll('div.fp');
          for (var folderDiv in folderDivs) {
            var name = folderDiv.children.elementAtOrNull(2)?.text ??
                'Favorite ${names.length}';
            var length = folderDiv.children.elementAtOrNull(0)?.text;
            if (length != null) {
              length = ' ($length)';
            }
            length ??= '';
            names.add('$name$length');
          }
          if (names.length > 10) {
            names = names.sublist(0, 10);
          }
          if (names.length == 10) {
            folderNames = names;
          }
        } catch (e) {
          // 忽视
        }
        return Res(g, subData: folderNames);
      }
      return Res(g);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'Data Analysis', '$e\n$s');
      return Res(null, errorMessage: e.toString());
    }
  }

  /// 获取列表的下一页并追加到 [galleries]。
  Future<bool> getNextPageGalleries(Galleries galleries) async {
    if (galleries.next == null) return true;
    var next = await getGalleries(galleries.next!);
    if (next.error) return false;
    galleries.galleries.addAll(next.data.galleries);
    galleries.next = next.data.next;
    return true;
  }

  Comment _parseComment(dom.Element e) {
    var name = e
            .getElementsByClassName('c3')[0]
            .getElementsByTagName('a')
            .elementAtOrNull(0)
            ?.text ??
        '未知';
    var time = e
            .getElementsByClassName('c3')
            .elementAtOrNull(0)
            ?.text
            .split('Posted on')
            .elementAtOrNull(1)
            ?.split('by')
            .elementAtOrNull(0)
            ?.trim() ??
        'unknown';
    var content = e.getElementsByClassName('c6')[0].text;
    var score = int.parse(e.querySelector('div.c5 > span')?.text ?? '0');
    var id = e.previousElementSibling?.attributes['name']?.nums ?? '0';
    bool voteUp = e
            .querySelector('a#comment_vote_up_$id')
            ?.attributes['style']
            ?.isNotEmpty ==
        true;
    bool voteDown = e
            .querySelector('a#comment_vote_down_$id')
            ?.attributes['style']
            ?.isNotEmpty ==
        true;
    bool? vote;
    if (voteUp) {
      vote = true;
    } else if (voteDown) {
      vote = false;
    }
    return Comment(id, name, content, time, score, vote);
  }

  /// 从画廊详情页链接获取完整 [Gallery]（最重的解析块，逐解析项保留 try/catch）。
  Future<Res<Gallery>> getGalleryInfo(String link, [bool setNW = true]) async {
    try {
      var res = await request(link, setNW: setNW);
      if (res.error) {
        return Res(null, errorMessage: res.errorMessage);
      }
      if (res.data.contains('Content Warning') &&
          res.data.contains('Never Warn Me Again')) {
        return const Res(null, errorMessage: 'Content Warning');
      }
      var document = parse(res.data);
      // tags：按 namespace 分桶
      var tags = <String, List<String>>{};
      var tagLists =
          document.querySelectorAll('div#taglist > table > tbody > tr');
      for (var tr in tagLists) {
        var list = <String>[];
        for (var div in tr.children[1].children) {
          list.add(div.children[0].attributes['onclick']!
              .split(':')[1]
              .split("'")[0]);
        }
        tags[tr.children[0].text.substring(0, tr.children[0].text.length - 1)] =
            list;
      }
      String maxPage = '1';

      for (var element in document.querySelectorAll('td.gdt2')) {
        if (element.text.contains('pages')) {
          maxPage = element.text.nums;
        }
      }

      bool favorite = true;
      if (document.getElementById('favoritelink')?.text ==
          ' Add to Favorites') {
        favorite = false;
      }
      var coverPath = document
          .querySelector('div#gleft > div#gd1 > div')!
          .attributes['style']!;
      coverPath =
          RegExp(r'https?://([-a-zA-Z0-9.]+(/\S*)?\.(?:jpg|jpeg|gif|png|webp))')
              .firstMatch(coverPath)![0]!;
      // 评论
      var comments = <Comment>[];
      for (var c in document.getElementsByClassName('c1')) {
        comments.add(_parseComment(c));
      }
      // 上传者
      var uploader =
          document.getElementById('gdn')!.children.elementAtOrNull(0)?.text ??
              '未知';

      // 星星
      var stars = getStarsFromPosition(
          document.getElementById('rating_image')!.attributes['style']!);

      // 平均分数
      var rating = document.getElementById('rating_label')?.text;
      // 类型
      var type = document.getElementsByClassName('cs')[0].text;
      // 时间
      var time = document
          .querySelector('div#gdd > table > tbody > tr > td.gdt2')!
          .text;
      // 身份认证数据
      var auth = getVariablesFromJsCode(res.data);
      var thumbnailUrls = <String>[];
      var title = document.querySelector('h1#gn')!.text;
      var subTitle = document.querySelector('h1#gj')?.text;
      if (subTitle != null && subTitle.removeAllBlank == '') {
        subTitle = null;
      }

      var pageSize = 20;
      var width = 200;
      var ext = 'webp';

      // Small Thumbnails on Page 0 (if exist)
      var smallThumbnails =
          document.querySelectorAll('div#gdt.gt100 > a > div');
      if (smallThumbnails.isNotEmpty) {
        // Merged
        var div = smallThumbnails[0].children.isEmpty
            ? smallThumbnails[0]
            : smallThumbnails[0].children[0];
        var style = div.attributes['style'];
        width = 100;
        pageSize = ext == 'webp' ? 40 : 20;
        var r = style!.split('background:transparent url(')[1];
        var totalPages = document
            .querySelectorAll('table.ptt > tbody > tr > td > a')
            .where((element) => element.text.isNum)
            .last
            .text;
        var url = r.split(')')[0];
        ext = url.substring(url.lastIndexOf('.') + 1);
        auth['thumbnailKey'] = '$url $totalPages';
      }

      // Large Thumbnails on Page 0 (if exist)
      var largeThumbnails =
          document.querySelectorAll('div#gdt.gt200 > a > div');
      if (largeThumbnails.isNotEmpty) {
        pageSize = 20;
        var div = largeThumbnails[0].children.isEmpty
            ? largeThumbnails[0]
            : largeThumbnails[0].children[0];
        var style = div.attributes['style'];
        width = 200;
        var r = style!.split('background:transparent url(')[1];
        if (r.contains('px')) {
          // Merged
          var totalPages = document
              .querySelectorAll('table.ptt > tbody > tr > td > a')
              .where((element) => element.text.isNum)
              .last
              .text;
          var url = r.split(')')[0];
          ext = url.substring(url.lastIndexOf('.') + 1);
          auth['thumbnailKey'] = '$url $totalPages';
        } else {
          // Stand-alone (legacy)
          var totalPages = document
              .querySelectorAll('table.ptt > tbody > tr > td > a')
              .where((element) => element.text.isNum)
              .last
              .text;
          auth['thumbnailKey'] = 'large thumbnail: $totalPages';
          thumbnailUrls.addAll(largeThumbnails.map((div) {
            div = div.children.isEmpty ? div : div.children[0];
            return div.attributes['style']!
                .split('background:transparent url(')[1]
                .split(')')[0];
          }));
        }
      }

      var archiveDownload = document
          .querySelectorAll('a')
          .firstWhereOrNull((element) => element.text == 'Archive Download')
          ?.attributes['onclick'];
      if (archiveDownload != null) {
        archiveDownload = archiveDownload.split("'")[1];
        if (archiveDownload.isURL) {
          auth['archiveDownload'] = archiveDownload;
        }
      }
      return Res(Gallery(
        title,
        type,
        time,
        uploader,
        stars,
        rating,
        coverPath,
        tags,
        comments,
        auth,
        favorite,
        link,
        maxPage,
        pageSize,
        thumbnailUrls,
        ext,
        width,
        subTitle,
      ));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'Data Analysis', '$e\n$s');
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<List<Comment>>> getComments(String url) async {
    var res = await request('$url?hc=1');
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var resComments = <Comment>[];
      var comments = document.getElementsByClassName('c1');
      for (var c in comments) {
        resComments.add(_parseComment(c));
      }
      return Res(resComments);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'Data Analysis', '$e\n$s');
      return Res(null, errorMessage: e.toString());
    }
  }

  Set<String> loadingReaderLinks = {};

  /// ehgt.org 在途请求计数（公共契约铁律：ehgt.org 限 3 并发，封面/缩略图/页图共用）。
  ///
  /// 沿用上游 `ImageManager.ehgtLoading` 语义。指向 ehgt.org 的图片请求进入前
  /// 经 [acquireEhgtSlot] 获取配额，完成后 [releaseEhgtSlot] 释放。
  int ehgtLoading = 0;

  /// 判断 url 是否走 ehgt.org（封面会把 s.exhentai.org 替换为 ehgt.org）。
  bool _isEhgtUrl(String url) =>
      url.contains('ehgt.org') || url.contains('s.exhentai.org');

  /// 获取一个 ehgt.org 并发配额（最多 3 并发），未获取到则轮询等待。
  Future<void> acquireEhgtSlot(String url) async {
    if (!_isEhgtUrl(url)) return;
    while (ehgtLoading >= 3) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    ehgtLoading++;
  }

  /// 释放一个 ehgt.org 并发配额。
  void releaseEhgtSlot(String url) {
    if (!_isEhgtUrl(url)) return;
    if (ehgtLoading > 0) {
      ehgtLoading--;
    }
  }

  /// 获取第 [page] 页的 reader 页链接（供 05 阅读链路使用）。
  Future<Res<String>> getReaderLink(String gLink, int page) async {
    var res = await _getReaderLinks(gLink, 1);
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    if (page <= res.data.length) {
      return Res(res.data[page - 1]);
    }
    var urlsOnePage = res.data.length;

    final shouldLoadPage = (page - 1) ~/ urlsOnePage + 1;
    final urlsRes = await _getReaderLinks(gLink, shouldLoadPage);
    if (urlsRes.error) {
      return Res.fromErrorRes(urlsRes);
    }
    return Res(urlsRes.data[(page - 1) % urlsOnePage]);
  }

  /// page 从 1 开始。
  ///
  /// 同一 URL 并发调用时，仅首个真正发起网络请求并写入 [_htmlCache]；
  /// 其余等待者被 [loadingReaderLinks] 挡住醒来后，直连缓存读取（由
  /// `request(url, useCache: true)` 内部判定命中），不会各自重新拉整页。
  /// 这也是本方法唯一显式传 `useCache: true` 的调用点——列表/画廊列表类
  /// 只读页缓存安全，取 showKey/imgKey/api 的请求绝不能走此缓存。
  Future<Res<List<String>>> _getReaderLinks(String link, int page) async {
    String url = link;
    if (page != 1) {
      url = url.contains('?') ? '$url&p=${page - 1}' : '$url?p=${page - 1}';
    }
    while (loadingReaderLinks.contains(url)) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    loadingReaderLinks.add(url);
    var res = await request(url, useCache: true);
    loadingReaderLinks.remove(url);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var urls = <String>[];
      var temp = parse(res.data);
      var links = temp.querySelectorAll('div#gdt > a');
      for (var l in links) {
        urls.add(l.attributes['href']!);
      }
      return Res(urls);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'Data Analysis', '$e\n$s');
      return Res(null, errorMessage: e.toString());
    }
  }

  /// 带 nl 参数换 CDN 节点重试取图片直链（供 05 图片解密状态机使用）。
  Future<(String image, String? nl)> getImageLinkWithNL(
      String gid, String imgKey, int p, String nl) async {
    var res = await request('$ehBaseUrl/s/$imgKey/$gid-$p?nl=$nl');
    if (res.error) {
      throw res.errorMessage ?? 'error';
    } else {
      var document = parse(res.data);
      var image = document.querySelector('div#i3 > a > img')?.attributes['src'];
      var newNl = document
          .querySelector('div#i6 > div > a#loadfail')
          ?.attributes['onclick']
          ?.split('\'')
          .firstWhereOrNull((element) => element.contains('-'));
      return (image ?? (throw 'Failed to get image.'), newNl);
    }
  }

  /// 画廊级 showKey 获取锁：同一画廊串行取 showKey/mpvKey，避免并发重复请求
  /// 触发风控或拿到失效 key（公共契约铁律：showKey 获取为画廊级加锁串行）。
  ///
  /// 用 `auth['showKey']=='loading'` 作占位互斥（照搬上游语义）。
  final _showKeyLocks = <String, Future<void>>{};

  /// 解密并返回第 [page] 页（1-based）的真实图片直链与下一次重试用的 nl。
  ///
  /// 状态机完整移植自上游 `ImageManager.getEhImageNew`（foundation/image_manager.dart
  /// 148-450），但**只负责解密 + 直链可用性验证 + nl 换节点重试**，不下载字节、
  /// 不写缓存（字节下载交给 [OnlineImageManager]，保持其源无关）。
  ///
  /// 流程：
  /// 1. `getReaderLink` 取该页 reader 页 URL，`split('/')[4]` 得 imgKey。
  /// 2. 画廊级加锁取 showKey / mpvKey（普通画廊得 showKey，MPV 画廊得 mpvKey+imgKey 列表）。
  /// 3. showKey 模式 → `apiRequest('showpage')` 解析 i3(图)/i6(原图+nl)；
  ///    mpvKey 模式 → `apiRequest('imagedispatch')` 解析 i(图)/s(nl)。
  /// 4. 对解析出的直链发试探性 GET（仅读响应头判 509/text-html），命中失败用 nl
  ///    换 CDN 节点重试，最多 4 次；4 次仍失败抛异常。
  ///
  /// 返回 `(已验证可用的 imageUrl, 最近一次 nl)`。
  Future<(String imageUrl, String? nl)> getEhImageUrl(
      Gallery gallery, int page) async {
    gallery.auth ??= <String, String>{};
    final galleryLink = gallery.link;
    final gid = getGalleryId(galleryLink).split('-').first;

    final readerLinkRes = await getReaderLink(galleryLink, page);
    if (readerLinkRes.error) {
      throw readerLinkRes.errorMessage ?? 'Failed to get reader link';
    }
    final readerLink = readerLinkRes.data;

    // imgKey：reader 页 URL 形如 .../s/{imgKey}/{gid}-{page}，第 4 段即 imgKey。
    final imgKey = readerLink.split('/')[4];

    await _acquireShowKey(gallery, readerLink);
    assert(gallery.auth!['showKey'] != null || gallery.auth!['mpvKey'] != null);

    // 共享下载 dio（连接池复用）；原先挂在 BaseOptions 上的 header / 超时改为
    // per-request 下发给 _verifyImageReachable，共享实例本身不被改写。
    final dio = sharedDownloadDio(options: sharedDownloadBaseOptions());
    final verifyHeaders = {'user-agent': ehUA, 'cookie': cookiesStr};

    if (gallery.auth!['mpvKey'] != null) {
      // MPV 画廊：imagedispatch。
      Future<(String image, String? nl)> getImageFromApi([String? nl]) async {
        final apiRes = await apiRequest({
          'gid': int.parse(gid),
          'imgkey': gallery.auth!['imgKey']!.split(',')[page - 1],
          'method': 'imagedispatch',
          'page': page,
          'mpvkey': gallery.auth!['mpvKey'],
          if (nl != null) 'nl': nl,
        });
        if (apiRes.error) {
          throw apiRes.errorMessage ?? 'Failed to make api request';
        }
        final apiJson = const JsonDecoder().convert(apiRes.data);
        return (apiJson['i'].toString(), apiJson['s']?.toString());
      }

      var (image, nl) = await getImageFromApi();
      int retryTimes = 0;
      while (true) {
        try {
          await _verifyImageReachable(dio, image, headers: verifyHeaders);
          return (image, nl);
        } catch (e) {
          retryTimes++;
          if (retryTimes == 4) {
            throw 'Failed to load image.\nMaximum number of retries reached.';
          }
          (image, nl) = await getImageFromApi(nl);
        }
      }
    } else {
      // 普通画廊：showpage。
      Future<(String image, String? nl)> getImageFromApi() async {
        final apiRes = await apiRequest({
          'gid': int.parse(gid),
          'imgkey': imgKey,
          'method': 'showpage',
          'page': page,
          'showkey': gallery.auth!['showKey'],
        });
        if (apiRes.error &&
            (apiRes.errorMessage?.contains('handshake') ?? false)) {
          throw 'Failed to make api request.\n'
              'This may be due to too frequent requests.\n'
              'Try to wait for some time and retry.';
        }
        if (apiRes.error) {
          throw apiRes.errorMessage ?? 'Failed to make api request';
        }
        final apiJson = const JsonDecoder().convert(apiRes.data);
        final i6 = apiJson['i6'] as String;
        final nl = RegExp(r"nl\('(.+?)'\)").firstMatch(i6)?.group(1);
        var image = apiJson['i3'] as String;
        image = image.substring(
            image.indexOf('src="') + 5, image.indexOf('" style'));
        return (image, nl);
      }

      // api 解析失败时回退到直接解析 reader 页 HTML（照搬上游容错）。
      Future<(String image, String? nl)> getImageFromHtml() async {
        final res = await request(readerLink);
        if (res.error) {
          throw res.errorMessage ?? 'error';
        }
        final document = parse(res.data);
        final image =
            document.querySelector('div#i3 > a > img')?.attributes['src'];
        final nl = document
            .querySelector('div#i6 > div > a#loadfail')
            ?.attributes['onclick']
            ?.split('\'')
            .firstWhereOrNull((element) => element.contains('-'));
        return (image ?? '', nl);
      }

      String image;
      String? nl;
      try {
        (image, nl) = await getImageFromApi();
      } catch (e) {
        (image, nl) = await getImageFromHtml();
      }

      if (image.contains('509.gif')) {
        throw 'Image loading limit reached (509).';
      }

      int retryTimes = 0;
      while (true) {
        try {
          await _verifyImageReachable(dio, image, headers: verifyHeaders);
          return (image, nl);
        } catch (e) {
          retryTimes++;
          if (retryTimes == 4) {
            throw 'Failed to load image.\nMaximum number of retries reached.';
          }
          if (nl == null) {
            rethrow;
          }
          final (newImage, newNl) =
              await getImageLinkWithNL(gid, imgKey, page, nl);
          image = newImage;
          if (kDebugMode) {
            print('Get new eh image: $image, new nl $newNl');
          }
          if (newNl != null) {
            nl = newNl;
          }
        }
      }
    }
  }

  /// 画廊级串行获取 showKey / mpvKey。同一画廊并发调用会复用同一个 future，
  /// 保证只发一次解析请求（公共契约铁律：showKey 获取为画廊级加锁串行）。
  Future<void> _acquireShowKey(Gallery gallery, String readerLink) {
    final existing = _showKeyLocks[gallery.link];
    if (existing != null) {
      return existing;
    }
    final future = _doAcquireShowKey(gallery, readerLink).whenComplete(() {
      _showKeyLocks.remove(gallery.link);
    });
    _showKeyLocks[gallery.link] = future;
    return future;
  }

  Future<void> _doAcquireShowKey(Gallery gallery, String readerLink) async {
    if (gallery.auth!['showKey'] != null || gallery.auth!['mpvKey'] != null) {
      return;
    }
    final res = await request(readerLink);
    if (res.error) {
      throw res.errorMessage ?? 'Failed to get showKey';
    }
    final html = parse(res.data);
    final script = html
        .querySelectorAll('script')
        .firstWhereOrNull((element) => element.text.contains('showkey'));
    if (script != null) {
      final match = RegExp(r'showkey="(.*?)"').firstMatch(script.text);
      gallery.auth!['showKey'] = match!.group(1)!;
    } else {
      // MPV 画廊：从内联脚本解析 mpvkey 与 imagelist（每页的 k 拼成 imgKey 列表）。
      final mpvScript = html
          .querySelectorAll('script')
          .firstWhereOrNull((element) => element.text.contains('mpvkey'))
          ?.text;
      if (mpvScript == null) {
        throw Exception('Failed to get showKey or mpvkey');
      }
      final mpvKey = mpvScript
          .split(';')
          .firstWhere((element) => element.contains('mpvkey'));
      gallery.auth!['mpvKey'] = mpvKey.removeAllBlank
          .replaceFirst('varmpvkey=', '')
          .replaceAll('"', '');
      final imageListScript = mpvScript
          .split(';')
          .firstWhere((element) => element.contains('imagelist'))
          .removeAllBlank
          .replaceFirst('varimagelist=', '');
      gallery.auth!['imgKey'] =
          (jsonDecode(imageListScript) as List).map((e) => e['k']).join(',');
    }
  }

  /// 试探性 GET 校验直链可用：只读响应头，命中 text/html（509 限流页/失效节点）即判失败。
  ///
  /// 指向 ehgt.org 的请求受 [acquireEhgtSlot] 3 并发闸控制；校验完立即取消流，
  /// 不读完整字节（完整下载由 [OnlineImageManager] 负责）。
  Future<void> _verifyImageReachable(
    Dio dio,
    String image, {
    Map<String, String>? headers,
  }) async {
    if (image.isEmpty) {
      throw 'empty url';
    }
    await acquireEhgtSlot(image);
    final cancelToken = CancelToken();
    try {
      final res = await dio.get<ResponseBody>(
        image,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          receiveTimeout: const Duration(seconds: 20),
          headers: headers,
        ),
        cancelToken: cancelToken,
      );
      final contentType = res.data?.headers['Content-Type']?[0] ??
          res.data?.headers['content-type']?[0];
      if (contentType == 'text/html; charset=UTF-8') {
        throw 'Image loading limit reached.';
      }
    } finally {
      // 只需响应头，取消未读完的流，避免重复拉全量字节。
      cancelToken.cancel('verified');
      releaseEhgtSlot(image);
    }
  }

  List<String> _splitKeyword(String keyword) {
    var res = <String>[];
    var buffer = StringBuffer();
    var qs = Queue<String>();
    for (int i = 0; i < keyword.length; i++) {
      var char = keyword[i];
      if (char == '"' || char == "'") {
        if (qs.isEmpty) {
          qs.add(char);
        } else {
          if (qs.first == char) {
            qs.removeFirst();
          } else {
            qs.add(char);
          }
        }
      }
      if (char == ' ') {
        if (qs.isEmpty) {
          res.add(buffer.toString());
          buffer.clear();
        } else {
          buffer.write(char);
        }
      } else {
        buffer.write(char);
      }
    }
    if (buffer.isNotEmpty) {
      res.add(buffer.toString());
    }
    return res;
  }

  /// 搜索 e-hentai / exhentai。
  Future<Res<Galleries>> search(
    String keyword, {
    int? fCats,
    int? startPages,
    int? endPages,
    int? minStars,
    int? expunged,
  }) async {
    if (keyword != '') {
      appdata.searchHistory.remove(keyword);
      appdata.searchHistory.add(keyword);
      appdata.writeHistory();
    }
    keyword = keyword.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (keyword.contains(' | ')) {
      var keywords = _splitKeyword(keyword);
      var newKeywords = <String>[];
      for (var k in keywords) {
        if (!k.contains(' | ')) {
          newKeywords.add(k);
        } else {
          var lr = k.split(':');
          if (lr.length != 2 &&
              !((lr[1].startsWith('"') && lr[1].endsWith('"')) ||
                  (lr[1].startsWith("'") && lr[1].endsWith("'")))) {
            newKeywords.add(k);
          } else {
            var key = lr[0];
            var value = lr[1].substring(1, lr[1].length - 1);
            value = '${value.split(' | ').first}\$';
            newKeywords.add('$key:"$value"');
          }
        }
      }
      keyword = newKeywords.join(' ');
    }
    var requestUrl = '$ehBaseUrl/?f_search=$keyword';
    if (fCats != null) {
      requestUrl += '&f_cats=$fCats';
    }
    if (startPages != null) {
      requestUrl += '&f_spf=$startPages';
    }
    if (endPages != null) {
      requestUrl += '&f_spt=$endPages';
    }
    if (minStars != null) {
      requestUrl += '&f_srdd=$minStars';
    }
    if (expunged != null && expunged == 1) {
      requestUrl += '&f_sh=on';
    }
    return getGalleries(requestUrl);
  }

  /// 评分。
  Future<bool> rateGallery(Map<String, String> auth, int rating) async {
    var res = await apiRequest({
      'method': 'rategallery',
      'apiuid': auth['apiuid'],
      'apikey': auth['apikey'],
      'gid': auth['gid'],
      'token': auth['token'],
      'rating': rating,
    });
    return !res.error;
  }

  /// 收藏。
  Future<bool> favorite(String gid, String token, {String id = '0'}) async {
    var res = await post(
        '$ehBaseUrl/gallerypopups.php?gid=$gid&t=$token&act=addfav',
        'favcat=$id&favnote=&apply=Add+to+Favorites&update=1',
        headers: {'Content-Type': 'application/x-www-form-urlencoded'});
    if (res.error) {
      return false;
    }
    if (res.data.isEmpty || res.data[0] != '<') {
      return false;
    } else {
      return true;
    }
  }

  /// 取消收藏（画廊弹窗路径）。
  Future<bool> unfavorite(String gid, String token) async {
    var res = await post(
        '$ehBaseUrl/gallerypopups.php?gid=$gid&t=$token&act=addfav',
        'favcat=favdel&favnote=&apply=Apply+Changes&update=1',
        headers: {'Content-Type': 'application/x-www-form-urlencoded'});
    if (res.error || res.data.isEmpty || res.data[0] != '<') {
      return false;
    } else {
      return true;
    }
  }

  /// 取消收藏（收藏夹页批量路径）。
  Future<bool> unfavorite2(String gid) async {
    var res = await post(
        '$ehBaseUrl/favorites.php', 'ddact=delete&modifygids%5B%5D=$gid',
        headers: {'Content-Type': 'application/x-www-form-urlencoded'});
    if (res.error) {
      return false;
    } else {
      return true;
    }
  }

  /// 发表评论。
  Future<Res<bool>> comment(String content, String link) async {
    var res = await post(
        link, 'commenttext_new=${Uri.encodeComponent(content)}',
        headers: {'Content-Type': 'application/x-www-form-urlencoded'});

    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    var document = parse(res.data);
    if (document.querySelector('p.br') != null) {
      return Res(null, errorMessage: document.querySelector('p.br')!.text);
    }
    return const Res(true);
  }

  /// 评论投票。
  Future<Res<int>> voteComment(
      Map<String, String> auth, String cid, bool isUp) async {
    var res = await apiRequest({
      'method': 'votecomment',
      'apikey': auth['apikey'],
      'apiuid': auth['apiuid'],
      'comment_id': cid,
      'gid': auth['gid'],
      'token': auth['token'],
      'comment_vote': isUp ? '1' : '-1',
    });
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var json = jsonDecode(res.data);
      var newScore = json['comment_score'];
      if (newScore is! int) {
        return const Res.error('Failed to get new score');
      }
      return Res(newScore);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  /// 取归档下载页信息（供 07 下载器调用，本计划不接执行流程）。
  Future<Res<ArchiveDownloadInfo>> getArchiveDownloadInfo(String url) async {
    var res = await request(url);
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);
      var body = document.querySelector('div#db')!;
      int index = url.contains('exhentai') ? 1 : 3;
      var origin = body.children[index].children[0];
      var originCost = origin.querySelector('div > strong')!.text;
      var originSize = origin.querySelector('p > strong')!.text;
      var resample = body.children[index].children[1];
      var resampleCost = resample.querySelector('div > strong')!.text;
      var resampleSize = resample.querySelector('p > strong')!.text;
      return Res(ArchiveDownloadInfo(
        originSize,
        resampleSize,
        originCost,
        resampleCost,
        document.querySelector('form#invalidate_form')?.attributes['action'],
      ));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'Network', '$e\n$s\n${res.data}');
      return Res.error(e.toString());
    }
  }

  /// 取消并重载归档信息（供 07 调用）。
  Future<Res<ArchiveDownloadInfo>> cancelAndReloadArchiveInfo(
      ArchiveDownloadInfo info) async {
    var url = info.cancelUnlockUrl!;
    var res = await post(url, 'invalidate_sessions=1', headers: {
      'content-type': 'application/x-www-form-urlencoded',
    });
    if (res.error) {
      return Res.fromErrorRes(res);
    }
    try {
      var document = parse(res.data);
      var body = document.querySelector('div#db')!;
      int index = url.contains('exhentai') ? 1 : 3;
      var origin = body.children[index].children[0];
      var originCost = origin.querySelector('div > strong')!.text;
      var originSize = origin.querySelector('p > strong')!.text;
      var resample = body.children[index].children[1];
      var resampleCost = resample.querySelector('div > strong')!.text;
      var resampleSize = resample.querySelector('p > strong')!.text;
      return Res(ArchiveDownloadInfo(
        originSize,
        resampleSize,
        originCost,
        resampleCost,
        document.querySelector('form#invalidate_form')?.attributes['action'],
      ));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, 'Network', '$e\n$s\n${res.data}');
      return Res.error(e.toString());
    }
  }

  /// 取归档下载真实链接（供 07 调用）。
  Future<Res<String>> getArchiveDownloadLink(String apiUrl, int type) async {
    try {
      var data = type == 1
          ? 'dltype=org&dlcheck=Download+Original+Archive'
          : 'dltype=res&dlcheck=Download+Resample+Archive';
      var res = await post(apiUrl, data, headers: {
        'content-type': 'application/x-www-form-urlencoded',
      });
      if (res.error) {
        return Res.fromErrorRes(res);
      }
      var document = parse(res.data);
      var link = document.querySelector('a')?.attributes['href'];
      if (link == null) {
        return const Res.error('Failed to get download link');
      }
      var res2 = await logDio().get<String>(link);
      document = parse(res2.data);
      var link2 = document.querySelector('a')?.attributes['href'];
      var host = Uri.parse(link).host;
      return Res('https://$host$link2');
    } catch (e) {
      return Res.error(e.toString());
    }
  }
}
