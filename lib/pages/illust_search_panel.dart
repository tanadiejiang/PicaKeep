import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';
import 'package:picakeep/pages/illust_search_tag_list.dart';
import 'package:picakeep/tools/translations.dart';

/// 搜索面板展开 / 收起的高度过渡时长（19 号）。
///
/// 与项目既有折叠动效同一量级（`explore_keep_alive_switcher.dart` 的 220ms）。
/// 公开成常量是为了让测试直接引用，而不是各自猜一个毫秒数。
const Duration illustSearchPanelAnimationDuration = Duration(milliseconds: 220);

/// Search controls stay out of the artwork wall until requested. Active filters
/// remain visible when collapsed, so a shortened list never has a hidden cause.
class IllustSearchPanel extends StatefulWidget {
  const IllustSearchPanel(
      {super.key,
      required this.expanded,
      required this.controller,
      required this.tags,
      required this.selectedTags,
      required this.resultCount,
      required this.onToggleTag,
      required this.onClear,
      required this.onExpand,
      required this.onCollapse,
      required this.matchTags,
      required this.onMatchTagsChanged});

  final bool expanded;
  final TextEditingController controller;
  final List<IllustTagSummary> tags;
  final Set<String> selectedTags;
  final int resultCount;
  final ValueChanged<String> onToggleTag;
  final VoidCallback onClear;

  /// 折叠态摘要行与顶部「展开」按钮触发。
  final VoidCallback onExpand;

  /// 面板右下角那个**悬浮**的「收起搜索」触发：与工具栏那个 × **完全等价**
  /// （父页面里就是 `_searchMode = false`）。
  final VoidCallback onCollapse;

  /// 关键词是否同时匹配作品标签（`settings[illustSearchMatchTagsSettingIndex]`）。
  final bool matchTags;
  final ValueChanged<bool> onMatchTagsChanged;

  @override
  State<IllustSearchPanel> createState() => _IllustSearchPanelState();
}

class _IllustSearchPanelState extends State<IllustSearchPanel> {
  bool _allTags = false;
  List<IllustTagSummary> _cachedTags = const [];
  Set<String> _cachedSelectedTags = const {};
  List<IllustTagSummary> _orderedTags = const [];
  Widget? _tagContent;

  void _updateTagCache() {
    final tagsChanged = _cachedTags.length != widget.tags.length ||
        !Iterable<int>.generate(widget.tags.length).every((i) =>
            _cachedTags[i].tag == widget.tags[i].tag &&
            _cachedTags[i].count == widget.tags[i].count);
    if (!tagsChanged && setEquals(_cachedSelectedTags, widget.selectedTags)) {
      return;
    }
    // The page mutates its selected Set in place, so keep value snapshots.
    _cachedTags = List.of(widget.tags);
    _cachedSelectedTags = Set.of(widget.selectedTags);
    _orderedTags = [
      ..._cachedTags.where((tag) => _cachedSelectedTags.contains(tag.tag)),
      ..._cachedTags.where((tag) => !_cachedSelectedTags.contains(tag.tag)),
    ];
    _tagContent = null;
  }

  Widget _buildTagContent() => _tagContent ??= IllustSearchTagList(
        key: const Key('illust-search-tag-content'),
        tags: _orderedTags,
        visibleTagLimit: _allTags ? null : 12,
        selectedTags: _cachedSelectedTags,
        // Read the latest callback even when the subtree is reused.
        onToggleTag: (tag) => widget.onToggleTag(tag),
      );

  @override
  Widget build(BuildContext context) {
    // 无障碍：系统关闭动画时不做过渡（项目既有先例见
    // `explore_keep_alive_switcher.dart` 的 `MediaQuery.disableAnimationsOf`）。
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final keyword = widget.controller.text.trim();
    final active = keyword.isNotEmpty || widget.selectedTags.isNotEmpty;
    return AnimatedSize(
      duration:
          reduceMotion ? Duration.zero : illustSearchPanelAnimationDuration,
      curve: Curves.easeOutCubic,
      // 从顶部展开、向上收起：折叠态那一行摘要不会被"居中"顶来顶去。
      alignment: Alignment.topCenter,
      // ⚠️ 收起态给**非空**的零高 child，绝不要传 `null`：
      // `RenderAnimatedSize` 在 `child == null` 时会把 tween 首尾都设成
      // `constraints.smallest`（`rendering/animated_size.dart` 的 child==null
      // 分支），也就是收起与展开**两个方向都瞬跳**，等于没有动画。
      // 传零高 `SizedBox` 才算"尺寸变化"，才会走 tween + forward(from: 0)。
      child: (!widget.expanded && !active)
          ? const SizedBox(width: double.infinity, height: 0)
          : _buildPanel(context, keyword, active),
    );
  }

  Widget _buildPanel(BuildContext context, String keyword, bool active) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    _updateTagCache();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Material(
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: .6)),
        ),
        clipBehavior: Clip.antiAlias,
        // 19 号：底部两个动作（「全部 N 个标签」/「收起搜索」）从"占一整行"
        // 改成**悬浮在面板底部**（用户要求：把按钮做成悬浮按钮，让那一块也能
        // 显示内容）。Stack 的尺寸由非 positioned 的 Padding 决定，所以悬浮
        // 按钮**不占内容高度**；腾出来的高度还给了标签区（上限 240 → 288）。
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.manage_search_rounded,
                          size: 22, color: colors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text('${widget.resultCount} 个作品',
                              style: theme.textTheme.titleSmall)),
                      if (!widget.expanded)
                        TextButton(
                            onPressed: widget.onExpand,
                            child: const Text('展开')),
                      TextButton(
                          onPressed: active ? widget.onClear : null,
                          child: const Text('清除')),
                    ]),
                    if (widget.expanded) ...[
                      TextField(
                        key: const Key('illust-search-input'),
                        controller: widget.controller,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => FocusScope.of(context).unfocus(),
                        decoration: InputDecoration(
                          hintText: '搜索标题或作者',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: keyword.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: '清除关键词',
                                  onPressed: widget.controller.clear,
                                  icon: const Icon(Icons.close_rounded)),
                          filled: true,
                          fillColor: colors.surface,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide.none),
                        ),
                      ),
                      // 「搜标签」开关与「标签」标题同行（用户指定的位置）：
                      // 省掉一整行，语义上也紧挨着它作用的标签区。
                      // 这是**搜索范围偏好**、不是筛选条件：所以「清除」只清
                      // 关键词与已选标签，不动它；折叠摘要行也不显示它。
                      const SizedBox(height: 4),
                      Row(children: [
                        Expanded(
                          child: Text('标签',
                              style: theme.textTheme.titleSmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                        Text('搜标签'.tl, style: theme.textTheme.bodySmall),
                        const SizedBox(width: 4),
                        Switch.adaptive(
                          key: const Key('illust-search-match-tags'),
                          value: widget.matchTags,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          onChanged: widget.onMatchTagsChanged,
                        ),
                      ]),
                      const SizedBox(height: 2),
                      Text('库内标签 · 选择多个时同时匹配',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant)),
                      const SizedBox(height: 6),
                      if (_orderedTags.isEmpty)
                        const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text('暂无标签，可使用标题或作者搜索'))
                      else
                        _buildTagContent(),
                    ] else
                      InkWell(
                        onTap: widget.onExpand,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                              [
                                if (keyword.isNotEmpty) '“$keyword”',
                                ...widget.selectedTags,
                              ].join(' · '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(color: colors.primary)),
                        ),
                      ),
                  ]),
            ),
            // 左下：标签太多时才有意义（其余时候不存在，不会挡住 chips）。
            if (widget.expanded && _orderedTags.length > 12)
              Positioned(
                left: 4,
                bottom: 4,
                child: _floatingAction(
                  onPressed: () => setState(() {
                    _allTags = !_allTags;
                    _tagContent = null;
                  }),
                  icon: Icon(_allTags ? Icons.expand_less : Icons.expand_more,
                      size: 20),
                  label:
                      Text(_allTags ? '收起标签' : '全部 ${_orderedTags.length} 个标签'),
                ),
              ),
            // 右下：「收起搜索」，与工具栏那个 × 等价。
            if (widget.expanded)
              Positioned(
                right: 4,
                bottom: 4,
                child: _floatingAction(
                  key: const Key('illust-search-collapse'),
                  onPressed: widget.onCollapse,
                  icon: const Icon(Icons.unfold_less_rounded, size: 20),
                  label: Text('收起搜索'.tl),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 面板底部那两个**悬浮**动作按钮（19 号）。
  ///
  /// 放在 `Stack` 的 `Positioned` 里、不参与 `Column` 布局，因此面板底部那块
  /// 空间是由标签 chips 使用的，按钮只是浮在它们之上（所以要有底色 + 阴影，
  /// 否则压在 chip 上读不清）。
  ///
  /// 为什么不用 `Row`/`Wrap` 排一行：那一行会占掉约 48dp 的内容高度，而用户
  /// 明确要求"把这块也让给内容"；另外窄屏 + 1.6 字号下两个按钮并排约 376px、
  /// 面板可用仅约 272px，`Row` 版本必 overflow（悬浮化同时解决了这两件事）。
  Widget _floatingAction({
    Key? key,
    required VoidCallback onPressed,
    required Widget icon,
    required Widget label,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: key,
      color: colors.surfaceContainerHighest,
      elevation: 1,
      borderRadius: BorderRadius.circular(999),
      clipBehavior: Clip.antiAlias,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: icon,
        label: label,
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          minimumSize: const Size(0, 36),
        ),
      ),
    );
  }
}
