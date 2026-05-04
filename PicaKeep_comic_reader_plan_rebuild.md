# PicaKeep 完整复刻计划文档（基于当前实际实现）

## 文档目的

本文档用于**一次性复刻当前 `PicaKeep` 的真实可运行版本**。

它不是最初的理想化裁剪计划，也不是开发过程记录，而是把以下三部分合并后的**最终落地蓝图**：
- 初始计划文档 `PicaKeep/.trae/documents/PicaKeep_comic_reader_plan.md`
- 中期修正文档 `PicaKeep/PicaKeep_comic_reader_plan_v3.md`
- 当前项目代码中已经实际完成的功能、结构调整与新增能力

目标是：按照本文档，从 `PicaComic` 出发，可以较稳定地重新做出现在这版 `PicaKeep`。

---

## 一、最终项目定位

`PicaKeep` 不是单纯“去联网版 PicaComic”，而是一个以 `PicaComic` 阅读器能力为基础、面向**本地漫画 / 本地图集 / 本地收藏 / 本地历史**的离线漫画库应用。

### 1.1 核心定位

- 保留 `PicaComic` 的阅读器核心体验
- 保留“我”“收藏”“设置”等主干交互
- 去除在线图源、账号、探索、分类、在线搜索、在线收藏同步
- 将“下载列表”扩展为**本地数据入口之一**
- 新增**本地漫画库聚合层**，可同时读取：
  - 当前应用下载目录
  - 原 PicaComic 数据目录
  - 用户自定义本地漫画路径
- 新增本地图集、本地文件管理、存储统计、数据源切换、隐私认证等能力

### 1.2 最终保留 / 新增能力

#### 保留并本地化的原有能力
- “我”页面
- “收藏”页面
- 已下载页面
- 漫画阅读器
- 阅读历史
- 图片收藏
- 设置页
- 多语言
- 主题 / 深色 / 纯黑 / 动态取色
- 桌面响应式导航

#### 在实际实现中新增的能力
- 本地漫画库 `LocalLibraryManager`
- 本地图集聚合页 `LocalLibraryPage`
- 本地文件管理页 `LocalLibraryFilesPage`
- 本地存储统计页 `LocalLibraryStoragePage`
- 受管数据源模式切换（当前目录 / 原应用目录 / 两者同时）
- 原应用下载目录迁移接入
- 自定义本地漫画路径扫描
- 本地详情页相关推荐模式
- 本地图集图片排序
- 应用返回前台身份验证
- Android 截图保护
- 桌面窗口标题栏快捷入口桥接

### 1.3 明确移除的能力
- 所有在线图源插件系统
- 在线漫画详情页分发体系
- 在线账号登录与账户管理
- 探索页 / 分类页
- 在线搜索入口 / 在线搜索结果页
- 网络收藏夹 / 网络同步
- 代理与网络设置
- 网络请求层及其模型

---

## 二、与初始计划相比的关键结论

### 2.1 初始计划正确但不完整的部分

初始计划的主方向是对的：
- 以本地功能为核心
- 保留阅读器
- 保留收藏 / 历史 / 下载
- 移除在线网络层
- 用统一本地详情页替代各图源详情页

但实际项目证明，仅做这些还不够。因为真实使用场景里，用户不仅有“应用内下载”，还有：
- 原 PicaComic 的历史数据
- 原 PicaComic 的下载目录
- 手工整理在磁盘上的漫画目录
- 图集型目录而非标准下载结构

因此实际实现多出了一层**本地资源聚合系统**。

### 2.2 v3 文档修正后仍需要上提为正式蓝图的部分

`v3` 已经记录了很多补丁，但它仍然偏“修复日志”。

需要上升为正式复刻要求的内容包括：
- `AuthPage` 不应视为已删除，而应视为**本地隐私锁屏页**
- `local_data_source.dart` 是正式基础设施，不是临时兼容层
- `local_library.dart` / `local_library_page.dart` 是正式核心模块，不是附加功能
- `ToolsPage` 已从占位页演变为本地资源管理入口
- 设置页中的“数据”部分已不只是下载目录设置，而是完整的本地数据接入控制台
- 依赖列表需以当前实际版本为准，而不是初始裁剪设想

---

## 三、当前实际项目的完整功能范围

## 3.1 主导航结构

主页面 `MainPage` 保持 **2 个 Tab + 2 个 Action**：

### Tab
- Tab 0：`MePage`
- Tab 1：`MainFavoritesPage`

### Action
- 搜索：`LocalSearchPage`
- 设置：`SettingsPage`

### 实际补充结构
- 使用 `MainPageHub` 连接桌面标题栏快捷入口与主 Navigator
- 首帧触发剪贴板检查 `checkLocalClipboard()`
- 初始页仍由设置项控制

---

## 3.2 “我”页面实际内容

当前 `MePage` 实际包含 5 个入口卡片：
- 历史记录
- 已下载
- 本地图集 / 本地漫画库
- 图片收藏
- 工具

这比初始计划多了一个正式入口：
- **本地图集 / 本地漫画库入口**

“我”页还具备以下实际行为：
- 监听 `App.localDataVersion`，在本地数据刷新后自动更新数量
- 已下载数量会根据“受管数据源模式”动态统计
- 历史封面会在下载目录、本地库、候选 ID 中回退查找

---

## 3.3 收藏页面实际内容

收藏页当前不是简单的本地收藏列表，而是一个**完整的本地收藏工作台**：

### 收藏首页能力
- 本地收藏夹列表
- 搜索收藏
- 搜索全部（转入全局本地搜索）
- 收藏夹排序
- 创建 / 删除 / 重命名 / 调序

### 收藏夹内能力
- 显示漫画卡片
- 下载状态识别
- 右键菜单 / 长按菜单
- 阅读 / 打开详情 / 取消收藏 / 标签编辑等操作
- 收藏点击行为遵循设置项
- 通过 `candidateDownloadIds()` / 本地库候选映射去解析真实本地条目

### 与初始计划相比的实际增强
- 不只是“本地收藏数据库展示”
- 还会尝试解析到：
  - 下载数据库中的实体
  - 本地聚合库中的实体
- 因此收藏页既是“收藏管理页”，也是“本地内容跳转页”

---

## 3.4 已下载页面实际内容

`download_page.dart` 基本保留了下载管理页的完整操作性，但现在面向纯本地数据：

### 已保留功能
- 列表展示
- 搜索
- 排序
- 多选
- 批量删除
- 批量加入本地收藏
- 漫画更多菜单
- 单项删除
- 章节删除
- 导出
- 复制路径
- 打开统一详情页 `LocalComicDetailPage`

### 详情浮层能力
- 漫画基础信息
- 章节列表
- 分章节阅读
- 删除章节
- 查看详情跳转

### 当前实际跳转策略
- 下载列表详情统一进入 `LocalComicDetailPage`
- 阅读统一走本地阅读数据结构
- 不再按平台分发到 Picacg / EH / JM 等页面

---

## 3.5 本地详情页实际能力

`LocalComicDetailPage` 是当前版本的核心页面之一，比初始计划更强。

### 基础展示区
- 封面
- 标题
- 作者 / 副标题
- 来源标签
- 文件大小
- 下载时间
- 标签翻译显示
- 简介区

### 阅读操作区
- 继续阅读
- 从头开始
- 指定章节阅读
- 删除整本下载
- 删除单章节

### 实际增强能力
- 历史回退匹配：支持 `id / comicId / itemId / favoriteTarget / alias` 多候选匹配历史
- 章节顺序切换
- AppBar 标题滚动联动
- 本地下拉联动与底部拉取交互
- **相关推荐**：基于本地库条目进行推荐分页，受设置项控制推荐模式
- 对普通下载项和本地图集条目统一适配

---

## 3.6 本地搜索实际能力

`LocalSearchPage` 最终不是单一搜索页，而是一个支持不同搜索上下文的本地搜索入口。

### 搜索范围
- 下载列表
- 本地收藏
- 本地聚合库（间接参与匹配 / 跳转）

### 搜索字段
- 名称
- 作者 / 副标题
- 标签
- 部分场景下可匹配路径 / 本地条目别名

### 语义拆分
- 收藏页“搜索收藏”：仅面向收藏语义
- 收藏页“搜索全部”：转向更完整的全局搜索
- 结果去重后按可读形式展示

---

## 3.7 本地漫画库（新增核心模块）

这是当前实现相较初始计划最大的结构升级。

### 模块目标
将多个来源的本地漫画 / 图集统一聚合成一个可浏览、可搜索、可阅读、可管理的数据层。

### 数据来源
- 当前应用下载目录
- 原 PicaComic 下载目录
- 用户自定义本地路径

### 关键文件
- `lib/foundation/local_library.dart`
- `lib/foundation/local_library_settings.dart`
- `lib/pages/local_library_page.dart`

### 核心对象
- `LocalLibrarySource`
- `LocalLibraryStorageEntry`
- `LocalLibraryStorageChildEntry`
- `LocalLibraryComicItem`
- `LocalPathReadingData`
- `LocalLibraryManager`

### 实际能力
- 扫描目录并生成聚合条目
- 区分受管下载项与普通本地图集
- 支持多章节 / 单章节 / 图集型条目
- 构造统一阅读数据
- 生成封面回退路径
- 维护别名与候选 ID
- 读取并统计目录体积
- 识别来源展示文案

### 页面能力
#### `LocalLibraryPage`
- 搜索
- 排序（时间 / 名称 / 体积）
- 仅显示图集过滤
- 打开详情页
- 打开系统目录
- 复制路径
- 下拉刷新 / 重扫后联动刷新

#### `LocalLibraryFilesPage`
- 管理自定义本地漫画路径
- 添加路径
- 删除路径
- 查看当前受管目录
- 触发重扫

#### `LocalLibraryStoragePage`
- 统计每个来源路径的大小
- 展示子目录 / 来源占用
- 复制路径 / 打开目录

---

## 3.8 设置页面实际内容

设置页仍保留 6 大分类，但现在每类都应以当前实现为准。

### 分类列表
- 浏览
- 阅读
- 外观
- 本地收藏
- APP
- 关于

### 浏览
保留并已对齐本地化的设置包括：
- 初始页面
- 漫画列表显示方式
- 关键词屏蔽
- 完全隐藏屏蔽作品
- 侧边翻页栏
- 漫画块显示模式
- 漫画块大小
- 缩略图布局
- 显示收藏状态
- 显示阅读位置
- 图片收藏大小
- 剪贴板检测

### 阅读
- 实际上继续沿用原阅读器设置体系
- 包含翻页、预加载、缩放、方向、自动翻页、页码显示等

### 外观
- 动态取色 / 主题色
- 深色模式
- 纯黑模式（实际索引已修正为 `[84]`）
- 高刷新率
- 主题切换即时生效

### 本地收藏
- 收藏展示相关设置
- 与收藏页点击行为、排序、布局相关的本地项

### APP
当前已演变为“数据与隐私控制台”，包含：
- 日志入口
- 当前应用下载目录设置
- 原应用下载目录设置
- 自定义本地漫画路径设置
- 本地图集图片排序
- 本地库列表排序
- 受管数据源模式切换
- 刷新本地漫画
- 重新扫描磁盘
- 语言切换
- 截图保护
- 身份验证

### 关于
- 版本 / 反馈 / 外部链接等

---

## 3.9 数据源模式与兼容策略（新增正式要求）

当前项目不是只读当前应用数据，而是支持多数据根接入。

### 关键文件
- `lib/foundation/local_data_source.dart`
- `lib/base.dart`

### 受管数据源模式
- `0`：仅当前应用数据目录
- `1`：当前应用数据目录 + 原 PicaComic 数据目录
- `2`：仅原 PicaComic 数据目录

### 作用范围
该模式会影响：
- 下载数据库读取
- 收藏数据库读取
- 历史记录读取
- “我”页面数量统计
- 本地库扫描与聚合

### 相关设置索引
- `[75]`：受管数据源模式
- `[90]`：原应用下载目录
- `[91]`：本地漫画路径列表
- `[92]`：本地图集图片排序
- `[93]`：本地图集列表排序
- `[94]`：本地图集页仅显示图集
- `[95]`：本地详情页相关推荐模式

这部分必须视为当前版本的正式基础设施，而不是兼容补丁。

---

## 3.10 剪贴板链接识别实际状态

当前 `tools/local_app_links.dart` 已接入 `MainPage`，但它的能力应按“当前实现 + 可继续优化”来定义。

### 已实现部分
- 检查剪贴板文本
- 识别 URL
- 解析 Picacg / E-Hentai / NHentai / JM / Hitomi 链接
- 生成对应本地候选 ID
- 在下载数据库和本地收藏中查找匹配项
- 弹出“已找到 / 未找到”提示

### 当前实现限制
- 找到后目前主要是提示与占位反馈
- 还没有完全打通成“直接跳到对应本地详情页”的最终交互闭环

因此复刻时应按以下优先级实现：
1. 先复刻现有解析与匹配能力
2. 再决定是否把“找到后直接打开详情页”做成增强项

---

## 3.11 工具页实际内容

`ToolsPage` 已不是占位工具页，而是本地资源入口页。

### 当前入口
- 本地文件管理
- 存储空间
- 本地图集
- 清理缓存（目前仍偏占位）

实际复刻时，应将前三项视为正式功能，将“清理缓存”视为可后补项。

---

## 3.12 权限、隐私与安全

初始计划原本移除了身份验证，但当前项目实际重新引入了**本地隐私能力**。

### `AuthPage`
- 使用 `local_auth`
- 应用启动时可选验证
- 应用回到前台时可再次验证
- `AuthPage.initial` / `AuthPage.lock` 控制首次进入与恢复锁屏

### 截图保护
- Android 上通过 `block_screenshot.dart` 启用
- 设置项控制开关

因此当前版本的定位不是“完全不要认证”，而是“不要在线认证，但保留本地隐私认证”。

---

## 3.13 桌面端能力

当前依赖和代码都说明桌面端被正式支持，而不是偶然可运行。

### 相关能力
- `window_manager` 标题栏与窗口行为
- `WindowFrame` 自定义窗口框架
- 桌面标题栏快捷入口通过 `MainPageHub` 打开页面
- 路径复制 / 打开系统目录 / 右键交互
- Windows 构建已验证通过

因此桌面适配是正式复刻范围的一部分。

---

## 四、实际依赖清单（以当前项目为准）

复刻时不要只按初始计划删依赖，应按**当前已使用依赖**构建。

### 4.1 核心依赖
- `flutter`
- `shared_preferences`
- `dynamic_color`
- `crypto`
- `photo_view` (git)
- `url_launcher`
- `path_provider`
- `shimmer_animation`
- `flutter_localizations`
- `intl`
- `flutter_displaymode`
- `flutter_reorderable_grid_view`
- `sqlite3`
- `sliver_tools`
- `collection`

### 4.2 当前版本实际仍需要的依赖
- `file_picker` — 自定义路径 / 本地目录管理
- `window_manager` — 桌面窗口框架
- `share_plus` — 导出 / 分享入口
- `file_selector` — 部分平台目录选择
- `flutter_image_gallery_saver` — 阅读器保存图片
- `local_auth` — 本地身份验证

### 4.3 覆盖与补丁
- `local_auth_windows` 使用本地 stub override

---

## 五、建议的复刻实施顺序（一次性重建版）

## 第一步：建立项目骨架

### 5.1 创建 Flutter 项目
- 项目名：`picakeep`
- 应用名：`PicaKeep`
- 包名沿现有项目配置保持一致
- 目标平台至少包含 Windows / Android

### 5.2 配置依赖
按“第四章依赖清单”完整接入，不要按最初删减版处理。

### 5.3 复制资源
- `assets/translation.json`
- `assets/tags.json`
- `assets/tags_tw.json`
- 图标与其他本地静态资源

---

## 第二步：搭建基础设施层

### 5.4 入口文件 `main.dart`
实现以下初始化顺序：
1. `WidgetsFlutterBinding.ensureInitialized()`
2. `App.init()`
3. `appdata.readData()`
4. `loadTranslations()`
5. `HistoryManager().init()`
6. `LocalFavoritesManager().init()`
7. `downloadManager.init()`
8. `App.applyDisplayModePreference()`
9. 桌面窗口初始化
10. `runApp()`

### 5.5 `App` 基础设施
保留并实现：
- `navigatorKey`
- `mainNavigatorKey`
- `updater`
- `localDataVersion`
- `notifyLocalDataChanged()`
- 桌面 / 移动平台判断
- `openReader()` / `pushInner()` 等导航辅助
- 语言环境解析
- Android 高刷应用

### 5.6 `base.dart`
保留原设置数组结构，并确保：
- 旧索引兼容
- 新增本地库相关索引 `[90]-[95]`
- 受管数据源索引 `[75]`
- 设置读取时做 normalize

### 5.7 新增本地数据源模块
实现：
- `local_data_source.dart`
- 原应用数据目录推导
- 当前 / 原应用 / 双路径模式切换

---

## 第三步：保留阅读器并完成本地化适配

### 5.8 复制阅读器目录
完整迁移 `pages/reader/`。

### 5.9 适配阅读数据提供层
确保阅读器既能读：
- 下载数据库的本地图片
- 本地图集聚合条目的文件路径

### 5.10 修复阅读历史恢复
`DownloadedItem.createReadingPage({int? ep, int? page})` 必须支持历史恢复参数。

### 5.11 保留阅读器外围能力
- 保存图片
- 图片收藏
- 历史写入
- 阅读设置

---

## 第四步：构建下载、本地详情与收藏主链路

### 5.12 下载模型与管理器
从原项目中抽出本地可用部分：
- `download.dart`
- `download_model.dart`

并移除网络下载队列，仅保留：
- 查询
- 删除
- 章节删除
- 图片 / 封面定位
- 数据解析

### 5.13 下载页
实现以下完整能力：
- 搜索
- 排序
- 多选
- 删除
- 加收藏
- 导出
- 复制路径
- 浮层详情
- 章节删除
- 统一跳本地详情页

### 5.14 本地详情页
实现：
- 头图信息区
- 标签区
- 简介区
- 章节区
- 继续阅读 / 从头开始
- 删除下载
- 历史恢复
- 推荐列表

### 5.15 收藏页
实现：
- 收藏夹管理
- 收藏夹排序
- 收藏夹内列表
- 下载状态识别
- 右键 / 长按菜单
- 标签编辑
- 点击行为可配置
- 收藏条目到下载 / 本地库的候选解析

---

## 第五步：加入本地漫画库聚合系统

### 5.16 实现 `LocalLibraryManager`
能力包括：
- 扫描当前下载目录
- 扫描原应用下载目录
- 扫描自定义路径
- 聚合成本地条目模型
- 建立封面 / 别名 / 原始 ID / 候选 ID
- 区分图集与标准下载结构
- 计算大小与来源

### 5.17 本地图集条目模型
实现 `LocalLibraryComicItem` 继承 `DownloadedItem`，让本地库条目直接复用：
- 下载列表卡片风格
- 详情页
- 阅读页
- 历史
- 推荐

### 5.18 本地图集浏览页
实现 `LocalLibraryPage`：
- 搜索
- 排序
- 仅图集过滤
- 打开目录
- 复制路径
- 打开详情页

### 5.19 本地文件管理页
实现 `LocalLibraryFilesPage`：
- 显示当前受管目录
- 选择并添加自定义路径
- 删除路径
- 触发刷新 / 重扫

### 5.20 存储统计页
实现 `LocalLibraryStoragePage`：
- 各来源路径占用
- 子目录体积统计
- 打开目录 / 复制路径

---

## 第六步：完成“我”、搜索、工具三条入口链

### 5.21 “我”页面
实现 5 个入口卡片：
- 历史记录
- 已下载
- 本地图集
- 图片收藏
- 工具

并接入本地数据刷新监听。

### 5.22 全局本地搜索页
实现：
- 搜索收藏
- 搜索下载
- 搜索聚合本地库的跳转目标
- 搜索建议
- 去重结果展示

### 5.23 工具页
实现 3 个正式入口：
- 本地文件管理
- 存储空间
- 本地图集

“清理缓存”可先做占位。

---

## 第七步：完成设置、隐私与桌面适配

### 5.24 设置页
保留 6 大类，按当前结构组织。

### 5.25 APP 数据控制区
必须包含：
- 当前下载目录
- 原应用下载目录
- 自定义路径
- 数据源模式
- 刷新本地漫画
- 重新扫描磁盘
- 语言切换
- 日志
- 截图保护
- 身份验证

### 5.26 认证页
实现 `AuthPage` 并在以下场景接入：
- 启动时
- 返回前台时

### 5.27 桌面窗口
保留：
- `WindowFrame`
- 标题栏快捷入口
- `MainPageHub`
- 目录打开与路径复制能力

---

## 第八步：兼容旧数据并做最终验证

### 5.28 数据兼容要求
- `download.db` 结构兼容原 PicaComic
- `local_favorite.db` 结构兼容原 PicaComic
- `history` 结构兼容原 PicaComic
- 原应用数据目录自动识别

### 5.29 功能验证清单

#### 启动与基础
- [ ] 应用启动正常
- [ ] 可直接进入主页面或身份验证页
- [ ] 多语言切换正常
- [ ] 主题 / 深色 / 纯黑 / 高刷正常

#### 导航与页面
- [ ] “我”页 5 个入口正常
- [ ] 收藏页正常
- [ ] 搜索页正常
- [ ] 设置页 6 大分类正常

#### 下载与详情
- [ ] 已下载列表正常
- [ ] 排序 / 搜索 / 多选正常
- [ ] 章节删除正常
- [ ] 导出 / 复制路径正常
- [ ] 本地详情页展示完整
- [ ] 继续阅读 / 从头开始可用

#### 阅读器
- [ ] 本地图片加载正常
- [ ] 阅读历史写入正常
- [ ] 从历史恢复正常
- [ ] 图片收藏正常
- [ ] 保存图片正常

#### 本地库
- [ ] 可读取当前应用下载目录
- [ ] 可读取原应用数据目录
- [ ] 可读取自定义路径
- [ ] 本地图集页搜索 / 排序 / 过滤正常
- [ ] 文件管理页路径管理正常
- [ ] 存储统计页体积显示正常

#### 收藏与历史
- [ ] 收藏夹管理正常
- [ ] 收藏页可识别下载状态
- [ ] 收藏页可跳本地详情或阅读
- [ ] 历史封面与跳转回退正常

#### 数据控制
- [ ] 刷新本地漫画生效
- [ ] 重新扫描磁盘生效
- [ ] 切换数据源模式后页面联动刷新

#### 隐私与桌面
- [ ] 身份验证正常
- [ ] 截图保护正常
- [ ] 桌面窗口框架正常
- [ ] 打开目录 / 复制路径正常

---

## 六、应新建 / 迁移 / 保留的关键文件

## 6.1 必须保留并继续作为核心的文件
- `lib/main.dart`
- `lib/base.dart`
- `lib/foundation/app.dart`
- `lib/foundation/state_controller.dart`
- `lib/foundation/download.dart`
- `lib/foundation/download_model.dart`
- `lib/foundation/history.dart`
- `lib/foundation/local_favorites.dart`
- `lib/pages/download_page.dart`
- `lib/pages/local_comic_detail_page.dart`
- `lib/pages/local_search_page.dart`
- `lib/pages/favorites/main_favorites_page.dart`
- `lib/pages/favorites/local_favorites.dart`
- `lib/pages/me_page.dart`
- `lib/pages/settings/settings_page.dart`
- `lib/pages/settings/app_settings.dart`
- `lib/pages/settings/explore_settings.dart`
- `lib/pages/settings/reading_settings.dart`
- `lib/pages/settings/local_favorite_settings.dart`
- `lib/pages/reader/`
- `lib/components/navigation_bar.dart`
- `lib/tools/translations.dart`
- `lib/tools/tags_translation.dart`
- `lib/tools/read_history_helper.dart`
- `lib/tools/save_image.dart`
- `lib/tools/local_app_links.dart`
- `lib/tools/block_screenshot.dart`

## 6.2 相比初始计划新增为正式模块的文件
- `lib/foundation/local_data_source.dart`
- `lib/foundation/local_library.dart`
- `lib/foundation/local_library_settings.dart`
- `lib/foundation/main_page_hub.dart`
- `lib/pages/local_library_page.dart`
- `lib/pages/auth_page.dart`
- `lib/tools/notification.dart`
- `lib/tools/extensions.dart`

---

## 七、最终复刻原则

1. **不要按最初设想过度裁剪。** 当前版本已经证明：仅保留下载 / 收藏 / 阅读器并不足以覆盖真实本地使用场景。
2. **优先复刻当前代码结构。** 特别是 `local_library.dart`、`local_data_source.dart`、`AuthPage`、`MainPageHub` 这几块。
3. **把原 PicaComic 数据兼容视为正式需求。** 它不是迁移脚本，而是日常可切换的数据接入模式。
4. **阅读器尽量少动。** 重点是把阅读数据提供层本地化。
5. **本地库条目应尽量复用 `DownloadedItem` 体系。** 这样才能复用详情页、阅读页、历史、推荐与 UI 组件。
6. **设置页不是装饰页，而是本地数据控制面板。** 刷新、重扫、路径切换都要真的生效。

---

## 八、结论

如果要复刻当前 `PicaKeep`，正确目标不是“做一个删掉联网功能的 PicaComic”，而是：

**做一个继承 PicaComic 阅读器与 UI 主干、同时具备本地下载库 + 原应用数据兼容 + 自定义本地路径聚合 + 本地图集管理能力的离线漫画库应用。**

这就是当前项目真实完成态所对应的复刻蓝图。