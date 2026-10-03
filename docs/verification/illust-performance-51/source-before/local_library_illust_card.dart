/// 插画视图的**瀑布流卡片**：近无边框大图 + 信息在底部。
///
/// ## 为什么单独成文件
///
/// `lib/pages/local_library_page.dart` 是 2583 行单文件，新增 UI 一律另起文件
/// （24 号计划「风险或注意事项」第一条）。
///
/// ## 两条硬约束
///
/// 1. **图片必须由调用方传入 provider**，本控件**绝不**用 `FileImage` /
///    `Image.file` 直读路径。目标设备有 root / Shizuku，那种模式下
///    `File.existsSync()` 会因挂载点可见而误报 true，而 `FileImage` 内部的
///    `readAsBytes()` 受 scoped storage 限制静默失败 → **整片破图**
///    （原因注释见 `foundation/local_library.dart:1213-1220`）。调用方传进来的
///    provider 来自 `LocalLibraryManager.imageProviderForLocalPath`，它在特权
///    模式下走 `StreamImageProvider`。
/// 2. **必须降采样**。瀑布流一屏可能同时解码 10~20 张大图，而
///    `BaseImageProvider` 的原始字节缓存上限只有 50 MB FIFO
///    （`foundation/image_loader/base_image_provider.dart:99`），不降采样会迅速
///    把缓存冲掉并抬高老年代 GC 压力。做法沿用既有先例
///    `ComicTile._buildImage` 的 `optimizeCoverDecode` 分支
///    （`components/comic_tile.dart:370-394`）：按**实际显示宽度 × 设备像素比**算
///    `cacheWidth`，用 `ResizeImage.resizeIfNeeded` 包一层。
///
///    ⚠️ 32 号起"实际显示宽度"不再等于列宽：改成 `BoxFit.contain` 后，格子比例
///    与图不符时显示宽度会**小于**列宽（按高贴合），此时若仍按列宽解码就是白解
///    一大截。见 [IllustCard._decodeWidthFor] 里对 `displayWidth` 的推导。
library;

import 'package:flutter/material.dart';

import 'package:picakeep/foundation/illust_card_info_config.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';

/// 卡片四周留白。
///
/// 用户要的是"接近无边框"。这里取 3 dp：既能看出卡片之间的分界，
/// 又明显比既有定高网格的 `Padding(all: 2)` + 卡片自身大圆角更"贴边"。
/// **同时参与宽度算术** —— `IllustCard` 用 `LayoutBuilder` 量到的宽度
/// 已经扣掉了这个留白（外层 `Padding`），所以 `cacheWidth` 不会算宽。
const double illustCardGap = 3;

/// 图片圆角。
const double illustCardImageRadius = 8;

/// 解码宽度的冗余系数。
///
/// 与 `comic_tile.dart` 的 `qualityScale = 1.35` 同口径：按精确列宽解码在
/// 高分屏上会略糊，留 35% 余量后肉眼与不降采样无差别。
const double _illustDecodeQualityScale = 1.35;

/// 单个插画条目卡片（瀑布流的一格）。
///
/// 高度由 [IllustLibraryEntry.aspectRatio] 决定；调用方不需要给它固定高度，
/// `SliverMasonryGrid` 会按子项自然高度摆放。
class IllustCard extends StatelessWidget {
  const IllustCard({
    super.key,
    required this.entry,
    required this.imageProvider,
    required this.onTap,
    required this.onLongPress,
    this.onInfoTap,
    this.infoSpans,
    this.locationLabel,
    this.selected = false,
    this.selecting = false,
  });

  final IllustLibraryEntry entry;

  /// 由调用方解析好的 provider（特权模式安全的那个）。为 null 表示无封面。
  final ImageProvider<Object>? imageProvider;

  /// **图片区**点击（36 号起 = 直接进阅读器）。
  final VoidCallback onTap;

  /// **信息区**点击（36 号起 = 打开本地详情页）。
  ///
  /// 为 null 时回落到 [onTap] —— 既有调用（含只关心"点一下有反应"的测试）
  /// 不会因为多了这一区而失去点击。
  final VoidCallback? onInfoTap;

  final VoidCallback onLongPress;

  /// 卡片底部信息（按设置里勾选的字段与顺序渲染）。
  ///
  /// 由调用方用 [illustrateCardInfoSpansFor] 算好传进来，而不是在卡片里读
  /// `appdata`：卡片是纯展示控件，读全局设置会让它无法被独立 widget 测试。
  ///
  /// **为 null 时用默认配置**（标题 + 作者各一行）—— 与 32 号改动前的观感一致。
  /// 这个兜底是为了让"直接构造本控件"（测试、以及将来别处复用）不会突然变成
  /// 一张没有说明文字的图；生产路径由页面显式传入设置里的配置。
  final List<IllustCardInfoSpan>? infoSpans;

  /// 多选态下是否已选中。
  final String? locationLabel;

  final bool selected;
  final bool selecting;

  /// 本控件实际会渲染的信息片段（显式传入，或走默认配置）。
  List<IllustCardInfoSpan> get _effectiveInfoSpans =>
      infoSpans ??
      illustrateCardInfoSpansFor(
        entry: entry,
        fields: kDefaultIllustCardInfoFields,
        separator: kDefaultIllustCardInfoSeparator,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spans = _effectiveInfoSpans;
    return Padding(
      padding: const EdgeInsets.all(illustCardGap),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 图片区与信息区**各自可点**（36 号）：同一张卡片上，"看图"与"管理"
          // 是两种意图，给它们各自的命中区域比让整卡做一件事更贴近使用习惯。
          _tappable(
            onTap: onTap,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(illustCardImageRadius),
              child: AspectRatio(
                aspectRatio: entry.aspectRatio,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildImage(context),
                    if (selecting && selected)
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary
                              .withValues(alpha: 0.22),
                          border: Border.all(color: theme.colorScheme.primary, width: 1.6),
                          borderRadius: BorderRadius.circular(illustCardImageRadius),
                        ),
                        child: Center(
                          child: Icon(
                            Icons.check_circle,
                            color: theme.colorScheme.primary,
                            size: 28,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (spans.isNotEmpty) ...[
            const SizedBox(height: 4),
            _tappable(
              onTap: onInfoTap ?? onTap,
              child: Padding(
                // 上边距取 1 而不是 2：信息块整体要"轻"，把纵向空间让给图片。
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _buildInfoText(theme, spans),
              ),
            ),
          ],
          if (locationLabel != null) Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(locationLabel!, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }

  /// 给一块区域挂"点击 + 长按"。
  ///
  /// 用 `GestureDetector` 而不是 `InkWell`：这是一面**近无边框**的图片墙，
  /// 水波纹要么被 `ClipRRect` 裁掉、要么在图上糊一层半透明高亮，两种都难看；
  /// 这里需要的只是"命中区域"。`HitTestBehavior.opaque` 保证信息区那几行文字
  /// 之间的空隙也能点中（否则点在行距上会穿透到列表）。
  ///
  /// ⚠️ **长按两个区都要响应**：多选是"对这张卡片"的操作，与点哪个区无关。
  /// 32 号首版这里只声明了 `onTap` 却忘了挂上去（卡片整张点不动），
  /// 36 号补手势时一并修掉 —— 新增手势区时记得别只挂一半。
  Widget _tappable({required VoidCallback onTap, required Widget child}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: child,
    );
  }

  /// 底部信息：**一个** `Text.rich`，每个字段一段（标题加粗、其余次要）。
  ///
  /// 为什么不是"每个字段一个 `Text`"：字段顺序与分隔符都由用户配置，
  /// 分隔符可能是换行（每项一行）也可能是 `-`（同一行里连起来）。
  /// 用一个富文本承载，两种形态都是同一份拼接结果，不会出现"改了分隔符
  /// 但排版还是按字段各占一行"这种不一致。
  ///
  /// `maxLines` 取"字段值片段数"：每个字段最多占一行，用户配了 4 个长字段也不会
  /// 把卡片撑得比图片还高；超出部分省略。默认两个字段 = 换行分隔，
  /// 效果与改动前的"标题一行 + 作者一行、各自 `maxLines: 1`"完全一致。
  Widget _buildInfoText(ThemeData theme, List<IllustCardInfoSpan> spans) {
    final emphasisStyle = theme.textTheme.bodySmall?.copyWith(
      fontWeight: FontWeight.w600,
      height: 1.2,
    );
    final secondaryStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.2,
    );
    // 分隔符片段不计入行数上限（换行分隔符本身"就是"那个换行，不该再占一行额度；
    // `' - '` 这种可见分隔符同理）。所以要按 isSeparator 判，不能按文本是否为空判。
    final valueCount =
        spans.where((span) => !span.isSeparator).length;
    return Text.rich(
      TextSpan(
        children: [
          for (final span in spans)
            TextSpan(
              text: span.text,
              style: span.emphasized ? emphasisStyle : secondaryStyle,
            ),
        ],
      ),
      maxLines: valueCount < 1 ? 1 : valueCount,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildImage(BuildContext context) {
    final provider = imageProvider;
    if (provider == null) {
      return _brokenImagePlaceholder(context);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // 这里的约束来自 `AspectRatio` 内部的 `Stack(fit: expand)`，是**紧**的：
        // maxWidth = 列宽（已扣掉本控件的 Padding），maxHeight = 列宽 / aspectRatio。
        final devicePixelRatio =
            MediaQuery.of(context).devicePixelRatio.clamp(1.0, 3.0).toDouble();
        final cacheWidth = _decodeWidthFor(constraints, devicePixelRatio);
        final displayProvider = ResizeImage.resizeIfNeeded(
          cacheWidth,
          null,
          provider,
        );
        return Image(
          image: displayProvider,
          // **不裁切**（用户原话「这个图的比例没有完全显示」）。
          //
          // 改动前是 `BoxFit.cover`：格子比例与图不符时**必然**裁掉多出来的部分。
          // 拿不到真实比例时格子会落到占位 3:4，`cover` 会把一张 0.53 的竖图
          // 上下各裁掉约 15% —— 用户看到的就是"比例没显示全"。
          //
          // `contain` 保证整张图永远完整可见。真实比例生效时格子与图同比例，
          // `contain` 与 `cover` 视觉等价（只剩浮点误差，而 contain 不会因为
          // 1~2px 的误差裁边）；比例未知时宁可留出留白，也不裁内容。
          fit: BoxFit.contain,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) => _brokenImagePlaceholder(context),
        );
      },
    );
  }

  /// 该按多少物理像素解码。
  ///
  /// `contain` 下的真实显示宽度 = 原图按"较小的那个缩放比"缩放后的宽度：
  /// - 图比格子更"瘦"（`图比例 < 格子比例`）→ 按高贴合，显示宽度 = 格高 × 图比例；
  /// - 否则按宽贴合，显示宽度 = 格宽。
  ///
  /// 格子的高已经由 [IllustLibraryEntry.aspectRatio] 决定，所以这个式子只用
  /// `entry.aspectRatio` 与格子约束，**不需要等图片解码完**就知道该解多大 ——
  /// 这正是"降采样不能丢"能做到的前提。
  ///
  /// 真实比例生效时 `图比例 == 格子比例`，两个分支等价、结果就是列宽 × DPR，
  /// 与改动前逐像素一致（无回归）；只有比例未知（占位 3:4）时才会比列宽小，
  /// 那正是需要省解码量的场景。
  int? _decodeWidthFor(BoxConstraints constraints, double devicePixelRatio) {
    final cellWidth = constraints.maxWidth;
    final cellHeight = constraints.maxHeight;
    if (!cellWidth.isFinite || cellWidth <= 0) {
      return null;
    }
    var displayWidth = cellWidth;
    if (cellHeight.isFinite && cellHeight > 0) {
      final imageRatio = entry.aspectRatio;
      if (imageRatio.isFinite && imageRatio > 0) {
        final cellRatio = cellWidth / cellHeight;
        if (imageRatio < cellRatio) {
          displayWidth = cellHeight * imageRatio;
        }
      }
    }
    if (!displayWidth.isFinite || displayWidth <= 0) {
      displayWidth = cellWidth;
    }
    return (displayWidth * devicePixelRatio * _illustDecodeQualityScale)
        .round();
  }

  Widget _brokenImagePlaceholder(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colorScheme.secondaryContainer,
      child: Icon(
        Icons.image_not_supported_outlined,
        size: 22,
        color: colorScheme.onSecondaryContainer,
      ),
    );
  }
}
