/// 探索注册表：描述与加载的唯一入口。
///
/// 纯 Dart：不导入 Flutter、`ComicSource`、`Res`；不持有全局网络实例。
/// 页面与未来的 AI 工具都只通过这里拿能力与数据，因此：
/// - 能力声明只有一份（Provider 的 [ExploreProvider.descriptor]）；
/// - 会话与续页句柄的 TTL / LRU / 上限只有一份实现；
/// - 未知源、未知选项、过期 token 都在这里统一归类为结构化错误。
library;

import 'dart:collection';
import 'dart:convert';

import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_provider.dart';

/// 默认可注入时钟，便于测试 TTL 行为。
typedef ExploreClock = DateTime Function();

/// 单个消费者会话。
class _ExploreSession {
  _ExploreSession(this.id, DateTime createdAt) : lastUsedAt = createdAt;

  final String id;
  DateTime lastUsedAt;

  /// 该会话已发放的续页句柄（LRU，超过上限淘汰最久未使用者）。
  final LinkedHashMap<String, ExploreContinuationToken> handles =
      LinkedHashMap<String, ExploreContinuationToken>();
}

/// 会话保留策略。
class ExploreSessionPolicy {
  const ExploreSessionPolicy({
    this.idleTtl = const Duration(minutes: 20),
    this.maxSessions = 32,
    this.maxHandlesPerSession = 128,
  });

  /// 空闲多久后会话连同其续页句柄一起失效。
  final Duration idleTtl;

  /// 最多同时保留多少个会话；超出按最久未使用者淘汰。
  final int maxSessions;

  /// 每个会话最多保留多少个续页句柄；超出按最久未使用者淘汰。
  final int maxHandlesPerSession;
}

/// 探索注册表。
///
/// 使用流程（页面 / AI 工具一致）：
/// 1. `createSession()` 拿 sessionId；
/// 2. `load(ExploreRequest(sessionId: ..., sourceKey: ..., entryId: ...))`；
/// 3. 首屏响应里的 `nextToken` 原样回填到下次请求的 `continuation`；
/// 4. 页面销毁时 `releaseSession(sessionId)`（幂等）。
class ExploreRegistry {
  ExploreRegistry({
    ExploreSessionPolicy policy = const ExploreSessionPolicy(),
    ExploreClock? clock,
    ExploreContinuationCodec? codec,
  })  : _policy = policy,
        _clock = clock ?? DateTime.now,
        _codec = codec ?? const _Base64ContinuationCodec();

  final ExploreSessionPolicy _policy;
  final ExploreClock _clock;
  final ExploreContinuationCodec _codec;

  final Map<String, ExploreProvider> _providers = <String, ExploreProvider>{};
  final Map<String, _ExploreSession> _sessions = <String, _ExploreSession>{};

  /// 注册（或替换）一个源。返回 `this` 便于链式组装。
  ExploreRegistry register(ExploreProvider provider) {
    _providers[provider.descriptor.sourceKey] = provider;
    return this;
  }

  bool hasSource(String sourceKey) =>
      _providers.containsKey(sourceKey.trim().toLowerCase());

  /// 全部源的描述，按注册顺序。
  List<ExploreSourceDescriptor> listSources() => _providers.values
      .map((provider) => provider.descriptor)
      .toList(growable: false);

  /// 全部源及其实时可用状态。
  List<ExploreSourceState> listSourceStates() => _providers.values
      .map((provider) => ExploreSourceState(
            descriptor: provider.descriptor,
            loggedIn: provider.isLoggedIn,
          ))
      .toList(growable: false);

  /// 单个源的描述；未知源返回 `null`。
  ExploreSourceDescriptor? describe(String sourceKey) =>
      _providers[sourceKey.trim().toLowerCase()]?.descriptor;

  ExploreProvider? providerOf(String sourceKey) =>
      _providers[sourceKey.trim().toLowerCase()];

  /// 当前上下文指纹（`sourceKey -> fingerprint`）。
  ///
  /// 绑定层用它比较"身份/站点是否变了"，变了就 release 对应源上的会话。
  Map<String, String> contextFingerprints() => <String, String>{
        for (final entry in _providers.entries)
          entry.key: entry.value.contextFingerprint,
      };

  // ── 会话 ──────────────────────────────────────────────────────────────────

  /// 新建一个消费者会话。
  ///
  /// 只管理本地句柄状态，**不发任何网络请求**。
  String createSession() {
    _pruneSessions();
    final id = _nextSessionId();
    final now = _clock();
    _sessions[id] = _ExploreSession(id, now);
    _enforceSessionLimit();
    return id;
  }

  /// 释放会话（幂等）。只清自己的续页句柄，不影响其它消费者。
  void releaseSession(String sessionId) {
    _sessions.remove(sessionId);
  }

  /// 会话是否仍存活。
  bool isSessionAlive(String sessionId) {
    _pruneSessions();
    return _sessions.containsKey(sessionId);
  }

  /// 手动使某源上的全部会话失效（账号/站点变化时调用）。
  ///
  /// 返回被清掉的会话数量。
  int invalidateSource(String sourceKey) {
    final key = sourceKey.trim().toLowerCase();
    final victims = <String>[];
    for (final entry in _sessions.entries) {
      final hasSourceHandle =
          entry.value.handles.values.any((token) => token.sourceKey == key);
      if (hasSourceHandle) {
        victims.add(entry.key);
      }
    }
    for (final id in victims) {
      _sessions.remove(id);
    }
    return victims.length;
  }

  /// 清空全部会话（测试与"账号实质变化"时使用）。
  void invalidateAll() => _sessions.clear();

  int get sessionCount {
    _pruneSessions();
    return _sessions.length;
  }

  int handleCountOf(String sessionId) =>
      _sessions[sessionId]?.handles.length ?? 0;

  int _sessionCounter = 0;

  String _nextSessionId() => 'explore-session-${++_sessionCounter}';

  void _pruneSessions() {
    final now = _clock();
    final stale = <String>[];
    for (final entry in _sessions.entries) {
      if (now.difference(entry.value.lastUsedAt) >= _policy.idleTtl) {
        stale.add(entry.key);
      }
    }
    for (final id in stale) {
      _sessions.remove(id);
    }
  }

  void _enforceSessionLimit() {
    while (_sessions.length > _policy.maxSessions) {
      String? oldestId;
      DateTime? oldestAt;
      for (final entry in _sessions.entries) {
        if (oldestAt == null || entry.value.lastUsedAt.isBefore(oldestAt)) {
          oldestAt = entry.value.lastUsedAt;
          oldestId = entry.key;
        }
      }
      if (oldestId == null) return;
      _sessions.remove(oldestId);
    }
  }

  // ── 校验 ──────────────────────────────────────────────────────────────────

  /// 校验请求的源 / 入口 / 选项 / 分类 / 续页句柄。
  ///
  /// 校验通过返回规范化后的真实请求（选项已回落到描述符默认值、续页游标已解出）；
  /// 失败返回结构化错误。
  ExploreResult<ExploreResolvedRequest> validate(ExploreRequest request) {
    final key = request.sourceKey.trim().toLowerCase();
    final provider = _providers[key];
    if (provider == null) {
      return ExploreFailure(
        ExploreError(
            ExploreErrorCode.unsupported, '未知的探索源：${request.sourceKey}'),
      );
    }
    final descriptor = provider.descriptor;
    final entry = descriptor.entryById(request.entryId);
    if (entry == null) {
      return ExploreFailure(
        ExploreError(
          ExploreErrorCode.unsupported,
          '该源没有入口：${request.entryId}',
        ),
      );
    }
    if (descriptor.requiresLogin && !provider.isLoggedIn) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.loginRequired, '该源需要登录后才能浏览'),
      );
    }

    final rawSessionId = request.sessionId.trim();
    if (rawSessionId.isEmpty) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '缺少会话 ID'),
      );
    }

    // 选项规范化：显式未知 → invalidArgument；未给 → 描述符默认值。
    String? optionId;
    if (entry.options.isNotEmpty) {
      final requested = request.options.first;
      if (requested == null || requested.isEmpty) {
        optionId = entry.defaultOptionIdOrFirst;
      } else if (entry.optionById(requested) == null) {
        return ExploreFailure(
          ExploreError(
            ExploreErrorCode.invalidArgument,
            '未知的选项：$requested',
          ),
        );
      } else {
        optionId = requested;
      }
    } else if (!request.options.isEmpty) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '该入口不接受选项'),
      );
    }

    final categoryKey = _categoryKeyOf(request.category);

    // 单页入口不接受续页：这是参数组合错误，必须在 token 校验之前判定，
    // 否则任意续页值都会先撞上 expiredContinuation，把责任推给"过期"。
    if (request.continuation != null && entry.singlePage) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.invalidArgument, '该入口只有单页'),
      );
    }

    var cursor = '';
    if (request.continuation != null) {
      final decoded = resolveContinuation(
        raw: request.continuation!,
        sessionId: rawSessionId,
        sourceKey: key,
        entryId: entry.id,
        optionId: optionId,
        categoryKey: categoryKey,
      );
      if (decoded.errorOrNull != null) {
        return ExploreFailure(decoded.errorOrNull!);
      }
      cursor = decoded.dataOrNull!.cursor;
    }

    return ExploreSuccess(ExploreResolvedRequest(
      request: ExploreRequest(
        sessionId: rawSessionId,
        sourceKey: key,
        entryId: entry.id,
        options: optionId == null
            ? ExploreOptions.none
            : ExploreOptions.single(optionId),
        category: request.category,
        continuation: request.continuation,
        categoryId: request.categoryId,
      ),
      provider: provider,
      entry: entry,
      optionId: optionId,
      cursor: cursor,
      isFirstPage: request.continuation == null,
    ));
  }

  /// 校验续页句柄并返回其游标。
  ExploreResult<ExploreContinuationToken> resolveContinuation({
    required String raw,
    required String sessionId,
    required String sourceKey,
    required String entryId,
    required String? optionId,
    required String categoryKey,
  }) {
    _pruneSessions();
    final token = _codec.decode(raw);
    if (token == null) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.expiredContinuation, '续页句柄无效'),
      );
    }
    final session = _sessions[sessionId];
    if (session == null) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.expiredContinuation, '会话已过期'),
      );
    }
    final normalizedOption = optionId ?? '';
    if (token.sessionId != sessionId ||
        token.sourceKey != sourceKey ||
        token.entryId != entryId ||
        token.optionKey != normalizedOption ||
        token.categoryKey != categoryKey) {
      return const ExploreFailure(
        ExploreError(
          ExploreErrorCode.expiredContinuation,
          '续页句柄与当前选择不匹配',
        ),
      );
    }
    // 句柄必须仍登记在这个会话名下：被 LRU 淘汰或被 release 后重放要明确失败。
    if (!session.handles.containsKey(raw)) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.expiredContinuation, '续页句柄已过期'),
      );
    }
    session.handles.remove(raw);
    session.handles[raw] = token;
    session.lastUsedAt = _clock();
    return ExploreSuccess(token);
  }

  /// 为 [page] 生成下一句柄；没有下一页返回 `null`。
  String? mintContinuation({
    required String sessionId,
    required String sourceKey,
    required String entryId,
    required String? optionId,
    required ExploreCategoryTarget? category,
    required String? cursor,
  }) {
    if (cursor == null || cursor.isEmpty) return null;
    final session = _sessions[sessionId];
    if (session == null) return null;
    final token = ExploreContinuationToken(
      sessionId: sessionId,
      sourceKey: sourceKey,
      entryId: entryId,
      optionKey: optionId ?? '',
      categoryKey: _categoryKeyOf(category),
      cursor: cursor,
    );
    final raw = _codec.encode(token);
    session.handles.remove(raw);
    session.handles[raw] = token;
    while (session.handles.length > _policy.maxHandlesPerSession) {
      final oldest = session.handles.keys.first;
      session.handles.remove(oldest);
    }
    session.lastUsedAt = _clock();
    return raw;
  }

  static String _categoryKeyOf(ExploreCategoryTarget? target) {
    if (target == null) return '';
    return '${target.kind}|${target.value}|${target.optionId ?? ''}';
  }

  // ── 加载 ──────────────────────────────────────────────────────────────────

  /// 概览。校验失败不发网络请求。
  Future<ExploreResult<ExploreOverview>> loadOverview(
    ExploreRequest request,
  ) async {
    final resolved = validate(request);
    final error = resolved.errorOrNull;
    if (error != null) return ExploreFailure(error);
    final r = resolved.dataOrNull!;
    final result = await _loadForContext(
      r,
      () => r.provider.loadOverview(_withResolvedOptions(request, r)),
    );
    return _attachOverviewTokens(result, r);
  }

  /// 漫画页（普通列表 / 榜单 / 分类结果 / 分区更多）。
  Future<ExploreResult<ExploreComicPage>> loadComics(
    ExploreRequest request,
  ) async {
    final resolved = validate(request);
    final error = resolved.errorOrNull;
    if (error != null) return ExploreFailure(error);
    final r = resolved.dataOrNull!;

    final result = await _loadForContext(
      r,
      () => r.provider.loadComics(_withResolvedOptions(request, r)),
    );
    return _attachTokens(result, r);
  }

  /// 分类目录。
  Future<ExploreResult<ExploreDirectory>> loadDirectory(
    ExploreRequest request,
  ) async {
    final resolved = validate(request);
    final error = resolved.errorOrNull;
    if (error != null) return ExploreFailure(error);
    final r = resolved.dataOrNull!;
    return _loadForContext(
      r,
      () => r.provider.loadDirectory(_withResolvedOptions(request, r)),
    );
  }

  /// 身份/站点在请求途中变化时，旧响应不得进入新上下文，也不得发放续页句柄。
  Future<ExploreResult<T>> _loadForContext<T>(
    ExploreResolvedRequest resolved,
    Future<ExploreResult<T>> Function() load,
  ) async {
    final provider = resolved.provider;
    final loggedIn = provider.isLoggedIn;
    if (provider.descriptor.requiresLogin && !loggedIn) {
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.loginRequired, '该源需要登录后才能浏览'),
      );
    }
    final fingerprint = provider.contextFingerprint;
    final result = await load();
    final current = providerOf(resolved.request.sourceKey);
    final currentLoggedIn = current?.isLoggedIn ?? false;
    if (current != null &&
        current.descriptor.requiresLogin &&
        !currentLoggedIn) {
      releaseSession(resolved.request.sessionId);
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.loginRequired, '登录状态已变化，请重新登录'),
      );
    }
    if (!identical(current, provider) ||
        currentLoggedIn != loggedIn ||
        current?.contextFingerprint != fingerprint) {
      releaseSession(resolved.request.sessionId);
      return const ExploreFailure(
        ExploreError(ExploreErrorCode.expiredContinuation, '账号或站点已变化，请重新加载'),
      );
    }
    return result;
  }

  /// 统一 `load`：按入口能力和目标自动分派。
  ///
  /// 无目标的分类/期号入口先展示目录，选中目标后加载漫画；普通推荐首屏
  /// 优先读取概览，仅在明确不支持概览时回落到列表。续页与单页随机直接读列表。
  Future<ExploreResult<Object>> load(ExploreRequest request) async {
    final resolved = validate(request);
    final error = resolved.errorOrNull;
    if (error != null) return ExploreFailure(error);
    final entry = resolved.dataOrNull!.entry;
    final hasTarget = request.category != null || request.categoryId != null;
    if (!hasTarget && request.continuation == null) {
      if (entry.kind == ExploreSectionKind.category || entry.directoryAsTab) {
        return _remap(await loadDirectory(request));
      }
      if (entry.kind == ExploreSectionKind.recommend && !entry.singlePage) {
        final overview = await loadOverview(request);
        if (overview.errorOrNull?.code != ExploreErrorCode.unsupported) {
          return _remap(overview);
        }
      }
    }
    return _remap(await loadComics(request));
  }

  static ExploreResult<Object> _remap<T>(ExploreResult<T> source) {
    final error = source.errorOrNull;
    if (error != null) return ExploreFailure(error);
    return ExploreSuccess<Object>(source.dataOrNull as Object);
  }

  ExploreRequest _withResolvedOptions(
    ExploreRequest request,
    ExploreResolvedRequest resolved,
  ) {
    return request.copyWith(
      entryId: resolved.entry.id,
      options: resolved.optionId == null
          ? ExploreOptions.none
          : ExploreOptions.single(resolved.optionId!),
      // 适配器只认源自己的游标（页码 / next 链接）：Registry 负责把 UI 传回来的
      // opaque 句柄解成游标。这样源适配器完全不需要知道会话与句柄编码的存在。
      continuation: resolved.isFirstPage ? null : resolved.cursor,
      clearContinuation: resolved.isFirstPage,
    );
  }

  /// 把适配器返回的"游标型"续页信息换成对上句柄。
  ///
  /// 适配器只负责说"还有下一页，游标是 X"；句柄绑定 sessionId/源/入口/选项/分类
  /// 由 Registry 统一完成，源适配器不需要（也不应该）知道会话的存在。
  ExploreResult<ExploreComicPage> _attachTokens(
    ExploreResult<ExploreComicPage> result,
    ExploreResolvedRequest resolved,
  ) {
    final page = result.dataOrNull;
    if (page == null) return result;
    if (page.isSinglePage || resolved.entry.singlePage) {
      return ExploreSuccess(ExploreComicPage(
        sourceKey: resolved.request.sourceKey,
        entryId: resolved.entry.id,
        items: page.items,
        optionId: resolved.optionId,
        categoryId: resolved.request.categoryId,
        nextToken: null,
        totalPages: resolved.entry.singlePage ? null : page.totalPages,
      ));
    }
    final rawCursor = page.nextToken;
    final token = mintContinuation(
      sessionId: resolved.request.sessionId,
      sourceKey: resolved.request.sourceKey,
      entryId: resolved.entry.id,
      optionId: resolved.optionId,
      category: resolved.request.category,
      cursor: rawCursor,
    );
    return ExploreSuccess(ExploreComicPage(
      sourceKey: resolved.request.sourceKey,
      entryId: resolved.entry.id,
      items: page.items,
      optionId: resolved.optionId,
      categoryId: resolved.request.categoryId,
      nextToken: token,
      totalPages: page.totalPages,
    ));
  }

  /// 概览分区里的 `moreEntryId` 不携带游标（首屏永远是首页），因此这里只做
  /// 分区错误与身份的整理；分区自身的续页在进入结果页后由 `loadComics` 发放。
  ExploreResult<ExploreOverview> _attachOverviewTokens(
    ExploreResult<ExploreOverview> result,
    ExploreResolvedRequest resolved,
  ) {
    final overview = result.dataOrNull;
    if (overview == null) return result;
    return ExploreSuccess(ExploreOverview(
      sourceKey: resolved.request.sourceKey,
      entryId: resolved.entry.id,
      sections: overview.sections,
    ));
  }
}

/// 校验通过后的解析结果。
class ExploreResolvedRequest {
  const ExploreResolvedRequest({
    required this.request,
    required this.provider,
    required this.entry,
    required this.optionId,
    required this.cursor,
    required this.isFirstPage,
  });

  final ExploreRequest request;
  final ExploreProvider provider;
  final ExploreEntry entry;
  final String? optionId;
  final String cursor;
  final bool isFirstPage;
}

/// 默认句柄编码：JSON + base64Url（不含凭据，可序列化）。
class _Base64ContinuationCodec implements ExploreContinuationCodec {
  const _Base64ContinuationCodec();

  @override
  String encode(ExploreContinuationToken token) {
    final payload = jsonEncode(<String, Object?>{
      's': token.sessionId,
      'k': token.sourceKey,
      'e': token.entryId,
      'o': token.optionKey,
      'c': token.categoryKey,
      'u': token.cursor,
    });
    return base64Url.encode(utf8.encode(payload));
  }

  @override
  ExploreContinuationToken? decode(String raw) {
    try {
      final decoded = utf8.decode(base64Url.decode(raw));
      final json = jsonDecode(decoded);
      if (json is! Map) return null;
      final cursor = json['u']?.toString() ?? '';
      if (cursor.isEmpty) return null;
      return ExploreContinuationToken(
        sessionId: json['s']?.toString() ?? '',
        sourceKey: json['k']?.toString() ?? '',
        entryId: json['e']?.toString() ?? '',
        optionKey: json['o']?.toString() ?? '',
        categoryKey: json['c']?.toString() ?? '',
        cursor: cursor,
      );
    } catch (_) {
      return null;
    }
  }
}
