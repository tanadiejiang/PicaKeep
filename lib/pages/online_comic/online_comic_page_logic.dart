import 'dart:async';

import 'package:flutter/material.dart';

import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/state_controller.dart';
import 'package:picakeep/network/res.dart';
import 'package:uuid/uuid.dart';

/// 通用在线漫画详情页的状态逻辑层。
///
/// 复用项目现有的 [StateController]（GetX 风格的轻量状态管理）。
/// 页面本体（[BaseOnlineComicPage]）保持 [StatelessWidget]，所有可变状态
/// 都外置到这里，通过 [StateBuilder] 绑定刷新。
///
/// 泛型 [T] 为各源站的详情数据模型（如 `PicacgComicItem` / `JmComicInfo`）。
class OnlineComicPageLogic<T> extends StateController {
  OnlineComicPageLogic({
    required this.loadData,
    this.loadFavoriteState,
    this.loadLikeState,
    this.onDataLoaded,
  });

  /// 详情数据加载入口，由子类页面提供（通常是某个 `XxxNetwork().getComicInfo(id)`）。
  final Future<Res<T>> Function() loadData;

  /// 收藏态加载入口（可选）。数据加载成功后调用，结果写入 [favorite]。
  /// 与原项目 `get()` 保持同一时机，避免收藏图标在数据出现后才闪现。
  final Future<bool> Function(T data)? loadFavoriteState;

  /// 点赞态加载入口（可选）。数据加载成功后调用，结果写入 [liked]。
  final Future<bool> Function(T data)? loadLikeState;

  /// Called once for each successful data load, outside widget build.
  final Future<void> Function(T data, String operationId)? onDataLoaded;

  /// 已加载到的详情数据；为 null 表示尚未加载成功。
  T? data;

  /// 错误信息；非 null 表示加载失败，进入错误态。
  String? error;

  /// 是否正在加载（初始为 true，首帧即骨架态）。
  bool loading = true;

  /// 本地/平台收藏态。子类可在 `onFavorite` 完成后通过 [setFavorite] 同步。
  bool favorite = false;

  /// 点赞态。子类可在 `onLike` 完成后通过 [setLiked] 同步。
  bool liked = false;

  /// 已下载状态。由 [checkDownloadedState] 异步设置。
  bool downloaded = false;

  /// 详情页滚动控制器，用于驱动 AppBar 标题随滚动渐显。
  final ScrollController scrollController = ScrollController();

  /// AppBar 标题是否显示（滚动越过封面高度阈值后为 true）。
  bool showAppbarTitle = false;

  /// 滚动渐显阈值（像素），对齐原项目封面高度 136。
  static const double _appbarTitleThreshold = 136;

  /// 防止首次加载被重复触发（builder 可能多次重建）。
  bool _loadStarted = false;

  int _loadGeneration = 0;

  /// 防止滚动监听被重复挂载。
  bool _scrollAttached = false;

  /// 由 builder 在首次构建时调用，安全地触发一次加载。
  ///
  /// 不在 builder 内同步调用 [update]，避免 build 期间 setState 报错——
  /// 这里把加载放进异步任务，加载结束后再 [update]。
  void startLoadingIfNeeded() {
    if (_loadStarted) return;
    _loadStarted = true;
    _load();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final operationId = 'online-${const Uuid().v4()}';
    final res = await loadData();
    if (generation != _loadGeneration) return;
    if (res.error) {
      error = res.errorMessageWithoutNull;
    } else {
      data = res.data;
      error = null;
      final dataObserver = onDataLoaded;
      if (dataObserver != null) {
        unawaited(dataObserver(res.data, operationId));
      }
      final loader = loadFavoriteState;
      if (loader != null) {
        try {
          favorite = await loader(res.data);
        } catch (_) {
          // 收藏态加载失败不影响详情展示。
        }
      }
      final likeLoader = loadLikeState;
      if (likeLoader != null) {
        try {
          liked = await likeLoader(res.data);
        } catch (_) {
          // 点赞态加载失败不影响详情展示。
        }
      }
    }
    loading = false;
    update();
  }

  /// 重试：重置为加载态并重新拉取。
  void retry() {
    data = null;
    error = null;
    loading = true;
    update();
    _load();
  }

  /// 由子类在收藏操作完成后调用，刷新收藏按钮图标。
  void setFavorite(bool value) {
    if (favorite == value) return;
    favorite = value;
    update();
  }

  /// 由子类在点赞操作完成后调用，刷新点赞按钮图标。
  void setLiked(bool value) {
    if (liked == value) return;
    liked = value;
    update();
  }

  /// 检测当前漫画是否已下载（本地库 + 下载数据库双通道）。
  Future<void> checkDownloadedState(List<String> candidates) async {
    try {
      final localItem =
          LocalLibraryManager().findCachedByCandidates(candidates);
      final result = localItem != null ||
          DownloadManager().resolveExistingId(candidates) != null;
      downloaded = result;
      update();
    } catch (_) {}
  }

  /// 在数据态首次构建时挂载滚动监听（只挂一次）。
  void attachScrollListener() {
    if (_scrollAttached) return;
    _scrollAttached = true;
    scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!scrollController.hasClients) return;
    final next = scrollController.position.pixels > _appbarTitleThreshold;
    if (next != showAppbarTitle) {
      showAppbarTitle = next;
      update();
    }
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }
}
