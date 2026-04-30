# PicaKeep 已下载不显示问题修复 v5 Spec

## Why

经过对原项目 PicaComic 和当前 PicaKeep 的详细代码对比，发现以下关键差异导致已下载漫画无法显示：

1. **原项目的 `_getComicFromJson` 使用 ID 前缀判断类型**，而 PicaKeep 使用 JSON key 判断类型。用户的 `download.db` 中的 JSON 数据是由原项目存储的，其结构与原项目的 `toJson()` 输出一致。
2. **PicaKeep 的 `_getComicFromJson` 对 Picacg 数据的解析逻辑错误**：原项目的 `DownloadedComic.toJson()` 输出是 `{"comicItem": {...}, "chapters": [...], "size": ..., "downloadedChapters": [...]}`，但 PicaKeep 的解析代码错误地假设 `comicItem` 内部还有 `chapters` 字段，实际上 `chapters` 在根级别。
3. **PicaKeep 的 `DownloadedGallery.id` getter 与原项目不一致**：原项目的 `DownloadedGallery.id` 从 `gallery.link` 提取 `gid-token` 格式，而 PicaKeep 的手动构造分支没有正确设置 `id`，导致 `getDirectory()` 查询失败。
4. **原项目的 `getAll()` 不处理 `_db == null`**，因为 `init()` 在应用启动时就被调用且 `_runInit` 标志防止重复初始化。PicaKeep 的 `getAll()` 虽然加了 `_db == null` 检查，但 `_initDb()` 是同步的而 `init()` 是异步的，导致路径可能还没获取到就打开数据库。
5. **PicaKeep 的 `DownloadedJmComic.fromMap` 期望的字段名与原项目不一致**：原项目存储的是 `{"comic": JmComicInfo.toJson(), "size": ..., "downloadedChapters": [...]}`，而 PicaKeep 的解析代码试图从 `comic` 中提取扁平化的字段，但 `JmComicInfo.toJson()` 的结构可能不同。

## What Changes

- **重写 `_getComicFromJson`**：改为与原项目一致的 ID 前缀判断逻辑，确保正确识别漫画类型
- **修复 Picacg 解析**：正确处理 `comicItem` + 根级别 `chapters` / `downloadedChapters` 的结构
- **修复 E-Hentai `id` 问题**：确保手动构造的 `DownloadedGallery` 的 `id` 与数据库存储的 `id` 一致
- **修复 JM 解析**：正确处理原项目存储的 `{"comic": JmComicInfo.toJson()}` 结构
- **修复 `getAll()` 初始化**：确保 `path` 已获取后再打开数据库
- **添加更详细的错误日志**：记录每条记录的解析失败原因

## Impact

- Affected code: `lib/foundation/download.dart`, `lib/foundation/download_model.dart`

## ADDED Requirements

### Requirement: 与原项目一致的类型判断逻辑
系统 SHALL 使用与原项目一致的 ID 前缀判断漫画类型，而非 JSON key 判断。

#### Scenario: 识别漫画类型
- **WHEN** `_getComicFromJson` 被调用
- **THEN** 按以下顺序判断类型：
  - `id.contains('-')` → `CustomDownloadedItem`
  - `id.startsWith("jm")` → `DownloadedJmComic`
  - `id.startsWith("hitomi")` → `DownloadedHitomiComic`
  - `id.startsWith("nhentai")` → `NhentaiDownloadedComic`
  - `id.startsWith("Ht")` → `DownloadedHtComic`
  - `id.isNum` → `DownloadedGallery` (E-Hentai)
  - 其他 → `DownloadedComic` (Picacg)

### Requirement: 正确的 Picacg JSON 解析
系统 SHALL 正确解析原项目存储的 Picacg JSON 结构。

#### Scenario: Picacg 数据结构
- **WHEN** JSON 包含 `comicItem` 键
- **THEN** `comicItem` 是 `ComicItem.toJson()` 的结果
- **THEN** `chapters` 和 `downloadedChapters` 在根级别
- **THEN** 使用 `DownloadedComic.fromJson(data)` 解析

### Requirement: 正确的 E-Hentai id 处理
系统 SHALL 确保 `DownloadedGallery` 的 `id` 与数据库中的 `id` 一致。

#### Scenario: E-Hentai id 生成
- **WHEN** 从 `gallery` 键手动构造 `DownloadedGallery`
- **THEN** 从 `link` 字段提取 `gid-token` 作为 `id`
- **THEN** 如果 `link` 不匹配，使用原始传入的 `id` 参数

### Requirement: 同步初始化保证 path 可用
系统 SHALL 在 `getAll()` 中确保 `path` 已获取后再打开数据库。

#### Scenario: _db 为 null 时调用 getAll
- **WHEN** `getAll()` 被调用且 `_db == null`
- **THEN** 先调用 `_getPath()` 获取路径
- **THEN** 再调用 `_initDb()` 打开数据库

## MODIFIED Requirements

### Requirement: DownloadedGallery 的 id getter
修改为优先使用传入的原始 id，仅在需要时从 link 提取。

## REMOVED Requirements

无
