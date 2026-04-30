# PicaKeep 已下载不显示修复 v3 Spec

## Why

用户设置下载目录后"已下载"页面仍为空。经审查 `download_.txt` 原始数据，发现上一轮修复未覆盖的 JSON 结构实际问题：

1. **Picacg 检测失败** — JSON 根键是 `"comicItem"` 而非 `"comicId"`，且章节列表在顶层 `"chapters"` 键而非 `"comicItem"` 内
2. **E-Hentai 解析字段错配** — `gallery.title` → `galleryTitle` 字段名不匹配，且 `gallery.tags` 是 `Map` 不是 `List`
3. **NHentai ID 前缀问题** — `comicID` 值已包含 `"nhentai"` 前缀，`id` getter 提取纯数字后与存储的带前缀 ID 不一致
4. **磁盘扫描不完整** — 不处理下载文件夹内图片平铺（无章节子目录）的情况
5. **无 txt 导入机制** — 用户数据在 `download_.txt` 中，不在 `download.db` 中

## What Changes

- 支持 Picacg `"comicItem"` 键检测，从 `"chapters"` 读取章节
- 修复 E-Hentai `gallery` 对象字段映射，`gallery.tags` 特殊处理（Map→List）
- NHentai `comicID` 前缀保留，`id` getter 直接返回 `comicID` 不截断
- 磁盘扫描增加"平铺图片目录"检测模式（章节=1，直接扫描目录下图片）
- 增加"从 download_.txt 导入"功能（设置页数据管理 + 下载页初始化时自动触发）
- `_getComicFromJson` 增加更多诊断日志

## Impact

- Affected code: `lib/foundation/download.dart`、`lib/foundation/download_model.dart`、`lib/pages/settings/app_settings.dart`、`lib/pages/download_page.dart`

## ADDED Requirements

### Requirement: Picacg JSON 检测与解析
系统 SHALL 正确检测 Picacg 格式并解析章节列表。

#### Scenario: Picacg 数据
- **WHEN** JSON 包含 `"comicItem"` 键
- **THEN** 从 `comicItem.id` 提取 comicId，`comicItem.chapters` 读取章节名列表
- **THEN** 章节映射为 `{index: chapterName}`

### Requirement: E-Hentai 解析修复
系统 SHALL 正确映射 gallery 对象的所有字段。

#### Scenario: E-Hentai 数据
- **WHEN** JSON 包含 `"gallery"` 键
- **THEN** 从 `gallery.title` 映射到 `galleryTitle`，从 `gallery.subtitle` 映射到 `subtitle`
- **AND** `gallery.tags` 是 Map 时，取其所有 value 合并为 List

### Requirement: NHentai ID 前缀保留
系统 SHALL 在 NHentai 中保留完整的 `comicID` 值。

#### Scenario: NHentai ID
- **WHEN** `comicID` 值为 `"nhentai408727"`
- **THEN** `id` getter 直接返回 `"nhentai408727"`，不做前缀截断

### Requirement: 磁盘扫描平铺目录支持
系统 SHALL 识别下载文件夹内图片平铺（无章节子目录）的情况。

#### Scenario: 平铺图片目录
- **WHEN** 漫画文件夹内直接包含图片文件（无子目录）
- **THEN** 创建章节 `"第1章"`，标记为已下载
- **AND** 图片作为第0章节内容

### Requirement: download_.txt 自动导入
系统 SHALL 在检测到 `download_.txt` 时自动将其导入到 `download.db`。

#### Scenario: 首次设置路径
- **WHEN** 用户设置下载目录，且该目录下存在 `download_.txt`
- **THEN** 自动解析 txt 内容，逐行解析字段，写入 `download.db`
- **THEN** txt 中每条记录：Tab 分隔 → id/title/subtitle/time/title(again)/size/json
- **THEN** 导入完成后删除或重命名 txt 文件避免重复导入
