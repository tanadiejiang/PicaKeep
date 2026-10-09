import 'package:flutter/material.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/pixiv_bookmark_feedback.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/accounts/account_page_route.dart';
import 'package:picakeep/pages/online_common/online_comic_list_item.dart';
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';

/// A dismissible discovery panel after a successful follow. Its data is a
/// separate read, so discovery errors cannot undo the confirmed follow.
class PixivFollowRecommendationsSheet extends StatefulWidget {
  const PixivFollowRecommendationsSheet({
    super.key,
    required this.seedAuthorId,
    required this.source,
    required this.bookmarks,
    required this.load,
    required this.writeFollow,
    required this.writeBookmark,
    required this.ownerIsCurrent,
    required this.accountIdentity,
    required this.isLoggedIn,
    required this.onAccountsChanged,
    required this.onOpenWork,
  });

  final String seedAuthorId;
  final ComicSource source;
  final RecommendationBookmarkController bookmarks;
  final Future<Res<List<PixivRecommendedAuthor>>> Function(String) load;
  final Future<Res<bool>> Function(String, {required bool isFollowing})
      writeFollow;
  final Future<Res<bool>> Function(String, {required bool isAdding})
      writeBookmark;
  final bool Function() ownerIsCurrent;
  final String Function() accountIdentity;
  final bool Function() isLoggedIn;
  final Future<void> Function() onAccountsChanged;
  final void Function(PixivComicBrief, List<PixivComicBrief>) onOpenWork;

  @override
  State<PixivFollowRecommendationsSheet> createState() =>
      _PixivFollowRecommendationsSheetState();
}

class _PixivFollowRecommendationsSheetState
    extends State<PixivFollowRecommendationsSheet> {
  List<PixivRecommendedAuthor> _authors = const [];
  final _busyAuthors = <String>{};
  final _followErrors = <String, String>{};
  final _followed = <String, bool>{};
  bool _loading = true;
  String? _error;
  int _generation = 0;
  late final String _account = widget.accountIdentity();

  bool get _current =>
      mounted &&
      widget.ownerIsCurrent() &&
      widget.accountIdentity() == _account;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.load(widget.seedAuthorId);
      if (!_current || generation != _generation) return;
      if (result.error) throw StateError(result.errorMessageWithoutNull);
      setState(() {
        _authors = result.data;
        _loading = false;
      });
    } catch (error) {
      if (_current && generation == _generation) {
        setState(() {
          _error = error.toString().replaceFirst('Bad state: ', '');
          _loading = false;
        });
      }
    }
  }

  Future<void> _follow(PixivAuthor author) async {
    if (!_current || _busyAuthors.contains(author.id)) return;
    if (!widget.isLoggedIn()) {
      await showAccountsPage(context);
      if (_current) await widget.onAccountsChanged();
      return;
    }
    final generation = _generation;
    final target = !(_followed[author.id] ?? author.isFollowed);
    setState(() {
      _busyAuthors.add(author.id);
      _followErrors.remove(author.id);
    });
    try {
      final result = await widget.writeFollow(author.id, isFollowing: target);
      if (!_current || generation != _generation) return;
      setState(() {
        if (result.error) {
          _followErrors[author.id] = result.errorMessageWithoutNull;
        } else {
          _followed[author.id] = target;
        }
      });
    } catch (_) {
      if (_current && generation == _generation) {
        setState(() => _followErrors[author.id] = '关注失败，请重试');
      }
    } finally {
      if (_current && generation == _generation) {
        setState(() => _busyAuthors.remove(author.id));
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = _current && (ModalRoute.of(context)?.isCurrent ?? true);
    final height =
        (MediaQuery.sizeOf(context).height * .56).clamp(330.0, 480.0);
    return SizedBox(
      height: height,
      child: PixivBookmarkFeedbackHost(
        active: active,
        identity: (
          'follow-recommendations',
          widget.seedAuthorId,
          _account,
          _generation
        ),
        bottomOffset: 16,
        child: Builder(
            builder: (context) => SafeArea(
                  top: false,
                  child: SizedBox(
                    height: height,
                    child: RepaintBoundary(
                      key: const ValueKey('pixiv-follow-recommendations-sheet'),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 16),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                const SizedBox(width: 20),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primaryContainer,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text('已关注',
                                      style: theme.textTheme.labelMedium
                                          ?.copyWith(
                                              color: theme.colorScheme
                                                  .onPrimaryContainer)),
                                ),
                                const Spacer(),
                                IconButton(
                                    tooltip: '关闭作者推荐',
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                    icon: const Icon(Icons.close)),
                                const SizedBox(width: 8),
                              ]),
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(20, 0, 20, 12),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text('发现更多作者',
                                          style: theme.textTheme.titleLarge
                                              ?.copyWith(
                                                  fontWeight: FontWeight.w600)),
                                      const SizedBox(height: 4),
                                      Text('左右滑动，看看他们的作品',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                  color: theme.colorScheme
                                                      .onSurfaceVariant)),
                                    ]),
                              ),
                              Expanded(
                                child: _loading
                                    ? const Center(
                                        child: CircularProgressIndicator())
                                    : _error != null
                                        ? Center(
                                            child: Padding(
                                                padding:
                                                    const EdgeInsets.all(20),
                                                child: Column(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Text('推荐暂时没能加载：$_error',
                                                          textAlign:
                                                              TextAlign.center),
                                                      TextButton.icon(
                                                          onPressed: active
                                                              ? _load
                                                              : null,
                                                          icon: const Icon(
                                                              Icons.refresh),
                                                          label: const Text(
                                                              '重试推荐')),
                                                    ])))
                                        : _authors.isEmpty
                                            ? const Center(
                                                child: Text('暂无更多作者推荐'))
                                            : LayoutBuilder(
                                                builder: (context,
                                                        constraints) =>
                                                    ListView.separated(
                                                      key: const ValueKey(
                                                          'pixiv-follow-authors-scroll'),
                                                      scrollDirection:
                                                          Axis.horizontal,
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                          horizontal: 20),
                                                      itemCount:
                                                          _authors.length,
                                                      separatorBuilder:
                                                          (_, __) =>
                                                              const SizedBox(
                                                                  width: 12),
                                                      itemBuilder:
                                                          (context, index) =>
                                                              SizedBox(
                                                        width: (constraints
                                                                    .maxWidth *
                                                                .84)
                                                            .clamp(
                                                                260.0, 380.0),
                                                        child: _authorCard(
                                                            context,
                                                            _authors[index],
                                                            active),
                                                      ),
                                                    )),
                              ),
                            ]),
                      ),
                    ),
                  ),
                )),
      ),
    );
  }

  Widget _authorCard(
      BuildContext context, PixivRecommendedAuthor entry, bool active) {
    final theme = Theme.of(context);
    final author = entry.author;
    final followed = _followed[author.id] ?? author.isFollowed;
    return Material(
      key: ValueKey('pixiv-follow-author-${author.id}'),
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(
                radius: 18,
                backgroundImage: author.avatar.isEmpty
                    ? null
                    : onlineCoverProvider(
                        url: author.avatar,
                        headers: const {'Referer': 'https://www.pixiv.net/'}),
                child: author.avatar.isEmpty
                    ? const Icon(Icons.person_outline)
                    : null),
            const SizedBox(width: 8),
            Expanded(
                child: Text(author.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall)),
            const SizedBox(width: 8),
            FilledButton.tonal(
              key: ValueKey('pixiv-follow-author-button-${author.id}'),
              onPressed: active && !_busyAuthors.contains(author.id)
                  ? () => _follow(author)
                  : null,
              child: Text(_busyAuthors.contains(author.id)
                  ? '处理中'
                  : followed
                      ? '已关注'
                      : '关注'),
            ),
          ]),
          if (_followErrors[author.id] case final error?)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error))),
          const SizedBox(height: 12),
          Expanded(
              child: entry.works.isEmpty
                  ? const Center(child: Text('暂无可显示作品'))
                  : ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: entry.works.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 6),
                      itemBuilder: (context, index) => SizedBox(
                        width: 92,
                        child: OnlineRecommendationCard(
                          key: ValueKey(
                              'pixiv-follow-work-${entry.works[index].id}'),
                          compactPreview: true,
                          source: widget.source,
                          comic: entry.works[index],
                          bookmarks: widget.bookmarks,
                          ownerIsCurrent: () =>
                              _current &&
                              (ModalRoute.of(context)?.isCurrent ?? true),
                          actionsEnabled: active,
                          feedbackCurrent: active,
                          accountIdentity: widget.accountIdentity,
                          isLoggedIn: widget.isLoggedIn,
                          writeBookmark: widget.writeBookmark,
                          onAccountsChanged: widget.onAccountsChanged,
                          onOpenDetail: () {
                            if (_current &&
                                (ModalRoute.of(context)?.isCurrent ?? true)) {
                              widget.onOpenWork(
                                  entry.works[index], entry.works);
                            }
                          },
                        ),
                      ),
                    )),
        ]),
      ),
    );
  }
}
