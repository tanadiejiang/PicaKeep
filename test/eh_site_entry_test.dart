import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:picakeep/base.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/network/eh_network/eh_main_network.dart';
import 'package:picakeep/pages/online_comic/eh_login_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationCachePath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  open.overrideFor(
      OperatingSystem.windows,
      () =>
          DynamicLibrary.open('${Directory.current.path}/windows/sqlite3.dll'));
  final originalPaths = PathProviderPlatform.instance;
  late Directory root;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('picakeep_pk06_');
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({});
    await App.init(dataPathOverride: '${root.path}/data');
  });
  tearDownAll(() => PathProviderPlatform.instance = originalPaths);

  test('mixed-site image requests use their own cookies and referer', () async {
    final net = EhNetwork();
    for (final host in ['e-hentai.org', 'exhentai.org']) {
      net.cookieJar.saveFromResponse(Uri.parse('https://$host'),
          [Cookie('ipb_member_id', host)..path = '/']);
    }
    for (final selected in ['0', '1']) {
      appdata.settings[20] = selected;
      await net.getCookies(true);
      for (final host in ['exhentai.org', 'e-hentai.org']) {
        final headers = net.galleryHeaders('https://$host/g/123/abc/');
        expect(headers['Referer'], 'https://$host');
        expect(headers['Cookie'], contains('ipb_member_id=$host'));
        expect(headers['User-Agent'], EhNetwork.ehUA);
      }
    }
  });

  testWidgets('login entry switches both sites and persists the selection',
      (tester) async {
    appdata.settings[20] = '0';
    await tester.pumpWidget(const MaterialApp(home: EhLoginPage()));
    expect(find.text('搜索站点'), findsOneWidget);
    for (final value in ['1', '0']) {
      final field = tester.widget<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>));
      await tester.runAsync(() async {
        await (field.onChanged as dynamic)(value);
      });
      await tester.pumpAndSettle();
      expect(appdata.settings[20], value);
      final saved = await tester
          .runAsync(() => File('${App.dataPath}/settings').readAsString());
      expect((jsonDecode(saved!) as List)[20], value);
      expect(tester.takeException(), isNull);
    }
  });
}
