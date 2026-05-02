import 'dart:io';

import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/image_favorites.dart';
import 'package:picakeep/pages/reader/comic_reading_page.dart' show ComicReadingPage, LocalReadingData;
import 'package:picakeep/tools/translations.dart';

class ImageFavoritesPage extends StatefulWidget {
  const ImageFavoritesPage({super.key});

  @override
  State<ImageFavoritesPage> createState() => _ImageFavoritesPageState();
}

class _ImageFavoritesPageState extends State<ImageFavoritesPage> {
  @override
  Widget build(BuildContext context) {
    return StateBuilder(
      tag: "image_favorites_page",
      init: SimpleController(),
      builder: (controller) {
        final images = ImageFavoriteManager.getAll();

        if (images.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: Text('图片收藏'.tl)),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.image_not_supported_outlined,
                      size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(
                    '暂无图片收藏'.tl,
                    style: const TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(title: Text('图片收藏'.tl)),
          body: GridView.builder(
            padding: const EdgeInsets.all(4),
            gridDelegate: SliverGridDelegateWithComics(true, appdata.settings[74]),
            itemCount: images.length,
            itemBuilder: (context, index) {
              return _FavoriteImageTile(images[index], () {
                ImageFavoriteManager.delete(images[index]);
                controller.update();
              });
            },
          ),
        );
      },
    );
  }
}

class _FavoriteImageTile extends StatelessWidget {
  const _FavoriteImageTile(this.image, this.onDelete);

  final ImageFavorite image;
  final VoidCallback onDelete;

  void _onTap(BuildContext context) {
    // Use stored info from otherInfo (set by tool_bar.dart when favoriting)
    final sourceKey = (image.otherInfo['sourceKey'] as String?) ?? '';
    final epsList = (image.otherInfo['eps'] as List?)?.cast<String>() ?? [];
    final eps = <String, String>{};
    for (var i = 0; i < epsList.length; i++) {
      eps[(i + 1).toString()] = epsList[i];
    }

    final data = LocalReadingData(
      title: image.title,
      id: image.id,
      downloadId: image.otherInfo['downloadId'] as String? ?? image.id,
      sourceKey: sourceKey,
      hasEp: eps.isNotEmpty,
      comicType: ComicType.other,
      eps: eps.isNotEmpty ? eps : null,
    );

    App.globalTo(() => ComicReadingPage(data, image.page, image.ep));
  }

  Widget _buildPlaceholder(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: const Center(child: Icon(Icons.image_not_supported)),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Handle empty path gracefully (may come from old migration data)
    if (image.imagePath.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          elevation: 1,
          child: _buildPlaceholder(context),
        ),
      );
    }

    // Try stored path as-is (new format: full path from persistentCurrentImage).
    var file = File(image.imagePath);
    if (!file.existsSync()) {
      // Old format: bare filename without directory — prepend images dir.
      if (!image.imagePath.contains('/') && !image.imagePath.contains('\\')) {
        file = File("${App.dataPath}/images/${image.imagePath}");
      }
    }
    final hasImage = file.existsSync();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        elevation: 1,
        child: Stack(
          children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.antiAlias,
                child: hasImage
                    ? Image.file(
                        file,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const Center(child: Icon(Icons.broken_image)),
                      )
                    : const Center(child: Icon(Icons.image_not_supported)),
              ),
            ),
            // Chapter/Page label at top-left corner
            Positioned(
              top: 6,
              left: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'E${image.ep} P${image.page}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            // Bottom title overlay
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.3),
                      Colors.black.withValues(alpha: 0.5),
                    ],
                  ),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(8),
                    bottomRight: Radius.circular(8),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                  child: Text(
                    image.title.replaceAll("\n", ""),
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 12.0,
                      color: Colors.white,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _onTap(context),
                  onLongPress: () {
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('删除'),
                        content: const Text('要删除这个图片收藏吗？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () {
                              onDelete();
                              Navigator.pop(ctx);
                            },
                            child: const Text('删除'),
                          ),
                        ],
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

