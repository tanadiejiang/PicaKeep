import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:picakeep/comic_source/favorite_data.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/res.dart';

import 'built_in/picacg.dart';
import 'built_in/jm.dart';
import 'built_in/ehentai.dart';
import 'built_in/nhentai.dart';

typedef LoginHandler = Future<Res<bool>> Function(
  String username,
  String password,
);

typedef LogoutHandler = FutureOr<void> Function();

typedef ReloginHandler = Future<Res<bool>> Function();

typedef AccountInfoLoader = Future<Res<List<AccountInfoItem>>> Function();

typedef OnlineSearchLoader = Future<Res<List<BaseComic>>> Function(
  String keyword,
  int page,
  String option,
);

typedef OnlineComicPageBuilder = Widget Function(BaseComic comic);

/// 源级别的封面/图片请求头钩子。返回 `null` 表示该源不需要自定义请求头,
/// 消费端应回退到裸 `NetworkImage`。picacg / jm 不实现它(保持 `null`),
/// ehentai 等需要 Cookie/Referer/User-Agent 鉴权的源在源注册时填上。
typedef ImageHeadersBuilder = Map<String, String>? Function(BaseComic comic);

class ComicSource {
  ComicSource.named({
    required this.key,
    required this.name,
    this.account,
    this.favoriteData,
    this.searchPageData,
    this.comicPageBuilder,
    this.imageHeadersBuilder,
    this.idMatcher,
    Map<String, dynamic>? data,
  }) : data = data ?? <String, dynamic>{};

  static final List<ComicSource> sources = <ComicSource>[];

  static List<ComicSource> get builtIn => <ComicSource>[picacg, jm, ehentai, nhentai];

  static Future<void> init() async {
    sources
      ..clear()
      ..addAll(builtIn);
    await _loadCustomSources();
    for (final source in sources) {
      await source.loadData();
    }
  }

  static Future<void> _loadCustomSources() async {
    // JS custom sources are intentionally disabled in this phase. The hook is
    // left here so a later JS-engine task can attach directory scanning without
    // changing the source registry contract.
    return;
  }

  static ComicSource? find(String key) {
    for (final source in sources) {
      if (source.key == key) {
        return source;
      }
    }
    return null;
  }

  static ComicSource require(String key) {
    final source = find(key);
    if (source == null) {
      throw StateError('ComicSource not found: $key');
    }
    return source;
  }

  final String key;
  final String name;
  final AccountConfig? account;
  final FavoriteData? favoriteData;
  final SearchPageData? searchPageData;
  final OnlineComicPageBuilder? comicPageBuilder;

  /// 可选:源级别封面/图片请求头钩子。默认 `null`,消费端回退裸 `NetworkImage`。
  final ImageHeadersBuilder? imageHeadersBuilder;

  /// 可选:ID 直跳正则。搜索页检测到输入文本匹配时，建议列表出现「打开漫画」条目。
  /// 匹配后搜索页将文本传给 [comicPageBuilder]（前缀剥离由源自行处理）。
  final RegExp? idMatcher;

  final Map<String, dynamic> data;

  bool _isSaving = false;
  bool _haveWaitingTask = false;

  String get filePath => '${App.dataPath}${Platform.pathSeparator}comic_source'
      '${Platform.pathSeparator}$key.data';

  bool get isLoggedIn {
    final token = data['token']?.toString() ?? '';
    return token.isNotEmpty;
  }

  Future<void> loadData() async {
    final file = File(filePath);
    if (!await file.exists()) {
      return;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        data
          ..clear()
          ..addAll(
              decoded.map((key, value) => MapEntry(key.toString(), value)));
      }
    } catch (error, stackTrace) {
      LogManager.addLog(
        LogLevel.error,
        'ComicSource',
        'Failed to load $key data: $error\n$stackTrace',
      );
    }
  }

  Future<void> saveData() async {
    if (_isSaving) {
      _haveWaitingTask = true;
      return;
    }
    _isSaving = true;
    try {
      do {
        _haveWaitingTask = false;
        final file = File(filePath);
        await file.parent.create(recursive: true);
        await file.writeAsString(jsonEncode(data), flush: true);
      } while (_haveWaitingTask);
    } finally {
      _isSaving = false;
    }
  }

  Future<Res<bool>> reLogin() async {
    final handler = account?.reLogin;
    if (handler == null) {
      return const Res.error('No relogin handler');
    }
    return handler();
  }
}

class AccountConfig {
  const AccountConfig({
    required this.login,
    this.logout,
    this.reLogin,
    this.infoItems,
    this.onLogin,
  });

  final LoginHandler login;
  final LogoutHandler? logout;
  final ReloginHandler? reLogin;
  final AccountInfoLoader? infoItems;

  /// 可选:自定义登录入口(纯增量)。源若提供该回调,账号页应调用它跳转到源自有的
  /// 登录页面,而非走默认的账密 [login] 表单。picacg / jm 不设置(保持 null,
  /// 走默认账密登录);ehentai 等 cookie 登录源在此挂自己的登录页。
  /// 返回 Future,账号页 await 它(登录页关闭)后再刷新账号信息区。
  final Future<void> Function(BuildContext context)? onLogin;
}

class AccountInfoItem {
  const AccountInfoItem({
    required this.title,
    required this.value,
  });

  final String title;
  final String value;
}

class SearchPageData {
  const SearchPageData({
    required this.loadPage,
    this.searchOptions = const <SearchOption>[],
    this.defaultOption = '',
    this.enableTagsSuggestions = false,
  });

  final OnlineSearchLoader loadPage;
  final List<SearchOption> searchOptions;
  final String defaultOption;

  /// 是否在搜索框输入时显示标签建议列表。
  /// eh/nh 源设为 true；picacg/jm 保持默认 false。
  final bool enableTagsSuggestions;
}

class SearchOption {
  const SearchOption({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;
}
