import 'package:flutter/material.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/pixiv_detail_preview.dart';
import 'package:picakeep/foundation/pixiv_local_detail.dart';
import 'package:picakeep/foundation/pixiv_detail_session.dart';
import 'package:picakeep/pages/local_comic_detail_page.dart';

Future<void> openPixivDetailSession(
  BuildContext context,
  PixivDetailSession session,
  String initialKey,
) async {
  try {
    await Navigator.of(context).push<void>(AppPageRoute(
      builder: (_) =>
          PixivDetailPager(session: session, initialKey: initialKey),
    ));
  } finally {
    session.dispose();
  }
}

String pixivLocalDetailKey(DownloadedItem item) =>
    'local:${item.id}:${item.fileSystemPath ?? item.directory ?? ''}';

Future<void> openLocalPixivDetail(
  BuildContext context,
  DownloadedItem item, {
  required Iterable<DownloadedItem> items,
  required PixivDetailScope scope,
  String? localFavoriteFolder,
}) async {
  if (PixivLocalIdentity.fromItem(item) == null) {
    await App.pushInner(() => LocalComicDetailPage(comic: item));
    return;
  }
  final session = PixivDetailSession(
    scope: scope,
    localFavoriteFolder: localFavoriteFolder,
    entries: [
      for (final value in items)
        if (PixivLocalIdentity.fromItem(value) != null)
          PixivDetailEntry(
            key: pixivLocalDetailKey(value),
            comicId: PixivLocalIdentity.fromItem(value)!.workId ?? value.id,
            builder: (_) => LocalComicDetailPage(comic: value),
          ),
    ],
  );
  if (session.indexOf(pixivLocalDetailKey(item)) < 0) {
    session.dispose();
    await App.pushInner(() => LocalComicDetailPage(comic: item));
    return;
  }
  try {
    await App.pushInner(() => PixivDetailPager(
          session: session,
          initialKey: pixivLocalDetailKey(item),
        ));
  } finally {
    session.dispose();
  }
}

class PixivDetailPager extends StatefulWidget {
  const PixivDetailPager({
    super.key,
    required this.session,
    required this.initialKey,
    this.prefetchCover,
  });

  final PixivDetailSession session;
  final String initialKey;
  final Future<void> Function(PixivDetailPreview preview)? prefetchCover;

  @override
  State<PixivDetailPager> createState() => _PixivDetailPagerState();
}

class _PixivDetailPagerState extends State<PixivDetailPager> {
  late int _current = widget.session.indexOf(widget.initialKey).clamp(0,
      widget.session.entries.isEmpty ? 0 : widget.session.entries.length - 1);
  late PageController _controller = PageController(initialPage: _current);
  late final _retainedIndex = ValueNotifier<int>(_current);
  PixivDetailCoverPrefetchQueue? _coverPrefetchQueue;
  bool _coverPrefetchScheduled = false;
  int _coverPrefetchEpoch = 0;

  bool get _canPrefetchCovers =>
      mounted &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      (widget.session.ownerIsCurrent?.call() ?? true);

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
    _scheduleCoverPrefetch();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_canPrefetchCovers) {
      _scheduleCoverPrefetch();
    } else {
      _stopCoverPrefetch();
    }
  }

  @override
  void didUpdateWidget(covariant PixivDetailPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_changed);
      widget.session.addListener(_changed);
      _current = widget.session.indexOf(widget.initialKey).clamp(
          0,
          widget.session.entries.isEmpty
              ? 0
              : widget.session.entries.length - 1);
      final previousController = _controller;
      _controller = PageController(initialPage: _current);
      previousController.dispose();
      _retainedIndex.value = _current;
    }
    if (oldWidget.session != widget.session ||
        oldWidget.prefetchCover != widget.prefetchCover) {
      _stopCoverPrefetch();
      _scheduleCoverPrefetch();
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _scheduleCoverPrefetch();
  }

  void _scheduleCoverPrefetch() {
    _coverPrefetchQueue?.clearCandidates();
    if (_coverPrefetchScheduled) return;
    _coverPrefetchScheduled = true;
    final epoch = _coverPrefetchEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _coverPrefetchEpoch) return;
      _coverPrefetchScheduled = false;
      if (!_canPrefetchCovers) {
        _stopCoverPrefetch();
        return;
      }
      final session = widget.session;
      final cancellation = PixivDetailCoverPrefetchCancellation();
      _coverPrefetchQueue ??= PixivDetailCoverPrefetchQueue(
        cancellation: cancellation,
        ownerIsCurrent: () =>
            mounted && widget.session == session && _canPrefetchCovers,
        loadCover: (preview) {
          final injected = widget.prefetchCover;
          if (injected != null) return injected(preview);
          return warmPixivDetailCover(
            preview,
            createLocalImageConfiguration(context),
            ownerIsCurrent: () =>
                mounted && widget.session == session && _canPrefetchCovers,
            cancellation: cancellation,
          );
        },
      );
      _coverPrefetchQueue!.replaceCandidates([
        for (final entry
            in pixivDetailNeighborCandidates(session.entries, _current))
          if (entry.preview != null &&
              entry.preview!.workId == entry.comicId &&
              entry.preview!.isCurrent)
            entry.preview!,
      ]);
    });
  }

  void _stopCoverPrefetch() {
    _coverPrefetchEpoch++;
    _coverPrefetchScheduled = false;
    _coverPrefetchQueue?.dispose();
    _coverPrefetchQueue = null;
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    _stopCoverPrefetch();
    _controller.dispose();
    _retainedIndex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final entries = session.entries;
    return PixivDetailSessionScope(
      session: session,
      child: Stack(children: [
        KeyedSubtree(
          // A new session must also release the old PageView keep-alive bucket.
          key: ObjectKey(session),
          child: PageView.builder(
            key: const Key('pixiv-work-pager'),
            controller: _controller,
            itemCount: entries.length + (session.hasMore ? 1 : 0),
            onPageChanged: (index) {
              setState(() => _current = index);
              _retainedIndex.value = index;
              _scheduleCoverPrefetch();
              if (index >= entries.length) session.requestMore();
            },
            itemBuilder: (context, index) {
              if (index == entries.length) {
                return Scaffold(
                  appBar: AppBar(),
                  body: Center(
                    child: session.busy
                        ? const CircularProgressIndicator()
                        : TextButton.icon(
                            onPressed: session.requestMore,
                            icon: const Icon(Icons.refresh),
                            label: Text(session.error ?? '加载下一批'),
                          ),
                  ),
                );
              }
              final entry = entries[index];
              return _RetainedPixivDetailEntry(
                key: ValueKey((session, entry.key)),
                entry: entry,
                index: index,
                currentIndex: _retainedIndex,
              );
            },
          ),
        ),
        if (session.error != null && !session.hasMore)
          Positioned(
            left: 16,
            right: 88,
            bottom: MediaQuery.paddingOf(context).bottom + 80,
            child: IgnorePointer(
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(session.error!, textAlign: TextAlign.center),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Keep visited neighbours without retaining every work browsed in the route.
/// The range notifier also reaches entries in the sliver's keep-alive bucket,
/// so eviction does not depend on PageView rebuilding an offscreen item slot.
class _RetainedPixivDetailEntry extends StatefulWidget {
  const _RetainedPixivDetailEntry({
    super.key,
    required this.entry,
    required this.index,
    required this.currentIndex,
  });

  final PixivDetailEntry entry;
  final int index;
  final ValueNotifier<int> currentIndex;

  @override
  State<_RetainedPixivDetailEntry> createState() =>
      _RetainedPixivDetailEntryState();
}

class _RetainedPixivDetailEntryState extends State<_RetainedPixivDetailEntry>
    with AutomaticKeepAliveClientMixin<_RetainedPixivDetailEntry> {
  @override
  bool get wantKeepAlive =>
      (widget.index - widget.currentIndex.value).abs() <= 1;

  @override
  void initState() {
    super.initState();
    widget.currentIndex.addListener(_rangeChanged);
  }

  @override
  void didUpdateWidget(covariant _RetainedPixivDetailEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      oldWidget.currentIndex.removeListener(_rangeChanged);
      widget.currentIndex.addListener(_rangeChanged);
    }
    updateKeepAlive();
  }

  void _rangeChanged() {
    if (!mounted) return;
    // Update both the keep-alive handle and the child activity/body. A far
    // entry releases its expensive detail state even before its slot is swept.
    setState(() {});
    updateKeepAlive();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!wantKeepAlive) return const SizedBox.expand();
    final active = widget.index == widget.currentIndex.value;
    return KeyedSubtree(
      // Preserve the entry's public subtree key used by restoration and fixtures.
      key: ValueKey(widget.entry.key),
      child: TickerMode(
        enabled: active,
        child: PixivDetailEntryScope(
          entry: widget.entry,
          isActive: active,
          child: Builder(builder: widget.entry.builder),
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.currentIndex.removeListener(_rangeChanged);
    super.dispose();
  }
}
