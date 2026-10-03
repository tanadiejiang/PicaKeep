/// 图集页「插画」视图的**内容区**：标签筛选条 + 瀑布流。
///
/// ## 为什么单独成文件
///
/// `lib/pages/local_library_page.dart` 是 2583 行单文件，新增 UI 一律另起文件
/// （24 号计划「风险或注意事项」第一条）。
///
/// ## 设计约束（逐条对应计划）
///
/// - **瀑布流只做插画侧**（决策 2）。图集条目没有宽高数据，做瀑布流要引入运行时
///   解码或持久化缓存，成本等级不同。
/// - **标签筛选只作用于插画侧**，且取数自 `LocalLibraryComicItem.tags`。
/// - **三种空态要分开**（计划「风险或注意事项」）：加载中 / 没有内容 /
///   筛选无匹配。用户此前对"整页转圈"明确表达过不满。
/// - **加载中的圈只出现在内容区域**。本控件只负责产出 sliver，
///   父页面的 `SliverAppBar` 与紧凑选择器始终在产品线上。
library;

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/pages/local_library_illust_card.dart';
import 'package:picakeep/tools/translations.dart';

/// 瀑布流的列间距（主轴与交叉轴同值）。
///
/// 卡片自身还有 [illustCardGap] 的外边距，两者相加才是视觉上的块间距。
/// 取 0 让"接近无边框"由卡片外边距单独控制，避免两套间距叠加后互相打架。
const double illustWaterfallSpacing = 0;

/// 插画视图内容区的四种状态（互斥）。
enum IllustContentState {
  /// 正在取数**且还没有任何数据** —— 只有这一种情况才转圈。
  loading,

  /// 取数完成但一条都没有（未下载过 Pixiv 内容 / 下载根不可用）。
  empty,

  /// 有数据，但被标签筛选筛空了。
  noTagMatch,

  /// 有数据可渲染（含"已有数据时的后台刷新"，那时不该把列表换掉）。
  content,
}

/// 决定内容区该显示哪种状态。
///
/// 抽成纯函数是为了能被直接单元测试：三种空态混淆过用户，不能只靠肉眼看 UI。
IllustContentState resolveIllustContentState({
  required bool loading,
  required int totalCount,
  required int filteredCount,
}) {
  // 顺序不能换：先"没数据 + 加载中"（转圈），再"没数据"（空态），
  // 最后才是"筛选无匹配"。反过来的话首帧会闪一下"暂无插画"。
  if (totalCount == 0) {
    return loading ? IllustContentState.loading : IllustContentState.empty;
  }
  if (filteredCount == 0) {
    return IllustContentState.noTagMatch;
  }
  return IllustContentState.content;
}

/// 插画视图的 sliver 列表。
class LocalLibraryIllustSlivers extends StatelessWidget {
  const LocalLibraryIllustSlivers({
    super.key,
    required this.allEntries,
    required this.entries,
    required this.tags,
    required this.selectedTags,
    required this.loading,
    required this.errorText,
    required this.columns,
    required this.itemBuilder,
    required this.onToggleTag,
    required this.onClearTags,
  });

  /// 筛前全量（用于区分"没有内容"与"筛选无匹配"）。
  final List<IllustLibraryEntry> allEntries;

  /// 筛后结果（真正渲染的那批）。
  final List<IllustLibraryEntry> entries;

  final List<IllustTagSummary> tags;
  final Set<String> selectedTags;
  final bool loading;
  final String? errorText;
  final int columns;

  /// 渲染单张卡片。父页面传进来，以复用它的点击 / 长按 / 多选 / 封面 provider。
  final Widget Function(BuildContext context, IllustLibraryEntry entry)
      itemBuilder;

  final ValueChanged<String> onToggleTag;
  final VoidCallback onClearTags;

  /// 瀑布流的 Key。测试用它拿到 `SliverMasonryGrid` 并断言真实列数 ——
  /// 列数是"布局结果"而不是常量，只断言常量等于没测。
  static const Key waterfallKey = Key('illust-waterfall');

  /// 标签筛选条的 Key。
  static const Key tagFilterBarKey = Key('illust-tag-filter-bar');

  /// 三种内容状态的 Key（测试据此区分"转圈"与两类空态）。
  static const Key loadingKey = Key('illust-content-loading');
  static const Key emptyKey = Key('illust-content-empty');
  static const Key noTagMatchKey = Key('illust-content-no-tag-match');

  @override
  Widget build(BuildContext context) {
    final state = resolveIllustContentState(
      loading: loading,
      totalCount: allEntries.length,
      filteredCount: entries.length,
    );
    return SliverMainAxisGroup(
      slivers: [
        if (tags.isNotEmpty)
          SliverToBoxAdapter(
            child: _IllustTagFilterBar(
              key: tagFilterBarKey,
              tags: tags,
              selectedTags: selectedTags,
              onToggleTag: onToggleTag,
              onClearTags: onClearTags,
            ),
          ),
        switch (state) {
          IllustContentState.loading => const SliverFillRemaining(
              key: loadingKey,
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            ),
          IllustContentState.empty => SliverFillRemaining(
              key: emptyKey,
              hasScrollBody: false,
              child: _IllustEmptyState(
                title: '暂无插画'.tl,
                description: _emptyDescription(errorText),
              ),
            ),
          IllustContentState.noTagMatch => SliverFillRemaining(
              key: noTagMatchKey,
              hasScrollBody: false,
              child: _IllustEmptyState(
                title: '没有匹配的标签'.tl,
                description: '试试取消几个标签'.tl,
                action: TextButton(
                  onPressed: onClearTags,
                  child: Text('清除筛选'.tl),
                ),
              ),
            ),
          IllustContentState.content => SliverPadding(
              padding: const EdgeInsets.fromLTRB(2, 0, 2, 96),
              sliver: SliverMasonryGrid.count(
                key: waterfallKey,
                crossAxisCount: columns,
                mainAxisSpacing: illustWaterfallSpacing,
                crossAxisSpacing: illustWaterfallSpacing,
                childCount: entries.length,
                itemBuilder: (context, index) =>
                    itemBuilder(context, entries[index]),
              ),
            ),
        },
      ],
    );
  }

  static String _emptyDescription(String? errorText) {
    final error = errorText?.trim() ?? '';
    if (error.isNotEmpty) {
      return error;
    }
    return '还没有下载过 Pixiv 插画，可在详情页选择「插画」下载'.tl;
  }
}

/// 横向滚动的标签筛选条。
class _IllustTagFilterBar extends StatelessWidget {
  const _IllustTagFilterBar({
    super.key,
    required this.tags,
    required this.selectedTags,
    required this.onToggleTag,
    required this.onClearTags,
  });

  final List<IllustTagSummary> tags;
  final Set<String> selectedTags;
  final ValueChanged<String> onToggleTag;
  final VoidCallback onClearTags;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          if (selectedTags.isNotEmpty)
            IconButton(
              tooltip: '清除筛选'.tl,
              icon: const Icon(Icons.filter_alt_off_outlined, size: 20),
              onPressed: onClearTags,
            ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              itemCount: tags.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final summary = tags[index];
                final selected = selectedTags.contains(summary.tag);
                return FilterChip(
                  key: ValueKey('illust-tag-${summary.tag}'),
                  label: Text('${summary.tag} (${summary.count})'),
                  selected: selected,
                  showCheckmark: false,
                  labelStyle: theme.textTheme.labelMedium,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (_) => onToggleTag(summary.tag),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 空态：图标 + 标题 + 说明 +（可选）操作按钮。
class _IllustEmptyState extends StatelessWidget {
  const _IllustEmptyState({
    required this.title,
    required this.description,
    this.action,
  });

  final String title;
  final String description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_outlined,
              size: 40,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              description,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: 8),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 取一条插画条目的封面 provider。
///
/// **唯一合法入口**。绝不要换成 `FileImage`：特权模式下会整片破图
/// （见 `foundation/local_library.dart:1213-1220` 的根因注释）。
ImageProvider<Object>? illustCoverProviderFor(LocalLibraryComicItem item) {
  return LocalLibraryManager().coverImageProviderForItem(item);
}
