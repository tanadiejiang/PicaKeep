import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/components/pixiv_bookmark_button.dart';
import 'package:picakeep/components/pixiv_bookmark_feedback.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/online_download_manager.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/accounts/account_page_route.dart';
import 'package:picakeep/pages/online_common/online_comic_list_item.dart';
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';
import 'pixiv_author_page_v2.dart';
import 'pixiv_comments_section.dart';
import 'pixiv_detail_shell.dart';

typedef PixivDetailBookmarkWriter = Future<Res<bool>> Function(String id,
    {required bool isAdding, required bool isPrivate});

class PixivOnlineDetailView extends StatefulWidget {
  const PixivOnlineDetailView({
    super.key,
    required this.comicId,
    required this.loadDetail,
    required this.loadPages,
    required this.writeBookmark,
    required this.onRead,
    required this.onDownload,
    required this.onDownloadLongPress,
    required this.onTagTap,
    this.loadAuthor,
    this.bookmarkStore,
    this.accountIdentity,
    this.isLoggedIn,
  });

  final String comicId;
  final Future<Res<PixivComicInfo>> Function() loadDetail;
  final Future<Res<List<PixivPage>>> Function(String) loadPages;
  final PixivDetailBookmarkWriter writeBookmark;
  final void Function(BuildContext, PixivComicInfo, int) onRead;
  final void Function(BuildContext, PixivComicInfo) onDownload;
  final void Function(BuildContext, PixivComicInfo) onDownloadLongPress;
  final void Function(BuildContext, String, String) onTagTap;
  final Future<Res<PixivAuthor>> Function(String)? loadAuthor;
  final PixivBookmarkStateStore? bookmarkStore;
  final String Function()? accountIdentity;
  final bool Function()? isLoggedIn;

  @override
  State<PixivOnlineDetailView> createState() => _PixivOnlineDetailViewState();
}

class _PixivOnlineDetailViewState extends State<PixivOnlineDetailView> {
  static const _headers = {
    'Referer': 'https://www.pixiv.net/',
    'User-Agent': PixivNetwork.pixivWebUA,
  };
  late final PixivBookmarkStateStore _bookmarkStore;
  late final RecommendationBookmarkController _bookmarks;
  PixivComicInfo? _data;
  List<PixivPage> _pages = const [];
  List<PixivDetailImage> _images = const [];
  String? _error;
  String? _imageError;
  bool _loading = true;
  bool _imagesLoading = false;
  bool _favorite = false;
  bool _favoriteBusy = false;
  bool _authorLoading = false;
  bool _followBusy = false;
  PixivAuthor? _author;
  String? _authorError;
  int _generation = 0;
  String _loadedAccount = '';
  int _bookmarkSequence = 0;
  int _bookmarkOperationGeneration = 0;
  PixivBookmarkEvent? _bookmarkEvent;
  bool _entryActive = true;

  String get _account =>
      widget.accountIdentity?.call() ?? pixivBookmarkAccountIdentity();

  @override
  void initState() {
    super.initState();
    _bookmarkStore = widget.bookmarkStore ?? PixivBookmarkStateStore.shared;
    _bookmarks = RecommendationBookmarkController(
        store: _bookmarkStore, resolveUnknownStates: true);
    _bookmarkStore.addListener(_onBookmarkChanged);
    App.localDataVersion.addListener(_onLocalChanged);
    _load();
  }

  void _onLocalChanged() {
    if (mounted) setState(() {});
  }

  void _onBookmarkChanged() {
    if (!mounted ||
        _favoriteBusy ||
        _data == null ||
        _loadedAccount != _account) {
      return;
    }
    final state = _bookmarkStore.stateFor(_account, _data!.id);
    if (state != null && _favorite != state.isBookmarked) {
      setState(() => _favorite = state.isBookmarked);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = PixivDetailEntryScope.isActiveOf(context);
    if (_entryActive != active) _bookmarkEvent = null;
    _entryActive = active;
  }

  @override
  void dispose() {
    _generation++;
    App.localDataVersion.removeListener(_onLocalChanged);
    _bookmarks.dispose();
    _bookmarkStore.removeListener(_onBookmarkChanged);
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final account = _account;
    setState(() {
      _loading = true;
      _bookmarkEvent = null;
      _error = null;
      _author = null;
      _authorLoading = false;
      _authorError = null;
      _imagesLoading = false;
      _imageError = null;
      _pages = const [];
      _images = const [];
    });
    try {
      final result = await widget.loadDetail();
      if (!mounted || generation != _generation || account != _account) return;
      if (result.error) throw StateError(result.errorMessageWithoutNull);
      setState(() {
        _data = result.data;
        _favorite =
            _bookmarkStore.stateFor(account, result.data.id)?.isBookmarked ??
                result.data.isBookmarked;
        _loadedAccount = account;
        _loading = false;
      });
      await _loadPages();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _loadPages() async {
    if (_imagesLoading || _data == null) return;
    final generation = _generation;
    final data = _data!;
    if (data.pageCount == 1) {
      _pages = [
        PixivPage(
          thumbMini: '',
          small: '',
          regular: data.regularUrl,
          original: data.coverUrl,
          width: data.width,
          height: data.height,
        )
      ];
      _buildImages();
      setState(() {});
      return;
    }
    if (data.pageCount <= 0) return;
    setState(() {
      _imagesLoading = true;
      _imageError = null;
    });
    try {
      final result = await widget.loadPages(data.id);
      if (!mounted || generation != _generation) return;
      if (result.error) throw StateError(result.errorMessageWithoutNull);
      setState(() {
        _pages = result.data;
        _imagesLoading = false;
        if (_pages.length != data.pageCount) {
          _imageError = '图片页数与详情不一致，请重试';
        }
        _buildImages();
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _imagesLoading = false;
          _imageError = error.toString();
        });
      }
    }
  }

  void _buildImages() {
    final data = _data!;
    _images = List.generate(_pages.length, (index) {
      final page = _pages[index];
      final url = page.regular.isNotEmpty ? page.regular : page.original;
      return PixivDetailImage(
        key: '${data.id}-$index',
        provider: url.isEmpty
            ? null
            : onlineCoverProvider(url: url, headers: _headers),
        aspectRatio:
            page.width > 0 && page.height > 0 ? page.width / page.height : .75,
        aspectRatioKnown: page.width > 0 && page.height > 0,
        onRead: () => widget.onRead(context, data, index + 1),
      );
    }, growable: false);
  }

  Future<void> _favoriteAction(BuildContext feedbackContext,
      {bool isPrivate = false}) async {
    if (_favoriteBusy || _data == null) return;
    final feedback = PixivBookmarkFeedbackHost.maybeOf(feedbackContext);
    final ticket = feedback?.capture(account: _account, workId: _data!.id);
    if (!(widget.isLoggedIn?.call() ?? PixivNetwork().isLoggedIn)) {
      await showAccountsPage(context);
      if (mounted) await _load();
      return;
    }
    if (_loadedAccount != _account) {
      final wasCurrent = ticket?.isCurrent ?? false;
      final account = _account;
      final reload = _load();
      final generation = _generation;
      // This is an immediate rejected click, not a late write result. Capture
      // its refreshed identity after the host has rebuilt for the new account.
      await WidgetsBinding.instance.endOfFrame;
      if (mounted &&
          feedbackContext.mounted &&
          wasCurrent &&
          _entryActive &&
          generation == _generation &&
          account == _account) {
        PixivBookmarkFeedbackHost.maybeOf(feedbackContext)
            ?.capture(account: account, workId: widget.comicId)
            .show(PixivBookmarkFeedbackMessage.failed('账号已变化，请刷新后重新操作'));
      }
      await reload;
      return;
    }
    final data = _data!;
    if (!_favorite && data.isBookmarkable != true) {
      ticket?.show(PixivBookmarkFeedbackMessage.failed('暂时无法确认此作品可收藏，请刷新'));
      return;
    }
    final generation = _generation;
    final account = _account;
    final target = !_favorite;
    final operationId = ++_bookmarkOperationGeneration;
    PixivBookmarkEvent? begin;
    setState(() {
      _favoriteBusy = true;
      if (_entryActive && (ticket?.isCurrent ?? false)) {
        _bookmarkEvent = begin = PixivBookmarkEvent(
          sequence: ++_bookmarkSequence,
          operationId: operationId,
          phase: PixivBookmarkPhase.begin,
          target: target,
        );
      }
    });
    try {
      ticket?.startWaiting(target: target);
      if (_entryActive &&
          (ticket?.isCurrent ?? false) &&
          !MediaQuery.disableAnimationsOf(feedbackContext)) {
        unawaited(HapticFeedback.selectionClick());
      }
      final result = await widget.writeBookmark(data.id,
          isAdding: target, isPrivate: isPrivate);
      if (!mounted || generation != _generation || account != _account) return;
      if (result.error) {
        _restoreBookmarkAuthority(account, data.id);
        _bookmarkResult(ticket, operationId, false,
            PixivBookmarkFeedbackMessage.failed(result.errorMessageWithoutNull),
            begin: begin);
      } else {
        setState(() => _favorite = target);
        if (_bookmarkStore.stateFor(account, data.id)?.isBookmarked != target) {
          _bookmarkStore.confirm(
              account,
              data.id,
              PixivBookmarkState(
                  isBookmarked: target,
                  isBookmarkable: data.isBookmarkable == true,
                  bookmarkPrivate: target ? isPrivate : null));
        }
        PixivDetailSessionScope.maybeOf(context)?.invalidatePagination();
        _bookmarkResult(
          ticket,
          operationId,
          true,
          !target
              ? const PixivBookmarkFeedbackMessage.removed()
              : isPrivate
                  ? const PixivBookmarkFeedbackMessage.privateAdded()
                  : const PixivBookmarkFeedbackMessage.added(),
          begin: begin,
        );
      }
    } catch (error) {
      if (!mounted || generation != _generation || account != _account) return;
      _restoreBookmarkAuthority(account, data.id);
      _bookmarkResult(ticket, operationId, false,
          PixivBookmarkFeedbackMessage.failed(error.toString()),
          begin: begin);
    } finally {
      ticket?.cancelWaiting();
      if (mounted) {
        setState(() => _favoriteBusy = false);
      }
    }
  }

  void _restoreBookmarkAuthority(String account, String workId) {
    final authority = _bookmarkStore.stateFor(account, workId);
    if (authority != null) {
      setState(() => _favorite = authority.isBookmarked);
    }
  }

  void _bookmarkResult(PixivBookmarkFeedbackTicket? ticket, int operationId,
      bool success, PixivBookmarkFeedbackMessage message,
      {PixivBookmarkEvent? begin}) {
    if (!_entryActive || !(ticket?.isCurrent ?? false)) {
      setState(() => _bookmarkEvent = null);
      return;
    }
    setState(() => _bookmarkEvent = PixivBookmarkEvent(
        sequence: ++_bookmarkSequence,
        operationId: operationId,
        phase: PixivBookmarkPhase.settle,
        success: success,
        begin: begin));
    ticket!.finish(message);
  }

  void _message(String text) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _loadAuthor() async {
    if (_authorLoading || _author != null || _data?.authorId.isEmpty != false) {
      return;
    }
    final generation = _generation;
    final account = _account;
    setState(() {
      _authorLoading = true;
      _authorError = null;
    });
    final result = await (widget.loadAuthor ??
        PixivNetwork().getAuthorInfo)(_data!.authorId);
    if (!mounted || generation != _generation || account != _account) return;
    setState(() {
      _authorLoading = false;
      if (result.error) {
        _authorError = result.errorMessageWithoutNull;
      } else {
        _author = result.data;
      }
    });
  }

  Future<void> _follow() async {
    if (_followBusy || _author == null) return;
    if (!PixivNetwork().isLoggedIn) {
      await showAccountsPage(context);
      if (mounted) {
        _author = null;
        await _loadAuthor();
      }
      return;
    }
    final account = _account;
    final generation = _generation;
    final target = !_author!.isFollowed;
    setState(() => _followBusy = true);
    try {
      final result =
          await PixivNetwork().setFollow(_author!.id, isFollowing: target);
      if (!mounted || generation != _generation || account != _account) return;
      if (result.success) {
        setState(() => _author = _author!.copyWith(isFollowed: target));
      }
      _message(result.error
          ? result.errorMessageWithoutNull
          : target
              ? '已关注'
              : '已取消关注');
    } finally {
      if (mounted) setState(() => _followBusy = false);
    }
  }

  Future<void> _openWork(PixivComicBrief comic) async {
    final source = ComicSource.find('pixiv');
    if (source == null) return;
    final data = _data!;
    final session = PixivDetailSession(
      scope: PixivDetailScope.related,
      entries:
          data.relatedWorks.map((work) => onlinePixivDetailEntry(source, work)),
    );
    await openOnlineComic(context, source, comic, detailSession: session);
  }

  Widget _authorCard(BuildContext context, PixivComicInfo data) {
    final avatar = _author?.avatar ?? data.authorAvatar;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(children: [
        Row(children: [
          CircleAvatar(
              radius: 20,
              backgroundImage: avatar.isEmpty
                  ? null
                  : onlineCoverProvider(url: avatar, headers: _headers),
              child: avatar.isEmpty ? const Icon(Icons.person_outline) : null),
          const SizedBox(width: 12),
          Expanded(
              child: Text(data.author,
                  style: const TextStyle(fontWeight: FontWeight.w600))),
          if (_authorLoading)
            const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2)),
          if (_author != null)
            FilledButton(
                onPressed: _followBusy ? null : _follow,
                child: Text(_followBusy
                    ? '处理中'
                    : _author!.isFollowed
                        ? '已关注'
                        : '加关注')),
          if (_authorError != null)
            IconButton(
                tooltip: '重试作者信息',
                onPressed: _loadAuthor,
                icon: const Icon(Icons.refresh)),
        ]),
        if (data.relatedWorks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SizedBox(
              height: 120,
              child: LayoutBuilder(
                  builder: (context, constraints) => ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: data.relatedWorks.length,
                        itemBuilder: (context, index) {
                          final work = data.relatedWorks[index];
                          return SizedBox(
                            width: (constraints.maxWidth - 16) / 3,
                            child: GestureDetector(
                              onTap: () => _openWork(work),
                              child: Stack(fit: StackFit.expand, children: [
                                Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: Image(
                                            image: onlineCoverProvider(
                                                url: pixivProportionalThumbUrl(
                                                    work.cover),
                                                headers: _headers),
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) =>
                                                const Icon(Icons
                                                    .broken_image_outlined)))),
                                if (work.pageCount > 1)
                                  Positioned(
                                      top: 2,
                                      right: 12,
                                      child: Text('${work.pageCount}',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              shadows: [
                                                Shadow(
                                                    color: Colors.black,
                                                    blurRadius: 2)
                                              ]))),
                              ]),
                            ),
                          );
                        },
                      )),
            ),
          ),
        TextButton.icon(
          onPressed: data.authorId.isEmpty
              ? null
              : () => Navigator.of(context).push(AppPageRoute(
                  builder: (_) => PixivAuthorPageV2(data.authorId))),
          icon: const Icon(Icons.person_outline),
          label: const Text('查看个人简介'),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = _entryActive && TickerMode.valuesOf(context).enabled;
    final media = MediaQuery.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final contentHeight = constraints.maxHeight - media.padding.vertical;
      final favoriteBottom = (contentHeight * .15).clamp(0.0, 80.0);
      return PixivBookmarkFeedbackHost(
        active: active,
        identity: (_account, widget.comicId, _generation),
        bottomOffset: favoriteBottom + 56 + 16,
        avoidViewInsets: true,
        child: Builder(builder: (context) => _buildContent(context, active)),
      );
    });
  }

  Widget _buildContent(BuildContext context, bool active) {
    final feedback = PixivBookmarkFeedbackHost.maybeOf(context);
    final feedbackCurrent = active && (feedback?.isCurrent ?? false);
    if (_loading || _data == null) {
      return Scaffold(
          appBar: AppBar(),
          body: Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error!),
                      IconButton(
                          tooltip: '重试',
                          onPressed: _load,
                          icon: const Icon(Icons.refresh)),
                    ])));
    }
    final data = _data!;
    final source = ComicSource.find('pixiv');
    final downloading =
        OnlineDownloadManager.instance.isDownloading('pixiv${data.id}');
    return PixivDetailShell(
      title: data.title,
      author: data.author,
      images: _images,
      imagesLoading: _imagesLoading,
      imageError: _imageError,
      onRetryImages: _loadPages,
      actionLabel: downloading ? '下载中' : '下载',
      actionIcon: Icons.download_outlined,
      onAction: () => widget.onDownload(context, data),
      onActionLongPress: () => widget.onDownloadLongPress(context, data),
      isFavorited: _favorite,
      favoriteBusy: _favoriteBusy,
      onlineBookmarkAnimations: true,
      favoriteActive: feedbackCurrent,
      favoriteIdentity: (_account, data.id, _generation),
      favoriteVisualEpoch: feedback?.visualEpoch,
      favoriteEvent: _bookmarkEvent,
      favoriteLabel: _favorite ? '取消Pixiv收藏' : '加入Pixiv收藏',
      onFavorite: () => _favoriteAction(context),
      onFavoriteLongPress: () => _favoriteAction(context, isPrivate: true),
      onShare: () async {
        await Clipboard.setData(
            ClipboardData(text: 'https://www.pixiv.net/artworks/${data.id}'));
        if (mounted) _message('已复制作品链接');
      },
      menuItems: const [
        PopupMenuItem(value: 'id', child: Text('复制ID')),
        PopupMenuItem(value: 'refresh', child: Text('刷新')),
        PopupMenuItem(value: 'read', child: Text('从头阅读')),
      ],
      onMenu: (value) {
        if (value == 'id') widget.onTagTap(context, data.id, 'ID');
        if (value == 'refresh') _load();
        if (value == 'read') widget.onRead(context, data, 1);
      },
      sliversBuilder: (context) => [
        SliverToBoxAdapter(
            child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 12, runSpacing: 4, children: [
              if (data.createDate.isNotEmpty)
                Text(data.createDate.replaceFirst('T', ' ').split('+').first),
              Text('${data.viewCount} 阅读'),
              Text('${data.likeCount} 喜欢'),
            ]),
            const SizedBox(height: 12),
            Wrap(
                spacing: 8,
                runSpacing: 2,
                children: data.tags
                    .map((tag) => TextButton(
                        onPressed: () => widget.onTagTap(context, tag, '标签'),
                        child: Text('#$tag')))
                    .toList()),
            if (data.description.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(data.description)),
            if (_imageError != null)
              TextButton.icon(
                  onPressed: _loadPages,
                  icon: const Icon(Icons.refresh),
                  label: Text(_imageError!)),
          ]),
        )),
        const PixivDetailFavoriteBoundary(),
        PixivDetailViewportTrigger(
            key: ValueKey('author-load-$_generation'), onVisible: _loadAuthor),
        SliverToBoxAdapter(child: _authorCard(context, data)),
        PixivCommentsSection(
            key: ValueKey('comments-${data.id}'),
            illustId: data.id,
            autoLoad: true),
        if (data.relatedWorks.isNotEmpty && source != null) ...[
          const SliverToBoxAdapter(
              child: Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Column(children: [
              Text('相关作品',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              Text('作者的其他作品')
            ]),
          )),
          SliverMasonryGrid.count(
            crossAxisCount: 2,
            childCount: data.relatedWorks.length,
            itemBuilder: (context, index) => OnlineRecommendationCard(
              source: source,
              comic: data.relatedWorks[index],
              bookmarks: _bookmarks,
              feedbackCurrent: feedbackCurrent,
              onAccountsChanged: _load,
              onOpenDetail: () => _openWork(data.relatedWorks[index]),
            ),
          ),
        ],
      ],
    );
  }
}
