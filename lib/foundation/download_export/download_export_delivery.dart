import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:share_plus/share_plus.dart';

import 'download_export_models.dart';

class PlatformDownloadExportArtifactSink implements DownloadExportArtifactSink {
  const PlatformDownloadExportArtifactSink();

  @override
  Future<DownloadExportDeliveryOutcome> deliver(
    DownloadExportArtifact artifact,
  ) async {
    if (_isDesktop) {
      final location = await getSaveLocation(
        suggestedName: artifact.suggestedName,
      );
      if (location == null) {
        return const DownloadExportDeliveryOutcome.cancelled();
      }
      await XFile(artifact.path).saveTo(location.path);
      return const DownloadExportDeliveryOutcome.delivered();
    }

    final result = await Share.shareXFiles(
      [XFile(artifact.path)],
      text: 'PicaKeep',
    );
    if (result.status == ShareResultStatus.dismissed) {
      return const DownloadExportDeliveryOutcome.cancelled();
    }
    if (result.status == ShareResultStatus.unavailable) {
      throw StateError('系统分享面板不可用');
    }
    return const DownloadExportDeliveryOutcome.delivered();
  }

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;
}
