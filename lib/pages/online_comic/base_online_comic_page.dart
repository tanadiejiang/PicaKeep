import 'package:flutter/material.dart';

import 'package:picakeep/foundation/state_controller.dart';
import 'package:picakeep/network/res.dart';

import 'online_comic_page_components.dart';
import 'online_comic_page_logic.dart';

/// 通用在线漫画详情页基类。
///
/// 子类只需实现少量 `extractXxx()` 数据适配方法与交互回调，基类负责构建完整
/// 的详情页 UI（封面信息区、动作按钮、标签区、章节区、简介区、推荐区），
/// 并处理加载/错误/数据三态、刷新重试、AppBar 标题随滚动渐显。
///
/// 泛型 [T] 为各源站的详情数据模型。参见 `docs/新增在线源站接入指南.md`。
///
/// 注意：交互回调（[onRead] / [onDownload] / [onFavorite] / [onTagTap] 等）
/// 都接收 [BuildContext]，因为子类是 [StatelessWidget]，导航与弹窗都需要 context。
abstract class BaseOnlineComicPage<T> extends StatelessWidget {
  const BaseOnlineComicPage({super.key});

  // ==========================================================
  // 强制实现：数据加载
  // ==========================================================

  /// 加载详情数据（核心网络入口）。
  Future<Res<T>> loadData();

  /// 状态管理唯一标识，用于区分同时打开的多个详情页。
  /// 建议形如 `'$sourceKey_$id'`。
  String get tag;

  // ==========================================================
  // 强制实现：基础信息
  // ==========================================================

  /// 漫画 ID。
  String get id;

  /// 源站标识（如 `'jm'`、`'picacg'`），用于搜索/图片等。
  String get sourceKey;

  /// 源站显示名称（可用 `'xxx'.tl` 翻译）。
  String get source;

  /// 从数据提取标题。
  String? extractTitle(T data);

  /// 从数据提取封面 URL。
  String? extractCover(T data);

  /// 从数据提取标签分组：key = 分类名，value = 该类标签。
  Map<String, List<String>>? extractTags(T data);

  // ==========================================================
  // 强制实现：交互行为
  // ==========================================================

  /// 标签点击/搜索。
  void onTagTap(BuildContext context, String tag, String category);

  /// 阅读。[ep] 为 1-based 章节序号。
  void onRead(BuildContext context, T data, {int ep});

  /// 下载。
  void onDownload(BuildContext context, T data);

  /// 收藏（点击收藏按钮）。完成后可通过 [refreshFavorite] 同步图标。
  void onFavorite(BuildContext context, T data);

  /// 加载收藏态（数据加载成功后调用）。
  Future<bool> loadFavoriteState(T data);

  // ==========================================================
  // 可选重写：附加信息
  // ==========================================================

  /// 副标题（通常是作者）。
  String? extractSubTitle(T data) => null;

  /// 简介。
  String? extractDescription(T data) => null;

  /// 总页数。
  int? extractPages(T data) => null;

  /// 浏览量。
  int? extractViews(T data) => null;

  /// 点赞数。
  int? extractLikes(T data) => null;

  /// 评论数。
  int? extractComments(T data) => null;

  /// 章节显示名列表（null 或空 = 无章节，隐藏章节区）。
  List<String>? extractEpisodes(T data) => null;

  /// 相关推荐（null 或空 = 隐藏推荐区）。
  List<OnlineComicRecommendation>? extractRecommendation(T data) => null;

  // ==========================================================
  // 可选重写：附加交互
  // ==========================================================

  /// 喜欢/点赞回调（非 null 才显示喜欢按钮）。
  void Function(BuildContext context, T data)? get onLike => null;

  /// 评论回调（非 null 才显示评论按钮）。
  void Function(BuildContext context, T data)? get onComment => null;

  /// 章节长按回调（如 JM 强制在线阅读）。
  void Function(BuildContext context, T data, int ep)? get onEpisodeLongPress =>
      null;

  /// 推荐项点击回调。默认无操作。
  void onRecommendationTap(BuildContext context, T data, int index) {}

  /// 图片请求头（JM 封面需 `getJmImgHeaders()`，picacg 返回 null）。
  Map<String, String>? get imageHeaders => null;

  /// 章节区标题下方的说明文案。
  String? get episodesSubtitle => null;

  /// 在标签区之后、章节区之前插入的自定义区块（可选）。
  Widget? buildCustomSection(BuildContext context, T data) => null;

  // ==========================================================
  // 内部辅助
  // ==========================================================

  /// 按 [tag] 查找当前页面的逻辑层实例。
  OnlineComicPageLogic<T> get _logic =>
      StateController.find<OnlineComicPageLogic<T>>(tag: tag);

  /// 供子类在收藏操作完成后同步收藏按钮图标。
  @protected
  void refreshFavorite(bool value) => _logic.setFavorite(value);

  /// 数字格式化（万位显示，如 12345 → 1.2万）。
  String _formatNumber(int n) {
    if (n < 10000) return n.toString();
    return '${(n / 10000).toStringAsFixed(1)}万';
  }

  // ==========================================================
  // build
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StateBuilder<OnlineComicPageLogic<T>>(
        tag: tag,
        init: OnlineComicPageLogic<T>(
          loadData: loadData,
          loadFavoriteState: loadFavoriteState,
        ),
        builder: (logic) {
          logic.startLoadingIfNeeded();
          return CustomScrollView(
            controller: logic.scrollController,
            slivers: [
              _buildAppBar(context, logic),
              if (logic.loading)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: OnlineComicLoadingView(),
                )
              else if (logic.error != null)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: OnlineComicErrorView(
                    error: logic.error!,
                    onRetry: logic.retry,
                  ),
                )
              else if (logic.data != null)
                ..._buildContent(context, logic, logic.data as T),
            ],
          );
        },
      ),
    );
  }

  Widget _buildAppBar(BuildContext context, OnlineComicPageLogic<T> logic) {
    final data = logic.data;
    final title = data == null ? null : extractTitle(data as T);
    return SliverAppBar(
      pinned: true,
      title: AnimatedOpacity(
        opacity: logic.showAppbarTitle && title != null ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: Text(title ?? ''),
      ),
    );
  }

  List<Widget> _buildContent(
      BuildContext context, OnlineComicPageLogic<T> logic, T data) {
    // 数据态首次构建时挂载滚动监听（attachScrollListener 内部去重）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      logic.attachScrollListener();
    });

    final custom = buildCustomSection(context, data);
    final tags = extractTags(data);
    final description = extractDescription(data);
    final episodes = extractEpisodes(data);
    final recommendation = extractRecommendation(data);

    return [
      SliverList(
        delegate: SliverChildListDelegate([
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInfoSection(context, data),
                const SizedBox(height: 20),
                _buildActions(context, logic, data),
                const SizedBox(height: 20),
                const Divider(),
                if (tags != null && tags.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('信息', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  OnlineComicTagsSection(
                    tags: tags,
                    onTagTap: (t, c) => onTagTap(context, t, c),
                  ),
                  const SizedBox(height: 16),
                  const Divider(),
                ],
                if (custom != null) ...[
                  const SizedBox(height: 12),
                  custom,
                  const SizedBox(height: 16),
                  const Divider(),
                ],
                if (description != null && description.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('简介', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Text(description,
                      style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 16),
                  const Divider(),
                ],
                if (episodes != null && episodes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  OnlineComicEpisodesList(
                    episodes: episodes,
                    subtitle: episodesSubtitle,
                    onEpisodeTap: (ep) => onRead(context, data, ep: ep),
                    onEpisodeLongPress: onEpisodeLongPress == null
                        ? null
                        : (ep) => onEpisodeLongPress!(context, data, ep),
                  ),
                ],
                if (recommendation != null && recommendation.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 12),
                  Text('相关推荐',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  OnlineComicRecommendationGrid(
                    comics: recommendation,
                    headers: imageHeaders,
                    onComicTap: (i) => onRecommendationTap(context, data, i),
                  ),
                ],
                SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
              ],
            ),
          ),
        ]),
      ),
    ];
  }

  Widget _buildInfoSection(BuildContext context, T data) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final title = extractTitle(data) ?? '';
    final subTitle = extractSubTitle(data);
    final pages = extractPages(data);
    final views = extractViews(data);
    final likes = extractLikes(data);
    final comments = extractComments(data);

    final stats = <Widget>[];
    void addStat(IconData icon, String text) {
      if (stats.isNotEmpty) stats.add(const SizedBox(width: 12));
      stats.add(Icon(icon, size: 16));
      stats.add(const SizedBox(width: 4));
      stats.add(Text(text,
          style: textTheme.bodySmall
              ?.copyWith(color: colorScheme.onSurfaceVariant)));
    }

    if (views != null) addStat(Icons.visibility_outlined, _formatNumber(views));
    if (likes != null) addStat(Icons.thumb_up_outlined, _formatNumber(likes));
    if (comments != null) {
      addStat(Icons.comment_outlined, _formatNumber(comments));
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OnlineComicCover(
          url: extractCover(data) ?? '',
          headers: imageHeaders,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: textTheme.titleLarge),
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Icons.tag, size: 16),
                const SizedBox(width: 4),
                Expanded(
                  child: SelectableText(
                    'ID: $id · $source',
                    maxLines: 1,
                    style: textTheme.bodySmall
                        ?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ),
              ]),
              if (subTitle != null && subTitle.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.person_outline, size: 16),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(subTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium),
                  ),
                ]),
              ],
              if (pages != null) ...[
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.menu_book_outlined, size: 16),
                  const SizedBox(width: 4),
                  Text('$pages 页',
                      style: textTheme.bodySmall
                          ?.copyWith(color: colorScheme.onSurfaceVariant)),
                ]),
              ],
              if (stats.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(children: stats),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildActions(
      BuildContext context, OnlineComicPageLogic<T> logic, T data) {
    final comments = extractComments(data);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        OnlineComicActionButton(
          icon: Icons.menu_book_outlined,
          label: '阅读',
          onTap: () => onRead(context, data, ep: 1),
        ),
        OnlineComicActionButton(
          icon: Icons.download_outlined,
          label: '下载',
          onTap: () => onDownload(context, data),
        ),
        OnlineComicActionButton(
          icon: logic.favorite ? Icons.favorite : Icons.favorite_outline,
          label: '收藏',
          onTap: () => onFavorite(context, data),
        ),
        if (onLike != null)
          OnlineComicActionButton(
            icon: Icons.thumb_up_outlined,
            label: '喜欢',
            onTap: () => onLike!(context, data),
          ),
        if (onComment != null)
          OnlineComicActionButton(
            icon: Icons.comment_outlined,
            label: '评论',
            badge: (comments != null && comments > 0)
                ? _formatNumber(comments)
                : null,
            onTap: () => onComment!(context, data),
          ),
      ],
    );
  }



}
