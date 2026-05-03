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
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/download.dart';
import 'package:picakeep/foundation/history.dart';
import 'package:picakeep/foundation/local_data_source.dart';
import 'package:picakeep/foundation/local_favorites.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/foundation/ui_mode.dart';
import 'package:picakeep/pages/auth_page.dart';
import 'package:picakeep/tools/block_screenshot.dart';
import 'package:share_plus/share_plus.dart';

part 'app_settings.dart';
part 'explore_settings.dart';
part 'reading_settings.dart';
part 'local_favorite_settings.dart';

void refreshLocalDataCaches() {
  DownloadManager().dispose();
  HistoryManager().dispose();
  LocalFavoritesManager().dispose();
}

const double _settingsWideLayoutBreakpoint = 900;

Widget buildTwoColumnLayout(double width, List<Widget> children) {
  return Column(children: children);
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
      !UiMode.m1(context) && MediaQuery.of(context).size.width >= _settingsWideLayoutBreakpoint;

  final categories = <String>["浏览", "阅读", "外观", "本地收藏", "APP", "关于"];

  final icons = <IconData>[
    Icons.explore,
    Icons.book,
    Icons.color_lens,
    Icons.collections_bookmark_rounded,
    Icons.apps,
    Icons.info
  ];

  double offset = 0;

  late final HorizontalDragGestureRecognizer gestureRecognizer;

  @override
  void initState() {
    currentPage = widget.initialPage;
    gestureRecognizer = HorizontalDragGestureRecognizer(debugOwner: this)
      ..onUpdate = ((details) => setState(() => offset += details.delta.dx))
      ..onEnd = (details) async {
        if (details.velocity.pixelsPerSecond.dx.abs() > 1 &&
            details.velocity.pixelsPerSecond.dx >= 0) {
          setState(() {
            Future.delayed(const Duration(milliseconds: 300), () => offset = 0);
            currentPage = -1;
          });
        } else if (offset > MediaQuery.of(context).size.width / 2) {
          setState(() {
            Future.delayed(const Duration(milliseconds: 300), () => offset = 0);
            currentPage = -1;
          });
        } else {
          int i = 10;
          while (offset != 0) {
            setState(() {
              offset -= i;
              i *= 10;
              if (offset < 0) {
                offset = 0;
              }
            });
            await Future.delayed(const Duration(milliseconds: 10));
          }
        }
      }
      ..onCancel = () async {
        int i = 10;
        while (offset != 0) {
          setState(() {
            offset -= i;
            i *= 10;
            if (offset < 0) {
              offset = 0;
            }
          });
          await Future.delayed(const Duration(milliseconds: 10));
        }
      };
    super.initState();
  }

  @override
  dispose() {
    super.dispose();
    gestureRecognizer.dispose();
    App.temporaryDisablePopGesture = false;
  }

  @override
  Widget build(BuildContext context) {
    if (currentPage != -1 && !enableTwoViews) {
      App.temporaryDisablePopGesture = true;
    } else {
      App.temporaryDisablePopGesture = false;
    }
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
      return Stack(
        children: [
          Positioned.fill(child: buildLeft()),
          Positioned(
            left: offset,
            width: MediaQuery.of(context).size.width,
            height: MediaQuery.of(context).size.height,
            child: Listener(
              onPointerDown: handlePointerDown,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                reverseDuration: const Duration(milliseconds: 300),
                switchInCurve: Curves.fastOutSlowIn,
                switchOutCurve: Curves.fastOutSlowIn,
                transitionBuilder: (child, animation) {
                  var tween = Tween<Offset>(
                      begin: const Offset(1, 0), end: const Offset(0, 0));
                  return SlideTransition(
                    position: tween.animate(animation),
                    child: child,
                  );
                },
                child: currentPage == -1
                    ? const SizedBox(key: Key("1"))
                    : buildRight(MediaQuery.of(context).size.width),
              ),
            ),
          )
        ],
      );
    }
  }

  void handlePointerDown(PointerDownEvent event) {
    if (event.position.dx < 20) {
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
          onTap: () => setState(() => currentPage = id),
          borderRadius: BorderRadius.circular(16),
          child: content,
        ).paddingVertical(4),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: categories.length,
      itemBuilder: (context, index) => buildItem(categories[index].tl, index),
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
        5 => buildAbout(width),
        _ => throw UnimplementedError()
      };
    }

    if (currentPage != -1) {
      return Material(
        child: CustomScrollView(
          primary: false,
          slivers: [
            SliverAppBar(
                title: Text(categories[currentPage].tl),
                automaticallyImplyLeading: false,
                scrolledUnderElevation: enableTwoViews ? 0 : null,
                leading: enableTwoViews
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => setState(() => currentPage = -1),
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
          ListTile(
            leading: const Icon(Icons.color_lens),
            title: Text("主题选择".tl),
            trailing: Select(
              initialValue:
                  (int.tryParse(appdata.settings[27]) ?? 0).toString(),
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
                appdata.settings[27] = value;
                appdata.updateSettings();
                App.updater?.call();
              },
              width: 140,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.dark_mode),
            title: Text("深色模式".tl),
            trailing: Select(
              initialValue: appdata.settings[32],
              values: const ["0", "1", "2"],
              titles: ["跟随系统".tl, "禁用".tl, "启用".tl],
              onChanged: (value) {
                setState(() {
                  appdata.settings[32] = value;
                });
                appdata.updateSettings();
                App.updater?.call();
              },
              width: 140,
            ),
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
                              onPressed: () => Navigator.of(dialogContext).pop(),
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
            child: Text("V1.0.0", style: TextStyle(fontSize: 16)),
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
    if (currentPage != -1) {
      setState(() {
        currentPage = -1;
      });
    }
  }
}

class SwitchSetting extends StatefulWidget {
  const SwitchSetting({
    super.key,
    required this.title,
    this.subTitle,
    required this.settingsIndex,
  });

  final String title;
  final String? subTitle;
  final int settingsIndex;

  @override
  State<SwitchSetting> createState() => _SwitchSettingState();
}

class _SwitchSettingState extends State<SwitchSetting> {
  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(widget.title),
      subtitle: widget.subTitle != null ? Text(widget.subTitle!) : null,
      trailing: Switch(
        value: appdata.settings[widget.settingsIndex] == '1',
        onChanged: (value) {
          setState(() {
            appdata.settings[widget.settingsIndex] = value ? '1' : '0';
            appdata.updateSettings();
          });
        },
      ),
    );
  }
}

class SelectSetting extends StatefulWidget {
  const SelectSetting({
    super.key,
    required this.title,
    required this.settingsIndex,
    required this.values,
    required this.titles,
    this.onChanged,
  });

  final String title;
  final int settingsIndex;
  final List<String> values;
  final List<String> titles;
  final void Function(String value)? onChanged;

  @override
  State<SelectSetting> createState() => _SelectSettingState();
}

class _SelectSettingState extends State<SelectSetting> {
  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(widget.title),
      trailing: Select(
        width: 140,
        initialValue: appdata.settings[widget.settingsIndex],
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
