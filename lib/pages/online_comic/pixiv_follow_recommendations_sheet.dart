import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/pixiv_bookmark_feedback.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/accounts/account_page_route.dart';
import 'package:picakeep/pages/online_common/online_comic_list_item.dart';
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';

class _DiscoveryScrollController extends ScrollController {
  double _savedOffset = 0;

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics,
          ScrollContext context, ScrollPosition? oldPosition) =>
      ScrollPositionWithSingleContext(
          physics: physics,
          context: context,
          initialPixels: _savedOffset,
          keepScrollOffset: false,
          oldPosition: oldPosition);

  @override
  void detach(ScrollPosition position) {
    _savedOffset = position.pixels;
    super.detach(position);
  }
}

/// The detail entry owns this state, independently of sliver/panel placement.
class PixivFollowDiscoveryController extends ChangeNotifier {
  PixivFollowDiscoveryController({
    required this.seedAuthorId,
    required this.load,
    required this.writeFollow,
    required this.ownerIsCurrent,
    required this.accountIdentity,
  }) : account = accountIdentity();

  final String seedAuthorId;
  final String account;
  final Future<Res<List<PixivRecommendedAuthor>>> Function(String) load;
  final Future<Res<bool>> Function(String, {required bool isFollowing})
      writeFollow;
  final bool Function() ownerIsCurrent;
  final String Function() accountIdentity;
  final scrollController = _DiscoveryScrollController();
  final _busyAuthors = <String>{};
  final _followErrors = <String, String>{};
  final _followed = <String, bool>{};
  List<PixivRecommendedAuthor> authors = const [];
  bool loading = false;
  bool dismissed = false;
  String? error;
  int _readGeneration = 0;
  bool _disposed = false;

  bool get isCurrent =>
      !_disposed && ownerIsCurrent() && accountIdentity() == account;
  bool isBusy(String id) => _busyAuthors.contains(id);
  String? followError(String id) => _followErrors[id];
  bool isFollowed(PixivAuthor author) =>
      _followed[author.id] ?? author.isFollowed;

  Future<void> read() async {
    if (!isCurrent || dismissed || loading) return;
    final generation = ++_readGeneration;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final result = await load(seedAuthorId);
      if (!isCurrent || dismissed || generation != _readGeneration) return;
      if (result.error) throw StateError(result.errorMessageWithoutNull);
      authors = List.unmodifiable(result.data.take(5).map((entry) =>
          PixivRecommendedAuthor(
              author: entry.author,
              works: List.unmodifiable(entry.works.take(3)))));
    } catch (failure) {
      if (!isCurrent || dismissed || generation != _readGeneration) return;
      error = failure.toString().replaceFirst('Bad state: ', '');
    } finally {
      if (!_disposed && generation == _readGeneration) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void dismiss() {
    if (_disposed || dismissed) return;
    dismissed = true;
    _readGeneration++;
    loading = false;
    notifyListeners();
  }

  Future<void> follow(PixivAuthor author,
      {required bool Function() actionsCurrent}) async {
    if (!isCurrent || dismissed || !actionsCurrent() || isBusy(author.id)) {
      return;
    }
    final target = !isFollowed(author);
    _busyAuthors.add(author.id);
    _followErrors.remove(author.id);
    notifyListeners();
    try {
      final result = await writeFollow(author.id, isFollowing: target);
      if (!isCurrent) return;
      if (result.error) {
        if (!dismissed && actionsCurrent()) {
          _followErrors[author.id] = result.errorMessageWithoutNull;
        }
      } else {
        _followed[author.id] = target;
      }
    } catch (_) {
      if (isCurrent && !dismissed && actionsCurrent()) {
        _followErrors[author.id] = '关注失败，请重试';
      }
    } finally {
      // Only this operation owns this author's lock, even after dismissal.
      _busyAuthors.remove(author.id);
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _readGeneration++;
    scrollController.dispose();
    super.dispose();
  }
}

class PixivFollowRecommendationsInline extends StatelessWidget {
  const PixivFollowRecommendationsInline({
    super.key,
    required this.controller,
    required this.source,
    required this.bookmarks,
    required this.writeBookmark,
    required this.accountIdentity,
    required this.isLoggedIn,
    required this.onAccountsChanged,
    required this.onOpenWork,
    this.active = true,
  });

  final PixivFollowDiscoveryController controller;
  final ComicSource source;
  final RecommendationBookmarkController bookmarks;
  final Future<Res<bool>> Function(String, {required bool isAdding})
      writeBookmark;
  final String Function() accountIdentity;
  final bool Function() isLoggedIn;
  final Future<void> Function() onAccountsChanged;
  final void Function(PixivComicBrief, List<PixivComicBrief>) onOpenWork;
  final bool active;

  bool _actionsCurrent(BuildContext context) =>
      controller.isCurrent &&
      !controller.dismissed &&
      active &&
      PixivDetailEntryScope.isActiveOf(context) &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      (PixivBookmarkFeedbackHost.maybeOf(context)?.isCurrent ?? true);

  Future<void> _follow(BuildContext context, PixivAuthor author) async {
    if (!_actionsCurrent(context)) return;
    if (!isLoggedIn()) {
      await showAccountsPage(context);
      if (context.mounted && controller.isCurrent) await onAccountsChanged();
      return;
    }
    await controller.follow(author,
        actionsCurrent: () => context.mounted && _actionsCurrent(context));
  }

  double _textHeight(BuildContext context, String text, TextStyle style,
      double width, int maxLines) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: maxLines,
      ellipsis: '...',
    )..layout(maxWidth: math.max(1, width));
    final height = painter.height;
    painter.dispose();
    return height;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          if (controller.dismissed) return const SizedBox.shrink();
          final theme = Theme.of(context);
          final enabled = _actionsCurrent(context);
          return RepaintBoundary(
            key: const ValueKey('pixiv-follow-recommendations-inline'),
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(children: [
                        Expanded(
                          child: Text('已关注，发现更多作者',
                              style: theme.textTheme.titleSmall),
                        ),
                        IconButton(
                          tooltip: '关闭作者推荐',
                          constraints:
                              const BoxConstraints(minWidth: 48, minHeight: 48),
                          onPressed: enabled ? controller.dismiss : null,
                          icon: const Icon(Icons.close),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 8),
                    if (controller.loading ||
                        controller.error != null ||
                        controller.authors.isEmpty)
                      _status(context, enabled)
                    else
                      LayoutBuilder(builder: (context, constraints) {
                        final cardWidth =
                            math.max(1.0, constraints.maxWidth - 32);
                        // Match the page's author-preview gutters; only the two
                        // image gaps consume space inside the three-column row.
                        final innerWidth = cardWidth;
                        final buttonStyle = theme.textTheme.labelMedium!;
                        final buttonPainter = TextPainter(
                          text: TextSpan(text: '处理中', style: buttonStyle),
                          textDirection: Directionality.of(context),
                          textScaler: MediaQuery.textScalerOf(context),
                        )..layout();
                        final buttonWidth =
                            math.max(48.0, buttonPainter.width + 20);
                        final buttonHeight =
                            math.max(48.0, buttonPainter.height + 8);
                        buttonPainter.dispose();
                        final separate = cardWidth < 260 ||
                            MediaQuery.textScalerOf(context).scale(14) > 20 ||
                            innerWidth - buttonWidth - 48 < 88;
                        final style = theme.textTheme.titleSmall!;
                        final nameWidth = separate
                            ? innerWidth - 40
                            : innerWidth - buttonWidth - 48;
                        var nameHeight = 0.0;
                        var errorHeight = 0.0;
                        for (final entry in controller.authors) {
                          nameHeight = math.max(
                              nameHeight,
                              _textHeight(context, entry.author.name, style,
                                  nameWidth, 2));
                          final error = controller.followError(entry.author.id);
                          if (error != null) {
                            errorHeight = math.max(
                                errorHeight,
                                _textHeight(
                                        context,
                                        error,
                                        theme.textTheme.bodySmall!,
                                        innerWidth,
                                        2) +
                                    8);
                          }
                        }
                        final headHeight = math.max(48.0, nameHeight) +
                            (separate ? buttonHeight + 8 : 0);
                        final imageSize = (innerWidth - 16) / 3;
                        final cardHeight = 16 +
                            headHeight +
                            8 +
                            math.max(48.0, imageSize) +
                            errorHeight;
                        return SizedBox(
                          height: cardHeight,
                          child: ListView.separated(
                            key: const ValueKey('pixiv-follow-authors-scroll'),
                            controller: controller.scrollController,
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: controller.authors.length,
                            separatorBuilder: (_, index) => SizedBox(
                              width: 24,
                              child: Center(
                                child: SizedBox(
                                  key: ValueKey(
                                      'pixiv-follow-author-divider-$index'),
                                  width: 1,
                                  height: math.max(48.0, cardHeight - 16),
                                  child: ColoredBox(
                                    color: theme.colorScheme.outlineVariant
                                        .withValues(alpha: .55),
                                  ),
                                ),
                              ),
                            ),
                            itemBuilder: (context, index) => SizedBox(
                              width: cardWidth,
                              child: _authorCard(
                                  context,
                                  controller.authors[index],
                                  enabled,
                                  separate,
                                  buttonWidth,
                                  headHeight,
                                  imageSize,
                                  errorHeight),
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              ),
            ),
          );
        },
      );

  Widget _status(BuildContext context, bool enabled) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 120),
          child: Center(
            child: controller.loading
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : controller.error != null
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          Text('推荐暂时没能加载：${controller.error}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center),
                          TextButton.icon(
                            style: TextButton.styleFrom(
                                minimumSize: const Size(48, 48)),
                            onPressed: enabled ? controller.read : null,
                            icon: const Icon(Icons.refresh),
                            label: const Text('重试推荐'),
                          ),
                        ]),
                      )
                    : const Text('暂无更多作者推荐'),
          ),
        ),
      );

  Widget _recommendedAvatar(BuildContext context, PixivAuthor author) {
    Widget placeholder({bool failed = false, bool loading = false}) =>
        Semantics(
          label: failed
              ? '${author.name}头像加载失败'
              : loading
                  ? '${author.name}头像加载中'
                  : '${author.name}头像',
          child: const CircleAvatar(
              radius: 16, child: Icon(Icons.person_outline, size: 20)),
        );
    final url = author.avatar.trim();
    return SizedBox.square(
        dimension: 32,
        child: ClipOval(
          child: url.isEmpty
              ? placeholder()
              : Image(
                  image: onlineCoverProvider(url: url, headers: const {
                    'Referer': 'https://www.pixiv.net/',
                    'User-Agent': PixivNetwork.pixivWebUA,
                  }),
                  width: 32,
                  height: 32,
                  fit: BoxFit.cover,
                  frameBuilder: (context, child, frame, synchronous) =>
                      frame != null || synchronous
                          ? child
                          : placeholder(loading: true),
                  errorBuilder: (_, __, ___) => placeholder(failed: true),
                ),
        ));
  }

  Widget _authorCard(
      BuildContext context,
      PixivRecommendedAuthor entry,
      bool enabled,
      bool separate,
      double buttonWidth,
      double headHeight,
      double imageSize,
      double errorHeight) {
    final theme = Theme.of(context);
    final author = entry.author;
    final followButton = FilledButton.tonal(
      key: ValueKey('pixiv-follow-author-button-${author.id}'),
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textStyle: theme.textTheme.labelMedium,
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
      onPressed: enabled && !controller.isBusy(author.id)
          ? () => _follow(context, author)
          : null,
      child: Text(controller.isBusy(author.id)
          ? '处理中'
          : controller.isFollowed(author)
              ? '已关注'
              : '关注'),
    );
    return Material(
      key: ValueKey('pixiv-follow-author-${author.id}'),
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            height: headHeight,
            child: Column(children: [
              Expanded(
                child: Row(children: [
                  _recommendedAvatar(context, author),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Tooltip(
                    message: author.name,
                    child: Text(author.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall),
                  )),
                  if (!separate) ...[
                    const SizedBox(width: 8),
                    SizedBox(width: buttonWidth, child: followButton),
                  ],
                ]),
              ),
              if (separate) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(width: buttonWidth, child: followButton),
                ),
              ],
            ]),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: math.max(48.0, imageSize),
            child: entry.works.isEmpty
                ? const Center(child: Text('暂无可显示作品'))
                : Row(children: [
                    for (final (index, work) in entry.works.indexed) ...[
                      if (index > 0) const SizedBox(width: 8),
                      SizedBox(
                        width: imageSize,
                        height: imageSize,
                        child: OnlineRecommendationCard(
                          key: ValueKey('pixiv-follow-work-${work.id}'),
                          compactPreview: true,
                          compactImageFit: BoxFit.cover,
                          source: source,
                          comic: work,
                          bookmarks: bookmarks,
                          ownerIsCurrent: () => _actionsCurrent(context),
                          actionsEnabled: enabled,
                          feedbackCurrent: enabled,
                          accountIdentity: accountIdentity,
                          isLoggedIn: isLoggedIn,
                          writeBookmark: writeBookmark,
                          onAccountsChanged: onAccountsChanged,
                          onOpenDetail: () {
                            if (_actionsCurrent(context)) {
                              onOpenWork(work, entry.works);
                            }
                          },
                        ),
                      ),
                    ],
                  ]),
          ),
          if (errorHeight > 0)
            SizedBox(
              height: errorHeight,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(controller.followError(author.id) ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall!
                        .copyWith(color: theme.colorScheme.error)),
              ),
            ),
        ]),
      ),
    );
  }
}
