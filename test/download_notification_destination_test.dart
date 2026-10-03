import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/pages/download_page.dart';
import 'package:picakeep/foundation/local_library_settings.dart';

void main() {
  test(
      'notification destination opens local downloads without overwriting the remembered remote/aggregate setting',
      () {
    final saved = appdata.settings[downloadedLibraryViewSettingIndex];
    addTearDown(
        () => appdata.settings[downloadedLibraryViewSettingIndex] = saved);
    for (final view in ['remote', 'aggregate']) {
      appdata.settings[downloadedLibraryViewSettingIndex] = view;
      final normal = DownloadPageLogic();
      final fromNotice = DownloadPageLogic(forceLocal: true);
      expect(normal.shouldAutoRefreshOnResume, isTrue);
      expect(fromNotice.shouldAutoRefreshOnResume, isFalse);
      expect(appdata.settings[downloadedLibraryViewSettingIndex], view);
    }
  });
}
