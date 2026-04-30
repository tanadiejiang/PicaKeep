# PicaKeep 已下载不显示问题修复 v4 Spec

## Why

经过对 `download.dart`、`download_model.dart`、`app_settings.dart` 和 `download_page.dart` 的完整代码审查，发现以下堆叠的关键根因：

1. **`getAll()` 当 `_db` 为 null 时不自动初始化** — `app_settings.dart` 保存新路径后调用 `dispose()` 清空 `_db`，但从未调用 `init()` 重新初始化。后续 `getAll()` 调用 `_db!.select()` 抛出 NullError，被 catch 吞掉返回 `[]`
2. **`_getComicFromJson` 中 `comic.id` getter 触发 `getDirectory()` → 死锁** — `getDirectory()` 调用 `_db!.select()` 但 `directory` 参数为 null 时仍会触发 `_directoryCache` miss → DB query → 再次触发 `_getComicFromJson` → 死锁或 null error
3. **Picacg chapters 是 Map 不是 List** — 你的数据中 `chapters` 是 `{"0": {"title": "...", "count": 10}, "1": {...}}` 结构，但代码假设它是 `List`，导致解析失败
4. **E-Hentai 检测顺序错误** — 你的 JSON 同时有 `galleryTitle` 和 `gallery` 键，但 `galleryTitle` 先匹配，用 `fromJson(data)` 而非手动构造的对象，字段名错配导致解析失败
5. **NHentai `id` 存回 db 时为纯数字，与存储的 `id` 前缀不一致** — `NhentaiDownloadedComic.id` = `comicID`（如 `"nhentai408727"`），但 `_addToDb` 用的 `item.id` = `"nhentai408727"`，这应该是正确的...

## What Changes

- `getAll()` 增加 `_db == null` 时自动调用 `init()` 的检查
- `_getComicFromJson` 增加 `if (_db == null) return null;` 保护，防止在 getter 链中调用时死锁
- 修复 Picacg chapters 解析：支持 Map 结构，提取 `values.map((e) => e["title"] ?? "...")`
- 修复 E-Hentai 检测顺序：`gallery`（手动构造）先于 `galleryTitle`（fromJson），且 `gallery` 分支设置 `id` getter 备用
- 移除 txt 导入逻辑（数据在 `download.db` 中不是 `download_.txt` 中）

## Impact

- Affected code: `lib/foundation/download.dart`

## ADDED Requirements

### Requirement: getAll() 自动初始化
系统 SHALL 在 `_db` 为 null 时自动调用 `init()` 重新初始化。

#### Scenario: _db 为 null
- **WHEN** `getAll()` 被调用且 `_db == null`
- **THEN** 调用 `await init()` 重新初始化（同步版本用 `_initDb()`）
- **THEN** 然后执行正常的数据库查询

### Requirement: _getComicFromJson 防止死锁
系统 SHALL 在 `_db` 为 null 时直接返回 null，不触发 getter 链。

#### Scenario: 在 getter 链中被调用
- **WHEN** `comic.id` getter 被调用，而 `directory == null`
- **THEN** `_getComicFromJson` 检测到 `_db == null` → 返回 null，不触发 `getDirectory()` 的 DB 查询

### Requirement: Picacg chapters Map 解析
系统 SHALL 支持 chapters 为 Map 结构的 Picacg 数据。

#### Scenario: Picacg chapters 是 Map
- **WHEN** `data["chapters"]` 是 `Map` 类型
- **THEN** 提取所有 value 的 `title` 字段组成章节列表

### Requirement: E-Hentai gallery 检测优先
系统 SHALL 在检测到 `gallery` 键时优先使用手动构造的 `DownloadedGallery`。

#### Scenario: E-Hentai 数据同时有 galleryTitle 和 gallery
- **WHEN** JSON 包含 `gallery` 键
- **THEN** 使用手动构造（从 `g["title"]` 等提取字段），忽略 `galleryTitle` 分支

## REMOVED Requirements

### Requirement: download_.txt 导入
**Reason**: 数据在 `download.db` 中，不在 `download_.txt` 中，`download_.txt` 只是导出文本
**Migration**: 移除 `importFromTxt` 方法，移除 `getAll()` 中的 txt 检查
