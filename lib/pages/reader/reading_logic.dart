part of pica_reader;

extension PageControllerExtension on PageController {
  void animatedJumpToPage(int page) {
    final current = this.page?.round() ?? 0;
    if ((current - page).abs() > 1) {
      jumpToPage(page > current ? page - 1 : page + 1);
    }
    animateToPage(page,
        duration: const Duration(milliseconds: 300), curve: Curves.ease);
  }

  void jumpByDeviceType(int page) {
    if (StateController.find<ComicReadingPageLogic>().mouseScroll) {
      jumpToPage(page);
    } else {
      animatedJumpToPage(page);
    }
  }
}

class ReaderViewportChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}

class ComicReadingPageLogic extends StateController {
  ///控制页面, 用于非从上至下(连续)阅读方式
  late PageController pageController;

  ///用于从上至下(连续)阅读方式, 跳转至指定项目
  var itemScrollController = ItemScrollController();

  ///用于从上至下(连续)阅读方式, 获取当前滚动到的元素的序号
  var itemScrollListener = ItemPositionsListener.create();

  ///用于从上至下(连续)阅读方式, 控制滚动
  var scrollController = ScrollController(keepScrollOffset: true);

  ///用于从上至下(连续)阅读方式, 获取放缩大小
  int get activePhotoControllerIndex {
    if (readingMethod == ReadingMethod.topToBottomContinuously) return 0;
    if (readingMethod.isTwoPage) {
      return pageController.hasClients
          ? pageController.page!.round()
          : (singlePageForFirstScreen ? index ~/ 2 + 1 : (index + 1) ~/ 2);
    }
    return index;
  }

  PhotoViewController get photoViewController =>
      ensurePhotoViewController(activePhotoControllerIndex);

  var photoViewControllers = <int, PhotoViewController>{};
  final readerViewportKey = GlobalKey();
  final sessionRasterCache = ReaderSessionRasterCache();
  final failureDiagnosticsSession = ReaderFailureDiagnosticsSession();

  /// Resolved page sizes keyed by `ReaderPageImage.resourceKey` (053). Pages
  /// recycled above the continuous viewport reuse them on rebuild.
  final pageSizeHints = <String, Size>{};
  final previewImagePool = ReaderPreviewImagePool();
  late final previewPreloader = ReaderPreviewPreloader(pool: previewImagePool);
  ReaderDisplayMode? _previewMode;
  ImageConfiguration _previewConfiguration = ImageConfiguration.empty;
  bool _previewStopped = false, _previewRefreshQueued = false;

  void syncPreviewPreloads(ReaderDisplayMode mode, BuildContext context) {
    _previewMode = mode;
    _previewConfiguration = createLocalImageConfiguration(context);
    _refreshPreviewWindow();
  }

  void _schedulePreviewWindow() {
    if (_previewStopped || _previewMode == null || _previewRefreshQueued) return;
    _previewRefreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _previewRefreshQueued = false;
      _refreshPreviewWindow();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _refreshPreviewWindow() {
    final mode = _previewMode;
    if (_previewStopped || mode == null) return;
    final episode = order;
    final pages = List<String>.unmodifiable(urls);
    final source = data;
    final current = index - 1;
    // Keys are captured when the window is queued, not when its asynchronous
    // worker eventually starts under potentially different credentials.
    final keys = <int, String>{};
    final visible = <int>{current};
    if (readingMethod.isTwoPage && (!singlePageForFirstScreen || current > 0)) {
      visible.add(current + 1);
    }
    if (readingMethod == ReadingMethod.topToBottomContinuously) {
      visible.addAll(itemScrollListener.itemPositions.value
          .where((position) => position.itemTrailingEdge > 0 &&
              position.itemLeadingEdge < 1)
          .map((position) => position.index));
    }
    previewPreloader.update(
      currentPage: current, pageCount: pages.length,
      preloadCount: mode == ReaderDisplayMode.previewFirst
          ? int.tryParse(appdata.settings[28]) ?? 0 : 0,
      visiblePages: visible,
      resourceKeyForPage: (page) => keys.putIfAbsent(page,
          () => _readerResourceKey(source, episode, page, pages[page])),
      loadProvider: (page, abort) {
        final expected = keys[page];
        if (!identical(data, source) || expected == null ||
            _readerResourceKey(source, episode, page, pages[page]) != expected) {
          throw observeReaderImageReason(
              StateError('Queued reader image scope or provider version changed'),
              ReaderImageReason.sourceChanged);
        }
        return source.createImageProvider(episode, page, pages[page],
            abortSignal: abort);
      },
      configuration: _previewConfiguration,
      // No fictitious global idle queue: retain the explicit setting's window.
      // Additional idle pages require a verified cross-source budget signal.
    );
  }

  @override
  void dispose() {
    _previewStopped = true;
    previewPreloader.dispose();
    previewImagePool.dispose();
    sessionRasterCache.dispose();
    failureDiagnosticsSession.dispose();
    super.dispose();
  }

  final viewportChanges = ReaderViewportChanges();
  final nativePixelScales = <int, double>{};
  final _transformSubscriptions =
      <StreamSubscription<PhotoViewControllerValue>>[];

  void notifyViewportChanged() => viewportChanges.changed();

  PhotoViewController ensurePhotoViewController(int index) {
    return photoViewControllers.putIfAbsent(index, () {
      final controller = ReaderPhotoViewController();
      _transformSubscriptions.add(
          controller.outputStateStream.listen((_) => notifyViewportChanged()));
      return controller;
    });
  }

  void showNativePixels() {
    final controller = photoViewController;
    final scaleKey = readingMethod == ReadingMethod.topToBottomContinuously
        ? -index
        : activePhotoControllerIndex;
    final scale = nativePixelScales[scaleKey];
    if (scale != null) controller.scale = scale;
  }

  ListenVolumeController? listenVolume;

  ScrollManager? scrollManager;

  String? errorMessage;
  bool isLoadingInfo = false;
  int chapterLoadRequestId = 0;
  int? loadingOrder;
  int? previousImageCacheMaximumSizeBytes;
  int? previousImageCacheMaximumSize;

  /// 进入阅读器时若按来源临时覆盖了翻页方式（`settings[9]`），这里存原值。
  ///
  /// 为什么需要它：翻页方式被十几处直接读 `appdata.settings[9]`
  /// （image_view / tool_bar / touch_control …），逐一改成"按来源解析"既容易漏，
  /// 也会让各处判断不一致。所以改为**临时改那一个值**，退出时还原 ——
  /// 期间所有读取点自动一致，且不动用户的全局设置。
  ///
  /// `null` 表示本次没有覆盖过。
  String? overriddenPageMode;

  final imageAbortSignal = StreamImageAbortSignal();

  void configureReaderCacheLimits() {
    final imageCache = PaintingBinding.instance.imageCache;
    previousImageCacheMaximumSizeBytes ??= imageCache.maximumSizeBytes;
    previousImageCacheMaximumSize ??= imageCache.maximumSize;
    imageCache.maximumSizeBytes = 96 * 1024 * 1024;
    imageCache.maximumSize = 80;
    BaseImageProvider.clearCache();
    BaseImageProvider.setCacheSizeLimit(16 * 1024 * 1024);
  }

  void restoreReaderCacheLimits() {
    BaseImageProvider.clearCache();
    BaseImageProvider.setCacheSizeLimit(50 * 1024 * 1024);
    final imageCache = PaintingBinding.instance.imageCache;
    if (previousImageCacheMaximumSizeBytes != null) {
      imageCache.maximumSizeBytes = previousImageCacheMaximumSizeBytes!;
      previousImageCacheMaximumSizeBytes = null;
    }
    if (previousImageCacheMaximumSize != null) {
      imageCache.maximumSize = previousImageCacheMaximumSize!;
      previousImageCacheMaximumSize = null;
    }
    // Surfaces and the reader session dispose their owned pixels separately.
    // Restoring the global limits already trims excess entries; keep decoded
    // list covers so returning from a reader can paint them without reloading.
  }

  void clearPhotoViewControllers() {
    for (final subscription in _transformSubscriptions) {
      unawaited(subscription.cancel());
    }
    _transformSubscriptions.clear();
    nativePixelScales.clear();
    photoViewControllers.forEach((key, value) => value.dispose());
    photoViewControllers.clear();
  }

  void abortActiveImageLoads() {
    imageAbortSignal.abort();
    _previewStopped = true;
    previewPreloader.dispose();
    previewImagePool.dispose();
    chapterLoadRequestId++;
  }

  bool noScroll = false;

  bool mouseScroll = false;

  double currentScale = 1.0;

  final _chapterPointers = <int>{};
  final _chapterGestureLogs = <String>{};
  int _chapterGesture = 0;
  int _chapterGestureOrder = 0;
  ReadingMethod? _chapterGestureMode;
  bool _chapterGestureInvalid = true;
  bool _chapterGestureConsumed = false;
  double _chapterPullDistance = 0;
  int _chapterPullDirection = 0;

  bool get hasNextChapter =>
      data.hasEp && order > 0 && order < (data.eps?.length ?? 0);
  bool get hasPreviousChapter =>
      data.hasEp && order > 1 && order <= (data.eps?.length ?? 0);

  void _clearChapterPull() {
    _chapterPullDistance = 0;
    _chapterPullDirection = 0;
    fABValue = 0;
  }

  void invalidateContinuousChapterGesture() {
    _chapterGestureInvalid = true;
    _clearChapterPull();
  }

  void resetContinuousChapterGesture() {
    _chapterPointers.clear();
    _chapterGestureLogs.clear();
    _chapterGestureConsumed = false;
    invalidateContinuousChapterGesture();
  }

  void syncContinuousChapterGesture() {
    if (_chapterGestureMode != readingMethod || _chapterGestureOrder != order) {
      invalidateContinuousChapterGesture();
    }
  }

  void beginContinuousChapterGesture(PointerDownEvent event) {
    if (_chapterPointers.isEmpty) {
      _chapterGesture++;
      _chapterGestureLogs.clear();
      _chapterGestureOrder = order;
      _chapterGestureMode = readingMethod;
      _chapterGestureConsumed = false;
      _chapterGestureInvalid =
          readingMethod != ReadingMethod.topToBottomContinuously ||
              isLoading ||
              urls.isEmpty ||
              !_kTouchLikeDeviceTypes.contains(event.kind) ||
              (event.kind == PointerDeviceKind.mouse &&
                  event.buttons != kPrimaryMouseButton);
      _clearChapterPull();
    } else {
      invalidateContinuousChapterGesture();
    }
    _chapterPointers.add(event.pointer);
  }

  void endContinuousChapterGesture(int pointer, {bool cancelled = false}) {
    if (cancelled) invalidateContinuousChapterGesture();
    _chapterPointers.remove(pointer);
    if (_chapterPointers.isEmpty) resetContinuousChapterGesture();
  }

  String? _chapterGestureRejection() {
    syncContinuousChapterGesture();
    if (_chapterPointers.isEmpty) return 'noPointer';
    if (_chapterGestureConsumed) return 'consumed';
    if (_chapterGestureInvalid || _chapterPointers.length != 1) {
      return 'invalidGesture';
    }
    if (isLoading || urls.isEmpty) {
      invalidateContinuousChapterGesture();
      return 'loading';
    }
    if (noScroll ||
        isCtrlPressed ||
        mouseScroll ||
        (photoViewControllers[0]?.scale ?? currentScale) > 1.05) {
      invalidateContinuousChapterGesture();
      return 'transformedOrLocked';
    }
    return null;
  }

  bool get canPullContinuousChapter => _chapterGestureRejection() == null;

  void trackContinuousChapterPointer(PointerMoveEvent event) {
    if (_chapterGestureRejection() != null) return;
    if ((_chapterPullDirection > 0 && event.delta.dy > 0) ||
        (_chapterPullDirection < 0 && event.delta.dy < 0) ||
        (fABValue > 0 && event.delta.dy > 0)) {
      _clearChapterPull();
    }
  }

  bool handleContinuousChapterScroll(
      ScrollNotification notification, int episode) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical ||
        episode != order ||
        _chapterGestureRejection() != null) {
      return false;
    }
    final metrics = notification.metrics;
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      final delta = notification.scrollDelta ?? 0;
      if ((_chapterPullDirection > 0 &&
              (delta < 0 || metrics.pixels < metrics.maxScrollExtent - 24)) ||
          (_chapterPullDirection < 0 &&
              (delta > 0 || metrics.pixels > metrics.minScrollExtent + 24)) ||
          (fABValue > 0 && delta < 0)) {
        _clearChapterPull();
      }
    } else if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      final direction = notification.overscroll > 0 ? 1 : -1;
      final atBoundary = direction > 0
          ? metrics.pixels >= metrics.maxScrollExtent - 24
          : metrics.pixels <= metrics.minScrollExtent + 24;
      if (!atBoundary || notification.overscroll == 0) {
        _clearChapterPull();
        return false;
      }
      if (_chapterPullDirection != direction) _clearChapterPull();
      _chapterPullDirection = direction;
      _chapterPullDistance += notification.overscroll.abs();
      if (_chapterPullDistance >= 88) {
        requestContinuousChapterChange(direction, trigger: 'overscroll');
        _clearChapterPull();
      }
    }
    return false;
  }

  Map<String, Object?> _chapterBoundarySnapshot() {
    double? finite(double? value) =>
        value != null && value.isFinite ? value : null;
    final position =
        scrollController.hasClients ? scrollController.position : null;
    final photo = photoViewControllers[0];
    return <String, Object?>{
      'chapter': order,
      'index': index,
      'pixels': finite(position?.pixels),
      'min': finite(position?.minScrollExtent),
      'max': finite(position?.maxScrollExtent),
      'scale': finite(photo?.scale),
      'x': finite(photo?.position.dx),
      'y': finite(photo?.position.dy),
      'anchors': itemScrollListener.itemPositions.value
          .take(3)
          .map((item) => {
                'index': item.index,
                'leading': finite(item.itemLeadingEdge),
                'trailing': finite(item.itemTrailingEdge),
              })
          .toList(),
    };
  }

  bool requestContinuousChapterChange(int direction,
      {required String trigger}) {
    var reason = _chapterGestureRejection();
    if (reason == null &&
        !(direction > 0 ? hasNextChapter : hasPreviousChapter)) {
      reason = 'noAdjacentChapter';
    }
    final before = _chapterBoundarySnapshot();
    final accepted = reason == null;
    if (accepted) {
      // Navigation can synchronously rebuild the list and emit more notifications.
      _chapterGestureConsumed = true;
      direction > 0 ? jumpToNextChapter() : jumpToLastChapter();
    }
    final logKey = '$trigger:$direction:${reason ?? 'accepted'}';
    if (_chapterGestureLogs.add(logKey)) {
      try {
        LogManager.addLog(
            LogLevel.info,
            'ReaderBoundary',
            jsonEncode({
              'gesture': _chapterGesture,
              'trigger': trigger,
              'direction': direction,
              'accepted': accepted,
              'reason': reason ?? 'accepted',
              'before': before,
              'after': _chapterBoundarySnapshot(),
            }));
      } catch (_) {}
    }
    return accepted;
  }

  bool get isCtrlPressed => HardwareKeyboard.instance.isControlPressed;

  List<bool> requestedLoadingItems = [];

  bool haveUsedInitialPage = false;

  /// 双页模式下是否在第一页时显示单页
  bool get singlePageForFirstScreen => appdata.implicitData[1] == '1';

  var focusNode = FocusNode();

  static int _getIndex(int initPage) {
    if (appdata.settings[9] == "5" || appdata.settings[9] == "6") {
      if (appdata.implicitData[1] == '1') {
        return initPage <= 1 ? 1 : (initPage.isEven ? initPage : initPage - 1);
      }
      return initPage % 2 == 1 ? initPage : initPage - 1;
    } else {
      return initPage;
    }
  }

  static int _getPage(int initPage) {
    if (appdata.settings[9] == "5" || appdata.settings[9] == "6") {
      return appdata.implicitData[1] == '1'
          ? (initPage + 2) ~/ 2
          : (initPage + 1) ~/ 2;
    } else {
      return initPage;
    }
  }

  ComicReadingPageLogic(
      this.order, this.data, int initialPage, this.updateHistory) {
    if (initialPage <= 0) {
      initialPage = 1;
    }
    pageController = PageController(initialPage: _getPage(initialPage));
    _index = _getIndex(initialPage);
    if (order <= 0) order = 1;
    itemScrollListener.itemPositions.addListener(() {
      final visible = itemScrollListener.itemPositions.value
          .where((p) => p.itemLeadingEdge < 1 && p.itemTrailingEdge > 0)
          .toList()
        ..sort((a, b) => a.index.compareTo(b.index));
      if (visible.isEmpty) return;
      notifyViewportChanged();
      var newIndex = visible.first.index + 1;
      if (newIndex != index) {
        index = newIndex;
        update(["ToolBar"]);
      }
    });
  }

  final void Function() updateHistory;

  ReadingData data;

  bool isLoading = true;

  ///旋转方向: null-跟随系统, false-竖向, true-横向
  bool? rotation;

  ///是否应该显示悬浮按钮, 为-1表示显示上一章, 为0表示不显示, 为1表示显示下一章
  int showFloatingButtonValue = 0;

  double fABValue = 0;

  void showFloatingButton(int value) {
    if (value == 0) {
      if (showFloatingButtonValue != 0) {
        showFloatingButtonValue = 0;
        fABValue = 0;
        update();
      }
    }
    if (value == 1 && showFloatingButtonValue == 0) {
      showFloatingButtonValue = 1;
      update();
    } else if (value == -1 && showFloatingButtonValue == 0 && order != 1) {
      showFloatingButtonValue = -1;
      update();
    }
  }

  ///当前的页面, 0和最后一个为空白页, 用于进行章节跳转
  late int _index;

  ///当前的页面, 0和最后一个为空白页, 用于进行章节跳转
  int get index => _index;

  ///当前的页面, 0和最后一个为空白页, 用于进行章节跳转
  set index(int value) {
    _index = value;
    _schedulePreviewWindow();
    for (var element in _indexChangeCallbacks) {
      element(value);
    }
    updateHistory();
  }

  final _indexChangeCallbacks = <void Function(int)>[];

  void addIndexChangeCallback(void Function(int) callback) {
    _indexChangeCallbacks.add(callback);
  }

  void removeIndexChangeCallback(void Function(int) callback) {
    _indexChangeCallbacks.remove(callback);
  }

  ///当前的章节位置, 从1开始
  int order;

  ///工具栏是否打开
  bool tools = false;

  ///是否显示设置窗口
  bool showSettings = false;

  ///所有的图片链接
  var urls = <String>[];

  void reload() {
    invalidateContinuousChapterGesture();
    index = 1;
    pageController = PageController(initialPage: 1);
    isLoading = true;
    update();
  }

  void change() {
    isLoading = !isLoading;
    update();
  }

  ReadingMethod get readingMethod =>
      ReadingMethod.values[int.parse(appdata.settings[9]) - 1];

  void jumpToNextPage() {
    if (readingMethod.index < 3) {
      pageController.jumpToPage(index + 1);
    } else if (readingMethod == ReadingMethod.topToBottomContinuously) {
      scrollController.jumpTo(scrollController.position.pixels + 600);
    } else {
      pageController.jumpToPage(pageController.page!.round() + 1);
    }
  }

  void jumpToLastPage() {
    if (readingMethod.index < 3) {
      pageController.jumpToPage(index - 1);
    } else if (readingMethod == ReadingMethod.topToBottomContinuously) {
      scrollController.jumpTo(scrollController.position.pixels - 600);
    } else {
      pageController.jumpToPage(pageController.page!.round() - 1);
    }
  }

  void jumpToPage(int i, [bool updateWidget = false]) {
    invalidateContinuousChapterGesture();
    i = i.clamp(1, length);
    if (readingMethod == ReadingMethod.topToBottomContinuously) {
      itemScrollController.jumpTo(index: i - 1);
    } else if (!readingMethod.isTwoPage) {
      pageController.jumpByDeviceType(i);
    } else {
      var index = singlePageForFirstScreen ? i ~/ 2 + 1 : (i + 1) ~/ 2;
      pageController.jumpByDeviceType(index);
    }
    if (index != i) {
      index = i;
    }
    if (updateWidget) {
      update(["ToolBar"]);
    }
  }

  void jumpByDeviceType(int page) {
    Future.microtask(() {
      if (mouseScroll) {
        pageController.jumpToPage(page);
      } else {
        pageController.animatedJumpToPage(page);
      }
    });
  }

  void jumpToNextChapter() {
    if (isLoading || urls.isEmpty) return;
    var eps = data.eps;
    if (!data.hasEp || order >= (eps?.length ?? 0)) {
      if (readingMethod != ReadingMethod.topToBottomContinuously) {
        if (readingMethod.index < 3) {
          jumpByDeviceType(urls.length);
        } else if (readingMethod == ReadingMethod.twoPage) {
          jumpByDeviceType((urls.length % 2 + urls.length) ~/ 2);
        }
      }
      return;
    }
    invalidateContinuousChapterGesture();
    showFloatingButtonValue = 0;
    order += 1;
    urls = [];
    isLoading = true;
    tools = false;
    index = 1;
    pageController = PageController(initialPage: 1);
    clearPhotoViewControllers();
    update();
  }

  void jumpToChapter(int index) {
    invalidateContinuousChapterGesture();
    order = index;
    urls = [];
    isLoading = true;
    tools = false;
    this.index = 1;
    pageController = PageController(initialPage: 1);
    clearPhotoViewControllers();
    update();
  }

  void jumpToLastChapter() {
    if (isLoading || urls.isEmpty) return;
    if (order == 1 || !data.hasEp) {
      if (readingMethod != ReadingMethod.topToBottomContinuously) {
        jumpByDeviceType(1);
      }
      return;
    }

    invalidateContinuousChapterGesture();
    showFloatingButtonValue = 0;
    order -= 1;
    urls = [];
    isLoading = true;
    tools = false;
    pageController = PageController(initialPage: 1);
    index = 1;
    clearPhotoViewControllers();
    update();
  }

  ///当前章节的长度
  int get length => urls.length;

  /// 是否处于自动翻页状态
  bool runningAutoPageTurning = false;

  /// 自动翻页
  void autoPageTurning() async {
    if (index == urls.length - 1) {
      runningAutoPageTurning = false;
      update();
      return;
    }
    int sec = int.parse(appdata.settings[33]);
    for (int i = 0; i < sec * 10; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (!runningAutoPageTurning) {
        return;
      }
    }
    jumpToNextPage();
    autoPageTurning();
  }

  void refresh_() {
    invalidateContinuousChapterGesture();
    pageController = PageController(initialPage: 1);
    itemScrollController = ItemScrollController();
    itemScrollListener = ItemPositionsListener.create();
    scrollController = ScrollController(keepScrollOffset: true);
    clearPhotoViewControllers();
    noScroll = false;
    currentScale = 1.0;
    showFloatingButtonValue = 0;
    index = 1;
    urls.clear();
    isLoading = true;
    tools = false;
    showSettings = false;
    update();
  }

  bool isFullScreen = false;

  void fullscreen() {
    if (App.isDesktop) {
      () async {
        try {
          final next = !(await windowManager.isFullScreen());
          await windowManager.setFullScreen(next);
          isFullScreen = next;
          focusNode.requestFocus();
          if (next) {
            StateController.findOrNull<WindowFrameController>()
                ?.hideWindowFrame();
          } else {
            StateController.findOrNull<WindowFrameController>()
                ?.showWindowFrame();
          }
          update(["ToolBar"]);
        } catch (_) {}
      }();
      return;
    }
    const channel = MethodChannel("pica_comic/full_screen");
    channel.invokeMethod("set", !isFullScreen);
    isFullScreen = !isFullScreen;
    focusNode.requestFocus();

    if (isFullScreen) {
      StateController.findOrNull<WindowFrameController>()?.hideWindowFrame();
    } else {
      StateController.findOrNull<WindowFrameController>()?.showWindowFrame();
    }
    update(["ToolBar"]);
  }

  void handleKeyboard(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      bool reverse = appdata.settings[9] == "2" || appdata.settings[9] == "6";
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowDown:
        case LogicalKeyboardKey.arrowRight:
          reverse ? jumpToLastPage() : jumpToNextPage();
        case LogicalKeyboardKey.arrowUp:
        case LogicalKeyboardKey.arrowLeft:
          reverse ? jumpToNextPage() : jumpToLastPage();
        case LogicalKeyboardKey.f12:
          fullscreen();
      }
    }
  }

  late final void Function() openEpsView;
}
