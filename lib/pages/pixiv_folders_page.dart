import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' hide Row;
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/foundation/pixiv_download_root.dart';
import 'package:picakeep/foundation/pixiv_library.dart';
import 'package:picakeep/foundation/pixiv_library_locations.dart';
import 'package:picakeep/foundation/trash.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';

String _operationLabel(Map<String, Object?> op) {
  final data = jsonDecode(op['payload'] as String) as Map;
  final kind = switch (op['kind']) {
    'batch' => '批量操作',
    'transfer' => data['move'] == true ? '移动作品' : '复制作品',
    'rename' => '重命名文件夹',
    'create' => '新建文件夹',
    'keep' => '将作品移回主目录',
    'remove' => '删除文件夹',
    'restore' => '还原文件夹',
    _ => '文件操作',
  };
  return '$kind未完成';
}

Future<void> _showError(BuildContext context, Object error) async {
  if (!context.mounted) return;
  await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
            title: const Text('操作未完成'),
            content: SingleChildScrollView(child: Text(error.toString())),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))
            ],
          ));
}

Future<String?> _askName(BuildContext context, {String? current}) async {
  final controller = TextEditingController(text: current);
  String? error;
  final value = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
            builder: (ctx, setState) => AlertDialog(
              title: Text(current == null ? '新建下载文件夹' : '重命名'),
              content: TextField(
                  controller: controller,
                  autofocus: true,
                  decoration:
                      InputDecoration(labelText: '文件夹名称', errorText: error)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () {
                      try {
                        PixivLibrary.validateSegment(controller.text);
                        Navigator.pop(ctx, controller.text);
                      } catch (_) {
                        setState(() => error = '名称不合法，不能包含路径分隔符或保留名');
                      }
                    },
                    child: const Text('确定'))
              ],
            ),
          ));
  // Dialog route closes with an animation; keep its controller alive until then.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  controller.dispose();
  return value;
}

Future<PixivFolder?> choosePixivFolder(BuildContext context) async {
  final library = PixivLibrary(effectivePixivDownloadRoot());
  await library.initialize();
  rememberPixivLibrary(library.root);
  if (!context.mounted) return null;
  return showDialog<PixivFolder>(
      context: context, builder: (_) => _FolderPicker(library: library));
}

class _FolderPicker extends StatefulWidget {
  const _FolderPicker({required this.library});
  final PixivLibrary library;
  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  String? selected;
  bool busy = false;
  @override
  Widget build(BuildContext context) {
    late final List<PixivFolder> folders;
    try {
      folders = widget.library.folders(counts: true);
    } catch (error) {
      return AlertDialog(title: const Text('无法读取下载文件夹'),
        content: Text('$error'), actions: [TextButton(
          onPressed: () => Navigator.pop(context), child: const Text('关闭'))]);
    }
    return AlertDialog(
      title: const Text('选择下载文件夹'),
      content: SizedBox(
          width: 440,
          height: 340,
          child: ListView(children: [
            for (final f in folders)
              ListTile(
                  leading: Icon(selected == f.id
                      ? Icons.radio_button_checked
                      : Icons.folder_outlined),
                  title: Text(f.name),
                  subtitle: Text(
                      f.isDefault ? '默认下载 · ${f.count} 项' : '${f.count} 项'),
                  selected: selected == f.id,
                  onTap: busy ? null : () => setState(() => selected = f.id)),
          ])),
      actions: [
        TextButton(
            onPressed: busy
                ? null
                : () async {
                    final name = await _askName(context);
                    if (name == null || !mounted) return;
                    setState(() => busy = true);
                    try {
                      final f = await widget.library.createFolder(name);
                      if (mounted) setState(() => selected = f.id);
                      App.notifyLocalDataChanged();
                    } catch (e) {
                      if (context.mounted) await _showError(context, e);
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            child: const Text('新建')),
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
            onPressed: selected == null || busy
                ? null
                : () =>
                    Navigator.pop(context, widget.library.folder(selected!)),
            child: const Text('选择'))
      ],
    );
  }
}

Future<bool?> _chooseMove(BuildContext context, String summary,
    {bool? explicitMove}) async {
  if (explicitMove != null) return explicitMove;
  final policy =
      normalizePixivTransferPolicy(appdata.settings[pixivTransferPolicyIndex]);
  if (policy != 'ask') return policy == 'move';
  return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
            title: const Text('作品已下载'),
            content: Text(summary),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('复制')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('移动'))
            ],
          ));
}

/// Works from local metadata even when the online details page cannot load.
PixivRecord recordForLocalItem(LocalLibraryComicItem item) {
  final file = item.fileSystemPath!;
  final root = p.dirname(item.sourceDbPath ?? file);
  final library = PixivLibrary(effectivePixivDownloadRoot());
  final registered =
      library.folders().where((f) => p.equals(f.path, root)).firstOrNull;
  final folder = registered ??
      PixivFolder(
          root: root,
          libraryId: root,
          id: 'root',
          name: p.basename(root),
          relativePath: '.');
  final db = sqlite3.open(p.join(root, 'download.db'), mode: OpenMode.readOnly);
  try {
    final row = db.select('SELECT * FROM download WHERE id=?',
        [item.sourceDbId ?? item.originalId]);
    if (row.isEmpty) throw StateError('找不到原下载记录');
    return PixivRecord(folder, Map<String, Object?>.from(row.single));
  } finally {
    db.dispose();
  }
}

Future<void> transferPixivItems(
    BuildContext context, List<LocalLibraryComicItem> items,
    {required bool move}) async {
  try {
    final target = await choosePixivFolder(context);
    if (target == null || !context.mounted) return;
    final records = items.map(recordForLocalItem).toList();
    await _runTransfers(context, records, target, move);
  } catch (e) {
    if (context.mounted) await _showError(context, e);
  }
}

Future<void> downloadPixivToFolder(BuildContext context, PixivComicInfo info,
    {required bool choose}) async {
  try {
    final library = PixivLibrary(effectivePixivDownloadRoot());
    await library.initialize();
    rememberPixivLibrary(library.root);
    if (!context.mounted) return;
    final target =
        choose ? await choosePixivFolder(context) : library.defaultFolder;
    if (target == null || !context.mounted) return;
    final id = 'pixiv${info.id}';
    if (library.find(target.id, id) case final existing?) {
      await PixivLibrary.snapshotOf(existing.path);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('此文件夹已存在该作品')));
      }
      return;
    }
    final local = (await LocalLibraryManager().getManagedDownloads())
        .where((i) => i.originalId == id && i.localStorageExists)
        .toList();
    if (local.isNotEmpty) {
      final source = recordForLocalItem(local.first);
      if (!context.mounted) return;
      final move = await _chooseMove(
          context, '${source.name}\n从：${source.folder.name}\n到：${target.name}');
      if (move != null && context.mounted) {
        await _runTransfers(context, [source], target, move);
      }
      return;
    }
    await OnlineDownloadManager.instance.enqueuePixiv(info, target: target);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已加入下载队列：${target.name}')));
    }
  } catch (e) {
    if (context.mounted) await _showError(context, e);
  }
}

Future<void> _runTransfers(BuildContext context, List<PixivRecord> records,
    PixivFolder target, bool move) async {
  await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _TransferProgress(records: records, target: target, move: move));
  await LocalLibraryManager().refresh();
  App.notifyLocalDataChanged();
}

class _TransferProgress extends StatefulWidget {
  const _TransferProgress(
      {required this.records, required this.target, required this.move});
  final List<PixivRecord> records;
  final PixivFolder target;
  final bool move;
  @override
  State<_TransferProgress> createState() => _TransferProgressState();
}

class _TransferProgressState extends State<_TransferProgress> {
  int current = 0, success = 0, skipped = 0;
  bool done = false, stop = false;
  final failures = <String>[];
  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final library = PixivLibrary(widget.target.root);
    try {
      final batch = library.createBatch(widget.records, widget.target.id,
          move: widget.move);
      await library.runBatch(batch,
          shouldStop: () => stop,
          onProgress: (processed, total, ok, existing, errors) {
            current = processed;
            success = ok;
            skipped = existing;
            failures
              ..clear()
              ..addAll(errors);
            if (mounted) setState(() {});
          });
    } catch (e) {
      failures.add(e.toString());
    }
    if (mounted) setState(() => done = true);
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: done,
      child: AlertDialog(
        title: Text(done ? '操作结果' : (widget.move ? '正在移动' : '正在复制')),
        content: SingleChildScrollView(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text('目标：${widget.target.name}'),
              const SizedBox(height: 12),
              if (!done)
                LinearProgressIndicator(
                    value: widget.records.isEmpty
                        ? 0
                        : current / widget.records.length),
              Text('$current / ${widget.records.length}'),
              Text('成功 $success，已存在 $skipped，失败 ${failures.length}'),
              if (stop) Text('未开始 ${widget.records.length - current} 项'),
              ...failures.map((f) => Text(f)),
              if (failures.isNotEmpty || stop)
                const Text('未完成操作可在下载文件夹管理页继续处理。'),
            ])),
        actions: [
          TextButton(
              onPressed: done
                  ? () => Navigator.pop(context)
                  : () => setState(() => stop = true),
              child: Text(done ? '完成' : '停止后续项目'))
        ],
      ));
}

class PixivFoldersPage extends StatefulWidget {
  const PixivFoldersPage({super.key});
  @override
  State<PixivFoldersPage> createState() => _PixivFoldersPageState();
}

class _PixivFoldersPageState extends State<PixivFoldersPage> {
  late final library = PixivLibrary(effectivePixivDownloadRoot());
  List<PixivFolder> folders = [];
  String? error;
  bool busy = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await library.initialize();
      rememberPixivLibrary(library.root);
      folders = library.folders(counts: true);
      error = null;
    } catch (e) {
      error = e.toString();
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _act(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
      await LocalLibraryManager().refresh();
      App.notifyLocalDataChanged();
    } catch (e) {
      if (mounted) await _showError(context, e);
    }
    await _load();
  }

  Future<void> _menu(PixivFolder folder) async {
    final action = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(title: Text(folder.name), subtitle: Text(folder.path)),
              if (!folder.isRoot)
                ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('重命名'),
                    onTap: () => Navigator.pop(ctx, 'rename')),
              ListTile(
                  leading: const Icon(Icons.star_outline),
                  title: const Text('设为默认下载文件夹'),
                  onTap: () => Navigator.pop(ctx, 'default')),
              if (!folder.isRoot)
                ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title: const Text('删除'),
                    onTap: () => Navigator.pop(ctx, 'delete')),
            ])));
    if (!mounted || action == null) return;
    if (action == 'default') {
      await _act(() => library.setDefault(folder.id));
      return;
    }
    if (OnlineDownloadManager.instance.hasPixivFolderTasks(folder)) {
      await _showError(context, '有下载任务引用此文件夹，请先完成或取消任务');
      return;
    }
    if (action == 'rename') {
      final name = await _askName(context, current: folder.name);
      if (name != null && mounted) {
        await _act(() async {
          await library.rename(folder.id, name);
        });
      }
    } else if (action == 'delete') {
      final policy = normalizePixivFolderDeletePolicy(
          appdata.settings[pixivFolderDeletePolicyIndex]);
      final trash = TrashManager.instance.useTrashByDefault;
      final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
                title: const Text('删除下载文件夹'),
                content: Text(
                    '${folder.name}\n${folder.path}\n${folder.count} 项作品\n\n连同内容删除：${trash ? '进入回收站，可还原' : '永久删除，无法还原'}。\n迁回主目录：全部成功后才删除空文件夹。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('取消')),
                  if (policy != 'delete')
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, 'keep'),
                        child: const Text('先移回主目录')),
                  if (policy != 'keep')
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, 'delete'),
                        child: Text(trash ? '连同作品放进回收站' : '连同作品永久删除'))
                ],
              ));
      if (choice != null && mounted) {
        await _act(() => library.removeFolder(folder.id,
            keepWorks: choice == 'keep', useTrash: trash));
      }
    }
  }

  Future<void> _sort() async {
    final order = List<PixivFolder>.from(folders);
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (ctx) => StatefulBuilder(
                builder: (ctx, setState) => Scaffold(
                      appBar: AppBar(title: const Text('排序'), actions: [
                        TextButton(
                            onPressed: () async {
                              try {
                                await library
                                    .reorder(order.map((f) => f.id).toList());
                                if (ctx.mounted) Navigator.pop(ctx);
                              } catch (e) {
                                if (ctx.mounted) await _showError(ctx, e);
                              }
                            },
                            child: const Text('保存'))
                      ]),
                      body: ReorderableListView.builder(
                          itemCount: order.length,
                          onReorder: (oldIndex, newIndex) => setState(() {
                                if (newIndex > oldIndex) newIndex--;
                                order.insert(
                                    newIndex, order.removeAt(oldIndex));
                              }),
                          itemBuilder: (_, i) => ListTile(
                              key: ValueKey(order[i].id),
                              leading: const Icon(Icons.folder),
                              title: Text(order[i].name),
                              trailing: const Icon(Icons.drag_handle))),
                    ))));
    try {
      await library.reorder(order.map((f) => f.id).toList());
    } catch (e) {
      if (mounted) await _showError(context, e);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final pending =
        error == null && !busy ? library.pending() : <Map<String, Object?>>[];
    final trash = error == null && !busy
        ? library.trashedFolders()
        : <Map<String, Object?>>[];
    return PopScope(
        canPop: !busy,
        child: Scaffold(
          appBar: AppBar(title: const Text('下载文件夹')),
          body: Column(children: [
            Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton.icon(
                          onPressed: busy
                              ? null
                              : () async {
                                  final name = await _askName(context);
                                  if (name != null && mounted) {
                                    await _act(() async {
                                      await library.createFolder(name);
                                    });
                                  }
                                },
                          icon: const Icon(Icons.create_new_folder_outlined),
                          label: const Text('新建')),
                      TextButton.icon(
                          onPressed: busy ? null : _sort,
                          icon: const Icon(Icons.reorder),
                          label: const Text('排序')),
                    ])),
            if (busy) const LinearProgressIndicator(),
            if (hasPendingPixivRootMove)
              ListTile(
                  title: const Text('下载根迁移未完成'),
                  trailing: TextButton(
                      onPressed: busy ? null : () => _act(resumePixivRootMove),
                      child: const Text('继续'))),
            if (error != null)
              Padding(padding: const EdgeInsets.all(16), child: Text(error!)),
            Expanded(
                child: CustomScrollView(slivers: [
              SliverPadding(
                  padding: const EdgeInsets.all(12),
                  sliver: SliverLayoutBuilder(builder: (ctx, constraints) {
                    final columns = constraints.crossAxisExtent < 360 ||
                            MediaQuery.textScalerOf(ctx).scale(15) > 20
                        ? 1
                        : (constraints.crossAxisExtent / 320).ceil();
                    return SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            mainAxisExtent: 60,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 6),
                        delegate: SliverChildBuilderDelegate((ctx, i) {
                          final f = folders[i];
                          return InkWell(
                              onTap: busy
                                  ? null
                                  : () => Navigator.pop(context, f.id),
                              onLongPress: busy ? null : () => _menu(f),
                              onSecondaryTap: busy ? null : () => _menu(f),
                              child: Row(children: [
                                const Icon(Icons.folder),
                                const SizedBox(width: 10),
                                Expanded(
                                    child: Text(f.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis)),
                                if (f.isDefault)
                                  const Tooltip(
                                      message: '默认下载',
                                      child: Icon(Icons.star, size: 16)),
                                Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 9, vertical: 3),
                                    decoration: BoxDecoration(
                                        color: Theme.of(ctx)
                                            .colorScheme
                                            .primaryContainer,
                                        borderRadius:
                                            BorderRadius.circular(99)),
                                    child: Text('${f.count}'))
                              ]));
                        }, childCount: folders.length));
                  })),
              if (pending.isNotEmpty)
                const SliverToBoxAdapter(child: ListTile(title: Text('未完成操作'))),
              for (final op in pending)
                SliverToBoxAdapter(
                    child: ListTile(
                        title: Text(_operationLabel(op)),
                        subtitle: Text(op['error']?.toString() ?? '操作被中断'),
                        trailing: TextButton(
                            onPressed: busy
                                ? null
                                : () => _act(
                                    () => library.resume(op['id'] as String)),
                            child: const Text('继续')))),
              if (trash.isNotEmpty)
                const SliverToBoxAdapter(
                    child: ListTile(title: Text('下载文件夹回收站'))),
              for (final op in trash)
                SliverToBoxAdapter(
                    child: ListTile(
                        leading: const Icon(Icons.folder_delete_outlined),
                        title: Text(
                            (jsonDecode(op['payload'] as String) as Map)['name']
                                .toString()),
                        trailing: TextButton(
                            onPressed: busy
                                ? null
                                : () => _act(() =>
                                    library.restoreFolder(op['id'] as String)),
                            child: const Text('还原')))),
            ])),
          ]),
        ));
  }
}
