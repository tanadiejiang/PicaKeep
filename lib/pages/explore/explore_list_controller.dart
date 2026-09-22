/// 探索列表的公共控制器。
///
/// 概览 / 榜单 / 分类 / 分区更多 / 随机共用同一份加载、续页、去重、屏蔽过滤与
/// 竞态处理逻辑，避免每个页面各写一遍。
library;

import 'package:flutter/foundation.dart';
import 'package:picakeep/foundation/explore/explore_models.dart';
import 'package:picakeep/foundation/explore/explore_registry.dart';
import 'package:picakeep/network/base_comic.dart';

/// 列表的一个可见条目（保留原始条目，便于屏蔽占位展示）。
class ExploreListItem {
  const ExploreListItem({
    required this.comic,
    required this.blockedBy,
  });

  final BaseComic comic;

  /// 命中的屏蔽词；为空表示未屏蔽。
  final String? blockedBy;

  bool get isBlocked => blockedBy != null;

  /// 去重身份：源 key + 原始 id。`BaseComic` 自身没有来源字段，因此由控制器
  /// 带上来源。
  String dedupeKeyOf(String sourceKey) => '$sourceKey\u0000${comic.id}';
}

/// 列表状态快照。
class ExploreListState {
  const ExploreListState({
    this.items = const <ExploreListItem>[],
    this.loading = false,
    this.loadingMore = false,
    this.error,
    this.moreError,
    this.hasMore = false,
    this.totalPages,
    this.optionId,
  });

  final List<ExploreListItem> items;
  final bool loading;

  /// 是否正在追加下一页（与首次 loading 区分，页尾显示独立指示器）。
  final bool loadingMore;

  /// 首次加载/刷新的错误。
  final ExploreError? error;

  /// 追加失败：**必须保留旧条目与 token**，页尾给手动重试。
  final ExploreError? moreError;

  final bool hasMore;
  final int? totalPages;
  final String? optionId;

  /// 原始（未过滤）条目是否为空但仍有下一页：过滤后为空时仍可继续加载。
  bool get isEmpty => items.every((item) => item.isBlocked);

  bool get hasVisibleItems => items.any((item) => !item.isBlocked);

  ExploreListState copyWith({
    List<ExploreListItem>? items,
    bool? loading,
    bool? loadingMore,
    ExploreError? error,
    bool clearError = false,
    ExploreError? moreError,
    bool clearMoreError = false,
    bool? hasMore,
    int? totalPages,
    String? optionId,
  }) {
    return ExploreListState(
      items: items ?? this.items,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      error: clearError ? null : (error ?? this.error),
      moreError: clearMoreError ? null : (moreError ?? this.moreError),
      hasMore: hasMore ?? this.hasMore,
      totalPages: totalPages ?? this.totalPages,
      optionId: optionId ?? this.optionId,
    );
  }
}

/// 屏蔽判定回调：返回命中的关键词，未命中返回 null。
typedef ExploreBlockingResolver = String? Function(BaseComic comic);

class ExploreListController extends ChangeNotifier {
  ExploreListController({
    required this.registry,
    required this.sourceKey,
    required this.entryId,
    required this.sessionId,
    this.blockingResolver,
  });

  final ExploreRegistry registry;
  final String sourceKey;
  final String entryId;
  final String sessionId;

  /// 为空表示不做屏蔽过滤（保持原始列表）。
  ExploreBlockingResolver? blockingResolver;

  ExploreListState get state => _state;
  ExploreListState _state = const ExploreListState();

  /// 请求代次：切源/选项/分类/刷新都自增；异步回调只提交到匹配代次。
  int _generation = 0;

  /// 当前分类/期号等目标快照。
  ExploreCategoryTarget? _category;
  String? _categoryId;

  /// 当前选项快照。
  ///
  /// 必须**原样保存**并用于续页：无选项入口若在续页时发送
  /// `ExploreOptions.single('')`，会被 Registry 判成"该入口不接受选项"而失败。
  ExploreOptions _options = ExploreOptions.none;

  /// 当前续页句柄（opaque token）。
  String? _nextToken;

  /// 同一列表一次只加载一页。
  bool _inFlight = false;

  /// 已提交的原始页签名（检测"有 next 但连续返回同一页"的异常）。
  String? _lastPageSignature;

  bool _disposed = false;

  String? get nextToken => _nextToken;

  ExploreCategoryTarget? get category => _category;

  String? get categoryId => _categoryId;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 首次加载 / 切换目标 / 刷新。
  ///
  /// [category] 与 [categoryId] 一起切换；[optionId] 通过 request 传入。
  Future<void> load({
    ExploreOptions options = ExploreOptions.none,
    ExploreCategoryTarget? category,
    String? categoryId,
    bool clearCategory = false,
  }) async {
    if (_disposed) return;
    _generation++;
    final generation = _generation;
    _inFlight = true;
    _category = clearCategory ? null : (category ?? _category);
    _categoryId = clearCategory ? null : (categoryId ?? _categoryId);
    _options = options;
    _nextToken = null;
    _lastPageSignature = null;
    _state = ExploreListState(
      loading: true,
      optionId: options.first,
    );
    _notify();

    final result = await registry.loadComics(ExploreRequest(
      sessionId: sessionId,
      sourceKey: sourceKey,
      entryId: entryId,
      options: options,
      category: _category,
      categoryId: _categoryId,
    ));

    if (_disposed || generation != _generation) return;
    _inFlight = false;
    final error = result.errorOrNull;
    if (error != null) {
      _state = _state.copyWith(loading: false, error: error);
      _notify();
      return;
    }
    final page = result.dataOrNull!;
    _nextToken = page.nextToken;
    _lastPageSignature = _signatureOf(page.items);
    _state = ExploreListState(
      items: _mapItems(page.items),
      hasMore: page.hasMore,
      totalPages: page.totalPages,
      optionId: options.first,
    );
    _notify();
  }

  /// 追加下一页。失败时保留旧条目与 token，并把错误放在页尾。
  Future<void> loadMore() async {
    final token = _nextToken;
    if (_disposed || _inFlight || token == null) return;
    final generation = _generation;
    _inFlight = true;
    _state = _state.copyWith(loadingMore: true, clearMoreError: true);
    _notify();

    final result = await registry.loadComics(ExploreRequest(
      sessionId: sessionId,
      sourceKey: sourceKey,
      entryId: entryId,
      options: _options,
      category: _category,
      categoryId: _categoryId,
      continuation: token,
    ));

    if (_disposed || generation != _generation) return;
    _inFlight = false;
    final error = result.errorOrNull;
    if (error != null) {
      // token 保持原样：用户可用同一个 token 重试。
      _state = _state.copyWith(loadingMore: false, moreError: error);
      _notify();
      return;
    }
    final page = result.dataOrNull!;
    final signature = _signatureOf(page.items);

    // 有 next 但连续返回同一原始页 → 停止自动追页并给可重试异常，避免死循环。
    if (signature != null &&
        signature == _lastPageSignature &&
        page.nextToken != null) {
      _nextToken = null;
      _state = _state.copyWith(
        loadingMore: false,
        hasMore: false,
        moreError: const ExploreError(
          ExploreErrorCode.parse,
          '服务端连续返回同一页，已停止自动加载',
        ),
      );
      _notify();
      return;
    }

    final merged = List<ExploreListItem>.from(_state.items);
    final seen = <String>{
      for (final item in merged) item.dedupeKeyOf(sourceKey),
    };
    for (final item in _mapItems(page.items)) {
      final key = item.dedupeKeyOf(sourceKey);
      if (seen.add(key)) merged.add(item);
    }

    _lastPageSignature = signature;
    _nextToken = page.nextToken;
    _state = _state.copyWith(
      items: merged,
      loadingMore: false,
      hasMore: page.hasMore,
      totalPages: page.totalPages,
      clearMoreError: true,
    );
    _notify();
  }

  /// 单页入口的"换一批"：替换当前批次，不追加。
  Future<void> reloadBatch({
    ExploreOptions options = ExploreOptions.none,
  }) async {
    await load(options: options, clearCategory: true);
  }

  /// 释放会话（页面销毁时调用，幂等）。
  void releaseSession() => registry.releaseSession(sessionId);

  /// 屏蔽设置变化后重算现有条目（保留位置，不重新请求）。
  void applyBlockingResolver(ExploreBlockingResolver? resolver) {
    blockingResolver = resolver;
    if (_disposed) return;
    _state =
        _state.copyWith(items: _mapItems(_state.items.map((e) => e.comic)));
    _notify();
  }

  List<ExploreListItem> _mapItems(Iterable<BaseComic> comics) {
    final resolver = blockingResolver;
    return <ExploreListItem>[
      for (final comic in comics)
        ExploreListItem(
          comic: comic,
          blockedBy: resolver?.call(comic),
        ),
    ];
  }

  String? _signatureOf(List<BaseComic> items) {
    if (items.isEmpty) return '';
    return items.map((e) => e.id).join(',');
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }
}
