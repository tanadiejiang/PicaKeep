import 'package:flutter/material.dart';

import 'package:picakeep/components/info_value_action.dart';
import 'package:picakeep/foundation/state_controller.dart';
import 'package:picakeep/foundation/untranslated_tags/untranslated_tag_coordinator.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/tools/tags_translation.dart';

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

  /// 是否启用标签中文翻译。eh/nh 源重写返回 true，jm/picacg 保持默认 false。
  bool get enableTagTranslation => false;

  /// 阅读。[ep] 为 1-based 章节序号。
  void onRead(BuildContext context, T data, {int ep});

  /// 下载。
  void onDownload(BuildContext context, T data);

  /// 收藏（点击收藏按钮）。完成后可通过 [refreshFavorite] 同步图标。
  void onFavorite(BuildContext context, T data);

  /// 加载收藏态（数据加载成功后调用）。
  Future<bool> loadFavoriteState(T data);

  /// 加载点赞态（数据加载成功后调用，默认 false）。
  /// 有点赞功能的源重写此方法，使点赞图标在进入页面时即反映已赞状态。
  Future<bool> loadLikeState(T data) async => false;

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

  /// 分享回调（非 null 才显示分享图标）。
  void Function(BuildContext context, T data)? get onShare => null;

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

  /// 替换默认 [OnlineComicTagsSection] 的自定义标签区（可选）。
  ///
  /// 返回非 null 时，完全替代默认渲染；返回 null 则走默认逻辑。
  /// nhentai 用此钩子实现「ID 行置顶 + 页数/时间合并行」，其它源不重写。
  Widget? buildTagsSectionOverride(
          BuildContext context, T data, Map<String, List<String>> tags) =>
      null;

  // ==========================================================
  // 内部辅助
  // ==========================================================

  /// 按 [tag] 查找当前页面的逻辑层实例。
  OnlineComicPageLogic<T> get _logic =>
      StateController.find<OnlineComicPageLogic<T>>(tag: tag);

  /// 供子类在收藏操作完成后同步收藏按钮图标。
  @protected
  void refreshFavorite(bool value) => _logic.setFavorite(value);

  /// 供子类在点赞操作完成后同步点赞按钮图标。
  @protected
  void refreshLiked(bool value) => _logic.setLiked(value);

  /// 当前收藏态（子类 onFavorite 里据此正确 toggle，而非用不可变的 data 原始值）。
  @protected
  bool get currentFavorite => _logic.favorite;

  /// 当前点赞态。
  @protected
  bool get currentLiked => _logic.liked;

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
          loadLikeState: onLike == null ? null : loadLikeState,
          onDataLoaded: _observeUntranslatedTags,
        ),
        builder: (logic) {
          logic.startLoadingIfNeeded();
          // 点击空白/非文字处清除信息区选中态：点击时让 SelectionArea 失焦，
          // SelectableRegion 焦点丢失即原生清空选区。translucent 不挡子级点击/滚动/长按选中。
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => FocusScope.of(context).unfocus(),
            child: CustomScrollView(
              controller: logic.scrollController,
              slivers: [
                _buildAppBar(context, logic),
                if (logic.loading)
                  const SliverToBoxAdapter(
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
            ),
          );
        },
      ),
    );
  }

  Future<void> _observeUntranslatedTags(T data, String operationId) async {
    if (sourceKey != 'ehentai' && sourceKey != 'nhentai') return;
    try {
      if (!tagTranslationsReady) {
        try {
          await loadTagTranslations();
        } catch (_) {
          // The collector keeps a bounded observation queue until retry.
        }
      }
      // A search/local/read observation may have arrived before the shared
      // translation table finished loading.  Flush that complete operation
      // before adding this detail observation so readiness does not silently
      // strand earlier tags until an unrelated future observation.
      if (tagTranslationsReady) {
        await UntranslatedTagCoordinator.instance.flushPending();
      }
      final tags = extractTags(data);
      if (tags == null || tags.isEmpty) return;
      await UntranslatedTagCoordinator.instance.observe(
        UntranslatedTagObservation(
          source: sourceKey,
          comicId: id,
          operationId: operationId,
          context: 'online-detail',
          categorized: tags,
        ),
      );
    } catch (_) {
      // Collection is diagnostic side data and must not change page behavior.
    }
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
                  buildTagsSectionOverride(context, data, tags) ??
                      OnlineComicTagsSection(
                        tags: tags,
                        onTagTap: (t, c) => onTagTap(context, t, c),
                        enableTagTranslation: enableTagTranslation,
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
                  Text('相关推荐', style: Theme.of(context).textTheme.titleSmall),
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
    final pages = extractPages(data);
    final views = extractViews(data);
    final comments = extractComments(data);

    Widget valueAction({
      required String displayText,
      String? rawSearchValue,
      required Widget child,
    }) {
      final normalized = (rawSearchValue ?? displayText).trim();
      return InfoValueAction(
        data: InfoValueData(
          displayText: displayText,
          rawSearchValue: normalized,
        ),
        onSearch:
            normalized.isEmpty ? null : () => onTagTap(context, normalized, ''),
        child: child,
      );
    }

    final stats = <Widget>[];
    void addStat(IconData icon, String displayText, String rawValue) {
      stats.add(
        valueAction(
          displayText: displayText,
          rawSearchValue: rawValue,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16),
              const SizedBox(width: 4),
              Text(
                displayText,
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    if (views != null) {
      addStat(Icons.visibility_outlined, _formatNumber(views), '$views');
    }
    if (comments != null) {
      addStat(Icons.comment_outlined, _formatNumber(comments), '$comments');
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
              valueAction(
                displayText: title,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(title, style: textTheme.titleMedium),
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Icons.public, size: 16),
                const SizedBox(width: 4),
                Expanded(
                  child: valueAction(
                    displayText: source,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        source,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall
                            ?.copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                ),
              ]),
              if (pages != null) ...[
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.menu_book_outlined, size: 16),
                  const SizedBox(width: 4),
                  valueAction(
                    displayText: '$pages 页',
                    rawSearchValue: '$pages',
                    child: Text(
                      '$pages 页',
                      style: textTheme.bodySmall
                          ?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                ]),
              ],
              if (stats.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(spacing: 12, runSpacing: 4, children: stats),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildActions(
      BuildContext context, OnlineComicPageLogic<T> logic, T data) {
    final likes = extractLikes(data);

    // 上排图标行：从头开始 / 分享 / 收藏 / 赞 / 评论
    final iconActions = <Widget>[
      OnlineComicIconAction(
        icon: Icons.play_circle_outline,
        label: '从头开始',
        onTap: () => onRead(context, data, ep: 1),
      ),
      if (onShare != null)
        OnlineComicIconAction(
          icon: Icons.share_outlined,
          label: '分享',
          onTap: () => onShare!(context, data),
        ),
      OnlineComicIconAction(
        icon: logic.favorite ? Icons.bookmark : Icons.bookmark_border,
        label: '收藏',
        active: logic.favorite,
        onTap: () => onFavorite(context, data),
      ),
      if (onLike != null)
        OnlineComicIconAction(
          icon: logic.liked ? Icons.thumb_up : Icons.thumb_up_outlined,
          label: likes != null ? _formatNumber(likes) : '喜欢',
          active: logic.liked,
          onTap: () => onLike!(context, data),
        ),
      if (onComment != null)
        OnlineComicIconAction(
          icon: Icons.chat_bubble_outline,
          label: '评论',
          onTap: () => onComment!(context, data),
        ),
    ];

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [for (final a in iconActions) Expanded(child: a)],
        ),
        const SizedBox(height: 16),
        // 下排两个大胶囊：下载 / 阅读
        Row(
          children: [
            Expanded(
              child: OnlineComicPillButton(
                label: '下载',
                onTap: () => onDownload(context, data),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OnlineComicPillButton(
                label: '阅读',
                filled: true,
                onTap: () => onRead(context, data, ep: 1),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
