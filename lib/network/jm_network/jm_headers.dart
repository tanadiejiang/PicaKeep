import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/ecb.dart';

const String _jmAuthKey = '18comicAPPContent';
const String kJmSecret = '185Hcomic3PAPP7R';
const String _jmPkgName = 'com.example.app';
const String jmAppVersion = '2.0.11';

String get _ua =>
    'Mozilla/5.0 (Linux; Android 10; K; wv) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Version/4.0 Chrome/138.0.0.0 Mobile Safari/537.36';

String get jmImgUA => 'Dalvik/2.1.0 (Linux; Android 10; K)';

Map<String, String> getJmBaseHeaders() => {
      'Accept': '*/*',
      'Accept-Encoding': 'gzip, deflate, br',
      'Accept-Language': 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7',
      'Connection': 'keep-alive',
      'Origin': 'https://localhost',
      'Referer': 'https://localhost/',
      'Sec-Fetch-Dest': 'empty',
      'Sec-Fetch-Mode': 'cors',
      'Sec-Fetch-Site': 'cross-site',
      'X-Requested-With': _jmPkgName,
    };

Map<String, String> getJmImgHeaders() => {
      'Accept': 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
      'Accept-Encoding': 'gzip, deflate, br',
      'Accept-Language': 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7',
      'Connection': 'keep-alive',
      'Referer': 'https://localhost/',
      'User-Agent': _ua,
      'X-Requested-With': _jmPkgName,
    };

BaseOptions getJmApiOptions(int time, {bool post = false}) {
  final token = md5.convert(const Utf8Encoder().convert('$time$_jmAuthKey'));
  return BaseOptions(
    receiveDataWhenStatusError: true,
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 30),
    responseType: ResponseType.bytes,
    headers: {
      ...getJmBaseHeaders(),
      'Authorization': 'Bearer',
      'Sec-Fetch-Storage-Access': 'active',
      'token': token.toString(),
      'tokenparam': '$time,$jmAppVersion',
      'user-agent': _ua,
      if (post) 'Content-Type': 'application/x-www-form-urlencoded',
    },
  );
}

/// AES-ECB 解密：base64 → 解密 → utf8 → 找最后一个 } 或 ] 截断
String convertJmData(String input, String secret) {
  final key = md5.convert(const Utf8Encoder().convert(secret));
  final data = base64Decode(input);
  final cipher = ECBBlockCipher(AESEngine())
    ..init(false, KeyParameter(const Utf8Encoder().convert(key.toString())));
  var offset = 0;
  final plain = Uint8List(data.length);
  while (offset < data.length) {
    offset += cipher.processBlock(data, offset, plain, offset);
  }
  final res = const Utf8Decoder(allowMalformed: true).convert(plain);
  var i = res.length - 1;
  for (; i >= 0; i--) {
    if (res[i] == '}' || res[i] == ']') break;
  }
  return res.substring(0, i + 1);
}
