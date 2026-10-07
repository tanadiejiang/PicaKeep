library pica_reader;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:crypto/crypto.dart';
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
import 'package:picakeep/foundation/archive/archive_reading_service.dart';
import 'package:picakeep/foundation/archive/archive_models.dart';
import 'package:picakeep/foundation/archive/archive_errors.dart';
import 'package:picakeep/foundation/privileged_storage_access.dart';
import 'package:picakeep/comic_source/comic_source.dart';
import 'package:picakeep/network/online_image/online_image_cache.dart';
import 'package:picakeep/foundation/image_favorites.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/tools/keep_screen_on.dart';
import 'package:picakeep/foundation/image_manager.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/reader_image_quality.dart';
import 'package:picakeep/foundation/image_pipeline/reader_page_source.dart';
import 'package:picakeep/foundation/image_pipeline/reader_session_raster_cache.dart';
import 'package:picakeep/foundation/image_pipeline/derived_image_store.dart';
import 'package:picakeep/pages/reader/reader_page_image.dart';
import 'package:picakeep/pages/reader/reader_image_surface.dart';
import 'package:picakeep/foundation/download_model.dart';
import 'package:picakeep/foundation/untranslated_tags/untranslated_tag_coordinator.dart';
import 'package:picakeep/network/online_image/online_image_manager.dart';
import 'package:picakeep/network/picacg_network/picacg_network.dart';
import 'package:picakeep/network/jm_network/jm_network.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/eh_network/get_gallery_id.dart';
import 'package:picakeep/network/nhentai_network/nhentai_main_network.dart';
// 第十八轮新增：Pixiv / Komiic 在线阅读数据所需的网络层与模型。
import 'package:picakeep/network/pixiv_network/pixiv_network.dart';
import 'package:picakeep/network/komiic_network/komiic_network.dart';
import 'package:picakeep/foundation/image_loader/jm_image_recombine.dart';
import 'package:picakeep/tools/save_image.dart';
import 'package:picakeep/tools/time.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/ui_mode.dart';
import 'package:picakeep/tools/key_down_event.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:window_manager/window_manager.dart';
import 'package:uuid/uuid.dart';

part 'eps_view.dart';

part 'image_view.dart';

part 'image.dart';

part 'touch_control.dart';

part 'reading_logic.dart';

part 'tool_bar.dart';

part 'reading_type.dart';

part 'reading_settings.dart';

part 'reading_data.dart';

part '../online_comic/picacg_reading_data.dart';
part '../online_comic/jm_reading_data.dart';
part '../online_comic/eh_reading_data.dart';
part '../online_comic/nhentai_reading_data.dart';
// 第十八轮新增源：Pixiv（单本多图，无章节）/ Komiic（有章节）。
part '../online_comic/pixiv_reading_data.dart';
part '../online_comic/komiic_reading_data.dart';

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
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
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
class _SelectedOriginalPage {
  const _SelectedOriginalPage(
      {required this.source,
      required this.workId,
      required this.title,
      required this.url,
      required this.eps});
  final ReaderPageSource source;
  final String workId;
  final String title;
  final String url;
  final List<String> eps;
}

class _PersistentSelectedImage {
  const _PersistentSelectedImage({required this.path, required this.selected});
  final String path;
  final _SelectedOriginalPage selected;
}

class ComicReadingPage extends StatelessWidget {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  final ReadingData readingData;

  late final History? history = HistoryManager().findSync(readingData.id);

  final int initialPage;

  final int initialEp;

  ReadingType get type => readingData.comicType;

  ComicReadingPage(this.readingData, this.initialPage, this.initialEp,
      {super.key}) {
    final logic = ComicReadingPageLogic(
        initialEp,
        readingData,
        initialPage,
        () => _updateHistory(
            StateController.find<ComicReadingPageLogic>(), false));
    StateController.put(logic);
    _applyDefaultPageModeForSource(logic);
    unawaited(_observeUntranslatedTagsForReader());
  }

  /// 让 Pixiv 与本地/图集类作品**默认以单页打开**。
  ///
  /// 理由：Pixiv 是单图或少量图的作品，本地图集也没有固定版式，"从上至下（连续）"
  /// 或"双页"用在它们身上都别扭。命中时**临时**覆盖 `settings[9]`，原值记在
  /// [ComicReadingPageLogic.overriddenPageMode] 上，退出阅读器时还原
  /// （见 `_restoreOverriddenPageMode`）—— 所以**不改动用户的全局设置**，
  /// 用户在阅读器里手动切换也照常生效。
  void _applyDefaultPageModeForSource(ComicReadingPageLogic logic) {
    final type = readingData.comicType;
    final preferSinglePage = type == ComicType.pixiv || type == ComicType.other;
    if (!preferSinglePage) {
      return;
    }
    final current = appdata.settings[9];
    // '1' / '2' 本就是单页（从左向右 / 从右向左），没什么可覆盖的。
    if (current == '1' || current == '2') {
      return;
    }
    logic.overriddenPageMode = current;
    appdata.settings[9] = '1';
  }

  /// 还原 [_applyDefaultPageModeForSource] 的临时覆盖。
  ///
  /// 判据是"`settings[9]` 是否仍等于我们设的 `'1'`"：若用户中途在阅读器里手动
  /// 调过，值就不是 `'1'` 了，那说明他确实想用新的 —— 此时保留用户的选择，不还原。
  void _restoreOverriddenPageMode(ComicReadingPageLogic logic) {
    final previous = logic.overriddenPageMode;
    if (previous == null) {
      return;
    }
    logic.overriddenPageMode = null;
    if (appdata.settings[9] == '1') {
      appdata.settings[9] = previous;
    }
  }

  Future<void> _observeUntranslatedTagsForReader() async {
    try {
      var source = readingData.untranslatedTagSource;
      var comicId = readingData.untranslatedTagComicId;
      var flatTags = readingData.untranslatedTagFlatTags.toList();
      var categorizedTags = readingData.untranslatedTagCategorizedTags;

      // Downloaded-list/history entries may only carry a stable download id;
      // recover the already persisted source metadata without guessing from a
      // title, path, or display label.
      if (source != null &&
          (flatTags.isNotEmpty || categorizedTags.isNotEmpty)) {
        // The reading data already contains the authoritative metadata.
      } else {
        final item =
            await downloadManager.getComicOrNull(readingData.downloadId);
        if (item != null) {
          final itemSource = switch (item.type) {
            DownloadType.ehentai => 'ehentai',
            DownloadType.nhentai => 'nhentai',
            _ => '',
          };
          if (itemSource.isNotEmpty) {
            source = itemSource;
            comicId = item is NhentaiDownloadedComic
                ? item.comicID
                : item is DownloadedComic
                    ? item.comicId
                    : item.id;
            flatTags = item.tags.toList();
            categorizedTags = item is NhentaiDownloadedComic
                ? item.categorizedTags
                : const <String, List<String>>{};
          }
        }
      }

      if (source == null ||
          source.isEmpty ||
          (flatTags.isEmpty && categorizedTags.isEmpty)) {
        return;
      }
      await UntranslatedTagCoordinator.instance.observe(
        UntranslatedTagObservation(
          source: source,
          comicId: comicId,
          flat: flatTags,
          categorized: categorizedTags,
          context: 'reader',
          operationId: 'reader-${const Uuid().v4()}',
        ),
      );
    } catch (_) {
      // Diagnostic metadata must never block or break reader startup.
    }
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
      TapController.reset();
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
      TapController.reset();
      logic.abortActiveImageLoads();
      logic.sessionRasterCache.dispose();
      // 恢复共享缓存限额，阅读会话资源已独立释放，保留列表封面。
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
      // 还原按来源做的翻页方式临时覆盖（用户在阅读中手动调过则保留其选择）。
      _restoreOverriddenPageMode(logic);
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
      // Dispose archive reading session if applicable
      if (readingData.id.startsWith('local_archive::')) {
        final archivePath = readingData.id.substring('local_archive::'.length);
        ArchiveReadingService.instance.disposeReadingSession(archivePath);
      }
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
                  print(
                      '[PicaKeep][build] isLoading=${logic.isLoading} urls=${logic.urls.length} errorMessage=${logic.errorMessage}');
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
      print(
          '[PicaKeep][loadInfo] set urls=${urls.length} requestId=$requestId chapterLoadRequestId=${logic.chapterLoadRequestId} order=$order logicOrder=${logic.order}');
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

  Future<_SelectedOriginalPage?> _selectCurrentOriginal() async {
    final logic = StateController.find<ComicReadingPageLogic>();
    // Freeze the data object, URL sequence, episode and metadata before any
    // async resolution or selection UI. No code below reads a new logic index.
    final data = readingData;
    final order = logic.order;
    final urls = List<String>.unmodifiable(logic.urls);
    final title = data.title;
    final workId = '${data.sourceKey}-${data.id}';
    final eps = List<String>.unmodifiable(data.eps?.keys ?? const <String>[]);
    final method = logic.readingMethod;
    var indexes = <int>[logic.index - 1];
    if (method == ReadingMethod.topToBottomContinuously) {
      indexes = logic.itemScrollListener.itemPositions.value
          .where(
              (item) => item.itemLeadingEdge < 1 && item.itemTrailingEdge > 0)
          .map((item) => item.index)
          .toSet()
          .toList()
        ..sort();
    } else if (method.isTwoPage) {
      // Freeze the actual gallery spread, including the initial screen before
      // onPageChanged synchronises the logical original-page index.
      final spread = logic.pageController.hasClients
          ? logic.pageController.page?.round()
          : null;
      final first = spread == null
          ? logic.index - 1
          : spread * 2 - 2 - (logic.singlePageForFirstScreen ? 1 : 0);
      indexes = [first, first + 1];
      if (method == ReadingMethod.twoPageReversed) {
        indexes = indexes.reversed.toList();
      }
    }
    indexes =
        indexes.where((index) => index >= 0 && index < urls.length).toList();
    if (indexes.isEmpty) {
      return null;
    }
    final candidates = <_SelectedOriginalPage>[];
    try {
      for (final index in indexes) {
        final source = await data.resolvePageSource(order, index, urls[index]);
        candidates.add(_SelectedOriginalPage(
            source: source,
            workId: workId,
            title: title,
            url: urls[index],
            eps: eps));
      }
      _SelectedOriginalPage? selected;
      if (candidates.length == 1) {
        selected = candidates.single;
      } else {
        selected = await showDialog<_SelectedOriginalPage>(
          context: App.globalContext!,
          builder: (dialogContext) => SimpleDialog(
            title: Text('选择屏幕上的图片'.tl),
            children: [
              for (final candidate in candidates)
                ListTile(
                  title: Text((candidate.source.identity.page + 1).toString()),
                  trailing: const Icon(Icons.arrow_right),
                  onTap: () => Navigator.of(dialogContext).pop(candidate),
                ),
            ],
          ),
        );
      }
      for (final candidate in candidates) {
        if (!identical(candidate, selected)) await candidate.source.dispose();
      }
      if (selected != null && !selected.source.isAuthoritativeOriginal) {
        showToast(message: '当前来源最高可用画质'.tl);
      }
      return selected;
    } catch (_) {
      for (final candidate in candidates) {
        await candidate.source.dispose();
      }
      rethrow;
    }
  }

  void share() async {
    _SelectedOriginalPage? selected;
    try {
      selected = await _selectCurrentOriginal();
      if (selected == null) return;
      await shareImage(await selected.source.openOriginalFile());
    } catch (error) {
      showToast(message: error.toString());
    } finally {
      await selected?.source.dispose();
    }
  }

  Future<_PersistentSelectedImage?> _persistentCurrentImage() async {
    final selected = await _selectCurrentOriginal();
    if (selected == null) return null;
    try {
      final file = await selected.source.openOriginalFile();
      final path = await persistentCurrentImage(file,
          identity: selected.source.identity);
      return _PersistentSelectedImage(path: path, selected: selected);
    } finally {
      await selected.source.dispose();
    }
  }

  void saveCurrentImage() async {
    _SelectedOriginalPage? selected;
    try {
      selected = await _selectCurrentOriginal();
      if (selected == null) return;
      await saveImage(await selected.source.openOriginalFile());
    } catch (error) {
      showToast(message: error.toString());
    } finally {
      await selected?.source.dispose();
    }
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
