import 'dart:io';
import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_favorites.dart';

class DownloadedComicTile extends StatelessWidget {
  const DownloadedComicTile({
    super.key,
    required this.name,
    required this.author,
    required this.imagePath,
    this.imageProvider,
    this.readingHistoryOverride,
    this.isFavoriteOverride,
    required this.type,
    required this.tag,
    required this.size,
    required this.onTap,
    required this.onLongTap,
    required this.onSecondaryTap,
  });

  final String size;
  final File imagePath;
  final ImageProvider<Object>? imageProvider;
  final History? readingHistoryOverride;
  final bool? isFavoriteOverride;
  final String author;
  final String name;
  final void Function() onTap;
  final void Function() onLongTap;
  final void Function(TapDownDetails details) onSecondaryTap;
  final String? type;
  final List<String> tag;

  List<String>? get tags => tag;

  String get description => size;

  String get subTitle => author;

  String get title => name;

  bool get enableLongPressed => true;

  String? get badge => type;

  String? get comicID => null;

  bool get showFavorite => appdata.settings[72] == '1';

  bool get showReadingPosition => appdata.settings[73] == '1';

  History? get readingHistory => readingHistoryOverride ??
      (comicID == null ? null : HistoryManager().findSync(comicID!));

  @override
  Widget build(BuildContext context) {
    var typeSetting = appdata.settings[44].split(',').first;
    Widget child;
    bool detailedMode;
    if (typeSetting == "0" || typeSetting == "3") {
      detailedMode = true;
      child = _buildDetailedMode(context);
    } else {
      detailedMode = false;
      child = _buildBriefMode(context);
    }

    final isFavorite = showFavorite ? _resolveFavoriteState() : false;

    if (!isFavorite) {
      return child;
    }

    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          left: detailedMode ? 16 : 6,
          top: 8,
          child: Container(
            height: 24,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(4)),
            clipBehavior: Clip.antiAlias,
            child: Row(children: [
              Container(
                height: 24,
                width: 24,
                color: Colors.green,
                child: const Icon(Icons.bookmark_rounded,
                    size: 16, color: Colors.white),
              ),
            ]),
          ),
        )
      ],
    );
  }

  bool _resolveFavoriteState() {
    final override = isFavoriteOverride;
    if (override != null) {
      return override;
    }
    final target = comicID;
    return target == null ? _checkFavorite() : LocalFavoritesManager().isExist(target);
  }

  bool _checkFavorite() {
    try {
      final fav = LocalFavoritesManager();
      final types = [
        FavoriteType.picacg,
        FavoriteType.ehentai,
        FavoriteType.jm,
        FavoriteType.hitomi,
        FavoriteType.htManga,
        FavoriteType.nhentai,
        FavoriteType.copyManga,
        FavoriteType.komiic,
      ];
      for (final folder in fav.folderNames) {
        for (final ft in types) {
          if (fav.comicExists(folder, name, ft.key)) {
            return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }

  Widget _buildDetailedMode(BuildContext context) {
    return LayoutBuilder(builder: (context, constrains) {
      final height = constrains.maxHeight - 16;
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: enableLongPressed ? onLongTap : null,
        onSecondaryTapDown: onSecondaryTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 24, 8),
          child: Row(
            children: [
              Container(
                width: height * 0.68,
                height: double.infinity,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.antiAlias,
                child: _buildImage(),
              ),
              SizedBox.fromSize(size: const Size(16, 5)),
              Expanded(
                child: _ComicDescription(
                  title: title.replaceAll("\n", ""),
                  user: subTitle,
                  description: description,
                  subDescription: _buildReadingPosition(),
                  badge: badge,
                  tags: tags,
                  maxLines: 2,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildBriefMode(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
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
                child: _buildImage(),
              ),
            ),
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
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                  child: Text(
                    title.replaceAll("\n", ""),
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 14.0,
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
                  onTap: onTap,
                  onLongPress: enableLongPressed ? onLongTap : null,
                  onSecondaryTapDown: onSecondaryTap,
                  borderRadius: BorderRadius.circular(8),
                  child: const SizedBox.expand(),
                ),
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildReadingPosition() {
    if (!showReadingPosition) {
      return const SizedBox.shrink();
    }
    final history = readingHistory;
    if (history == null) {
      return const SizedBox.shrink();
    }

    final page = history.page <= 0 ? 1 : history.page;
    final ep = history.ep <= 0 ? null : history.ep;
    final text = ep == null ? 'P$page' : 'E$ep · P$page';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: Colors.orange.shade700,
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildImage() {
    final provider = imageProvider;
    final resolvedProvider = provider ??
        (imagePath.path.isEmpty ? null : FileImage(imagePath) as ImageProvider<Object>);
    if (resolvedProvider == null) {
      return const Center(child: Icon(Icons.image_not_supported));
    }
    return Image(
      image: resolvedProvider,
      fit: BoxFit.cover,
      height: double.infinity,
      gaplessPlayback: false,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, __, ___) =>
          const Center(child: Icon(Icons.image_not_supported)),
    );
  }
}

class _ComicDescription extends StatelessWidget {
  const _ComicDescription({
    required this.title,
    required this.user,
    required this.description,
    this.subDescription,
    this.badge,
    this.maxLines = 2,
    this.tags,
  });

  final String title;
  final String user;
  final String description;
  final Widget? subDescription;
  final String? badge;
  final List<String>? tags;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final visibleTags = tags
        ?.map((element) => element.trim())
        .where((element) => element.isNotEmpty)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14.0),
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
        ),
        if (user.isNotEmpty)
          Text(user, style: const TextStyle(fontSize: 10.0), maxLines: 1),
        const SizedBox(height: 4),
        if (visibleTags != null)
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Padding(
                padding: EdgeInsets.only(bottom: constraints.maxHeight % 23),
                child: Wrap(
                  runAlignment: WrapAlignment.start,
                  clipBehavior: Clip.antiAlias,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  children: [
                    for (var s in visibleTags)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(0, 0, 4, 3),
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(3, 1, 3, 3),
                          decoration: BoxDecoration(
                            color: s == "Unavailable"
                                ? Theme.of(context).colorScheme.errorContainer
                                : Theme.of(context)
                                    .colorScheme
                                    .secondaryContainer,
                            borderRadius:
                                const BorderRadius.all(Radius.circular(8)),
                          ),
                          child: Text(s, style: const TextStyle(fontSize: 12)),
                        ),
                      )
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (subDescription != null) subDescription!,
                  Text(description, style: const TextStyle(fontSize: 12.0)),
                ],
              ),
            ),
            if (badge != null)
              Container(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                ),
                child: Text(badge!, style: const TextStyle(fontSize: 12)),
              )
          ],
        )
      ],
    );
  }
}
