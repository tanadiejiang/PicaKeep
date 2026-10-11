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
import 'package:picakeep/foundation/pixiv_detail_feeds.dart';
import 'package:picakeep/foundation/pixiv_detail_feed_settings.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/foundation/pixiv_detail_preview.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/accounts/account_page_route.dart';
import 'package:picakeep/pages/explore/explore_common.dart';
import 'package:picakeep/pages/online_common/online_comic_list_item.dart';
import 'package:picakeep/pages/online_common/online_recommendation_card.dart';
import 'pixiv_author_page_v2.dart';
import 'pixiv_comments_section.dart';
import 'pixiv_detail_shell.dart';
import 'pixiv_follow_recommendations_sheet.dart';

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
    this.writeFollow,
    this.loadRecommendedAuthors,
    this.loadAuthorWorkIds,
    this.loadAuthorPreviewWorks,
    this.loadRecommendations,
    this.loadRecommendationWorks,
    this.loadCommentRoots,
    this.loadCommentReplies,
    this.onOpenWork,
    this.bookmarkStore,
    this.accountIdentity,
    this.isLoggedIn,
    this.initialPreview,
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
  final Future<Res<bool>> Function(String, {required bool isFollowing})?
      writeFollow;
  final Future<Res<List<PixivRecommendedAuthor>>> Function(String)?
      loadRecommendedAuthors;
  final PixivWorkIdsLoader? loadAuthorWorkIds;
  final PixivAuthorPreviewLoader? loadAuthorPreviewWorks;
  final PixivRecommendationsLoader? loadRecommendations;
  final PixivRecommendationWorksLoader? loadRecommendationWorks;
  final PixivCommentRootsLoader? loadCommentRoots;
  final PixivCommentRepliesLoader? loadCommentReplies;
  final Future<void> Function(PixivComicBrief, PixivDetailSession)? onOpenWork;
  final PixivBookmarkStateStore? bookmarkStore;
  final String Function()? accountIdentity;
  final bool Function()? isLoggedIn;
  final PixivDetailPreview? initialPreview;

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
  bool _authorAttempted = false;
  bool _avatarReadQueued = false;
  bool _followBusy = false;
  int _authorFollowRevision = 0;
  PixivAuthor? _author;
  String? _authorError;
  PixivAuthorPreviewController? _authorPreview;
  PixivWorkRecommendationsController? _recommendations;
  PixivFollowDiscoveryController? _discovery;
  int _generation = 0;
  int _imageRequestVersion = 0;
  PixivDetailPreview? _entryPreview;
  String _loadedAccount = '';
  int _bookmarkSequence = 0;
  int _bookmarkOperationGeneration = 0;
  PixivBookmarkEvent? _bookmarkEvent;
  bool _entryActive = true;
  bool _galleryExpanded = true;
  double _bottomPullDistance = 0;
  bool _pullTriggered = false;

  PixivDetailSession? get _session => context
      .getInheritedWidgetOfExactType<PixivDetailSessionScope>()
      ?.notifier;

  String get _authorName {
    final profile = _author?.name.trim() ?? '';
    if (profile.isNotEmpty) return profile;
    final detail = _data?.author.trim() ?? '';
    if (detail.isNotEmpty) return detail;
    final id = _data?.authorId.trim() ?? '';
    return id.isEmpty ? '作者信息待完善' : '作者 $id';
  }

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
    App.displaySettingsVersion.addListener(_onDisplaySettingsChanged);
    _load(reuseSession: true);
  }

  void _onLocalChanged() {
    if (mounted) setState(() {});
  }

  void _onDisplaySettingsChanged() {
    if (!mounted) return;
    final data = _data;
    if (data != null &&
        _loadedAccount == _account &&
        (_authorPreview?.previewCount != readPixivAuthorPreviewCount() ||
            _recommendations?.batchSize != readPixivRelatedRequestedCount())) {
      _disposeFeeds();
      _createFeeds(data, _generation, _loadedAccount);
      _bottomPullDistance = 0;
      _pullTriggered = false;
    }
    setState(() {});
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
    _entryPreview = PixivDetailSessionScope.previewOf(context);
    if (_entryActive != active) _bookmarkEvent = null;
    _entryActive = active;
  }

  @override
  void didUpdateWidget(covariant PixivOnlineDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.comicId != widget.comicId) _load();
  }

  void _disposeFeeds() {
    _authorPreview?.removeListener(_onFeedChanged);
    _recommendations?.removeListener(_onFeedChanged);
    _authorPreview?.dispose();
    _recommendations?.dispose();
    _authorPreview = null;
    _recommendations = null;
  }

  PixivDetailPreview? get _preview {
    final preview = _entryPreview ?? widget.initialPreview;
    if (preview == null ||
        preview.workId != widget.comicId ||
        preview.accountIdentity != _account ||
        !preview.isCurrent) {
      return null;
    }
    return preview;
  }

  String get _authorAvatar {
    final profile = _author?.avatar.trim() ?? '';
    final detail = _data?.authorAvatar.trim() ?? '';
    return profile.isNotEmpty
        ? profile
        : detail.isNotEmpty
            ? detail
            : (_preview?.authorAvatarUrl.trim() ?? '');
  }

  void _queueMissingAvatar(bool active) {
    final data = _data;
    if (!active ||
        _loading ||
        data == null ||
        _loadedAccount != _account ||
        data.authorId.trim().isEmpty ||
        _authorAvatar.isNotEmpty ||
        _authorAttempted ||
        _authorLoading ||
        _avatarReadQueued ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    _avatarReadQueued = true;
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _avatarReadQueued = false;
      if (!mounted ||
          generation != _generation ||
          !_entryActive ||
          !TickerMode.valuesOf(context).enabled ||
          !(ModalRoute.of(context)?.isCurrent ?? true) ||
          _authorAvatar.isNotEmpty) {
        return;
      }
      unawaited(_loadAuthor());
    });
  }

  void _disposeDiscovery() {
    _discovery?.removeListener(_onFeedChanged);
    _discovery?.dispose();
    _discovery = null;
  }

  void _onFeedChanged() {
    if (mounted) setState(() {});
  }

  bool _acceptWork(PixivComicBrief work) =>
      !readHideBlockedComics() ||
      buildExploreBlockingResolver()?.call(work) == null;

  void _createFeeds(PixivComicInfo data, int generation, String account) {
    bool isCurrent() =>
        mounted &&
        generation == _generation &&
        account == _account &&
        data.id == _data?.id;
    _authorPreview = PixivAuthorPreviewController(
      workId: data.id,
      authorId: data.authorId,
      seed: data.relatedWorks,
      previewCount: readPixivAuthorPreviewCount(),
      loadIds: widget.loadAuthorWorkIds ?? PixivNetwork().getAuthorWorkIds,
      loadWorks:
          widget.loadAuthorPreviewWorks ?? PixivNetwork().getAuthorPreviewWorks,
      ownerIsCurrent: isCurrent,
      accepts: _acceptWork,
    )..addListener(_onFeedChanged);
    final batchSize = readPixivRelatedRequestedCount();
    _recommendations = PixivWorkRecommendationsController(
      workId: data.id,
      batchSize: batchSize,
      loadInitial: widget.loadRecommendations ??
          (id) => PixivNetwork().getWorkRecommendations(id, limit: batchSize),
      loadWorks: widget.loadRecommendationWorks ??
          PixivNetwork().getRecommendationWorks,
      ownerIsCurrent: isCurrent,
      accepts: _acceptWork,
    )..addListener(_onFeedChanged);
  }

  void _loadVisibleAuthor() {
    if (!_entryActive || !TickerMode.valuesOf(context).enabled) return;
    _loadAuthor();
    final preview = _authorPreview;
    if (preview != null && !preview.attempted) preview.load();
  }

  @override
  void dispose() {
    _generation++;
    _disposeFeeds();
    _disposeDiscovery();
    App.localDataVersion.removeListener(_onLocalChanged);
    App.displaySettingsVersion.removeListener(_onDisplaySettingsChanged);
    _bookmarks.dispose();
    _bookmarkStore.removeListener(_onBookmarkChanged);
    super.dispose();
  }

  Future<void> _load({bool reuseSession = false}) async {
    if (!reuseSession) {
      _session?.invalidateResponses(account: _account, workId: widget.comicId);
    }
    final generation = ++_generation;
    final account = _account;
    _disposeFeeds();
    _disposeDiscovery();
    setState(() {
      _loading = true;
      _data = null;
      _imageRequestVersion++;
      _galleryExpanded = true;
      _bookmarkEvent = null;
      _error = null;
      _author = null;
      _authorLoading = false;
      _authorAttempted = false;
      _authorError = null;
      _imagesLoading = false;
      _imageError = null;
      _pages = const [];
      _images = const [];
    });
    try {
      final session = _session;
      final result = await (session == null
          ? widget.loadDetail()
          : session.readResponse<Res<PixivComicInfo>>(
              account: account,
              workId: widget.comicId,
              kind: 'detail',
              load: widget.loadDetail,
              isReusable: (value) => !value.error,
            ));
      if (!mounted || generation != _generation || account != _account) return;
      if (result.error) throw StateError(result.errorMessageWithoutNull);
      setState(() {
        _data = result.data;
        _createFeeds(result.data, generation, account);
        _favorite =
            _bookmarkStore.stateFor(account, result.data.id)?.isBookmarked ??
                result.data.isBookmarked;
        _loadedAccount = account;
        _loading = false;
      });
      await _loadPages();
    } catch (error) {
      if (mounted && generation == _generation && account == _account) {
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
    final account = _loadedAccount;
    if (account != _account) return;
    final requestVersion = ++_imageRequestVersion;
    bool current() =>
        mounted &&
        generation == _generation &&
        requestVersion == _imageRequestVersion &&
        account == _account &&
        data.id == _data?.id;
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
      final session = _session;
      final result = await (session == null
          ? widget.loadPages(data.id)
          : session.readResponse<Res<List<PixivPage>>>(
              account: account,
              workId: data.id,
              kind: 'pages',
              load: () => widget.loadPages(data.id),
              isReusable: (value) =>
                  !value.error && value.data.length == data.pageCount,
            ));
      if (!current()) return;
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
      if (current()) {
        setState(() {
          _imagesLoading = false;
          _imageError = error.toString();
        });
      }
    }
  }

  Future<void> _retryImages() async {
    if (_imagesLoading || _data == null || _loadedAccount != _account) return;
    _session?.invalidateResponses(
        account: _account, workId: widget.comicId, kind: 'pages');
    final generation = _generation;
    final version = _imageRequestVersion;
    final account = _account;
    final width = (MediaQuery.sizeOf(context).width *
            MediaQuery.devicePixelRatioOf(context) *
            1.2)
        .round();
    final configuration = createLocalImageConfiguration(context);
    for (final image in _images) {
      final provider = image.provider;
      if (provider == null) continue;
      await ResizeImage.resizeIfNeeded(width, null, provider)
          .evict(configuration: configuration);
      await provider.evict(configuration: configuration);
    }
    if (!mounted ||
        generation != _generation ||
        version != _imageRequestVersion ||
        account != _account) {
      return;
    }
    await _loadPages();
  }

  void _buildImages() {
    final data = _data!;
    final preview = _preview;
    _images = List.generate(_pages.length, (index) {
      final page = _pages[index];
      final url = page.regular.isNotEmpty ? page.regular : page.original;
      final pageRatioKnown = page.width > 0 && page.height > 0;
      final seed = index == 0 ? preview : null;
      return PixivDetailImage(
        key: '${data.id}-$index',
        contentIdentity: (_generation, _imageRequestVersion),
        provider: url.isEmpty
            ? null
            : onlineCoverProvider(url: url, headers: _headers),
        previewProvider: seed?.provider,
        previewFallbackProvider: seed?.fallbackProvider,
        aspectRatio: pageRatioKnown
            ? page.width / page.height
            : (seed?.aspectRatio ?? .75),
        aspectRatioKnown: pageRatioKnown || (seed?.aspectRatioKnown ?? false),
        onRead: () => widget.onRead(context, data, index + 1),
      );
    }, growable: false);
  }

  List<PixivDetailImage> get _displayImages {
    final preview = _preview;
    if (_images.isNotEmpty) {
      final first = _images.first;
      if (first.previewProvider == preview?.provider &&
          first.previewFallbackProvider == preview?.fallbackProvider) {
        return _images;
      }
      return [
        PixivDetailImage(
          key: first.key,
          provider: first.provider,
          previewProvider: preview?.provider,
          previewFallbackProvider: preview?.fallbackProvider,
          contentIdentity: first.contentIdentity,
          aspectRatio: first.aspectRatio,
          aspectRatioKnown: first.aspectRatioKnown,
          onRead: first.onRead,
        ),
        ..._images.skip(1),
      ];
    }
    if (preview == null || _data == null) return _images;
    final data = _data!;
    final known = data.width > 0 && data.height > 0;
    return [
      PixivDetailImage(
        key: '${data.id}-0',
        contentIdentity: (_generation, _imageRequestVersion),
        provider: null,
        previewProvider: preview.provider,
        previewFallbackProvider: preview.fallbackProvider,
        aspectRatio: known ? data.width / data.height : preview.aspectRatio,
        aspectRatioKnown: known || preview.aspectRatioKnown,
        onRead: () => widget.onRead(context, data, 1),
      ),
    ];
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

  Future<void> _loadAuthor({bool retry = false}) async {
    final data = _data;
    if (_authorLoading ||
        (!retry && (_authorAttempted || _author != null)) ||
        data == null ||
        data.authorId.trim().isEmpty ||
        _loading ||
        _loadedAccount != _account ||
        !_entryActive ||
        !TickerMode.valuesOf(context).enabled) {
      return;
    }
    final generation = _generation;
    final account = _account;
    final followRevision = _authorFollowRevision;
    bool current() =>
        mounted &&
        generation == _generation &&
        account == _account &&
        data.id == _data?.id &&
        data.authorId == _data?.authorId;
    setState(() {
      _authorLoading = true;
      _authorAttempted = true;
      _authorError = null;
    });
    try {
      final result = await (widget.loadAuthor ??
          PixivNetwork().getAuthorInfo)(data.authorId);
      if (!current()) return;
      if (result.error) throw StateError(result.errorMessageWithoutNull);
      setState(() => _author =
          followRevision != _authorFollowRevision && _author != null
              ? result.data.copyWith(isFollowed: _author!.isFollowed)
              : result.data);
    } catch (error) {
      if (current()) {
        setState(() =>
            _authorError = error.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (current()) setState(() => _authorLoading = false);
    }
  }

  void _retryAuthor() => unawaited(_loadAuthor(retry: true));

  Future<void> _follow() async {
    if (_followBusy ||
        _author == null ||
        _loadedAccount != _account ||
        !_entryActive ||
        !TickerMode.valuesOf(context).enabled ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    if (!(widget.isLoggedIn?.call() ?? PixivNetwork().isLoggedIn)) {
      await showAccountsPage(context);
      if (mounted) await _load();
      return;
    }
    final account = _account;
    final generation = _generation;
    final authorId = _author!.id;
    final target = !_author!.isFollowed;
    setState(() => _followBusy = true);
    try {
      final result = await (widget.writeFollow ??
          PixivNetwork().setFollow)(authorId, isFollowing: target);
      if (!mounted || generation != _generation || account != _account) return;
      if (result.error) {
        if (_entryActive &&
            TickerMode.valuesOf(context).enabled &&
            (ModalRoute.of(context)?.isCurrent ?? true)) {
          _message(result.errorMessageWithoutNull);
        }
      } else {
        setState(() {
          _authorFollowRevision++;
          _author = _author!.copyWith(isFollowed: target);
        });
        if (target &&
            _entryActive &&
            TickerMode.valuesOf(context).enabled &&
            (ModalRoute.of(context)?.isCurrent ?? true)) {
          _showFollowRecommendations(authorId, generation, account);
        } else if (!target &&
            _entryActive &&
            (ModalRoute.of(context)?.isCurrent ?? true)) {
          _message('已取消关注');
        }
      }
    } catch (_) {
      if (mounted &&
          generation == _generation &&
          account == _account &&
          _entryActive &&
          TickerMode.valuesOf(context).enabled &&
          (ModalRoute.of(context)?.isCurrent ?? true)) {
        _message('关注失败，请重试');
      }
    } finally {
      // Refresh preserves the single follow lock; the originating write owns
      // its release even when its old result no longer belongs to this page.
      if (mounted) {
        setState(() => _followBusy = false);
      }
    }
  }

  void _showFollowRecommendations(
      String authorId, int generation, String account) {
    final workId = _data?.id;
    if (ComicSource.find('pixiv') == null || !mounted || workId == null) return;
    _disposeDiscovery();
    late final PixivFollowDiscoveryController discovery;
    discovery = PixivFollowDiscoveryController(
      seedAuthorId: authorId,
      load:
          widget.loadRecommendedAuthors ?? PixivNetwork().getRecommendedAuthors,
      writeFollow: widget.writeFollow ?? PixivNetwork().setFollow,
      ownerIsCurrent: () =>
          mounted &&
          generation == _generation &&
          account == _account &&
          workId == _data?.id &&
          authorId == _data?.authorId &&
          identical(_discovery, discovery),
      accountIdentity: () => _account,
    )..addListener(_onFeedChanged);
    setState(() => _discovery = discovery);
    unawaited(discovery.read());
  }

  Future<void> _openDiscoveryWork(PixivFollowDiscoveryController discovery,
      PixivComicBrief work, List<PixivComicBrief> works) async {
    final source = ComicSource.find('pixiv');
    if (source == null ||
        !discovery.isCurrent ||
        discovery.dismissed ||
        !_entryActive ||
        !TickerMode.valuesOf(context).enabled ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    final session = PixivDetailSession(
      scope: PixivDetailScope.author,
      entries: works.map((item) => onlinePixivDetailEntry(source, item)),
      ownerIsCurrent: () => discovery.isCurrent,
    );
    if (widget.onOpenWork case final open?) {
      try {
        await open(work, session);
      } finally {
        session.dispose();
      }
    } else {
      await openOnlineComic(context, source, work, detailSession: session);
    }
  }

  Future<void> _openWork(PixivComicBrief comic,
      {required bool recommendation}) async {
    final source = ComicSource.find('pixiv');
    if (source == null) return;
    final feed = _recommendations;
    final preview = _authorPreview;
    if (recommendation ? feed?.isCurrent != true : preview?.isCurrent != true) {
      return;
    }
    final session = PixivDetailSession(
      scope:
          recommendation ? PixivDetailScope.related : PixivDetailScope.author,
      entries: (recommendation ? feed!.items : preview!.items)
          .map((work) => onlinePixivDetailEntry(source, work)),
      hasMore: recommendation && feed!.hasMore,
      continuationPosition: recommendation ? feed!.continuationPosition : null,
      ownerIsCurrent: () => recommendation
          ? identical(_recommendations, feed) && feed!.isCurrent
          : identical(_authorPreview, preview) && preview!.isCurrent,
      loadMore: !recommendation
          ? null
          : () async {
              await feed!.loadMore();
              if (feed.error != null) throw StateError(feed.error!);
              return PixivDetailBatch(
                feed.items.map((work) => onlinePixivDetailEntry(source, work)),
                hasMore: feed.hasMore,
                continuationPosition: feed.continuationPosition,
              );
            },
    );
    if (widget.onOpenWork case final open?) {
      try {
        await open(comic, session);
      } finally {
        session.dispose();
      }
    } else {
      await openOnlineComic(context, source, comic, detailSession: session);
    }
  }

  List<Widget> _recommendationSlivers(BuildContext context, ComicSource source,
      bool active, bool feedbackCurrent) {
    final feed = _recommendations!;
    final works = feed.items;
    final blocking = buildExploreBlockingResolver();
    return [
      PixivDetailViewportTrigger(
        key: ValueKey(('recommendations-load', feed, active)),
        onVisible: !active || feed.attempted ? null : feed.load,
      ),
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 24, 16, 12),
          child: Text('相关推荐',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        ),
      ),
      if (works.isNotEmpty)
        SliverMasonryGrid.count(
          key: ValueKey('pixiv-related-grid-${feed.workId}'),
          crossAxisCount: 2,
          childCount: works.length,
          itemBuilder: (context, index) => OnlineRecommendationCard(
            key: ValueKey('pixiv-related-${works[index].id}'),
            source: source,
            comic: works[index],
            bookmarks: _bookmarks,
            actionsEnabled: active && feed.isCurrent,
            blockedBy: blocking?.call(works[index]),
            feedbackCurrent: feedbackCurrent,
            onAccountsChanged: _load,
            onOpenDetail: () => _openWork(works[index], recommendation: true),
          ),
        ),
      SliverToBoxAdapter(
        child: Padding(
          key: ValueKey('pixiv-related-status-${feed.workId}'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (feed.busy)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            if (feed.error != null) ...[
              Text('相关推荐加载失败：${feed.error}', textAlign: TextAlign.center),
              TextButton.icon(
                onPressed: active
                    ? feed.initialized
                        ? feed.loadNextRound
                        : feed.load
                    : null,
                icon: const Icon(Icons.refresh),
                label: const Text('重试相关推荐'),
              ),
            ] else if (!feed.busy && feed.canLoadNextRound)
              TextButton(
                onPressed: active ? feed.loadNextRound : null,
                child: Text(feed.lastAddedCount == 0
                    ? '本轮没有新的可显示作品，再推荐一轮'
                    : '上拉或点击，再推荐一轮'),
              )
            else if (!feed.busy && feed.initialized && works.isEmpty)
              const Text('暂无相关推荐'),
          ]),
        ),
      ),
    ];
  }

  bool _onRecommendationScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is ScrollStartNotification ||
        notification is ScrollEndNotification) {
      _bottomPullDistance = 0;
      _pullTriggered = false;
      return false;
    }
    final feed = _recommendations;
    if (!_galleryExpanded ||
        !_entryActive ||
        !TickerMode.valuesOf(context).enabled ||
        feed == null ||
        !feed.isCurrent ||
        !feed.canLoadNextRound ||
        feed.busy ||
        _pullTriggered) {
      return false;
    }
    final metrics = notification.metrics;
    if (metrics.pixels < metrics.maxScrollExtent - 24) {
      _bottomPullDistance = 0;
      return false;
    }
    if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        notification.overscroll > 0) {
      _bottomPullDistance += notification.overscroll;
    } else if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null &&
        (notification.scrollDelta ?? 0) > 0 &&
        metrics.pixels > metrics.maxScrollExtent) {
      // BouncingScrollPhysics reports extra pixels instead of Overscroll.
      _bottomPullDistance = metrics.pixels - metrics.maxScrollExtent;
    }
    if (_bottomPullDistance >= 120) {
      _pullTriggered = true;
      _bottomPullDistance = 0;
      feed.loadNextRound();
    }
    return false;
  }

  Widget _currentAuthorAvatar(BuildContext context) {
    final url = _authorAvatar;
    final fallbackUrl = _data?.authorAvatar.trim() ?? '';
    Widget placeholder({bool failed = false, bool loading = false}) =>
        Semantics(
          label: loading || _authorLoading && url.isEmpty
              ? '作者头像加载中'
              : failed || _authorError != null
                  ? '作者头像加载失败'
                  : '暂无作者头像',
          child: CircleAvatar(
              radius: 20,
              child: _authorLoading && url.isEmpty
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.person_outline)),
        );
    Widget image(String source, {bool allowFallback = false}) => Image(
          image: onlineCoverProvider(url: source, headers: _headers),
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          frameBuilder: (context, child, frame, synchronous) =>
              frame != null || synchronous ? child : placeholder(loading: true),
          errorBuilder: (_, __, ___) =>
              allowFallback && fallbackUrl.isNotEmpty && fallbackUrl != source
                  ? image(fallbackUrl)
                  : placeholder(failed: true),
        );
    return SizedBox.square(
      dimension: 40,
      child: ClipOval(
          child: url.isEmpty ? placeholder() : image(url, allowFallback: true)),
    );
  }

  Widget _authorCard(BuildContext context, PixivComicInfo data) {
    final preview = _authorPreview!;
    final works = preview.items;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(children: [
        Row(children: [
          _currentAuthorAvatar(context),
          const SizedBox(width: 12),
          Expanded(
              child: Text(_authorName,
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
                      : '加关注'),
            ),
          if (_authorError != null)
            IconButton(
                tooltip: '重试作者信息',
                onPressed: _authorLoading ? null : _retryAuthor,
                icon: const Icon(Icons.refresh)),
        ]),
        if (works.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SizedBox(
              height: 120,
              child: LayoutBuilder(
                builder: (context, constraints) => ListView.builder(
                  key: ValueKey('pixiv-author-preview-${data.id}'),
                  scrollDirection: Axis.horizontal,
                  itemCount: works.length,
                  itemBuilder: (context, index) {
                    final work = works[index];
                    return SizedBox(
                      key: ValueKey('pixiv-author-preview-${work.id}'),
                      width: (constraints.maxWidth - 16) / 3,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ComicSource.find('pixiv') == null
                            ? const Icon(Icons.image_outlined)
                            : OnlineRecommendationCard(
                                compactPreview: true,
                                source: ComicSource.find('pixiv')!,
                                comic: work,
                                bookmarks: _bookmarks,
                                ownerIsCurrent: () =>
                                    preview.isCurrent &&
                                    identical(_authorPreview, preview),
                                onAccountsChanged: _load,
                                actionsEnabled:
                                    _entryActive && preview.isCurrent,
                                feedbackCurrent: _entryActive,
                                accountIdentity: widget.accountIdentity,
                                isLoggedIn: widget.isLoggedIn,
                                writeBookmark: (id, {required isAdding}) =>
                                    widget.writeBookmark(id,
                                        isAdding: isAdding, isPrivate: false),
                                onOpenDetail: () =>
                                    _openWork(work, recommendation: false),
                              ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        if (preview.busy)
          const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(minHeight: 2)),
        if (!preview.busy && preview.error != null)
          TextButton.icon(
            key: ValueKey('pixiv-author-preview-retry-${data.id}'),
            onPressed: preview.isCurrent ? preview.load : null,
            icon: const Icon(Icons.refresh),
            label: const Text('重试作者作品'),
          )
        else if (!preview.busy && preview.hasMore && preview.attempted)
          TextButton(
            onPressed: preview.isCurrent ? preview.load : null,
            child: const Text('继续加载作者作品'),
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
    _queueMissingAvatar(active);
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

  Widget _loadingPreview(BuildContext context, PixivDetailPreview preview) {
    Widget imageFor(ImageProvider<Object> provider,
            {bool allowFallback = true}) =>
        Image(
          key: ValueKey(('pixiv-metadata-preview', provider)),
          image: provider,
          fit: BoxFit.contain,
          alignment: Alignment.topCenter,
          excludeFromSemantics: true,
          frameBuilder: (_, child, frame, synchronous) =>
              frame != null || synchronous
                  ? child
                  : const Center(child: CircularProgressIndicator()),
          errorBuilder: (_, __, ___) {
            final fallback = preview.fallbackProvider;
            if (allowFallback && fallback != null && fallback != provider) {
              return imageFor(fallback, allowFallback: false);
            }
            return const Center(
                child: Icon(Icons.image_not_supported_outlined, size: 48));
          },
        );
    final ratio = preview.aspectRatio.isFinite && preview.aspectRatio > 0
        ? preview.aspectRatio
        : .75;
    return Scaffold(
      body: SafeArea(
        child: Stack(children: [
          SingleChildScrollView(
            child: Semantics(
              image: true,
              label: '作品封面预览',
              child: AspectRatio(
                  aspectRatio: ratio, child: imageFor(preview.provider)),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            child: IconButton(
              tooltip: '返回',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back,
                  color: Colors.white,
                  shadows: [Shadow(color: Colors.black, blurRadius: 3)]),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: Material(
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: _error == null
                    ? Semantics(liveRegion: true, child: const Text('正在加载作品详情'))
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        const Text('作品详情加载失败'),
                        IconButton(
                            tooltip: '重试详情',
                            onPressed: _load,
                            icon: const Icon(Icons.refresh)),
                      ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildContent(BuildContext context, bool active) {
    final feedback = PixivBookmarkFeedbackHost.maybeOf(context);
    final feedbackCurrent = active && (feedback?.isCurrent ?? false);
    if (_loading || _data == null) {
      final preview = _preview;
      if (preview != null) {
        return _loadingPreview(context, preview);
      }
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
    return NotificationListener<ScrollNotification>(
      key: ValueKey('pixiv-related-pull-${data.id}'),
      onNotification: _onRecommendationScroll,
      child: PixivDetailShell(
        title: data.title.trim().isEmpty ? '作品 ${data.id}' : data.title,
        author: _authorName,
        galleryCollapsible: data.pageCount > 1,
        showDetailsForShortGallery: true,
        deferHeaderUntilImageReady: true,
        showSingleAuthorAvatar: true,
        imageReadinessIdentity: (_account, data.id, _generation),
        authorAvatarUrl: _authorAvatar,
        authorAvatarFallbackUrl: data.authorAvatar.trim(),
        authorAvatarLoading: _authorLoading && _authorAvatar.isEmpty,
        authorAvatarError: _authorAvatar.isEmpty ? _authorError : null,
        onRetryAuthorAvatar: _retryAuthor,
        onGalleryExpansionChanged: (expanded) {
          if (mounted && _galleryExpanded != expanded) {
            setState(() => _galleryExpanded = expanded);
          }
        },
        images: _displayImages,
        imagesLoading: _imagesLoading,
        imageError: _imageError,
        onRetryImages: _retryImages,
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
                    onPressed: _retryImages,
                    icon: const Icon(Icons.refresh),
                    label: Text(_imageError!)),
            ]),
          )),
          const PixivDetailFavoriteBoundary(),
          PixivDetailViewportTrigger(
            key: ValueKey(('author-load', _authorPreview, active)),
            onVisible: active ? _loadVisibleAuthor : null,
          ),
          SliverToBoxAdapter(child: _authorCard(context, data)),
          if (source != null && _discovery != null && !_discovery!.dismissed)
            SliverToBoxAdapter(
              key: ValueKey(('follow-discovery', _discovery)),
              child: PixivFollowRecommendationsInline(
                controller: _discovery!,
                source: source,
                bookmarks: _bookmarks,
                active: active && feedbackCurrent,
                writeBookmark: (id, {required isAdding}) => widget
                    .writeBookmark(id, isAdding: isAdding, isPrivate: false),
                accountIdentity: () => _account,
                isLoggedIn:
                    widget.isLoggedIn ?? () => PixivNetwork().isLoggedIn,
                onAccountsChanged: _load,
                onOpenWork: (work, works) =>
                    unawaited(_openDiscoveryWork(_discovery!, work, works)),
              ),
            ),
          PixivCommentsSection(
            key: ValueKey('comments-${data.id}'),
            illustId: data.id,
            commentsDisabled: data.commentsDisabled == true,
            autoLoad: true,
            previewLimit: 4,
            loadRoots: widget.loadCommentRoots,
            loadReplies: widget.loadCommentReplies,
          ),
          if (source != null && _galleryExpanded)
            ..._recommendationSlivers(context, source, active, feedbackCurrent),
        ],
      ),
    );
  }
}
