import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:picakeep/components/select.dart' hide AnimatedContainer;
import 'package:picakeep/components/scrollable.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/local_library.dart';
import 'package:picakeep/foundation/local_library_settings.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/ui_mode.dart';
import 'package:picakeep/foundation/app_runtime_mode.dart';
import 'package:picakeep/pages/app_capabilities_page.dart';
import 'package:picakeep/pages/auth_page.dart';
import 'package:picakeep/pages/local_library_page.dart';
import 'package:picakeep/server/local_server_runtime.dart';
import 'package:picakeep/server/local_server_runtime_sync.dart';
import 'package:picakeep/tools/block_screenshot.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'app_settings.dart';
part 'log_settings.dart';
part 'internal_directory_browser.dart';
part 'app_capabilities_settings.dart';
part 'runtime_service_settings.dart';
part 'explore_settings.dart';
part 'reading_settings.dart';
part 'local_favorite_settings.dart';

void refreshLocalDataCaches() {
  // Managers are reinitialized in place so mounted widgets never observe
  // closed database handles during a mode switch.
}

const double _settingsWideLayoutBreakpoint = 900;

Widget buildTwoColumnLayout(double width, List<Widget> children) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final child in children)
        SizedBox(width: double.infinity, child: child),
    ],
  );
}

Widget buildResponsiveSettingTile({
  Widget? leading,
  required Widget title,
  Widget? subtitle,
  required Widget trailing,
  double trailingWidth = 140,
  bool expandTrailingOnNarrow = false,
  VoidCallback? onTap,
}) {
  return LayoutBuilder(
    builder: (context, constraints) {
      const horizontalPadding = 32.0;
      const reservedLeadingWidth = 56.0;
      const reservedTitleWidth = 120.0;
      const minimumTrailingWidth = 72.0;
      final availableTrailingWidth = constraints.maxWidth -
          horizontalPadding -
          (leading != null ? reservedLeadingWidth : 0.0) -
          reservedTitleWidth;
      final safeTrailingWidth = availableTrailingWidth > minimumTrailingWidth
          ? availableTrailingWidth
          : minimumTrailingWidth;
      final effectiveTrailingWidth = expandTrailingOnNarrow
          ? safeTrailingWidth
          : (safeTrailingWidth < trailingWidth
              ? safeTrailingWidth
              : trailingWidth);

      return ListTile(
        leading: leading,
        title: title,
        subtitle: subtitle,
        trailing: SizedBox(
          width: effectiveTrailingWidth,
          child: Align(
            alignment: Alignment.centerRight,
            child: trailing,
          ),
        ),
        onTap: onTap,
      );
    },
  );
}

class SettingsPage extends StatefulWidget {
  static void open([int initialPage = -1]) {
    App.globalTo(() => SettingsPage(initialPage: initialPage));
  }

  const SettingsPage({this.initialPage = -1, super.key});

  final int initialPage;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int currentPage = -1;

  ColorScheme get colors => Theme.of(context).colorScheme;

  bool get enableTwoViews =>
      !UiMode.m1(context) &&
      MediaQuery.of(context).size.width >= _settingsWideLayoutBreakpoint;

  final categories = <String>["浏览", "阅读", "外观", "本地收藏", "APP", "APP能力", "关于"];

  final icons = <IconData>[
    Icons.explore,
    Icons.book,
    Icons.color_lens,
    Icons.collections_bookmark_rounded,
    Icons.apps,
    Icons.cloud_sync_outlined,
    Icons.info
  ];

  double offset = 0;
  bool _isDraggingPage = false;
  int _pageTransitionToken = 0;
  LocalHistoryEntry? _subPageHistoryEntry;
  bool _isRemovingSubPageHistoryEntry = false;

  late final HorizontalDragGestureRecognizer gestureRecognizer;

  void _openPage(int id) {
    if (enableTwoViews) {
      _removeSubPageHistoryEntry();
      setState(() {
        currentPage = id;
        offset = 0;
        _isDraggingPage = false;
      });
      return;
    }
    final width = MediaQuery.of(context).size.width;
    final transitionToken = ++_pageTransitionToken;
    setState(() {
      currentPage = id;
      offset = width;
      _isDraggingPage = false;
    });
    _ensureSubPageHistoryEntry();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || transitionToken != _pageTransitionToken) {
        return;
      }
      setState(() {
        offset = 0;
      });
    });
  }

  void _closePage({bool animate = true, bool removeHistoryEntry = true}) {
    if (currentPage == -1) {
      return;
    }
    if (removeHistoryEntry) {
      _removeSubPageHistoryEntry();
    }
    if (enableTwoViews || !animate) {
      setState(() {
        currentPage = -1;
        offset = 0;
        _isDraggingPage = false;
      });
      return;
    }
    final width = MediaQuery.of(context).size.width;
    final transitionToken = ++_pageTransitionToken;
    setState(() {
      offset = width;
      _isDraggingPage = false;
    });
    Future<void>.delayed(const Duration(milliseconds: 220), () {
      if (!mounted || transitionToken != _pageTransitionToken) {
        return;
      }
      setState(() {
        currentPage = -1;
        offset = 0;
      });
    });
  }

  void _ensureSubPageHistoryEntry() {
    if (enableTwoViews || currentPage == -1 || _subPageHistoryEntry != null) {
      return;
    }
    final route = ModalRoute.of(context);
    if (route == null) {
      return;
    }
    final entry = LocalHistoryEntry(onRemove: _handleSubPageHistoryRemoved);
    route.addLocalHistoryEntry(entry);
    _subPageHistoryEntry = entry;
  }

  void _removeSubPageHistoryEntry() {
    final entry = _subPageHistoryEntry;
    if (entry == null) {
      return;
    }
    _subPageHistoryEntry = null;
    _isRemovingSubPageHistoryEntry = true;
    entry.remove();
    _isRemovingSubPageHistoryEntry = false;
  }

  void _handleSubPageHistoryRemoved() {
    _subPageHistoryEntry = null;
    if (_isRemovingSubPageHistoryEntry ||
        !mounted ||
        enableTwoViews ||
        currentPage == -1) {
      return;
    }
    _closePage(removeHistoryEntry: false);
  }

  @override
  void initState() {
    currentPage = widget.initialPage;
    gestureRecognizer = HorizontalDragGestureRecognizer(debugOwner: this)
      ..onUpdate = (details) {
        final width = MediaQuery.of(context).size.width;
        setState(() {
          _isDraggingPage = true;
          offset = (offset + details.delta.dx).clamp(0.0, width);
        });
      }
      ..onEnd = (details) {
        final width = MediaQuery.of(context).size.width;
        final shouldClose =
            details.velocity.pixelsPerSecond.dx >= 0 || offset > width / 2;
        if (shouldClose) {
          _closePage();
          return;
        }
        setState(() {
          offset = 0;
          _isDraggingPage = false;
        });
      }
      ..onCancel = () {
        if (offset == 0) {
          return;
        }
        setState(() {
          offset = 0;
          _isDraggingPage = false;
        });
      };
    super.initState();
  }

  @override
  dispose() {
    _removeSubPageHistoryEntry();
    gestureRecognizer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (currentPage != -1 && !enableTwoViews) {
        _ensureSubPageHistoryEntry();
      } else {
        _removeSubPageHistoryEntry();
      }
    });
    return Material(
      child: buildBody(),
    );
  }

  Widget buildBody() {
    if (enableTwoViews) {
      return Row(
        children: [
          SizedBox(
            width: 320,
            height: double.infinity,
            child: buildLeft(),
          ),
          Container(
            width: 0.6,
            height: double.infinity,
            color: context.colorScheme.outlineVariant,
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return buildRight(constraints.maxWidth);
              },
            ),
          )
        ],
      );
    } else {
      return LayoutBuilder(
        builder: (context, constraints) {
          final pageWidth = constraints.maxWidth;
          final pageHeight = constraints.maxHeight;
          return Stack(
            children: [
              Positioned.fill(child: buildLeft()),
              if (currentPage != -1)
                AnimatedPositioned(
                  duration: _isDraggingPage
                      ? Duration.zero
                      : const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  left: offset,
                  width: pageWidth,
                  height: pageHeight,
                  child: Listener(
                    onPointerDown: handlePointerDown,
                    child: buildRight(pageWidth),
                  ),
                ),
            ],
          );
        },
      );
    }
  }

  void handlePointerDown(PointerDownEvent event) {
    if (currentPage != -1 && event.position.dx < 20) {
      gestureRecognizer.addPointer(event);
    }
  }

  Widget buildLeft() {
    return Material(
      child: Column(
        children: [
          SizedBox(
            height: MediaQuery.of(context).padding.top,
          ),
          SizedBox(
            height: 56,
            child: Row(children: [
              const SizedBox(width: 8),
              Tooltip(
                message: "Back",
                child: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => App.back(context),
                ),
              ),
              const SizedBox(width: 24),
              Text(
                "设置".tl,
                style: Theme.of(context).textTheme.headlineSmall,
              )
            ]),
          ),
          const SizedBox(height: 4),
          Expanded(child: buildCategories())
        ],
      ),
    );
  }

  Widget buildCategories() {
    Widget buildItem(String name, int id) {
      final bool selected = id == currentPage;

      Widget content = AnimatedContainer(
        key: ValueKey(id),
        duration: const Duration(milliseconds: 300),
        width: double.infinity,
        height: 48,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        decoration: BoxDecoration(
            color: selected ? colors.primaryContainer : null,
            borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          Icon(icons[id]),
          const SizedBox(width: 16),
          Text(name, style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          if (selected) const Icon(Icons.arrow_right)
        ]),
      );

      return Padding(
        padding: enableTwoViews
            ? const EdgeInsets.fromLTRB(16, 0, 16, 0)
            : EdgeInsets.zero,
        child: InkWell(
          onTap: () => _openPage(id),
          borderRadius: BorderRadius.circular(16),
          child: content,
        ).paddingVertical(4),
      );
    }

    return SmoothScrollProvider(
      builder: (context, controller, physics) => ListView.builder(
        controller: controller,
        physics: physics,
        padding: EdgeInsets.zero,
        cacheExtent: 320,
        itemCount: categories.length,
        itemBuilder: (context, index) => buildItem(categories[index].tl, index),
      ),
    );
  }

  Widget buildRight(double availableWidth) {
    Widget buildContent(double width) {
      return switch (currentPage) {
        -1 => const SizedBox(),
        0 => buildExploreSettings(width, context),
        1 => ReadingSettings(width: width),
        2 => buildAppearanceSettings(width),
        3 => LocalFavoritesSettings(width: width),
        4 => buildAppSettings(width, context),
        5 => buildAppCapabilitiesSettings(width, context),
        6 => buildAbout(width),
        _ => throw UnimplementedError()
      };
    }

    if (currentPage != -1) {
      return Material(
        child: SmoothCustomScrollView(
          cacheExtent: 640,
          slivers: [
            SliverAppBar(
                title: Text(categories[currentPage].tl),
                automaticallyImplyLeading: false,
                scrolledUnderElevation: enableTwoViews ? 0 : null,
                leading: enableTwoViews
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => _closePage(),
                      )),
            SliverToBoxAdapter(
              child: buildContent(availableWidth),
            )
          ],
        ),
      );
    }

    return buildContent(availableWidth);
  }

  Widget buildAppearanceSettings(double width) => buildTwoColumnLayout(
        width,
        [
          SelectSetting(
            leading: const Icon(Icons.color_lens),
            title: "主题选择".tl,
            settingsIndex: 27,
            initialValue: (int.tryParse(appdata.settings[27]) ?? 0).toString(),
            values: const [
              "0",
              "1",
              "2",
              "3",
              "4",
              "5",
              "6",
              "7",
              "8",
              "9",
              "10",
              "11",
              "12"
            ],
            titles: const [
              "dynamic",
              "red",
              "pink",
              "purple",
              "indigo",
              "blue",
              "cyan",
              "teal",
              "green",
              "lime",
              "yellow",
              "amber",
              "orange"
            ],
            onChanged: (value) {
              App.updater?.call();
            },
          ),
          SelectSetting(
            leading: const Icon(Icons.dark_mode),
            title: "深色模式".tl,
            settingsIndex: 32,
            values: const ["0", "1", "2"],
            titles: ["跟随系统".tl, "禁用".tl, "启用".tl],
            onChanged: (value) {
              setState(() {});
              App.updater?.call();
            },
          ),
          if (appdata.settings[32] == "0" || appdata.settings[32] == "2")
            ListTile(
              leading: const Icon(Icons.remove_red_eye),
              title: Text("纯黑色模式".tl),
              trailing: Switch(
                value: appdata.settings[84] == "1",
                onChanged: (value) {
                  setState(() {
                    appdata.settings[84] = value ? "1" : "0";
                  });
                  appdata.updateSettings();
                  App.updater?.call();
                },
              ),
            ),
          if (App.isAndroid)
            ListTile(
              leading: const Icon(Icons.smart_screen_outlined),
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("高刷新率模式".tl),
                  const SizedBox(width: 4),
                  InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () {
                      showDialog<void>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: Text("高刷新率模式".tl),
                          content: Text(
                            "尝试强制设置高刷新率，可能不起作用".tl,
                          ),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(),
                              child: Text("确定".tl),
                            ),
                          ],
                        ),
                      );
                    },
                    child: const Icon(Icons.info_outline, size: 18),
                  ),
                ],
              ),
              trailing: Switch(
                value: appdata.settings[38] == "1",
                onChanged: (value) async {
                  setState(() {
                    appdata.settings[38] = value ? "1" : "0";
                  });
                  await appdata.updateSettings();
                  await App.applyDisplayModePreference();
                },
              ),
            ),
          Padding(
            padding:
                EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
          ),
        ],
      );

  Widget buildAbout(double width) => buildTwoColumnLayout(
        width,
        [
          const SizedBox(
            height: 130,
            width: double.infinity,
            child: Center(
              child: Icon(Icons.book_rounded, size: 80),
            ),
          ),
          const Center(
            child: Text(
              "PicaKeep",
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
          ),
          const Center(
            child: Text("V1.8.23", style: TextStyle(fontSize: 16)),
          ),
          const SizedBox(height: 4),
          const Center(
            child: Text("本地漫画阅读器 / 收藏管理器"),
          ),
          Padding(
            padding:
                EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
          ),
        ],
      );

  void handlePopInvoked(bool didPop) {
    if (didPop) {
      return;
    }
    if (currentPage != -1) {
      _closePage();
    }
  }
}

class SwitchSetting extends StatefulWidget {
  const SwitchSetting({
    super.key,
    this.leading,
    required this.title,
    this.subTitle,
    required this.settingsIndex,
  });

  final Widget? leading;
  final String title;
  final String? subTitle;
  final int settingsIndex;

  @override
  State<SwitchSetting> createState() => _SwitchSettingState();
}

class _SwitchSettingState extends State<SwitchSetting> {
  @override
  Widget build(BuildContext context) {
    return buildResponsiveSettingTile(
      leading: widget.leading,
      title: Text(widget.title),
      subtitle: widget.subTitle != null ? Text(widget.subTitle!) : null,
      trailingWidth: 60,
      trailing: Switch(
        value: appdata.settings[widget.settingsIndex] == '1',
        onChanged: (value) {
          setState(() {
            appdata.settings[widget.settingsIndex] = value ? '1' : '0';
          });
          appdata.updateSettings();
        },
      ),
    );
  }
}

class SelectSetting extends StatefulWidget {
  const SelectSetting({
    super.key,
    this.leading,
    required this.title,
    required this.settingsIndex,
    required this.values,
    required this.titles,
    this.controlWidth = 140,
    this.initialValue,
    this.onChanged,
  });

  final Widget? leading;
  final String title;
  final int settingsIndex;
  final List<String> values;
  final List<String> titles;
  final double controlWidth;
  final String? initialValue;
  final void Function(String value)? onChanged;

  @override
  State<SelectSetting> createState() => _SelectSettingState();
}

class _SelectSettingState extends State<SelectSetting> {
  @override
  Widget build(BuildContext context) {
    return buildResponsiveSettingTile(
      leading: widget.leading,
      title: Text(widget.title),
      trailingWidth: widget.controlWidth,
      trailing: Select(
        width: widget.controlWidth,
        initialValue:
            widget.initialValue ?? appdata.settings[widget.settingsIndex],
        values: widget.values,
        titles: widget.titles,
        onChanged: (value) {
          setState(() {
            appdata.settings[widget.settingsIndex] = value;
            appdata.updateSettings();
          });
          widget.onChanged?.call(value);
        },
      ),
    );
  }
}

class SettingsTitle extends StatelessWidget {
  const SettingsTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(text),
    );
  }
}

class NewPageSetting extends StatelessWidget {
  const NewPageSetting({
    super.key,
    required this.title,
    required this.page,
  });

  final String title;
  final Widget page;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title),
      trailing: const Icon(Icons.arrow_right),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => page),
        );
      },
    );
  }
}

class PopUpWidgetScaffold extends StatelessWidget {
  const PopUpWidgetScaffold({
    super.key,
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
      body: child,
    );
  }
}
