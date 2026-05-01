import 'dart:io';
import 'package:flutter/material.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/tools/translations.dart';
import 'history_page.dart';
import 'image_favorites.dart';
import 'tools.dart';
import 'download_page.dart';

class MePage extends StatelessWidget {
  const MePage({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: LayoutBuilder(
        builder: (context, constrains) {
          final width = constrains.maxWidth;
          bool shouldShowTwoPanel = width > 600;
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                const SizedBox(height: 12),
                _buildHistoryCard(context),
                if (shouldShowTwoPanel)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            const SizedBox(height: 12),
                            _buildDownloadCard(context),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          children: [
                            const SizedBox(height: 12),
                            _buildImageFavoriteCard(context),
                            const SizedBox(height: 12),
                            _buildToolsCard(context),
                          ],
                        ),
                      ),
                    ],
                  )
                else ...[
                  const SizedBox(height: 12),
                  _buildDownloadCard(context),
                  const SizedBox(height: 12),
                  _buildImageFavoriteCard(context),
                  const SizedBox(height: 12),
                  _buildToolsCard(context),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildHistoryCard(BuildContext context) {
    List<History> history = [];
    try {
      history = HistoryManager().getRecent();
    } catch (e) {
      print('[PicaKeep] MePage: HistoryManager.getRecent() failed: $e');
    }
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const HistoryPage()),
      ),
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(12),
      child: Card.outlined(
        margin: EdgeInsets.zero,
        color: Colors.transparent,
        child: Container(
          margin: EdgeInsets.zero,
          width: double.infinity,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.history),
                title: Text("历史记录".tl),
                trailing: const Icon(Icons.chevron_right),
                mouseCursor: SystemMouseCursors.click,
              ),
              SizedBox(
                height: 128,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: history.length,
                  itemBuilder: (context, index) {
                    return InkWell(
                      onTap: () => _openComicFromHistory(context, history[index]),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        width: 96,
                        height: 128,
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: Theme.of(context).colorScheme.secondaryContainer,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: _buildCoverImage(context, history[index]),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCoverImage(BuildContext context, History item) {
    final cover = item.cover;
    if (cover.isEmpty) {
      return Center(
        child: Icon(
          Icons.auto_stories,
          size: 32,
          color: Theme.of(context).colorScheme.onSecondaryContainer,
        ),
      );
    }
    if (cover.startsWith('/') || cover.contains(':\\')) {
      return Image.file(
        File(cover),
        width: 96,
        height: 128,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stackTrace) {
          return Center(
            child: Icon(
              Icons.auto_stories,
              size: 32,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
          );
        },
      );
    }
    return Center(
      child: Icon(
        Icons.auto_stories,
        size: 32,
        color: Theme.of(context).colorScheme.onSecondaryContainer,
      ),
    );
  }

  void _openComicFromHistory(BuildContext context, History history) async {
    try {
      var comic = await DownloadManager().getComicOrNull(history.target);
      if (comic != null) {
        if (!context.mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => comic.createReadingPage()),
        );
      }
    } catch (e) {
      print('[PicaKeep] MePage: _openComicFromHistory failed: $e');
    }
  }

  Widget _buildDownloadCard(BuildContext context) {
    int total = 0;
    try {
      total = DownloadManager().total;
    } catch (e) {
      print('[PicaKeep] MePage: DownloadManager().total failed: $e');
    }
    return _MePageCard(
      icon: const Icon(Icons.download_for_offline),
      title: "已下载".tl,
      description: "共 @a 部漫画".tlParams({"a": total.toString()}),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const DownloadPage()),
      ),
    );
  }

  Widget _buildImageFavoriteCard(BuildContext context) {
    return _MePageCard(
      icon: const Icon(Icons.image),
      title: "图片收藏".tl,
      description: "@a 条图片收藏".tlParams({"a": "0"}),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ImageFavoritesPage()),
      ),
    );
  }

  Widget _buildToolsCard(BuildContext context) {
    return _MePageCard(
      icon: const Icon(Icons.build_circle),
      title: "工具".tl,
      description: "本地工具".tl,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ToolsPage()),
      ),
    );
  }
}

class _MePageCard extends StatelessWidget {
  const _MePageCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
    this.child,
  });

  final Widget icon;
  final String title;
  final String description;
  final VoidCallback onTap;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Card.outlined(
        margin: EdgeInsets.zero,
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: icon,
              title: Text(title),
              trailing: const Icon(Icons.chevron_right),
              mouseCursor: SystemMouseCursors.click,
            ),
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 16, top: 8),
              child: Text(description),
            ),
            if (child != null) child!,
          ],
        ),
      ),
    );
  }
}
