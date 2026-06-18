import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../foundation/app.dart';
import '../server/local_server_runtime.dart';
import 'translations.dart';

/// Windows 系统托盘控制器。
///
/// 仅在 Windows 桌面启用:窗口关闭时缩到托盘后台常驻(由 window_frame 拦截 close),
/// 托盘菜单复用现成的 [LocalServerRuntime] 启停服务端,服务能力与桌面版完全一致。
/// 其它平台(Linux/macOS/Android)不调用本控制器,行为不受影响。
class TrayController with TrayListener {
  TrayController._();

  static final TrayController instance = TrayController._();

  bool _initialized = false;

  /// 仅 Windows 初始化托盘。其它平台为 no-op。
  Future<void> init() async {
    if (!Platform.isWindows || _initialized) {
      return;
    }
    _initialized = true;

    trayManager.addListener(this);
    // 托盘图标在 setIcon 内部会拼成 <exe目录>/data/flutter_assets/<iconPath>,
    // 即 pubspec 声明的 assets/tray_icon.ico。Windows 原生 LoadImage 仅支持 .ico。
    try {
      await trayManager.setIcon('assets/tray_icon.ico');
    } catch (_) {}
    try {
      await trayManager.setToolTip('PicaKeep');
    } catch (_) {}
    await _refreshMenu();

    // 服务运行状态变化时刷新菜单「启动/停止」文案。
    App.serviceRuntimeVersion.addListener(_onRuntimeChanged);
  }

  void _onRuntimeChanged() {
    unawaited(_refreshMenu());
  }

  Future<void> _refreshMenu() async {
    if (!Platform.isWindows) {
      return;
    }
    final running = LocalServerRuntime.instance.isRunning;
    final menu = Menu(
      items: [
        MenuItem(key: _keyShow, label: '显示主界面'.tl),
        MenuItem.separator(),
        MenuItem(
          key: _keyToggleServer,
          label: running ? '停止服务'.tl : '启动服务'.tl,
        ),
        MenuItem.separator(),
        MenuItem(key: _keyExit, label: '退出'.tl),
      ],
    );
    try {
      await trayManager.setContextMenu(menu);
    } catch (_) {}
  }

  /// 显示并聚焦主窗口。
  Future<void> _showWindow() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  /// 真正退出:解除关窗拦截后销毁窗口(否则会被 onWindowClose 再拦回托盘)。
  Future<void> _exitApp() async {
    try {
      App.serviceRuntimeVersion.removeListener(_onRuntimeChanged);
      await trayManager.destroy();
    } catch (_) {}
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {}
  }

  @override
  void onTrayIconMouseDown() {
    // 左键单击托盘图标:显示主界面。
    unawaited(_showWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    // 右键弹出菜单。
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _keyShow:
        unawaited(_showWindow());
        break;
      case _keyToggleServer:
        if (LocalServerRuntime.instance.isRunning) {
          unawaited(LocalServerRuntime.instance.stop());
        } else {
          unawaited(LocalServerRuntime.instance.start());
        }
        break;
      case _keyExit:
        unawaited(_exitApp());
        break;
    }
  }

  static const _keyShow = 'show';
  static const _keyToggleServer = 'toggle_server';
  static const _keyExit = 'exit';
}

/// 顶层初始化入口,供 main.dart 在桌面初始化后调用。Windows 以外为 no-op。
Future<void> initTray() => TrayController.instance.init();
