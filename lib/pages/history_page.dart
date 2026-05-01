import 'dart:io';

import 'package:flutter/material.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/components/scrollable.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/tools/read_history_helper.dart';
import 'package:picakeep/tools/translations.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final comics = <History>[];
  bool searchInit = false;
  bool searchMode = false;
  String keyword = "";
  final results = <History>[];

  @override
  void initState() {
    super.initState();
    comics.addAll(HistoryManager().getAll());
  }

  Widget buildTitle() {
    if (searchMode) {
      return TextField(
        autofocus: searchInit,
        decoration:
            InputDecoration(border: InputBorder.none, hintText: "搜索".tl),
        onChanged: (s) {
          setState(() {
            keyword = s.toLowerCase();
          });
        },
      );
    }
    return Text("${"历史记录".tl}(${comics.length})");
  }

  void find() {
    results.clear();
    if (keyword.isEmpty) {
      results.addAll(comics);
    } else {
      for (final element in comics) {
        if (element.title.toLowerCase().contains(keyword) ||
            element.subtitle.toLowerCase().contains(keyword)) {
          results.add(element);
        }
      }
    }
  }

  File _coverFile(History item) {
    final c = item.cover.trim();
    if (c.isNotEmpty && (c.startsWith('/') || c.contains(':\\'))) {
      final f = File(c);
      if (f.existsSync()) return f;
    }
    try {
      return DownloadManager().getCover(item.target);
    } catch (_) {
      return File('');
    }
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return "刚刚";
    if (diff.inMinutes < 60) return "${diff.inMinutes}分钟前";
    if (diff.inHours < 24) return "${diff.inHours}小时前";
    if (diff.inDays < 30) return "${diff.inDays}天前";
    if (diff.inDays < 365) return "${(diff.inDays / 30).floor()}个月前";
    return "${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}";
  }

  void _clearAll() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text("清除记录".tl),
        content: Text("要清除历史记录吗?".tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text("取消".tl),
          ),
          TextButton(
            onPressed: () {
              HistoryManager().clearHistory();
              setState(() {
                comics.clear();
              });
              Navigator.of(dialogContext).pop();
            },
            child: Text("清除".tl),
          ),
        ],
      ),
    );
  }

  Future<void> _openComic(History item) async {
    final comic = await DownloadManager().getComicOrNull(item.target);
    if (comic != null) {
      if (!mounted) return;
      await ensureHistoryBeforeRead(comic);
      if (!mounted) return;
      await App.openReader(() => comic.createReadingPage());
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("未找到该漫画".tl)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (searchMode) {
      find();
      if (searchInit) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => searchInit = false);
        });
      }
    }
    final list = searchMode ? results : comics;
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(
            title: buildTitle(),
            actions: [
              Tooltip(
                message: "清除".tl,
                child: IconButton(
                  icon: const Icon(Icons.delete_forever),
                  onPressed: comics.isEmpty ? null : _clearAll,
                ),
              ),
              Tooltip(
                message: "搜索".tl,
                child: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () {
                    setState(() {
                      searchMode = !searchMode;
                      searchInit = true;
                      if (!searchMode) {
                        keyword = "";
                      }
                    });
                  },
                ),
              ),
            ],
          ),
          if (list.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Center(child: Text("暂无历史记录".tl)),
              ),
            )
          else
            SliverGrid(
              delegate: SliverChildBuilderDelegate(
                childCount: list.length,
                (context, i) {
                  final comic = list[i];
                  final cover = _coverFile(comic);
                  return Padding(
                    padding: const EdgeInsets.all(2),
                    child: DownloadedComicTile(
                      name: comic.title,
                      author: comic.subtitle,
                      imagePath: cover.existsSync() ? cover : DownloadManager().getCover(comic.target),
                      type: comic.type.name,
                      tag: const [],
                      size: _formatTime(comic.time),
                      onTap: () => _openComic(comic),
                      onLongTap: () {
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text("删除".tl),
                            content: Text("要删除这条历史记录吗".tl),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                child: Text("取消".tl),
                              ),
                              TextButton(
                                onPressed: () {
                                  HistoryManager().remove(comic.target);
                                  setState(() {
                                    comics.removeWhere(
                                        (e) => e.target == comic.target);
                                  });
                                  Navigator.of(ctx).pop();
                                },
                                child: Text("删除".tl),
                              ),
                            ],
                          ),
                        );
                      },
                      onSecondaryTap: (_) {},
                    ),
                  );
                },
              ),
              gridDelegate: SliverGridDelegateWithComics(),
            ),
          SliverPadding(
            padding:
                EdgeInsets.only(top: MediaQuery.of(context).padding.bottom),
          ),
        ],
      ),
    );
  }
}
