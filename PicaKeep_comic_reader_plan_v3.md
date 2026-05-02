# PicaKeep 开发计划 v3 — 基于半成品现状

## 执行进度 (2026-03-14 更新 v7)

✅ **全部修复完成** — `flutter analyze` **0 issues**

| 阶段 | 状态 | 关键修复 |
|------|------|---------|
| P1 编译清理 | ✅ | 移除 9 warnings, 删除 `uuid`/`init.js`, 清理死代码 |
| P2 阅读器历史 | ✅ | `createReadingPage({int? ep, int? page})` 7 子类, 3 调用点 |
| P3 设置对齐 | ✅ | 纯黑模式 index [28]→[84] (3处), explore 无在线残留 |
| P4 数据兼容 | ✅ | download.db / local_favorite.db / history 表结构一致 |
| P5 功能补全 | ✅ | 多语言加载正常, 图片收藏计数动态化 |
| P6 编译验证 | ✅ | `pub get` + `analyze` + `build windows` 全通过 |

### 本轮修复 (2026-03-14 v7) — 收藏页真正重写：视觉样式+页面结构对齐原项目

| 问题 | 根因 | 修复文件 |
|------|------|---------|
| 收藏页 tile description 只显示来源类型，不显示时间 | PicaComic 的 `description` 格式为 `"${time} \| ${type}"`，PicaKeep 仅为 `type` | `pages/favorites/local_favorites.dart` |
| 未下载时 tile 显示来源类型为 badge | PicaComic 只在已下载时显示"已下载"badge，未下载时无 badge | `pages/favorites/local_favorites.dart` |
| tile size 字段传了文件大小而非 description | PicaComic 的 description 是时间+类型，PicaKeep 传了计算出的文件大小覆盖了 description | `pages/favorites/local_favorites.dart` |
| 收藏页主结构为分离的列表页+网格页 | PicaComic 是单页 Stack 布局：顶部栏+文件夹下拉抽屉+内容区，PicaKeep 是两个独立页面 | `pages/favorites/main_favorites_page.dart` |
| 文件夹列表视觉不匹配 | PicaComic 使用 SliverGrid + 计数 badge + 长按菜单，PicaKeep 使用 Card+ListTile | `pages/favorites/main_favorites_page.dart` |
| 缺少文件夹下拉切换交互 | PicaComic 顶部栏点击展开/收起文件夹抽屉，PicaKeep 无此交互 | `pages/favorites/main_favorites_page.dart` |
| type 参数可空性不匹配 | `DownloadedComicTile.type` 为 non-nullable `String`，但 badge 为 `String?` | `components/comic_tile.dart` |

### 本轮修复 (2026-03-14 v6) — 收藏页重写 + 全警告清零

| 问题 | 根因 | 修复文件 |
|------|------|---------|
| 收藏页 `editTags` 未定义 | PicaKeep `foundation/local_favorites.dart` 缺少 `editTags` 方法 | `foundation/local_favorites.dart` |
| `dl.read()` 未定义 | `ReadComic` 扩展在 `download_page.dart` 中但未导入 | `pages/favorites/local_favorites.dart` |
| `base.dart` 未使用导入 | 重构残留 | `pages/favorites/local_favorites.dart` |
| 不必要的字符串插值 | `'${comic.type.name}'` 应为 `comic.type.name` | `pages/favorites/local_favorites.dart` |
| `sort_child_properties_last` (3处) | `PopupMenuItem` 中 `child:` 应在 `onTap:` 之后 | `pages/favorites/local_favorites.dart` |
| `onLongTap` 可空类型不匹配 | `DownloadedComicTile.onLongTap` 不可空但传入 `null` | `pages/favorites/local_favorites.dart` |
| `await_only_futures` + `use_of_void_result` | `_FavSearchDelegate.onOpen` 为 `void` 但被 `await` | `pages/favorites/local_favorites.dart` |
| `LocalFavoritesPage` 未定义 | `local_search_page.dart` 引用已改名类 → `LocalFavoritesFolder` | `pages/local_search_page.dart` |
| 未使用导入 | `local_search_page.dart` 导入不存在引用的文件 | `pages/local_search_page.dart` |

### 本轮追加修复 (2026-03-14 #5) — 收藏页对齐 + 阅读器图片收藏 + 设置页视觉

| 问题 | 根因 | 修复文件 |
|------|------|---------|
| 收藏页长按菜单为底部弹出（与原项目对话框风格不一致） | `_showComicMenu` 使用 `showModalBottomSheet`，原项目使用 `showDialog` | `pages/favorites/local_favorites.dart` |
| 收藏页无下载状态徽章 | 缺少 `_isDownloaded` 辅助方法，`_buildTile` 未检查下载状态 | `pages/favorites/local_favorites.dart` |
| 收藏页右键菜单无响应 | `onSecondaryTap: (_) {}` 空实现 | `pages/favorites/local_favorites.dart` |
| 阅读器单页模式下收藏图片无反应 | `_persistentCurrentImage` 依赖 `checkEpDownloaded`，当 `downloadedEps` 未填充时跳过直接文件读取，回退到空数据 stream 加载 | `pages/reader/comic_reading_page.dart` |
| 设置页关于部分视觉不一致 | 图标和文字布局与原项目有差异 | `pages/settings/settings_page.dart` |

### 本轮追加修复 (2026-03-14 #4) — 修复历史记录/图片收藏/收藏页

| 问题 | 根因 | 修复文件 |
|------|------|---------|
| 历史记录首次点击显示错误 UI (重试/未知错误/切换章节) | 所有 7 个 `createReadingPage` 实现中 `ep`/`page` 参数传入 `ComicReadingPage(data, ep, page)` 顺序错误 — `ep` 被当作 `initialPage`、`page` 被当作 `order`，导致 `loadEp(wrongChapter)` 失败；首次失败时 dispose 的 `_updateHistory` 偶然"反交换"了值，第二次点击恰巧正确的 bug | `foundation/download_model.dart` (7 处) |
| 历史记录 ep=0 不工作 | `reading_logic.dart` 中 `order <= 0 ? order = 1 : order` 语义不清，替换为 `if (order <= 0) order = 1` | `pages/reader/reading_logic.dart` |
| 图片收藏不显示收藏时的图片作为封面 (再次) | `_persistentCurrentImage()` 对已下载图片使用 `loadImage` stream 获取数据，而 `LocalReadingData.loadImage` 仅 yield `[1]` 占位符（1 字节垃圾）→ storage 文件实为损坏数据。修复：对已下载图片直接用 `downloadManager.getImage()` 读取实际文件 | `pages/reader/comic_reading_page.dart` |
| 收藏页缺少长按上下文菜单 | 长按直接进入多选模式，与原项目风格不一致 → 改为长按弹出底部菜单（阅读/取消收藏）；多选仍通过 FAB 按钮触发 | `pages/favorites/local_favorites.dart` |

### 本轮追加修复 (2026-03-14 #3) — analyze 36→0

| 问题 | 根因 | 修复文件 |
|------|------|---------|
| 收藏夹大小+点击 (再次) | `toDownloadId()` 修复后仍存在边缘 ID 不匹配 → 添加 `comic.target` 直接回退 + 全函数 try-catch | `pages/favorites/local_favorites.dart` |
| 图片收藏封面不显示 | 空 `imagePath`（旧迁移数据）进入 fallback 产生错误目录路径 → 空值时跳过文件检查 | `pages/image_favorites.dart` |
| flutter analyze 降至 0 | 17 `withOpacity`→`withValues` (UTF-8 PowerShell)、`dart fix` 13 自动修复、RadioGroup 迁移、TickerMode 迁移、ignore third-party | `comic_tile.dart`, `custom_slider.dart`, `comic_reading_page.dart`, `tool_bar.dart`, `wrapping.dart`, `image.dart`, `reading_settings.dart`, `components.dart`, `local_favorite_settings.dart`, `window_frame.dart`, `local_app_links.dart` |

### 上次追加修复 (2026-03-14 #2)

| 问题 | 根因 | 修复文件 |
|------|------|---------|
| 收藏夹不显示大小 + 无法点击 | `toDownloadId()` 双前缀: target 已存完整 DB ID (如 `copy_manga-abc123`), 再次拼接前缀 → `copy_manga-copy_manga-abc123` 无法匹配 | `foundation/local_favorites.dart` |
| 图片收藏数量返回'我'页未同步 | `then` 回调在路由过渡期 setState 可能不刷新 → 改用 `addPostFrameCallback` 延迟刷新 | `pages/me_page.dart` |
| 图片收藏封面不显示 | 旧数据 bare filename 的 fallback 拼接对全路径也生效, 产生错误路径 → 仅对无路径分隔符的值添加前缀 | `pages/image_favorites.dart` |
| flutter analyze 从 43 降至 36 | 移除 4 个 unnecessary_import、1 个 unused_import、修复 prefer_collection_literals、const constructors、curly_braces | `layout.dart`, `main_page.dart`, `me_page.dart`, `stream_image_provider.dart`, `base_image_provider.dart`, `download_model.dart` |

### 第一次追加修复 (2026-03-14 #1)

| 问题 | 根因 | 修复文件 |
|------|------|---------|
| 收藏夹不显示大小 | `dm.getDirectory(id)` 返回相对路径, `Directory(dirPath)` 无法访问 → 改为 `Directory("${dm.path}/$dirPath")` | `pages/favorites/local_favorites.dart` |
| 图片收藏不显示封面 | `tool_bar.dart` 写入时 `image.split("/").last` 只存文件名, 读取时又拼 `${App.dataPath}/images/` 前缀 → 改为直接存储完整路径 | `pages/reader/tool_bar.dart`, `pages/image_favorites.dart` |
| 图片收藏点击无法跳转 | `split('-')` 解析 sourceKey 对 `copy_manga` 失效 + `file.existsSync()` 错误拦截 → 改为从 `otherInfo` 读取 `sourceKey`/`downloadId`, 移除文件存在检查 | `pages/image_favorites.dart`, `pages/reader/tool_bar.dart` |

## 当前状态总结

项目位于 `d:\Flutter_Projucts\PicaComic\PicaKeep`，已有完整编译记录（Windows x64 Debug/Release 构建产物存在）。核心架构已搭建完毕，约 **70-80% 完成**。

### 已完成模块

| 模块 | 文件 | 状态 |
|------|------|------|
| 项目骨架 | `pubspec.yaml`, `main.dart` | 完成 |
| 设置存储 | `base.dart` (90 索引保留, 去除在线依赖) | 完成 |
| 应用基础 | `foundation/app.dart`, `def.dart`, `state_controller.dart`, `log.dart` | 完成 |
| 本地收藏 | `foundation/local_favorites.dart` (FavoriteType 扩展至 copyManga/komiic, 本地名称映射) | 完成 |
| 下载管理 | `foundation/download.dart` (纯本地查询/删除, 去除下载队列和网络) | 完成 |
| 下载数据模型 | `foundation/download_model.dart` (8 种子类, 各自实现 `createReadingPage()`) | 完成 |
| 历史记录 | `foundation/history.dart` | 完成 |
| 图片加载 | `foundation/image_loader/`, `foundation/image_manager.dart` | 完成 |
| 导航栏 | `components/navigation_bar.dart` | 完成 |
| 通用组件 | `components/` (comic_tile, layout, message, select, side_bar, window_frame 等) | 完成 |
| 主页面 | `pages/main_page.dart` (2 Tab: 我 + 收藏, 搜索 + 设置 actions) | 完成 |
| "我"页面 | `pages/me_page.dart` (历史/下载/图片收藏/工具, 无账号) | 完成 |
| 历史页面 | `pages/history_page.dart` | 完成 |
| 收藏页面 | `pages/favorites/main_favorites_page.dart`, `local_favorites.dart` | 完成 |
| 已下载页面 | `pages/download_page.dart` (列表/排序/搜索/多选/浮层面板/详情) | 完成 |
| 本地详情页 | `pages/local_comic_detail_page.dart` | 完成 |
| 本地搜索页 | `pages/local_search_page.dart` | 完成 |
| 阅读器 | `pages/reader/` (LocalReadingData + ComicReadingPage, 所有引擎完整) | 完成 |
| 设置页面 | `pages/settings/` (浏览/阅读/外观/收藏/APP/关于) | 完成 |
| 剪贴板检测 | `tools/local_app_links.dart` | 完成 |
| 多语言 | `tools/translations.dart`, `tags_translation.dart` | 基本完成 |
| 资源 | `assets/` (translation.json, tags.json, tags_tw.json, init.js) | 已完成 |

### 待修复/补齐的问题

---

## 第一阶段：编译通过与代码清理

### 1.1 修复 `flutter analyze` 警告/错误

当前 `download_page.dart` 顶部有 `// ignore_for_file: unused_element, unused_import`，说明存在死代码。

**行动**：
- 运行 `flutter analyze` 查看所有 warning/error
- 移除 `download_page.dart` 中未使用的 import 和方法
- 移除 `download_model.dart` 中未被引用的子类和工厂方法
- 移除 `pubspec.yaml` 中未使用的依赖（`uuid`, `file_picker` 如未实际使用）
- 移除 `assets/init.js`（仅用于 JS 引擎/自定义图源，本地版不需要）

### 1.2 pubspec.yaml 精简

当前依赖中部分可能是多余的，需逐一确认：

| 依赖 | 是否需要 | 原因 |
|------|---------|------|
| `window_manager` | 需要 | 桌面端窗口管理（main.dart 和 window_frame.dart 使用） |
| `file_picker` | 待确认 | 设置页面 import 了 `file_picker` |
| `share_plus` | 待确认 | 可能用于导出/分享漫画 |
| `file_selector` | 待确认 | 可能用于选择下载目录 |
| `flutter_image_gallery_saver` | 待确认 | 可能用于保存图片到相册 |
| `uuid` | 待确认 | 可能未使用 |
| `flutter_displaymode` | 需要 | 高刷新率（设置中引用 index [38]） |

**行动**：逐项 grep 确认是否被实际 import，移除未使用的。

---

## 第二阶段：阅读器功能修复

### 2.1 修复 `createReadingPage()` 中的硬编码初始页/章节

**问题**：所有 `DownloadedItem` 子类的 `createReadingPage()` 都硬编码 `initialPage: 1, initialEp: 1`，不读取历史记录。

```dart:download_model.dart
@override
Widget createReadingPage() {
  // ...
  return ComicReadingPage(data, 1, 1);  // ← 硬编码了 1, 1
}
```

**修复**：接受 `ep` 和 `page` 参数，从 `ensureHistoryBeforeRead()` 的结果传入：
- 修改 `createReadingPage({int? ep, int? page})` 抽象方法签名
- 每个子类实现中从 History 读取对应进度
- 也可以让调用方（`ReadComic.read()`）把 history 的 ep/page 传进去

### 2.2 验证阅读器图片加载路径

**问题**：`LocalReadingData.loadEp()` 调用 `downloadManager.getEpLength(downloadId, ep)`，检查路径是否正确对应文件系统结构。

**行动**：用实际下载数据测试阅读器是否能正确打开图片。文件路径格式为 `${download.path}/${directory}/${ep}/${index}.{ext}`。

### 2.3 修复阅读器返回后的收藏页/我页刷新

**问题**：阅读结束后的 `onReadEnd` 回调（`local_favorites.dart` 中的 `onReadEnd`）和 `History` 更新是否正确触发 UI 刷新。

**行动**：确认 `ComicReadingPage._updateHistory()` 在阅读完成时正确调用 `StateController.update()` 刷新相关页面。

---

## 第三阶段：设置页面对齐

### 3.1 纯黑模式 index 修复

**问题**：`main.dart` 第 48 行使用 `appdata.settings[28]` 判断纯黑模式，但 PicaComic 中纯黑模式在 index [84]。index [28] 在 PicaComic 中是"预加载页数"。

**修复**：统一为 index [84]，同步修改：
- `main.dart` 中的 `_getPureBlack()` 方法
- `settings_page.dart` 中外观设置的纯黑模式开关引用

### 3.2 设置项覆盖检查

逐一确认以下设置在 PicaComic → PicaKeep 的 index 映射正确：

| 设置 | PicaComic index | PicaKeep index | 状态 |
|------|----------------|----------------|------|
| 点击翻页 | [0] | [0] | 一致 |
| 音量键翻页 | [7] | [7] | 一致 |
| 翻页方式 | [9] | [9] | 一致 |
| 夜间降低亮度 | [18] | [18] | 一致 |
| 预加载页数 | [28] | [28] | 一致 (但主 dart 错误引用了 28 做纯黑) |
| 纯黑模式 | [84] | [84] | 一致 (但主 dart 未引用 84) |
| 深色模式 | [32] | [32] | 一致 |
| 颜色主题 | [27] | [27] | 一致 |
| 高刷新率 | [38] | [38] | 一致 |
| 自动翻页 | [33] | [33] | 一致 |
| 点按范围 | [40] | [40] | 一致 |
| 图片布局 | [41] | [41] | 一致 |
| 固定屏幕方向 | [76] | [76] | 一致 |
| 双击缩放 | [49] | [49] | 一致 |
| 长按缩放 | [55] | [55] | 一致 |
| 显示页码 | [57] | [57] | 一致 |
| 侧边翻页 | [64] | [64] | 一致 |

### 3.3 移除"浏览"设置中残留的在线项

**行动**：检查 `explore_settings.dart` 确认以下项已移除：
- 网络收藏页面 (index [68])
- 探索页面 (index [77])
- 分类页面 (index [67])
- 默认搜索源 (index [63] 保留但改造为本地)

---

## 第四阶段：数据兼容性

### 4.1 download.db 兼容 PicaComic 数据

**行动**：验证 `DownloadManager._initDb()` 能正确读取 PicaComic 生成的 `download.db`：
- 表结构：`id, title, subtitle, time, directory, size, json`
- JSON 字段解析：确认每种类型的 `fromJson`/`fromMap` 能正确解析各平台 JSON
- 目录名映射：`_resolveDirectoryForId()` 能正确找到实际文件目录

### 4.2 local_favorite.db 兼容 PicaComic 数据

**行动**：验证 `LocalFavoritesManager` 能读取 PicaComic 的数据库：
- 表结构一致（`target, name, author, type, tags, cover_path, time, display_order`）
- `FavoriteType.key` 值与 PicaComic 一致

### 4.3 History 数据兼容

**行动**：验证 `HistoryManager` 能读取 PicaComic 的历史记录（基于 SQLite 的 history 表格式）。

---

## 第五阶段：功能补全

### 5.1 多语言加载修复

**问题**：`main.dart` 调用 `await loadTranslations()`，需确认该函数存在且正确加载 `translation.json`。

**行动**：
- 检查 `tools/translations.dart` 中 `loadTranslations()` 的实现
- 验证 `.tl` 和 `.tlParams()` 扩展方法正常工作
- 验证语言切换（index [50]）能触发 UI 刷新

### 5.2 历史记录页面修复

**问题**：`me_page.dart._openComicFromHistory()` 使用 `DownloadManager().getComicOrNull(history.target)`，但 PicaComic 的 `history.target` 可能不是 PicaKeep 的 `DownloadedItem.id` 格式。

例如：PicaComic 对于 Picacg 的历史记录 `target` 可能存的是 MongoDB ObjectId 或者 URL，而 PicaKeep 中下载 ID 直接就是那个 ObjectId。

**行动**：
- 检查 `HistoryManager.findSync()` 返回的 `target` 格式
- 如有不匹配，在 `ensureHistoryBeforeRead` 中添加 ID 转换逻辑
- 测试从历史记录打开漫画的完整流程

### 5.3 本地搜索页增强

**问题**：当前 `local_search_page.dart` 的搜索可能不覆盖所有字段。

**行动**：
- 确认搜索范围：下载列表 + 收藏列表
- 确认搜索字段：name, author/subTitle, tags
- 确认搜索建议基于本地已有标签
- 搜索结果点击跳转到本地详情页

### 5.4 收藏页点击漫画导航

**问题**：收藏页点击漫画后，应判断该漫画是否已下载，如果已下载则跳转到 `LocalComicDetailPage`，否则展示收藏信息（离线不可用提示）。

**行动**：
- 在 `main_favorites_page.dart` 或 `local_favorites.dart` (pages) 的点击处理中：
  1. 用 `FavoriteItem.toDownloadId()` 生成下载 ID
  2. 调用 `DownloadManager().isExists(id)` 检查
  3. 已下载 → 跳转 `LocalComicDetailPage`
  4. 未下载 → 提示"请先下载该漫画"

### 5.5 图片收藏功能验证

**行动**：
- 检查 `pages/image_favorites.dart` 和 `foundation/image_favorites.dart` 的 part 文件
- 验证图片收藏的存储/读取/删除功能
- 验证 me_page 中"图片收藏"卡片显示正确数量

---

## 第六阶段：验证清单

### 编译验证
- [ ] `flutter pub get` 成功
- [ ] `flutter analyze` 无 error
- [ ] `flutter build windows` 成功

### 功能验证
- [ ] 应用启动，直接显示主页面（2 Tab）
- [ ] "我" Tab：历史记录列表 + 封面图
- [ ] "我" Tab：已下载数量显示正确，点击跳转下载页
- [ ] "我" Tab：图片收藏、工具入口正常
- [ ] 已下载页面：列表、排序（时间/标题/作者/大小）、搜索过滤
- [ ] 已下载页面：长按多选 → 删除/收藏操作
- [ ] 已下载页面：浮层面板（章节列表/删除章节/查看详情）
- [ ] 已下载页面：点击"查看详情"跳转 `LocalComicDetailPage`
- [ ] 本地详情页：封面/标题/作者/来源/标签/章节/简介/操作按钮
- [ ] 本地详情页：点击章节打开阅读器
- [ ] "收藏" Tab：文件夹管理正常
- [ ] 收藏页点击已下载漫画 → 跳转本地详情页
- [ ] 收藏页点击未下载漫画 → 提示信息
- [ ] 本地搜索页：搜索建议/结果展示
- [ ] 漫画阅读器：正常打开、翻页、缩放、切换模式
- [ ] 漫画阅读器：阅读历史记录保存与恢复
- [ ] 漫画阅读器：从历史记录恢复上次阅读位置
- [ ] 设置：浏览/阅读/外观/收藏/APP/关于 六个类别
- [ ] 设置：纯黑模式切换（index [84]）
- [ ] 设置：深色模式/主题色切换
- [ ] 设置：语言切换（中文简体/繁体/英文）
- [ ] 剪贴板检测：粘贴链接 → 本地搜索 → 找到/未找到
- [ ] 桌面端：窗口管理正常（最小尺寸/标题栏隐藏）
- [ ] 响应式：窄屏单列 / 宽屏双列布局

---

## 实施顺序

按优先级排列：

1. **编译通过**：`flutter pub get` + `flutter analyze` 修复 → 移除死代码/未使用依赖
2. **阅读器修复**：`createReadingPage` 传入 history ep/page → 阅读进度恢复
3. **纯黑模式修复**：index [28] → [84]
4. **多语言验证**：确认 `loadTranslations` 和 `.tl` 扩展正常工作
5. **历史记录兼容**：验证 target 格式匹配，修复不匹配情况
6. **收藏页导航修复**：已下载/未下载的正确分流
7. **设置项全面检查**：逐项对照 index 表
8. **图片收藏验证**：功能完整性
9. **全功能验证**：按第六阶段清单逐项测试