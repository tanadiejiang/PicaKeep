import 'package:flutter/material.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/network/eh_network/eh_models.dart';
import 'package:picakeep/network/res.dart';

bool isEhContentWarning(Res<Gallery> result) {
  return result.error &&
      result.errorMessageWithoutNull.contains('Content Warning');
}

typedef EhGalleryInfoRequest = Future<Res<Gallery>> Function(
  String link,
  bool setNW,
);

typedef EhContentWarningConfirmation = Future<bool?> Function();

Future<Res<Gallery>> requestEhGalleryInfoWithContentWarning({
  required String link,
  required EhGalleryInfoRequest request,
  required EhContentWarningConfirmation confirmContentWarning,
}) async {
  final initialResult = await request(link, true);
  if (!isEhContentWarning(initialResult)) {
    return initialResult;
  }
  if (await confirmContentWarning() != true) {
    return initialResult;
  }
  return request(link, false);
}

Future<Res<Gallery>> getEhGalleryInfoWithContentWarning({
  required BuildContext context,
  required String link,
}) async {
  final network = EhNetwork();
  return requestEhGalleryInfoWithContentWarning(
    link: link,
    request: (link, setNW) => network.getGalleryInfo(link, setNW),
    confirmContentWarning: () async {
      if (!context.mounted) {
        return false;
      }
      return showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('内容警告'),
          content: const Text('该画廊标记了成人内容警告。确认继续查看吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('继续'),
            ),
          ],
        ),
      );
    },
  );
}
