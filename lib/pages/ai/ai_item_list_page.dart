import 'dart:io';
import 'package:flutter/material.dart';
import '../../foundation/ai/ai_result_item.dart';
import '../../foundation/remote_library_data_source.dart';
import '../../foundation/download_model.dart';
import '../../components/comic_tile.dart';
import '../../components/layout.dart';
import '../download_page.dart';

class AiItemListPage extends StatelessWidget {
  final String title;
  final List<AiResultItem> items;

  const AiItemListPage({
    super.key,
    required this.title,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('$title (${items.length}条)'),
      ),
      body: items.isEmpty
          ? const Center(
              child: Text('暂无结果'),
            )
          : CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(4),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithComics(),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final item = items[index];
                        return Padding(
                          padding: const EdgeInsets.all(2),
                          child: DownloadedComicTile(
                            name: item.title,
                            author: item.author,
                            imagePath: File(''),
                            imageProvider: item.coverUrl.isNotEmpty
                                ? NetworkImage(item.coverUrl)
                                : null,
                            type: item.source,
                            tag: item.tags,
                            size: item.availability['remoteDownloaded'] == true
                                ? '远程已下载'
                                : '',
                            onTap: () => _showItemDetail(context, item),
                            onLongTap: () {},
                            onSecondaryTap: (_) {},
                          ),
                        );
                      },
                      childCount: items.length,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _showItemDetail(BuildContext context, AiResultItem item) async {
    DownloadedItem? realItem;
    try {
      realItem = await const RemoteLibraryDataSource()
          .findByCandidates([item.id, item.title]);
    } catch (_) {
      // 查找失败，降级到轻量底栏
    }

    if (!context.mounted) return;

    if (realItem != null) {
      final sheetController = DraggableScrollableController();
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) {
          return DraggableScrollableSheet(
            controller: sheetController,
            initialChildSize: 0.6,
            minChildSize: 0.3,
            maxChildSize: 0.9,
            builder: (context, scrollController) {
              return DownloadedComicInfoView(
                realItem!,
                null,
                scrollController: scrollController,
                sheetController: sheetController,
                sheetMaxSize: 0.9,
              );
            },
          );
        },
      );
    } else {
      // fallback：轻量底栏
      showModalBottomSheet(
        context: context,
        builder: (context) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 封面图
                if (item.coverUrl.isNotEmpty)
                  Center(
                    child: Image(
                      image: NetworkImage(item.coverUrl),
                      height: 120,
                      errorBuilder: (context, error, stackTrace) {
                        return Container(
                          height: 120,
                          width: 80,
                          color: Colors.grey[300],
                          child: const Icon(Icons.image_not_supported),
                        );
                      },
                    ),
                  )
                else
                  Center(
                    child: Container(
                      height: 120,
                      width: 80,
                      color: Colors.grey[300],
                      child: const Icon(Icons.image),
                    ),
                  ),
                const SizedBox(height: 16),

                // 标题
                Text(
                  item.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),

                // 作者
                Text(
                  item.author,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),

                // 标签
                if (item.tags.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: item.tags
                        .take(8)
                        .map((tag) => Chip(
                              label: Text(tag),
                              visualDensity: VisualDensity.compact,
                            ))
                        .toList(),
                  ),
                const SizedBox(height: 12),

                // availability 状态
                _buildAvailabilityStatus(context, item.availability),
              ],
            ),
          );
        },
      );
    }
  }

  Widget _buildAvailabilityStatus(
      BuildContext context, Map<String, dynamic> availability) {
    final statusList = <String>[];

    if (availability['remoteDownloaded'] == true) {
      statusList.add('远程已下载');
    }
    if (availability['localDownloaded'] == true) {
      statusList.add('本地已下载');
    }
    if (availability['favorited'] == true) {
      statusList.add('已收藏');
    }

    if (statusList.isEmpty) {
      return const SizedBox.shrink();
    }

    return Text(
      statusList.join(' · '),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.primary,
          ),
    );
  }
}
