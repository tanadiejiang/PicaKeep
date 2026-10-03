import 'package:flutter/material.dart';
import 'package:picakeep/foundation/local_library_illust_view.dart';

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
      required this.onExpand});

  final bool expanded;
  final TextEditingController controller;
  final List<IllustTagSummary> tags;
  final Set<String> selectedTags;
  final int resultCount;
  final ValueChanged<String> onToggleTag;
  final VoidCallback onClear;
  final VoidCallback onExpand;

  @override
  State<IllustSearchPanel> createState() => _IllustSearchPanelState();
}

class _IllustSearchPanelState extends State<IllustSearchPanel> {
  bool _allTags = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final keyword = widget.controller.text.trim();
    final active = keyword.isNotEmpty || widget.selectedTags.isNotEmpty;
    if (!widget.expanded && !active) return const SizedBox.shrink();
    final ordered = [
      ...widget.tags.where((tag) => widget.selectedTags.contains(tag.tag)),
      ...widget.tags.where((tag) => !widget.selectedTags.contains(tag.tag)),
    ];
    final shown = _allTags ? ordered : ordered.take(12).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Material(
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: .6)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.manage_search_rounded,
                  size: 22, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                  child: Text('${widget.resultCount} 个作品',
                      style: theme.textTheme.titleSmall)),
              if (!widget.expanded)
                TextButton(onPressed: widget.onExpand, child: const Text('展开')),
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
              const SizedBox(height: 16),
              Text('标签', style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text('库内标签 · 选择多个时同时匹配',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant)),
              const SizedBox(height: 6),
              if (ordered.isEmpty)
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('暂无标签，可使用标题或作者搜索'))
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: SingleChildScrollView(
                    primary: false,
                    child: Wrap(spacing: 6, runSpacing: 2, children: [
                      for (final tag in shown)
                        FilterChip(
                          key: ValueKey('illust-search-tag-${tag.tag}'),
                          label: Text('${tag.tag} · ${tag.count}'),
                          selected: widget.selectedTags.contains(tag.tag),
                          onSelected: (_) => widget.onToggleTag(tag.tag),
                        ),
                    ]),
                  ),
                ),
              if (ordered.length > 12)
                TextButton.icon(
                  onPressed: () => setState(() => _allTags = !_allTags),
                  icon: Icon(_allTags ? Icons.expand_less : Icons.expand_more),
                  label: Text(_allTags ? '收起标签' : '全部 ${ordered.length} 个标签'),
                ),
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
      ),
    );
  }
}
