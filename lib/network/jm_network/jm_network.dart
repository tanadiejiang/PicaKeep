import 'package:picakeep/network/res.dart';

class CookieJar {
  Future<void> deleteAll() async {}
}

class JmNetwork {
  CookieJar cookieJar = CookieJar();

  Future<void> getProfile() async {}

  Future<Map<String, dynamic>?> getProfileFromServer() async => null;

  Future<bool> punchIn() async => false;

  Future<Map<String, dynamic>?> getComicInfo(String id) async => null;

  Future<Res<List<String>>> getChapter(String id) async {
    return Res([]);
  }
}
