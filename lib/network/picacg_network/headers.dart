import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import 'package:picakeep/comic_source/built_in/picacg.dart';
import 'package:picakeep/network/app_dio.dart';

const String _apiKey = 'C69BAF41DA5ABD1FFEDC6D2FEA56B';
const String _signatureSecret =
    '~d}\$Q7\$eIni=V)9\\RK/P.RM4;9[7|@/CA}b~OW!3?EV`:<>M7pddUBL5n|0/*Cn';

String _createNonce() => const Uuid().v1().replaceAll('-', '');

String createPicacgSignature(
  String path,
  String nonce,
  String time,
  String method,
) {
  final source = '$path$time$nonce$method$_apiKey'.toLowerCase();
  final hmacSha256 = Hmac(sha256, utf8.encode(_signatureSecret));
  return hmacSha256.convert(utf8.encode(source)).toString();
}

BaseOptions picacgHeaders(String method, String token, String path) {
  final nonce = _createNonce();
  final time = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
  final normalizedMethod = method.toUpperCase();
  return BaseOptions(
    receiveDataWhenStatusError: true,
    responseType: ResponseType.plain,
    connectTimeout: networkConnectTimeout,
    receiveTimeout: networkReceiveTimeout,
    sendTimeout: networkSendTimeout,
    headers: {
      'api-key': _apiKey,
      'accept': 'application/vnd.picacomic.com.v1+json',
      'app-channel': picacg.data['appChannel']?.toString() ?? '3',
      'authorization': token,
      'time': time,
      'nonce': nonce,
      'app-version': '2.2.1.3.3.4',
      'app-uuid': 'defaultUuid',
      'image-quality': picacg.data['imageQuality']?.toString() ?? 'original',
      'app-platform': 'android',
      'app-build-version': '45',
      'Content-Type': 'application/json; charset=UTF-8',
      'user-agent': 'okhttp/3.8.1',
      'version': 'v1.4.1',
      'Host': 'picaapi.picacomic.com',
      'signature': createPicacgSignature(
        path,
        nonce,
        time,
        normalizedMethod,
      ),
    },
  );
}
