/// 探索能力的 Flutter 应用绑定层。
///
/// 这是纯契约层与真实网络/账号之间**唯一**的连接点：把 `ComicSource` 的登录态、
/// 站点设置与网络单例注入四个 Provider，并对"身份/站点变了"做会话失效。
///
/// 页面与未来 AI 工具都只拿 `ExploreRegistry`，不直接 new 网络单例。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/explore/explore_registry.dart';
import 'package:picakeep/foundation/explore/providers/eh_explore_provider.dart';
import 'package:picakeep/foundation/explore/providers/jm_explore_provider.dart';
import 'package:picakeep/foundation/explore/providers/nhentai_explore_provider.dart';
import 'package:picakeep/foundation/explore/providers/picacg_explore_provider.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';

/// 应用级探索注册表（进程内单例，在 `_initializeOnlineFoundation` 组装）。
class ExploreBindings {
  ExploreBindings._(this.registry, this._fingerprints);

  /// 测试接缝：用**现成的**注册表组装实例，不触碰任何真实网络单例。
  ///
  /// 为什么需要它：`install()` 会构造四源的真实网络单例（EH 的 `CookieJarSql`
  /// 需要 `sqlite3` 动态库），在 `flutter test` 环境下无法加载，页面级测试因此
  /// 无法覆盖"四源 / 三页签可达"。用这个构造 + [debugSetInstance] 注入一个全部
  /// 由 fake provider 组成的注册表，就能在不起网络、不碰磁盘的前提下测页面行为。
  @visibleForTesting
  ExploreBindings.forTesting(
    this.registry, {
    Map<String, String>? fingerprints,
  }) : _fingerprints = fingerprints ?? const <String, String>{};

  static ExploreBindings? _instance;

  static ExploreBindings? get instance => _instance;

  /// 测试接缝：注入/清空进程级实例（传 `null` 即复位）。
  ///
  /// 只应在测试的 `setUp`/`tearDown` 里使用；生产代码唯一的组装入口是 [install]。
  @visibleForTesting
  static void debugSetInstance(ExploreBindings? bindings) {
    _instance = bindings;
  }

  final ExploreRegistry registry;

  /// 上次观察到的上下文指纹（源 key → 指纹），用于判定身份/站点变化。
  Map<String, String> _fingerprints;

  /// 组装注册表。**不发任何网络请求**。
  ///
  /// `ComicSource.init()` 之后调用；未初始化时调用方必须保持旧的探索实例不变。
  static ExploreBindings install({ExploreRegistry? registry}) {
    final target = registry ?? ExploreRegistry();
    target
      ..register(JmExploreProvider(
        isLoggedInGetter: () => _sourceLoggedIn('jm'),
        contextFingerprintGetter: () => _jmFingerprint(),
        network: JmNetwork(),
      ))
      ..register(PicacgExploreProvider(
        isLoggedInGetter: () => _sourceLoggedIn('picacg'),
        contextFingerprintGetter: () => _picacgFingerprint(),
        network: PicacgNetwork(),
      ))
      ..register(EhExploreProvider(
        isLoggedInGetter: () => _sourceLoggedIn('ehentai'),
        contextFingerprintGetter: () => _ehFingerprint(),
        siteBaseUrlGetter: () => EhNetwork().ehBaseUrl,
        network: EhNetwork(),
      ))
      ..register(NhentaiExploreProvider(
        isLoggedInGetter: () => _sourceLoggedIn('nhentai'),
        contextFingerprintGetter: () => _nhFingerprint(),
        network: NhentaiNetwork(),
      ));
    final bindings = ExploreBindings._(target, target.contextFingerprints());
    _instance = bindings;
    return bindings;
  }

  /// 重新核对上下文：身份/站点变化时使对应源的会话失效。
  ///
  /// 返回发生变化的源 key 列表（空表示没变化）。**只有**身份或站点变化才失效
  /// 数据会话；卡片、屏蔽、翻译显示策略的变化由页面重算现有条目，不影响会话。
  List<String> refreshContext() {
    final current = registry.contextFingerprints();
    final changed = <String>[];
    for (final entry in current.entries) {
      if (_fingerprints[entry.key] != entry.value) {
        changed.add(entry.key);
      }
    }
    if (changed.isNotEmpty) {
      for (final key in changed) {
        registry.invalidateSource(key);
      }
      _fingerprints = current;
    }
    return changed;
  }

  // ── 登录态 / 指纹 ─────────────────────────────────────────────────────────

  static bool _sourceLoggedIn(String key) {
    return ComicSource.find(key)?.isLoggedIn ?? false;
  }

  /// JM：账号身份（token 是否有 + 账号名）+ 当前 API 域名索引。
  ///
  /// 指纹只做**内部比较**：不写日志、不进公开 ID。用 token + 账号摘要而不是
  /// 完整账密；域名索引变化（换活域名）不影响数据语义，故只取索引而非完整域名。
  static String _jmFingerprint() {
    final source = ComicSource.find('jm');
    if (source == null) return 'missing';
    final token = source.data['token']?.toString() ?? '';
    final account = source.data['account'];
    final accountKey = account is List && account.isNotEmpty
        ? account.first.toString().hashCode.toString()
        : '';
    final domainIndex = _settingsValue(17);
    return '$token|$accountKey|$domainIndex';
  }

  /// Picacg：token + 用户 id。
  static String _picacgFingerprint() {
    final source = ComicSource.find('picacg');
    if (source == null) return 'missing';
    final token = source.data['token']?.toString() ?? '';
    final user = source.data['user'];
    final userId = user is Map ? (user['id']?.toString() ?? '') : '';
    return '$token|$userId';
  }

  /// EH：站点选择（表站 / 里站）+ 成员 id + igneous 摘要。
  static String _ehFingerprint() {
    final source = ComicSource.find('ehentai');
    final site = _settingsValue(20);
    final network = EhNetwork();
    // 读取前刷新 cookie 快照，使 id/igneous 是当前身份的值。
    final memberId = network.id;
    final igneousKey =
        network.igneous.isEmpty ? '' : network.igneous.hashCode.toString();
    return '${source?.isLoggedIn ?? false}|$site|$memberId|$igneousKey';
  }

  /// NH：JWT 是否存在 + 账号标记。
  static String _nhFingerprint() {
    final source = ComicSource.find('nhentai');
    if (source == null) return 'missing';
    final token = source.data['token']?.toString() ?? '';
    final name = source.data['name']?.toString() ?? '';
    return '$token|$name';
  }

  /// 读取 settings 的容错版本（越界/未初始化返回空串）。
  static String _settingsValue(int index) {
    try {
      return comicSourceSettingsReader?.call(index) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// settings 读取接缝：由调用方（`lib/main.dart`）注入 `appdata.settings` 读取，
  /// 使本文件不直接依赖 `base.dart`，也让测试能替换。
  static String Function(int index)? comicSourceSettingsReader;
}
