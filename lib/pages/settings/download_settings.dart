part of 'settings_page.dart';

Widget _buildDownloadSettings(double width) {
  return buildTwoColumnLayout(width, [
    const SelectSetting(
      leading: Icon(Icons.download_outlined),
      title: '并发下载数',
      settingsIndex: 79,
      values: ['1', '2', '4', '6', '8', '16'],
      titles: ['1', '2', '4', '6（默认）', '8', '16'],
      controlWidth: 120,
      tailing: Icon(Icons.arrow_drop_down),
    ),
    const Divider(),
    const _FixDirectoryNamesTile(),
    const Divider(),
    SettingsTitle('禁漫 (jm) 网络'.tl),
    const _JmApiDomainsTile(),
    const Divider(),
    SettingsTitle('Pixiv'.tl),
    const _PixivDirNameTemplateTile(),
    const Divider(),
    const _PixivDownloadDirTile(),
    const Divider(),
    // Pixiv 产物形态（`settings[154]`）。默认关：这是**兼容性变更** ——
    // 一个作品从"一个目录"变成一个文件，老内容不会被转换，开关关着就与改动前
    // 逐字节一致，最安全。
    SwitchSetting(
      leading: const Icon(Icons.folder_zip_outlined),
      title: '多图打包为压缩包'.tl,
      subTitle: '多图作品打成一个 zip（仅存储不压缩），单图作品直接放一个图片文件；'
              '关闭时一个作品一个文件夹'
          .tl,
      settingsIndex: pixivMultiPageZipSettingIndex,
    ),
  ]);
}

/// jm API 域名设置：自动更新（拉 bytepluses）+ 手填兜底 + API 分流选择
class _JmApiDomainsTile extends StatefulWidget {
  const _JmApiDomainsTile();

  @override
  State<_JmApiDomainsTile> createState() => _JmApiDomainsTileState();
}

class _JmApiDomainsTileState extends State<_JmApiDomainsTile> {
  bool _busy = false;

  List<String> get _domains => appdata.settings[85]
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  Future<void> _updateDomains() async {
    setState(() => _busy = true);
    try {
      final ok = await JmNetwork().getApiDomains();
      if (!mounted) return;
      setState(() {});
      final domains = appdata.settings[85];
      if (ok) {
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('更新成功'),
            content: Text('已获取域名：\n$domains'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('确定'),
              ),
            ],
          ),
        );
      } else {
        _showSettingMessage(context, '域名获取失败，仍使用当前域名');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _editDomains() {
    final ctrl = TextEditingController(text: appdata.settings[85]);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手填 jm API 域名'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            hintText: 'domain1.com,domain2.com',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final val = ctrl.text.trim();
              if (val.isNotEmpty) {
                appdata.settings[85] = val;
                await appdata.updateSettings();
                await JmNetwork().selectDomain();
              }
              if (ctx.mounted) Navigator.of(ctx).pop();
              if (mounted) {
                setState(() {});
                _showSettingMessage(context, '域名已保存');
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final domains = _domains;
    final idx = (int.tryParse(appdata.settings[17]) ?? 0)
        .clamp(0, domains.isEmpty ? 0 : domains.length - 1);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('jm API 域名'),
          subtitle: Text(
            appdata.settings[85],
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          trailing: _busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Wrap(
                  spacing: 0,
                  children: [
                    TextButton(
                      onPressed: _updateDomains,
                      child: const Text('自动更新'),
                    ),
                    TextButton(
                      onPressed: _editDomains,
                      child: const Text('手填'),
                    ),
                  ],
                ),
        ),
        if (domains.length > 1)
          buildResponsiveSettingTile(
            leading: const Icon(Icons.alt_route),
            title: const Text('API 分流'),
            subtitle: const Text('手动选择使用第几个 API 域名'),
            trailingWidth: 150,
            trailing: Select(
              width: 150,
              initialValue: idx.toString(),
              values: [for (var i = 0; i < domains.length; i++) i.toString()],
              titles: [for (var i = 0; i < domains.length; i++) '分流${i + 1}'],
              onChanged: (value) {
                appdata.settings[17] = value;
                appdata.updateSettings();
              },
            ),
          ),
      ],
    );
  }
}

class _FixDirectoryNamesTile extends StatefulWidget {
  const _FixDirectoryNamesTile();

  @override
  State<_FixDirectoryNamesTile> createState() => _FixDirectoryNamesTileState();
}

class _FixDirectoryNamesTileState extends State<_FixDirectoryNamesTile> {
  bool _running = false;

  Future<void> _run() async {
    setState(() => _running = true);
    try {
      final result =
          await OnlineDownloadManager.instance.fixDirectoryNames();
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('修正完成'),
          content: Text(
            '已修正：${result.fixed} 个\n'
            '已跳过：${result.skipped} 个\n'
            '失败：${result.failed} 个',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _running
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.drive_file_rename_outline),
      title: const Text('修正已下载文件夹名'),
      subtitle: const Text('将旧的纯 ID 文件夹改为"标题_ID"格式'),
      trailing: _running ? null : const Icon(Icons.arrow_right),
      onTap: _running ? null : _run,
    );
  }
}

/// Pixiv 下载的**目录名模板**（`settings[153]`）。
///
/// 弹窗内提供实时预览：模板是纯字符串，用户很难凭空想象"`{title}-{author}` 到底
/// 长什么样"，给他一句样例远比解释语法有效。
class _PixivDirNameTemplateTile extends StatefulWidget {
  const _PixivDirNameTemplateTile();

  @override
  State<_PixivDirNameTemplateTile> createState() =>
      _PixivDirNameTemplateTileState();
}

class _PixivDirNameTemplateTileState
    extends State<_PixivDirNameTemplateTile> {
  Future<void> _showDialog() async {
    final parsed = parsePixivDirNameTemplate(
      appdata.settings[pixivDirNameTemplateSettingIndex],
    );
    // 弹窗内的当前值：由编辑器经 onChanged 报上来，点「确定」才写盘。
    // 编辑器自己不碰持久化 —— 拖动排序的过程中绝不写 settings。
    var currentFields = parsed.fields;
    var currentSeparator = parsed.separator;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Pixiv 下载目录名模板'.tl),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: PixivDirNameTemplateEditor(
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
              // 一个字段都没勾时不写盘：空模板会被渲染层退回 `{title}`，
              // 那是用户没预期的结果，不如直接拦住。
              onPressed: currentFields.isEmpty
                  ? null
                  : () async {
                      appdata.settings[pixivDirNameTemplateSettingIndex] =
                          buildPixivDirNameTemplate(
                        currentFields,
                        currentSeparator,
                      );
                      await appdata.updateSettings();
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

  @override
  Widget build(BuildContext context) {
    final parsed = parsePixivDirNameTemplate(
      appdata.settings[pixivDirNameTemplateSettingIndex],
    );
    return ListTile(
      leading: const Icon(Icons.drive_file_rename_outline),
      title: Text('下载目录名模板'.tl),
      subtitle: Text(
        '当前：${buildPixivDirNameTemplate(parsed.fields, parsed.separator)}\n'
                '示例：${pixivDirNameTemplatePreview(parsed.fields, parsed.separator)}'
            .tl,
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
      onTap: _showDialog,
    );
  }
}

/// Pixiv **专属下载目录**（`settings[152]`）。
///
/// 留空 = 与其它来源共用「本应用下载目录」（`settings[22]`）。
///
/// ⚠️ 非空时它是一个**独立下载根**：读取侧会把它当成"本应用的第二个下载源"
/// 参与列表扫描（见 `local_library_scan.dart` 的 Pixiv 源）。改这里**不会**
/// 搬动已下载内容，所以弹窗里不出现下载转移选项。
class _PixivDownloadDirTile extends StatefulWidget {
  const _PixivDownloadDirTile();

  @override
  State<_PixivDownloadDirTile> createState() => _PixivDownloadDirTileState();
}

class _PixivDownloadDirTileState extends State<_PixivDownloadDirTile> {
  Future<String?> _pickFolder() async {
    try {
      return await FilePicker.platform.getDirectoryPath();
    } catch (_) {
      return null;
    }
  }

  void _openCurrentDirectory(String path) {
    if (path.isEmpty) {
      return;
    }
    if (Platform.isWindows) {
      Process.run('explorer', [path]);
    } else if (Platform.isMacOS) {
      Process.run('open', [path]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [path]);
    }
  }

  Widget _buildPathDisplay(BuildContext context, String display) {
    return Container(
      width: double.infinity,
      height: 40,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Text(
        display,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
    );
  }

  Future<void> _showBrowseDialog() async {
    final controller = TextEditingController(
      text: appdata.settings[pixivDownloadDirSettingIndex],
    );
    await showDialog<void>(
      context: context,
      builder: (ctx) => _DirectoryPathDialog(
        title: '设置 Pixiv 专属下载目录'.tl,
        hintText: '留空 = 跟随「本应用下载目录」'.tl,
        helperText:
            '提示：点按“浏览”调用系统目录选择；长按“浏览”打开内置文件夹浏览。'
                    '设置后该目录会被当作本应用的另一个下载根，参与已下载列表扫描。'
                .tl,
        controller: controller,
        initialPath: appdata.settings[pixivDownloadDirSettingIndex],
        // 只换扫描/落盘位置，不搬已下载内容（目录名已进 db，搬动会牵连记录），
        // 因此不出现下载转移选项。
        hasExistingDownloads: false,
        onBrowse: () async {
          final picked = await _pickFolder();
          if (picked != null) {
            controller.text = picked;
          }
        },
        onLongPressBrowse: () async {
          Navigator.of(ctx).pop();
          final browsed = await openInternalDirectoryBrowser(
            context,
            title: '选择 Pixiv 下载目录'.tl,
            initialPath: controller.text,
          );
          if (!mounted || browsed == null) {
            return;
          }
          controller.text = browsed;
          appdata.settings[pixivDownloadDirSettingIndex] = browsed;
          await appdata.updateSettings();
          if (!mounted) {
            return;
          }
          setState(() {});
          await _runRescanLocalComics(context);
        },
        onOpenCurrentDirectory: () {
          _openCurrentDirectory(controller.text.trim());
        },
        onCancel: () => Navigator.of(ctx).pop(),
        onConfirm: (migrateDownloads) async {
          appdata.settings[pixivDownloadDirSettingIndex] =
              controller.text.trim();
          await appdata.updateSettings();
          if (!ctx.mounted || !mounted) {
            return;
          }
          Navigator.of(ctx).pop();
          setState(() {});
          await _runRescanLocalComics(context);
        },
      ),
    );
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final path = appdata.settings[pixivDownloadDirSettingIndex].trim();
    // trailing 只放短占位（与「原应用下载目录」tile 的 `未设置` 一致）：
    // 写长文案会把 trailing 撑满，标题被挤成两行（真机截图已暴露）。
    // "留空 = 跟随本应用下载目录"的语义交给 subtitle 承载。
    final display = path.isEmpty ? '未设置'.tl : path;
    return buildResponsiveSettingTile(
      leading: const Icon(Icons.folder_special_outlined),
      title: Text('Pixiv 专属下载目录'.tl),
      subtitle: Text('留空则与其它来源共用「本应用下载目录」'.tl),
      trailingWidth: 220,
      onTap: _showBrowseDialog,
      trailing: _buildPathDisplay(context, display),
    );
  }
}

/// 目录名模板编辑器：**勾选字段 + 拖拽排序 + 分隔符选择 + 实时预览**。
///
/// **公开且纯受控、零持久化**：初值从参数进，当前值经 [onChanged] 报出。
/// 这样拆有两个理由：
/// 1. **可测** —— 能直接 widget 测试构造它，验证 `ReorderableListView` 放进弹窗时的
///    布局约束（这是最容易到真机才暴露的一类问题）。私有类无法被测试构造。
/// 2. **与落盘解耦** —— 编排逻辑与"写 settings"分开，宿主持有副本、点保存才落盘，
///    与参考实现的结构一致（它的 `TestStepEditor` 同样是纯受控公开组件）。
class PixivDirNameTemplateEditor extends StatefulWidget {
  const PixivDirNameTemplateEditor({
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
  State<PixivDirNameTemplateEditor> createState() =>
      _PixivDirNameTemplateEditorState();
}

class _PixivDirNameTemplateEditorState
    extends State<PixivDirNameTemplateEditor> {

  /// **全部**字段的当前排列（含未勾选的）。
  ///
  /// 未勾选的字段也留在列表里占位：这样"取消勾选"只改勾选态、**不动位置**，
  /// 重新勾选时它还在原处。这条语义照搬自参考实现 —— 比"只把勾选项拿来排序"
  /// 少一个"取消后位置丢失"的交互难题。
  late List<String> _order;

  late final Set<String> _selected;
  late String _separator;

  /// 历史值里的分隔符可能不在候选内（例如手写过 `{title} ({author})`）。
  /// 不丢弃它：作为额外选项显示出来，用户不主动改就不会被改掉。
  late final List<String> _separatorOptions;

  @override
  void initState() {
    super.initState();
    _order = <String>[
      ...widget.initialFields,
      ...kPixivDirNameFieldKeys.where(
        (key) => !widget.initialFields.contains(key),
      ),
    ];
    _selected = <String>{...widget.initialFields};
    _separator = widget.initialSeparator;
    _separatorOptions = <String>[
      ...kPixivDirNameSeparators,
      if (!kPixivDirNameSeparators.contains(_separator)) _separator,
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

  /// 分隔符的展示名：空串与单个空格在 chip 上看不出区别，需要可读占位。
  String _separatorLabel(String option) {
    if (option.isEmpty) {
      return '无'.tl;
    }
    if (option == ' ') {
      return '空格'.tl;
    }
    return option;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _orderedSelected;
    final preview = pixivDirNameTemplatePreview(selected, _separator);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '勾选要包含的字段，长按可拖动调整顺序。'.tl,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        ReorderableListView.builder(
          // 与参考实现一致：让列表**自适应内容高度**（shrinkWrap + 禁自身滚动），
          // 而不是在外面套固定高度。固定高度一旦与"圆角卡片 + 两行文字"的实际行高
          // 对不上，列表就会变成内部可滚，拖动与滚动手势互相干扰。
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: _order.length,
          // 拖动中的浮起卡片保持与静态一致的圆角：默认实现会套一层带阴影的直角
          // Material 方块，把圆角盖掉。
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
              // **整列表替换**，不能写成 `clear()` + `addAll()` 原地改：
              // `ReorderableListView` 依赖 children 列表被换成新实例来重建 ——
              // 原地修改会让它只生效一次，之后再也拖不动。
              _order = reorderPixivDirNameFieldOrder(
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
              key: ValueKey<String>('pixiv-dir-field-$key'),
              index: index,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _PixivDirNameFieldRow(
                  label: (kPixivDirNameFieldLabels[key] ?? key).tl,
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
        SelectableText(
          selected.isEmpty ? '（未勾选任何字段）'.tl : preview,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '只影响之后的新下载；已下载目录不会被重命名'
                  '（目录名已写进下载记录，改名会让旧记录找不到内容）。'
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
/// 观感照搬参考实现（12 圆角、勾选换底色与边框）；区别是**保留明确的勾选框** ——
/// 参考项目用"整行底色"表达的是"算不算计入 PASS"这个附加维度，
/// 而这里"包不包含这个字段"是主语义，必须一眼看出勾没勾。
///
/// 手柄只是视觉提示：**整行都能长按拖动**（见外层 `ReorderableDelayedDragStartListener`）。
class _PixivDirNameFieldRow extends StatelessWidget {
  const _PixivDirNameFieldRow({
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected
            ? scheme.primary.withValues(alpha: 0.08)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(_radius),
        border: Border.all(
          color: selected
              ? scheme.primary.withValues(alpha: 0.35)
              : scheme.outlineVariant,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(_radius),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            children: [
              // 勾选框自己消费点击、不冒泡到外层 InkWell，因此不会双触发。
              Checkbox(value: selected, onChanged: (_) => onToggle()),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      variable,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 2, right: 8),
                child: Icon(
                  Icons.drag_handle,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
