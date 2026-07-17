import 'package:flutter/material.dart';
import 'package:shimmer_animation/shimmer_animation.dart';
import 'package:picakeep/components/info_value_action.dart';
import 'package:picakeep/tools/tags_translation.dart'
    show tagTranslateCategory, tagTranslateWithNs;

/// 通用在线漫画详情页的可复用 UI 组件集合。
///
/// 这些组件全部不依赖具体数据模型——上层 [BaseOnlineComicPage] 先用
/// `extractXxx()` 把各源站数据适配成普通字段/回调，再传进来。
/// 视觉风格对齐现有 PicaCG / JM 详情页（_ActionButton、_InfoChip 等）。

// ============================================================
// 推荐项轻量模型
// ============================================================

/// 相关推荐的轻量数据载体。
///
/// 各源站推荐项结构不一（picacg 是 Brief、JM 无推荐），统一映射成这个类型，
/// 避免推荐区耦合具体模型。
class OnlineComicRecommendation {
  const OnlineComicRecommendation({
    required this.title,
    required this.cover,
    this.subTitle,
  });

  final String title;
  final String cover;
  final String? subTitle;
}

// ============================================================
// 网络封面图（统一 Image.network + 占位 + 可选 headers）
// ============================================================

/// 在线封面图。项目无 cached_network_image，统一用 [Image.network] + errorBuilder。
/// JM 封面需要 [headers]（`getJmImgHeaders()`），picacg 传 null 即可。
class OnlineComicCover extends StatelessWidget {
  const OnlineComicCover({
    super.key,
    required this.url,
    this.headers,
    this.width = 120,
    this.height = 168,
    this.radius = 8,
  });

  final String url;
  final Map<String, String>? headers;
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    Widget placeholder() => Container(
          width: width,
          height: height,
          color: colorScheme.surfaceContainerHighest,
          child: const Icon(Icons.broken_image_outlined),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: url.isEmpty
          ? placeholder()
          : Image.network(
              url,
              width: width,
              height: height,
              fit: BoxFit.cover,
              headers: headers,
              errorBuilder: (_, __, ___) => placeholder(),
            ),
    );
  }
}

// ============================================================
// 加载态 / 错误态 / 空态
// ============================================================

/// 统一错误视图（取代两处私有 _ErrorView）。
class OnlineComicErrorView extends StatelessWidget {
  const OnlineComicErrorView({
    super.key,
    required this.error,
    required this.onRetry,
  });

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 统一加载态：与数据态布局同构的骨架屏。
///
/// 结构严格对齐 [BaseOnlineComicPage] 的 `_buildContent` 真实区块顺序，
/// 占位尺寸（封面 120×168、按钮行、标签行、章节 2 列网格）与真实组件一致，
/// 数据到达后替换无明显跳变。整片用 [Shimmer] 包裹做流光，子级为半透明灰块。
///
/// 一处改全源生效：JM / Picacg 及未来所有接入基类的源共用此加载态。
class OnlineComicLoadingView extends StatelessWidget {
  const OnlineComicLoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 占位块统一色：半透明 surfaceContainerHighest，与原项目 buildLoading 一致。
    final blockColor = cs.surfaceContainerHighest.withValues(alpha: 0.4);

    Widget bar({double? width, double height = 16, double radius = 8}) =>
        Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: blockColor,
            borderRadius: BorderRadius.circular(radius),
          ),
        );

    // 顶部圆形图标动作占位（对齐 OnlineComicIconAction：44 圆 + 下方小标签）。
    Widget iconAction() => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: blockColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(height: 8),
            bar(width: 28, height: 8, radius: 4),
          ],
        );

    return Shimmer(
      color: cs.surfaceContainerHighest,
      colorOpacity: 0.5,
      child: Padding(
        // 与数据态 _buildContent 外层同构。
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 封面 + 信息区（对齐 _buildInfoSection）──
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 封面：与 OnlineComicCover 默认 120×168 / radius 8 一致。
                Container(
                  width: 120,
                  height: 168,
                  decoration: BoxDecoration(
                    color: blockColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      bar(height: 20), // 标题行
                      const SizedBox(height: 8),
                      bar(width: 100, height: 12), // 源
                      const SizedBox(height: 10),
                      bar(width: 140, height: 12), // 统计行
                      const SizedBox(height: 10),
                      bar(width: 80, height: 12),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // ── 动作按钮区（对齐 _buildActions：图标行 + 两大胶囊）──
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [for (var i = 0; i < 5; i++) iconAction()],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: bar(height: 48, radius: 24)),
                const SizedBox(width: 12),
                Expanded(child: bar(height: 48, radius: 24)),
              ],
            ),
            const SizedBox(height: 20),
            const Divider(),
            // ── 信息标签区（对齐 OnlineComicTagsSection 若干行）──
            const SizedBox(height: 12),
            bar(width: 40, height: 16), // 「信息」标题
            const SizedBox(height: 12),
            for (var i = 0; i < 3; i++) ...[
              Row(
                children: [
                  bar(width: 56, height: 28, radius: 10),
                  const SizedBox(width: 6),
                  bar(width: 72, height: 28, radius: 10),
                  const SizedBox(width: 6),
                  bar(width: 60, height: 28, radius: 10),
                ],
              ),
              const SizedBox(height: 6),
            ],
            const SizedBox(height: 10),
            const Divider(),
            // ── 章节区占位（对齐 OnlineComicEpisodesList 2 列网格）──
            const SizedBox(height: 12),
            bar(width: 80, height: 16), // 「章节 (N)」标题
            const SizedBox(height: 12),
            for (var row = 0; row < 3; row++) ...[
              Row(
                children: [
                  Expanded(child: bar(height: 44, radius: 8)),
                  const SizedBox(width: 8),
                  Expanded(child: bar(height: 44, radius: 8)),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================
// 动作按钮（提取自现有详情页 _ActionButton，支持 busy / badge）
// ============================================================

/// 详情页动作按钮（阅读/下载/收藏/喜欢/评论）。
class OnlineComicActionButton extends StatelessWidget {
  const OnlineComicActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
    this.badge,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool busy;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 80,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : (badge != null
                    ? Badge(label: Text(badge!), child: Icon(icon, size: 22))
                    : Icon(icon, size: 22)),
            const SizedBox(height: 6),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// 信息 chip
// ============================================================

/// 详情页顶部图标动作（无底描边圆形图标 + 下方标签）。
///
/// 对齐上游 PicaComic：从头开始 / 分享 / 收藏 / 赞 / 评论。
/// [label] 可传数字（如赞数），[active] 用于收藏/已赞高亮。
class OnlineComicIconAction extends StatelessWidget {
  const OnlineComicIconAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool busy;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 图标统一跟随主题色；active（如已收藏）用更实的描边/底色区分。
    final color = cs.primary;
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(40),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // 圆底始终无色（透明）；图标恒为主题色。
                // active（已收藏/已赞）只把描边加实区分，不填充底色。
                border: Border.all(
                  color: cs.primary.withValues(alpha: active ? 1.0 : 0.5),
                ),
              ),
              alignment: Alignment.center,
              child: busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      icon,
                      size: 22,
                      color: color,
                    ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// 详情页主操作大胶囊按钮（下载 / 阅读）。
///
/// [filled] 为 true 时用 FilledButton（阅读），false 用 tonal（下载）。
class OnlineComicPillButton extends StatelessWidget {
  const OnlineComicPillButton({
    super.key,
    required this.label,
    required this.onTap,
    this.busy = false,
    this.filled = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool busy;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final child = busy
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(label);
    final style = ButtonStyle(
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(vertical: 14),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
    );
    return filled
        ? FilledButton(
            onPressed: busy ? null : onTap,
            style: style,
            child: child,
          )
        : FilledButton.tonal(
            onPressed: busy ? null : onTap,
            style: style,
            child: child,
          );
  }
}

class OnlineComicInfoChip extends StatelessWidget {
  const OnlineComicInfoChip({
    super.key,
    required this.label,
    required this.color,
    required this.textColor,
  });

  final String label;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style:
            Theme.of(context).textTheme.labelSmall?.copyWith(color: textColor),
      ),
    );
  }
}

// ============================================================
// 标签分组区（分类标题 chip + 标签 chip；点击/长按）
// ============================================================

/// 标签分组区。每个分类一行：分类名 chip（不可点）+ 该类标签 chip（可点）。
///
/// - 点击标签：触发 [onTagTap]（子类通常跳搜索）。
/// - 长按标签：直接复制当前显示值；搜索复用 [onTagTap]。
class OnlineComicTagsSection extends StatelessWidget {
  const OnlineComicTagsSection({
    super.key,
    required this.tags,
    required this.onTagTap,
    this.enableTagTranslation = false,
  });

  /// 分组标签：key = 分类名，value = 该类标签列表。
  final Map<String, List<String>> tags;

  /// 标签点击/搜索回调 (tag, category)。
  final void Function(String tag, String category) onTagTap;

  /// 是否启用标签中文翻译（eh/nh 开启，jm/picacg 保持 false）。
  final bool enableTagTranslation;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final entries =
        tags.entries.where((e) => e.value.isNotEmpty).toList(growable: false);
    if (entries.isEmpty) return const SizedBox.shrink();
    // 分类标题柔和配色（按分类索引轮换，对齐上游多彩观感）。
    final palette = <Color>[
      cs.primaryContainer,
      cs.tertiaryContainer,
      cs.secondaryContainer,
      cs.errorContainer,
      cs.primaryContainer,
    ];
    final onPalette = <Color>[
      cs.onPrimaryContainer,
      cs.onTertiaryContainer,
      cs.onSecondaryContainer,
      cs.onErrorContainer,
      cs.onPrimaryContainer,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, e) in entries.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                OnlineComicInfoChip(
                  label: enableTagTranslation
                      ? tagTranslateCategory(e.key)
                      : e.key,
                  color: palette[i % palette.length],
                  textColor: onPalette[i % onPalette.length],
                ),
                for (final v in e.value)
                  InfoValueAction(
                    data: InfoValueData(
                      displayText: enableTagTranslation
                          ? tagTranslateWithNs(v, e.key)
                          : v,
                    ),
                    onSearch: () => onTagTap(v, e.key),
                    child: OnlineComicInfoChip(
                      label: enableTagTranslation
                          ? tagTranslateWithNs(v, e.key)
                          : v,
                      color: cs.primary.withValues(alpha: 0.10),
                      textColor: cs.primary,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// ============================================================
// 章节列表（>20 默认折叠）
// ============================================================

/// 章节列表。超过 [defaultCollapseCount] 条时默认折叠，底部显示「显示全部 (N)」。
class OnlineComicEpisodesList extends StatefulWidget {
  const OnlineComicEpisodesList({
    super.key,
    required this.episodes,
    required this.onEpisodeTap,
    this.onEpisodeLongPress,
    this.collapsible = true,
    this.defaultCollapseCount = 20,
    this.subtitle,
  });

  /// 章节显示名列表。
  final List<String> episodes;

  /// 章节点击：参数为 1-based 章节序号。
  final void Function(int index) onEpisodeTap;

  /// 章节长按（可选，JM 用来强制在线阅读）：参数为 1-based 序号。
  final void Function(int index)? onEpisodeLongPress;

  final bool collapsible;
  final int defaultCollapseCount;

  /// 章节标题下方的说明文案（可选）。
  final String? subtitle;

  @override
  State<OnlineComicEpisodesList> createState() =>
      _OnlineComicEpisodesListState();
}

class _OnlineComicEpisodesListState extends State<OnlineComicEpisodesList> {
  bool _expanded = false;
  bool _reversed = false;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final total = widget.episodes.length;
    final collapsed =
        widget.collapsible && !_expanded && total > widget.defaultCollapseCount;
    final shown = collapsed ? widget.defaultCollapseCount : total;

    // 生成展示用的 1-based 序号序列（支持倒序）。
    final order = List<int>.generate(total, (i) => i + 1);
    if (_reversed) {
      final r = order.reversed.toList();
      r.length = shown;
      order
        ..clear()
        ..addAll(r);
    } else {
      order.length = shown;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('章节 ($total)', style: textTheme.titleSmall),
            ),
            if (total > 1)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: _reversed ? '正序' : '倒序',
                icon: Icon(
                  _reversed ? Icons.arrow_downward : Icons.arrow_upward,
                  size: 20,
                ),
                onPressed: () => setState(() => _reversed = !_reversed),
              ),
          ],
        ),
        if (widget.subtitle != null)
          Text(
            widget.subtitle!,
            style: textTheme.bodySmall
                ?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 3.2,
          ),
          itemCount: order.length,
          itemBuilder: (context, i) {
            final ep = order[i];
            final name = ep - 1 < widget.episodes.length
                ? widget.episodes[ep - 1]
                : '第$ep章';
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => widget.onEpisodeTap(ep),
              onLongPress: widget.onEpisodeLongPress == null
                  ? null
                  : () => widget.onEpisodeLongPress!(ep),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium,
                ),
              ),
            );
          },
        ),
        if (collapsed)
          Center(
            child: TextButton(
              onPressed: () => setState(() => _expanded = true),
              child: Text('显示全部 ($total)'),
            ),
          ),
      ],
    );
  }
}

// ============================================================
// 相关推荐（3 列网格）
// ============================================================

/// 相关推荐网格（3 列）。
class OnlineComicRecommendationGrid extends StatelessWidget {
  const OnlineComicRecommendationGrid({
    super.key,
    required this.comics,
    required this.onComicTap,
    this.headers,
  });

  final List<OnlineComicRecommendation> comics;
  final void Function(int index) onComicTap;
  final Map<String, String>? headers;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    if (comics.isEmpty) return const SizedBox.shrink();
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.48,
      ),
      itemCount: comics.length,
      itemBuilder: (context, index) {
        final c = comics[index];
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => onComicTap(index),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 0.72,
                child: OnlineComicCover(
                  url: c.cover,
                  headers: headers,
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Text(
                  c.title,
                  style: textTheme.labelSmall,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
