// ignore_for_file: unused_element

import 'dart:io' show Platform, Process;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/state_controller.dart';
import 'package:picakeep/foundation/ui_mode.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:picakeep/components/comic_tile.dart';
import 'package:picakeep/components/scrollable.dart';
import 'package:picakeep/components/layout.dart';
import 'package:picakeep/components/components.dart';
import 'reader/comic_reading_page.dart';
import 'local_comic_detail_page.dart';

void _toComicInfoPage(BuildContext context, DownloadedItem comic) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => LocalComicDetailPage(comic: comic),
  ));
}

extension ReadComic on DownloadedItem {
  void read({int? ep, int? page}) {
    final hasEp = eps.isNotEmpty;
    final readingData = LocalReadingData(
      title: name,
      id: id,
      downloadId: id,
      sourceKey: _extractSourceKey(id),
      hasEp: hasEp,
      eps: hasEp ? {for (int i = 0; i < eps.length; i++) eps[i]: eps[i]} : null,
      favoriteType: _downloadTypeToFavoriteType(type),
    );

    Navigator.of(App.globalContext!).push(MaterialPageRoute(
      builder: (_) => ComicReadingPage(
        readingData,
        page ?? 1,
        ep ?? (hasEp ? 1 : 0),
      ),
    ));
  }
}

String _extractSourceKey(String id) {
  if (id.contains('copy_manga')) return 'copy_manga';
  if (id.contains('Komiic')) return 'Komiic';
  if (id.startsWith('jm')) return 'jm';
  if (id.startsWith('nhentai')) return 'nhentai';
  if (id.startsWith('hitomi')) return 'hitomi';
  if (id.startsWith('Ht')) return 'htmanga';
  if (RegExp(r'^\d+$').hasMatch(id)) return 'ehentai';
  return 'picacg';
}

FavoriteType _downloadTypeToFavoriteType(DownloadType type) {
  switch (type) {
    case DownloadType.picacg:
      return FavoriteType.picacg;
    case DownloadType.ehentai:
      return FavoriteType.ehentai;
    case DownloadType.jm:
      return FavoriteType.jm;
    case DownloadType.hitomi:
      return FavoriteType.hitomi;
    case DownloadType.htmanga:
      return FavoriteType.htManga;
    case DownloadType.nhentai:
      return FavoriteType.nhentai;
    case DownloadType.copyManga:
      return FavoriteType.copyManga;
    case DownloadType.komiic:
      return FavoriteType.komiic;
    default:
      return const FavoriteType(0);
  }
}

class DownloadPageLogic extends StateController {
  bool loading = true;
  bool selecting = false;
  int selectedNum = 0;
  var selected = <bool>[];
  var comics = <DownloadedItem>[];
  var baseComics = <DownloadedItem>[];
  bool searchMode = false;
  bool searchInit = false;
  String keyword = "";
  String keyword_ = "";

  void change() {
    loading = !loading;
    try {
      update();
    } catch (e) {
      // ignore
    }
  }

  void find() {
    if (keyword == keyword_) {
      return;
    }
    keyword_ = keyword;
    comics.clear();
    if (keyword == "") {
      comics.addAll(baseComics);
    } else {
      for (var element in baseComics) {
        if (element.name.toLowerCase().contains(keyword) ||
            element.subTitle.toLowerCase().contains(keyword)) {
          comics.add(element);
        }
      }
    }
    resetSelected(comics.length);
  }

  @override
  void refresh() {
    searchMode = false;
    selecting = false;
    selectedNum = 0;
    selected.clear();
    comics.clear();
    change();
  }

  void resetSelected(int length) {
    selected = List.generate(length, (index) => false);
    selectedNum = 0;
  }
}

class DownloadPage extends StatelessWidget {
  const DownloadPage({super.key});

  @override
  Widget build(BuildContext context) {
    return StateBuilder<DownloadPageLogic>(
      init: DownloadPageLogic(),
      builder: (logic) {
        if (logic.loading) {
          Future.wait([
            _getComics(logic),
            Future.delayed(const Duration(milliseconds: 300))
          ]).then((v) {
            logic.resetSelected(logic.comics.length);
            logic.change();
          });
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        } else {
          return Scaffold(
            floatingActionButton: _buildFAB(context, logic),
            body: SmoothCustomScrollView(
              slivers: [
                _buildAppbar(context, logic),
                _buildComics(context, logic)
              ],
            ),
          );
        }
      },
    );
  }

  Widget _buildComics(BuildContext context, DownloadPageLogic logic) {
    logic.find();
    final comics = logic.comics;
    if (comics.isEmpty) {
      return SliverToBoxAdapter(
        child: _buildEmptyState(context),
      );
    }
    return SliverGrid(
      delegate: SliverChildBuilderDelegate(
        childCount: comics.length,
        (context, index) {
          return _buildItem(context, logic, index);
        },
      ),
      gridDelegate: SliverGridDelegateWithComics(),
    );
  }

  Future<void> _getComics(DownloadPageLogic logic) async {
    var order = '', direction = 'desc';
    switch (appdata.settings[26][0]) {
      case "0":
        order = 'time';
      case "1":
        order = 'title';
      case "2":
        order = 'subtitle';
      case "3":
        order = 'size';
      default:
        throw UnimplementedError();
    }
    if (appdata.settings[26][1] == "1") {
      direction = 'asc';
    }
    logic.comics = DownloadManager().getAll(order, direction);
    logic.baseComics = logic.comics.toList();
  }

  Widget _buildItem(BuildContext context, DownloadPageLogic logic, int index) {
    bool selected = logic.selected[index];
    var type = logic.comics[index].type.name;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Container(
        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context).colorScheme.surfaceContainerHighest
              : Colors.transparent,
          borderRadius: const BorderRadius.all(Radius.circular(16)),
        ),
        child: DownloadedComicTile(
          name: logic.comics[index].name,
          author: logic.comics[index].subTitle,
          imagePath: DownloadManager().getCover(logic.comics[index].id),
          type: type,
          tag: logic.comics[index].tags,
          onTap: () async {
            if (logic.selecting) {
              logic.selected[index] = !logic.selected[index];
              logic.selected[index] ? logic.selectedNum++ : logic.selectedNum--;
              if (logic.selectedNum == 0) {
                logic.selecting = false;
              }
              logic.update();
            } else {
              _showInfo(index, logic, context);
            }
          },
          size: () {
            if (logic.comics[index].comicSize != null) {
              return "${logic.comics[index].comicSize!.toStringAsFixed(2)}MB";
            } else {
              return "未知大小".tl;
            }
          }.call(),
          onLongTap: () {
            if (logic.selecting) return;
            logic.selected[index] = true;
            logic.selectedNum++;
            logic.selecting = true;
            logic.update();
          },
          onSecondaryTap: (details) {
            _showDesktopMenu(context, logic, index, details);
          },
        ),
      ),
    );
  }

  void _showDesktopMenu(BuildContext context, DownloadPageLogic logic,
      int index, TapDownDetails details) {
    showMenu(
      context: context,
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx,
        details.globalPosition.dy,
        details.globalPosition.dx + 1,
        details.globalPosition.dy + 1,
      ),
      items: [
        PopupMenuItem(
          child: Text("阅读".tl),
          onTap: () {
            logic.comics[index].read();
          },
        ),
        PopupMenuItem(
          child: Text("删除".tl),
          onTap: () {
            Future.delayed(const Duration(milliseconds: 200), () {
              showDialog(
                context: App.globalContext!,
                builder: (ctx) => AlertDialog(
                  title: Text("确认删除".tl),
                  content: Text("此操作无法撤销, 是否继续?".tl),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text("取消".tl),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        DownloadManager().delete([logic.comics[index].id]);
                        logic.comics.removeAt(index);
                        logic.selected.removeAt(index);
                        logic.update();
                      },
                      child: Text("确认".tl),
                    ),
                  ],
                ),
              );
            });
          },
        ),
        PopupMenuItem(
          child: Text("导出".tl),
          onTap: () => _exportComic(context, logic.comics[index]),
        ),
        PopupMenuItem(
          child: Text("查看漫画详情".tl),
          onTap: () {
            Future.delayed(const Duration(milliseconds: 300), () {
              _toComicInfoPage(App.globalContext!, logic.comics[index]);
            });
          },
        ),
        PopupMenuItem(
          child: Text("复制路径".tl),
          onTap: () {
            Future.delayed(const Duration(milliseconds: 300), () {
              var path =
                  "${DownloadManager().path}/${logic.comics[index].directory ?? ''}";
              Clipboard.setData(ClipboardData(text: path));
            });
          },
        ),
      ],
    );
  }

  void _exportComic(BuildContext context, DownloadedItem comic) {
    final dir = comic.directory ?? '';
    final fullPath = "${DownloadManager().path}/$dir";
    if (Platform.isWindows) {
      Process.run('explorer', [fullPath]);
    } else if (Platform.isMacOS) {
      Process.run('open', [fullPath]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [fullPath]);
    }
  }

  void _showInfo(int index, DownloadPageLogic logic, BuildContext context) {
    if (UiMode.m1(context)) {
      showModalBottomSheet(
        context: context,
        builder: (context) {
          return DownloadedComicInfoView(logic.comics[index], logic);
        },
      );
    } else {
      showDialog(
        context: App.globalContext!,
        builder: (context) => Dialog(
          child: SizedBox(
            width: 400,
            height: 500,
            child: DownloadedComicInfoView(logic.comics[index], logic),
          ),
        ),
      );
    }
  }

  Widget _buildFAB(BuildContext context, DownloadPageLogic logic) =>
      FloatingActionButton(
        enableFeedback: true,
        onPressed: () {
          if (!logic.selecting) {
            logic.selecting = true;
            logic.update();
          } else {
            if (logic.selectedNum == 0) return;
            showDialog(
              context: context,
              builder: (dialogContext) {
                return AlertDialog(
                  title: Text("删除".tl),
                  content: Text("要删除已选择的项目吗? 此操作无法撤销".tl),
                  actions: [
                    TextButton(
                      onPressed: () => App.globalBack(),
                      child: Text("取消".tl),
                    ),
                    TextButton(
                      onPressed: () async {
                        App.globalBack();
                        var comics = <String>[];
                        for (int i = 0; i < logic.selected.length; i++) {
                          if (logic.selected[i]) {
                            comics.add(logic.comics[i].id);
                          }
                        }
                        await DownloadManager().delete(comics);
                        logic.refresh();
                      },
                      child: Text("确认".tl),
                    ),
                  ],
                );
              },
            );
          }
        },
        child: logic.selecting
            ? const Icon(Icons.delete_forever_outlined)
            : const Icon(Icons.checklist_outlined),
      );

  Widget _buildTitle(BuildContext context, DownloadPageLogic logic) {
    if (logic.searchMode && !logic.selecting) {
      final FocusNode focusNode = FocusNode();
      focusNode.requestFocus();
      bool focus = logic.searchInit;
      logic.searchInit = false;
      return TextField(
        focusNode: focus ? focusNode : null,
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: "搜索".tl,
        ),
        onChanged: (s) {
          logic.keyword = s.toLowerCase();
          logic.update();
        },
      );
    } else {
      return logic.selecting
          ? Text("已选择 @num 个项目".tlParams({"num": logic.selectedNum.toString()}))
          : Text("已下载".tl);
    }
  }

  Widget _buildAppbar(BuildContext context, DownloadPageLogic logic) {
    return SliverAppbar(
      title: _buildTitle(context, logic),
      color: logic.selecting
          ? Theme.of(context).colorScheme.primaryContainer
          : null,
      leading: logic.selecting
          ? IconButton(
              onPressed: () {
                logic.selecting = false;
                logic.selectedNum = 0;
                for (int i = 0; i < logic.selected.length; i++) {
                  logic.selected[i] = false;
                }
                logic.update();
              },
              icon: const Icon(Icons.close),
            )
          : null,
      actions: _buildActions(context, logic),
    );
  }

  List<Widget> _buildActions(BuildContext context, DownloadPageLogic logic) {
    return [
      if (!logic.selecting && !logic.searchMode)
        Tooltip(
          message: "排序".tl,
          child: IconButton(
            icon: const Icon(Icons.sort),
            onPressed: () async {
              bool changed = false;
              await showDialog(
                context: context,
                builder: (context) => SimpleDialog(
                  title: Text("漫画排序模式".tl),
                  children: [
                    SizedBox(
                      width: 400,
                      child: Column(
                        children: [
                          ListTile(
                            title: Text("漫画排序模式".tl),
                            trailing: DropdownButton<int>(
                              value: int.parse(appdata.settings[26][0]),
                              items: [
                                DropdownMenuItem(
                                    value: 0, child: Text("时间".tl)),
                                DropdownMenuItem(
                                    value: 1, child: Text("漫画名".tl)),
                                DropdownMenuItem(
                                    value: 2, child: Text("作者名".tl)),
                                DropdownMenuItem(
                                    value: 3, child: Text("大小".tl)),
                              ],
                              onChanged: (i) {
                                if (i != null) {
                                  appdata.settings[26] = appdata.settings[26]
                                      .replaceRange(0, 1, i.toString());
                                  appdata.updateSettings();
                                  changed = true;
                                }
                              },
                            ),
                          ),
                          ListTile(
                            title: Text("倒序".tl),
                            trailing: Switch(
                              value: appdata.settings[26][1] == "1",
                              onChanged: (b) {
                                appdata.settings[26] = appdata.settings[26]
                                    .replaceRange(1, 2, b ? "1" : "0");
                                appdata.updateSettings();
                                changed = true;
                              },
                            ),
                          ),
                        ],
                      ),
                    )
                  ],
                ),
              );
              if (changed) {
                logic.refresh();
              }
            },
          ),
        ),
      if (logic.selecting)
        Tooltip(
          message: "更多".tl,
          child: IconButton(
            icon: const Icon(Icons.more_horiz),
            onPressed: () {
              showMenu(
                context: context,
                position: RelativeRect.fromLTRB(
                  MediaQuery.of(context).size.width - 60,
                  50,
                  MediaQuery.of(context).size.width - 60,
                  50,
                ),
                items: [
                  PopupMenuItem(
                    child: Text("全选".tl),
                    onTap: () {
                      for (int i = 0; i < logic.selected.length; i++) {
                        logic.selected[i] = true;
                      }
                      logic.selectedNum = logic.comics.length;
                      logic.update();
                    },
                  ),
                  PopupMenuItem(
                    child: Text("导出".tl),
                    onTap: () => _exportSelected(context, logic),
                  ),
                  PopupMenuItem(
                    child: Text("查看漫画详情".tl),
                    onTap: () => Future.delayed(
                      const Duration(milliseconds: 200),
                      () {
                        if (logic.selectedNum != 1) {
                          // showToast not available in picakeep
                        } else {
                          for (int i = 0; i < logic.selected.length; i++) {
                            if (logic.selected[i]) {
                              _toComicInfoPage(
                                  App.globalContext!, logic.comics[i]);
                            }
                          }
                        }
                      },
                    ),
                  ),
                  PopupMenuItem(
                    child: Text("添加至本地收藏".tl),
                    onTap: () => Future.delayed(
                      const Duration(milliseconds: 200),
                      () => _addToLocalFavoriteFolder(context, logic),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      if (!logic.selecting)
        Tooltip(
          message: "搜索".tl,
          child: IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              logic.searchMode = !logic.searchMode;
              logic.searchInit = true;
              if (!logic.searchMode) {
                logic.keyword = "";
              }
              logic.update();
            },
          ),
        )
    ];
  }

  void _exportSelected(BuildContext context, DownloadPageLogic logic) {
    if (logic.selectedNum == 0) return;
    for (int i = 0; i < logic.selected.length; i++) {
      if (logic.selected[i]) {
        _exportComic(context, logic.comics[i]);
      }
    }
  }

  void _addToLocalFavoriteFolder(
      BuildContext context, DownloadPageLogic logic) {
    String? folder;
    showDialog(
      context: App.globalContext!,
      builder: (context) => SimpleDialog(
        title: const Text("复制到..."),
        children: [
          SizedBox(
            width: 400,
            height: 132,
            child: Column(
              children: [
                ListTile(
                  title: Text("收藏夹".tl),
                  trailing: DropdownButton<String>(
                    hint: Text("选择收藏夹".tl),
                    items: LocalFavoritesManager()
                        .folderNames
                        .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                        .toList(),
                    onChanged: (v) => folder = v,
                  ),
                ),
                const Spacer(),
                Center(
                  child: FilledButton(
                    child: Text("确认".tl),
                    onPressed: () {
                      if (folder == null) return;
                      for (int i = 0; i < logic.selected.length; i++) {
                        if (logic.selected[i]) {
                          var comic = logic.comics[i];
                          LocalFavoritesManager().addComic(
                            folder!,
                            FavoriteItem(
                              target: comic.id,
                              name: comic.name,
                              coverPath: '',
                              author: comic.subTitle,
                              type: _downloadTypeToFavoriteType(comic.type),
                              tags: comic.tags,
                            ),
                          );
                        }
                      }
                      App.globalBack();
                    },
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final path = DownloadManager().path ?? appdata.settings[22];
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.download_done, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text('暂无已下载的漫画'.tl,
                style: const TextStyle(fontSize: 18, color: Colors.grey)),
            const SizedBox(height: 8),
            if (path.isNotEmpty)
              Text('下载目录: $path',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () async {
                await DownloadManager().init();
                final count = DownloadManager().scanDirectoryForComics();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('扫描完成，共发现 $count 个漫画')),
                  );
                }
              },
              icon: const Icon(Icons.refresh),
              label: Text('重新扫描磁盘'.tl),
            ),
            const SizedBox(height: 8),
            Text('请确保下载目录中存在 download.db 数据库文件',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline)),
          ],
        ),
      ),
    );
  }
}

class DownloadedComicInfoView extends StatefulWidget {
  const DownloadedComicInfoView(this.item, this.logic, {super.key});
  final DownloadedItem item;
  final DownloadPageLogic logic;

  @override
  State<DownloadedComicInfoView> createState() =>
      _DownloadedComicInfoViewState();
}

class _DownloadedComicInfoViewState extends State<DownloadedComicInfoView> {
  String name = "";
  List<String> eps = [];
  List<int> downloadedEps = [];
  late final comic = widget.item;

  deleteEpisode(int i) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("确认删除".tl),
        content: Text("要删除这个章节吗".tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text("取消".tl),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              var message = await DownloadManager().deleteEpisode(comic, i);
              if (message == null) {
                setState(() {});
              }
            },
            child: Text("确认".tl),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    getInfo();
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 16, 0, 16),
            child: Text(
              name,
              style: const TextStyle(fontSize: 22),
            ),
          ),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 300,
                childAspectRatio: 4,
              ),
              itemBuilder: (BuildContext context, int i) {
                return Padding(
                  padding: const EdgeInsets.all(4),
                  child: InkWell(
                    borderRadius: const BorderRadius.all(Radius.circular(16)),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius:
                            const BorderRadius.all(Radius.circular(16)),
                        color: downloadedEps.contains(i)
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(eps[i]),
                          ),
                          const SizedBox(width: 4),
                          if (downloadedEps.contains(i))
                            const Icon(Icons.download_done),
                          const SizedBox(width: 16),
                        ],
                      ),
                    ),
                    onTap: () => readSpecifiedEps(i),
                    onLongPress: () {
                      deleteEpisode(i);
                    },
                    onSecondaryTapDown: (details) {
                      deleteEpisode(i);
                    },
                  ),
                );
              },
              itemCount: eps.length,
            ),
          ),
          SizedBox(
            height: 50,
            child: Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      App.globalBack();
                      _toComicInfoPage(context, widget.item);
                    },
                    child: Text("查看详情".tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    onPressed: () => read(),
                    child: Text("阅读".tl),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: MediaQuery.of(context).padding.bottom,
          )
        ],
      ),
    );
  }

  void getInfo() {
    name = comic.name;
    eps = comic.eps;
    downloadedEps = comic.downloadedEps;
  }

  void read() {
    comic.read();
  }

  void readSpecifiedEps(int i) {
    comic.read(ep: i + 1);
  }
}
