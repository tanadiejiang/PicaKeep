part of pica_reader;

extension ScrollExtension on ScrollController {
  static double? futurePosition;

  void smoothTo(double value) {
    futurePosition ??= position.pixels;
    futurePosition = futurePosition! + value * 1.2;
    futurePosition = futurePosition!
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    animateTo(futurePosition!,
        duration: const Duration(milliseconds: 200), curve: Curves.linear);
  }
}

const Set<PointerDeviceKind> _kTouchLikeDeviceTypes = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.mouse,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.unknown
};

extension ImageExt on ComicReadingPage {
  bool _isReaderImageWidthLimited() => appdata.settings[43] == "1";
  double _maxReaderImageWidth() =>
      (double.tryParse(appdata.settings[116]) ?? 980)
          .clamp(600, 1600)
          .toDouble();
  double _clampReaderImageWidth(double width) => _isReaderImageWidthLimited()
      ? math.min(width, _maxReaderImageWidth())
      : width;

  Widget buildComicView(
      ComicReadingPageLogic logic, BuildContext context, String target) {
    ScrollExtension.futurePosition = null;
    final decoration = BoxDecoration(
        color: useDarkBackground
            ? Colors.black
            : Theme.of(context).colorScheme.surface);
    final mode = readerDisplayMode(
        sourceKey: logic.data.sourceKey,
        pipelineSetting: appdata.settings[readerImagePipelineSettingIndex]);
    final viewportKey = logic.readerViewportKey;
    double topPullDistance = 0;
    double bottomPullDistance = 0;

    BoxFit getFit() => switch (appdata.settings[41]) {
          "1" => BoxFit.fitWidth,
          "2" => BoxFit.fitHeight,
          _ => BoxFit.contain,
        };

    Widget page(int imageIndex,
        {PhotoViewController? controller,
        double? continuousWidth,
        Alignment alignment = Alignment.center,
        BoxFit fit = BoxFit.contain,
        int? controllerIndex}) {
      if (imageIndex < 0 || imageIndex >= logic.urls.length) {
        return const SizedBox();
      }
      final episode = logic.order;
      final url = logic.urls[imageIndex];
      return ReaderPageImage(
        key: ValueKey('$episode:$imageIndex:$url'),
        resourceKey: '$episode:$imageIndex:$url',
        loadSource: () =>
            logic.data.resolvePageSource(episode, imageIndex, url),
        loadCachedPreview: (original) =>
            logic.data.loadCachedPreview(episode, imageIndex, url, original),
        viewportKey: viewportKey,
        sessionRasterCache: logic.sessionRasterCache,
        transformChanges: logic.viewportChanges,
        mode: mode,
        controller: controller,
        continuousWidth: continuousWidth,
        fit: fit,
        alignment: alignment,
        backgroundDecoration: decoration,
        nativeScaleChanged: controllerIndex == null
            ? null
            : (scale) => logic.nativePixelScales[controllerIndex] = logic
                    .readingMethod.isTwoPage
                ? math.max(logic.nativePixelScales[controllerIndex] ?? 0, scale)
                : scale,
      );
    }

    bool handleContinuousOverscroll(OverscrollNotification notification) {
      if (!logic.data.hasEp) return false;
      final metrics = notification.metrics;
      if (notification.overscroll > 0 &&
          metrics.pixels >= metrics.maxScrollExtent - 24) {
        bottomPullDistance += notification.overscroll;
        topPullDistance = 0;
        if (bottomPullDistance >= 88) {
          bottomPullDistance = 0;
          logic.jumpToNextChapter();
        }
      } else if (notification.overscroll < 0 &&
          metrics.pixels <= metrics.minScrollExtent + 24) {
        topPullDistance += -notification.overscroll;
        bottomPullDistance = 0;
        if (topPullDistance >= 88) {
          topPullDistance = 0;
          logic.jumpToLastChapter();
        }
      } else {
        topPullDistance = 0;
        bottomPullDistance = 0;
      }
      return false;
    }

    Widget continuous() => LayoutBuilder(builder: (context, constraints) {
          final width = _clampReaderImageWidth(constraints.maxWidth);
          return NotificationListener<OverscrollNotification>(
            onNotification: handleContinuousOverscroll,
            child: Center(
                child: SizedBox(
              width: width,
              child: ScrollablePositionedList.builder(
                itemScrollController: logic.itemScrollController,
                itemPositionsListener: logic.itemScrollListener,
                itemCount: logic.urls.length,
                addSemanticIndexes: false,
                minCacheExtent: MediaQuery.of(context).size.height,
                scrollController: logic.scrollController,
                scrollBehavior: const MaterialScrollBehavior().copyWith(
                    scrollbars: false, dragDevices: _kTouchLikeDeviceTypes),
                physics:
                    (logic.noScroll || logic.isCtrlPressed || logic.mouseScroll)
                        ? const NeverScrollableScrollPhysics()
                        : const ClampingScrollPhysics(),
                itemBuilder: (_, index) => page(index,
                    continuousWidth: width, controllerIndex: -(index + 1)),
              ),
            )),
          );
        });

    Widget single() => LayoutBuilder(builder: (context, constraints) {
          final axis =
              appdata.settings[9] == "3" ? Axis.vertical : Axis.horizontal;
          return DecoratedBox(
              decoration: decoration,
              child: Center(
                child: SizedBox(
                  width: _clampReaderImageWidth(constraints.maxWidth),
                  height: constraints.maxHeight,
                  child: PageView.builder(
                    key: ValueKey(
                        'single:${logic.order}:${logic.readingMethod.index}'),
                    controller: logic.pageController,
                    reverse: appdata.settings[9] == "2",
                    scrollDirection: axis,
                    itemCount: logic.urls.length + 2,
                    itemBuilder: (_, index) {
                      if (index == 0 || index == logic.urls.length + 1) {
                        return const SizedBox();
                      }
                      return PhotoViewGestureDetectorScope(
                          axis: axis,
                          child: page(index - 1,
                              controller:
                                  logic.ensurePhotoViewController(index),
                              controllerIndex: index,
                              fit: getFit()));
                    },
                    onPageChanged: (i) {
                      if (i == 0) {
                        if (!logic.data.hasEp) {
                          logic.jumpByDeviceType(1);
                          return;
                        }
                        logic.jumpToLastChapter();
                      } else if (i == logic.urls.length + 1) {
                        if (!logic.data.hasEp) {
                          logic.jumpByDeviceType(i - 1);
                          return;
                        }
                        logic.jumpToNextChapter();
                      } else {
                        logic.index = i;
                        logic.update();
                      }
                    },
                  ),
                ),
              ));
        });

    Widget doublePage() => LayoutBuilder(builder: (context, constraints) {
          int count = (logic.urls.length + 1) ~/ 2;
          if (logic.urls.length.isEven && logic.singlePageForFirstScreen) {
            count++;
          }
          final itemCount = count + 2;
          final width = _clampReaderImageWidth(constraints.maxWidth);
          return DecoratedBox(
              decoration: decoration,
              child: Center(
                child: SizedBox(
                  width: width,
                  height: constraints.maxHeight,
                  child: PhotoViewGallery.builder(
                    key: ValueKey(
                        'double:${logic.order}:${logic.readingMethod.index}'),
                    backgroundDecoration: decoration,
                    itemCount: itemCount,
                    reverse:
                        logic.readingMethod == ReadingMethod.twoPageReversed,
                    pageController: logic.pageController,
                    builder: (_, index) {
                      if (index == 0 || index == itemCount - 1) {
                        return PhotoViewGalleryPageOptions.customChild(
                            child: const SizedBox());
                      }
                      final first = index * 2 -
                          2 -
                          (logic.singlePageForFirstScreen ? 1 : 0);
                      var images = [first, first + 1];
                      if (logic.readingMethod ==
                          ReadingMethod.twoPageReversed) {
                        images = images.reversed.toList();
                      }
                      return PhotoViewGalleryPageOptions.customChild(
                          controller: logic.ensurePhotoViewController(index),
                          childSize: Size(width, constraints.maxHeight),
                          minScale: 1.0,
                          initialScale: 1.0,
                          maxScale: 64.0,
                          child: Row(children: [
                            Expanded(
                                child: page(images[0],
                                    controllerIndex: index,
                                    alignment: Alignment.centerRight)),
                            Expanded(
                                child: page(images[1],
                                    controllerIndex: index,
                                    alignment: Alignment.centerLeft)),
                          ]));
                    },
                    onPageChanged: (i) {
                      if (i == 0) {
                        if (!logic.data.hasEp || logic.order == 1) {
                          logic.pageController.jumpByDeviceType(1);
                          return;
                        }
                        logic.jumpToLastChapter();
                      } else if (i == itemCount - 1) {
                        if (!logic.data.hasEp ||
                            logic.order == logic.data.eps?.length) {
                          logic.pageController.jumpByDeviceType(i - 1);
                          return;
                        }
                        logic.jumpToNextChapter();
                      } else {
                        logic.index = logic.singlePageForFirstScreen
                            ? (i * 2 - 2).clamp(1, logic.urls.length)
                            : i * 2 - 1;
                        logic.update();
                      }
                    },
                  ),
                ),
              ));
        });

    final Widget body;
    if (logic.readingMethod.index < 3) {
      body = single();
    } else if (logic.readingMethod == ReadingMethod.topToBottomContinuously) {
      body = PhotoView.customChild(
        backgroundDecoration: decoration,
        key: ValueKey('continuous:${logic.order}'),
        minScale: 1.0,
        maxScale: 64.0,
        strictScale: true,
        controller: logic.ensurePhotoViewController(0),
        onScaleEnd: (context, detail, value) {
          final previous = logic.currentScale;
          logic.currentScale = value.scale ?? 1;
          if ((previous <= 1.05) != (logic.currentScale <= 1.05)) {
            logic.update();
          }
          return appdata.settings[43] == "1" &&
              updateLocation(context, logic.photoViewController);
        },
        child: continuous(),
      );
    } else {
      body = doublePage();
    }

    void onPointerSignal(PointerSignalEvent signal) {
      logic.mouseScroll = signal.kind == PointerDeviceKind.mouse;
      if (signal is! PointerScrollEvent || logic.isCtrlPressed) return;
      if (logic.readingMethod != ReadingMethod.topToBottomContinuously) {
        signal.scrollDelta.dy > 0
            ? logic.jumpToNextPage()
            : logic.jumpToLastPage();
      } else if (logic.scrollController.hasClients) {
        final position = logic.scrollController.position;
        if ((position.pixels == position.minScrollExtent &&
                signal.scrollDelta.dy < 0) ||
            (position.pixels == position.maxScrollExtent &&
                signal.scrollDelta.dy > 0)) {
          logic.photoViewController.updateMultiple(
              position: logic.photoViewController.position -
                  Offset(0, signal.scrollDelta.dy));
        } else if (!App.isMacOS) {
          logic.scrollController.smoothTo(signal.scrollDelta.dy);
        }
      }
    }

    return Positioned.fill(
      top: App.isDesktop ? MediaQuery.of(context).padding.top : 0,
      child: SizedBox(
        key: viewportKey,
        child: Listener(
          onPointerSignal: onPointerSignal,
          onPointerPanZoomUpdate: (event) {
            if (event.kind == PointerDeviceKind.trackpad &&
                event.scale == 1.0 &&
                logic.readingMethod == ReadingMethod.topToBottomContinuously) {
              logic.scrollController.smoothTo(-event.panDelta.dy * 1.2);
            }
          },
          onPointerDown: (_) => logic.mouseScroll = false,
          child: NotificationListener<ScrollUpdateNotification>(
            child: body,
            onNotification: (_) {
              logic.notifyViewportChanged();
              TapController.lastScrollTime = DateTime.now();
              if (!logic.scrollController.hasClients) return false;
              final position = logic.scrollController.position;
              if (position.pixels <= position.minScrollExtent &&
                  logic.order > 1) {
                logic.showFloatingButton(-1);
              } else if (position.pixels >= position.maxScrollExtent &&
                  logic.order < (logic.data.eps?.length ?? 1)) {
                logic.showFloatingButton(1);
              } else {
                logic.showFloatingButton(0);
              }
              return true;
            },
          ),
        ),
      ),
    );
  }

  /// create a image provider
  ImageProvider createImageProvider(
      ReadingType type, ComicReadingPageLogic logic, int index, String target) {
    return logic.data.createImageProvider(
      logic.order,
      index,
      logic.urls[index],
      abortSignal: logic.imageAbortSignal,
    );
  }

  /// check current location of [PageView], update location when it is out of range.
  bool updateLocation(BuildContext context, PhotoViewController controller) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;
    if (width / height < 1.2) {
      return false;
    }
    final currentLocation = controller.position;
    final scale = controller.scale ?? 1;
    double imageWidth = height / 1.2;
    if (_isReaderImageWidthLimited()) {
      imageWidth = _clampReaderImageWidth(imageWidth);
    }
    final showWidth = width / scale;
    if (showWidth >= imageWidth && currentLocation.dx != 0) {
      controller.updateMultiple(
          position: Offset(controller.initial.position.dx, currentLocation.dy));
      return true;
    }
    if (showWidth < imageWidth) {
      final lEdge = (width - imageWidth) / 2;
      final rEdge = width - lEdge;
      final showLEdge =
          (0 - currentLocation.dx) / scale - showWidth / 2 + width / 2;
      final showREdge =
          (0 - currentLocation.dx) / scale + showWidth / 2 + width / 2;
      final updateValue = (width / 2 - (rEdge - showWidth / 2)) * scale;
      if (lEdge > showLEdge) {
        controller.updateMultiple(
            position: Offset(0 - updateValue, currentLocation.dy));
        return true;
      } else if (rEdge < showREdge) {
        controller.updateMultiple(
            position: Offset(updateValue, currentLocation.dy));
        return true;
      }
    }
    return false;
  }

  // PageView's adjacent pages and one continuous viewport provide bounded
  // original-file prefetch. No whole-image precache or fictitious idle queue.
}
