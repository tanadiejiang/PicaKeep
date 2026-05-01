import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_gallery_saver/flutter_image_gallery_saver.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/log.dart';
import 'package:picakeep/tools/translations.dart';
import 'package:share_plus/share_plus.dart';

void _toast(String message) {
  final c = App.globalContext;
  if (c == null) return;
  ScaffoldMessenger.maybeOf(c)?.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
  );
}

String _fileNameFromPath(String path) {
  final i = path.replaceAll('\\', '/').lastIndexOf('/');
  return i >= 0 ? path.substring(i + 1) : path;
}

({String ext, String mime}) _detectType(List<int> data) {
  if (data.length >= 3 &&
      data[0] == 0xff &&
      data[1] == 0xd8 &&
      data[2] == 0xff) {
    return (ext: '.jpg', mime: 'image/jpeg');
  }
  if (data.length >= 8 &&
      data[0] == 0x89 &&
      data[1] == 0x50 &&
      data[2] == 0x4e &&
      data[3] == 0x47) {
    return (ext: '.png', mime: 'image/png');
  }
  if (data.length >= 12 &&
      data[0] == 0x52 &&
      data[1] == 0x49 &&
      data[2] == 0x46 &&
      data[3] == 0x46) {
    return (ext: '.webp', mime: 'image/webp');
  }
  return (ext: '.jpg', mime: 'image/jpeg');
}

/// Save current image to gallery (mobile) or user-chosen path (desktop).
Future<void> saveImage(File file) async {
  final data = await file.readAsBytes();
  final type = _detectType(data);
  var fileName = _fileNameFromPath(file.path);
  if (!fileName.contains('.')) {
    fileName += type.ext;
  }
  if (App.isAndroid || App.isIOS) {
    final imageSaver = ImageGallerySaver();
    await imageSaver.saveImage(data);
    _toast("已保存".tl);
  } else if (App.isDesktop) {
    try {
      final path =
          (await getSaveLocation(suggestedName: fileName))?.path;
      if (path != null) {
        final xFile = XFile.fromData(
          data,
          mimeType: type.mime,
          name: fileName,
        );
        await xFile.saveTo(path);
        _toast("已保存".tl);
      }
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Save Image", "$e\n$s");
    }
  }
}

Future<String> persistentCurrentImage(File file) async {
  final dir = Directory("${App.dataPath}/images");
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  final name = _fileNameFromPath(file.path);
  final newFile = File("${dir.path}/$name");
  if (!await newFile.exists()) {
    await newFile.writeAsBytes(await file.readAsBytes());
  }
  return newFile.path;
}

void shareImage(File file) {
  Share.shareXFiles([XFile(file.path)]);
}
