import 'package:flutter/material.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';

class LocalComicDetailPage extends StatelessWidget {
  final DownloadedItem comic;

  const LocalComicDetailPage({super.key, required this.comic});

  String get _sourceLabel {
    switch (comic.type) {
      case DownloadType.picacg:
        return 'Picacg';
      case DownloadType.ehentai:
        return 'E-Hentai';
      case DownloadType.jm:
        return '禁漫';
      case DownloadType.hitomi:
        return 'Hitomi';
      case DownloadType.htmanga:
        return '绅士漫画';
      case DownloadType.nhentai:
        return 'NHentai';
      case DownloadType.copyManga:
        return '拷贝漫画';
      case DownloadType.komiic:
        return 'Komiic';
      default:
        return '本地';
    }
  }

  Color _sourceColor(BuildContext context) {
    switch (comic.type) {
      case DownloadType.jm:
        return Colors.orange;
      case DownloadType.picacg:
        return Colors.pink;
      case DownloadType.ehentai:
        return Colors.blue;
      case DownloadType.nhentai:
        return Colors.red;
      case DownloadType.hitomi:
        return Colors.purple;
      default:
        return Theme.of(context).colorScheme.primary;
    }
  }

  String _formatSize(double? size) {
    if (size == null) return '未知';
    if (size > 1024) return '${(size / 1024).toStringAsFixed(1)} GB';
    return '${size.toStringAsFixed(1)} MB';
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildCover() {
    try {
      final f = DownloadManager().getCover(comic.id);
      if (f.existsSync())
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(f,
              fit: BoxFit.cover,
              width: 160,
              height: 220,
              errorBuilder: (_, __, ___) => _placeholderCover()),
        );
    } catch (_) {}
    return _placeholderCover();
  }

  Widget _placeholderCover() {
    return Container(
        width: 160,
        height: 220,
        decoration: BoxDecoration(
            color: Colors.grey[300], borderRadius: BorderRadius.circular(12)),
        child: const Icon(Icons.image_not_supported, size: 48));
  }

  void _onRead({int? ep}) {
    // Placeholder - navigate to reader
  }

  void _onDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
          title: const Text('确认删除'),
          content: Text('确定要删除"${comic.name}"吗？'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除')),
          ]),
    );
    if (confirmed == true) {
      await DownloadManager().delete([comic.id]);
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(comic.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: '删除下载',
                onPressed: () => _onDelete(context)),
          ]),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Header: cover + info
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _buildCover(),
            const SizedBox(width: 16),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(comic.name,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis),
                  if (comic.subTitle.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(comic.subTitle,
                        style: TextStyle(
                            fontSize: 15,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant))
                  ],
                  const SizedBox(height: 10),
                  Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                          color: _sourceColor(context).withAlpha(30),
                          borderRadius: BorderRadius.circular(12)),
                      child: Text(_sourceLabel,
                          style: TextStyle(
                              color: _sourceColor(context),
                              fontWeight: FontWeight.w600))),
                  const SizedBox(height: 8),
                  Text(_formatSize(comic.comicSize),
                      style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(context).colorScheme.outline)),
                  Text(_formatTime(comic.time),
                      style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).colorScheme.outline)),
                ])),
          ]),

          const SizedBox(height: 20),

          // Action buttons
          Row(children: [
            Expanded(
                child: FilledButton.icon(
                    onPressed: () => _onRead(),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('从头开始'))),
          ]),

          const SizedBox(height: 20),

          // Tags
          if (comic.tags.isNotEmpty) ...[
            const Text('标签',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
                spacing: 8,
                runSpacing: 6,
                children: comic.tags
                    .map((t) => Chip(
                          label: Text(t, style: const TextStyle(fontSize: 12)),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ))
                    .toList()),
          ],

          const SizedBox(height: 20),

          // Chapters
          const Text('章节',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                childAspectRatio: 2.5,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8),
            itemCount: comic.eps.length,
            itemBuilder: (ctx, i) => ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: comic.downloadedEps.contains(i)
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
              onPressed:
                  comic.downloadedEps.contains(i) ? () => _onRead(ep: i) : null,
              child: Text(comic.eps[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
            ),
          ),

          const SizedBox(height: 40),
        ]),
      ),
    );
  }
}
