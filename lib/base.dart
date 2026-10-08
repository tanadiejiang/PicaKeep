import 'package:picakeep/foundation/pixiv_library.dart';
// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'foundation/archive/archive_memory_cache.dart';
import 'foundation/archive/archive_password_store.dart';
import 'foundation/ai/ai_prompt_tags.dart';
import 'foundation/app.dart';
import 'foundation/app_runtime_mode.dart';
import 'foundation/illust_card_info_config.dart';
import 'foundation/local_data_source.dart';
import 'foundation/local_library_illust_view.dart';
import 'foundation/local_library_settings.dart';
import 'foundation/log.dart';
import 'foundation/explore/explore_selection_state.dart';
import 'foundation/pixiv_download_naming.dart';
import 'foundation/pixiv_bookmark_feedback_settings.dart';
import 'foundation/reader_image_quality.dart';
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
    "", //8 代理地址 host:port，空=不使用手动代理（自动跟随系统代理）
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
    "0", //75
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
    "", //90 原应用下载目录
    "[]", //91 本地漫画路径列表
    "0", //92 本地图集图片排序
    "time_desc", //93 本地图集列表排序
    "1", //94 本地图集页仅显示图集
    "0", //95 本地详情页相关推荐模式
    "0", //96 无论有无文件都按下载数据库显示
    "client", //97 运行模式
    "", //98 客户端服务端地址
    "mdns", //99 局域网发现方式
    "9527", //100 服务端后台端口（默认值应与 defaultServiceAdminPort 保持一致）
    "0", //101 安卓 Root 浏览模式
    "0", //102 安卓 Shizuku 浏览模式
    "local", //103 已下载页来源视图
    "local", //104 资源库页来源视图
    "trash", //105 删除行为
    '["service_info","local_files","app_capabilities","trash"]', //106 外显工具顺序
    '["service_info","local_files","app_capabilities","trash"]', //107 外显工具显示
    '[]', //108 压缩包默认密码列表
    '1', //109 压缩包自动解密开关
    '32', //110 压缩包阅读缓存上限 MB
    '0', //111 压缩包章节使用序号
    'local', //112 收藏页来源视图
    'local', //113 图片收藏页来源视图
    '6', //114 阅读时远程图片并发上限
    '8', //115 浏览时远程图片并发上限
    '980', //116 阅读最大显示宽度 px
    '1', //117 mDNS 失败时自动网段扫描
    '{}', //118 图集合集外壳目录识别
    '2', //119 App 字号（0跟随系统/1小/2标准/3大/4特大）
    '0', //120 showAiTab
    '0', //121 aiCapabilitySearchOnline
    '0', //122 aiCapabilityDownloadComic
    '0', //123 aiCapabilitySearchLocal
    '0', //124 aiCapabilityQueryLocalLibrary
    '0', //125 aiCapabilityResolveLocalItems
    '0', //126 aiCapabilityGetDownloadStatus
    '', //127 aiProviderTemplate
    '', //128 aiBaseUrl
    '', //129 aiApiKey
    '', //130 aiModelId
    '{}', //131 aiModelParams
    '[]', //132 aiPromptTemplates
    '0', //133 aiCapabilityQueryRemoteLibrary
    '0', //134 aiCapabilityDisplayResultList
    '0', //135 aiCapabilityManageFavorites
    '0', //136 aiPromptTagsLongTerm
    '0', //137 aiPromptTemplatesInitialized
    '5', //138 aiMaxToolRounds
    '0', //139 aiCapabilityGetComicDetail
    '[]', //140 服务发现自定义端口 JSON
    '1', //141 aiIndexUserOnly 消息索引仅显示用户对话
    '6', //142 aiIndexBarMaxTicks 迷你索引条刻度上限，'0'=不限制
    '0', //143 aiModelSupportsVision 当前模型支持图片识别（视觉）
    '{}', //144 aiOcrConfig OCR 接口配置 JSON
    '0', //145 aiCapabilitySearchByImage 以图搜源
    '1', //146 aiThinkingEnabled 开启思考（关=请求带 thinking:disabled）
    '1', //147 aiShowReasoning 会话中显示思考过程（纯 UI，不影响接收与存档）
    '0', //148 aiPersistentCardDismissed 已了解长期状态卡片（1=永久隐藏）
    '0', //149 aiAutoDownloadEnabled AI自动下载（0=关闭=工具不暴露给AI；1=允许AI自行入队）
    '{}', //150 comicTileDisplayConfig 卡片信息显示配置 JSON，结构 {"local":{...},"online":{...},"search":{"<源key>":{...}}}，每个节点 {"tagRows":2,"showTags":true,"showId":true}（tagRows 0=不限行）；读写见 foundation/comic_tile_display_config.dart
    '0', //151 originalDirUsageMode 原应用下载目录的使用方式：0=直接使用（原地读取，默认，不占额外空间）；1=复制到本应用下载目录后再使用（摆脱对原目录与权限的依赖，但占用双倍空间）
    '', //152 pixivDownloadDir Pixiv 专属下载目录；空=跟随「本应用下载目录」（settings[22]）。Pixiv 是单图作品，与漫画混在一个目录里不好翻，所以允许单独指定
    kDefaultPixivDirNameTemplate, //153 pixivDirNameTemplate 默认标题 + 作品 ID；见 foundation/pixiv_download_naming.dart
    '0', //154 pixivMultiPageZip Pixiv 多图打包：1=多图打成一个 zip（仅存储不加密）、单图直接放图片文件；0=一个作品一个目录（默认，与改动前逐字节一致）。读取侧必须同时认两种形态，见 local_library_static.dart
    'album', //155 illustLibraryView 图集页当前视图：album=图集（默认，与改动前一致）／illust=Pixiv 插画瀑布流。与三档来源（settings[104]）**正交**，见 foundation/local_library_illust_view.dart
    '3', //156 illustWaterfallColumns 插画瀑布流列数（2 或 3）
    'right', //157 illustViewSwitcherPosition 视图切换悬浮按钮位置：right（默认，与既有 FAB 一致）／left
    '{title}\n{author}', //158 illustCardInfo 插画卡片底部信息模板，支持 {title} / {author} / {pages} / {size}；默认 `{title}`+换行+`{author}`，与改动前"标题、作者各占一行"逐字一致（分隔符默认是换行，见 foundation/illust_card_info_config.dart）
    '0', //159 readerHighQualityComic 漫画阅读高清模式：1=按图片自身分辨率解码（原图）；0=按屏幕宽度降采样（默认，省内存）。见 foundation/reader_image_quality.dart
    '1', //160 readerHighQualityIllust 插画/图集阅读高清模式：1=原图（**默认开**）；0=降采样。与 159 分开是用户要求两类内容各自控制，默认值方向也相反
    'ask', //161 pixivTransferPolicy
    'ask', //162 pixivFolderDeletePolicy
    '0', //163 illustSearchMatchTags 插画搜索关键词是否同时匹配作品标签：0=只匹配标题/作者（默认，与 56 号搜索面板行为一致）；1=标题/作者/标签任一命中。见 foundation/local_library_illust_view.dart
    '{}', //164 exploreSelectionState Pixiv 探索页分区/入口/榜单范围选择状态 JSON
    '', //165 readerImagePipelineSettings: versioned original-file reader policy
    '0', //166 pixivBookmarkQueueCounts: 显示收藏队列数量（默认关闭）
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
    _ensureCurrentSettingsLength();
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
    final hadMissingSettings = st.length < settings.length;
    for (int i = 0; i < st.length && i < settings.length; i++) {
      settings[i] = st[i].toString();
    }
    final loadedSettings = List<String>.from(settings);
    settings[readerImagePipelineSettingIndex] =
        normalizeReaderImagePipelineSettings(
      st.length > readerImagePipelineSettingIndex
          ? st[readerImagePipelineSettingIndex]
          : null,
      legacyComic: st.length > readerHighQualityComicSettingIndex
          ? st[readerHighQualityComicSettingIndex]
          : null,
      legacyIllust: st.length > readerHighQualityIllustSettingIndex
          ? st[readerHighQualityIllustSettingIndex]
          : null,
    );
    if (settings[26].length < 2) {
      settings[26] += "0";
    }
    settings[managedDataSourceModeSettingIndex] =
        normalizeManagedDataSourceMode(
            settings[managedDataSourceModeSettingIndex]);
    settings[originalDownloadDirSettingIndex] =
        settings[originalDownloadDirSettingIndex].trim();
    settings[localComicPathsSettingIndex] = encodeLocalComicPathList(
      decodeLocalComicPathList(settings[localComicPathsSettingIndex]),
    );
    settings[localLibraryCollectionShellSettingIndex] =
        encodeLocalCollectionShellPathMap(
      decodeLocalCollectionShellPathMap(
          settings[localLibraryCollectionShellSettingIndex]),
    );
    settings[localAlbumImageSortSettingIndex] =
        normalizeLocalAlbumImageSort(settings[localAlbumImageSortSettingIndex]);
    settings[localLibraryListSortSettingIndex] = normalizeLocalLibraryListSort(
        settings[localLibraryListSortSettingIndex]);
    if (settings[localLibraryAlbumOnlySettingIndex] != "0") {
      settings[localLibraryAlbumOnlySettingIndex] = "1";
    }
    settings[localDetailRecommendationSettingIndex] =
        normalizeLocalDetailRecommendationMode(
            settings[localDetailRecommendationSettingIndex]);
    settings[localLibraryShowAllDatabaseRecordsSettingIndex] =
        normalizeLocalLibraryShowAllDatabaseRecords(
            settings[localLibraryShowAllDatabaseRecordsSettingIndex]);
    settings[downloadedLibraryViewSettingIndex] =
        normalizeDownloadedLibraryView(
            settings[downloadedLibraryViewSettingIndex]);
    settings[localLibraryViewSettingIndex] =
        normalizeLocalLibraryView(settings[localLibraryViewSettingIndex]);
    settings[favoritesLibraryViewSettingIndex] =
        normalizeTwoWayLibraryView(settings[favoritesLibraryViewSettingIndex]);
    settings[imageFavoritesLibraryViewSettingIndex] =
        normalizeTwoWayLibraryView(
            settings[imageFavoritesLibraryViewSettingIndex]);
    settings[appRuntimeModeSettingIndex] =
        normalizeAppRuntimeMode(settings[appRuntimeModeSettingIndex]);
    settings[remoteServerAddressSettingIndex] =
        settings[remoteServerAddressSettingIndex].trim();
    settings[serviceDiscoveryModeSettingIndex] = normalizeServiceDiscoveryMode(
        settings[serviceDiscoveryModeSettingIndex]);
    settings[serviceDiscoveryMdnsFallbackSettingIndex] =
        normalizeServiceDiscoveryMdnsFallback(
            settings[serviceDiscoveryMdnsFallbackSettingIndex]);
    settings[serviceAdminPortSettingIndex] =
        normalizeServiceAdminPortValue(settings[serviceAdminPortSettingIndex]);
    settings[serviceScanCustomPortsSettingIndex] = encodeServiceScanCustomPorts(
      decodeServiceScanCustomPorts(
        settings[serviceScanCustomPortsSettingIndex],
      ),
    );
    settings[androidRootModeSettingIndex] =
        normalizeAndroidRootMode(settings[androidRootModeSettingIndex]);
    settings[androidShizukuModeSettingIndex] =
        normalizeAndroidShizukuMode(settings[androidShizukuModeSettingIndex]);
    settings[deleteBehaviorSettingIndex] =
        normalizeDeleteBehavior(settings[deleteBehaviorSettingIndex]);
    settings[externalToolOrderSettingIndex] = normalizeExternalToolOrderSetting(
        settings[externalToolOrderSettingIndex]);
    settings[externalToolVisibilitySettingIndex] =
        normalizeExternalToolVisibilitySetting(
            settings[externalToolVisibilitySettingIndex]);
    // Pixiv 多图打包开关（`settings[154]`）：值不是 '1' 就落回 '0'（关）——
    // 产物形态是兼容性变更，默认保持现状最安全。
    settings[pixivMultiPageZipSettingIndex] =
        normalizePixivMultiPageZip(settings[pixivMultiPageZipSettingIndex]);
    // 图集页「图集 / 插画」视图维度（settings[155..157]）。
    // 全部走归一化：这三个值是**页面级 UI 状态**，脏值会让图集页落到
    // "不认识的视图"或"0 列瀑布流"这类难排查的状态。
    settings[illustLibraryViewSettingIndex] =
        normalizeIllustLibraryView(settings[illustLibraryViewSettingIndex]);
    settings[illustWaterfallColumnsSettingIndex] =
        normalizeIllustWaterfallColumnsSetting(
            settings[illustWaterfallColumnsSettingIndex]);
    settings[illustViewSwitcherPositionSettingIndex] =
        normalizeIllustViewSwitcherPosition(
            settings[illustViewSwitcherPositionSettingIndex]);
    // 插画卡片底部信息模板（settings[158]）：空白（含未设置）回落到默认
    // `{title}\n{author}` —— 与改动前写死的"标题 + 作者"观感一致。
    settings[illustCardInfoSettingIndex] =
        normalizeIllustCardInfoTemplate(settings[illustCardInfoSettingIndex]);
    // 阅读清晰度两套开关（settings[159..160]）。归一化方向**刻意相反**：
    // 漫画缺省即关（只认 '1'），插画/图集缺省即开（只认 '0'）——
    // 直接写 `== '1'` 会让未设置落到关，与"默认打开"矛盾。
    settings[readerHighQualityComicSettingIndex] =
        normalizeReaderHighQualityComic(
            settings[readerHighQualityComicSettingIndex]);
    settings[readerHighQualityIllustSettingIndex] =
        normalizeReaderHighQualityIllust(
            settings[readerHighQualityIllustSettingIndex]);
    settings[pixivTransferPolicyIndex] =
        normalizePixivTransferPolicy(settings[pixivTransferPolicyIndex]);
    settings[pixivFolderDeletePolicyIndex] = normalizePixivFolderDeletePolicy(
        settings[pixivFolderDeletePolicyIndex]);
    // 插画搜索是否同时匹配标签（settings[163]，19 号）：只认 '1'，其余回落 '0'。
    settings[illustSearchMatchTagsSettingIndex] =
        normalizeIllustSearchMatchTags(
            settings[illustSearchMatchTagsSettingIndex]);
    settings[exploreSelectionSettingIndex] =
        normalizeExploreSelectionJson(settings[exploreSelectionSettingIndex]);
    settings[pixivBookmarkQueueCountsSettingIndex] =
        normalizePixivBookmarkQueueCounts(
            st.elementAtOrNull(pixivBookmarkQueueCountsSettingIndex));
    setManagedDataSourceMode(settings[managedDataSourceModeSettingIndex]);
    _syncArchiveRuntimeSettings();
    var settingsChanged = hadMissingSettings;
    for (var i = 0; i < settings.length; i++) {
      if (settings[i] != loadedSettings[i]) {
        settingsChanged = true;
        break;
      }
    }
    if (settingsChanged) {
      await updateSettings();
    }
  }

  void _syncArchiveRuntimeSettings() {
    ArchivePasswordStore.instance.configureFromRawSettings(
      defaultPasswordsJson: settings[archiveDefaultPasswordsSettingIndex],
      autoUnlockEnabledValue: settings[archiveAutoUnlockEnabledSettingIndex],
      persist: (defaultPasswords, autoUnlockEnabled) async {
        settings[archiveDefaultPasswordsSettingIndex] =
            ArchivePasswordStore.encodeDefaultPasswords(defaultPasswords);
        settings[archiveAutoUnlockEnabledSettingIndex] =
            autoUnlockEnabled ? '1' : '0';
        await updateSettings(false);
      },
    );
    ArchiveMemoryCache.instance.setLimitMB(
      int.tryParse(settings[archiveReadingCacheLimitMbSettingIndex]) ?? 32,
    );
  }

  Future<void> updateSettings([bool syncData = true]) async {
    // Settings may still be an old, short array when a component writes before
    // normal startup/import. Capture missing legacy facts before appending the
    // new defaults, and preserve every value already present.
    final readerPolicy =
        settings.elementAtOrNull(readerImagePipelineSettingIndex);
    final legacyComic =
        settings.elementAtOrNull(readerHighQualityComicSettingIndex);
    final legacyIllust =
        settings.elementAtOrNull(readerHighQualityIllustSettingIndex);
    _ensureCurrentSettingsLength();
    settings[pixivBookmarkQueueCountsSettingIndex] =
        normalizePixivBookmarkQueueCounts(
            settings[pixivBookmarkQueueCountsSettingIndex]);
    settings[readerImagePipelineSettingIndex] =
        normalizeReaderImagePipelineSettings(
      readerPolicy,
      legacyComic: legacyComic,
      legacyIllust: legacyIllust,
    );
    settings[serviceScanCustomPortsSettingIndex] = encodeServiceScanCustomPorts(
      decodeServiceScanCustomPorts(
          settings[serviceScanCustomPortsSettingIndex]),
    );
    _syncArchiveRuntimeSettings();
    // 落盘是尽力而为：设置本身已经写在内存的 settings 与 SharedPreferences 里，
    // 仅因 dataPath 未就绪或目录不可写就抛异常，会把"改一个开关"升级成崩溃。
    try {
      var settingsFile = File("${App.dataPath}/settings");
      await settingsFile.writeAsString(jsonEncode(settings));
    } catch (_) {}
    if (syncData) {}
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList("settings", settings);
  }

  void _ensureCurrentSettingsLength() {
    final defaults = Appdata().settings;
    if (settings.length >= defaults.length) return;
    settings = [
      ...settings,
      ...defaults.skip(settings.length),
    ];
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

  Future<bool> readEssentialData() async {
    var s = await SharedPreferences.getInstance();
    try {
      AppStartupTrace.log('appdata.readEssentialData.start');
      await readSettings(s);
      if (s.getStringList("firstUse") != null) {
        var st = s.getStringList("firstUse")!;
        for (int i = 0; i < st.length; i++) {
          firstUse[i] = st[i];
        }
      }
      AppStartupTrace.log('appdata.readEssentialData.done');
      return firstUse[3] == "1";
    } catch (e) {
      AppStartupTrace.log('appdata.readEssentialData.failed: $e');
      return false;
    }
  }

  Future<void> readDeferredData() async {
    var s = await SharedPreferences.getInstance();
    try {
      AppStartupTrace.log('appdata.readDeferredData.start');
      searchHistory = s.getStringList("search") ?? [];
      favoriteTags = (s.getStringList("favoriteTags") ?? []).toSet();
      blockingKeyword = s.getStringList("blockingKeyword") ?? [];
      readImplicitData();
      AppStartupTrace.log('appdata.readDeferredData.done');
    } catch (e) {
      AppStartupTrace.log('appdata.readDeferredData.failed: $e');
    }
  }

  Future<bool> readData() async {
    try {
      final result = await readEssentialData();
      await readDeferredData();
      return result;
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
      final rawSettings = json["settings"];
      if (rawSettings is! List) {
        return false;
      }
      final newSettings = rawSettings.map((value) => value.toString()).toList();
      final existingReaderPolicy =
          settings.elementAtOrNull(readerImagePipelineSettingIndex);
      _ensureCurrentSettingsLength();
      var downloadPath = settings[22];
      var authRequired = settings[13];
      for (var i = 0; i < settings.length && i < newSettings.length; i++) {
        settings[i] = newSettings[i];
      }
      settings[readerImagePipelineSettingIndex] =
          normalizeReaderImagePipelineSettings(
        newSettings.length > readerImagePipelineSettingIndex
            ? newSettings[readerImagePipelineSettingIndex]
            : existingReaderPolicy,
        legacyComic: newSettings.length > readerHighQualityComicSettingIndex
            ? newSettings[readerHighQualityComicSettingIndex]
            : null,
        legacyIllust: newSettings.length > readerHighQualityIllustSettingIndex
            ? newSettings[readerHighQualityIllustSettingIndex]
            : null,
      );
      settings[managedDataSourceModeSettingIndex] =
          normalizeManagedDataSourceMode(
              settings[managedDataSourceModeSettingIndex]);
      settings[originalDownloadDirSettingIndex] = downloadPath;
      settings[localComicPathsSettingIndex] = encodeLocalComicPathList(
        decodeLocalComicPathList(settings[localComicPathsSettingIndex]),
      );
      settings[localLibraryCollectionShellSettingIndex] =
          encodeLocalCollectionShellPathMap(
        decodeLocalCollectionShellPathMap(
            settings[localLibraryCollectionShellSettingIndex]),
      );
      settings[localAlbumImageSortSettingIndex] = normalizeLocalAlbumImageSort(
          settings[localAlbumImageSortSettingIndex]);
      settings[localLibraryListSortSettingIndex] =
          normalizeLocalLibraryListSort(
              settings[localLibraryListSortSettingIndex]);
      settings[localDetailRecommendationSettingIndex] =
          normalizeLocalDetailRecommendationMode(
              settings[localDetailRecommendationSettingIndex]);
      settings[localLibraryShowAllDatabaseRecordsSettingIndex] =
          normalizeLocalLibraryShowAllDatabaseRecords(
              settings[localLibraryShowAllDatabaseRecordsSettingIndex]);
      settings[downloadedLibraryViewSettingIndex] =
          normalizeDownloadedLibraryView(
              settings[downloadedLibraryViewSettingIndex]);
      settings[localLibraryViewSettingIndex] =
          normalizeLocalLibraryView(settings[localLibraryViewSettingIndex]);
      settings[serviceDiscoveryModeSettingIndex] =
          normalizeServiceDiscoveryMode(
              settings[serviceDiscoveryModeSettingIndex]);
      settings[serviceDiscoveryMdnsFallbackSettingIndex] =
          normalizeServiceDiscoveryMdnsFallback(
              settings[serviceDiscoveryMdnsFallbackSettingIndex]);
      settings[appRuntimeModeSettingIndex] =
          normalizeAppRuntimeMode(settings[appRuntimeModeSettingIndex]);
      settings[remoteServerAddressSettingIndex] =
          settings[remoteServerAddressSettingIndex].trim();
      settings[serviceAdminPortSettingIndex] = normalizeServiceAdminPortValue(
          settings[serviceAdminPortSettingIndex]);
      settings[serviceScanCustomPortsSettingIndex] =
          encodeServiceScanCustomPorts(
        decodeServiceScanCustomPorts(
          settings[serviceScanCustomPortsSettingIndex],
        ),
      );
      settings[deleteBehaviorSettingIndex] =
          normalizeDeleteBehavior(settings[deleteBehaviorSettingIndex]);
      settings[externalToolOrderSettingIndex] =
          normalizeExternalToolOrderSetting(
              settings[externalToolOrderSettingIndex]);
      settings[externalToolVisibilitySettingIndex] =
          normalizeExternalToolVisibilitySetting(
              settings[externalToolVisibilitySettingIndex]);
      // Pixiv 下载设置：目录去掉首尾空白（空串 = 跟随 settings[22]）；
      // 模板空值回落到默认 `{title}`，避免设置数组里留空白串。
      settings[pixivDownloadDirSettingIndex] =
          settings[pixivDownloadDirSettingIndex].trim();
      settings[pixivDirNameTemplateSettingIndex] =
          normalizePixivDirNameTemplate(
              settings[pixivDirNameTemplateSettingIndex]);
      settings[pixivMultiPageZipSettingIndex] =
          normalizePixivMultiPageZip(settings[pixivMultiPageZipSettingIndex]);
      settings[illustLibraryViewSettingIndex] =
          normalizeIllustLibraryView(settings[illustLibraryViewSettingIndex]);
      settings[illustWaterfallColumnsSettingIndex] =
          normalizeIllustWaterfallColumnsSetting(
              settings[illustWaterfallColumnsSettingIndex]);
      settings[illustViewSwitcherPositionSettingIndex] =
          normalizeIllustViewSwitcherPosition(
              settings[illustViewSwitcherPositionSettingIndex]);
      settings[illustCardInfoSettingIndex] =
          normalizeIllustCardInfoTemplate(settings[illustCardInfoSettingIndex]);
      settings[readerHighQualityComicSettingIndex] =
          normalizeReaderHighQualityComic(
              settings[readerHighQualityComicSettingIndex]);
      settings[readerHighQualityIllustSettingIndex] =
          normalizeReaderHighQualityIllust(
              settings[readerHighQualityIllustSettingIndex]);
      settings[pixivTransferPolicyIndex] =
          normalizePixivTransferPolicy(settings[pixivTransferPolicyIndex]);
      settings[pixivFolderDeletePolicyIndex] = normalizePixivFolderDeletePolicy(
          settings[pixivFolderDeletePolicyIndex]);
      // 与 readSettings 同一行：导入路径也必须归一化（漏一处就会出现"导入后不生效"）。
      settings[illustSearchMatchTagsSettingIndex] =
          normalizeIllustSearchMatchTags(
              settings[illustSearchMatchTagsSettingIndex]);
      settings[exploreSelectionSettingIndex] =
          normalizeExploreSelectionJson(settings[exploreSelectionSettingIndex]);
      settings[pixivBookmarkQueueCountsSettingIndex] =
          normalizePixivBookmarkQueueCounts(newSettings
              .elementAtOrNull(pixivBookmarkQueueCountsSettingIndex));
      setManagedDataSourceMode(settings[managedDataSourceModeSettingIndex]);
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

Appdata _createAppdata() {
  final data = Appdata();
  AiPromptTagSettingsController.instance.configureStorage(
    settingsProvider: () => data.settings,
    persistSettings: () => data.updateSettings(),
  );
  return data;
}

var appdata = _createAppdata();

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
  appdata = _createAppdata();
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
