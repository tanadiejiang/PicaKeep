import 'package:flutter/material.dart';
import 'package:picakeep/tools/android_foreground_service.dart';
import 'package:picakeep/tools/download_notification_controller.dart';

Future<void> showDownloadBackgroundSupport(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _DownloadBackgroundSupport(),
    );

class _DownloadBackgroundSupport extends StatefulWidget {
  const _DownloadBackgroundSupport();
  @override
  State<_DownloadBackgroundSupport> createState() =>
      _DownloadBackgroundSupportState();
}

class _DownloadBackgroundSupportState extends State<_DownloadBackgroundSupport>
    with WidgetsBindingObserver {
  AndroidForegroundServiceSupportState? _support;
  bool _busy = false;
  final _controller = AndroidForegroundServiceController.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _read();
  }

  Future<void> _read() async {
    final support = await _controller.readSupportState();
    if (mounted) setState(() => _support = support);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _read();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _requestNotifications() async {
    if (_busy) return;
    setState(() => _busy = true);
    final granted = await _controller.requestNotificationPermission();
    if (!granted) await _controller.openNotificationSettings();
    await _read();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('后台下载', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                const Text('下载会显示进度通知。锁屏或切换应用时继续下载；断网后等待网络恢复。'),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.notifications_outlined),
                  title: const Text('下载通知'),
                  subtitle: Text(_support == null
                      ? '正在读取…'
                      : _support!.notificationsGranted
                          ? '已允许'
                          : '未允许，通知可能不可见'),
                  trailing: TextButton(
                      onPressed: _busy ? null : _requestNotifications,
                      child: const Text('设置')),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.battery_saver_outlined),
                  title: const Text('电池优化'),
                  subtitle: Text(_support == null
                      ? '正在读取…'
                      : _support!.ignoringBatteryOptimizations
                          ? '已允许不受电池优化限制'
                          : '系统可能限制锁屏联网，可按需调整'),
                  trailing: TextButton(
                      onPressed: _controller.openBatteryOptimizationSettings,
                      child: const Text('设置')),
                ),
                ValueListenableBuilder<String?>(
                  valueListenable:
                      DownloadNotificationController.instance.warning,
                  builder: (_, warning, __) => warning == null
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(warning,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error)),
                        ),
                ),
                const Text(
                    '系统后台时限、省电策略或手动结束应用仍可能中断下载。任务会保留，重新打开后可继续；不会自动更改系统设置。'),
              ],
            ),
          ),
        ),
      );
}
