import 'dart:io';
import 'package:flutter/material.dart';
import '../../foundation/ai/ai_result_item.dart';
import '../../foundation/ai/ai_sources.dart';
import '../../foundation/ai/ai_download_queue.dart';
import '../../foundation/app_page_route.dart';
import '../../foundation/remote_library_data_source.dart';
import '../../foundation/download_model.dart';
import '../../components/comic_tile.dart';
import '../../components/layout.dart';
import '../download_page.dart';
import '../online_comic/picacg_comic_page_v2.dart';
import '../online_comic/jm_comic_page_v2.dart';
import '../online_comic/nhentai_comic_page_v2.dart';
import '../online_comic/eh_comic_page_v2.dart';
import 'ai_download_list_page.dart';

class AiItemListPage extends StatefulWidget {
  final String title;
  final List<AiResultItem> items;

  const AiItemListPage({
    super.key,
    required this.title,
    required this.items,
  });

  @override
  State<AiItemListPage> createState() => _AiItemListPageState();
}

class _AiItemListPageState extends State<AiItemListPage> {
  bool _selecting = false;
  late List<bool> _selected;
  int _selectedNum = 0;

  @override
  void initState() {
    super.initState();
    _selected = List.filled(widget.items.length, false);
  }

  void _onTap(int index) {
    if (_selecting) {
      setState(() {
        _selected[index] = !_selected[index];
        _selectedNum += _selected[index] ? 1 : -1;
        if (_selectedNum == 0) {
          _selecting = false;
        }
      });
    } else {
      _openDetail(widget.items[index]);
    }
  }

  void _onLongTap(int index) {
    setState(() {
      _selecting = true;
      _selected[index] = true;
      _selectedNum = 1;
    });
  }

  void _exitSelection() {
    setState(() {
      _selected = List.filled(widget.items.length, false);
      _selectedNum = 0;
      _selecting = false;
    });
  }

  void _openDetail(AiResultItem item) {
    Widget page;
    switch (item.source) {
      case aiSourcePicacg:
        page = PicacgComicPageV2(item.id);
      case aiSourceJm:
        page = JmComicPageV2(item.id);
      case aiSourceNhentai:
        page = NhentaiComicPageV2(item.id);
      case aiSourceEhentai:
        page = EhentaiComicPageV2(item.id);
      default:
        _showFallbackSheet(item);
        return;
    }
    Navigator.of(context).push(AppPageRoute(builder: (_) => page));
  }

  Future<void> _showFallbackSheet(AiResultItem item) async {
    DownloadedItem? realItem;
    try {
      realItem = await const RemoteLibraryDataSource()
          .findByCandidates([item.id, item.title]);
    } catch (_) {
      // 查找失败，降级到轻量底栏
    }

    if (!mounted) return;

    if (realItem != null) {
      final sheetController = DraggableScrollableController();
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: false,
        useSafeArea: false,
        backgroundColor: Colors.transparent,
        builder: (context) {
          return DraggableScrollableSheet(
            controller: sheetController,
            initialChildSize: 0.6,
            minChildSize: 0.3,
            maxChildSize: 0.9,
            expand: false,
            builder: (context, scrollController) {
              return Material(
                color: Theme.of(context).colorScheme.surface,
                surfaceTintColor: Theme.of(context).colorScheme.surfaceTint,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                ),
                clipBehavior: Clip.antiAlias,
                child: DownloadedComicInfoView(
                  realItem!,
                  null,
                  scrollController: scrollController,
                  sheetController: sheetController,
                  sheetMaxSize: 0.9,
                ),
              );
            },
          );
        },
      ).whenComplete(sheetController.dispose);
    } else {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: false,
        useSafeArea: false,
        backgroundColor: Colors.transparent,
        builder: (context) {
          return Material(
            color: Theme.of(context).colorScheme.surface,
            surfaceTintColor: Theme.of(context).colorScheme.surfaceTint,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
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
            ),
          );
        },
      );
    }
  }

  Future<void> _addToQueue() async {
    final toQueue = <AiResultItem>[];
    for (var i = 0; i < widget.items.length; i++) {
      if (_selected[i]) {
        toQueue.add(widget.items[i]);
      }
    }
    if (toQueue.isEmpty) return;

    final skipped = await AiDownloadQueue.instance.addItems(toQueue);

    if (!mounted) return;
    final addedCount = toQueue.length - skipped;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          skipped > 0
              ? '已加入队列 $addedCount 项，$skipped 项因来源信息缺失或重复被跳过'
              : '已加入队列 $addedCount 项',
        ),
      ),
    );

    _exitSelection();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _selecting
          ? AppBar(
              backgroundColor:
                  Theme.of(context).colorScheme.primaryContainer,
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelection,
              ),
              title: Text('已选 $_selectedNum 项'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.download),
                  tooltip: '加入下载队列',
                  onPressed: _selectedNum > 0 ? _addToQueue : null,
                ),
              ],
            )
          : AppBar(
              title: Text('${widget.title} (${widget.items.length}条)'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.queue),
                  tooltip: '下载队列',
                  onPressed: () {
                    Navigator.of(context).push(
                      AppPageRoute(
                          builder: (_) => const AiDownloadListPage()),
                    );
                  },
                ),
              ],
            ),
      body: widget.items.isEmpty
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
                        final item = widget.items[index];
                        return Padding(
                          padding: const EdgeInsets.all(2),
                          child: Stack(
                            children: [
                              DownloadedComicTile(
                                name: item.title,
                                author: item.author,
                                imagePath: File(''),
                                imageProvider: item.coverUrl.isNotEmpty
                                    ? NetworkImage(item.coverUrl)
                                    : null,
                                type: item.source,
                                tag: item.tags,
                                size: item.availability['remoteDownloaded'] ==
                                        true
                                    ? '远程已下载'
                                    : '',
                                onTap: () => _onTap(index),
                                onLongTap: () => _onLongTap(index),
                                onSecondaryTap: (_) {},
                              ),
                              if (_selecting)
                                IgnorePointer(
                                  child: AnimatedContainer(
                                    duration:
                                        const Duration(milliseconds: 150),
                                    color: _selected[index]
                                        ? Theme.of(context)
                                            .colorScheme
                                            .primary
                                            .withValues(alpha: 0.3)
                                        : Colors.transparent,
                                    child: _selected[index]
                                        ? const Align(
                                            alignment: Alignment.topRight,
                                            child: Padding(
                                              padding: EdgeInsets.all(6),
                                              child: Icon(
                                                Icons.check_circle,
                                                color: Colors.white,
                                              ),
                                            ),
                                          )
                                        : null,
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                      childCount: widget.items.length,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
