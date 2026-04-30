# PicaKeep "我"页面 Null 错误修复 v11 Spec

## Why

v10 修复后，"我"页面出现 `Null check operator used on a null value` 错误，导致页面无法显示。

## What Changes

- 修复 `me_page.dart` 中导致 Null 错误的代码
- 确保所有可能为 null 的值都被正确处理

## Impact

- Affected code: `lib/pages/me_page.dart`
- **BREAKING**: 无

## Technical Analysis

**根因分析**：
- `me_page.dart` 中使用了 `.tl` 和 `.tlParams()` 扩展方法
- 这些扩展方法可能依赖于 `Translations` 实例，而该实例可能未正确初始化
- 或者 `DownloadManager().total` 访问时 `_db` 为 null

## ADDED Requirements

### Requirement: "我"页面无 Null 错误
系统 SHALL 确保"我"页面在任何情况下都不会出现 Null check operator 错误。

#### Scenario: 打开"我"页面
- **WHEN** 用户进入"我"页面
- **THEN** 页面正常显示
- **THEN** 不出现任何 Null 错误

## MODIFIED Requirements

无

## REMOVED Requirements

无
