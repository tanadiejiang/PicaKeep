# PicaKeep 阅读器及下载页面修复 v10 Spec

## Why

PicaKeep 存在多个严重问题需要修复：

1. **阅读器只显示一张图片**：无法显示全部漫画页面
2. **阅读设置按钮无效**：点击无法打开设置
3. **底部工具栏按钮功能未实现**：除自动翻页外，其他按钮都不可用
4. **重新扫描磁盘写入空数据**：数据库中出现无效的空记录
5. **扫描后需返回再进入才显示漫画**：UI 刷新问题
6. **已下载数量显示不一致且不实时更新**：样式和刷新问题

## What Changes

- **修复阅读器图片显示**：确保漫画所有页面正确加载和显示
- **修复工具栏功能**：确保所有按钮回调正确连接
- **修复数据库扫描**：过滤无效/空数据记录
- **修复 UI 刷新**：扫描后立即更新显示
- **修复数量显示**：匹配原项目样式并实时更新

## Impact

- Affected code: `lib/pages/reader/`, `lib/pages/download_page.dart`, `lib/pages/me_page.dart`, `lib/foundation/download.dart`
- **BREAKING**: 无

## Technical Analysis

### 问题 1-3：阅读器问题

**问题 1 根因分析**：
- 阅读器可能只加载了封面而非漫画页面
- 需要检查 `ComicReadingPage` 的 `loadInfo` 方法
- 需要验证 `ReadingData.loadEp()` 返回正确的图片列表

**问题 2-3 根因分析**：
- 工具栏按钮的 `onPressed` 回调可能未正确连接
- `showSettings` 函数可能在错误的时机被调用
- 需要检查 `StateController.find<ComicReadingPageLogic>()` 的返回值

### 问题 4-6：下载页面和数量显示问题

**问题 4 根因分析**：
- `DownloadManager.getAll()` 或扫描逻辑未过滤空数据
- JSON 解析失败时可能写入了不完整的数据
- 需要在写入数据库前验证数据有效性

**问题 5 根因分析**：
- 扫描后 `StateBuilder` 未收到更新通知
- 需要在扫描完成后调用 `logic.update()` 触发重建

**问题 6 根因分析**：
- `me_page.dart` 中获取 `DownloadManager().total` 的时机问题
- 需要使用 `StatefulWidget` 或 `StateBuilder` 监听数据变化

## ADDED Requirements

### Requirement: 阅读器完整加载所有页面
系统 SHALL 确保阅读器加载并显示漫画的所有页面，而不仅仅是封面或单张图片。

#### Scenario: 打开漫画阅读
- **WHEN** 用户点击漫画进入阅读器
- **THEN** 漫画的所有页面都被加载
- **THEN** 用户可以浏览漫画的所有页面

### Requirement: 工具栏按钮功能正常
系统 SHALL 确保所有工具栏按钮（设置、收藏、上一章、下一章、章节列表等）都能正常工作。

#### Scenario: 点击工具栏按钮
- **WHEN** 用户点击工具栏上的任意按钮
- **THEN** 对应功能被正确执行
- **THEN** UI 正确响应（如工具栏显示/隐藏、设置面板打开等）

### Requirement: 扫描数据库过滤无效数据
系统 SHALL 确保扫描本地文件时，只写入有效的漫画数据到数据库。

#### Scenario: 扫描本地文件
- **WHEN** 用户点击"重新扫描磁盘"
- **THEN** 只有包含有效漫画信息的记录被写入数据库
- **THEN** 空数据或无效数据被过滤掉

### Requirement: 扫描后立即刷新 UI
系统 SHALL 确保扫描完成后立即更新页面显示。

#### Scenario: 扫描完成
- **WHEN** 扫描完成
- **THEN** 已下载页面立即显示最新数据
- **THEN** 无需手动刷新或导航

### Requirement: 数量显示与原项目一致
系统 SHALL 确保"已下载"数量显示格式与原项目一致，并实时更新。

#### Scenario: 查看"我"页面
- **WHEN** 用户进入"我"页面
- **THEN** 已下载数量正确显示
- **THEN** 扫描后数量实时更新

## MODIFIED Requirements

无

## REMOVED Requirements

无
