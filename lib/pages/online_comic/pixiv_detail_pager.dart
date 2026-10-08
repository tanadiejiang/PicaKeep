import 'package:flutter/material.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download_model.dart';
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
  });

  final PixivDetailSession session;
  final String initialKey;

  @override
  State<PixivDetailPager> createState() => _PixivDetailPagerState();
}

class _PixivDetailPagerState extends State<PixivDetailPager> {
  late int _current = widget.session.indexOf(widget.initialKey).clamp(0,
      widget.session.entries.isEmpty ? 0 : widget.session.entries.length - 1);
  late final PageController _controller = PageController(initialPage: _current);

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final entries = session.entries;
    return PixivDetailSessionScope(
      session: session,
      child: Stack(children: [
        PageView.builder(
          key: const Key('pixiv-work-pager'),
          controller: _controller,
          itemCount: entries.length + (session.hasMore ? 1 : 0),
          onPageChanged: (index) {
            setState(() => _current = index);
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
            // Evict distant detail states, including their requests/listeners.
            if ((index - _current).abs() > 1) return const SizedBox.expand();
            final entry = entries[index];
            return KeyedSubtree(
              key: ValueKey(entry.key),
              child: TickerMode(
                enabled: index == _current,
                child: PixivDetailEntryScope(
                  entry: entry,
                  isActive: index == _current,
                  child: Builder(builder: entry.builder),
                ),
              ),
            );
          },
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
