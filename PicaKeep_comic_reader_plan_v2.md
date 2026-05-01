# PicaKeep 漫画阅读器开发计划 v2

## 项目目标

以 `PicaComic` 为蓝本，开发一个精简的**本地**漫画阅读器 `PicaKeep`，仅保留：**"我"页、收藏页、阅读器、本地搜索、设置、多语言、主题**。移除所有在线网络功能。

---

## 代码审查结论（原计划的关键问题）

通过审查 PicaComic 实际代码（201 个 dart 文件），原计划存在以下严重低估：

### 问题 1：阅读器不能"完整复制不改动"
`ComicReadingPage` 导入了 `comic_source/`、`network/picacg_network/`、`network/eh_network/`、`network/jm_network/`、`network/nhentai_network/` 等在线模块。它有 6 个平台特定构造函数（`.picacg()`, `.ehentai()`, `.jmComic()` 等），图片加载依赖 `ImageManager` 走网络请求。**阅读器必须修改**：保留翻页引擎，替换图片数据提供方为本地文件加载。

### 问题 2：local_favorites.dart 深度耦合在线模块
`FavoriteType.comicSource` 调用 `ComicSource.find()`，`FavoriteType.comicType` 返回 `ComicType` 枚举。导入所有在线网络模型（picacg/ehentai/jm/hitomi/htmanga/nhentai）。

### 问题 3：download.dart 依赖整个网络层
导入所有平台的 `DownloadingItem` 子类和网络模型，`generateId()` 依赖 `ComicSource`。

### 问题 4：BaseComic 的传染性
`FavoriteItem.fromBaseComic()`、History、download_page 的 `ReadComic` 扩展全部依赖 `BaseComic` 及各平台子类。

### 问题 5：settings 索引不能随意变动
`base.dart` 中 `appdata.settings` 有 90 个索引位置，直接删除中间项会破坏已有数据的读取。

---

## 修正后的实施策略

**核心原则**：
1. 从依赖树的**叶子节点**开始解耦，自底向上移植
2. 阅读器**保留引擎、改写数据入口**
3. 统一为单一 `LocalComic` 数据模型，替代分散的平台特定模型
4. settings 索引**保留位置、仅移除在线 UI**

---

## 第一阶段：项目骨架搭建

### 1.1 创建 Flutter 项目
- 在 `d:\Flutter_Projucts\PicaComic_DS\` 同级创建 `PicaKeep` 目录
- `flutter create --project-name picakeep --org lingxue PicaKeep`
- 应用名：PicaKeep，描述：本地漫画阅读器

### 1.2 配置 pubspec.yaml（最小依赖）

**保留（本地功能所需）：**
```yaml
dependencies:
  flutter:
    sdk: flutter
  shared_preferences: ^2.0.16        # 设置存储
  dynamic_color: ^1.6.9              # Material You 动态取色
  crypto: any                         # 封面缓存哈希
  photo_view:                         # 阅读器核心（图片缩放/平移）
    git:
      url: https://github.com/wgh136/photo_view
      ref: a1255d1
  url_launcher: ^6.1.8              # 打开外部链接
  path_provider: ^2.0.12            # 应用目录
  sqlite3: 2.1.0                    # 本地数据库
  sqlite3_flutter_libs: any         # SQLite Flutter 绑定
  shimmer_animation: ^2.1.0         # 骨架屏
  flutter_displaymode: 0.6.0        # 高刷新率
  flutter_reorderable_grid_view: 5.0.1  # 收藏排序拖拽
  sliver_tools: ^0.2.12             # Sliver 工具
  flutter_localizations:            # 多语言
    sdk: flutter
  intl: any
  collection: ^1.18.0
```

**移除（在线相关）：**
dio, html, flutter_inappwebview, flutter_qjs, workmanager, webdav_client, zip_flutter, local_auth, image_picker, file_selector, share_plus, window_manager, desktop_webview_window, flutter_local_notifications, pdf, cookie_jar, dio_cookie_manager, dio_http2_adapter, pointycastle, uuid, flutter_image_gallery_saver, flutter_file_dialog, app_links, mime, image

### 1.3 复制资源文件
从 PicaComic 复制：
- `assets/translation.json`, `assets/tags.json`, `assets/tags_tw.json`
- `fonts/NotoSansSC-Regular.ttf`
- `images/` 目录全部图片

---

## 第二阶段：核心基础设施（自底向上）

### 2.1 foundation/app.dart — 基本不变
- 平台判断、路径、导航器 key、UI mode
- 移除 `Webdav.uploadData()` 调用（在 `updateSettings()` 中）
- 保留 `App.dataPath`、`App.cachePath`、`navigatorKey`、`mainNavigatorKey`

### 2.2 foundation/def.dart — 基本不变
- 保留颜色数组 `colors` 等常量

### 2.3 foundation/state_controller.dart — 不变
- `StateController` 混入类，完整复制

### 2.4 foundation/log.dart — 不变
- `LogManager`，完整复制

### 2.5 foundation/app_page_route.dart — 不变
- `AppPageRoute`，完整复制

### 2.6 foundation/pair.dart, stack.dart, widget_utils.dart — 按需复制
- 作为工具类，按需复制使用到的部分

### 2.7 foundation/ui_mode.dart — 不变
- UI 响应式模式判断

---

## 第三阶段：数据层解耦与统一

### 3.1 重构 base.dart — 精简 settings（保留索引位置）

**策略**：保留全部 90 个 settings 索引位置（兼容已有数据），但：
- 移除在线相关的 `_Settings` getter/setter（如 `isComicSourceEnabled`、`jmApiDomains`、`explorePages`、`categoryPages`）
- 移除 `setNetworkProxy()` 调用
- 移除 `Webdav` 相关导入和调用
- 移除 `JmNetwork` 导入
- 移除 `notifications` 全局变量
- 移除 `clearAppdata()` 中的在线清理逻辑
- 保留 `Appdata` 类、`_Settings` 类中本地相关的 getter/setter

### 3.2 重构 foundation/local_favorites.dart — 断耦在线模块

**核心改动**：
- **删除** `FavoriteType.comicSource` getter（依赖 `ComicSource.find()`）
- **删除** `FavoriteType.comicType` getter（依赖 `ComicType` 枚举）
- **替换** `FavoriteType.name` 为本地硬编码映射表：

```dart
String get name {
  const names = {
    0: 'picacg', 1: 'ehentai', 2: 'jm',
    3: 'hitomi', 4: 'htmanga', 6: 'nhentai',
  };
  return names[key] ?? 'other';
}
```

- **删除** `FavoriteItem.fromPicacg()`, `.fromEhentai()`, `.fromJmComic()`, `.fromHitomi()`, `.fromHtcomic()`, `.fromNhentai()`, `.custom()` — 这些构造函数依赖在线模型
- **删除** `factory FavoriteItem.fromBaseComic()` — 依赖 `BaseComic`
- **删除** `toDownloadId()` 中的 `ComicSource` 分支
- **替换** `toDownloadId()` 为本地映射逻辑
- **删除** `getCover()` 中的在线加载逻辑（`ImageManager().getImage()` + cookie），改为仅支持本地 `file://` 和下载目录封面
- **删除** 所有 `import` 在线网络模型的语句
- **保留** `addComic()`, `deleteComic()`, `deleteFolder()`, `createFolder()`, `rename()`, `reorder()`, `search()`, `allComics()` 等核心 CRUD

### 3.3 重构 foundation/download_model.dart — 统一为 LocalComic

**核心改动**：
- **保留** `DownloadType` 枚举（值不变）
- **保留** `DownloadedItem` 抽象类的基础字段：`id`, `name`, `subTitle`, `eps`, `downloadedEps`, `tags`, `comicSize`, `time`, `directory`, `toJson()`
- **新增** `LocalComic` 具体类：统一表示所有已下载漫画，替代原来的平台特定子类（`DownloadedComic`, `DownloadedGallery`, `DownloadedJmComic` 等）
- **删除** 所有网络相关的 `DownloadingItem` 及其子类（`PicDownloadingItem`, `EhDownloadingItem` 等）
- **删除** `ComicType` 引用

`LocalComic` 数据结构：
```dart
class LocalComic extends DownloadedItem {
  @override final DownloadType type;
  @override final String id;
  @override final String name;
  @override final String subTitle;
  @override final List<String> eps;
  @override final List<int> downloadedEps;
  @override final List<String> tags;
  @override double? comicSize;
  @override DateTime? time;
  @override String? directory;
  
  // 额外元数据（从原始 JSON 中提取，用于详情页展示）
  final String? description;
  final String? coverPath;  // 原始封面 URL/路径
  final Map<String, dynamic> rawJson;  // 保留原始 JSON 用于兼容
  
  factory LocalComic.fromDbRow(String id, String title, String subtitle, 
      int timeMs, String directory, double size, String jsonStr) {
    final json = jsonDecode(jsonStr);
    // 统一解析逻辑，从不同平台 JSON 中提取标准化字段
  }
}
```

### 3.4 重构 foundation/download.dart — 仅保留本地查询/删除

**核心改动**：
- **保留** `DownloadManager` 单例模式
- **保留** `_DownloadDb` mixin：`_createTable()`, `_addToDb()`, `_deleteFromDb()`, `_getComicWithDb()`, `getAll()`, `isExists()`, `total`, `getDirectory()`
- **保留** 公开方法：`getAll()`, `getComicOrNull()`, `delete()`, `deleteEpisode()`, `getEpLength()`, `getComicLength()`, `getImage()`, `getCover()`, `getImageAsync()`
- **保留** `init()` — 简化为仅初始化路径和数据库（不再读取下载队列）
- **删除** `DownloadingItem` 队列相关：`downloading`, `isDownloading`, `_error`
- **删除** `_onFinish()`, `_onError()`, `_saveInfo()`, `start()`, `pause()`, `cancel()`, `moveToFirst()`
- **删除** `AddDownloadExt` 扩展（所有 `addXxxDownload()` 方法）
- **删除** `generateId()`（依赖 `ComicSource`）
- **删除** `downloadingItemFromMap()` 函数
- **删除** `Listenable` 实现（无需通知下载状态变化）
- **保留** `_getComicFromJson()` 但改为返回 `LocalComic`
- **删除** 对 `ComicSource`、所有网络模型、`DownloadedItem` 子类的 import

### 3.5 重构 foundation/history.dart — 断耦 ComicSource

**核心改动**：
- **保留** `HistoryManager` 的基本 CRUD：`init()`, `findOrCreate()`, `find()`, `addHistory()`, `clearHistory()`
- **保留** `HistoryType` 但移除 `comicSource` getter
- **保留** `History` 类字段：`title`, `subtitle`, `cover`, `ep`, `page`, `target`, `time`
- **删除** `HistoryMixin`（在线漫画模型实现它）
- **保留** `image_favorites.dart` part（图片收藏功能完全本地，不变）
- **删除** 对 `ComicSource`、`webdav`、在线模型的 import

### 3.6 保留 foundation/image_loader/ — 不变
- `base_image_provider.dart` — 保留
- `file_image_loader.dart` — 保留（本地文件加载，核心）
- `stream_image_provider.dart` — 保留（预加载流）
- `cached_image.dart` — 保留（缓存）
- `image_recombine.dart` — 保留（图片重组）
- `image_manager.dart` — **精简**：移除网络图片加载逻辑，仅保留本地文件加载

### 3.7 删除整个 foundation/js_engine.dart
- `JsEngine` 仅用于自定义图源插件系统，本地版不需要

### 3.8 删除 foundation/cache_manager.dart
- 网络缓存管理，本地版不需要。或保留最小骨架（仅图片缓存大小限制）。

---

## 第四阶段：UI 组件移植

### 4.1 components/navigation_bar.dart — 基本不变
- 完整复制，这是核心导航组件
- 依赖的 `components/components.dart`（`OverlayWidget` 等）一并复制

### 4.2 按需移植其他组件
以下组件在"我"页、收藏页、下载页、阅读器中会用到，需根据编译错误精准移植：
- `components/comic_tile.dart` — 漫画卡片（收藏/下载列表展示）
- `components/comics_list.dart` — 漫画列表
- `components/layout.dart` — 布局工具
- `components/loading.dart` — 加载动画
- `components/menu.dart` — 右键菜单
- `components/message.dart` — Toast 消息
- `components/pop_up_widget.dart` — 弹出组件
- `components/select.dart` — 多选组件
- `components/select_download_eps.dart` — 章节选择（如果保留）
- `components/custom_slider.dart` — 自定义滑块
- `components/flyout.dart` — 浮动面板（`DownloadedComicInfoView` 依赖）
- `components/button.dart` — 按钮组件
- `components/consts.dart` — 常量
- `components/scrollable_list/` — 滚动列表组件（阅读器依赖）
- `components/appbar.dart` — 自定义 AppBar
- `components/animated_image.dart` — 动画图片
- `components/avatar.dart` — 头像组件（"我"页使用）
- `components/comment.dart` — 评论组件（如果阅读器保留评论区则需）

**策略**：先不完整复制全部 components，而是在移植页面时按编译错误逐个解决，避免引入死代码。

---

## 第五阶段：页面移植（按依赖顺序）

### 5.1 设置页面 — 最先移植（依赖最少）

**保留的设置类别**（与 UI 交互的 index 不变）：

| 设置类别 | 文件 | 说明 |
|---------|------|------|
| 浏览 | `explore_settings.dart` | 仅保留本地显示项 |
| 阅读 | `reading_settings.dart` | **完整保留** |
| 外观 | 内嵌在 settings_page | **完整保留** |
| 本地收藏 | `local_favorite_settings.dart` | 基本不变 |
| APP | `app_settings.dart` | 精简 |
| 关于 | 内嵌在 settings_page | 保留 |

**explore_settings.dart 精简**：
- 保留：初始页面(23，仅"我"/"收藏")、漫画列表显示(25)、关键词屏蔽、完全隐藏(83)、侧边翻页栏(64)、漫画块显示模式(44)、漫画块大小(65)、缩略图布局(66)、显示收藏状态(72)、显示阅读位置(73)、图片收藏大小(74)、检查剪贴板(61)
- 移除：网络收藏页面(68)、探索页面(77)、分类页面(67)、默认搜索源(63)、自动添加语言筛选(69)

**移除的设置类别**：
- `comic_source_settings.dart` — 图源管理
- `network_setting.dart` — 网络设置
- `picacg_settings.dart` / `eh_settings.dart` / `jm_settings.dart` / `hi_settings.dart` / `nh_settings.dart` / `ht_settings.dart` — 各平台专用设置
- `blocking_keyword_page.dart` — 如果保留关键词屏蔽功能则保留

### 5.2 本地搜索页面 — 新建（无依赖）

新建 `pages/local_search_page.dart`：
- 搜索输入框 + 搜索建议（基于本地标签）
- 搜索范围：`LocalFavoritesManager().allComics()` + `DownloadManager().getAll()`
- 搜索字段：`name`、`author`/`subTitle`、`tags`
- 结果以网格展示，点击跳转收藏详情或本地漫画详情
- 不需要复制 `pre_search_page.dart` 或 `search_result_page.dart`

### 5.3 收藏页面 — 移植

**核心文件**：
- `pages/favorites/main_favorites_page.dart` — 精简为纯本地收藏
- `pages/favorites/local_favorites.dart` — 基本不变
- `pages/favorites/local_search_page.dart` — 不变

**改动**：
- 移除网络收藏/本地收藏切换逻辑
- 保留文件夹创建/删除/重命名/排序
- 保留漫画移动/删除
- 保留拖拽排序
- 点击漫画：改为跳转到 `LocalComicDetailPage`（而非在线漫画详情页）

**不复制**：
- `pages/favorites/network_favorite_page.dart`
- `pages/favorites/network_to_local.dart`

### 5.4 已下载页面 — 移植并改造

**文件**：`pages/download_page.dart`

**保留全部功能**：
- 列表展示（排序：时间/标题/作者/大小）
- 搜索过滤
- 长按多选模式 + 操作按钮（删除、添加到本地收藏）
- 右键/更多菜单
- `DownloadedComicInfoView` 浮动面板（章节列表、删除章节、分批阅读）
- "查看详情"按钮

**核心改造 — `ReadComic` 扩展**：
原代码通过 `comic.type` 分发到不同平台构造函数。改为统一本地阅读入口：

```dart
extension ReadComic on DownloadedItem {
  void read({int? ep}) async {
    final history = await HistoryManager().findOrCreateByDownloadId(id);
    App.globalTo(() => ComicReadingPage.local(
      id: id,
      title: name,
      ep: ep ?? history?.ep ?? 0,
      initialPage: history?.page ?? 0,
    ));
  }
}
```

**核心改造 — `_toComicInfoPage()` 方法**：
原来按类型分发到 `PicacgComicPage`/`EhGalleryPage`/`JmComicPage` 等在线详情页。
改为统一导航到 `LocalComicDetailPage`，传入 `DownloadedItem` 数据。

### 5.5 本地漫画详情页 — 新建

新建 `pages/local_comic_detail_page.dart`：
- **漫画信息区**：封面 + 标题 + 作者 + 来源标签 + 文件大小 + 下载时间
- **标签区**：彩色标签卡片
- **章节区**：网格布局，已下载章节高亮可点击
- **简介区**：纯文本描述
- **操作按钮**：继续阅读 | 从头开始 | 删除下载

数据来源：从 `DownloadedItem` 字段和 `toJson()` 的原始 JSON 中提取。

### 5.6 "我"页面 — 移植并精简

**文件**：`pages/me_page.dart`

**改动**：
- 移除 `buildAccount()` 方法（账号管理模块）
- 移除 `accounts_page.dart` import
- 保留：历史记录、已下载、图片收藏、工具 四个模块
- 保留双列/单列响应式布局
- 移除 `ComicSource` import

### 5.7 历史记录页面 — 基本不变
`pages/history_page.dart` — 保留。移除对在线详情页的导航，改为本地详情页/阅读器。

### 5.8 图片收藏页面 — 不变
`pages/image_favorites.dart` — 完整保留（纯本地功能）。

### 5.9 工具页面 — 精简
`pages/tools.dart` — 移除在线工具（如代理测试等），保留本地工具。

---

## 第六阶段：阅读器适配（关键阶段）

### 6.1 阅读器文件清单（全部移植但需修改）

```
pages/reader/
├── comic_reading_page.dart  ← 主文件，需大量修改
├── eps_view.dart            ← 章节选择视图，需适配
├── image_view.dart          ← 图片展示视图，基本不变
├── image.dart               ← 图片加载逻辑，需修改数据源
├── touch_control.dart       ← 触控逻辑，不变
├── reading_logic.dart       ← 阅读逻辑（翻页/模式），基本不变
├── tool_bar.dart            ← 工具栏，基本不变
├── reading_type.dart        ← 阅读模式枚举，不变
├── reading_settings.dart    ← 阅读设置页面，完整保留
└── reading_data.dart        ← 阅读数据模型，需改造
```

### 6.2 comic_reading_page.dart 改造方案

**删除**：
- 所有在线平台的命名构造函数（`.picacg()`, `.ehentai()`, `.jmComic()`, `.hitomi()`, `.htmanga()`, `.nhentai()`）
- 所有在线网络相关的 import
- `ComicSource` 依赖
- 评论页面引用（`jm_comments_page.dart`）

**新增**：
- 单一 `ComicReadingPage.local()` 构造函数，参数为 `id`（下载 ID）、`title`、`ep`、`initialPage`
- 所有图片通过 `DownloadManager().getImage(id, ep, index)` 获取本地文件
- 封面通过 `DownloadManager().getCover(id)` 获取

### 6.3 reading_data.dart 改造

**原 ReadingData** 持有平台特定数据（`ComicItem`, `Gallery`, `JmComicInfo` 等）。
**改为** 持有通用本地漫画数据：
- `id` — 下载 ID
- `title` — 标题
- `eps` — 章节列表
- `ep` — 当前章节
- `type` — 阅读模式（不变）

### 6.4 image.dart 改造

图片提供方从 `ImageManager`（网络+本地）切换为纯本地 `DownloadManager().getImage()`：
- 删除在线图片加载的 `ImageProvider` 分支
- 保留本地文件的 `FileImage` 加载路径
- 取消对 `ImageManager` 的 import

### 6.5 保留不变的部分
- `touch_control.dart` — 触控/手势逻辑
- `reading_logic.dart` — 翻页/模式切换逻辑
- `tool_bar.dart` — 工具栏 UI
- `reading_type.dart` — 阅读模式枚举
- `reading_settings.dart` — 设置页面（完整保留）
- `eps_view.dart` — 章节选择（只需数据源改为 `DownloadedItem.eps`）

---

## 第七阶段：主入口与主页面

### 7.1 main_page.dart — 精简为 2 Tab

**改动**：
- 底部导航从 4 Tab 减为 2 Tab：**"我"**、**"收藏"**
- 侧边栏 Actions 保留 2 个：**搜索**（→ `LocalSearchPage`）、**设置**（→ `SettingsPage`）
- 移除 `ExplorePage`、`AllCategoryPage`
- 移除 `_login()` 方法（哔咔登录/签到）
- 移除 `_checkUpdates()` 中的在线更新检查
- 移除 `_checkDownload()` 中的下载队列恢复
- 保留 `checkClipboard()` 但改为调用本地版剪贴板检测
- 移除 `_pages` 中的探索和分类页

### 7.2 main.dart — 入口精简

**改动**：
- 移除 `window_manager`、`desktop_webview_window`、`block_screenshot`、`webdav`、`auth_page`、`welcome_page` 等 import
- `main()` 简化为：
  ```dart
  void main() {
    runZonedGuarded(() async {
      WidgetsFlutterBinding.ensureInitialized();
      await init();
      runApp(const MyApp());
    }, (error, stack) { ... });
  }
  ```
- `MyApp` 直接显示 `MainPage`（移除 `WelcomePage`、`AuthPage` 分发逻辑）
- 保留 `DynamicColorBuilder`、主题系统、高刷新率
- 移除桌面窗口管理相关代码
- 移除生命周期中的代理设置、认证锁定逻辑

### 7.3 init.dart — 初始化精简

**保留的初始化**：
- `App.init()` — 应用路径初始化
- `appdata.readData()` — 设置读取
- `downloadManager.init()` — 下载数据库初始化
- `LocalFavoritesManager().init()` — 收藏数据库初始化
- `HistoryManager().init()` — 历史记录初始化
- `AppTranslation.init()` — 翻译初始化
- `TagsTranslation.readData()` — 标签翻译

**删除的初始化**：
- `JsEngine().init()` — JS 引擎
- `ComicSource.init()` — 图源插件系统
- `JmNetwork().init()` — 禁漫网络
- `NhentaiNetwork().init()` — NHentai 网络
- `HttpProxyServer` — HTTP 代理
- `SingleInstanceCookieJar` — Cookie 存储
- `AppLinks` — 应用链接（改为本地剪贴板检测）
- `Workmanager` — 后台任务
- `_checkOldData()` — 账号数据迁移逻辑
- `CacheManager` 相关 — 网络缓存管理
- `checkDownloadPath()` — 如果路径配置保留则保留

---

## 第八阶段：工具模块移植

### 8.1 完整保留的工具
- `tools/translations.dart` — 多语言支持（不变）
- `tools/tags_translation.dart` — 标签翻译（不变）
- `tools/io_tools.dart` — IO 工具（不变）
- `tools/io_extensions.dart` — IO 扩展（不变）
- `tools/extensions.dart` — 通用扩展（保留，移除网络相关扩展）
- `tools/time.dart` — 时间工具（不变）
- `tools/keep_screen_on.dart` — 屏幕常亮（不变）
- `tools/key_down_event.dart` — 键盘事件（桌面端可选保留）
- `tools/mouse_listener.dart` — 鼠标侧键（桌面端可选保留）
- `tools/file_type.dart` — 文件类型检测（保留）

### 8.2 改造的工具
- `tools/app_links.dart` → `tools/local_app_links.dart`：
  - 保留 `isURL()`、链接解析逻辑
  - 移除在线漫画页面跳转，改为搜索本地数据库
  - 找到 → 跳转本地详情页；未找到 → 提示

### 8.3 删除的工具
- `tools/background_service.dart` — 后台下载服务
- `tools/block_screenshot.dart` — 截图阻止
- `tools/cache_auto_clear.dart` — 缓存自动清理
- `tools/debug.dart` — 调试工具
- `tools/js.dart` — JS 引擎工具
- `tools/notification.dart` — 通知
- `tools/pdf.dart` — PDF 导出
- `tools/save_image.dart` — 保存图片到相册

---

## 第九阶段：剪贴板检测（本地版）

### 9.1 local_app_links.dart

改造原 `tools/app_links.dart`：

**支持的链接识别**（在本地数据库中搜索）：

| 链接模式 | 提取的 ID | 搜索方式 |
|---------|----------|---------|
| `picacomic.com` | URL path 中的 MongoDB ID | `DownloadManager().getComicOrNull(id)` |
| `e-hentai.org/g/{gid}` | 纯数字 GID | `DownloadManager().getComicOrNull(gid.toString())` |
| `nhentai.net/g/{id}` | 数字 ID | `DownloadManager().getComicOrNull("nhentai$id")` |
| `jmcomic` 相关 | 数字 ID | `DownloadManager().getComicOrNull("jm$id")` |
| `hitomi.la` | 数字 ID | `DownloadManager().getComicOrNull("hitomi$id")` |

同时搜索本地收藏数据库 `LocalFavoritesManager().find(target, type)`。

---

## 第十阶段：删除与清理

### 10.1 不复制（删除）的整个目录
```
comic_source/          # 图源插件系统
network/               # 除 download.dart 和 download_model.dart 外的全部
pages/picacg/          # 哔咔专用页面
pages/ehentai/         # E-Hentai 专用页面
pages/jm/              # 禁漫专用页面
pages/hitomi/          # Hitomi 专用页面
pages/htmanga/         # 绅士漫画专用页面
pages/nhentai/         # NHentai 专用页面
```

### 10.2 不复制（删除）的独立文件
```
lib/init.dart          # → 重写精简版
lib/main.dart          # → 重写精简版
lib/base.dart          # → 重写精简版
lib/pages/welcome_page.dart
lib/pages/auth_page.dart
lib/pages/accounts_page.dart
lib/pages/explore_page.dart
lib/pages/category_page.dart
lib/pages/category_comics_page.dart
lib/pages/comic_page.dart
lib/pages/pre_search_page.dart
lib/pages/search_result_page.dart
lib/pages/ranking_page.dart
lib/pages/downloading_page.dart
lib/pages/webview.dart
lib/pages/show_image_page.dart
lib/pages/logs_page.dart
lib/pages/favorites/network_favorite_page.dart
lib/pages/favorites/network_to_local.dart
lib/pages/settings/comic_source_settings.dart
lib/pages/settings/network_setting.dart
lib/pages/settings/picacg_settings.dart
lib/pages/settings/eh_settings.dart
lib/pages/settings/jm_settings.dart
lib/pages/settings/hi_settings.dart
lib/pages/settings/nh_settings.dart
lib/pages/settings/ht_settings.dart
lib/pages/settings/multi_pages_filter.dart
lib/pages/settings/components.dart
lib/network/download_model.dart  # → 移到 foundation/ 并重写
lib/network/download.dart        # → 移到 foundation/ 并重写
lib/foundation/cache_manager.dart
lib/foundation/js_engine.dart
```

### 10.3 保留 foundation/image_loader/
所有文件保留，但 `image_manager.dart` 需删除网络加载路径。

---

## 第十一阶段：编译与验证

### 11.1 验证步骤
1. `flutter pub get`
2. 逐个文件解决编译错误（import 缺失、类型不匹配等）
3. `flutter analyze` 确保零错误
4. `flutter build apk --debug` 验证 Android 构建
5. 功能验证清单：

- [ ] 应用启动直接进入 MainPage（2 Tab）
- [ ] "我" Tab：历史记录、已下载、图片收藏、工具 可用
- [ ] 已下载列表：展示、排序、搜索、长按多选、删除、`DownloadedComicInfoView`
- [ ] 本地漫画详情页：标题/作者/来源/标签/简介/章节 正确展示
- [ ] "收藏" Tab：文件夹管理、漫画增删改查、拖拽排序
- [ ] 收藏内搜索正常
- [ ] 全局搜索（侧边栏）能搜到收藏+已下载
- [ ] 漫画阅读器：翻页、缩放、模式切换、屏幕方向
- [ ] 阅读设置完整保留（所有选项可用）
- [ ] 设置页面：浏览/阅读/外观/收藏/APP/关于
- [ ] 多语言切换
- [ ] 主题切换（动态取色/深色/纯黑）
- [ ] 剪贴板检测弹窗（如有配置）
- [ ] 导航栏响应式切换（手机/平板/桌面）

---

## 实施顺序建议

按以下顺序执行，每个阶段完成后 `flutter analyze` 验证：

1. **第一阶段**：项目创建 + pubspec.yaml + 资源复制
2. **第二阶段**：foundation/ 基础设施（app.dart, def.dart, state_controller, log.dart, app_page_route, ui_mode）
3. **第三阶段**：数据层（base.dart → local_favorites.dart → download_model.dart → download.dart → history.dart → image_loader/）
4. **第四阶段**：UI 组件（按需移植，与第五阶段交叉进行）
5. **第五阶段**：设置页面 → 本地搜索页 → 收藏页 → 下载页 → 详情页 → 我页 → 历史页
6. **第六阶段**：阅读器适配（最复杂的改造）
7. **第七阶段**：main.dart + init.dart + main_page.dart（最终组装）
8. **第八阶段**：工具模块 + 剪贴板检测
9. **第九阶段**：清理 + 验证

---

## 风险点与缓解措施

| 风险 | 缓解 |
|------|------|
| 阅读器深度耦合在线模块，改造可能引入 bug | 先做最小改动（仅替换数据源），保留原有翻页/缩放引擎不变。充分测试 |
| settings 索引错位导致已有数据损坏 | **不改变索引位置**，仅移除 UI 入口和 setter。旧数据可正常读取 |
| 组件依赖链过长，移植遗漏 | 以编译错误为驱动，`flutter analyze` 每步验证。先不完整复制 components，按需逐个移植 |
| `DownloadedItem` 多态体系替换为 `LocalComic` 后的兼容性 | 保留 `toJson()` 的原始 JSON，`LocalComic` 作为统一包装器，兼容所有平台的数据格式 |
| 收藏页点击漫画后的导航目标改变 | `FavoriteItem.toDownloadId()` 已生成下载 ID，直接用此 ID 查 `DownloadManager` 判断是否已下载，以此决定导航到详情页还是仅展示收藏信息 |