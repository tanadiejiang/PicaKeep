import 'package:flutter/material.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/download.dart';
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
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final shouldShowTwoPanel = width > 600;
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                const SizedBox(height: 12),
                buildHistory(context),
                if (shouldShowTwoPanel)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            const SizedBox(height: 12),
                            buildDownload(context),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          children: [
                            const SizedBox(height: 12),
                            buildImageFavorite(context),
                            const SizedBox(height: 12),
                            buildTools(context),
                          ],
                        ),
                      ),
                    ],
                  )
                else ...[
                  const SizedBox(height: 12),
                  buildDownload(context),
                  const SizedBox(height: 12),
                  buildImageFavorite(context),
                  const SizedBox(height: 12),
                  buildTools(context),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget buildHistory(BuildContext context) {
    List<History> history;
    try {
      history = HistoryManager().getRecent();
    } catch (_) {
      history = [];
    }

    int count;
    try {
      count = HistoryManager().count();
    } catch (_) {
      count = 0;
    }

    return _MePageCard(
      icon: const Icon(Icons.history),
      title: "\u5386\u53F2\u8BB0\u5F55($count)",
      description: history.isEmpty
          ? "\u6682\u65E0\u5386\u53F2\u8BB0\u5F55"
          : "\u6700\u8FD1\u6D4F\u89C8\u7684\u6F2B\u753B",
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const HistoryPage()),
        );
      },
      child: history.isEmpty
          ? null
          : SizedBox(
              height: 128,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: history.length,
                itemBuilder: (context, index) {
                  final item = history[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Column(
                      children: [
                        Container(
                          width: 80,
                          height: 100,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            color: Theme.of(context)
                                .colorScheme
                                .secondaryContainer,
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Center(
                            child: Icon(
                              Icons.auto_stories,
                              size: 32,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSecondaryContainer,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          width: 80,
                          child: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
    );
  }

  Widget buildDownload(BuildContext context) {
    int count;
    try {
      count = DownloadManager().total;
    } catch (_) {
      count = 0;
    }

    return _MePageCard(
      icon: const Icon(Icons.download_for_offline),
      title: "\u5DF2\u4E0B\u8F7D($count)",
      description: "\u5171 $count \u90E8\u6F2B\u753B",
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const DownloadPage()),
        );
      },
    );
  }

  Widget buildImageFavorite(BuildContext context) {
    return _MePageCard(
      icon: const Icon(Icons.image),
      title: "\u56FE\u7247\u6536\u85CF",
      description: "0 \u6761\u56FE\u7247\u6536\u85CF",
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ImageFavoritesPage()),
        );
      },
    );
  }

  Widget buildTools(BuildContext context) {
    return _MePageCard(
      icon: const Icon(Icons.build_circle),
      title: "\u5DE5\u5177",
      description: "\u672C\u5730\u5DE5\u5177",
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ToolsPage()),
        );
      },
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
            if (child != null) child!,
          ],
        ),
      ),
    );
  }
}
