import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/tools/extensions.dart';

bool canHandleLocal(String text) {
  if (!text.isURL) return false;
  final uri = Uri.tryParse(text);
  if (uri == null) return false;
  final host = uri.host;
  if (host.contains('picacomic.com') || host.contains('picacg')) {
    return _extractPicacgId(uri) != null;
  }
  if (host.contains('e-hentai.org') || host.contains('exhentai.org')) {
    return uri.path.contains('/g/');
  }
  if (host.contains('nhentai.net') || host.contains('nhentai')) {
    return uri.path.contains('/g/');
  }
  if (host.contains('18comic') || host.contains('jmcomic')) {
    return _extractJmId(uri) != null;
  }
  if (host.contains('hitomi.la')) return _extractHitomiId(uri) != null;
  return false;
}

String? _extractPicacgId(Uri uri) =>
    RegExp(r'([a-fA-F0-9]{24})').firstMatch(uri.path)?.group(1);
String? _extractEhId(Uri uri) {
  final m = RegExp(r'/g/(\d+)/(\w+)').firstMatch(uri.path);
  return m != null ? '${m.group(1)}-${m.group(2)}' : null;
}

String? _extractNhentaiId(Uri uri) =>
    RegExp(r'/g/(\d+)').firstMatch(uri.path)?.group(1);
String? _extractJmId(Uri uri) {
  final m = RegExp(r'(?:album|photo|book)/(\d+)').firstMatch(uri.path);
  if (m != null) return m.group(1);
  for (final seg in uri.pathSegments) {
    if (seg.isNum) return seg;
  }
  return null;
}

String? _extractHitomiId(Uri uri) {
  final m =
      RegExp(r'/(?:doujinshi|manga|cg|reader)/(\d+)').firstMatch(uri.path);
  if (m != null) return m.group(1);
  for (final seg in uri.pathSegments) {
    if (seg.nums.isNotEmpty) return seg.nums;
  }
  return null;
}

class _ParsedLink {
  final String dlId;
  final String rawId;
  final FavoriteType favType;
  final String sourceName;
  _ParsedLink(
      {required this.dlId,
      required this.rawId,
      required this.favType,
      required this.sourceName});
}

_ParsedLink? _parseUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final host = uri.host;
  if (host.contains('picacomic.com') || host.contains('picacg')) {
    final id = _extractPicacgId(uri);
    if (id != null) {
      return _ParsedLink(
          dlId: id,
          rawId: id,
          favType: FavoriteType.picacg,
          sourceName: 'Picacg');
    }
  }
  if (host.contains('e-hentai.org') || host.contains('exhentai.org')) {
    final id = _extractEhId(uri);
    if (id != null) {
      return _ParsedLink(
          dlId: id,
          rawId: id,
          favType: FavoriteType.ehentai,
          sourceName: 'E-Hentai');
    }
  }
  if (host.contains('nhentai.net') || host.contains('nhentai')) {
    final id = _extractNhentaiId(uri);
    if (id != null) {
      return _ParsedLink(
          dlId: 'nhentai$id',
          rawId: id,
          favType: FavoriteType.nhentai,
          sourceName: 'NHentai');
    }
  }
  if (host.contains('18comic') || host.contains('jmcomic')) {
    final id = _extractJmId(uri);
    if (id != null) {
      return _ParsedLink(
          dlId: 'jm$id', rawId: id, favType: FavoriteType.jm, sourceName: '禁漫');
    }
  }
  if (host.contains('hitomi.la')) {
    final id = _extractHitomiId(uri);
    if (id != null) {
      return _ParsedLink(
          dlId: 'hitomi$id',
          rawId: id,
          favType: FavoriteType.hitomi,
          sourceName: 'Hitomi');
    }
  }
  return null;
}

Future<void> handleLocalAppLinks(String url) async {
  final parsed = _parseUrl(url);
  if (parsed == null) return;
  String? foundName;
  try {
    final m = DownloadManager();
    await m.init();
    final c = await m.getComicOrNull(parsed.dlId);
    if (c != null) foundName = c.name;
  } catch (_) {}
  if (foundName == null) {
    for (final item in LocalFavoritesManager().allComics()) {
      if (item.comic.target == parsed.rawId &&
          item.comic.type == parsed.favType) {
        foundName = item.comic.name;
        break;
      }
    }
  }
  final context = App.globalContext;
  if (context == null || !context.mounted) return;
  if (foundName != null) {
    await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('在本地找到'),
                content: Text('在本地找到：$foundName'),
                actions: [
                  TextButton(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('打开: $foundName')));
                      },
                      child: const Text('确定'))
                ]));
  } else {
    await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('本地未找到匹配的漫画'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('确定'))
                ]));
  }
}

Future<void> checkLocalClipboard() async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final text = data?.text;
  if (text == null || !text.isURL) return;
  if (canHandleLocal(text)) await handleLocalAppLinks(text);
}
