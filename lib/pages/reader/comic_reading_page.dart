library pica_reader;

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:picakeep/components/components.dart';
import 'package:picakeep/components/custom_slider.dart';
import 'package:picakeep/components/scrollable_list/src/item_positions_listener.dart';
import 'package:picakeep/components/scrollable_list/src/scrollable_positioned_list.dart';
import 'package:picakeep/components/window_frame.dart';
import 'package:picakeep/foundation/image_loader/base_image_provider.dart';
import 'package:picakeep/foundation/image_loader/file_image_loader.dart';
import 'package:picakeep/foundation/image_loader/stream_image_provider.dart';
import 'package:picakeep/foundation/image_favorites.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/tools/keep_screen_on.dart';
import 'package:picakeep/foundation/image_manager.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/tools/save_image.dart';
import 'package:picakeep/tools/time.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/ui_mode.dart';
import 'package:picakeep/tools/key_down_event.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:window_manager/window_manager.dart';

part 'eps_view.dart';

part 'image_view.dart';

part 'image.dart';

part 'touch_control.dart';

part 'reading_logic.dart';

part 'tool_bar.dart';

part 'reading_type.dart';

part 'reading_settings.dart';

part 'reading_data.dart';

SystemUiOverlayStyle _readerOverlayStyle(bool useDarkBackground) {
  final isDark = useDarkBackground;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
    systemNavigationBarColor: isDark ? Colors.black : Colors.white,
    systemNavigationBarIconBrightness:
        isDark ? Brightness.light : Brightness.dark,
    systemNavigationBarDividerColor: Colors.transparent,
  );
}

void _showReaderSystemUi({required bool useDarkBackground}) {
  SystemChrome.setSystemUIOverlayStyle(
    _readerOverlayStyle(useDarkBackground),
  );
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
}

void _hideReaderSystemUi({required bool useDarkBackground}) {
  SystemChrome.setSystemUIOverlayStyle(
    _readerOverlayStyle(useDarkBackground),
  );
  SystemChrome.setEnabledSystemUIMode(
    App.isMobile ? SystemUiMode.immersiveSticky : SystemUiMode.immersive,
  );
}

void _syncReaderSystemUi({
  required bool useDarkBackground,
  required bool visible,
}) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (visible) {
      _showReaderSystemUi(useDarkBackground: useDarkBackground);
    } else {
      _hideReaderSystemUi(useDarkBackground: useDarkBackground);
    }
  });
}

///阅读器
class ComicReadingPage extends StatelessWidget {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  final ReadingData readingData;

  late final History? history = HistoryManager().findSync(readingData.id);

  final int initialPage;

  final int initialEp;

  ReadingType get type => readingData.comicType;

  ComicReadingPage(this.readingData, this.initialPage, this.initialEp,
      {super.key}) {
    StateController.put(ComicReadingPageLogic(
        initialEp,
        readingData,
        initialPage,
        () => _updateHistory(
            StateController.find<ComicReadingPageLogic>(), false)));
  }

  _updateHistory(ComicReadingPageLogic? logic, bool updateMePage) {
    if (history == null || logic == null) {
      return;
    }
    final h = history!;
    if (readingData.hasEp) {
      if (logic.order == 1 && logic.index == 1) {
        h.ep = 0;
        h.page = 0;
      } else {
        if (logic.order == readingData.eps?.length &&
            logic.index == logic.length) {
          h.ep = 0;
          h.page = 0;
        } else {
          h.ep = logic.order;
          h.page = logic.index;
        }
      }
    } else {
      if (logic.index == 1) {
        h.ep = 0;
        h.page = 0;
      } else {
        h.ep = 1;
        h.page = logic.index;
      }
    }
    h.maxPage = logic.length;
    HistoryManager().saveReadHistory(h, updateMePage);
  }

  bool get useDarkBackground => appdata.appSettings.useDarkBackground;

  @override
  Widget build(BuildContext context) {
    return StateBuilder<ComicReadingPageLogic>(initState: (logic) {
      App.setReadingActive(true);
      _syncReaderSystemUi(useDarkBackground: useDarkBackground, visible: false);
      if (appdata.settings[14] == "1") {
        setKeepScreenOn();
      }
      if (appdata.settings[76] == "1") {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight
        ]);
      } else if (appdata.settings[76] == "2") {
        SystemChrome.setPreferredOrientations(
            [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
      }
      //进入阅读器时清除内存中的缓存, 并且增大限制
      logic.configureReaderCacheLimits();
      logic.openEpsView = () => openEpsDrawer(context);
      if (useDarkBackground) {
        Future.microtask(() =>
            StateController.findOrNull<WindowFrameController>()
                ?.setDarkTheme());
      }
    }, dispose: (logic) {
      //清除缓存并减小最大缓存
      logic.restoreReaderCacheLimits();
      logic.clearPhotoViewControllers();
      _showReaderSystemUi(useDarkBackground: useDarkBackground);
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      if (logic.listenVolume != null) {
        logic.listenVolume!.stop();
      }
      if (appdata.settings[14] == "1") {
        cancelKeepScreenOn();
      }
      logic.runningAutoPageTurning = false;
      ComicImage.clear();
      StateController.remove<ComicReadingPageLogic>();
      // 更新本地收藏
      LocalFavoritesManager()
          .onReadEnd(readingData.favoriteId, readingData.favoriteType);
      // 保存历史记录
      if (history != null) {
        _updateHistory(logic, true);
      }
      // 退出全屏
      if (logic.isFullScreen) {
        logic.fullscreen();
      }
      ImageManager.clearTasks();

      if (appdata.settings[76] != "0") {
        SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      }
      if (useDarkBackground) {
        Future.microtask(() =>
            StateController.findOrNull<WindowFrameController>()?.resetTheme());
      }
      App.setReadingActive(false);
    }, builder: (logic) {
      _syncReaderSystemUi(
        useDarkBackground: useDarkBackground,
        visible: logic.tools,
      );
      return DefaultTextStyle.merge(
        style: TextStyle(
          color: useDarkBackground ? Colors.white : null,
          fontSize: 16,
        ),
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: _readerOverlayStyle(useDarkBackground),
          child: MediaQuery.removePadding(
            context: context,
            removeTop: App.isMobile,
            child: PopScope(
              canPop: true,
              child: Scaffold(
                backgroundColor: useDarkBackground ? Colors.black : null,
                endDrawerEnableOpenDragGesture: false,
                key: _scaffoldKey,
                endDrawer: Drawer(
                  child: buildEpsView(),
                ),
                floatingActionButton: buildEpChangeButton(logic),
                body: StateBuilder<ComicReadingPageLogic>(builder: (logic) {
                  if (logic.isLoading) {
                    history?.readEpisode.add(logic.order);
                    loadInfo(logic);
                    return const Center(
                      child: CircularProgressIndicator(),
                    );
                  } else if (logic.urls.isNotEmpty) {
                    if (logic.readingMethod ==
                            ReadingMethod.topToBottomContinuously &&
                        !logic.haveUsedInitialPage &&
                        initialPage != 0) {
                      Future.microtask(() {
                        logic.jumpToPage(initialPage);
                        logic.haveUsedInitialPage = true;
                      });
                    }
                    //监听音量键
                    if (appdata.settings[7] == "1") {
                      if (logic.listenVolume == null) {
                        logic.listenVolume = ListenVolumeController(
                            () => logic.jumpToLastPage(),
                            () => logic.jumpToNextPage());
                        logic.listenVolume!.listenVolumeChange();
                      }
                    } else if (logic.listenVolume != null) {
                      logic.listenVolume!.stop();
                      logic.listenVolume = null;
                    }

                    if (appdata.settings[9] == "4") {
                      logic.scrollManager ??= ScrollManager(logic);
                    }

                    var body = Listener(
                      onPointerMove: TapController.onPointerMove,
                      onPointerUp: (event) =>
                          TapController.onTapUp(event, context),
                      onPointerDown: (event) =>
                          TapController.onTapDown(event, context),
                      behavior: HitTestBehavior.translucent,
                      onPointerCancel: TapController.onTapCancel,
                      child: Stack(
                        children: [
                          buildComicView(
                            logic,
                            context,
                            readingData.id,
                          ),
                          if (MediaQuery.of(context).platformBrightness ==
                                  Brightness.dark &&
                              appdata.appSettings.reduceBrightnessInDarkMode)
                            Positioned(
                              top: 0,
                              bottom: 0,
                              left: 0,
                              right: 0,
                              child: IgnorePointer(
                                child: ColoredBox(
                                  color: Colors.black.withValues(alpha: 0.2),
                                ),
                              ),
                            ),

                          if (appdata.appSettings.showPageInfoInReader)
                            buildPageInfoText(logic, context),

                          //底部工具栏
                          buildBottomToolBar(logic, context, readingData.hasEp),

                          ...buildButtons(logic, context),

                          //顶部工具栏
                          buildTopToolBar(logic, context),
                        ],
                      ),
                    );

                    return KeyboardListener(
                      focusNode: logic.focusNode,
                      autofocus: true,
                      onKeyEvent: logic.handleKeyboard,
                      child: body,
                    );
                  } else {
                    return buildErrorView(logic, context);
                  }
                }),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget buildErrorView(ComicReadingPageLogic logic, BuildContext context) {
    return SafeArea(
        child: Stack(
      children: [
        Positioned(
          left: 8,
          top: 12,
          child: IconButton(
            icon: const Icon(
              Icons.arrow_back,
            ),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        Positioned(
          top: MediaQuery.of(App.globalContext!).size.height / 2 - 80,
          left: 0,
          right: 0,
          child: const Align(
            alignment: Alignment.topCenter,
            child: Icon(
              Icons.error_outline,
              size: 60,
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: MediaQuery.of(App.globalContext!).size.height / 2 - 10,
          child: Align(
            alignment: Alignment.topCenter,
            child: Text(
              logic.errorMessage ?? "未知错误".tl,
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: MediaQuery.of(App.globalContext!).size.height / 2 + 30,
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 250,
              height: 40,
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        logic.change();
                      },
                      child: Text("重试".tl),
                    ),
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  Expanded(
                      child: FilledButton(
                    onPressed: () {
                      if (!readingData.hasEp) {
                        showToast(message: "没有其它章节".tl);
                        return;
                      }
                      if (MediaQuery.of(context).size.width > 600) {
                        showSideBar(
                          context,
                          buildEpsView(),
                          title: null,
                          useSurfaceTintColor: true,
                          addTopPadding: true,
                          width: 400,
                        );
                      } else {
                        showModalBottomSheet(
                          context: context,
                          useSafeArea: false,
                          showDragHandle: false,
                          constraints: BoxConstraints(
                            maxHeight:
                                MediaQuery.of(context).size.height * 0.56,
                          ),
                          builder: (context) {
                            return buildEpsView();
                          },
                        );
                      }
                    },
                    child: Text("切换章节".tl),
                  )),
                ],
              ),
            ),
          ),
        ),
      ],
    ));
  }

  void loadInfo(ComicReadingPageLogic logic) async {
    if (logic.isLoadingInfo && logic.loadingOrder == logic.order) {
      return;
    }
    final requestId = ++logic.chapterLoadRequestId;
    final order = logic.order;
    logic.isLoadingInfo = true;
    logic.loadingOrder = order;
    logic.errorMessage = null;
    logic.urls = [];
    try {
      final urls = await readingData.loadEp(order);
      if (StateController.findOrNull<ComicReadingPageLogic>() != logic ||
          requestId != logic.chapterLoadRequestId ||
          order != logic.order) {
        return;
      }
      logic.urls = urls;
      logic.isLoading = false;
      logic.update();
    } catch (e) {
      if (StateController.findOrNull<ComicReadingPageLogic>() != logic ||
          requestId != logic.chapterLoadRequestId ||
          order != logic.order) {
        return;
      }
      logic.errorMessage = e.toString().trim();
      logic.urls = [];
      logic.isLoading = false;
      logic.update();
    } finally {
      if (StateController.findOrNull<ComicReadingPageLogic>() == logic &&
          requestId == logic.chapterLoadRequestId) {
        logic.isLoadingInfo = false;
        logic.loadingOrder = null;
      }
    }
  }

  Widget buildEpsView() {
    return EpsView(readingData);
  }

  void openEpsDrawer(BuildContext context) {
    if (MediaQuery.of(context).size.width > 600) {
      showSideBar(
        context,
        buildEpsView(),
        title: null,
        useSurfaceTintColor: true,
        width: 400,
        addTopPadding: true,
      );
    } else {
      showModalBottomSheet(
        context: context,
        useSafeArea: false,
        showDragHandle: false,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.56,
        ),
        builder: (context) {
          return buildEpsView();
        },
      );
    }
  }

  /// Used when [ComicReadingPageLogic.readingMethod] is [ReadingMethod.topToBottomContinuously].
  ///
  /// Select a image form screen, to share or download
  Future<int?> selectImage() async {
    var logic = StateController.find<ComicReadingPageLogic>();
    var items = logic.itemScrollListener.itemPositions.value.toList();
    if (items.length == 1) {
      return items[0].index;
    }
    int? res;
    await showDialog(
        context: App.globalContext!,
        builder: (dialogContext) {
          return SimpleDialog(
            title: Text("选择屏幕上的图片".tl),
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 400,
                ),
                child: Column(
                  children: [
                    for (var item in items)
                      ListTile(
                        title: Text((item.index + 1).toString()),
                        onTap: () {
                          res = item.index;
                          Navigator.of(dialogContext).pop();
                        },
                        trailing: const Icon(Icons.arrow_right),
                      )
                  ],
                ),
              )
            ],
          );
        });
    return res;
  }

  String getImageKey(int index) {
    var logic = StateController.find<ComicReadingPageLogic>();
    return logic.urls[index];
  }

  Future<File> _getFileFromStream(Stream<List<int>> stream) async {
    var bytes = <int>[];
    await for (var event in stream) {
      bytes.addAll(event);
    }
    var dir = Directory.systemTemp;
    var file =
        File("${dir.path}/share_${DateTime.now().millisecondsSinceEpoch}.jpg");
    return file.writeAsBytes(bytes);
  }

  void share() async {
    var logic = StateController.find<ComicReadingPageLogic>();
    int? index = logic.index - 1;
    if (logic.readingMethod == ReadingMethod.topToBottomContinuously) {
      index = await selectImage();
    }
    if (index == null) {
      return;
    }

    var file = await _getFileFromStream(
        readingData.loadImage(logic.order, index, logic.urls[index]));

    shareImage(file);
  }

  Future<String?> _persistentCurrentImage() async {
    var logic = StateController.find<ComicReadingPageLogic>();
    int? index = logic.index - 1;
    if (logic.readingMethod == ReadingMethod.topToBottomContinuously) {
      index = await selectImage();
    }
    if (index == null) {
      return null;
    }

    // For downloaded images, always try direct file read first.
    // Don't depend on checkEpDownloaded — downloadedEps may not
    // be populated yet, but the files are already on disk.
    if (readingData.downloaded) {
      try {
        // Ensure downloadedEps is populated for checkEpDownloaded
        if (readingData.downloadedEps.isEmpty) {
          final comic =
              await downloadManager.getComicOrNull(readingData.downloadId);
          if (comic != null) {
            readingData.downloadedEps = comic.downloadedEps;
          }
        }
        final file = downloadManager.getImage(
          readingData.downloadId,
          readingData.hasEp ? logic.order : 0,
          index,
        );
        if (file.existsSync()) {
          return persistentCurrentImage(file);
        }
      } catch (_) {
        // Fall through to stream-based loading as last resort
      }
    }

    var file = await _getFileFromStream(
        readingData.loadImage(logic.order, index, logic.urls[index]));

    return persistentCurrentImage(file);
  }

  void saveCurrentImage() async {
    var logic = StateController.find<ComicReadingPageLogic>();
    int? index = logic.index - 1;
    if (logic.readingMethod == ReadingMethod.topToBottomContinuously) {
      index = await selectImage();
    }
    if (index == null) {
      return;
    }

    var file = await _getFileFromStream(
        readingData.loadImage(logic.order, index, logic.urls[index]));

    saveImage(file);
  }

  Widget? buildEpChangeButton(ComicReadingPageLogic logic) {
    if (!readingData.hasEp) return null;
    switch (logic.showFloatingButtonValue) {
      case -1:
        return FloatingActionButton(
          onPressed: () => logic.jumpToLastChapter(),
          child: const Icon(Icons.arrow_back_ios_outlined),
        );
      case 0:
        return null;
      case 1:
        return Hero(
            tag: "FAB",
            child: StateBuilder<ComicReadingPageLogic>(
              id: "FAB",
              builder: (logic) {
                return Container(
                  width: 58,
                  height: 58,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                      color: Theme.of(App.globalContext!)
                          .colorScheme
                          .primaryContainer,
                      borderRadius: BorderRadius.circular(16)),
                  child: Stack(
                    children: [
                      Positioned.fill(
                          child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => logic.jumpToNextChapter(),
                          borderRadius: BorderRadius.circular(16),
                          child: Center(
                              child: Icon(
                            Icons.arrow_forward_ios,
                            size: 24,
                            color: Theme.of(App.globalContext!)
                                .colorScheme
                                .onPrimaryContainer,
                          )),
                        ),
                      )),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        height: logic.fABValue,
                        child: ColoredBox(
                          color: Theme.of(App.globalContext!)
                              .colorScheme
                              .surfaceTint
                              .withValues(alpha: 0.2),
                          child: const SizedBox.expand(),
                        ),
                      )
                    ],
                  ),
                );
              },
            ));
    }
    return null;
  }
}
