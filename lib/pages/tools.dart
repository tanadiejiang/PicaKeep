import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:picakeep/base.dart' hide eraseCache;
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/archive/archive_memory_cache.dart';
import 'package:picakeep/foundation/archive/archive_reading_service.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/remote_library_data_source.dart';
import 'package:picakeep/pages/app_capabilities_page.dart';
import 'package:picakeep/pages/local_library_page.dart';
import 'package:picakeep/pages/service_info_page.dart';
import 'package:picakeep/pages/settings/archive_settings_page.dart';
import 'package:picakeep/pages/tool_display_config.dart';
import 'package:picakeep/pages/trash_page.dart';
import 'package:picakeep/tools/io_tools.dart';
import 'package:picakeep/tools/translations.dart';

class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key, this.startInCustomizeMode = false});

  final bool startInCustomizeMode;

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  final ScrollController _scrollController = ScrollController();

  bool _customizingExternalTools = false;
  bool _cacheManagementExpanded = false;
  bool _loadingCacheSize = false;
  int? _cacheSizeBytes;
  late List<String> _orderedExternalIds;
  late Set<String> _visibleExternalIds;

  @override
  void initState() {
    super.initState();
    _customizingExternalTools = widget.startInCustomizeMode;
    final preferences = readToolDisplayPreferences();
    _orderedExternalIds = List<String>.from(preferences.orderedExternalIds);
    _visibleExternalIds = Set<String>.from(preferences.visibleExternalIds);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _toggleCustomizeMode() {
    setState(() {
      _customizingExternalTools = !_customizingExternalTools;
    });
  }

  void _exitCustomizeMode() {
    if (!_customizingExternalTools) {
      return;
    }
    setState(() {
      _customizingExternalTools = false;
    });
  }

  void _enterCustomizeMode() {
    if (_customizingExternalTools) {
      return;
    }
    setState(() {
      _customizingExternalTools = true;
    });
  }

  void _toggleExternalToolVisibility(String id) {
    setState(() {
      if (_visibleExternalIds.contains(id)) {
        _visibleExternalIds.remove(id);
      } else {
        _visibleExternalIds.add(id);
      }
    });
    unawaited(_saveExternalToolPreferences());
  }

  Future<void> _saveExternalToolPreferences() {
    return saveToolDisplayPreferences(
      ToolDisplayPreferences(
        orderedExternalIds: _orderedExternalIds,
        visibleExternalIds: _visibleExternalIds,
      ),
    );
  }

  void _toggleCacheManagement() {
    setState(() {
      _cacheManagementExpanded = !_cacheManagementExpanded;
    });
    if (_cacheManagementExpanded) {
      unawaited(_refreshCacheSize());
    }
  }

  Future<void> _refreshCacheSize() async {
    if (_loadingCacheSize) {
      return;
    }
    setState(() {
      _loadingCacheSize = true;
    });
    // 先按 cacheLimit 清理超限的旧缓存（LRU），再统计——否则 trim 只在远程
    // 封面下载后触发，平时缓存会一直超限不降，工具页显示的"当前"也下不来。
    await RemoteLibraryDataSource.trimCacheToLimit();
    final size = await _calculateCacheSize();
    if (!mounted) {
      return;
    }
    setState(() {
      _cacheSizeBytes = size;
      _loadingCacheSize = false;
    });
  }

  Future<int> _calculateCacheSize() async {
    var total = 0;
    final cacheDirectories = <Directory>[
      Directory(App.cachePath),
      Directory('${App.dataPath}${Platform.pathSeparator}cache'),
    ];
    for (final cacheDirectory in cacheDirectories) {
      if (!await cacheDirectory.exists()) {
        continue;
      }
      await for (final entity in cacheDirectory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    }
    return total;
  }

  String get _cacheLimitText {
    final current = _cacheSizeBytes == null
        ? (_loadingCacheSize ? '计算中'.tl : '--')
        : bytesLengthToReadableSize(_cacheSizeBytes!);
    final limit =
        bytesLengthToReadableSize(appdata.appSettings.cacheLimit * 1024 * 1024);
    return '$current / $limit';
  }

  Future<void> _editCacheLimit(BuildContext context) async {
    final controller =
        TextEditingController(text: appdata.appSettings.cacheLimit.toString());
    final value = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('缓存大小限制'.tl),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            suffixText: 'MB',
            hintText: '请输入缓存大小限制'.tl,
          ),
          onSubmitted: (raw) {
            final parsed = int.tryParse(raw.trim());
            if (parsed != null && parsed > 0) {
              Navigator.of(dialogContext).pop(parsed);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('取消'.tl),
          ),
          FilledButton(
            onPressed: () {
              final parsed = int.tryParse(controller.text.trim());
              if (parsed != null && parsed > 0) {
                Navigator.of(dialogContext).pop(parsed);
              }
            },
            child: Text('确定'.tl),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) {
      return;
    }
    appdata.appSettings.cacheLimit = value;
    await appdata.updateSettings();
    if (mounted) {
      setState(() {});
      // 新限制立即生效：按新值清理超限旧缓存并刷新显示。
      unawaited(_refreshCacheSize());
    }
  }

  Future<void> _openTool(BuildContext context, String id) {
    switch (id) {
      case serviceInfoToolId:
        return Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const ServiceInfoPage(standalone: true),
          ),
        );
      case localFilesToolId:
        return Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const LocalLibraryFilesPage(),
          ),
        );
      case localStorageToolId:
        return Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const LocalLibraryStoragePage(),
          ),
        );
      case albumsToolId:
        return Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const LocalLibraryPage(
              albumOnly: true,
              title: '图集',
            ),
          ),
        );
      case appCapabilitiesToolId:
        return Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AppCapabilitiesPage()),
        );
      case trashToolId:
        return Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const TrashPage()),
        );
      case clearCacheToolId:
        return _clearCache(context);
      case archiveSettingsToolId:
        return Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ArchiveSettingsPage()),
        );
      default:
        return Future.value();
    }
  }

  Future<void> _clearCache(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('正在清理缓存'.tl),
        duration: const Duration(seconds: 10),
      ),
    );
    await eraseCache();
    if (!context.mounted) {
      return;
    }
    setState(() {
      _cacheSizeBytes = 0;
    });
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('缓存已清理'.tl),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<void> _editArchiveCacheLimit(BuildContext context) async {
    final current = int.tryParse(
          appdata.settings[archiveReadingCacheLimitMbSettingIndex],
        ) ??
        32;
    final controller = TextEditingController(text: current.toString());
    final value = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('压缩包阅读缓存大小限制'.tl),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(suffixText: 'MB', hintText: '8~256'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text('取消'.tl),
          ),
          TextButton(
            onPressed: () {
              final v = int.tryParse(controller.text);
              Navigator.of(dialogContext).pop(v);
            },
            child: Text('确定'.tl),
          ),
        ],
      ),
    );
    if (value != null) {
      final clamped = value.clamp(8, 256);
      appdata.settings[archiveReadingCacheLimitMbSettingIndex] = clamped.toString();
      await appdata.updateSettings();
      ArchiveMemoryCache.instance.setLimitMB(clamped);
      if (mounted) setState(() {});
    }
  }

  Future<void> _clearArchiveCache(BuildContext context) async {
    ArchiveReadingService.instance.clearAllReadingState();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('压缩包阅读缓存已清理'.tl),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Widget _buildCacheManagementCard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card.outlined(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.delete_sweep),
            title: Text('缓存管理'.tl),
            subtitle: Text('管理本地缓存数据'.tl),
            trailing: AnimatedRotation(
              turns: _cacheManagementExpanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 180),
              child: const Icon(Icons.chevron_right),
            ),
            onTap: _toggleCacheManagement,
            onLongPress: _enterCustomizeMode,
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Column(
              children: [
                Divider(height: 1, color: colorScheme.outlineVariant),
                ListTile(
                  leading: const Icon(Icons.sd_storage_outlined),
                  title: Text('缓存大小限制'.tl),
                  subtitle: Text(_cacheLimitText),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _editCacheLimit(context),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: Text('清除缓存'.tl),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _clearCache(context),
                ),
                ListTile(
                  leading: const Icon(Icons.folder_zip_outlined),
                  title: Text('压缩包阅读缓存大小限制'.tl),
                  subtitle: Text(
                    '${appdata.settings[archiveReadingCacheLimitMbSettingIndex]} MB',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _editArchiveCacheLimit(context),
                ),
                ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: Text('清理压缩包阅读缓存'.tl),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _clearArchiveCache(context),
                ),
              ],
            ),
            crossFadeState: _cacheManagementExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 180),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildRegularToolCards(BuildContext context) {
    return _orderedExternalIds
        .map((id) => toolDisplayDefinitionMap[id])
        .whereType<ToolDisplayDefinition>()
        .map(
          (definition) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: definition.id == clearCacheToolId
                ? _buildCacheManagementCard(context)
                : _ToolCard(
                    key: ValueKey('tool_${definition.id}'),
                    icon: definition.icon,
                    title: definition.title.tl,
                    subtitle: definition.subtitle.tl,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openTool(context, definition.id),
                    onLongPress: _enterCustomizeMode,
                  ),
          ),
        )
        .toList(growable: false);
  }

  List<Widget> _buildCustomizeEditorCards(BuildContext context) {
    return _orderedExternalIds
        .map((id) => toolDisplayDefinitionMap[id])
        .whereType<ToolDisplayDefinition>()
        .map(
          (definition) => Padding(
            key: ValueKey('external_${definition.id}'),
            padding: const EdgeInsets.only(bottom: 12),
            child: _ToolCard(
              icon: definition.icon,
              title: definition.title.tl,
              subtitle: definition.subtitle.tl,
              trailing: const Icon(Icons.menu),
              selected: _visibleExternalIds.contains(definition.id),
              onTap: () => _toggleExternalToolVisibility(definition.id),
            ),
          ),
        )
        .toList(growable: false);
  }

  Widget _buildNormalBody(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: _buildRegularToolCards(context),
    );
  }

  Widget _buildCustomizeBody(BuildContext context) {
    return ReorderableBuilder(
      scrollController: _scrollController,
      longPressDelay: const Duration(milliseconds: 500),
      onReorder: (reorderFunc) {
        setState(() {
          _orderedExternalIds = List<String>.from(
            reorderFunc(List<String>.from(_orderedExternalIds)),
          );
        });
        unawaited(_saveExternalToolPreferences());
      },
      dragChildBoxDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
      ),
      builder: (children) {
        return ListView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: children,
        );
      },
      children: _buildCustomizeEditorCards(context),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    if (_customizingExternalTools) {
      return AppBar(
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: _exitCustomizeMode,
          icon: const Icon(Icons.close),
        ),
        titleSpacing: 0,
        title: Text('外显按钮与排序'.tl),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                '${'已选择'.tl} ${_visibleExternalIds.length} ${'个项目'.tl}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
        ],
      );
    }

    return AppBar(
      title: Text('工具'.tl),
      actions: [
        IconButton(
          tooltip: '外显按钮与排序'.tl,
          onPressed: _toggleCustomizeMode,
          icon: const Icon(Icons.tune_outlined),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(context),
      // 预返回动画（predictive back）会缩放整页。工具页 body 内有多张
      // Card.outlined(Clip.antiAlias) + AnimatedCrossFade，动画期间每张卡片
      // 各自触发离屏 saveLayer（profile 录制见 saveLayer×52），120Hz 下 raster
      // 超 8.33ms 预算导致返回动画卡顿。用 RepaintBoundary 把整页栅格化成单层，
      // 返回缩放只合成这一层纹理，避免每帧重做几十个 saveLayer。
      body: RepaintBoundary(
        child: _customizingExternalTools
            ? _buildCustomizeBody(context)
            : _buildNormalBody(context),
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onLongPress,
    this.trailing,
    this.selected = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card.outlined(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          ListTile(
            leading: Icon(icon),
            title: Text(title),
            subtitle: Text(subtitle),
            trailing: trailing,
            onTap: onTap,
            onLongPress: onLongPress,
          ),
          if (selected)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.15),
                    border: Border.all(
                      color: colorScheme.primary,
                      width: 1.6,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          colorScheme.primary.withValues(alpha: 0.09),
                          colorScheme.primary.withValues(alpha: 0.19),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
