# PicaKeep 已下载漫画无法显示修复 v6 Spec

## Why

经过对原项目 PicaComic 与当前 PicaKeep 代码的详细对比分析，发现以下关键差异导致已下载漫画始终显示"暂无已下载的漫画"：

1. **下载路径读取方式错误**：原 PicaComic 的 `_getPath()` 直接从 `appdata.settings[22]` 读取路径；PicaKeep 改为从 `SharedPreferences.getStringList("settings")` 读取。当用户通过设置界面设置路径后，路径保存在 `appdata.settings` 中（同时也写入 SharedPreferences），但 PicaKeep 的 `_getPath()` 与 `appdata.settings` 读取逻辑脱钩，在某些初始化顺序下可能读到空值导致路径回退到默认应用目录。

2. **E-Hentai (DownloadedGallery) JSON 结构不兼容**：原项目存储的是 `{"gallery": Gallery.toJson(), "size": ...}`（包含 `gallery` 包装键），而 PicaKeep 的 `DownloadedGallery.fromJson` 期望的是扁平字段 `galleryTitle`、`subtitle`、`link` 等直接用 `json["galleryTitle"]` 访问。这导致所有 E-Hentai 记录解析失败返回 null。

3. **JM/禁漫 (DownloadedJmComic) JSON 结构不兼容**：原项目存储的是 `{"comic": JmComicInfo.toJson(), "size": ..., "downloadedChapters": [...]}`，PicaKeep 的 `fromMap` 尝试从 `map["comic"]` 和根级别字段读取。此部分已有 fallback 处理但可能存在边界情况。

4. **Picacg (DownloadedComic) 标签解析缺失**：原项目的 `ComicItem.tags` 是 List，被 `comicItem.tags` 方式访问。PicaKeep 的 `fromJson` 会尝试从 `json["tagList"]` 或 `json["comicItem"]["tags"]` 读取，但未正确处理 `comicItem.tags` 的格式（可能是 List<String> 或 List<dynamic>）。

5. **错误处理完全静默**：`DownloadPage._loadComics()` 用 try-catch 包裹所有逻辑，任何异常都被静默吞掉且仅显示"暂无已下载的漫画"，用户无法知道实际发生了什么错误。

## What Changes

- **修复 `_getPath()` 路径读取**：改为直接从 `appdata.settings[22]` 读取，与 PicaComic 一致，确保用户设置的路径被正确使用
- **修复 `DownloadedGallery.fromJson`**：支持原项目的嵌套 JSON 格式 `{"gallery": {...}, ...}` 和扁平格式 `{"galleryTitle": ..., ...}`
- **修复 `DownloadedComic.fromJson` 标签解析**：确保 `comicItem.tags` 被正确转换为 `List<String>`
- **添加详细错误日志和用户可见提示**：在 `getAll()` 中记录成功/失败数量，在 `_getPath()` 中记录当前使用的路径
- **添加"重新扫描磁盘"到主页提示**：当列表为空时，提示用户可能需要重新扫描

## 保留的功能（不做任何改动）

- ✅ **设置 → APP → 下载目录 → "浏览"按钮选择文件夹** — 完整保留，代码不动
- ✅ `app_settings.dart` 中的 `_DownloadDirTile` 组件 — 完整保留
- ✅ 设置路径到 `appdata.settings[22]` 的逻辑 — 完整保留
- ✅ 阅读器、收藏、历史等所有其他模块 — 完整保留

## Impact

- Affected code: `lib/foundation/download.dart`, `lib/foundation/download_model.dart`, `lib/pages/download_page.dart`
- **不修改**: `lib/pages/settings/app_settings.dart` 中的下载目录选择 UI
- **BREAKING**: 无，所有改动向后兼容

## ADDED Requirements

### Requirement: 下载路径读取一致性
系统 SHALL 在 `_getPath()` 中直接从 `appdata.settings[22]` 读取下载路径，与设置界面写入端保持一致（设置界面通过 `appdata.settings[22] = newPath` 保存路径）。

**注意**："浏览文件夹选择路径"的 UI（`_DownloadDirTile`）完全不动，此修复仅改变 `_getPath()` 读取路径的数据源，使读写两端统一。

#### Scenario: 用户已设置自定义下载路径
- **WHEN** `DownloadManager._getPath()` 被调用
- **THEN** 读取 `appdata.settings[22]` 
- **THEN** 如果路径非空且目录存在，设置 `path` 为该自定义路径
- **THEN** 如果路径为空或目录不存在，回退到应用默认 `download/` 目录

### Requirement: E-Hentai JSON 兼容解析
系统 SHALL 同时支持原项目的嵌套 JSON 格式和扁平 JSON 格式。

#### Scenario: 原项目嵌套格式
- **WHEN** JSON 包含键 `"gallery"`
- **THEN** 从 `json["gallery"]` 中提取 galleryTitle/subtitle/uploader/link/coverPath/tags
- **THEN** 从根级别提取 `json["size"]`
- **THEN** 正确设置 `id`（从 link 提取 gid-token）

#### Scenario: 扁平格式（兼容旧 PicaKeep 数据）
- **WHEN** JSON 不包含 `"gallery"` 键但包含 `"galleryTitle"`
- **THEN** 直接从根级别字段解析

### Requirement: 用户可见的错误反馈
系统 SHALL 在列表为空时提供用户友好的提示信息。

#### Scenario: 已下载列表为空
- **WHEN** `getAll()` 返回空列表
- **THEN** 显示"暂无已下载的漫画"
- **THEN** 同时显示一个"重新扫描磁盘"按钮，引导用户修复数据

### Requirement: 详细的运行日志
系统 SHALL 在关键路径记录日志方便排查问题。

#### Scenario: 数据库加载
- **WHEN** `getAll()` 执行
- **THEN** 打印当前使用的下载路径
- **THEN** 打印数据库中的总记录数和解析成功/失败数

## MODIFIED Requirements

### Requirement: DownloadedGallery 数据模型
修改 `DownloadedGallery.fromJson` 以支持嵌套 `gallery` 包装结构和扁平结构。

### Requirement: DownloadedComic 标签解析
修改 `DownloadedComic.fromJson` 确保 `comicItem.tags` 被正确解析为 `List<String>`。

## REMOVED Requirements

无
