import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:picakeep/pages/app_capabilities_page.dart';
import 'package:picakeep/pages/local_library_page.dart';
import 'package:picakeep/pages/service_info_page.dart';
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
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('缓存已清理'.tl),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  List<Widget> _buildRegularToolCards(BuildContext context) {
    return allToolDisplayDefinitions
        .map(
          (definition) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _ToolCard(
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
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _visibleExternalIds.contains(definition.id)
                        ? Icons.visibility
                        : Icons.visibility_off_outlined,
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.drag_indicator),
                ],
              ),
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
      longPressDelay: const Duration(milliseconds: 800),
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
      body: _customizingExternalTools
          ? _buildCustomizeBody(context)
          : _buildNormalBody(context),
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
