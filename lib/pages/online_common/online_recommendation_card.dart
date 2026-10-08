import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/components/pixiv_bookmark_button.dart';
import 'package:picakeep/components/pixiv_bookmark_feedback.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/foundation/pixiv_bookmark_state.dart';
import 'package:picakeep/foundation/comic_tile_display_config.dart';
import 'package:picakeep/foundation/download_author_resolver.dart';
import 'package:picakeep/network/base_comic.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/pixiv_network/pixiv_parsing.dart'
    show pixivProportionalThumbUrl;
import 'package:picakeep/network/res.dart';
import 'package:picakeep/pages/accounts/account_page_route.dart';
import 'package:picakeep/pages/online_comic/pixiv_author_page_v2.dart';
import 'online_comic_list_item.dart';
import 'online_waterfall_card.dart';

class _BookmarkState {
  _BookmarkState(this.input, this.value)
      : stateKnown = input.bookmarkStateKnown,
        canAdd = input.isBookmarkable {
    observedInputs[input] = true;
  }
  PixivComicBrief input;
  Expando<bool> observedInputs = Expando<bool>();
  bool value;
  bool stateKnown;
  bool canAdd;
  bool confirmed = false;
  bool busy = false;
  int revision = 0;
  int sharedRevision = -1;
}

/// A feed owns this controller so the same work in different sections shares
/// confirmed bookmark state and a single write lock. Production controllers
/// also retain account confirmations across feeds and resolve visible unknowns.
class RecommendationBookmarkController extends ChangeNotifier {
  RecommendationBookmarkController({
    PixivBookmarkStateStore? store,
    this.resolveUnknownStates = false,
  }) : _store = store {
    _store?.addListener(_onSharedChanged);
  }

  RecommendationBookmarkController.shared()
      : this(store: PixivBookmarkStateStore.shared, resolveUnknownStates: true);

  final PixivBookmarkStateStore? _store;
  final bool resolveUnknownStates;
  final Map<String, _BookmarkState> _states = {};
  bool _disposed = false;
  int _generation = 0;

  String _key(String account, String id) => '$account\u0000$id';

  _BookmarkState _state(String account, PixivComicBrief comic) {
    final key = _key(account, comic.id);
    final value = _states.putIfAbsent(
        key, () => _BookmarkState(comic, comic.isBookmarked));
    if (!identical(value.input, comic)) {
      final isNewInput = value.observedInputs[comic] != true;
      value.observedInputs[comic] = true;
      final incomingConflicts = isNewInput &&
          _store?.stateFor(account, comic.id) == null &&
          comic.bookmarkStateKnown &&
          (!value.stateKnown ||
              comic.isBookmarked != value.value ||
              comic.isBookmarkable != value.canAdd);
      // Old cards keep rendering their original briefs after a confirmed
      // toggle. Only a newly observed known snapshot can supersede that state;
      // weak identity tracking avoids retaining every loaded brief forever.
      if (incomingConflicts) value.revision++;
      if (isNewInput && (comic.bookmarkStateKnown || !value.stateKnown)) {
        value.input = comic;
      }
      // Different pages may provide an unknown brief for the same work.
      // Rendering that brief must neither downgrade a known state nor cancel
      // a pending request owned by another card.
      if (isNewInput &&
          !value.confirmed &&
          !value.busy &&
          (comic.bookmarkStateKnown || !value.stateKnown)) {
        value.value = comic.isBookmarked;
        value.stateKnown = comic.bookmarkStateKnown;
        value.canAdd = comic.isBookmarkable;
      }
    }
    _applySharedState(account, comic.id, value);
    return value;
  }

  void _applySharedState(String account, String id, _BookmarkState value) {
    final shared = _store?.stateFor(account, id);
    final revision = _store?.revisionFor(account, id) ?? -1;
    if (shared == null || value.busy || revision == value.sharedRevision) {
      return;
    }
    value.sharedRevision = revision;
    value.value = shared.isBookmarked;
    value.canAdd = shared.isBookmarkable;
    value.stateKnown = true;
    value.confirmed = true;
    value.revision++;
  }

  void _onSharedChanged() {
    if (_disposed) return;
    for (final entry in _states.entries) {
      final separator = entry.key.indexOf('\u0000');
      _applySharedState(entry.key.substring(0, separator),
          entry.key.substring(separator + 1), entry.value);
    }
    notifyListeners();
  }

  Future<void> ensureConfirmedState({
    required String account,
    required PixivComicBrief comic,
    required Future<Res<PixivBookmarkState>> Function(String id) readState,
    required bool Function() isCurrentAccount,
  }) async {
    if (_disposed || !resolveUnknownStates || account.isEmpty) return;
    final unknown = !comic.bookmarkStateKnown && comic.canLoadBookmarkState;
    final stale = _store?.stateFor(account, comic.id) != null &&
        !(_store?.isFresh(account, comic.id) ?? false);
    if (!unknown && !stale) return;
    await _store?.resolve(
        account: account,
        id: comic.id,
        readState: readState,
        isCurrentAccount: () => !_disposed && isCurrentAccount());
  }

  bool isBookmarked(String account, PixivComicBrief comic) =>
      _state(account, comic).value;
  bool isBusy(String account, PixivComicBrief comic) =>
      _state(account, comic).busy;

  bool isStateKnown(String account, PixivComicBrief comic) =>
      _state(account, comic).stateKnown;

  bool canToggle(String account, PixivComicBrief comic) {
    final value = _state(account, comic);
    return value.value ||
        value.canAdd ||
        (!value.stateKnown && comic.canLoadBookmarkState);
  }

  void synchronizeConfirmedState({
    required String account,
    required PixivComicBrief comic,
    required PixivBookmarkState state,
  }) {
    if (_disposed) return;
    final value = _state(account, comic);
    if (value.busy) return;
    value.value = state.isBookmarked;
    value.canAdd = state.isBookmarkable;
    value.stateKnown = true;
    value.confirmed = true;
    value.revision++;
    _store?.confirm(account, comic.id, state);
    notifyListeners();
  }

  /// Read the detail authority without allowing a late response to overwrite a
  /// newer toggle, feed reset, account, or card identity.
  Future<void> refreshConfirmedState({
    required String account,
    required PixivComicBrief comic,
    required Future<Res<PixivBookmarkState>> Function(String id) readState,
    required bool Function() isCurrentAccount,
  }) async {
    if (_disposed || !isCurrentAccount()) return;
    final value = _state(account, comic);
    if (value.busy) return;
    final generation = _generation;
    final revision = value.revision;
    final sharedRevision = _store?.revisionFor(account, comic.id);
    try {
      final state = await readState(comic.id);
      if (_disposed ||
          generation != _generation ||
          revision != value.revision ||
          sharedRevision != _store?.revisionFor(account, comic.id) ||
          value.busy ||
          !isCurrentAccount() ||
          state.error) {
        return;
      }
      synchronizeConfirmedState(
          account: account, comic: comic, state: state.data);
    } catch (_) {
      // Keep the previously confirmed state when the read is unavailable.
    }
  }

  Future<Res<bool>?> toggle({
    required String account,
    required PixivComicBrief comic,
    Future<Res<PixivBookmarkState>> Function(String id)? readState,
    required Future<Res<bool>> Function(String, {required bool isAdding}) write,
    required bool Function() isCurrentAccount,
  }) async {
    if (_disposed) return null;
    final value = _state(account, comic);
    if (value.busy || !isCurrentAccount() || !canToggle(account, comic)) {
      return null;
    }
    final generation = _generation;
    final revision = ++value.revision;
    bool isCurrent() =>
        !_disposed &&
        generation == _generation &&
        revision == value.revision &&
        isCurrentAccount();
    value.busy = true;
    notifyListeners();
    Res<bool>? result;
    bool? target;
    try {
      if (!value.stateKnown) {
        Res<PixivBookmarkState> state;
        if (readState == null) {
          state = const Res.error('无法读取收藏状态');
        } else if (_store != null) {
          // Reuse the visible-card lookup instead of starting a duplicate GET
          // when the user taps before background confirmation has arrived.
          await _store.resolve(
              account: account,
              id: comic.id,
              readState: readState,
              isCurrentAccount: isCurrent);
          final confirmed = _store.stateFor(account, comic.id);
          state = confirmed == null
              ? const Res.error('无法读取收藏状态，请稍后重试')
              : Res(confirmed);
        } else {
          state = await readState(comic.id);
        }
        if (isCurrent()) {
          if (state.error) {
            result = Res.fromErrorRes(state);
          } else {
            value.value = state.data.isBookmarked;
            value.canAdd = state.data.isBookmarkable;
            value.stateKnown = true;
            // A failed write must retain the state confirmed by this read.
            value.confirmed = true;
          }
        }
      }
      if (isCurrent() && result == null && value.stateKnown) {
        target = !value.value;
        if (target && !value.canAdd) {
          result = const Res.error('该作品当前不可收藏');
        } else {
          result = await write(comic.id, isAdding: target);
        }
      }
    } catch (_) {
      result = const Res.error('暂时无法连接 Pixiv，请检查网络后重试');
    }
    if (_disposed) return null;
    value.busy = false;
    if (!isCurrent()) {
      value.value = value.input.isBookmarked;
      value.stateKnown = value.input.bookmarkStateKnown;
      value.canAdd = value.input.isBookmarkable;
      value.confirmed = false;
      value.sharedRevision = -1;
      _applySharedState(account, comic.id, value);
      notifyListeners();
      return null;
    }
    if (result?.success == true && target != null) {
      value.value = target;
      value.stateKnown = true;
      value.confirmed = true;
      // Real network writes already publish the latest capability/privacy.
      // Preserve that authority; injected writers still publish here.
      if (_store?.stateFor(account, comic.id)?.isBookmarked != target) {
        _store?.confirm(
            account,
            comic.id,
            PixivBookmarkState(
                isBookmarked: target, isBookmarkable: value.canAdd));
      }
    }
    _applySharedState(account, comic.id, value);
    notifyListeners();
    return result == null || result.error ? result : Res(target!);
  }

  /// Refresh/replaced-account data becomes the next authoritative state.
  void reset({bool preserveConfirmed = false}) {
    if (_disposed) return;
    _generation++;
    // Keep pending locks until their requests settle, even if a refresh begins.
    if (!preserveConfirmed) {
      _states.removeWhere((_, value) => !value.busy);
      for (final value in _states.values) {
        value.confirmed = false;
        value.observedInputs = Expando<bool>();
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _store?.removeListener(_onSharedChanged);
    super.dispose();
  }
}

/// Adapts source metadata and Pixiv-only account actions to the shared card.
class OnlineRecommendationCard extends StatefulWidget {
  const OnlineRecommendationCard({
    super.key,
    required this.source,
    required this.comic,
    required this.bookmarks,
    required this.onAccountsChanged,
    this.onDataRefresh,
    this.actionsEnabled = true,
    this.feedbackCurrent = true,
    this.blockedBy,
    this.accountIdentity,
    this.isLoggedIn,
    this.writeBookmark,
    this.loadBookmarkState,
    this.manageAccounts,
    this.onOpenDetail,
    this.onOpenAuthor,
    this.detailSessionBuilder,
    this.isAuthorPage = false,
  });

  final ComicSource source;
  final BaseComic comic;
  final RecommendationBookmarkController bookmarks;
  final VoidCallback onAccountsChanged;
  final Future<void> Function()? onDataRefresh;
  final bool actionsEnabled;
  final bool feedbackCurrent;
  final String? blockedBy;
  final String Function()? accountIdentity;
  final bool Function()? isLoggedIn;
  final Future<Res<bool>> Function(String id, {required bool isAdding})?
      writeBookmark;
  final Future<Res<PixivBookmarkState>> Function(String id)? loadBookmarkState;
  final Future<void> Function(BuildContext)? manageAccounts;
  final VoidCallback? onOpenDetail;
  final ValueChanged<String>? onOpenAuthor;
  final PixivDetailSession Function()? detailSessionBuilder;
  final bool isAuthorPage;

  @override
  State<OnlineRecommendationCard> createState() =>
      _OnlineRecommendationCardState();
}

class _OnlineRecommendationCardState extends State<OnlineRecommendationCard> {
  bool _openingAccounts = false;
  int _generation = 0;
  int _detailGeneration = 0;
  bool _resolutionScheduled = false;
  int _eventSequence = 0;
  int _operationSequence = 0;
  PixivBookmarkEvent? _bookmarkEvent;
  PixivBookmarkFeedbackTicket? _eventTicket;

  String get _account =>
      widget.accountIdentity?.call() ??
      pixivBookmarkAccountIdentity(widget.source);
  bool get _loggedIn => widget.isLoggedIn?.call() ?? widget.source.isLoggedIn;
  PixivComicBrief? get _pixiv {
    if (widget.source.key.toLowerCase() != 'pixiv') return null;
    return widget.comic is PixivComicBrief
        ? widget.comic as PixivComicBrief
        : null;
  }

  @override
  void initState() {
    super.initState();
    widget.bookmarks.addListener(_onBookmarkChanged);
  }

  @override
  void didUpdateWidget(covariant OnlineRecommendationCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookmarks != widget.bookmarks) {
      oldWidget.bookmarks.removeListener(_onBookmarkChanged);
      widget.bookmarks.addListener(_onBookmarkChanged);
      _generation++;
      _detailGeneration++;
      _openingAccounts = false;
    }
    if (oldWidget.comic.id != widget.comic.id ||
        oldWidget.source != widget.source) {
      _generation++;
      _detailGeneration++;
      _openingAccounts = false;
    }
    if (oldWidget.actionsEnabled && !widget.actionsEnabled) {
      _generation++;
      _openingAccounts = false;
    }
  }

  @override
  void dispose() {
    _generation++;
    _detailGeneration++;
    widget.bookmarks.removeListener(_onBookmarkChanged);
    super.dispose();
  }

  void _onBookmarkChanged() {
    if (mounted) setState(() {});
  }

  void _message(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _toggleBookmark() async {
    final comic = _pixiv;
    if (!widget.actionsEnabled ||
        comic == null ||
        !widget.bookmarks.canToggle(_account, comic) ||
        _openingAccounts) {
      return;
    }
    final account = _account;
    final generation = _generation;
    if (widget.bookmarks.isBusy(account, comic)) return;
    if (!_loggedIn) {
      setState(() => _openingAccounts = true);
      try {
        await (widget.manageAccounts?.call(context) ??
            showAccountsPage(context));
      } catch (_) {
        if (mounted && generation == _generation) {
          _message('暂时无法打开账号管理，请重试');
        }
      }
      if (!mounted || generation != _generation) return;
      setState(() => _openingAccounts = false);
      widget.onAccountsChanged();
      return;
    }
    final host = PixivBookmarkFeedbackHost.maybeOf(context);
    final ticket = host?.capture(account: account, workId: comic.id);
    final operationId = ++_operationSequence;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    bool feedbackCurrent() =>
        mounted && widget.feedbackCurrent && (ticket?.isCurrent ?? true);
    PixivBookmarkEvent? beginEvent;
    void emit(PixivBookmarkPhase phase, {bool? target, bool success = true}) {
      if (!feedbackCurrent()) return;
      setState(() {
        _eventTicket = ticket;
        _bookmarkEvent = PixivBookmarkEvent(
          sequence: ++_eventSequence,
          operationId: operationId,
          phase: phase,
          target: target,
          success: success,
          begin: phase == PixivBookmarkPhase.settle ? beginEvent : null,
        );
        if (phase == PixivBookmarkPhase.begin) beginEvent = _bookmarkEvent;
      });
    }

    emit(PixivBookmarkPhase.accepted);
    ticket?.startWaiting(
      target: widget.bookmarks.isStateKnown(account, comic)
          ? !widget.bookmarks.isBookmarked(account, comic)
          : null,
    );
    if (feedbackCurrent() && !reducedMotion) {
      unawaited(HapticFeedback.selectionClick());
    }
    final writer = widget.writeBookmark ??
        (String id, {required bool isAdding}) =>
            PixivNetwork().setBookmark(id, isAdding: isAdding);
    final result = await widget.bookmarks.toggle(
      account: account,
      comic: comic,
      readState: widget.loadBookmarkState ??
          (id) => PixivNetwork().getBookmarkState(id),
      write: (id, {required isAdding}) {
        emit(PixivBookmarkPhase.begin, target: isAdding);
        ticket?.updateWaitingTarget(isAdding);
        return writer(id, isAdding: isAdding);
      },
      isCurrentAccount: () =>
          mounted &&
          generation == _generation &&
          identical(_pixiv, comic) &&
          widget.actionsEnabled &&
          _account == account &&
          _loggedIn,
    );
    if (!mounted ||
        generation != _generation ||
        _account != account ||
        !identical(_pixiv, comic) ||
        result == null) {
      ticket?.cancelWaiting();
      return;
    }
    emit(PixivBookmarkPhase.settle, success: result.success);
    ticket?.finish(result.error
        ? PixivBookmarkFeedbackMessage.failed(result.errorMessageWithoutNull)
        : result.data
            ? const PixivBookmarkFeedbackMessage.added()
            : const PixivBookmarkFeedbackMessage.removed());
  }

  void _openAuthor(String id) {
    final open = widget.onOpenAuthor;
    if (open != null) {
      open(id);
    } else {
      Navigator.of(context).push(AppPageRoute(
          builder: (_) => PixivAuthorPageV2(id, bookmarks: widget.bookmarks)));
    }
  }

  Future<void> _openDetail() async {
    final open = widget.onOpenDetail;
    if (open != null) {
      open();
      return;
    }
    final generation = ++_detailGeneration;
    final account = _account;
    final comic = _pixiv;
    bool isCurrent() =>
        mounted && generation == _detailGeneration && _account == account;
    await openOnlineComic(context, widget.source, widget.comic,
        detailSession: widget.detailSessionBuilder?.call());
    if (!isCurrent()) return;
    await widget.onDataRefresh?.call();
    if (!isCurrent() || comic == null || _pixiv?.id != comic.id || !_loggedIn) {
      return;
    }
    // A parent refresh temporarily disables actions, invalidating write UI
    // feedback. It must not invalidate this detail-return read for the same
    // account and work. The controller separately guards newer state changes.
    await widget.bookmarks.refreshConfirmedState(
      account: account,
      comic: comic,
      readState: widget.loadBookmarkState ??
          (id) => PixivNetwork().getBookmarkState(id),
      isCurrentAccount: () =>
          isCurrent() && _pixiv?.id == comic.id && _loggedIn,
    );
  }

  @override
  Widget build(BuildContext context) {
    final comic = widget.comic;
    final pixiv = _pixiv;
    _scheduleBookmarkResolution();
    final author = resolveSourceAuthors(
      source: widget.source.key,
      flatTags: comic.tags,
      fallbackAuthor: comic.subTitle,
    ).join(', ');
    final settings = readComicTileDisplaySettings();
    final headers = widget.source.imageHeadersBuilder?.call(comic) ??
        const <String, String>{};
    final card = OnlineWaterfallCard(
      title: comic.title,
      cover:
          pixiv == null ? comic.cover : pixivProportionalThumbUrl(comic.cover),
      fallbackCover: pixiv == null ? null : comic.cover,
      imageHeaders: headers,
      onTap: _openDetail,
      author: widget.isAuthorPage ? '' : author,
      authorAvatarUrl: widget.isAuthorPage ? '' : pixiv?.authorAvatar ?? '',
      showAuthorAvatar: !widget.isAuthorPage,
      onAuthorTap:
          !widget.isAuthorPage && pixiv != null && pixiv.authorId.isNotEmpty
              ? () => _openAuthor(pixiv.authorId)
              : null,
      pageCount: pixiv?.pageCount ?? 0,
      width: pixiv?.width,
      height: pixiv?.height,
      tags: comic.tags,
      tagConfig: widget.isAuthorPage
          ? settings.pixivAuthorTags
          : settings.recommendTags,
      onToggleFavorite:
          pixiv != null && widget.bookmarks.canToggle(_account, pixiv)
              ? _toggleBookmark
              : null,
      isFavorited: pixiv == null
          ? false
          : widget.bookmarks.isBookmarked(_account, pixiv),
      favoriteStateKnown:
          pixiv == null || widget.bookmarks.isStateKnown(_account, pixiv),
      favoriteEnabled: widget.actionsEnabled && !_openingAccounts,
      favoriteBusy: pixiv != null && widget.bookmarks.isBusy(_account, pixiv),
      favoriteStyle: settings.favoriteStyle,
      pixivBookmarkAnimations: pixiv != null,
      favoriteIdentity: (_account, comic.id),
      favoriteVisualEpoch:
          PixivBookmarkFeedbackHost.maybeOf(context)?.visualEpoch,
      favoriteFeedbackCurrent: widget.feedbackCurrent &&
          (PixivBookmarkFeedbackHost.maybeOf(context)?.isCurrent ?? true),
      favoriteEvent: (_eventTicket?.isCurrent ?? true) ? _bookmarkEvent : null,
    );
    if (widget.blockedBy == null) return card;
    return Opacity(
      opacity: .45,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        card,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          child: Text('已屏蔽：${widget.blockedBy}',
              style: Theme.of(context).textTheme.labelSmall),
        ),
      ]),
    );
  }

  void _scheduleBookmarkResolution() {
    if (_resolutionScheduled ||
        !widget.bookmarks.resolveUnknownStates ||
        !widget.actionsEnabled ||
        !_loggedIn ||
        _pixiv == null) {
      return;
    }
    _resolutionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !widget.actionsEnabled || !_loggedIn) {
        _resolutionScheduled = false;
        return;
      }
      final comic = _pixiv;
      if (comic == null) {
        _resolutionScheduled = false;
        return;
      }
      final account = _account;
      final controller = widget.bookmarks;
      await controller.ensureConfirmedState(
        account: account,
        comic: comic,
        readState: widget.loadBookmarkState ??
            (id) => PixivNetwork().getBookmarkState(id),
        isCurrentAccount: () =>
            mounted &&
            _account == account &&
            _loggedIn &&
            widget.actionsEnabled &&
            identical(controller, widget.bookmarks) &&
            _pixiv?.id == comic.id,
      );
      _resolutionScheduled = false;
      if (mounted &&
          (_account != account ||
              _pixiv?.id != comic.id ||
              !identical(controller, widget.bookmarks))) {
        _scheduleBookmarkResolution();
      }
    });
  }
}
