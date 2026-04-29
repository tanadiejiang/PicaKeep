# PicaKeep 本地漫画阅读器 Spec

## Why

以 PicaComic 为蓝本，构建一个纯本地的漫画阅读器 PicaKeep。去除所有在线网络功能（图源插件系统、网络请求层、在线账户管理等），仅保留"我"页、"收藏"页、漫画阅读器、本地搜索、设置、多语言、主题定制等核心本地功能。

## What Changes

- 新建 Flutter 项目 PicaKeep（包名 `lingxue.picakeep`）
- 从 PicaComic 选择性移植：核心架构、我页、收藏页、阅读器、设置页、多语言/主题
- 新增：本地搜索页面、本地漫画详情页、本地化剪贴板链接检测
- 移除：全部在线网络层（network/）、图源系统（comic_source/）、在线探索/分类/搜索/账号页面、各图源专用页面、网络设置/漫画源设置
- **BREAKING**: 无（新项目，无向后兼容需求）

## Impact

- Affected specs: 无（新项目）
- Affected code: `d:\Flutter_Projucts\PicaComic\PicaKeep` 全新构建

---

## ADDED Requirements

### Requirement: 项目初始化
系统 SHALL 创建包名为 `lingxue.picakeep`、应用名为 `PicaKeep` 的 Flutter 项目，仅包含本地功能所需的依赖。

#### Scenario: 项目创建成功
- **WHEN** 执行 `flutter create` 并配置 pubspec.yaml
- **THEN** `flutter pub get` 成功，项目可被 IDE 识别

#### Scenario: 依赖精简
- **WHEN** 检查 pubspec.yaml
- **THEN** 包含 shared_preferences、sqlite3、path_provider、crypto、dynamic_color、shimmer_animation、url_launcher、flutter_displaymode、photo_view、sliver_tools、flutter_reorderable_grid_view
- **THEN** 不包含 dio、html、flutter_inappwebview、flutter_qjs、workmanager、webdav_client 等在线依赖

---

### Requirement: 应用入口与核心架构
系统 SHALL 提供精简的 main.dart，直接路由到 MainPage，不经过 WelcomePage/AuthPage。

#### Scenario: 冷启动
- **WHEN** 用户打开应用
- **THEN** 初始化 SharedPreferences、SQLite 数据库
- **THEN** 直接进入 MainPage 显示 2 个 Tab（"我" + "收藏"）

#### Scenario: main() 函数
- **WHEN** 检查 main.dart 代码
- **THEN** 无网络初始化、代理设置、在线认证逻辑
- **THEN** 保留 Flutter 绑定初始化、生命周期管理

---

### Requirement: 主页面 (MainPage)
系统 SHALL 使用 NaviPane 组件展示 2 个 Tab 和 2 个侧边栏 Action。

#### Scenario: Tab 导航
- **WHEN** 用户在底部导航栏点击
- **THEN** 可在"我"和"收藏"之间切换
- **THEN** 不存在"探索"和"分类" Tab

#### Scenario: 侧边栏 Actions
- **WHEN** 用户点击侧边栏按钮
- **THEN** 搜索按钮打开本地搜索页面 `LocalSearchPage`
- **THEN** 设置按钮打开设置页面 `SettingsPage`

#### Scenario: 响应式布局
- **WHEN** 屏幕宽度变化
- **THEN** <600px 显示底部导航栏
- **THEN** 600~1400px 显示折叠侧栏
- **THEN** >1400px 显示展开侧栏

---

### Requirement: "我"页面 (MePage)
系统 SHALL 保留历史记录、已下载、图片收藏、工具四个模块，移除账号管理模块。

#### Scenario: "我"页面布局
- **WHEN** 用户切换到"我" Tab
- **THEN** 显示历史记录卡片（最近阅读的漫画封面横向列表）
- **THEN** 显示已下载卡片（已下载漫画总数）
- **THEN** 显示图片收藏卡片（图片收藏数量）
- **THEN** 显示工具卡片
- **THEN** 不存在账号管理模块

#### Scenario: 历史记录入口
- **WHEN** 用户点击历史记录卡片
- **THEN** 导航到 `HistoryPage`

#### Scenario: 已下载入口
- **WHEN** 用户点击已下载卡片
- **THEN** 导航到 `DownloadPage`

---

### Requirement: "收藏"页面 (FavoritesPage)
系统 SHALL 仅显示本地收藏文件夹，移除网络收藏切换。

#### Scenario: 收藏页面布局
- **WHEN** 用户切换到"收藏" Tab
- **THEN** 显示本地收藏文件夹列表
- **THEN** 不存在"网络收藏"和"本地收藏"切换
- **THEN** 顶部显示当前文件夹名

#### Scenario: 文件夹管理
- **WHEN** 用户操作文件夹
- **THEN** 支持创建、删除、重命名、排序文件夹

#### Scenario: 收藏内容展示
- **WHEN** 用户点击某个文件夹
- **THEN** 以网格展示该文件夹内漫画（LocalFavoriteTile）
- **THEN** 支持漫画的移动、删除操作

#### Scenario: 收藏内搜索
- **WHEN** 用户在收藏页触发搜索
- **THEN** 在 `local_search_page.dart`（收藏内）中按名称/作者/标签搜索

---

### Requirement: 下载页面 (DownloadPage)
系统 SHALL 完整保留原下载页面的全部功能，将详情跳转改为本地详情页。

#### Scenario: 下载列表展示
- **WHEN** 用户进入下载页面
- **THEN** 以列表展示所有已下载漫画
- **THEN** 支持排序（按时间/标题/作者/大小）

#### Scenario: 搜索过滤
- **WHEN** 用户在下载页输入关键词
- **THEN** 实时过滤匹配的漫画

#### Scenario: 长按多选
- **WHEN** 用户长按某个漫画
- **THEN** 进入多选模式，该项被选中
- **THEN** 显示删除/添加到收藏等批量操作按钮

#### Scenario: 右键更多菜单
- **WHEN** 用户在桌面端右键漫画
- **THEN** 弹出菜单：阅读、删除、导出、查看详情、复制路径

#### Scenario: 单击浮动面板
- **WHEN** 用户单击漫画
- **THEN** 弹出 `DownloadedComicInfoView` 面板
- **THEN** 显示章节列表（已下载绿色高亮）
- **THEN** 可点击特定章节阅读、长按删除章节
- **THEN** 底部显示"查看详情"和"阅读"按钮

#### Scenario: 查看详情跳转
- **WHEN** 用户点击"查看详情"
- **THEN** 导航到 `LocalComicDetailPage`（不再是各图源专用页面）

---

### Requirement: 本地漫画详情页 (LocalComicDetailPage) - 新建
系统 SHALL 提供本地漫画详情页，参考原 `BaseComicPage` 布局，数据全部来自本地。

#### Scenario: 详情页布局
- **WHEN** 用户进入本地漫画详情页
- **THEN** 显示漫画信息区：本地封面 + 标题 + 作者 + 来源标签 + 文件大小 + 下载时间
- **THEN** 显示标签区：不同颜色卡片展示标签（来自 `DownloadedItem.tags`）
- **THEN** 显示章节区：网格按钮，已下载章节高亮
- **THEN** 显示简介区：纯文本描述（来自 JSON 的 `description` 字段）

#### Scenario: 操作按钮
- **WHEN** 查看操作按钮区
- **THEN** 有"继续阅读"（有历史时）和"从头开始"按钮
- **THEN** 有"删除下载"按钮

#### Scenario: 章节阅读
- **WHEN** 用户点击某个已下载章节
- **THEN** 打开阅读器，从该章节开始阅读

#### Scenario: 数据映射
- **WHEN** 展示数据
- **THEN** 标题来自 `DownloadedItem.name`
- **THEN** 作者来自 `DownloadedItem.subTitle`
- **THEN** 封面来自 `DownloadManager.getCover(id)` 本地文件
- **THEN** 来源来自 `DownloadedItem.type` → 名称映射
- **THEN** 标签来自 `DownloadedItem.tags`
- **THEN** 章节来自 `DownloadedItem.eps` + `downloadedEps`
- **THEN** 文件大小来自 `DownloadedItem.comicSize`
- **THEN** 下载时间来自 `DownloadedItem.time`

---

### Requirement: 本地搜索页面 (LocalSearchPage) - 新建
系统 SHALL 提供全局本地搜索，搜索范围覆盖所有本地收藏和已下载漫画。

#### Scenario: 搜索输入
- **WHEN** 用户点击顶部搜索按钮
- **THEN** 进入 `LocalSearchPage`
- **THEN** 显示搜索输入框（参考原 PreSearchPage）
- **THEN** 无图源选择器和在线搜索选项

#### Scenario: 执行搜索
- **WHEN** 用户输入关键词并确认
- **THEN** 在所有收藏文件夹 + 已下载漫画中搜索
- **THEN** 匹配漫画名 `name`、作者 `author`/`subTitle`、标签 `tags`
- **THEN** 结果以网格/列表展示

#### Scenario: 搜索建议
- **WHEN** 用户开始输入
- **THEN** 基于本地已有标签提供搜索建议

---

### Requirement: 设置页面 (SettingsPage)
系统 SHALL 保留 6 个设置类别（浏览/阅读/外观/本地收藏/APP/关于），移除漫画源和网络设置。

#### Scenario: 设置页面入口
- **WHEN** 用户点击侧边栏或 AppBar 的设置按钮
- **THEN** 打开设置页面，左侧分类列表，右侧内容

#### Scenario: 保留的设置类别
- **WHEN** 查看设置分类
- **THEN** 包含：浏览（仅本地显示）、阅读（完整）、外观（完整）、本地收藏（完整）、APP、关于（完整）
- **THEN** 不包含：漫画源、网络

#### Scenario: 浏览设置精简
- **WHEN** 用户进入浏览设置
- **THEN** 保留：初始页面（仅"我""收藏"）、漫画列表显示方式、关键词屏蔽、隐藏屏蔽作品、侧边翻页栏、漫画块显示模式/大小/缩略图布局、显示收藏状态、显示阅读位置、图片收藏大小、检查剪切板链接
- **THEN** 移除：网络收藏页面、探索页面、分类页面、默认搜索源、自动添加语言筛选

#### Scenario: 阅读设置完整
- **WHEN** 用户进入阅读设置
- **THEN** 包含：阅读模式、点按翻页、反转翻页、音量键翻页、自动翻页间隔、宽屏控制按钮、保持屏幕常亮、降低图片亮度、固定屏幕方向、图片预加载、双击缩放、长按缩放、显示页面信息、深色背景

---

### Requirement: 剪贴板链接检测（本地化改造）
系统 SHALL 检测剪切板链接并在本地数据库中搜索匹配的漫画。

#### Scenario: 找到匹配
- **WHEN** 剪切板有链接（picacomic/e-hentai/nhentai/jmcomic/hitomi）
- **AND** 从链接提取的 ID 在本地下载/收藏数据库中存在
- **THEN** 弹出"在本地找到：[漫画名]"，点击确定跳转到本地详情页/阅读页

#### Scenario: 未找到匹配
- **WHEN** 剪切板有链接
- **AND** 从链接提取的 ID 在本地数据库中不存在
- **THEN** 弹出"本地未找到匹配的漫画"

#### Scenario: 无链接
- **WHEN** 剪切板无链接或不是支持的域名
- **THEN** 不做任何反应

---

### Requirement: 漫画阅读器
系统 SHALL 完整保留 PicaComic 的阅读器功能，代码不做改动。

#### Scenario: 阅读模式
- **WHEN** 用户进入阅读器
- **THEN** 支持 6 种模式：从左至右、从右至左、从上至下、从上至下(连续)、双页、双页(反向)

#### Scenario: 翻页方式
- **WHEN** 用户阅读漫画
- **THEN** 支持点按翻页（可反转）
- **THEN** 支持音量键翻页（Android）
- **THEN** 支持自动翻页（间隔可配置 1-20s）

#### Scenario: 缩放
- **WHEN** 用户查看图片
- **THEN** 支持双击缩放
- **THEN** 支持长按缩放

#### Scenario: 其他功能
- **WHEN** 阅读中
- **THEN** 图片预加载 0-15 张可配置
- **THEN** 支持屏幕方向锁定
- **THEN** 显示页面信息
- **THEN** 深色模式下降图片亮度
- **THEN** 宽屏时显示控制按钮
- **THEN** 保持屏幕常亮（Android）

#### Scenario: 图片加载改造
- **WHEN** 阅读器需要加载图片
- **THEN** 通过 `DownloadManager.getImage(id, ep, index)` 获取本地文件
- **THEN** 封面通过 `DownloadManager.getCover(id)` 获取

---

### Requirement: 数据模型
系统 SHALL 保留 FavoriteItem、FavoriteType、DownloadedItem、DownloadType、DownloadManager 等核心模型，移除所有在线模型。

#### Scenario: FavoriteType 精简
- **WHEN** 检查 FavoriteType 类
- **THEN** 保留 key 值和名称标识
- **THEN** 移除 comicSource getter（依赖在线图源系统）
- **THEN** 移除 comicType getter（依赖 ComicType 枚举）
- **THEN** 使用本地 key→名称映射表

#### Scenario: DownloadedItem 保留
- **WHEN** 检查 DownloadedItem 及其子类
- **THEN** 保留所有数据字段（name/id/subTitle/tags/eps/downloadedEps/comicSize/time/directory）
- **THEN** 移除网络请求相关方法

#### Scenario: DownloadType 扩展
- **WHEN** 检查 DownloadType 枚举
- **THEN** 保留 picacg/ehentai/jm/hitomi/htmanga/nhentai/other/favorite
- **THEN** 扩展 copy_manga、Komiic

#### Scenario: DownloadManager 精简
- **WHEN** 检查 DownloadManager
- **THEN** 保留 getAll/getComicOrNull/isExists/getCover/getImage/delete/deleteEpisode/generateId
- **THEN** 移除所有网络下载方法（addPicDownload/addEhDownload 等）
- **THEN** 移除 DownloadingItem 下载队列

#### Scenario: 移除的模型
- **WHEN** 检查代码库
- **THEN** 不存在 BaseComic/CustomComic/Profile/ComicItemBrief/EhGalleryBrief/JmComicBrief 等在线模型
- **THEN** 不存在 ComicSource 插件系统
- **THEN** 不存在 Res<T> 网络响应封装
- **THEN** 不存在 FavoriteData 网络收藏加载器

---

### Requirement: 多语言支持
系统 SHALL 完整保留原有的多语言支持。

#### Scenario: 语言切换
- **WHEN** 用户在设置中切换语言
- **THEN** 所有界面文案更新为对应语言
- **THEN** translations.dart/tags_translation.dart 正常工作

#### Scenario: 资源文件
- **WHEN** 检查 assets 目录
- **THEN** 包含 translation.json、tags.json、tags_tw.json

---

### Requirement: 主题定制
系统 SHALL 完整保留原有的主题定制功能。

#### Scenario: 主题切换
- **WHEN** 用户在设置中切换主题
- **THEN** 支持 Material You 动态取色、深色模式、纯黑模式
- **THEN** 支持高刷新率

---

### Requirement: 数据库存储
系统 SHALL 保留 SQLite 数据库结构和文件目录。

#### Scenario: 收藏数据库
- **WHEN** 应用使用收藏功能
- **THEN** SQLite 数据库 `local_favorite.db` 结构不变
- **THEN** 封面缓存 `favoritesCover/` 目录不变

#### Scenario: 下载数据库
- **WHEN** 应用使用下载功能
- **THEN** SQLite 数据库 `download.db` 结构不变（id, title, subtitle, time, directory, size, json）
- **THEN** 下载文件目录 `download/` 结构不变

---

### Requirement: 编译与验证
系统 SHALL 能成功编译并在 Windows 上运行。

#### Scenario: 编译通过
- **WHEN** 执行 `flutter pub get` 和 `flutter analyze`
- **THEN** 无编译错误
- **THEN** `flutter build windows` 成功

#### Scenario: 无死代码引用
- **WHEN** 代码审查
- **THEN** 无对 network/（除 download.dart/download_model.dart）、comic_source/ 的引用
- **THEN** 无对已移除页面的引用
