import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:picakeep/pages/settings/settings_page.dart';
import 'package:url_launcher/url_launcher.dart';

PackageInfo _packageInfo({
  String version = '1.9.54',
  String buildNumber = '1',
}) {
  return PackageInfo(
    appName: 'PicaKeep',
    packageName: 'io.github.tanadiejiang.picakeep',
    version: version,
    buildNumber: buildNumber,
  );
}

Widget _aboutPage({
  required PackageInfoLoader packageInfoLoader,
  AboutUrlLauncher? aboutUrlLauncher,
  Key? settingsPageKey,
  double textScale = 1,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(360, 800),
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 360,
            child: SettingsPage(
              key: settingsPageKey,
              initialPage: 9,
              packageInfoLoader: packageInfoLoader,
              aboutUrlLauncher: aboutUrlLauncher,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('formatAboutVersionText', () {
    test('uses the installed version and non-zero build number', () {
      expect(
        formatAboutVersionText(version: '1.9.54', buildNumber: '1'),
        'V1.9.54 (1)',
      );
    });

    test('omits blank and zero build numbers without a hard-coded fallback',
        () {
      expect(
        formatAboutVersionText(version: '1.9.54', buildNumber: ''),
        'V1.9.54',
      );
      expect(
        formatAboutVersionText(version: '1.9.54', buildNumber: '0'),
        'V1.9.54',
      );
      expect(
        formatAboutVersionText(version: ' ', buildNumber: '1'),
        '版本未知',
      );
    });
  });

  testWidgets('shows mocked package details, copy, and both external entries',
      (tester) async {
    final openedUrls = <Uri>[];
    final launchModes = <LaunchMode>[];
    await tester.pumpWidget(
      _aboutPage(
        packageInfoLoader: () async => _packageInfo(),
        aboutUrlLauncher: (uri, mode) async {
          openedUrls.add(uri);
          launchModes.add(mode);
          return true;
        },
      ),
    );
    await tester.pump();

    expect(find.text('PicaKeep'), findsOneWidget);
    expect(find.text('V1.9.54 (1)'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    final appIcon = tester.widget<Image>(find.byType(Image));
    expect(appIcon.image, isA<AssetImage>());
    expect((appIcon.image as AssetImage).assetName, 'assets/app_icon.png');
    expect(
      find.text(
        '把喜欢的漫画好好留在身边。\n专注本地收藏、整理与阅读，也支持多源下载和局域网跨设备浏览。',
      ),
      findsOneWidget,
    );
    expect(find.text('项目地址'), findsOneWidget);
    expect(find.text('问题反馈 (GitHub)'), findsOneWidget);

    await tester.ensureVisible(find.text('项目地址'));
    await tester.tap(find.text('项目地址'));
    await tester.pump();
    await tester.ensureVisible(find.text('问题反馈 (GitHub)'));
    await tester.tap(find.text('问题反馈 (GitHub)'));
    await tester.pump();

    expect(
      openedUrls,
      orderedEquals([
        Uri.parse('https://github.com/tanadiejiang/PicaKeep'),
        Uri.parse('https://github.com/tanadiejiang/PicaKeep/issues'),
      ]),
    );
    expect(
      launchModes,
      orderedEquals([
        LaunchMode.externalApplication,
        LaunchMode.externalApplication,
      ]),
    );
  });

  testWidgets('keeps the version area stable while loading and handles errors',
      (tester) async {
    final completer = Completer<PackageInfo>();
    var loadCount = 0;
    await tester.pumpWidget(
      _aboutPage(
        packageInfoLoader: () {
          loadCount += 1;
          return completer.future;
        },
      ),
    );

    final versionFinder = find.byKey(const ValueKey('about-version'));
    expect(find.text('版本读取中'), findsOneWidget);
    final loadingSize = tester.getSize(versionFinder);
    expect(loadCount, 1);

    completer.complete(_packageInfo());
    await tester.pump();

    expect(find.text('V1.9.54 (1)'), findsOneWidget);
    expect(tester.getSize(versionFinder).height, loadingSize.height);
    expect(loadCount, 1);

    await tester.pumpWidget(
      _aboutPage(
        packageInfoLoader: () =>
            Future<PackageInfo>.error(StateError('test failure')),
        aboutUrlLauncher: (_, __) async => false,
        settingsPageKey: const ValueKey('failed-about-page'),
        textScale: 1.8,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('版本未知'), findsOneWidget);
    await tester.ensureVisible(find.text('项目地址'));
    await tester.tap(find.text('项目地址'));
    await tester.pump();
    expect(find.text('无法打开项目地址'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
