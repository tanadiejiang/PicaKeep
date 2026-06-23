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

class _ReaderImageRequest {
  const _ReaderImageRequest({required this.provider});

  final ImageProvider provider;
}

extension ImageExt on ComicReadingPage {
  bool _isReaderImageWidthLimited() {
    return appdata.settings[43] == "1";
  }

  double _maxReaderImageWidth() {
    return (double.tryParse(appdata.settings[116]) ?? 980)
        .clamp(600, 1600)
        .toDouble();
  }

  double _clampReaderImageWidth(double rawWidth) {
    if (!_isReaderImageWidthLimited()) {
      return rawWidth;
    }
    return math.min(rawWidth, _maxReaderImageWidth());
  }

  bool _shouldUseOriginalLocalImageStrategy(ComicReadingPageLogic logic) {
    return logic.data.supportsLocalImageSort;
  }

  _ReaderImageRequest _createReaderImageRequest(
    BuildContext context,
    ComicReadingPageLogic logic,
    int index,
    String target, {
    double? layoutWidth,
  }) {
    final provider = createImageProvider(type, logic, index, target);
    if (_shouldUseOriginalLocalImageStrategy(logic)) {
      return _ReaderImageRequest(provider: provider);
    }
    final mediaQuery = MediaQuery.of(context);
    final devicePixelRatio =
        mediaQuery.devicePixelRatio.clamp(1.0, 2.5).toDouble();
    final size = mediaQuery.size;

    int? cacheWidth;

    if (logic.readingMethod == ReadingMethod.topToBottomContinuously) {
      final width = layoutWidth ?? size.width;
      cacheWidth = (width * devicePixelRatio).round();
    } else if (logic.readingMethod.isTwoPage) {
      cacheWidth = ((size.width / 2) * devicePixelRatio * 1.35).round();
    } else {
      cacheWidth = (size.width * devicePixelRatio * 1.6).round();
    }

    return _ReaderImageRequest(
      provider: ResizeImage.resizeIfNeeded(cacheWidth, null, provider),
    );
  }

  /// build comic image
  Widget buildComicView(
      ComicReadingPageLogic logic, BuildContext context, String target) {
    ScrollExtension.futurePosition = null;
    double topPullDistance = 0;
    double bottomPullDistance = 0;

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

    Widget buildType4() {
      return LayoutBuilder(
        builder: (context, constraints) {
          final decodeWidth = constraints.maxWidth;
          final listWidth = _clampReaderImageWidth(constraints.maxWidth);
          return NotificationListener<OverscrollNotification>(
            onNotification: handleContinuousOverscroll,
            child: Center(
              child: SizedBox(
                width: listWidth,
                child: ScrollablePositionedList.builder(
                  itemScrollController: logic.itemScrollController,
                  itemPositionsListener: logic.itemScrollListener,
                  itemCount: logic.urls.length,
                  addSemanticIndexes: false,
                  minCacheExtent: MediaQuery.of(context).size.height * 3,
                  scrollController: logic.scrollController,
                  scrollBehavior: const MaterialScrollBehavior().copyWith(
                      scrollbars: false, dragDevices: _kTouchLikeDeviceTypes),
                  physics: (logic.noScroll ||
                          logic.isCtrlPressed ||
                          logic.mouseScroll)
                      ? const NeverScrollableScrollPhysics()
                      : const ClampingScrollPhysics(),
                  itemBuilder: (context, index) {
                    return LayoutBuilder(builder: (context, constraints) {
                      final width = constraints.maxWidth;

                      precacheComicImage(logic, context, index + 1, target);

                      if (_shouldUseOriginalLocalImageStrategy(logic)) {
                        return Center(
                          child: ComicImage(
                            filterQuality: FilterQuality.medium,
                            image:
                                createImageProvider(type, logic, index, target),
                            knownImageSize: logic.data.imageSize(
                              logic.order,
                              index,
                              logic.urls[index],
                            ),
                            width: width,
                            fit: BoxFit.contain,
                          ),
                        );
                      }

                      final imageRequest = _createReaderImageRequest(
                        context,
                        logic,
                        index,
                        target,
                        layoutWidth: decodeWidth,
                      );
                      return Center(
                        child: ComicImage(
                          filterQuality: FilterQuality.medium,
                          image: imageRequest.provider,
                          knownImageSize: logic.data.imageSize(
                            logic.order,
                            index,
                            logic.urls[index],
                          ),
                          width: width,
                          fit: BoxFit.contain,
                        ),
                      );
                    });
                  },
                ),
              ),
            ),
          );
        },
      );
    }

    final decoration = BoxDecoration(
      color: useDarkBackground
          ? Colors.black
          : Theme.of(context).colorScheme.surface,
    );

    Widget buildType123() {
      return LayoutBuilder(
        builder: (context, constraints) {
          final galleryWidth = _clampReaderImageWidth(constraints.maxWidth);
          return DecoratedBox(
            decoration: decoration,
            child: Center(
              child: SizedBox(
                width: galleryWidth,
                height: constraints.maxHeight,
                child: PhotoViewGallery.builder(
                  backgroundDecoration: decoration,
                  key: Key(logic.readingMethod.index.toString()),
                  reverse: appdata.settings[9] == "2",
                  scrollDirection: appdata.settings[9] != "3"
                      ? Axis.horizontal
                      : Axis.vertical,
                  itemCount: logic.urls.length + 2,
                  builder: (BuildContext context, int index) {
                    ImageProvider? imageProvider;
                    if (index != 0 && index != logic.urls.length + 1) {
                      if (_shouldUseOriginalLocalImageStrategy(logic)) {
                        imageProvider =
                            createImageProvider(type, logic, index - 1, target);
                      } else {
                        imageProvider = _createReaderImageRequest(
                          context,
                          logic,
                          index - 1,
                          target,
                          layoutWidth: galleryWidth,
                        ).provider;
                      }
                    } else {
                      return PhotoViewGalleryPageOptions.customChild(
                        scaleStateController: PhotoViewScaleStateController(),
                        child: const SizedBox(),
                      );
                    }

                    precacheComicImage(logic, context, index, target);

                    BoxFit getFit() {
                      switch (appdata.settings[41]) {
                        case "1":
                          return BoxFit.fitWidth;
                        case "2":
                          return BoxFit.fitHeight;
                        default:
                          return BoxFit.contain;
                      }
                    }

                    logic.photoViewControllers[index] ??= PhotoViewController();

                    return PhotoViewGalleryPageOptions(
                      filterQuality: FilterQuality.medium,
                      imageProvider: imageProvider,
                      fit: getFit(),
                      controller: logic.photoViewControllers[index],
                      errorBuilder: (_, error, s, retry) {
                        return Center(
                          child: SizedBox(
                            height: 300,
                            width: 400,
                            child: Column(
                              children: [
                                Expanded(
                                  child: Center(
                                    child: Text(
                                      error.toString(),
                                      style: TextStyle(
                                          color: appdata
                                                  .appSettings.useDarkBackground
                                              ? Colors.white
                                              : null),
                                      maxLines: 3,
                                    ),
                                  ),
                                ),
                                const SizedBox(
                                  height: 4,
                                ),
                                MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: Listener(
                                    onPointerDown: (details) {
                                      TapController.ignoreNextTap = true;
                                      retry();
                                    },
                                    child: const SizedBox(
                                      width: 84,
                                      height: 36,
                                      child: Center(
                                        child: Text(
                                          "Retry",
                                          style: TextStyle(color: Colors.blue),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(
                                  height: 16,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                      heroAttributes: PhotoViewHeroAttributes(
                          tag: "$index/${logic.urls.length}"),
                    );
                  },
                  pageController: logic.pageController,
                  loadingBuilder: (context, event) => Center(
                    child: SizedBox(
                      width: 20.0,
                      height: 20.0,
                      child: CircularProgressIndicator(
                        backgroundColor:
                            context.colorScheme.surfaceContainerHigh,
                        value: event == null || event.expectedTotalBytes == null
                            ? null
                            : event.cumulativeBytesLoaded /
                                event.expectedTotalBytes!,
                      ),
                    ),
                  ),
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
            ),
          );
        },
      );
    }

    Widget buildComicImageOrEmpty(
        {required int imageIndex,
        required BoxFit fit,
        required Alignment alignment,
        double? layoutWidth}) {
      if (imageIndex < 0 || imageIndex >= logic.urls.length) {
        return const SizedBox();
      }

      final imageRequest = _createReaderImageRequest(
        context,
        logic,
        imageIndex,
        target,
        layoutWidth: layoutWidth,
      );
      return ComicImage(
        key: ValueKey(imageIndex),
        image: imageRequest.provider,
        knownImageSize: logic.data.imageSize(
          logic.order,
          imageIndex,
          logic.urls[imageIndex],
        ),
        fit: fit,
        alignment: alignment,
      );
    }

    Widget buildType56() {
      int calcItemCount() {
        int count = logic.urls.length ~/ 2;
        if (logic.urls.length % 2 != 0) {
          count++;
        } else if (logic.singlePageForFirstScreen) {
          count++;
        }
        return count + 2;
      }

      return LayoutBuilder(
        builder: (context, constraints) {
          final galleryWidth = _clampReaderImageWidth(constraints.maxWidth);
          final pageWidth = galleryWidth / 2;
          return DecoratedBox(
            decoration: decoration,
            child: Center(
              child: SizedBox(
                width: galleryWidth,
                height: constraints.maxHeight,
                child: PhotoViewGallery.builder(
                  key: Key(logic.readingMethod.index.toString()),
                  backgroundDecoration: decoration,
                  itemCount: calcItemCount(),
                  reverse: logic.readingMethod == ReadingMethod.twoPageReversed,
                  builder: (BuildContext context, int index) {
                    if (index == 0 || index == calcItemCount() - 1) {
                      return PhotoViewGalleryPageOptions.customChild(
                          child: const SizedBox());
                    }
                    precacheComicImage(logic, context, index * 2 + 1, target);

                    logic.photoViewControllers[index] ??= PhotoViewController();

                    int firstImage = index * 2 - 2;
                    if (firstImage % 2 != 0) {
                      firstImage++;
                    }
                    if (logic.singlePageForFirstScreen) {
                      firstImage--;
                    }
                    var images = <int>[firstImage, firstImage + 1];
                    if (logic.readingMethod == ReadingMethod.twoPageReversed) {
                      images = images.reversed.toList();
                    }

                    return PhotoViewGalleryPageOptions.customChild(
                        controller: logic.photoViewControllers[index],
                        child: Row(
                          children: [
                            Expanded(
                              child: buildComicImageOrEmpty(
                                imageIndex: images[0],
                                fit: BoxFit.contain,
                                alignment: Alignment.centerRight,
                                layoutWidth: pageWidth,
                              ),
                            ),
                            Expanded(
                              child: buildComicImageOrEmpty(
                                imageIndex: images[1],
                                fit: BoxFit.contain,
                                alignment: Alignment.centerLeft,
                                layoutWidth: pageWidth,
                              ),
                            ),
                          ],
                        ));
                  },
                  pageController: logic.pageController,
                  onPageChanged: (i) {
                    if (i == 0) {
                      if (!logic.data.hasEp || logic.order == 1) {
                        logic.pageController.jumpByDeviceType(1);
                        return;
                      }
                      logic.jumpToLastChapter();
                    } else if (i == calcItemCount() - 1) {
                      if (!logic.data.hasEp ||
                          logic.order == logic.data.eps?.length) {
                        logic.pageController.jumpByDeviceType(
                            logic.pageController.page!.round() - 1);
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
            ),
          );
        },
      );
    }

    Widget body;

    if (["1", "2", "3"].contains(appdata.settings[9])) {
      body = buildType123();
    } else if (appdata.settings[9] == "4") {
      logic.photoViewControllers[0] ??= PhotoViewController();
      body = PhotoView.customChild(
          backgroundDecoration: decoration,
          key: Key(logic.order.toString()),
          minScale: 1.0,
          maxScale: 2.5,
          strictScale: true,
          controller: logic.photoViewControllers[0],
          onScaleEnd: (context, detail, value) {
            var prev = logic.currentScale;
            logic.currentScale = value.scale ?? 1.0;
            if ((prev <= 1.05 && logic.currentScale > 1.05) ||
                (prev > 1.05 && logic.currentScale <= 1.05)) {
              logic.update();
            }
            if (appdata.settings[43] != "1") {
              return false;
            }
            return updateLocation(context, logic.photoViewController);
          },
          child: buildType4());
    } else {
      body = buildType56();
    }

    void onPointerSignal(PointerSignalEvent pointerSignal) {
      logic.mouseScroll = pointerSignal.kind == PointerDeviceKind.mouse;
      if (pointerSignal is PointerScrollEvent && !logic.isCtrlPressed) {
        if (logic.readingMethod != ReadingMethod.topToBottomContinuously) {
          pointerSignal.scrollDelta.dy > 0
              ? logic.jumpToNextPage()
              : logic.jumpToLastPage();
        } else {
          if ((logic.scrollController.position.pixels ==
                      logic.scrollController.position.minScrollExtent &&
                  pointerSignal.scrollDelta.dy < 0) ||
              (logic.scrollController.position.pixels ==
                      logic.scrollController.position.maxScrollExtent &&
                  pointerSignal.scrollDelta.dy > 0)) {
            logic.photoViewController.updateMultiple(
                position: logic.photoViewController.position -
                    Offset(0, pointerSignal.scrollDelta.dy));
          } else if (!App.isMacOS) {
            logic.scrollController.smoothTo(pointerSignal.scrollDelta.dy);
          }
        }
      }
    }

    return Positioned.fill(
      top: App.isDesktop ? MediaQuery.of(context).padding.top : 0,
      child: Listener(
        onPointerSignal: onPointerSignal,
        onPointerPanZoomUpdate: (event) {
          if (event.kind == PointerDeviceKind.trackpad &&
              logic.readingMethod == ReadingMethod.topToBottomContinuously) {
            if (event.scale == 1.0) {
              logic.scrollController.smoothTo(0 - event.panDelta.dy * 1.2);
            }
          }
        },
        onPointerDown: (details) => logic.mouseScroll = false,
        child: NotificationListener<ScrollUpdateNotification>(
          child: body,
          onNotification: (notification) {
            TapController.lastScrollTime = DateTime.now();
            // update floating button
            var length = logic.data.eps?.length ?? 1;
            if (!logic.scrollController.hasClients) return false;
            if (logic.scrollController.position.pixels -
                        logic.scrollController.position.minScrollExtent <=
                    0 &&
                logic.order != 0) {
              logic.showFloatingButton(-1);
            } else if (logic.scrollController.position.pixels -
                        logic.scrollController.position.maxScrollExtent >=
                    0 &&
                logic.order < length) {
              logic.showFloatingButton(1);
            } else {
              logic.showFloatingButton(0);
            }

            return true;
          },
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

  /// preload image
  void precacheComicImage(ComicReadingPageLogic logic, BuildContext context,
      int index, String target) {
    if (logic.requestedLoadingItems.length != logic.length + 1) {
      logic.requestedLoadingItems = List.filled(logic.length + 1, false);
    }

    var precacheEnd = int.parse(appdata.settings[28]) + index;
    if (precacheEnd > logic.urls.length) {
      precacheEnd = logic.urls.length;
    }
    for (var current = index; current < precacheEnd; current++) {
      if (current < 0 ||
          current >= logic.urls.length ||
          logic.requestedLoadingItems[current]) {
        continue;
      }
      logic.requestedLoadingItems[current] = true;
      precacheImage(
        _createReaderImageRequest(context, logic, current, target).provider,
        context,
      );
    }
    if (!ImageManager.haveTask) {
      var extraEnd = precacheEnd + 3;
      if (extraEnd > logic.urls.length) {
        extraEnd = logic.urls.length;
      }
      for (var current = precacheEnd; current < extraEnd; current++) {
        if (current < 0 ||
            current >= logic.urls.length ||
            logic.requestedLoadingItems[current]) {
          continue;
        }
        logic.requestedLoadingItems[current] = true;
        precacheImage(
          _createReaderImageRequest(context, logic, current, target).provider,
          context,
        );
      }
    }
  }
}
