# PicaKeep 漫画阅读器修复 v7 Spec

## Why

发现两个关键问题阻止 PicaKeep 漫画阅读器正常工作：

1. **数据库未初始化错误**：`LateInitializationError: Field 'db' has not been initialized`
   - `HistoryManager` 和 `LocalFavoritesManager` 的 `init()` 方法未被调用
   - 阅读器在初始化历史记录时直接使用 `HistoryManager().findSync()`，但数据库未打开

2. **UI 样式还原不完整**：已下载页面的 SliverAppBar 使用 Flutter 原生组件，与原项目 PicaComic 的自定义 `SliverAppbar` 样式不完全一致

## What Changes

- **修复 main.dart 数据库初始化**：在应用启动时调用 `HistoryManager().init()` 和 `LocalFavoritesManager().init()`
- **复制原项目 SliverAppbar 组件**：将 PicaComic 的 `components/appbar.dart` 中的 `SliverAppbar` 组件复制到 PicaKeep
- **更新 download_page.dart 使用自定义 SliverAppbar**：替换 Flutter 原生 SliverAppBar 为自定义组件

## Impact

- Affected code: `lib/main.dart`, `lib/components/appbar.dart`, `lib/pages/download_page.dart`
- **不修改**: 阅读器核心代码、收藏模块、历史模块
- **BREAKING**: 无

## ADDED Requirements

### Requirement: 数据库初始化
系统 SHALL 在应用启动时初始化所有 SQLite 数据库。

#### Scenario: 应用启动
- **WHEN** `main()` 函数执行
- **THEN** 调用 `await HistoryManager().init()`
- **THEN** 调用 `await LocalFavoritesManager().init()`
- **THEN** 确保阅读器可以正常访问历史记录数据库

### Requirement: 自定义 SliverAppbar 组件
系统 SHALL 使用 PicaComic 原项目中的自定义 `SliverAppbar` 组件。

#### Scenario: 已下载页面渲染
- **WHEN** `DownloadPage` 构建
- **THEN** 使用 `SliverAppbar` 自定义组件
- **THEN** 支持 `title`、`leading`、`actions`、`color`、`radius` 参数

## REMOVED Requirements

无
