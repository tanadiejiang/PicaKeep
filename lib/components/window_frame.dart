import 'dart:io';

import 'package:flutter/material.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/main_page_hub.dart';
import 'package:picakeep/pages/download_page.dart';
import 'package:picakeep/pages/history_page.dart';
import 'package:picakeep/pages/image_favorites.dart';
import 'package:picakeep/pages/local_search_page.dart';
import 'package:picakeep/pages/settings/settings_page.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:window_manager/window_manager.dart';

export 'side_bar.dart' show showSideBar;

const _kTitleBarHeight = 36.0;

class WindowFrameController extends StateController {
  bool useDarkTheme = false;
  bool isHideWindowFrame = false;

  void setDarkTheme() {
    useDarkTheme = true;
    update();
  }

  void resetTheme() {
    useDarkTheme = false;
    update();
  }

  VoidCallback openSideBar = () {};

  void hideWindowFrame() {
    isHideWindowFrame = true;
    update();
  }

  void showWindowFrame() {
    isHideWindowFrame = false;
    update();
  }
}

class WindowFrame extends StatelessWidget {
  const WindowFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    StateController.putIfNotExists(WindowFrameController());
    if (App.isMobile) return child;

    return StateBuilder<WindowFrameController>(builder: (controller) {
      if (controller.isHideWindowFrame) return child;

      return Stack(
        children: [
          Positioned.fill(
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: const EdgeInsets.only(top: _kTitleBarHeight),
              ),
              child: child,
            ),
          ),
          const _DesktopSideBarOverlay(),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              surfaceTintColor: Theme.of(context).colorScheme.surfaceTint,
              child: Theme(
                data: Theme.of(context).copyWith(
                  brightness:
                      controller.useDarkTheme ? Brightness.dark : null,
                ),
                child: Builder(
                  builder: (context) {
                    return SizedBox(
                      height: _kTitleBarHeight,
                      child: Row(
                        children: [
                          if (!App.isMacOS)
                            buildMenuButton(controller, context)
                                .toAlign(Alignment.centerLeft)
                          else
                            DragToMoveArea(
                              child: const SizedBox(
                                height: double.infinity,
                                width: 16,
                              ),
                            ).paddingRight(52),
                          Expanded(
                            child: DragToMoveArea(
                              child: Text(
                                'PicaKeep',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: (controller.useDarkTheme ||
                                          context.brightness ==
                                              Brightness.dark)
                                      ? Colors.white
                                      : Colors.black,
                                ),
                              ).toAlign(Alignment.centerLeft).paddingLeft(4),
                            ),
                          ),
                          if (!App.isMacOS)
                            const WindowButtons()
                          else
                            buildMenuButton(controller, context)
                                .toAlign(Alignment.centerRight),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      );
    });
  }

  Widget buildMenuButton(
      WindowFrameController controller, BuildContext context) {
    return InkWell(
      onTap: () => controller.openSideBar(),
      child: SizedBox(
        width: 42,
        height: double.infinity,
        child: Center(
          child: CustomPaint(
            size: const Size(18, 20),
            painter: _MenuPainter(
              color: (controller.useDarkTheme ||
                      Theme.of(context).brightness == Brightness.dark)
                  ? Colors.white
                  : Colors.black,
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuPainter extends CustomPainter {
  final Color color;

  _MenuPainter({this.color = Colors.black});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = _framePaint(color);
    final path = Path()
      ..moveTo(0, size.height / 4)
      ..lineTo(size.width, size.height / 4)
      ..moveTo(0, size.height / 4 * 2)
      ..lineTo(size.width, size.height / 4 * 2)
      ..moveTo(0, size.height / 4 * 3)
      ..lineTo(size.width, size.height / 4 * 3);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _DesktopSideBarOverlay extends StatefulWidget {
  const _DesktopSideBarOverlay();

  @override
  State<_DesktopSideBarOverlay> createState() => _DesktopSideBarOverlayState();
}

class _DesktopSideBarOverlayState extends State<_DesktopSideBarOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  void run() {
    if (_controller.isAnimating) return;
    if (_controller.isCompleted) {
      _controller.reverse();
    } else {
      _controller.forward();
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
      value: 0,
    );
    StateController.find<WindowFrameController>().openSideBar = run;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: CurvedAnimation(
        parent: _controller,
        curve: Curves.fastEaseInToSlowEaseOut,
      ),
      builder: (context, child) {
        final value = _controller.value;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: run,
                child: Container(
                  width: double.infinity,
                  height: double.infinity,
                  color: value == 0
                      ? null
                      : Colors.black.withValues(alpha: 0.2 * value),
                ),
              ),
            ),
            Positioned(
              left: !App.isMacOS ? (1 - _controller.value) * (-300) : null,
              right: App.isMacOS ? (_controller.value - 1) * 300 : null,
              top: 0,
              bottom: 0,
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                surfaceTintColor: Theme.of(context).colorScheme.surfaceTint,
                elevation: 2,
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(8),
                  bottomRight: Radius.circular(8),
                ),
                child: SizedBox(
                  width: 300,
                  height: double.infinity,
                  child: const SingleChildScrollView(
                    child: _DesktopQuickMenuBody(),
                  ).paddingTop(_kTitleBarHeight),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DesktopQuickMenuBody extends StatelessWidget {
  const _DesktopQuickMenuBody();

  void _closeThen(void Function() action) {
    StateController.find<WindowFrameController>().openSideBar();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final hub = StateController.findOrNull<MainPageHub>();
    void push(Widget Function() page) {
      _closeThen(() => hub?.openPage(page));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        _menuItem(
          icon: Icons.history,
          title: '历史记录'.tl,
          onTap: () => push(() => const HistoryPage()),
        ),
        _menuItem(
          icon: Icons.download_outlined,
          title: '已下载'.tl,
          onTap: () => push(() => const DownloadPage()),
        ),
        _menuItem(
          icon: Icons.image_outlined,
          title: '图片收藏'.tl,
          onTap: () => push(() => const ImageFavoritesPage()),
        ),
        const Divider().paddingHorizontal(8),
        _menuItem(
          icon: Icons.search,
          title: '搜索'.tl,
          onTap: () => push(() => const LocalSearchPage()),
        ),
        _menuItem(
          icon: Icons.settings,
          title: '设置'.tl,
          onTap: () {
            _closeThen(() => SettingsPage.open());
          },
        ),
      ],
    );
  }

  Widget _menuItem({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 16),
            Text(title, style: const TextStyle(fontSize: 14)),
          ],
        ),
      ),
    ).paddingHorizontal(8);
  }
}

class WindowButtons extends StatefulWidget {
  const WindowButtons({super.key});

  @override
  State<WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<WindowButtons> with WindowListener {
  bool isMaximized = false;

  @override
  void initState() {
    windowManager.addListener(this);
    windowManager.isMaximized().then((value) {
      if (mounted && value) {
        setState(() => isMaximized = true);
      }
    });
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    setState(() => isMaximized = true);
    super.onWindowMaximize();
  }

  @override
  void onWindowUnmaximize() {
    setState(() => isMaximized = false);
    super.onWindowUnmaximize();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = dark ? Colors.white : Colors.black;
    final hoverColor = dark ? Colors.white30 : Colors.black12;

    return SizedBox(
      width: 138,
      height: _kTitleBarHeight,
      child: Row(
        children: [
          WindowButton(
            icon: MinimizeIcon(color: color),
            hoverColor: hoverColor,
            onPressed: () async {
              if (await windowManager.isMinimized()) {
                await windowManager.restore();
              } else {
                await windowManager.minimize();
              }
            },
          ),
          if (isMaximized)
            WindowButton(
              icon: RestoreIcon(color: color),
              hoverColor: hoverColor,
              onPressed: () => windowManager.unmaximize(),
            )
          else
            WindowButton(
              icon: MaximizeIcon(color: color),
              hoverColor: hoverColor,
              onPressed: () => windowManager.maximize(),
            ),
          WindowButton(
            icon: CloseIcon(color: color),
            hoverIcon: CloseIcon(color: !dark ? Colors.white : Colors.black),
            hoverColor: Colors.red,
            onPressed: () {
              if (appdata.implicitData.length > 2 &&
                  appdata.implicitData[2] == '0') {
                showDialog<void>(
                  context: App.navigatorKey.currentContext!,
                  builder: (ctx) {
                    var isCheck = false;
                    return AlertDialog(
                      title: Text('是否退出程序?'.tl),
                      content: StatefulBuilder(
                        builder: (context, setSt) {
                          return Row(
                            children: [
                              Checkbox(
                                value: isCheck,
                                onChanged: (v) =>
                                    setSt(() => isCheck = v ?? false),
                              ),
                              Text('不再提示'.tl),
                            ],
                          );
                        },
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: Text('否'.tl),
                        ),
                        TextButton(
                          onPressed: () {
                            if (isCheck) {
                              appdata.implicitData[2] = '1';
                              appdata.writeImplicitData();
                            }
                            windowManager.close();
                          },
                          child: Text('是'.tl),
                        ),
                      ],
                    );
                  },
                );
              } else {
                windowManager.close();
              }
            },
          ),
        ],
      ),
    );
  }
}

class WindowButton extends StatefulWidget {
  const WindowButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.hoverColor,
    this.hoverIcon,
  });

  final Widget icon;
  final VoidCallback onPressed;
  final Color hoverColor;
  final Widget? hoverIcon;

  @override
  State<WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<WindowButton> {
  bool isHovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => isHovering = true),
      onExit: (_) => setState(() => isHovering = false),
      child: GestureDetector(
        onTap: () => widget.onPressed(),
        child: Container(
          width: 46,
          height: double.infinity,
          decoration:
              BoxDecoration(color: isHovering ? widget.hoverColor : null),
          child: isHovering ? widget.hoverIcon ?? widget.icon : widget.icon,
        ),
      ),
    );
  }
}

class CloseIcon extends StatelessWidget {
  const CloseIcon({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) =>
      _AlignedPaint(_ClosePainter(color));
}

class _ClosePainter extends _IconPainter {
  _ClosePainter(super.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = _framePaint(color, true);
    canvas.drawLine(Offset.zero, Offset(size.width, size.height), p);
    canvas.drawLine(Offset(0, size.height), Offset(size.width, 0), p);
  }
}

class MaximizeIcon extends StatelessWidget {
  const MaximizeIcon({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) =>
      _AlignedPaint(_MaximizePainter(color));
}

class _MaximizePainter extends _IconPainter {
  _MaximizePainter(super.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = _framePaint(color);
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width - 1, size.height - 1), p);
  }
}

class RestoreIcon extends StatelessWidget {
  const RestoreIcon({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) =>
      _AlignedPaint(_RestorePainter(color));
}

class _RestorePainter extends _IconPainter {
  _RestorePainter(super.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = _framePaint(color);
    canvas.drawRect(Rect.fromLTRB(0, 2, size.width - 2, size.height), p);
    canvas.drawLine(const Offset(2, 2), const Offset(2, 0), p);
    canvas.drawLine(const Offset(2, 0), Offset(size.width, 0), p);
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(size.width, size.height - 2),
      p,
    );
    canvas.drawLine(
      Offset(size.width, size.height - 2),
      Offset(size.width - 2, size.height - 2),
      p,
    );
  }
}

class MinimizeIcon extends StatelessWidget {
  const MinimizeIcon({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) =>
      _AlignedPaint(_MinimizePainter(color));
}

class _MinimizePainter extends _IconPainter {
  _MinimizePainter(super.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = _framePaint(color);
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      p,
    );
  }
}

abstract class _IconPainter extends CustomPainter {
  _IconPainter(this.color);

  final Color color;

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _AlignedPaint extends StatelessWidget {
  const _AlignedPaint(this.painter);

  final CustomPainter painter;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: CustomPaint(size: const Size(10, 10), painter: painter),
    );
  }
}

Paint _framePaint(Color color, [bool isAntiAlias = false]) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..isAntiAlias = isAntiAlias
  ..strokeWidth = 1;

/// Call from [main] after [WidgetsFlutterBinding.ensureInitialized].
Future<void> initWindowManagerIfDesktop() async {
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
  await windowManager.ensureInitialized();
  await windowManager.setTitleBarStyle(
    TitleBarStyle.hidden,
    windowButtonVisibility: Platform.isMacOS,
  );
  await windowManager.setBackgroundColor(Colors.transparent);
  await windowManager.setMinimumSize(const Size(500, 600));
}

Future<void> showWindowWhenReady() async {
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
  await windowManager.waitUntilReadyToShow();
  if (!Platform.isLinux) {
    await windowManager.show();
  } else {
    await windowManager.show();
  }
}
