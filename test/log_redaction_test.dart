import 'dart:io';
import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:picakeep/foundation/app.dart';
import 'package:picakeep/foundation/log_file_service.dart';
import 'package:picakeep/network/app_dio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('picakeep_log_redaction_');
    App.dataPath = root.path;
    addTearDown(() async {
      await LogFileService.instance.dispose();
      await root.delete(recursive: true);
    });
  });

  group('NetworkLogRedactor', () {
    test('redacts credential fields recursively without changing the source',
        () {
      final source = <String, Object?>{
        'Authorization': 'Bearer AUTH_CREDENTIAL_CANARY',
        'COOKIE': 'session=COOKIE_CREDENTIAL_CANARY',
        'sEt-CoOkIe': 'session=SET_COOKIE_CREDENTIAL_CANARY',
        'nested': <Object?>[
          <String, Object?>{'x-api-key': 'API_CREDENTIAL_CANARY'},
          <String, Object?>{
            'api-key': 'ALT_API_CREDENTIAL_CANARY',
            'apiKey': 'CAMEL_API_CREDENTIAL_CANARY',
            'access_token': 'ACCESS_CREDENTIAL_CANARY',
            'refresh_token': 'REFRESH_CREDENTIAL_CANARY',
            'password': 'PASSWORD_CREDENTIAL_CANARY',
            'pwd': 'PWD_CREDENTIAL_CANARY',
          },
        ],
        'body': <String, Object?>{
          'messages': <Object?>[
            <String, String>{'content': 'BODY_CANARY'},
          ],
          'tools': <String>['TOOL_CANARY'],
          'response': 'RESPONSE_BODY_CANARY',
        },
      };

      final redacted = NetworkLogRedactor.redactCopy(source)! as Map;
      final rendered = redacted.toString();

      expect(rendered, isNot(contains('AUTH_CREDENTIAL_CANARY')));
      expect(rendered, isNot(contains('COOKIE_CREDENTIAL_CANARY')));
      expect(rendered, isNot(contains('SET_COOKIE_CREDENTIAL_CANARY')));
      expect(rendered, isNot(contains('API_CREDENTIAL_CANARY')));
      expect(rendered, isNot(contains('ALT_API_CREDENTIAL_CANARY')));
      expect(rendered, isNot(contains('CAMEL_API_CREDENTIAL_CANARY')));
      expect(rendered, isNot(contains('ACCESS_CREDENTIAL_CANARY')));
      expect(rendered, isNot(contains('REFRESH_CREDENTIAL_CANARY')));
      expect(rendered, isNot(contains('PASSWORD_CREDENTIAL_CANARY')));
      expect(rendered, isNot(contains('PWD_CREDENTIAL_CANARY')));
      expect(rendered, contains('BODY_CANARY'));
      expect(rendered, contains('TOOL_CANARY'));
      expect(rendered, contains('RESPONSE_BODY_CANARY'));
      expect(source['Authorization'], 'Bearer AUTH_CREDENTIAL_CANARY');
      expect(
        ((source['nested']! as List).first as Map)['x-api-key'],
        'API_CREDENTIAL_CANARY',
      );
    });

    test('redacts URL parameters, user info, Bearer and Cookie text', () {
      final uri = Uri.parse(
        'https://user:pass@example.com/v1?query=BODY_CANARY&'
        'access_token=URL_CREDENTIAL_CANARY&Api-Key=URL_API_CANARY&'
        'refresh_token=URL_REFRESH_CANARY&password=URL_PASSWORD_CANARY',
      );
      final redactedUri = NetworkLogRedactor.redactUri(uri).toString();
      final redactedText = NetworkLogRedactor.redactText(
        'Authorization: Bearer TEXT_CREDENTIAL_CANARY\n'
        'Cookie: sid=COOKIE_TEXT_CANARY\n'
        'Set-Cookie: sid=SET_COOKIE_TEXT_CANARY\n'
        'response body BODY_CANARY',
      );

      expect(redactedUri, isNot(contains('user:pass')));
      expect(redactedUri, isNot(contains('URL_CREDENTIAL_CANARY')));
      expect(redactedUri, isNot(contains('URL_API_CANARY')));
      expect(redactedUri, isNot(contains('URL_REFRESH_CANARY')));
      expect(redactedUri, isNot(contains('URL_PASSWORD_CANARY')));
      expect(redactedUri, contains('BODY_CANARY'));
      expect(redactedText, isNot(contains('TEXT_CREDENTIAL_CANARY')));
      expect(redactedText, isNot(contains('COOKIE_TEXT_CANARY')));
      expect(redactedText, isNot(contains('SET_COOKIE_TEXT_CANARY')));
      expect(redactedText, contains('BODY_CANARY'));
      expect(uri.toString(), contains('URL_CREDENTIAL_CANARY'));
    });
  });

  test('history export creates a redacted temporary copy', () async {
    final source = File('${root.path}${Platform.pathSeparator}history.txt');
    await source.writeAsString(
      'Authorization: Bearer SERVICE_CREDENTIAL_CANARY\n'
      'Cookie: sid=SERVICE_COOKIE_CANARY\n'
      'data: {messages: [{content: SERVICE_BODY_CANARY}]}',
    );
    final temp = Directory('${root.path}${Platform.pathSeparator}temp');
    await temp.create();

    final exported = await LogFileService.instance.exportHistory(
      source.path,
      temporaryDirectory: temp,
    );

    expect(exported, isNotNull);
    expect(exported, isNot(source.path));
    final exportedText = await File(exported!).readAsString();
    expect(exportedText, isNot(contains('SERVICE_CREDENTIAL_CANARY')));
    expect(exportedText, isNot(contains('SERVICE_COOKIE_CANARY')));
    expect(exportedText, contains('SERVICE_BODY_CANARY'));
    expect(await source.readAsString(), contains('SERVICE_CREDENTIAL_CANARY'));
  });

  test('copyAll, current export, and ZIP export never expose credentials',
      () async {
    final service = LogFileService.instance;
    await service.init();
    expect(service.currentFilePath, isNotNull);
    service.writeLine(
      'Authorization: Bearer CURRENT_CREDENTIAL_CANARY\n'
      'data: CURRENT_BODY_CANARY',
    );
    final copied = await service.copyAll();
    expect(copied, isNot(contains('CURRENT_CREDENTIAL_CANARY')));
    expect(copied, contains('CURRENT_BODY_CANARY'));

    final temp = Directory('${root.path}${Platform.pathSeparator}exports');
    await temp.create();
    final currentPath = await service.exportCurrent(temporaryDirectory: temp);
    expect(currentPath, isNotNull);
    final current = await File(currentPath!).readAsString();
    expect(current, isNot(contains('CURRENT_CREDENTIAL_CANARY')));
    expect(current, contains('CURRENT_BODY_CANARY'));

    final zipPath = await service.exportAllAsZip(temporaryDirectory: temp);
    expect(zipPath, isNotNull);
    final archive = ZipDecoder().decodeBytes(
      await File(zipPath!).readAsBytes(),
    );
    final zipText = archive.files
        .where((file) => file.isFile)
        .map((file) => utf8.decode(file.content as List<int>))
        .join('\n');
    expect(zipText, isNot(contains('CURRENT_CREDENTIAL_CANARY')));
    expect(zipText, contains('CURRENT_BODY_CANARY'));
  });
}
