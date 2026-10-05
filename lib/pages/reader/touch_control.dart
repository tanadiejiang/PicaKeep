part of pica_reader;

const _kMaxTapOffset = 4.0;

/// Control scroll when readingMethod is [ReadingMethod.topToBottomContinuously]
/// and the image has been enlarge
class ScrollManager {
  ComicReadingPageLogic logic;

  ScrollManager(this.logic);

  Offset? tapLocation;

  int? startTime;

  Offset? moveOffset;

  int get fingers => TapController.fingers;

  void tapDown(PointerDownEvent details) {
    moveOffset = Offset.zero;
    startTime = DateTime.now().millisecondsSinceEpoch;
    var logic = StateController.find<ComicReadingPageLogic>();
    var temp = logic.noScroll;
    logic.noScroll = fingers >= 2;
    if (temp != logic.noScroll) {
      logic.update();
    }
  }

  void tapUp(PointerUpEvent details) {
    var logic = StateController.find<ComicReadingPageLogic>();
    var temp = logic.noScroll;
    logic.noScroll = fingers >= 2;
    if (temp != logic.noScroll) {
      logic.update();
    }
    tapLocation = null;

    if (moveOffset != null && moveOffset != Offset.zero) {
      if (moveOffset!.dx * moveOffset!.dx + moveOffset!.dy * moveOffset!.dy >
          400) {
        final offset = moveOffset! /
            (DateTime.now().millisecondsSinceEpoch - startTime!).toDouble() *
            100;
        logic.photoViewController.animatePosition?.call(
            logic.photoViewController.position,
            logic.photoViewController.position + offset);
      }
    }
    moveOffset = null;
    startTime = null;
    if (logic.fABValue < 58) {
      logic.fABValue = 0;
      logic.update(["FAB"]);
    } else if (logic.fABValue >= 58) {
      logic.fABValue = 0;
      logic.jumpToNextChapter();
    }
  }

  void tapCancel() {
    final previousNoScroll = logic.noScroll;
    logic.noScroll = fingers >= 2;
    tapLocation = null;
    moveOffset = null;
    startTime = null;
    logic.fABValue = 0;
    if (previousNoScroll != logic.noScroll) logic.update();
    logic.update(["FAB"]);
  }

  /// handle pointer move event
  void addOffset(Offset value) {
    if (logic.scrollController.offset ==
            logic.scrollController.position.maxScrollExtent &&
        logic.photoViewController.scale == 1 &&
        logic.showFloatingButtonValue == 1) {
      logic.fABValue -= value.dy / 3;
      logic.update(["FAB"]);
      return;
    }
    if (logic.photoViewController.scale == 1) {
      return;
    }
    if (moveOffset != null) {
      moveOffset = moveOffset! + value;
    }
    if (logic.scrollController.offset !=
            logic.scrollController.position.maxScrollExtent &&
        logic.scrollController.offset !=
            logic.scrollController.position.minScrollExtent) {
      value = Offset(value.dx, 0);
    }
    logic.photoViewController
        .updateMultiple(position: logic.photoViewController.position + value);
    return;
  }
}

class _TapDownPointer {
  int id;
  Offset offset;

  double getDistance() {
    return offset.dx * offset.dx + offset.dy * offset.dy;
  }

  _TapDownPointer(this.id) : offset = const Offset(0, 0);
}

class TapController {
  static final _activePointers = <int>{};
  static bool _multiPointerInteraction = false;
  static int _gestureGeneration = 0;
  static Timer? _longPressTimer;

  static Offset? _tapOffset;

  static DateTime lastScrollTime = DateTime(2023);

  static bool ignoreNextTap = false;

  static bool longTimePressScale = false;

  static _TapDownPointer? _tapDownPointer;

  static void Function(PointerUpEvent event)? onTapUpReplacement;

  static int fingers = 0;

  /// Pending tap/long-press callbacks belong to one reader session only.
  static void reset() {
    _gestureGeneration++;
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _activePointers.clear();
    _multiPointerInteraction = false;
    fingers = 0;
    _tapOffset = null;
    _tapDownPointer = null;
    _doubleClickRecognizer = null;
    onTapUpReplacement = null;
    ignoreNextTap = false;
    longTimePressScale = false;
  }

  static void onTapCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    fingers = _activePointers.length;
    _gestureGeneration++;
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _tapOffset = null;
    _tapDownPointer = null;
    _doubleClickRecognizer = null;
    onTapUpReplacement = null;
    if (_activePointers.isEmpty) _multiPointerInteraction = false;
    final logic = StateController.findOrNull<ComicReadingPageLogic>();
    if (appdata.settings[9] == "4") logic?.scrollManager?.tapCancel();
  }

  static void onTapDown(PointerDownEvent event, BuildContext context) {
    if (event.buttons == kSecondaryMouseButton) {
      handleSecondaryTapUp(event, context);
      return;
    }
    if (_activePointers.isEmpty) _multiPointerInteraction = false;
    _activePointers.add(event.pointer);
    fingers = _activePointers.length;
    final isMultiPointer = fingers > 1;
    if (isMultiPointer) {
      // PhotoView owns pinch gestures. A remaining stationary finger must not
      // later turn the pinch into a tap, double tap, or long-press zoom.
      _multiPointerInteraction = true;
      _gestureGeneration++;
      _longPressTimer?.cancel();
      _longPressTimer = null;
      _tapOffset = null;
      _tapDownPointer = null;
      _doubleClickRecognizer = null;
      onTapUpReplacement = null;
    }
    if (ignoreNextTap) {
      ignoreNextTap = false;
      return;
    }
    var logic = StateController.find<ComicReadingPageLogic>();

    if (!isMultiPointer && appdata.settings[55] == "1") {
      _tapDownPointer = _TapDownPointer(event.pointer);
      final generation = _gestureGeneration;
      _longPressTimer?.cancel();
      _longPressTimer = Timer(const Duration(milliseconds: 300), () {
        if (generation == _gestureGeneration &&
            !_multiPointerInteraction &&
            _activePointers.length == 1 &&
            event.pointer == _tapDownPointer?.id) {
          onTapUpReplacement = _handleLongPressEnd;
          _handleLongPressStart(event.position);
        }
      });
    }

    if (appdata.settings[9] == "4") {
      logic.scrollManager!.tapDown(event);
    }

    if (_multiPointerInteraction) return;

    if (logic.tools &&
        (event.position.dy <
                MediaQuery.of(App.globalContext!).padding.top + 50 ||
            MediaQuery.of(App.globalContext!).size.height - event.position.dy <
                105 + MediaQuery.of(App.globalContext!).padding.bottom)) {
      return;
    }

    if (event.buttons == kSecondaryMouseButton) {
      if (logic.showSettings) {
        logic.showSettings = false;
        logic.update();
        return;
      }
      logic.tools = !logic.tools;
      logic.update();
      if (logic.tools) {
        _showReaderSystemUi(
          useDarkBackground: appdata.appSettings.useDarkBackground,
        );
      } else {
        _hideReaderSystemUi(
          useDarkBackground: appdata.appSettings.useDarkBackground,
        );
      }
      return;
    }

    if (!logic.scrollController.hasClients) {
      _tapOffset = event.position;
    } else if (logic.scrollController.hasClients &&
        (DateTime.now() - lastScrollTime).inMilliseconds > 50) {
      _tapOffset = event.position;
    }
  }

  static bool Function(PointerUpEvent detail)? _doubleClickRecognizer;

  static void handleSecondaryTapUp(
      PointerDownEvent detail, BuildContext context) {
    var logic = StateController.find<ComicReadingPageLogic>();
    showMenu(
        context: context,
        position: RelativeRect.fromLTRB(detail.position.dx, detail.position.dy,
            detail.position.dx, detail.position.dy),
        items: [
          PopupMenuItem(
            child: Text("设置".tl),
            onTap: () => showSettings(context),
          ),
          if (App.isWindows)
            PopupMenuItem(
              onTap: logic.fullscreen,
              child: Text("全屏".tl),
            ),
          PopupMenuItem(
            child: Text("退出".tl),
            onTap: () => unawaited(App.maybePopActiveRoute(context: context)),
          ),
          if (logic.data.hasEp)
            PopupMenuItem(
              onTap: logic.openEpsView,
              child: Text("章节".tl),
            ),
        ]);
  }

  static void onTapUp(PointerUpEvent detail, BuildContext context) async {
    if (!_activePointers.remove(detail.pointer)) return;
    _longPressTimer?.cancel();
    _longPressTimer = null;
    fingers = _activePointers.length;
    final wasMultiPointer = _multiPointerInteraction;
    if (_activePointers.isEmpty) _multiPointerInteraction = false;
    if (!wasMultiPointer && onTapUpReplacement != null) {
      onTapUpReplacement!(detail);
      onTapUpReplacement = null;
      return;
    }

    var logic = StateController.find<ComicReadingPageLogic>();

    _tapDownPointer = null;

    if (appdata.settings[9] == "4") {
      if (wasMultiPointer) {
        logic.scrollManager!.tapCancel();
      } else {
        logic.scrollManager!.tapUp(detail);
      }
    }

    if (wasMultiPointer) {
      _tapOffset = null;
      return;
    }

    if (_tapOffset != null) {
      var distance = (detail.position - _tapOffset!).distanceSquared;
      _tapOffset = null;
      if (distance > _kMaxTapOffset || distance < -_kMaxTapOffset) {
        return;
      }
    } else {
      return;
    }

    final screenSize = MediaQuery.sizeOf(context);

    if (appdata.settings[49] == "1") {
      if (_doubleClickRecognizer == null) {
        bool flag = false;
        final generation = _gestureGeneration;
        bool recognize(PointerUpEvent another) {
          final delta = detail.position - another.position;
          if (delta.distanceSquared <= 30 * 30) {
            flag = true;
            return true;
          }
          return false;
        }

        _doubleClickRecognizer = recognize;
        await Future.delayed(const Duration(milliseconds: 200));
        if (identical(_doubleClickRecognizer, recognize)) {
          _doubleClickRecognizer = null;
        }
        if (generation != _gestureGeneration ||
            !context.mounted ||
            StateController.findOrNull<ComicReadingPageLogic>() != logic) {
          return;
        }
        if (flag) {
          _handleDoubleClick(detail.position);
          return;
        }
      } else {
        if (_doubleClickRecognizer!.call(detail)) return;
        _doubleClickRecognizer = null;
      }
    }

    _handleClick(detail, logic, screenSize);
  }

  static void onPointerMove(PointerMoveEvent event) {
    final logic = StateController.find<ComicReadingPageLogic>();
    if (event.pointer == _tapDownPointer?.id) {
      _tapDownPointer!.offset += event.delta;
      if (_tapDownPointer!.getDistance() > 1) {
        _tapDownPointer = null;
        _longPressTimer?.cancel();
        _longPressTimer = null;
      }
    }
    if (appdata.settings[9] == "4" && logic.scrollManager!.fingers < 2) {
      logic.scrollManager!.addOffset(event.delta);
    }
  }

  static void _handleClick(
      PointerUpEvent detail, ComicReadingPageLogic logic, Size screenSize) {
    bool flag = false;
    bool flag2 = false;
    final range = int.parse(appdata.settings[40]) / 100;
    if (appdata.settings[0] == "1" && !logic.tools) {
      void updatePageWithSetting(bool next) {
        if (appdata.settings[70] == "1") {
          next = !next;
        }
        next ? logic.jumpToNextPage() : logic.jumpToLastPage();
      }

      switch (appdata.settings[9]) {
        case "1":
        case "5":
          detail.position.dx > screenSize.width * (1 - range)
              ? updatePageWithSetting(true)
              : flag = true;
          detail.position.dx < screenSize.width * range
              ? updatePageWithSetting(false)
              : flag2 = true;
          break;
        case "2":
        case "6":
          detail.position.dx > screenSize.width * (1 - range)
              ? updatePageWithSetting(false)
              : flag = true;
          detail.position.dx < screenSize.width * range
              ? updatePageWithSetting(true)
              : flag2 = true;
          break;
        case "3":
          detail.position.dy > screenSize.height * (1 - range)
              ? updatePageWithSetting(true)
              : flag = true;
          detail.position.dy < screenSize.height * range
              ? updatePageWithSetting(false)
              : flag2 = true;
          break;
        case "4":
          detail.position.dy > screenSize.height * (1 - range)
              ? logic.jumpToNextPage()
              : flag = true;
          detail.position.dy < screenSize.height * range
              ? logic.jumpToLastPage()
              : flag2 = true;
          break;
      }
    } else {
      flag = flag2 = true;
    }
    if (flag && flag2) {
      logic.tools = !logic.tools;
      logic.update(["ToolBar"]);
      if (logic.tools) {
        _showReaderSystemUi(
          useDarkBackground: appdata.appSettings.useDarkBackground,
        );
        StateController.findOrNull<WindowFrameController>()?.resetTheme();
      } else {
        _hideReaderSystemUi(
          useDarkBackground: appdata.appSettings.useDarkBackground,
        );
        if (appdata.settings[81] == "1") {
          StateController.findOrNull<WindowFrameController>()?.setDarkTheme();
        }
      }
    }
  }

  static void _handleDoubleClick(Offset position) async {
    var logic = StateController.find<ComicReadingPageLogic>();
    var controller = logic.photoViewController;
    double target;
    if (controller.scale == null ||
        controller.getInitialScale?.call() == null) {
      return;
    }
    if (!logic.readingMethod.useComicImage) {
      controller.onDoubleClick?.call();
      return;
    }
    if (controller.scale != controller.getInitialScale?.call()) {
      target = controller.getInitialScale!.call()!;
    } else {
      target = controller.getInitialScale!.call()! * 1.75;
    }
    var size = MediaQuery.of(App.globalContext!).size;
    controller.animateScale?.call(target,
        Offset(size.width / 2 - position.dx, size.height / 2 - position.dy));
  }

  static void _handleLongPressStart(Offset position) {
    var logic = StateController.find<ComicReadingPageLogic>();
    var controller = logic.photoViewController;
    if (controller.scale != controller.getInitialScale?.call() ||
        controller.scale == null ||
        controller.getInitialScale?.call() == null) {
      return;
    }
    final target = controller.getInitialScale!.call()! * 1.75;
    var size = MediaQuery.of(App.globalContext!).size;
    controller.animateScale?.call(target,
        Offset(size.width / 2 - position.dx, size.height / 2 - position.dy));
    controller.updateState?.call(null);
  }

  static void _handleLongPressEnd(PointerUpEvent event) {
    var logic = StateController.find<ComicReadingPageLogic>();
    var controller = logic.photoViewController;
    if (controller.scale == controller.getInitialScale?.call() ||
        controller.scale == null) {
      return;
    }
    final target = controller.getInitialScale?.call();
    controller.animateScale?.call(target ?? 1);
    controller.updateState?.call(null);
  }
}
