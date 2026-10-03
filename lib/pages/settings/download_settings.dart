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
    // 「修正已下载文件夹名」已移到「数据管理」区（`app_settings.dart`）。
    //
    // 理由：它是一次性的**历史数据维护**动作（把早期哔咔源留下的"纯 id 目录"
    // 改成标题），与「刷新本地漫画」「重新扫描磁盘」同类，不属于"下载参数"。
    // 放在「并发下载数」正下方会让用户误以为它是常规下载设置。
    //
    // 这里原有一条 `const Divider()`：32 号给 `SettingsTitle` 统一加了主分割线
    // （见 `settings_common_widgets.dart` 的 `SettingsSectionDivider`），
    // 留着就会紧挨着出现两条线。删掉这一条，分区线由那套机制统一出。
    SettingsTitle('禁漫 (jm) 网络'.tl),
    const _JmApiDomainsTile(),
    SettingsTitle('Pixiv'.tl),
    const _PixivDirNameTemplateTile(),
    const Divider(),
    const _PixivDownloadDirTile(),
    const Divider(),
    const ListTile(
      leading: Icon(Icons.folder_zip_outlined), title: Text('作品保存方式'),
      subtitle: Text('单图直接保存为图片，多图保存为 ZIP；已有作品格式保持不变'),
    ),
    const SelectSetting(
      leading: Icon(Icons.drive_file_move_outline),
      title: '已下载作品另选文件夹时', settingsIndex: pixivTransferPolicyIndex,
      values: ['copy', 'move', 'ask'], titles: ['复制', '移动', '每次提示（默认）'],
      controlWidth: 150, tailing: Icon(Icons.arrow_drop_down),
    ),
    const SelectSetting(
      leading: Icon(Icons.folder_delete_outlined),
      title: '删除下载文件夹时', settingsIndex: pixivFolderDeletePolicyIndex,
      values: ['delete', 'keep', 'ask'], titles: ['连同作品删除', '先移回主目录', '每次提示（默认）'],
      controlWidth: 170, tailing: Icon(Icons.arrow_drop_down),
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

// 「修正已下载文件夹名」（`_FixDirectoryNamesTile`）已整体移到
// `app_settings.dart` 的「数据管理」区 —— 那是历史数据维护动作，不是下载参数。
// 同时它已收窄为**只处理哔咔（picacg）的记录**（见 `fixDirectoryNames` 的注释）。

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

class _PixivDirNameTemplateTileState extends State<_PixivDirNameTemplateTile> {
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
              // 一个字段都没勾时不写盘：空模板会被渲染层退回默认模板，
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
/// ## 36 号起的默认位置
///
/// 留空**不再**表示"与其它来源共用「本应用下载目录」"，而是
/// **`<数据目录>/download_pixiv`**（与 `download` 同级）——
/// 真机反馈里 Pixiv 的目录/单图/zip 混在 `download` 里"裸露在外面"，
/// 用户要求单独放。解析统一走 `effectivePixivDownloadRoot()`。
///
/// ⚠️ 它始终是一个**独立下载根**：读取侧会把它当成"本应用的另一个下载源"
/// 参与列表扫描（见 `local_library_scan.dart` 的 Pixiv 源）。
///
/// ## 旧内容迁移
///
/// 改默认位置只影响**新**下载。36 号之前已经落进 `download` 的内容由本 tile
/// 下方的迁移入口负责搬（`foundation/pixiv_download_migration.dart`）。
class _PixivDownloadDirTile extends StatefulWidget {
  const _PixivDownloadDirTile();

  @override
  State<_PixivDownloadDirTile> createState() => _PixivDownloadDirTileState();
}

class _PixivDownloadDirTileState extends State<_PixivDownloadDirTile> {
  /// 每个候选源根里还留着多少条 Pixiv 记录（43 号续）。
  ///
  /// 全部为 0 时**不显示**迁移入口 —— 一个常年存在的"迁移"按钮会让人以为
  /// 总有什么要搬。
  ///
  /// 用 Map 而不是单个计数：源根不止一个。36 号只查了默认根，而真机上
  /// Pixiv 内容会随"换下载目录"的迁移落进 `settings[22]`
  ///（见 `pixivRelocationSourceRoots` 的注释），只查默认根会永远数不到。
  Map<String, int> _pendingByRoot = <String, int>{};

  int get _pendingTotal =>
      _pendingByRoot.values.fold<int>(0, (sum, count) => sum + count);

  @override
  void initState() {
    super.initState();
    unawaited(_detectLegacyEntries());
  }

  Future<void> _detectLegacyEntries() async {
    final counts = <String, int>{};
    for (final root in pixivRelocationSourceRoots()) {
      final count = await countPixivEntriesInRoot(root);
      if (count > 0) {
        counts[root] = count;
      }
    }
    if (!mounted) {
      return;
    }
    setState(() => _pendingByRoot = counts);
  }

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

  Future<void> _applyPixivRoot(String configured, bool migrate) async {
    final previous = effectivePixivDownloadRoot();
    final target = configured.trim().isEmpty ? defaultPixivDownloadPath() : configured.trim();
    try {
      final library = PixivLibrary(previous);
      if (migrate && OnlineDownloadManager.instance.tasks.any((t) => t.sourceKey == 'pixiv' && !t.completed && !t.cancelled)) {
        throw StateError('有未完成的Pixiv下载任务，请先完成或取消后迁移下载根');
      }
      if (Directory(previous).existsSync()) {
        await library.initialize();
        rememberPixivLibrary(previous);
        if (migrate && previous != target) {
          if (previous == appdata.settings[22].trim() || previous == legacyPixivDownloadPath()) {
            throw StateError('当前目录与漫画共用，请先将Pixiv内容归位到独立目录后迁移');
          }
          await relocatePixivLibrary(previous, target);
        }
      }
      final destination = PixivLibrary(resolvePixivLibraryRoot(target));
      await destination.initialize();
      rememberPixivLibrary(destination.root);
      appdata.settings[pixivDownloadDirSettingIndex] = configured.trim();
      await appdata.updateSettings();
      if (!mounted) return;
      setState(() {});
      await _detectLegacyEntries();
      if (mounted) await _runRescanLocalComics(context);
    } catch (e) {
      if (!mounted) return;
      await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('目录设置未完成'), content: Text('$e'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))]));
    }
  }

  Future<void> _showBrowseDialog() async {
    final previous = effectivePixivDownloadRoot();
    final controller = TextEditingController(text: appdata.settings[pixivDownloadDirSettingIndex]);
    await showDialog<void>(context: context, builder: (ctx) => _DirectoryPathDialog(
      title: '设置 Pixiv 专属下载目录', hintText: '留空使用默认位置',
      helperText: '勾选转移会连同自定义文件夹和数据库迁移到空目录；不勾选则保留旧位置供浏览。长按浏览可打开内置目录选择。',
      controller: controller, initialPath: appdata.settings[pixivDownloadDirSettingIndex],
      hasExistingDownloads: Directory(previous).existsSync(),
      onBrowse: () async { final path = await _pickFolder(); if (path != null && ctx.mounted) controller.text = path; },
      onLongPressBrowse: () async {
        final initial = controller.text;
        Navigator.pop(ctx);
        final path = await openInternalDirectoryBrowser(context, title: '选择 Pixiv 下载目录', initialPath: initial);
        if (path != null && mounted) {
          final move = await showDialog<bool>(context: context, builder: (inner) => AlertDialog(
            title: const Text('更改Pixiv下载根'), content: Text('新位置：$path'), actions: [
              TextButton(onPressed: () => Navigator.pop(inner), child: const Text('取消')),
              TextButton(onPressed: () => Navigator.pop(inner, false), child: const Text('仅更改路径')),
              TextButton(onPressed: () => Navigator.pop(inner, true), child: const Text('转移到新目录'))]));
          if (move != null) await _applyPixivRoot(path, move);
        }
      },
      onRestoreDefault: () { controller.text = ''; return Future<void>.value(); },
      onOpenCurrentDirectory: () => _openCurrentDirectory(controller.text),
      onCancel: () => Navigator.pop(ctx),
      onConfirm: (move) async {final next=controller.text;Navigator.pop(ctx);await _applyPixivRoot(next,move);},
    ));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 36 号起**恒有生效路径**（未设置时是默认的 `<数据目录>/download_pixiv`），
    // 所以不再显示"未设置"——那会让用户以为 Pixiv 内容没有自己的目录。
    // trailing 只放短占位（与「原应用下载目录」tile 的 `未设置` 一致）：
    // 写长文案会把 trailing 撑满，标题被挤成两行（真机截图已暴露）。
    final display = effectivePixivDownloadRoot();
    final useDefault = pixivDownloadRootIsDefault();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        buildResponsiveSettingTile(
          leading: const Icon(Icons.folder_special_outlined),
          title: Text('Pixiv 专属下载目录'.tl),
          subtitle: Text(
            useDefault
                ? '默认与「本应用下载目录」同级，单独存放 Pixiv 内容'.tl
                : '已自定义：Pixiv 的下载都落到这个独立目录'.tl,
          ),
          trailingWidth: 220,
          onTap: _showBrowseDialog,
          trailing: _buildPathDisplay(context, display),
        ),
        if (_pendingTotal > 0)
          ListTile(
            leading: const Icon(Icons.drive_file_move_outline),
            title: Text('把旧的 Pixiv 下载搬过来'.tl),
            subtitle: Text(
              '检测到 $_pendingTotal 项 Pixiv 内容仍在其它下载目录里'.tl,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _migrateLegacyEntries,
          ),
      ],
    );
  }

  /// 把各候选源根里的 Pixiv 内容搬到当前生效的 Pixiv 根。
  ///
  /// 先确认再执行：这是**数据搬迁**，不能让用户在没被告知的情况下触发。
  /// 进度与结果都在对话框里（[_PixivMigrationDialog]），完成后重扫本地库，
  /// 让"已下载 / 资源库"立刻反映新位置。
  ///
  /// 源根可能有**多个**（默认根 + 用户自定义下载目录），逐个搬、每个弹一次
  /// 进度框 —— 复用同一个对话框，比把多源塞进去改动更小。
  Future<void> _migrateLegacyEntries({String? targetOverride}) async {
    final requestedTarget = (targetOverride ?? '').trim();
    final to = targetOverride == null
        ? effectivePixivDownloadRoot()
        : (requestedTarget.isEmpty
            ? defaultPixivDownloadPath()
            : requestedTarget);
    final sources = _pendingByRoot.entries
        .where((entry) => entry.value > 0 && entry.key != to)
        .toList();
    if (sources.isEmpty) {
      return;
    }
    final pendingTotal =
        sources.fold<int>(0, (sum, entry) => sum + entry.value);
    final breakdown = sources
        .map((entry) => '· ${entry.key}\n  （${entry.value} 项）')
        .join('\n');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('迁移 Pixiv 下载内容'.tl),
        content: Text(
          '把下列位置里的 $pendingTotal 项 Pixiv 内容移动到：\n$to\n\n'
                  '$breakdown\n\n'
                  '· 只移动 Pixiv 的内容，其它来源原样不动；\n'
                  '· 目标已存在同名条目会跳过，不会覆盖；\n'
                  '· 移动失败的内容留在原处，不会丢失。'
              .tl,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('开始迁移'.tl),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    for (final entry in sources) {
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _PixivMigrationDialog(from: entry.key, to: to),
      );
    }
    if (!mounted) {
      return;
    }
    await _detectLegacyEntries();
    if (!mounted) {
      return;
    }
    // 43 号续：**归位完成后清掉"无封面"标记**。
    //
    // 那些条目在归位**之前**（路径指向旧目录、实体已失效）就已经被打了
    // `noCoverSentinel`，而它是**一次性判定** —— 一旦落下，
    // `_ensureManagedDownloadCoverCache` 会直接短路、**永不再探测**。
    // 于是归位后封面文件明明就在包里，列表却永远是占位图标（真机踩到）。
    //
    // 放在这里而不是 `_refreshInternal`：那里处在 widget 测试路径上，
    // 加真实 IO 会让 `pumpAndSettle` 永不收敛。
    await LocalLibraryManager().clearAllNoCoverSentinels();
    if (!mounted) {
      return;
    }
    await _runRescanLocalComics(context);
  }
}

/// 迁移进度 / 结果对话框。
///
/// 迁移本身在 [initState] 里启动（不是按钮回调），这样对话框一出现就开始干活，
/// 进度回调只需要 `setState`。完成后再挂一个「完成」按钮 ——
/// 结果必须让用户看到：搬了几条、跳过几条、哪些失败。
class _PixivMigrationDialog extends StatefulWidget {
  const _PixivMigrationDialog({required this.from, required this.to});

  final String from;
  final String to;

  @override
  State<_PixivMigrationDialog> createState() => _PixivMigrationDialogState();
}

class _PixivMigrationDialogState extends State<_PixivMigrationDialog> {
  int _current = 0;
  int _total = 0;
  String _label = '';
  PixivMigrationResult? _result;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    final result = await migratePixivDownloadEntries(
      fromRoot: widget.from,
      toRoot: widget.to,
      onProgress: (current, total, label) {
        if (!mounted) {
          return;
        }
        setState(() {
          _current = current;
          _total = total;
          _label = label;
        });
      },
    );
    if (!mounted) {
      return;
    }
    setState(() => _result = result);
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    if (result == null) {
      return AlertDialog(
        title: Text('正在迁移 Pixiv 下载'.tl),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            LinearProgressIndicator(
              value: _total <= 0 ? null : _current / _total,
            ),
            const SizedBox(height: 12),
            Text('$_current / $_total'),
            if (_label.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                _label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      );
    }
    final failures = result.failures;
    return AlertDialog(
      title: Text('迁移完成'.tl),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('已移动 ${result.movedEntries} 项，跳过 ${result.skippedEntries} 项'
                .tl),
            if (failures.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text('${failures.length} 项失败：'.tl),
              for (final failure in failures.take(8))
                Text('· $failure',
                    style: Theme.of(context).textTheme.bodySmall),
              if (failures.length > 8)
                Text('· …', style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('完成'.tl),
        ),
      ],
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
    _order = List<String>.of(kPixivDirNameFieldKeys);
    _selected = <String>{...widget.initialFields};
    // 未勾选项保留默认位置；已勾选项在对应位置按保存的顺序还原。
    // 默认只勾标题/ID 时，作者仍在首行，而不是被挤到已勾选项后面。
    var selectedIndex = 0;
    for (var i = 0; i < _order.length; i++) {
      if (_selected.contains(_order[i])) {
        _order[i] = widget.initialFields[selectedIndex++];
      }
    }
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
