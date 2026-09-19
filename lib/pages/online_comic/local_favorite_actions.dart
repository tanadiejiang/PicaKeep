import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:picakeep/foundation/local_favorites.dart';

/// Returns true only when the user explicitly chooses the platform action.
Future<bool> choosePlatformFavorite(
    BuildContext context, FavoriteItem item) async {
  final choice = await showModalBottomSheet<bool>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
            leading: const Icon(Icons.bookmark_add_outlined),
            title: const Text('本地收藏夹'),
            onTap: () => Navigator.pop(sheetContext, false)),
        ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('平台收藏'),
            onTap: () => Navigator.pop(sheetContext, true)),
      ]),
    ),
  );
  if (choice == false && context.mounted) {
    await showLocalFavoriteFoldersWithFeedback(context, item);
  }
  return choice == true && context.mounted;
}

bool isLocallyFavorited(FavoriteItem item) =>
    isLocalFavoriteTarget(item.target, item.type);
bool isLocalFavoriteTarget(String target, FavoriteType type) {
  final manager = LocalFavoritesManager();
  return manager.folderNames
      .any((folder) => manager.comicExists(folder, target, type.key));
}

/// 单本收藏对话框。返回 null 表示用户取消（未提交任何改动）。
Future<LocalFavoriteBatchResult?> showLocalFavoriteFolders(
        BuildContext context, FavoriteItem item) =>
    showDialog<LocalFavoriteBatchResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _LocalFavoriteFolders(items: [item], batch: false),
    );

/// 单本入口：显示对话框并在提交后给出提示；用户取消时不提示。
///
/// 对话框使用「暂存 + 提交」语义：勾选只改本地选择状态，点「完成」才写库，
/// 直接关闭对话框视为放弃。因此提示只能由调用方在拿到结果后显示
/// （对话框自身的 SnackBar 会随其销毁而消失）。
Future<void> showLocalFavoriteFoldersWithFeedback(
    BuildContext context, FavoriteItem item) async {
  final result = await showLocalFavoriteFolders(context, item);
  if (result == null || !context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(localFavoriteSingleMessage(result))));
}

/// 单本收藏提交后的提示文案。
String localFavoriteSingleMessage(LocalFavoriteBatchResult result) {
  if (result.failedRelations > 0) {
    final base = result.addedRelations == 0
        ? '收藏操作失败，请重试'
        : '已添加到本地收藏，部分收藏夹失败';
    // 新建的收藏夹即使收藏失败也已落库，必须让用户知道，
    // 否则收藏夹列表里会"凭空"多出一个空夹而没有任何解释。
    if (result.createdFolders.isNotEmpty) {
      return '$base；已创建 ${result.createdFolders.length} 个收藏夹，未成功添加的空夹已保留';
    }
    return base;
  }
  if (result.addedRelations > 0) return '已添加到本地收藏';
  return '已取消本地收藏';
}

Future<LocalFavoriteBatchResult?> showAddToLocalFavoriteFolders(
  BuildContext context,
  List<FavoriteItem> items,
) =>
    showDialog<LocalFavoriteBatchResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _LocalFavoriteFolders(items: List.unmodifiable(items), batch: true),
    );

String localFavoriteBatchMessage(LocalFavoriteBatchResult result) {
  String message;
  if (result.failedRelations > 0) {
    message = result.addedRelations == 0 && result.alreadyPresentRelations == 0
        ? '添加失败，未新增收藏，请重试'
        : '已新增 ${result.addedRelations} 项，${result.alreadyPresentRelations} 项已存在，${result.failedRelations} 项失败（项指漫画与收藏夹的关系）';
    final reason =
        result.relations.where((r) => r.error != null).firstOrNull?.error;
    if (reason != null) {
      message += '：${reason.length > 120 ? reason.substring(0, 120) : reason}';
    }
    if (result.createdFolders.isNotEmpty) {
      message += '；已创建 ${result.createdFolders.length} 个收藏夹，未成功添加的空夹已保留';
    }
  } else if (result.addedRelations == 0) {
    message = '所选漫画已在目标收藏夹中';
  } else if (result.alreadyPresentRelations == 0) {
    message = '已添加 ${result.addedComics} 本到本地收藏（${result.folderCount} 个收藏夹）';
  } else {
    message =
        '已新增 ${result.addedRelations} 项收藏，${result.alreadyPresentRelations} 项已存在；涉及 ${result.totalComics} 本漫画';
  }
  return message;
}

class _LocalFavoriteFolders extends StatefulWidget {
  const _LocalFavoriteFolders({required this.items, required this.batch});
  final List<FavoriteItem> items;
  final bool batch;
  @override
  State<_LocalFavoriteFolders> createState() => _LocalFavoriteFoldersState();
}

class _LocalFavoriteFoldersState extends State<_LocalFavoriteFolders> {
  final _name = TextEditingController();
  final _manager = LocalFavoritesManager();
  final _selected = <String>{};
  final _pending = <String>{};

  /// 进入对话框时的实际收藏状态。提交时以它和 [_selected] 的差异做增删，
  /// 因此勾选本身不写库；单本模式下它同时是 [_selected] 的初值。
  late final Set<String> _initial;

  String? _error;
  bool _busy = false;
  int _completed = 0;
  int _total = 0;
  List<String>? _submittingFolders;

  @override
  void initState() {
    super.initState();
    _initial = _favoritedFoldersNow();
    if (!widget.batch) _selected.addAll(_initial);
  }

  Set<String> _favoritedFoldersNow() {
    if (widget.batch) return const <String>{};
    final item = widget.items.single;
    return _manager.folderNames
        .where((folder) =>
            _manager.comicExists(folder, item.target, item.type.key))
        .toSet();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _toggle(String folder, bool selected) {
    setState(() {
      if (selected) {
        _selected.add(folder);
      } else {
        _selected.remove(folder);
      }
      _error = null;
    });
  }

  void _create() {
    final name = _name.text.trim();
    if (name.isEmpty || name.contains('"')) {
      setState(() => _error = name.isEmpty ? '请输入收藏夹名称' : '收藏夹名称不合法');
      return;
    }
    setState(() {
      if (!_manager.folderNames.contains(name)) _pending.add(name);
      _selected.add(name);
      _name.clear();
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (widget.batch && _selected.isEmpty) {
      setState(() => _error = '请至少选择一个收藏夹');
      return;
    }

    final items = widget.items;
    final toAdd = _selected.where((f) => !_initial.contains(f)).toList();
    final toRemove = _initial.where((f) => !_selected.contains(f)).toList();

    // 没有任何差异：不写库，直接关闭（调用方收到 null，不弹提示）。
    if (toAdd.isEmpty && toRemove.isEmpty) {
      if (mounted) Navigator.pop(context);
      return;
    }

    _submittingFolders = {..._manager.folderNames, ..._pending}.toList();
    setState(() {
      _busy = true;
      _error = null;
      _completed = 0;
      _total = (toAdd.length + toRemove.length) * items.length;
    });

    // 先执行移除侧（同步操作，量小，不单独上报进度）。
    var removed = 0;
    final removalFailures = <String>[];
    for (final folder in toRemove) {
      for (final item in items) {
        try {
          _manager.deleteComicWithTarget(folder, item.target, item.type);
          // 校验是否真的移除成功：多库合并场景下部分库可能拒绝删除。
          if (_manager.comicExists(folder, item.target, item.type.key)) {
            removalFailures.add(folder);
          }
        } catch (_) {
          removalFailures.add(folder);
        }
        removed++;
      }
    }
    if (removalFailures.isNotEmpty) {
      // 取消收藏未完全生效：停在对话框内让用户看到并重试，不继续执行添加。
      _submittingFolders = null;
      setState(() {
        _busy = false;
        _error = '部分收藏取消失败，请重试';
      });
      return;
    }

    // 待新建的收藏夹，交给 addComicsToFolders 统一记账。
    final created = <String>[];
    final failures = <String, String>{};
    for (final folder in toAdd.where(_pending.contains)) {
      try {
        if (!_manager.folderNames.contains(folder)) {
          _manager.createFolder(folder);
          created.add(folder);
        }
      } catch (e) {
        failures[folder] = '无法创建「$folder」：$e';
      }
    }

    final result = await _manager.addComicsToFolders(
      toAdd,
      items,
      createdFolders: created,
      folderCreationFailures: failures,
      onProgress: (done, total) {
        if (mounted) {
          setState(() {
            _completed = removed + done;
            _total = removed + total;
          });
        }
      },
    );
    if (mounted) Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final folders =
        _submittingFolders ?? {..._manager.folderNames, ..._pending}.toList();
    final media = MediaQuery.of(context);
    final availableHeight =
        media.size.height - media.viewInsets.vertical - media.padding.vertical;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _busy ? null : () => Navigator.pop(context),
          child: Center(
              child: GestureDetector(
            onTap: () {},
            child: AlertDialog(
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              constraints: const BoxConstraints(maxWidth: 480),
              title: Text(widget.batch ? '添加到本地收藏' : '本地收藏夹'),
              content: SizedBox(
                width: math.min(400, media.size.width - 80),
                child: ConstrainedBox(
                  constraints:
                      BoxConstraints(maxHeight: math.max(60, availableHeight * .48)),
                  child: SingleChildScrollView(
                      child:
                          Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(widget.batch
                        ? '已选择 ${widget.items.length} 本漫画，可添加到多个收藏夹'
                        : '勾选收藏夹后点「完成」生效'),
                    if (folders.isEmpty) const Text('暂无收藏夹，请先新建'),
                    for (final folder in folders)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(folder),
                        subtitle: _pending.contains(folder)
                            ? const Text('待新建')
                            : null,
                        value: _selected.contains(folder),
                        onChanged: _busy
                            ? null
                            : (value) => _toggle(folder, value == true),
                      ),
                    TextField(
                        controller: _name,
                        enabled: !_busy,
                        decoration:
                            const InputDecoration(labelText: '新收藏夹名称')),
                    TextButton.icon(
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: const Text('新建并选中'),
                        onPressed: _busy ? null : _create),
                    if (_error != null)
                      Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                  ])),
                ),
              ),
              actions: [
                if (_busy) ...[
                  LinearProgressIndicator(
                      value: _total == 0 ? null : _completed / _total),
                  Text('正在处理 $_completed / $_total'),
                ],
                TextButton(
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: Text(widget.batch ? '添加到所选收藏夹' : '完成')),
              ],
            ),
          )),
        ),
      ),
    );
  }
}
