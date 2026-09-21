import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:picakeep/components/animated_check_icon.dart';
import 'package:picakeep/foundation/local_favorites.dart';

/// 平台收藏夹的一项。
///
/// [id] 由各源自己定义语义：JM 是 FID（空串 = 默认夹）、EH 是 0-9 的下标字符串、
/// Picacg / NH 无夹概念（单夹，id 自己定一个即可）。面板只负责原样回传。
class FavoriteFolderOption {
  const FavoriteFolderOption({required this.id, required this.name});

  final String id;
  final String name;
}

/// 提交结果。[ok] 为 false 时 [message] 是给用户看的错误文案。
class PlatformFavoriteSubmitResult {
  const PlatformFavoriteSubmitResult.ok() : ok = true, message = null;
  const PlatformFavoriteSubmitResult.failed(this.message) : ok = false;

  final bool ok;
  final String? message;
}

enum PlatformFavoriteAction { platformSubmitted, localSubmitted }

/// 平台收藏面板的返回值。
///
/// 只表示**成功**的提交；提交失败时面板自己弹提示并留在原地，调用方拿不到结果。
/// 用户直接关闭面板时返回 null。
class PlatformFavoritePanelResult {
  const PlatformFavoritePanelResult(
    this.action, {
    this.favoriteTarget,
    this.localResult,
  });

  final PlatformFavoriteAction action;

  /// 平台页提交后的目标态（true = 已收藏）；本地页提交时为 null。
  ///
  /// 调用方据此刷新图标，不必再猜用户是收藏还是取消。
  final bool? favoriteTarget;

  /// 本地页提交的明细；调用方用它生成提示文案（与本地收藏对话框同一套文案）。
  final LocalFavoriteBatchResult? localResult;
}

/// 显示「网络 / 本地」选项卡式收藏面板（对齐原项目 `FavoriteComicWidget` 形态）。
///
/// - 网络页：夹列表 + 文件夹图标 + 选中打勾，**单选**，底部按钮提交；
/// - 本地页：复用 PicaKeep 的复选框多选语义（含新建夹），点面板底部按钮提交；
/// - 关掉面板（点外部 / 返回）零副作用。
///
/// [onSubmitPlatform] 的 `favorite` 表示目标态；面板**只在目标态与初始态不同时**
/// 调用它 —— 因为 Picacg / NH 的接口是「翻转」而非置位，无变化也调用会把
/// "保持收藏"翻成"取消收藏"。
Future<PlatformFavoritePanelResult?> showPlatformFavoritePanel(
  BuildContext context, {
  required String sourceTitle,
  required FavoriteItem localItem,
  required bool isFavorite,
  required bool canFavorite,
  List<FavoriteFolderOption>? folders,
  Future<List<FavoriteFolderOption>> Function()? foldersLoader,
  String? foldersErrorText,
  required Future<PlatformFavoriteSubmitResult> Function({
    String? folderId,
    required bool favorite,
  }) onSubmitPlatform,
}) {
  return showModalBottomSheet<PlatformFavoritePanelResult>(
    context: context,
    // 面板内有 TabBar + 列表 + 底部按钮，必须放开高度限制。
    isScrollControlled: true,
    builder: (_) => PlatformFavoritePanel(
      sourceTitle: sourceTitle,
      localItem: localItem,
      isFavorite: isFavorite,
      canFavorite: canFavorite,
      folders: folders,
      foldersLoader: foldersLoader,
      foldersErrorText: foldersErrorText,
      onSubmitPlatform: onSubmitPlatform,
    ),
  );
}

class PlatformFavoritePanel extends StatefulWidget {
  const PlatformFavoritePanel({
    super.key,
    required this.sourceTitle,
    required this.localItem,
    required this.isFavorite,
    required this.canFavorite,
    this.folders,
    this.foldersLoader,
    this.foldersErrorText,
    required this.onSubmitPlatform,
  });

  final String sourceTitle;
  final FavoriteItem localItem;

  /// 面板打开时的平台收藏态。已收藏时底部按钮直接是「取消收藏」。
  final bool isFavorite;
  final bool canFavorite;
  final List<FavoriteFolderOption>? folders;
  final Future<List<FavoriteFolderOption>> Function()? foldersLoader;
  final String? foldersErrorText;
  final Future<PlatformFavoriteSubmitResult> Function({
    String? folderId,
    required bool favorite,
  }) onSubmitPlatform;

  @override
  State<PlatformFavoritePanel> createState() => _PlatformFavoritePanelState();
}

class _PlatformFavoritePanelState extends State<PlatformFavoritePanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this)
    ..addListener(() => setState(() {}));

  // ── 网络页状态 ──────────────────────────────────────────────────────────
  List<FavoriteFolderOption>? _folders;
  String? _foldersError;
  bool _loadingFolders = false;

  /// 选中的平台夹 id；null = 未选（面板打开时不预选，与原项目一致）。
  String? _selectedFolderId;

  /// 用户是否显式取消勾选（表达"取消收藏"的意图）。
  bool _platformCleared = false;

  // ── 本地页状态（与 _LocalFavoriteFolders 的语义保持一致）──────────────
  final _localName = TextEditingController();
  final _localManager = LocalFavoritesManager();
  final _localSelected = <String>{};
  final _localPending = <String>{};
  late final Set<String> _localInitial = _favoritedFoldersNow();
  String? _localError;

  // ── 公共 ────────────────────────────────────────────────────────────────
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 预选"这本当前已在哪些本地夹"：否则用户看不出本地收藏状态，
    // 也无法通过取消勾选来表达"从该夹移除"（提交是暂存差异语义）。
    _localSelected.addAll(_localInitial);
    _folders = widget.folders;
    if (_folders == null && widget.foldersLoader != null) {
      _loadFolders();
    }
  }

  @override
  void dispose() {
    _tab.dispose();
    _localName.dispose();
    super.dispose();
  }

  Set<String> _favoritedFoldersNow() {
    final item = widget.localItem;
    return _localManager.folderNames
        .where((folder) =>
            _localManager.comicExists(folder, item.target, item.type.key))
        .toSet();
  }

  Future<void> _loadFolders() async {
    setState(() {
      _loadingFolders = true;
      _foldersError = null;
    });
    try {
      final list = await widget.foldersLoader!.call();
      if (!mounted) return;
      setState(() {
        _folders = list;
        _loadingFolders = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingFolders = false;
        _foldersError = widget.foldersErrorText ?? '收藏夹加载失败';
      });
    }
  }

  /// 平台页当前的目标态：勾选了夹 → true；显式取消勾选 → false；未动 → null。
  bool? get _platformTarget {
    if (_selectedFolderId != null) return true;
    if (_platformCleared) return false;
    // 已收藏且没动任何东西：底部按钮是「取消收藏」，点它即表达取消意图。
    return widget.isFavorite ? false : null;
  }

  bool get _platformHasChange => _platformTarget != null;

  /// 该按什么动作提交：已收藏且没选新夹 = 取消；否则按目标态。
  bool get _submitFavoriteValue => _selectedFolderId != null;

  void _selectFolder(String id) {
    setState(() {
      if (_selectedFolderId == id) {
        // 再点一次 = 取消勾选：表达"取消平台收藏"。
        _selectedFolderId = null;
        _platformCleared = widget.isFavorite;
      } else {
        _selectedFolderId = id;
        _platformCleared = false;
      }
    });
  }

  Future<void> _submitPlatform() async {
    final target = _platformTarget;
    if (_busy || target == null) return;

    final wantFavorite = _submitFavoriteValue;
    setState(() => _busy = true);
    final res = await widget.onSubmitPlatform(
      folderId: _selectedFolderId,
      favorite: wantFavorite,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.ok) {
      Navigator.of(context).pop(
        PlatformFavoritePanelResult(
          PlatformFavoriteAction.platformSubmitted,
          favoriteTarget: wantFavorite,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(res.message ?? '操作失败')),
      );
    }
  }

  void _toggleLocal(String folder, bool selected) {
    setState(() {
      if (selected) {
        _localSelected.add(folder);
      } else {
        _localSelected.remove(folder);
      }
      _localError = null;
    });
  }

  void _createLocal() {
    final name = _localName.text.trim();
    if (name.isEmpty || name.contains('"')) {
      setState(() => _localError = name.isEmpty ? '请输入收藏夹名称' : '收藏夹名称不合法');
      return;
    }
    setState(() {
      if (!_localManager.folderNames.contains(name)) _localPending.add(name);
      _localSelected.add(name);
      _localName.clear();
      _localError = null;
    });
  }

  /// 本地提交：与 `_LocalFavoriteFolders._submit` 同语义（暂存差异 → 写库），
  /// 但**不**自己写 UI 框架（面板已有底部按钮），逻辑独立维护以免动到对话框。
  Future<void> _submitLocal() async {
    if (_busy) return;
    final item = widget.localItem;

    final toAdd =
        _localSelected.where((f) => !_localInitial.contains(f)).toList();
    final toRemove =
        _localInitial.where((f) => !_localSelected.contains(f)).toList();

    // 无差异：直接关面板，不写库、不提示（与对话框一致）。
    if (toAdd.isEmpty && toRemove.isEmpty) {
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      _busy = true;
      _localError = null;
    });

    var removed = 0;
    final removalFailures = <String>[];
    for (final folder in toRemove) {
      try {
        _localManager.deleteComicWithTarget(folder, item.target, item.type);
        if (_localManager.comicExists(folder, item.target, item.type.key)) {
          removalFailures.add(folder);
        }
      } catch (_) {
        removalFailures.add(folder);
      }
      removed++;
    }
    assert(removed == toRemove.length, '移除计数应与待移除夹数一致');
    if (removalFailures.isNotEmpty) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _localError = '部分收藏取消失败，请重试';
      });
      return;
    }

    final created = <String>[];
    final failures = <String, String>{};
    for (final folder in toAdd.where(_localPending.contains)) {
      try {
        if (!_localManager.folderNames.contains(folder)) {
          _localManager.createFolder(folder);
          created.add(folder);
        }
      } catch (e) {
        failures[folder] = '无法创建「$folder」：$e';
      }
    }

    final result = await _localManager.addComicsToFolders(
      toAdd,
      [item],
      createdFolders: created,
      folderCreationFailures: failures,
    );
    if (!mounted) return;
    Navigator.of(context).pop(
      PlatformFavoritePanelResult(
        PlatformFavoriteAction.localSubmitted,
        localResult: result,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final onLocalTab = _tab.index == 1;
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 8),
          TabBar(
            controller: _tab,
            onTap: (_) => setState(() {}),
            tabs: const [Tab(text: '网络'), Tab(text: '本地')],
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _buildPlatformTab(scrollController),
                _buildLocalTab(scrollController),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: SizedBox(
              height: 60,
              child: Center(
                child: onLocalTab
                    ? _buildLocalButton()
                    : _buildPlatformButton(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlatformButton() {
    if (!widget.canFavorite) {
      return const FilledButton(onPressed: null, child: Text('收藏'));
    }
    // 文案与 `_platformTarget` 同源：
    // - 选了某个夹 → 「收藏」（已收藏时即"收藏到该夹"，也就是换夹）；
    // - 没选夹但已收藏 → 「取消收藏」，点它即取消（不必先去取消勾选）；
    // - 没选夹且未收藏 → 禁用的「收藏」。
    final isDeselect = _selectedFolderId == null;
    final label = (isDeselect && widget.isFavorite) ? '取消收藏' : '收藏';
    final enabled = !_busy && _platformHasChange;
    return FilledButton(
      onPressed: enabled ? _submitPlatform : null,
      child: Text(label),
    );
  }

  Widget _buildLocalButton() {
    // 面板当前只服务单本收藏，文案固定为「完成」（与本地收藏对话框一致）。
    return FilledButton(
      onPressed: _busy ? null : _submitLocal,
      child: const Text('完成'),
    );
  }

  Widget _buildPlatformTab(ScrollController controller) {
    if (!widget.canFavorite) {
      return ListView(
        controller: controller,
        children: [
          const SizedBox(height: 24),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text('登录 ${widget.sourceTitle} 后可使用平台收藏'),
            enabled: false,
          ),
        ],
      );
    }
    if (_loadingFolders) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_foldersError != null) {
      return Center(child: Text(_foldersError!));
    }
    final folders = _folders ?? const <FavoriteFolderOption>[];
    if (folders.isEmpty) {
      return const Center(child: Text('暂无平台收藏夹'));
    }
    return ListView(
      controller: controller,
      children: [
        for (final folder in folders)
          _buildFolderRow(
            key: ValueKey('folder-${folder.id}'),
            name: folder.name,
            selected: _selectedFolderId == folder.id,
            onTap: () => _selectFolder(folder.id),
          ),
      ],
    );
  }

  Widget _buildFolderRow({
    required Key key,
    required String name,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      key: key,
      onTap: _busy ? null : onTap,
      child: SizedBox(
        height: 48,
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Icon(
                selected ? Icons.folder : Icons.folder_outlined,
                size: 28,
                color: Theme.of(context).colorScheme.secondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(name, overflow: TextOverflow.ellipsis),
              ),
              if (selected) const AnimatedCheckIcon(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLocalTab(ScrollController controller) {
    final folders = {..._localManager.folderNames, ..._localPending}.toList();
    final media = MediaQuery.of(context);
    return ListView(
      controller: controller,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            '勾选收藏夹后点「完成」生效',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (folders.isEmpty) const Text('暂无收藏夹，请先新建'),
        for (final folder in folders)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(folder),
            subtitle:
                _localPending.contains(folder) ? const Text('待新建') : null,
            value: _localSelected.contains(folder),
            onChanged: _busy
                ? null
                : (value) => _toggleLocal(folder, value == true),
          ),
        TextField(
          controller: _localName,
          enabled: !_busy,
          decoration: const InputDecoration(labelText: '新收藏夹名称'),
        ),
        TextButton.icon(
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('新建并选中'),
          onPressed: _busy ? null : _createLocal,
        ),
        if (_localError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _localError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        // 给底部按钮留出空间，避免最后一项被盖住。
        SizedBox(height: math.max(0, media.padding.bottom)),
      ],
    );
  }
}
