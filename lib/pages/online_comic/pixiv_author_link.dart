import 'package:flutter/material.dart';
import 'package:picakeep/foundation/app_page_route.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/res.dart';

import 'pixiv_author_page_v2.dart';

typedef PixivAuthorDetailLoader = Future<Res<PixivComicInfo>> Function(
    String id);

String? _numericId(String? value) {
  final id = value?.trim() ?? '';
  return RegExp(r'^[0-9]+$').hasMatch(id) && RegExp(r'[1-9]').hasMatch(id)
      ? id
      : null;
}

/// Persisted UID wins. An older download can resolve just this work on demand.
/// Display names and folder names are never used to infer identity.
class PixivAuthorDestination {
  const PixivAuthorDestination({this.authorId, this.comicId});

  final String? authorId;
  final String? comicId;

  static PixivAuthorDestination? fromDownloadedItem(DownloadedItem item) {
    DownloadedItem? record = item;
    if (item is LocalLibraryComicItem) {
      final raw = item.sourceRowJson;
      if (raw == null || raw.trim().isEmpty) return null;
      try {
        record = parseDownloadedItemRecordJson(item.originalId, raw);
      } catch (_) {
        return null;
      }
    }
    if (record is! CustomDownloadedItem ||
        record.sourceKey.trim().toLowerCase() != 'pixiv') {
      return null;
    }
    final id = record.id.trim();
    return PixivAuthorDestination(
      authorId: record.authorId,
      comicId: _numericId(record.comicId) ??
          _numericId(
              id.toLowerCase().startsWith('pixiv') ? id.substring(5) : id),
    );
  }

  Future<Res<String>> resolve({PixivAuthorDetailLoader? loadDetail}) async {
    final uid = _numericId(authorId);
    if (uid != null) return Res(uid);
    final id = _numericId(comicId);
    if (id == null) {
      return const Res.error('这条本地记录缺少作者 ID 和有效作品 ID，无法打开作者页');
    }
    try {
      final result =
          await (loadDetail?.call(id) ?? PixivNetwork().getComicInfo(id));
      if (result.error) {
        return Res.error('无法获取作者信息：${result.errorMessageWithoutNull}');
      }
      final resolved = _numericId(result.data.authorId);
      if (resolved == null) {
        return const Res.error('这件作品未返回有效作者 ID，暂时无法打开作者页');
      }
      return Res(resolved);
    } catch (_) {
      return const Res.error('无法获取作者信息，请检查网络后重试');
    }
  }
}

/// Shared local/online entry: a visible progress state prevents duplicate
/// requests; returning from the destination restores the action normally.
class PixivAuthorLink extends StatefulWidget {
  const PixivAuthorLink({
    super.key,
    required this.destination,
    this.authorName = '',
    this.compact = false,
    this.loadDetail,
    this.pageBuilder,
  });

  final PixivAuthorDestination destination;
  final String authorName;
  final bool compact;
  final PixivAuthorDetailLoader? loadDetail;
  final Widget Function(String uid)? pageBuilder;

  @override
  State<PixivAuthorLink> createState() => _PixivAuthorLinkState();
}

class _PixivAuthorLinkState extends State<PixivAuthorLink> {
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final result =
          await widget.destination.resolve(loadDetail: widget.loadDetail);
      if (!mounted) return;
      if (result.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.errorMessageWithoutNull)),
        );
        return;
      }
      await Navigator.of(context).push(AppPageRoute<void>(
        builder: (_) =>
            widget.pageBuilder?.call(result.data) ??
            PixivAuthorPageV2(result.data),
      ));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = _opening
        ? const SizedBox.square(
            dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(Icons.person_outline, color: colorScheme.primary);
    if (widget.compact) {
      return Semantics(
        button: true,
        label: '打开作者页',
        child: InkWell(
          onTap: _opening ? null : _open,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 72,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  icon,
                  const SizedBox(height: 8),
                  Text(_opening ? '正在打开' : '作者页',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelMedium),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: _opening ? null : _open,
        leading: icon,
        title: Text(
            widget.authorName.trim().isEmpty ? 'Pixiv 作者' : widget.authorName),
        subtitle: Text(_opening ? '正在获取作者信息…' : '打开作者页 · 浏览全部作品'),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}
