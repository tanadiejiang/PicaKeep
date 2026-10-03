import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:picakeep/foundation/illust_folder_preferences.dart';
import 'package:picakeep/foundation/pixiv_library.dart';

class IllustFolderSelector extends StatelessWidget {
  const IllustFolderSelector(
      {super.key,
      required this.folders,
      required this.totalCount,
      required this.selectedId,
      required this.onSelected,
      required this.onManage});
  final List<PixivFolder> folders;
  final int totalCount;
  final String? selectedId;
  final ValueChanged<String?>? onSelected;
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selected = folders.where((f) => f.id == selectedId).firstOrNull;
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          Expanded(
              child: PopupMenuButton<String>(
            enabled: onSelected != null,
            tooltip: '选择插画文件夹',
            constraints: BoxConstraints.tightFor(
                width: math.min(360, MediaQuery.sizeOf(context).width - 32)),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            color: colors.surface,
            elevation: 6,
            onSelected: (id) => onSelected?.call(id.isEmpty ? null : id),
            itemBuilder: (_) => [
              for (final option in [
                (id: '', name: '全部文件夹', count: totalCount),
                for (final folder in folders)
                  (id: folder.id, name: folder.name, count: folder.count),
              ])
                PopupMenuItem<String>(
                  value: option.id,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: option.id == (selected?.id ?? '')
                            ? colors.secondaryContainer
                            : null,
                        borderRadius: BorderRadius.circular(14)),
                    child: Row(children: [
                      Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                              color: colors.surfaceContainerLowest,
                              borderRadius: BorderRadius.circular(10)),
                          child: Icon(option.id.isEmpty
                              ? Icons.folder_copy_outlined
                              : Icons.folder_outlined)),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Text(option.name,
                              maxLines: 2, overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: 8),
                      Text('${option.count}',
                          style: Theme.of(context).textTheme.labelMedium),
                      if (option.id == (selected?.id ?? '')) ...[
                        const SizedBox(width: 8),
                        Icon(Icons.check_circle,
                            color: colors.primary, size: 22),
                      ],
                    ]),
                  ),
                ),
            ],
            child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(children: [
                  const Icon(Icons.folder_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(selected?.name ?? '全部文件夹',
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium)),
                  const Icon(Icons.expand_more),
                ])),
          )),
          TextButton(onPressed: onManage, child: const Text('管理')),
        ]));
  }
}

class IllustFolderRetentionTile extends StatefulWidget {
  const IllustFolderRetentionTile({super.key, this.preferences});
  final IllustFolderPreferences? preferences;
  @override
  State<IllustFolderRetentionTile> createState() =>
      _IllustFolderRetentionTileState();
}

class _IllustFolderRetentionTileState extends State<IllustFolderRetentionTile> {
  late final _preferences =
      widget.preferences ?? IllustFolderPreferences.instance;
  bool _ready = false;
  bool _loadFailed = false;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loadFailed = false);
    try {
      await _preferences.load();
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _preferences,
        builder: (_, __) => ListTile(
          leading: const Icon(Icons.folder_special_outlined),
          title: const Text('记住插画文件夹'),
          subtitle: Text(_loadFailed
              ? '读取失败，点击重试'
              : _preferences.retention == IllustFolderRetention.restart
                  ? '重启后保持'
                  : '仅本次应用会话'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _loadFailed
              ? _load
              : !_ready || _saving
                  ? null
                  : () async {
                      final next = await showDialog<IllustFolderRetention>(
                          context: context,
                          builder: (ctx) => SimpleDialog(
                                title: const Text('记住插画文件夹'),
                                children: [
                                  for (final retention
                                      in IllustFolderRetention.values)
                                    SimpleDialogOption(
                                        onPressed: () =>
                                            Navigator.of(ctx).pop(retention),
                                        child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                                vertical: 8),
                                            child: Row(children: [
                                              Icon(retention ==
                                                      _preferences.retention
                                                  ? Icons.radio_button_checked
                                                  : Icons.radio_button_off),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                  child: Text(retention ==
                                                          IllustFolderRetention
                                                              .restart
                                                      ? '重启后保持'
                                                      : '仅本次应用会话')),
                                            ]))),
                                ],
                              ));
                      if (next == null || !mounted) return;
                      setState(() => _saving = true);
                      try {
                        await _preferences.setRetention(next);
                      } catch (_) {
                        if (context.mounted) {
                          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                              const SnackBar(content: Text('未能保存记忆方式，请重试')));
                        }
                      } finally {
                        if (mounted) setState(() => _saving = false);
                      }
                    },
        ),
      );
}
