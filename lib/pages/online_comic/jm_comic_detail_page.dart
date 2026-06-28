import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/pages/online_comic/jm_comments_page.dart';
import 'package:picakeep/pages/online_search/online_search_result_page.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart';

class JmComicDetailPage extends StatefulWidget {
  const JmComicDetailPage({super.key, required this.comic});

  final BaseComic comic;

  @override
  State<JmComicDetailPage> createState() => _JmComicDetailPageState();
}

class _JmComicDetailPageState extends State<JmComicDetailPage> {
  late Future<JmComicInfo> _future = _load();
  bool _favoriteBusy = false;
  bool _downloadBusy = false;
  bool? _isFavourite; // 本地覆盖，toggle 后立即反映

  Future<JmComicInfo> _load() async {
    final res = await JmNetwork().getComicInfo(widget.comic.id);
    if (res.error) throw res.errorMessageWithoutNull;
    return res.data;
  }

  Future<void> _toggleFavorite(JmComicInfo info) async {
    if (_favoriteBusy) return;
    final current = _isFavourite ?? info.isFavourite;

    if (current) {
      // 取消收藏
      setState(() => _favoriteBusy = true);
      final res = await JmNetwork().setFavorite(info.id, add: false);
      if (!mounted) return;
      setState(() { _favoriteBusy = false; if (!res.error) _isFavourite = false; });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(res.error ? res.errorMessageWithoutNull : '已取消收藏')),
      );
      return;
    }

    // 加收藏：先获取收藏夹列表
    setState(() => _favoriteBusy = true);
    final foldersRes = await JmNetwork().getFolders();
    if (!mounted) return;
    setState(() => _favoriteBusy = false);

    String? folderId;
    if (foldersRes.data.isNotEmpty) {
      folderId = await showDialog<String>(
        context: context,
        builder: (_) => _FolderSelectDialog(folders: foldersRes.data),
      );
      if (!mounted || folderId == null) return; // 用户取消
    } else {
      folderId = ''; // 默认夹
    }

    setState(() => _favoriteBusy = true);
    final res = await JmNetwork().setFavorite(info.id, add: true);
    if (!mounted) return;
    if (!res.error && folderId.isNotEmpty) {
      await JmNetwork().moveFavoriteToFolder(info.id, folderId);
    }
    if (!mounted) return;
    setState(() { _favoriteBusy = false; if (!res.error) _isFavourite = true; });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(res.error ? res.errorMessageWithoutNull : '已收藏')),
    );
  }

  Future<void> _read(JmComicInfo info, {int ep = 1, bool forceOnline = false}) async {
    await History.ensureForLocalRead(
      target: info.id,
      type: HistoryType.jmComic,
      title: info.title,
      subtitle: info.author,
      cover: info.coverUrl,
      ep: ep,
    );
    if (!mounted) return;
    Navigator.of(context).push(AppPageRoute(
      builder: (_) => ComicReadingPage(
          JmReadingData(info: info, forceOnline: forceOnline), 1, ep),
    ));
  }

  Future<void> _download(JmComicInfo info) async {
    if (_downloadBusy) return;
    setState(() => _downloadBusy = true);
    final res = await OnlineDownloadManager.instance.enqueueJm(info);
    if (!mounted) return;
    setState(() => _downloadBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(res.error ? res.errorMessageWithoutNull : '已加入下载队列')),
    );
  }

  void _openComments(JmComicInfo info) {
    Navigator.of(context).push(AppPageRoute(
      builder: (_) => JmCommentsPage(
        comicId: info.id,
        totalComments: info.comments,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<JmComicInfo>(
      future: _future,
      builder: (context, snapshot) {
        final info = snapshot.data;
        return Scaffold(
          appBar: AppBar(title: Text(info?.title ?? widget.comic.title)),
          body: switch (snapshot.connectionState) {
            ConnectionState.done when snapshot.hasError => _ErrorView(
                error: snapshot.error.toString(),
                onRetry: () => setState(() => _future = _load()),
              ),
            ConnectionState.done when info != null => _JmDetailView(
                info: info,
                isFavourite: _isFavourite ?? info.isFavourite,
                favoriteBusy: _favoriteBusy,
                downloadBusy: _downloadBusy,
                onRead: (ep) => _read(info, ep: ep),
                onReadOnline: (ep) => _read(info, ep: ep, forceOnline: true),
                onDownload: () => _download(info),
                onFavorite: () => _toggleFavorite(info),
                onComment: () => _openComments(info),
              ),
            _ => const Center(child: CircularProgressIndicator()),
          },
        );
      },
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, size: 48),
          const SizedBox(height: 12),
          Text(error, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ]),
      ),
    );
  }
}

class _JmDetailView extends StatelessWidget {
  const _JmDetailView({
    required this.info,
    required this.isFavourite,
    required this.favoriteBusy,
    required this.downloadBusy,
    required this.onRead,
    required this.onReadOnline,
    required this.onDownload,
    required this.onFavorite,
    required this.onComment,
  });

  final JmComicInfo info;
  final bool isFavourite;
  final bool favoriteBusy;
  final bool downloadBusy;
  final ValueChanged<int> onRead;
  final ValueChanged<int> onReadOnline;
  final VoidCallback onDownload;
  final VoidCallback onFavorite;
  final VoidCallback onComment;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return ListView(padding: const EdgeInsets.all(16), children: [
      // ── 封面 + 信息区 ──
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(
            info.coverUrl,
            width: 120,
            height: 168,
            fit: BoxFit.cover,
            headers: getJmImgHeaders(),
            errorBuilder: (_, __, ___) => Container(
              width: 120,
              height: 168,
              color: colorScheme.surfaceContainerHighest,
              child: const Icon(Icons.broken_image_outlined),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(info.title, style: textTheme.titleLarge),
            const SizedBox(height: 8),
            // ID
            Row(children: [
              const Icon(Icons.tag, size: 16),
              const SizedBox(width: 4),
              SelectableText(
                'ID: ${info.id}',
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ]),
            const SizedBox(height: 6),
            // 作者
            Row(children: [
              const Icon(Icons.person_outline, size: 16),
              const SizedBox(width: 4),
              Expanded(
                child: Text(info.author,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium),
              ),
            ]),
            const SizedBox(height: 6),
            // 章节数
            Row(children: [
              const Icon(Icons.menu_book_outlined, size: 16),
              const SizedBox(width: 4),
              Text(
                '${info.series.length} 章',
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ]),
            const SizedBox(height: 6),
            // 统计：观看数、点赞、评论
            Row(children: [
              const Icon(Icons.visibility_outlined, size: 16),
              const SizedBox(width: 4),
              Text(
                _formatNumber(info.views),
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.thumb_up_outlined, size: 16),
              const SizedBox(width: 4),
              Text(
                _formatNumber(info.likes),
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(width: 12),
              const Icon(Icons.comment_outlined, size: 16),
              const SizedBox(width: 4),
              Text(
                _formatNumber(info.comments),
                style: textTheme.bodySmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ]),
          ]),
        ),
      ]),

      const SizedBox(height: 20),

      // ── 动作按钮区 ──
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _ActionButton(
          icon: Icons.menu_book_outlined,
          label: '阅读',
          onTap: () => onRead(1),
        ),
        _ActionButton(
          icon: Icons.download_outlined,
          label: '下载',
          busy: downloadBusy,
          onTap: onDownload,
        ),
        _ActionButton(
          icon: isFavourite ? Icons.favorite : Icons.favorite_outline,
          label: '收藏',
          busy: favoriteBusy,
          onTap: onFavorite,
        ),
        _ActionButton(
          icon: Icons.comment_outlined,
          label: '评论',
          badge: info.comments > 0 ? _formatNumber(info.comments) : null,
          onTap: onComment,
        ),
      ]),

      const SizedBox(height: 20),
      const Divider(),

      // ── 信息区（参考本地详情页样式）──
      const SizedBox(height: 12),
      Text('信息', style: textTheme.titleSmall),
      const SizedBox(height: 8),
      _InfoRow('ID', ['JM${info.id}']),
      if (info.authors.isNotEmpty) _InfoRow('作者', info.authors),
      if (info.works.isNotEmpty) _InfoRow('作品', info.works),
      if (info.actors.isNotEmpty) _InfoRow('演员', info.actors.take(30).toList()),
      if (info.tags.isNotEmpty) _InfoRow('标签', info.tags.take(30).toList()),

      const SizedBox(height: 16),
      const Divider(),

      // ── 简介区 ──
      const SizedBox(height: 12),
      Text('简介', style: textTheme.titleSmall),
      const SizedBox(height: 8),
      Text(
        info.description.isEmpty ? '暂无简介' : info.description,
        style: textTheme.bodyMedium,
      ),

      const SizedBox(height: 16),
      const Divider(),

      // ── 章节区 ──
      const SizedBox(height: 12),
      Text('章节 (${info.series.length})', style: textTheme.titleSmall),
      Text(
        '点击优先读本地下载，长按强制在线阅读',
        style: textTheme.bodySmall
            ?.copyWith(color: colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 4),
      for (var i = 1; i <= info.series.length; i++)
        ListTile(
          dense: true,
          leading: Text(
            '$i',
            style: textTheme.bodySmall
                ?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
          title: Text(
            i <= info.epNames.length ? info.epNames[i - 1] : '第$i章',
          ),
          trailing: const Icon(Icons.play_circle_outline, size: 20),
          onTap: () => onRead(i),
          onLongPress: () => onReadOnline(i),
        ),
    ]);
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
    this.badge,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool busy;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 80,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : (badge != null
                  ? Badge(
                      label: Text(badge!),
                      child: Icon(icon, size: 22),
                    )
                  : Icon(icon, size: 22)),
          const SizedBox(height: 6),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ]),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip(
      {required this.label, required this.color, required this.textColor});
  final String label;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: textColor),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.values);
  final String label;
  final List<String> values;

  void _onLongPressAt(BuildContext context, String value, Offset pos) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final local = overlay.globalToLocal(pos);
    final size = overlay.size;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(local.dx, local.dy, size.width - local.dx, size.height - local.dy),
      items: [
        const PopupMenuItem(value: 'copy', child: Text('复制')),
        if (label != 'ID') const PopupMenuItem(value: 'search', child: Text('搜索')),
      ],
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: value));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
          );
        }
      case 'search':
        final source = ComicSource.find('jm');
        if (source == null || !context.mounted) return;
        Navigator.of(context).push(AppPageRoute(
          builder: (_) => OnlineSearchResultPage(source: source, keyword: value, option: ''),
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          _InfoChip(label: label, color: cs.surfaceContainerHighest, textColor: cs.onSurface),
          for (final v in values)
            GestureDetector(
              onLongPressStart: (d) => _onLongPressAt(context, v, d.globalPosition),
              child: _InfoChip(label: v, color: cs.secondaryContainer, textColor: cs.onSecondaryContainer),
            ),
        ],
      ),
    );
  }
}

/// 格式化数字（万位显示，如 12345 → 1.2万）
String _formatNumber(int n) {
  if (n < 10000) return n.toString();
  return '${(n / 10000).toStringAsFixed(1)}万';
}

class _FolderSelectDialog extends StatelessWidget {
  const _FolderSelectDialog({required this.folders});
  final List<JmFolder> folders;

  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      title: const Text('选择收藏夹'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(''),
          child: const Text('默认收藏夹'),
        ),
        for (final f in folders)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(f.id),
            child: Text(f.name),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(null),
          child: Text('取消', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      ],
    );
  }
}
