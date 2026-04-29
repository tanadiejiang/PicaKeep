# PicaKeep 漫画阅读器开发计划

## 项目目标

以 `PicaComic` 为蓝本，开发一个精简的**本地**漫画阅读器 `PicaKeep`，**仅保留以下功能**：
- **"我" 页面** — 完整保留
- **"收藏" 页面** — 完整保留（仅本地收藏，去除所有在线网络收藏）
- **漫画阅读器** — 完整保留原有的阅读器功能（**不做任何改动，包括阅读设置，和原来一模一样**）
- **顶部搜索** — 改为**仅本地漫画搜索**，不依赖在线搜索
- **设置页面** — 保留（移除与在线网络相关的设置项）
- **多语言支持** — 和原来一样
- **主题定制** — 和原来一样

**去除所有在线网络功能**：移除所有漫画图源（哔咔/EHentai/JM/Hitomi 等）的在线请求层、在线账户管理、网络收藏同步等。

---

## 第一步：项目初始化

### 1.1 创建 Flutter 项目
- 在 `d:\Flutter_Projucts\PicaComic\PicaKeep` 中创建新的 Flutter 项目
- **应用名**：`PicaKeep`
- **项目名**：`picakeep`
- **包名**：`lingxue.picakeep`
- **描述**：本地漫画阅读器 / 收藏管理器
- 其他 Flutter 项目元信息参考 PicaComic

### 1.2 配置 pubspec.yaml
从 PicaComic 的 `pubspec.yaml` 中**仅提取本地功能所需依赖**：

**保留的依赖：**
- `flutter` SDK
- `shared_preferences` — 设置存储
- `sqlite3` + `sqlite3_flutter_libs` — 本地收藏数据库 + 下载数据库
- `path_provider` — 应用目录
- `crypto` — 文件哈希（封面缓存）
- `dynamic_color` — Material You 动态取色
- `shimmer_animation` — 骨架屏加载动画
- `url_launcher` — 打开外部链接（关于页等）
- `flutter_displaymode` — 高刷新率支持
- `photo_view` (git) — 图片查看器（阅读器核心依赖）
- `sliver_tools` — Sliver 工具
- `flutter_reorderable_grid_view` — 拖拽排序网格（收藏排序）

**移除的依赖（在线相关）：**
- `dio` — HTTP 客户端
- `html` — HTML 解析
- `flutter_inappwebview` — WebView
- `flutter_qjs` — JS 引擎（自定义图源）
- `workmanager` — 后台任务
- `webdav_client` — 云同步
- `zip_flutter` — ZIP 解压
- `local_auth` — 生物认证
- `image_picker` — 图片选择
- `file_selector` — 文件选择
- `share_plus` — 分享功能
- `window_manager` — 桌面窗口管理
- `desktop_webview_window` — 桌面 WebView
- `flutter_local_notifications` — 本地通知
- `pdf` — PDF 支持
- 所有图源相关的 git 引用

### 1.3 复制资源文件
从 PicaComic 复制必要的资源：
- `assets/translation.json` / `assets/tags.json` / `assets/tags_tw.json` — 翻译与标签数据
- 应用图标相关图片
- 任何本地功能需要的静态资源

---

## 第二步：搭建核心架构

### 2.1 main.dart 入口重构
- 简化 `main()` 函数，移除所有网络初始化、代理设置、在线认证相关逻辑
- 保留基本的 Flutter 绑定初始化、SharedPreferences 初始化、本地数据库初始化
- 路由直接指向 `MainPage`，移除 `WelcomePage` 和 `AuthPage`（简化首次使用逻辑为本地判断）
- 保留生命周期管理基础部分

### 2.2 全局基础模块精简
- **`base.dart`**: 仅保留本地应用数据（`appdata`），移除网络相关全局变量
- **`foundation/app.dart`**: 保留导航器 `navigatorKey`、`mainNavigatorKey`，保留 `AppPageRoute`
- **`foundation/state_controller.dart`**: 完整保留状态管理基类

### 2.3 主页面 MainPage 重构
- 底部导航栏 `NaviPane` 精简为 **2 个 Tab**：
  - Tab 0: "我" (`MePage`)
  - Tab 1: "收藏" (`FavoritesPage`)
- 侧边栏 Actions 保留 **2 个**：
  - 搜索 (`LocalSearchPage`) — 改为本地漫画搜索
  - 设置 (`SettingsPage`)
- 移除 "探索" 和 "分类" Tab

### 2.4 导航栏组件 NaviPane
- 从 PicaComic 完整复制 `components/navigation_bar.dart`
- 保持响应式布局能力（底部栏 / 折叠侧栏 / 展开侧栏）

---

## 第三步：移植"我"页面 (MePage)

### 3.1 核心页面
- 复制 `pages/me_page.dart`，保持原有布局结构
- 保留的模块：
  - **历史记录** — 本地阅读历史
  - **已下载** — 本地下载的漫画（详见第五步）
  - **图片收藏** — 本地图片收藏
  - **工具** — 本地工具（移除在线相关工具）
- 移除的模块：
  - **账号管理** — 移除所有在线图源账号登录功能

### 3.2 依赖模块移植
- `foundation/history.dart` — 历史记录管理（完整保留）
- `foundation/local_favorites.dart` — 本地收藏管理（完整保留）
- `pages/history_page.dart` — 历史记录页面
- `pages/download_page.dart` — 下载页面（详见第五步）
- `pages/image_favorites.dart` — 图片收藏页面
- `pages/tools.dart` — 工具页面（精简在线相关工具）

---

## 第四步：移植"收藏"页面 (FavoritesPage)

### 4.1 核心页面
- 复制 `pages/favorites/main_favorites_page.dart` — 收藏主页面
- 复制 `pages/favorites/local_favorites.dart` — 本地收藏展示
- 复制 `pages/favorites/local_search_page.dart` — 本地收藏内搜索
- 移除的文件（不需要）：
  - `pages/favorites/network_favorite_page.dart` — 网络收藏
  - `pages/favorites/network_to_local.dart` — 网络→本地同步

### 4.2 精简收藏页面逻辑
- 移除"网络收藏夹"和"本地收藏夹"的切换
- 收藏文件夹**统一为本地收藏**
- 保留文件夹管理功能（创建/删除/重命名/排序）
- 保留漫画在文件夹间的移动、删除操作

### 4.3 数据层
- 完整保留 `foundation/local_favorites.dart` 中的：
  - `LocalFavoritesManager` — SQLite 数据库管理
  - `FavoriteItem` — 收藏数据模型
  - 封面缓存逻辑
- **保留 `FavoriteType`**：该类标识每条收藏/下载记录**来自哪个漫画源**（如 JM=禁漫、Picacg=哔咔、E-Hentai、NHentai、Hitomi、HtManga、拷贝漫画、Komiic 等）。
  在 PicaKeep 中已下载的漫画仍保留其原始来源信息，用于在"已下载"列表中展示来源标签。
  - **保留** `FavoriteType` 的 key 值和名称标识
  - **移除** `comicSource` getter（依赖在线图源插件系统）
  - **移除** `comicType` getter（依赖 `ComicType` 枚举，该枚举在在线网络层定义）
  - 改为直接用 key → 名称的本地映射表

---

## 第五步：已下载页面及详情页（完整保留 + 重构为本地）

### 5.1 下载管理器（保留 + 精简）
- 复制 `network/download.dart` — `DownloadManager` 单例，SQLite 管理下载记录
- **保留的功能**：
  - `getAll()` — 从 SQLite 获取所有已下载漫画（支持排序）
  - `getComicOrNull()` — 获取单个漫画
  - `isExists()` — 检查是否存在
  - `getCover()` — 获取封面文件
  - `getImage()` — 按章节/页码获取图片
  - `delete()` — 删除下载
  - `deleteEpisode()` — 删除单个章节
  - `generateId()` — 统一 ID 生成
- **移除**：所有网络下载相关逻辑（`addPicDownload`/`addEhDownload` 等网络下载方法、`DownloadingItem` 下载队列、`newDownload.json` 持久化队列）

### 5.2 下载数据模型（保留 + 精简）
- 复制 `network/download_model.dart`
- 保留 `DownloadedItem` 抽象基类的**数据结构**（name/id/subTitle/tags/eps/downloadedEps/comicSize/time/directory）
- **保留** `DownloadType` 枚举及其值（picacg/ehentai/jm/hitomi/htmanga/nhentai/other/favorite/copy_manga/Komiic），因为它们标识下载记录的来源
- 各平台具体模型类简化：
  - 移除网络请求相关方法
  - 保留数据字段（用于本地数据展示和序列化/反序列化）
  - 根据你的 `download_.txt` 数据格式，需要支持以下类型：

| 来源类型 | 数据中的 key | JSON 结构 |
|----------|-------------|-----------|
| 禁漫 (JM) | `"comic"` | `{name, id, author, description, series, tags, epNames}` |
| NHentai | `"comicID"` | `{title, size, cover}` |
| E-Hentai | `"gallery"` | `{title, subTitle, type, time, uploader, stars, rating, coverPath, tags}` |
| 哔咔 (Picacg) | `"comicItem"` | `{creator, id, title, description, thumbUrl, author, chineseTeam, categories, tags, likes, comments, epsCount, time, pagesCount}` |
| 拷贝漫画 | `"sourceKey"="copy_manga"` | `{id, name, tags, sourceKey, sourceName, cover, comicId, chapters, downloadedEps}` |
| Komiic | `"sourceKey"="Komiic"` | `{id, name, tags, sourceKey, sourceName, cover, comicId, chapters, downloadedEps}` |

### 5.3 已下载页面（完整保留 + 改造）
- 复制 `pages/download_page.dart`
- **保留全部功能**：
  - 列表展示（排序：按时间/标题/作者/大小）
  - 搜索过滤（本地关键词搜索）
  - 长按 → 进入多选模式
  - 多选模式下的操作按钮（删除、添加到本地收藏）
  - 右键/更多菜单（阅读、删除、导出、查看详情、复制路径）
  - 单击 → `DownloadedComicInfoView` 浮动面板（章节列表、分批阅读、删除章节）
  - `DownloadedComicInfoView` 底部"查看详情"按钮
- **改造 `_toComicInfoPage()` 方法**：
  - 原来按类型分发到各在线平台的 `PicacgComicPage`/`EhGalleryPage`/`JmComicPage` 等
  - **改为统一分发到新的本地漫画详情页** `LocalComicDetailPage`，传入从 `DownloadedItem` 提取的本地数据

### 5.4 本地漫画详情页（新建）
- 新建 `pages/local_comic_detail_page.dart`
- 参考原 `pages/comic_page.dart` 中 `BaseComicPage` 的布局结构，但全部使用本地数据：
  - **漫画信息区**：封面 + 标题 + 作者 + 来源标签 + 文件大小 + 下载时间
  - **标签区**：用不同颜色卡片展示标签
  - **章节区**：网格布局的章节按钮，已下载章节高亮，点击可直接阅读
  - **简介区**：纯文本描述（从 JSON 的 `description` 字段提取）
  - **操作按钮**：继续阅读 | 从头开始 | 删除下载
- 数据来源：从 `DownloadedItem.toJson()` 的 JSON 中提取对应字段：
  | 展示字段 | JSON 数据来源 |
  |----------|--------------|
  | 标题 | `DownloadedItem.name` |
  | 作者 | `DownloadedItem.subTitle` |
  | 封面 | `DownloadManager.getCover(id)` — 本地文件 |
  | 来源 | `DownloadedItem.type` → 来源名称映射 |
  | 标签 | `DownloadedItem.tags` |
  | 简介 | JSON 中的 `description` 字段 |
  | 章节 | `DownloadedItem.eps` + `downloadedEps` |
  | 文件大小 | `DownloadedItem.comicSize` |
  | 下载时间 | `DownloadedItem.time` |

---

## 第六步：本地搜索功能

### 6.1 新增本地搜索页面
- 创建新的 `pages/local_search_page.dart`（与收藏内的搜索不同，这是全局搜索）
- 搜索范围：所有本地收藏文件夹中的漫画 + 已下载漫画
- 搜索字段：漫画名 `name`、作者 `author`/`subTitle`、标签 `tags`
- UI 设计参考原有的 `PreSearchPage`，但简化：
  - 保留搜索输入框
  - 移除图源选择器
  - 移除在线搜索选项
  - 搜索建议基于本地已有的标签
  - 搜索结果以网格/列表展示匹配的漫画

### 6.2 不需要的文件
- 不复制 `pages/pre_search_page.dart`（在线搜索入口）
- 不复制 `pages/search_result_page.dart`（在线搜索结果）
- 不复制 `network/res.dart`（网络响应封装）
- 不复制 `network/base_comic.dart`（在线漫画基类）

---

## 第七步：设置页面精简

### 7.1 保留的设置类别
复制 `pages/settings/settings_page.dart` 及其 part 文件，精简约以下类别：

| 保留 | 设置类别 | 说明 |
|------|---------|------|
| ✅ | 浏览 | 仅保留本地显示相关的设置，去除在线功能（详见7.3） |
| ✅ | 阅读 | **完整保留** — 本地阅读必须（阅读模式、翻页、缩放等） |
| ✅ | 外观 | **完整保留** — 主题、深色模式、纯黑模式、高刷新率 |
| ✅ | 本地收藏 | **完整保留** — 收藏相关的设置 |
| ✅ | APP | 日志、数据管理、语言、隐私 |
| ✅ | 关于 | **完整保留** — 版本信息、反馈等 |

### 7.2 移除的设置类别

| 移除 | 设置类别 | 原因 |
|------|---------|------|
| ❌ | 漫画源 | 图源管理（无在线图源） |
| ❌ | 网络 | 代理、网络设置等（无网络功能） |

### 7.3 "浏览"设置的精简（explore_settings.dart）

**保留以下本地显示相关设置：**
- "初始页面" — 启动标签页选择（只保留"我"和"收藏"两个选项）
- "漫画列表显示方式" — 连续/分页模式
- "关键词屏蔽" — 本地关键词过滤
- "完全隐藏屏蔽的作品" — 屏蔽开关
- "启用侧边翻页栏" — UI 交互
- "漫画块显示模式" — 详细/简略
- "漫画块大小" — 网格大小调节
- "漫画块缩略图布局" — 覆盖/容纳
- "显示收藏状态" — 收藏标记
- "显示阅读位置" — 阅读进度标记
- "图片收藏大小" — 图片收藏网格大小
- **"检查剪切板中的链接"** — **保留并改造**（详见7.4）

**移除以下在线相关设置：**
- "网络收藏页面" — 在线收藏相关
- "探索页面" — 依赖 ComicSource
- "分类页面" — 依赖 ComicSource
- "默认搜索源" — 依赖 ComicSource
- "自动添加语言筛选" — 在线搜索相关

### 7.4 剪贴板检测改造

保留 `tools/app_links.dart` 或新建本地版本 `tools/local_app_links.dart`：

**改造逻辑：**
1. 检查剪切板中是否为链接（保留 `isURL` 判断）
2. 从链接中提取漫画 ID（如 `jm651891`、`nhentai408727`、`2971848` 等）
3. **在本地下载数据库** + **本地收藏数据库** 中搜索匹配的漫画
   - 对应你 `download_.txt` 中的 `id` 字段
4. 找到 → 弹出提示"在本地找到：[漫画名]"，点击确定跳转到本地详情页/阅读页
5. 未找到 → 弹出提示"本地未找到匹配的漫画"

**支持的链接类型识别：**
| 链接域名/模式 | 提取方式 | 对应数据 ID 格式 |
|--------------|---------|-----------------|
| `picacomic.com` | URL path 中的 ID | `{mongoId}` 如 `6595730e2ef71146c8a109a6` |
| `e-hentai.org/g/{gid}` | path 中的 gid | 纯数字：`2971848` |
| `nhentai.net/g/{id}` | path 中的数字 | `nhentai{id}` 如 `nhentai408727` |
| `jmcomic` 相关 | URL 中的数字 | `jm{id}` 如 `jm651891` |
| `hitomi.la` | path 解析 | `hitomi:{id}` |

### 7.5 从 appdata.settings 中移除的设置键
- 移除与网络代理、在线认证、图源相关的 settings 索引

---

## 第八步：移植漫画阅读器（完整保留，不做任何改动）

> **⚠️ 重要：阅读器模块不做任何代码改动，完整从 PicaComic 复制。**
> 阅读设置（reading_settings.dart）同样不做任何改动。

### 8.1 核心阅读器
- 完整复制 `pages/reader/` 整个目录，**代码不做任何修改**
- 阅读器所有功能保留（和原项目一模一样）：
  - 多种阅读模式（左至右、右至左、上至下、从上至下连续、双页、双页反向）
  - 图片预加载（0~15 张可配置）
  - 点按翻页 / 音量键翻页
  - 双击缩放 / 长按缩放
  - 屏幕方向锁定
  - 页面信息显示
  - 自动翻页（可配置间隔时间）
  - 深色模式下降低图片亮度
  - 宽屏时显示控制按钮
  - 保持屏幕常亮（Android）
  - 阅读历史记录同步

### 8.2 阅读图片加载改造
> 虽然阅读器代码本身不改动，但它依赖的图片提供方需要适配。
> 阅读器通过抽象层获取图片，只需确保底层 `getImage(id, ep, index)` 能返回本地文件路径即可。
- 从 `DownloadManager.getImage(id, ep, index)` 提供本地图片文件
- 从 `DownloadManager.getCover(id)` 提供封面
- 图片加载层需能区分本地文件路径并正确加载

### 8.3 阅读入口
- 收藏页点击漫画 → 从 `FavoriteItem` 提取信息 → 构造阅读请求
- 下载页点击阅读 → 利用已有 `ReadComic` extension，移除在线图源分发后直接本地加载
- 历史记录页 → 从历史记录恢复阅读进度

---

## 第九步：数据模型与存储

### 9.1 保留的模型
- `FavoriteItem` — 完整保留
- `FavoriteType` — **保留**，但移除 `comicSource` 和 `comicType` 等依赖在线图源的 getter，改为本地名称映射
- `DownloadedItem` 及各平台子类 — **保留数据结构**，精简为纯数据类
- `DownloadType` 枚举 — **保留并扩展**（加入 copy_manga、Komiic 等）
- `DownloadManager` — 保留本地查询/删除功能，移除网络下载方法
- 历史记录模型
- 图片收藏模型

### 9.2 移除的模型
- `BaseComic` / `CustomComic` — 在线漫画抽象
- `Profile` — 用户资料
- 所有图源特定在线模型（`ComicItemBrief`, `EhGalleryBrief`, `JmComicBrief` 等）
- `FavoriteData` — 网络收藏加载器
- `ComicSource` 整个插件系统
- `Res<T>` — 网络响应封装

### 9.3 数据库
- SQLite 数据库 `local_favorite.db` — 结构保持不变
- SQLite 数据库 `download.db` — 结构保持不变（`id, title, subtitle, time, directory, size, json`）
- 封面缓存目录 `favoritesCover/` — 保持不变
- 下载文件目录 `download/` — 保持不变

---

## 第十步：多语言与主题

### 10.1 多语言支持
- 和原来一样，完整保留 `tools/translations.dart`
- 保留 `assets/translation.json`、`assets/tags.json`、`assets/tags_tw.json`
- 保留 `tools/tags_translation.dart`

### 10.2 主题定制
- 和原来一样，完整保留外观设置模块
- 支持：Material You 动态取色、深色模式、纯黑模式、高刷新率

---

## 第十一步：组件与工具移植

### 11.1 需要移植的通用组件
从 `components/` 目录复制必要的组件：
- `navigation_bar.dart` — 导航栏（核心，必须）
- 其他"我"页、"收藏"页、下载页、阅读器用到的组件（需进一步确认）

### 11.2 需要移植的工具模块
从 `tools/` 目录：
- `translations.dart` — 多语言支持
- `tags_translation.dart` — 标签翻译
- `io_tools.dart` — IO 工具
- `app_links.dart` — 链接解析（改造为本地版）

---

## 第十二步：清理与验证

### 12.1 代码清理
- 移除所有未使用的 import
- 移除所有在线网络相关的 dead code
- 确保没有对已删除模块的引用
- 清理 `appdata.settings` 中无用的设置键

### 12.2 编译验证
- 运行 `flutter pub get`
- 运行 `flutter analyze` 确保无编译错误
- 运行 `flutter build` 验证构建成功

### 12.3 功能验证清单
- [ ] 应用启动正常，直接进入主页面
- [ ] "我" Tab 显示正常，历史记录、下载、图片收藏等功能可用
- [ ] 已下载页面：列表、排序、搜索、长按多选、`DownloadedComicInfoView`、章节级删除、查看本地详情页全部正常
- [ ] 本地漫画详情页：标题/作者/来源/标签/简介/章节 全部正确展示
- [ ] 已下载列表点击"查看漫画详情"跳转到本地详情页
- [ ] 剪贴板检测：粘贴链接 → 搜索本地数据库 → 找到/未找到提示
- [ ] "收藏" Tab 显示正常，文件夹管理、漫画收藏增删改查可用
- [ ] 本地搜索能正确搜索所有收藏+已下载的漫画
- [ ] 漫画阅读器正常打开、翻页、缩放、切换模式
- [ ] 设置页面各选项正常保存和生效
- [ ] 多语言切换正常
- [ ] 主题（动态取色/深色/纯黑）切换正常
- [ ] 导航栏在手机/平板/桌面不同宽度下响应式切换正常

---

## 数据样本参考

你的 `download_.txt` 中导出的 50 条下载记录包含以下来源分布：

| 来源 | ID 格式 | 数量 |
|------|---------|------|
| 禁漫 (JM) | `jm{数字ID}` | ~11条 |
| NHentai | `nhentai{数字ID}` | ~10条 |
| E-Hentai | `{纯数字GID}` | ~14条 |
| 哔咔 (Picacg) | `{MongoDB ObjectId}` | ~8条 |
| 拷贝漫画 | `copy_manga-{comicId}` | ~3条 |
| Komiic | `Komiic-{comicId}` | ~4条 |

每条记录包含字段（根据类型不同略有差异）：
- `id` — 唯一标识
- `title` — 标题（name）
- `subtitle` — 副标题/作者
- `time` — 下载时间戳
- `directory` — 文件系统目录名
- `size` — 文件大小(MB)
- `json` — 完整元数据 JSON（含 tags、description、chapters、cover 等）

---

## 文件变更清单

### 新建文件
| 文件 | 说明 |
|------|------|
| `lib/main.dart` | 精简后的入口 |
| `lib/base.dart` | 精简后的全局数据 |
| `lib/pages/main_page.dart` | 精简后的主页面（2 Tab） |
| `lib/pages/local_search_page.dart` | 新的本地搜索页面 |
| `lib/pages/local_comic_detail_page.dart` | 新的本地漫画详情页 |
| `lib/tools/local_app_links.dart` | 本地化的剪贴板链接检测 |

### 从 PicaComic 复制并修改的文件
| 源文件 | 目标文件 | 修改说明 |
|--------|---------|---------|
| `components/navigation_bar.dart` | 同路径 | 基本不变 |
| `foundation/app.dart` | 同路径 | 精简 |
| `foundation/state_controller.dart` | 同路径 | 不变 |
| `foundation/local_favorites.dart` | 同路径 | 保留 FavoriteType，移除 comicSource/comicType getter |
| `foundation/history.dart` | 同路径 | 基本不变 |
| `network/download.dart` | `foundation/download.dart` | 移入 foundation，移除网络下载方法，保留本地查询/删除 |
| `network/download_model.dart` | `foundation/download_model.dart` | 保留数据模型，扩展 DownloadType 枚举 |
| `pages/me_page.dart` | 同路径 | 移除账号管理模块 |
| `pages/history_page.dart` | 同路径 | 不变 |
| `pages/download_page.dart` | 同路径 | `_toComicInfoPage()` 改为导航到 LocalComicDetailPage |
| `pages/download_page.dart` 中的 `ReadComic` extension | 同文件 | 改造阅读入口为纯本地 |
| `pages/image_favorites.dart` | 同路径 | 不变 |
| `pages/tools.dart` | 同路径 | 精简在线工具 |
| `pages/favorites/main_favorites_page.dart` | 同路径 | 移除网络收藏切换 |
| `pages/favorites/local_favorites.dart` | 同路径 | 基本不变 |
| `pages/favorites/local_search_page.dart` | 同路径 | 不变 |
| `pages/reader/` (整个目录) | 同路径 | **不修改，完整复制** |
| `pages/settings/settings_page.dart` | 同路径 | 精简为6个类别 |
| `pages/settings/explore_settings.dart` | 同路径 | 保留本地显示+剪贴板检测，移除在线项 |
| `pages/settings/reading_settings.dart` | 同路径 | **不修改，完整保留** |
| `pages/settings/app_settings.dart` | 同路径 | 精简 |
| `pages/settings/local_favorite_settings.dart` | 同路径 | 基本不变 |
| `tools/translations.dart` | 同路径 | 基本不变 |
| `tools/tags_translation.dart` | 同路径 | 基本不变 |
| `tools/io_tools.dart` | 同路径 | 基本不变 |

### 不复制（移除）的文件/目录
| 路径 | 原因 |
|------|------|
| `network/` (整个目录，除了 download.dart 和 download_model.dart) | 在线网络功能 |
| `network/res.dart` | 网络响应封装 |
| `network/base_comic.dart` | 在线漫画基类 |
| `comic_source/` (整个目录) | 图源插件系统 |
| `pages/explore_page.dart` | 在线探索 |
| `pages/category_page.dart` | 在线分类 |
| `pages/pre_search_page.dart` | 在线搜索入口 |
| `pages/search_result_page.dart` | 在线搜索结果 |
| `pages/comic_page.dart` | 在线漫画详情（被 LocalComicDetailPage 替代） |
| `pages/accounts_page.dart` | 在线账号管理 |
| `pages/picacg/` (整个目录) | 哔咔专用页面 |
| `pages/ehentai/` (整个目录) | E-Hentai 专用页面 |
| `pages/jm/` (整个目录) | 禁漫专用页面 |
| `pages/hitomi/` (整个目录) | Hitomi 专用页面 |
| `pages/htmanga/` (整个目录) | 绅士漫画专用页面 |
| `pages/nhentai/` (整个目录) | NHentai 专用页面 |
| `pages/favorites/network_favorite_page.dart` | 网络收藏 |
| `pages/favorites/network_to_local.dart` | 网络同步 |
| `pages/settings/comic_source_settings.dart` | 图源设置 |
| `pages/settings/network_setting.dart` | 网络设置 |
