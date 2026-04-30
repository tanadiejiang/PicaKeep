# PicaKeep 阅读器修复 v8 Spec

## Why

修复两个关键问题：

1. **阅读器无法打开**：`ScrollController not attached to any scroll views` 错误。`SmoothCustomScrollView` 使用 `CustomScrollView`，但 `ScrollController` 没有被正确附加到滚动视图上。

2. **UI 显示问题**：
   - "我" 页面已下载组件未显示漫画数量
   - 已下载页面漫画大小显示格式与原项目不一致

## What Changes

- **修复 SmoothCustomScrollView**：移除 `ScrollController` 或确保它正确附加到 `CustomScrollView`
- **修复 "我" 页面已下载组件**：添加漫画数量显示
- **修复漫画大小显示格式**：确保大小显示格式与原项目一致

## Impact

- Affected code: `lib/components/scrollable.dart`, `lib/pages/me_page.dart`, `lib/pages/download_page.dart`
- **BREAKING**: 无

## ADDED Requirements

### Requirement: 阅读器滚动修复
系统 SHALL 确保 `SmoothCustomScrollView` 不抛出 `ScrollController not attached` 错误。

#### Scenario: 打开阅读器
- **WHEN** 用户点击漫画进入阅读器
- **THEN** `CustomScrollView` 正确渲染
- **THEN** 不抛出 `ScrollController not attached` 错误

### Requirement: "我"页面已下载数量显示
系统 SHALL 在"我"页面的已下载组件中显示漫画数量。

#### Scenario: 查看"我"页面
- **WHEN** 用户进入"我"页面
- **THEN** 已下载组件显示漫画数量（如"已下载 (12)"）

### Requirement: 漫画大小显示格式
系统 SHALL 使用与原项目一致的格式显示漫画大小。

#### Scenario: 查看已下载漫画列表
- **WHEN** 用户查看已下载漫画
- **THEN** 大小显示格式与原项目一致
