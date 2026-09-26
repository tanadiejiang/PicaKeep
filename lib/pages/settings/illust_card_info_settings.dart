// 「设置 → 浏览 → 插画列表 → 卡片底部信息」：勾选字段 + 拖拽排序 + 分隔符 + 预览。
//
// ## 交互形态照 27 号
//
// 用户原话「也是和下载命名一样可以自由选择」，所以这里的编辑器与
// `download_settings.dart` 的 `PixivDirNameTemplateEditor` 是**同一套形态**：
// 可勾选字段 + 长按拖动排序 + 实时预览，编排逻辑（弹窗、取消/确定、点确定才写盘）
// 也一致。差别只在字段表与要写的 settings 下标。
//
// ## 为什么编辑器是 public 且"纯受控、零持久化"
//
// 与 `PixivDirNameTemplateEditor` 同样的两条理由：
// 1. **可测** —— `ReorderableListView` 放进 `AlertDialog` 时的布局约束是最容易
//    到真机才暴露的一类问题，私有类没法被测试构造；
// 2. **与落盘解耦** —— 拖动排序的过程中绝不能写 settings，宿主持有副本、
//    点「确定」才落盘。

part of 'settings_page.dart';

/// 「卡片底部信息」设置行。
///
/// subtitle 直接显示"当前模板 + 一个样例"，用户不必点进弹窗就知道现在配的是什么
/// （与「下载目录名模板」那行同构）。
class _IllustCardInfoTile extends StatefulWidget {
  const _IllustCardInfoTile();

  @override
  State<_IllustCardInfoTile> createState() => _IllustCardInfoTileState();
}

class _IllustCardInfoTileState extends State<_IllustCardInfoTile> {
  Future<void> _showDialog() async {
    final parsed = illustCardInfoSpecFromSetting(
      appdata.settings[illustCardInfoSettingIndex],
    );
    // 弹窗内的当前值：由编辑器经 onChanged 报上来，点「确定」才写盘。
    // 编辑器自己不碰持久化 —— 拖动排序的过程中绝不写 settings。
    var currentFields = parsed.fields;
    var currentSeparator = parsed.separator;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('插画卡片底部信息'.tl),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: IllustCardInfoEditor(
                initialFields: parsed.fields,
                initialSeparator: parsed.separator,
                onChanged: (fields, separator) {
                  currentFields = fields;
                  currentSeparator = separator;
                  // 只为让「确定」按钮的可用态跟着勾选数变化。
                  setDialogState(() {});
                },
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('取消'.tl),
            ),
            FilledButton(
              // 一个字段都没勾时不写盘：空模板会被归一化层退回默认值，
              // 那是用户没预期的结果（"我明明清空了，怎么又冒出标题作者"），
              // 不如直接拦住。
              onPressed: currentFields.isEmpty
                  ? null
                  : () async {
                      appdata.settings[illustCardInfoSettingIndex] =
                          buildIllustCardInfoTemplate(
                        currentFields,
                        currentSeparator,
                      );
                      await appdata.updateSettings();
                      // 卡片显示什么只在图集页的 `build` 里读，而设置页是一个
                      // 非 opaque 路由 —— pop 回去**不会**重建那一页（实测见
                      // `foundation/app.dart` 的 displaySettingsVersion 注释）。
                      // 不通知的话用户会觉得"改了没用"。
                      App.notifyDisplaySettingsChanged();
                      if (ctx.mounted) {
                        Navigator.of(ctx).pop();
                      }
                      if (mounted) {
                        setState(() {});
                      }
                    },
              child: Text('确定'.tl),
            ),
          ],
        ),
      ),
    );
  }

  /// 单行展示用的模板文案：把换行分隔符显示成 `↵`。
  ///
  /// 不显示的话默认值看起来就是 `{title}{author}` —— 用户会以为"两个字段粘在一起
  /// 了"，而实际渲染是两行。用一个可见符号表达"这里有个换行"最省解释。
  String _templateDisplay(List<String> fields, String separator) {
    return buildIllustCardInfoTemplate(fields, separator)
        .replaceAll('\n', ' ↵ ');
  }

  @override
  Widget build(BuildContext context) {
    final parsed = illustCardInfoSpecFromSetting(
      appdata.settings[illustCardInfoSettingIndex],
    );
    final preview = illustCardInfoPreview(parsed.fields, parsed.separator);
    return ListTile(
      leading: const Icon(Icons.art_track_outlined),
      title: Text('卡片底部信息'.tl),
      subtitle: Text(
        '当前：${_templateDisplay(parsed.fields, parsed.separator)}\n'
                '示例：${preview.replaceAll('\n', ' / ')}'
            .tl,
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
      onTap: _showDialog,
    );
  }
}

/// 卡片底部信息编辑器：**勾选字段 + 拖拽排序 + 分隔符选择 + 实时预览**。
///
/// 公开且纯受控、零持久化（理由见本文件头部）。
class IllustCardInfoEditor extends StatefulWidget {
  const IllustCardInfoEditor({
    super.key,
    required this.initialFields,
    required this.initialSeparator,
    required this.onChanged,
  });

  /// 初始**已勾选**的字段，按初始顺序。
  final List<String> initialFields;

  /// 初始分隔符。
  final String initialSeparator;

  /// 勾选 / 顺序 / 分隔符任一变化时回调；`fields` 只含勾选项，按当前顺序。
  final void Function(List<String> fields, String separator) onChanged;

  @override
  State<IllustCardInfoEditor> createState() => _IllustCardInfoEditorState();
}

class _IllustCardInfoEditorState extends State<IllustCardInfoEditor> {
  /// **全部**字段的当前排列（含未勾选的）。
  ///
  /// 未勾选的字段也留在列表里占位：这样"取消勾选"只改勾选态、**不动位置**，
  /// 重新勾选时它还在原处。这条语义与 `PixivDirNameTemplateEditor` 一致。
  late List<String> _order;

  late final Set<String> _selected;
  late String _separator;

  /// 历史值里的分隔符可能不在候选内（例如手写过 `{title}·{author}`）。
  /// 不丢弃它：作为额外选项显示出来，用户不主动改就不会被改掉。
  late final List<String> _separatorOptions;

  @override
  void initState() {
    super.initState();
    _order = <String>[
      ...widget.initialFields,
      ...kIllustCardInfoFieldKeys.where(
        (key) => !widget.initialFields.contains(key),
      ),
    ];
    _selected = <String>{...widget.initialFields};
    _separator = widget.initialSeparator;
    _separatorOptions = <String>[
      ...kIllustCardInfoSeparators,
      if (!kIllustCardInfoSeparators.contains(_separator)) _separator,
    ];
  }

  /// 当前勾选项，按列表顺序 —— 这就是最终会写进模板串的字段序列。
  List<String> get _orderedSelected => <String>[
        for (final key in _order)
          if (_selected.contains(key)) key,
      ];

  void _emit() {
    widget.onChanged(_orderedSelected, _separator);
  }

  /// 分隔符的展示名。
  ///
  /// 空串、空格、换行在 chip 上都看不出来，必须给可读占位 ——
  /// 三个都显示成空白的话，用户根本不知道自己选的是哪个。
  String _separatorLabel(String option) {
    if (option.isEmpty) {
      return '无'.tl;
    }
    if (option == ' ') {
      return '空格'.tl;
    }
    if (option == '\n') {
      return '换行'.tl;
    }
    return option;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _orderedSelected;
    final preview = illustCardInfoPreview(selected, _separator);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '勾选要在卡片底部显示的字段，长按可拖动调整顺序。'.tl,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        ReorderableListView.builder(
          // 与 `PixivDirNameTemplateEditor` 一致：让列表**自适应内容高度**
          // （shrinkWrap + 禁自身滚动），而不是在外面套固定高度 —— 固定高度与
          // 实际行高对不上时列表会变成内部可滚，拖动与滚动手势互相干扰。
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: _order.length,
          // 拖动中的浮起卡片保持与静态一致的圆角（默认实现会套一层带阴影的直角
          // Material 方块，把圆角盖掉）。
          proxyDecorator: (child, index, animation) => AnimatedBuilder(
            animation: animation,
            builder: (context, _) => Transform.scale(
              scale: 1 + animation.value * 0.02,
              child: Material(
                color: Colors.transparent,
                elevation: 0,
                child: child,
              ),
            ),
          ),
          onReorder: (oldIndex, newIndex) {
            setState(() {
              // **整列表替换**，不能原地改：`ReorderableListView` 依赖 children
              // 列表被换成新实例来重建，原地修改会让它只生效一次。
              _order = reorderIllustCardInfoFieldOrder(
                _order,
                oldIndex,
                newIndex,
              );
            });
            _emit();
          },
          itemBuilder: (context, index) {
            final key = _order[index];
            final selected = _selected.contains(key);
            return ReorderableDelayedDragStartListener(
              key: ValueKey<String>('illust-card-info-field-$key'),
              index: index,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _IllustCardInfoFieldRow(
                  label: (kIllustCardInfoFieldLabels[key] ?? key).tl,
                  variable: '{$key}',
                  selected: selected,
                  onToggle: () {
                    setState(() {
                      if (selected) {
                        _selected.remove(key);
                      } else {
                        _selected.add(key);
                      }
                    });
                    _emit();
                  },
                ),
              ),
            );
          },
        ),
        const Divider(),
        Text('分隔符'.tl, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          children: [
            for (final option in _separatorOptions)
              ChoiceChip(
                label: Text(_separatorLabel(option)),
                selected: _separator == option,
                onSelected: (_) {
                  setState(() => _separator = option);
                  _emit();
                },
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text('预览'.tl, style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        // 预览用与卡片**同一条**取值/拼接路径（`illustCardInfoPreview` →
        // `buildIllustCardInfoText`），所以"预览里看到什么，卡片上就显示什么"。
        SelectableText(
          selected.isEmpty ? '（未勾选任何字段）'.tl : preview,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '只影响图集页「插画」视图的卡片底部；改动后返回该页即刻生效。'
                  '「页数」「尺寸」取不到时会自动不显示（隐藏文件的作品、'
                  '打包成压缩包的作品数不出页数）。'
              .tl,
          style: theme.textTheme.bodySmall,
        ),
        if (selected.isEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '至少要勾选一个字段。'.tl,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

/// 单个字段行：**圆角卡片 + 勾选框 + 字段名/变量名 + 拖拽手柄**。
///
/// 与 `_PixivDirNameFieldRow` 同款（12 圆角、勾选换底色与边框、整行长按可拖），
/// 两处设置页的观感因此一致。
class _IllustCardInfoFieldRow extends StatelessWidget {
  const _IllustCardInfoFieldRow({
    required this.label,
    required this.variable,
    required this.selected,
    required this.onToggle,
  });

  final String label;
  final String variable;
  final bool selected;
  final VoidCallback onToggle;

  static const double _radius = 12;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final background =
        selected ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final foreground =
        selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(_radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Checkbox(
                value: selected,
                onChanged: (_) => onToggle(),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      variable,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: foreground.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.drag_handle, size: 20, color: foreground),
            ],
          ),
        ),
      ),
    );
  }
}
