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

  static List<ComicSource> get builtIn =>
      <ComicSource>[picacg, jm, ehentai, nhentai];

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

  /// 同一实例正在进行的保存任务；null 表示空闲。
  Future<void>? _saveTask;

  /// 本轮保存期间是否又发生了新修改（需要再写一轮）。
  bool _saveAgain = false;

  String get filePath => '${App.dataPath}${Platform.pathSeparator}comic_source'
      '${Platform.pathSeparator}$key.data';

  /// 文件写入接缝：默认写 [filePath]，测试可替换为受控实现。
  @visibleForTesting
  Future<void> Function(String path, String contents) writeDataFile =
      _writeDataFile;

  static Future<void> _writeDataFile(String path, String contents) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(contents, flush: true);
  }

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

  /// 保存源数据，并在返回时保证"调用者此前的修改已经落盘"。
  ///
  /// 同一实例的并发调用共享同一个保存任务：保存期间发生的调用**不会提前返回**，
  /// 而是等待包含自己这次修改的最后一轮写入结束；任一轮写入失败都会把错误传播给
  /// 本轮所有等待者，并释放任务状态以便重试。数据格式与文件位置保持不变。
  Future<void> saveData() {
    final pending = _saveTask;
    if (pending != null) {
      // 保存进行中：登记"还有新修改"，等待当前任务把这一轮补写完。
      _saveAgain = true;
      return pending;
    }
    // 占位必须早于序列化/调用 writer，避免同步异常清理后又挂回失败任务。
    final completer = Completer<void>();
    _saveTask = completer.future;
    unawaited(_runSaveLoop().then<void>(
      (_) => completer.complete(),
      onError: completer.completeError,
    ));
    return completer.future;
  }

  Future<void> _runSaveLoop() async {
    try {
      do {
        _saveAgain = false;
        // jsonEncode 在 await 之前同步取快照，保证写出的正是本轮的数据。
        await writeDataFile(filePath, jsonEncode(data));
      } while (_saveAgain);
    } finally {
      // 失败或完成后都释放任务状态，使后续保存可以重新开始（可重试）。
      _saveTask = null;
      _saveAgain = false;
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
    this.registerWebsite,
    this.allowReLogin = true,
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

  /// 可选:注册入口 URL。仅当非 null 时,通用登录页显示注册入口并外部打开。
  /// 目前只有 jm 声明(取自原项目 `built_in/jm.dart`);picacg 无注册接口。
  final String? registerWebsite;

  /// 是否允许账号页显示"重新登录"。默认 true。
  /// ehentai / nhentai 无账号页重登能力,显式置 false;
  /// UI 需同时要求 [reLogin] 非 null,两者同时满足才显示。
  final bool allowReLogin;
}

class AccountInfoItem {
  const AccountInfoItem({
    required this.title,
    this.value = '',
    this.builder,
  });

  final String title;
  final String value;

  /// 可选:自定义渲染(例如 EH 的 cookies 折叠管理区)。
  /// 非 null 时账号页优先使用它,忽略 [value]。
  final WidgetBuilder? builder;
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
