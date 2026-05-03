// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'foundation/app.dart';
import 'foundation/log.dart';
import 'foundation/history.dart';
import 'foundation/local_favorites.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'foundation/def.dart';
import 'foundation/download.dart';
export 'foundation/def.dart';

String get pathSep => Platform.pathSeparator;

var downloadManager = DownloadManager();

class Appdata {
  List<String> searchHistory = [];
  Set<String> favoriteTags = {};

  var history = HistoryManager();

  List<String> settings = [
    "1", //0
    "dd", //1
    "1", //2
    "0", //3
    "1", //4
    "1", //5
    "1", //6
    "1", //7
    "0", //8
    "1", //9
    "0", //10
    "0", //11
    "0", //12
    "0", //13
    "1", //14
    "1", //15
    "0", //16
    "0", //17
    "0", //18
    "0", //19
    "0", //20
    "111111", //21
    "", //22
    "0", //23
    "1111111111", //24
    "0", //25
    "00", //26
    "0", //27
    "2", //28
    "0", //29
    "1", //30
    "https://www.wnacg.com", //31
    "0", //32
    "5", //33
    "1000", //34
    "500", //35
    "1", //36
    "0", //37
    "0", //38
    "0", //39
    "25", //40
    "0", //41
    "0", //42
    "1", //43
    "0,1.0", //44
    "", //45
    "0", //46
    "0", //47
    "https://nhentai.net", //48
    "1", //49
    "", //50
    "", //51
    "0", //52
    "0", //53
    "0", //54
    "1", //55
    "https://18comic.vip", //56
    "1", //57
    "0", //58
    "012345678", //59
    "0", //60
    "0", //61
    "10000", //62
    "0", //63
    "0", //64
    "0", //65
    "0", //66
    "picacg,ehentai,jm,htmanga,nhentai", //67
    "picacg,ehentai,jm,htmanga,nhentai", //68
    "0", //69
    "0", //70
    "1", // 71
    "1", //72
    "0", //73
    "1.0", //74
    "", //75
    "0", //76
    "picacg,Eh主页,Eh热门,禁漫主页,禁漫最新,hitomi,绅士漫画,nhentai", //77
    "0", //78
    "6", //79
    "1", //80
    "0", //81
    "111111", //82
    "1", //83
    "0", //84
    "www.cdntwice.org,www.cdnsha.org,www.cdnaspa.cc,www.cdnntr.cc", //85
    "https://cdn-msp.jmapiproxy3.cc", //86
    "gold-usergeneratedcontent.net", //87
    "0", //88
    "2.0.11", //89
  ];

  List<String> implicitData = [
    "1;;",
    "0",
    "0",
    webUA,
  ];

  void writeImplicitData() async {
    var s = await SharedPreferences.getInstance();
    await s.setStringList("implicitData", implicitData);
  }

  void readImplicitData() async {
    var s = await SharedPreferences.getInstance();
    var data = s.getStringList("implicitData");
    if (data == null) {
      writeImplicitData();
      return;
    }
    for (int i = 0; i < data.length && i < implicitData.length; i++) {
      implicitData[i] = data[i];
    }
  }

  List<String> blockingKeyword = [];

  List<String> firstUse = [
    "1",
    "1",
    "1",
    "0",
    "1",
  ];

  int getSearchMode() {
    var modes = ["dd", "da", "ld", "vd"];
    return modes.indexOf(settings[1]);
  }

  void setSearchMode(int mode) async {
    var modes = ["dd", "da", "ld", "vd"];
    settings[1] = modes[mode];
    var s = await SharedPreferences.getInstance();
    await s.setStringList("settings", settings);
  }

  Future<void> readSettings(SharedPreferences s) async {
    var settingsFile = File("${App.dataPath}/settings");
    List<String> st;
    if (settingsFile.existsSync()) {
      var json = jsonDecode(await settingsFile.readAsString());
      if (json is List) {
        st = List.from(json);
      } else {
        st = [];
      }
    } else {
      st = s.getStringList("settings") ?? [];
    }
    for (int i = 0; i < st.length && i < settings.length; i++) {
      settings[i] = st[i];
    }
    if (settings[26].length < 2) {
      settings[26] += "0";
    }
  }

  Future<void> updateSettings([bool syncData = true]) async {
    var settingsFile = File("${App.dataPath}/settings");
    await settingsFile.writeAsString(jsonEncode(settings));
    if (syncData) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList("settings", settings);
  }

  void writeFirstUse() async {
    var s = await SharedPreferences.getInstance();
    await s.setStringList("firstUse", firstUse);
  }

  void writeHistory() async {
    var s = await SharedPreferences.getInstance();
    await s.setStringList("search", searchHistory);
    await s.setStringList("favoriteTags", favoriteTags.toList());
  }

  Future<void> writeData([bool sync = true]) async {
    await updateSettings();
  }

  Future<bool> readData() async {
    var s = await SharedPreferences.getInstance();
    try {
      await readSettings(s);
      searchHistory = s.getStringList("search") ?? [];
      favoriteTags = (s.getStringList("favoriteTags") ?? []).toSet();
      blockingKeyword = s.getStringList("blockingKeyword") ?? [];
      if (s.getStringList("firstUse") != null) {
        var st = s.getStringList("firstUse")!;
        for (int i = 0; i < st.length; i++) {
          firstUse[i] = st[i];
        }
      }
      readImplicitData();
      return firstUse[3] == "1";
    } catch (e) {
      return false;
    }
  }

  Map<String, dynamic> toJson() => {
        "settings": settings,
        "firstUse": firstUse,
        "blockingKeywords": blockingKeyword,
        "favoriteTags": favoriteTags.toList(),
      };

  bool readDataFromJson(Map<String, dynamic> json) {
    try {
      var newSettings = List<String>.from(json["settings"]);
      var downloadPath = settings[22];
      var authRequired = settings[13];
      for (var i = 0; i < settings.length && i < newSettings.length; i++) {
        settings[i] = newSettings[i];
      }
      settings[22] = downloadPath;
      settings[13] = authRequired;
      var newFirstUse = List<String>.from(json["firstUse"]);
      for (var i = 0; i < firstUse.length && i < newFirstUse.length; i++) {
        firstUse[i] = newFirstUse[i];
      }
      if (json["history"] != null) {
        history.readDataFromJson(json["history"]);
      }
      blockingKeyword = Set<String>.from(
              ((json["blockingKeywords"] ?? []) + blockingKeyword) as List)
          .toList();
      favoriteTags =
          Set.from((json["favoriteTags"] ?? []) + List.from(favoriteTags));
      writeData(false);
      return true;
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Appdata.readDataFromJson",
          "error reading appdata$e\n$s");
      readData();
      return false;
    }
  }

  final appSettings = _Settings();

  ReaderSettings readerSettings = ReaderSettings();

  bool read(dynamic key) => true;

  void save() {
    writeData();
  }
}

var appdata = Appdata();

class ReaderSettings {
  int readerType = 0;
  int readerDirection = 0;
  int readingDirection = 0;
  double pageTurningInterval = 0.0;
  int preload = 0;
  String readingBounds = '';
}

Future<void> eraseCache(
    {List<String>? types, bool onlyExpired = false}) async {}

Future<void> clearAppdata() async {
  var s = await SharedPreferences.getInstance();
  await s.clear();
  var settingsFile = File("${App.dataPath}/settings");
  if (await settingsFile.exists()) {
    await settingsFile.delete();
  }
  appdata.history.clearHistory();
  appdata = Appdata();
  await appdata.readData();
  await eraseCache();
  await LocalFavoritesManager().clearAll();
}

class _Settings {
  List<String> get _settings => appdata.settings;

  int get theme => int.parse(_settings[27]);

  set theme(int value) {
    appdata.settings[27] = value.toString();
  }

  int get darkMode => int.parse(appdata.settings[32]);

  set darkMode(int value) {
    appdata.settings[32] = value.toString();
  }

  int get comicTileDisplayType =>
      int.parse(appdata.settings[44].split(',').first);

  set comicTileDisplayType(int v) {
    var values = appdata.settings[44].split(',');
    if (values.length != 2) {
      values = ['0', '1.0'];
    }
    values[0] = v.toString();
    appdata.settings[44] = values.join(',');
  }

  int get comicsListDisplayType => int.parse(appdata.settings[25]);

  set comicsListDisplayType(int value) {
    appdata.settings[25] = value.toString();
  }

  String get initialSearchTarget => appdata.settings[63];

  set initialSearchTarget(String value) {
    appdata.settings[63] = value;
  }

  bool get reduceBrightnessInDarkMode => appdata.settings[18] == "1";

  set reduceBrightnessInDarkMode(bool value) {
    appdata.settings[18] = value ? "1" : "0";
  }

  bool get showPageInfoInReader => appdata.settings[57] == "1";

  set showPageInfoInReader(bool value) {
    appdata.settings[57] = value ? "1" : "0";
  }

  bool get showButtonsInReader => appdata.settings[4] == "1";

  set showButtonsInReader(bool value) {
    appdata.settings[4] = value ? "1" : "0";
  }

  bool get flipPageWithClick => appdata.settings[0] == "1";

  set flipPageWithClick(bool value) {
    appdata.settings[0] = value ? "1" : "0";
  }

  bool get useDarkBackground => appdata.settings[81] == "1";

  set useDarkBackground(bool value) {
    appdata.settings[81] = value ? "1" : "0";
  }

  bool get fullyHideBlockedWorks => appdata.settings[83] == "1";

  set fullyHideBlockedWorks(bool value) {
    appdata.settings[83] = value ? "1" : "0";
  }

  int get cacheLimit => int.tryParse(appdata.settings[35]) ?? 500;

  set cacheLimit(int value) {
    appdata.settings[35] = value.toString();
  }
}
