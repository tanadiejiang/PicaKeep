import 'package:flutter/services.dart';
import 'package:picakeep/foundation/app.dart';

class AppIconInfo {
  const AppIconInfo({required this.id, required this.label});

  final String id;
  final String label;
}

class AppIconChannel {
  AppIconChannel._();

  static final AppIconChannel instance = AppIconChannel._();

  static const MethodChannel _channel =
      MethodChannel('lingxue.picakeep/app_icon');

  Future<List<AppIconInfo>> list() async {
    if (!App.isAndroid) {
      return const [];
    }
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('list');
      if (result == null) {
        return const [];
      }
      return result
          .whereType<Map<Object?, Object?>>()
          .map((item) {
            final id = item['id'];
            final label = item['label'];
            if (id is! String || label is! String) {
              return null;
            }
            return AppIconInfo(id: id, label: label);
          })
          .whereType<AppIconInfo>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<String?> current() async {
    if (!App.isAndroid) {
      return null;
    }
    try {
      return await _channel.invokeMethod<String>('current');
    } catch (_) {
      return null;
    }
  }

  Future<void> set(String id) async {
    if (!App.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('set', {'id': id});
    } catch (_) {}
  }
}
