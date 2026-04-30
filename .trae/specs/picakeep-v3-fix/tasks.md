# PicaKeep 已下载不显示修复 v3 - Task List

## Task 1: 修复 Picacg JSON 检测与解析（comicItem + chapters）
- [x] 1.1 在 `_getComicFromJson` 中，增加 `data.containsKey("comicItem")` 检测分支（第一个 if）
- [x] 1.2 创建 `DownloadedComic` 并正确映射字段：comicItem.id→comicId, comicItem.title→title, comicItem.author→author, data["chapters"]→chapters, data["downloadedChapters"]→downloadedChapters, data["comicItem"]["tags"]→tagList

## Task 2: 修复 E-Hentai 解析（gallery 字段映射 + tags Map→List）
- [x] 2.1 `gallery.title` → `galleryTitle`，`gallery.subtitle` → `subtitle`
- [x] 2.2 `gallery.tags` 为 Map 时展开为 List（取所有 value）
- [x] 2.3 `gallery.link`、`gallery.uploader`、`gallery.coverPath` 正确映射

## Task 3: 修复 NHentai ID 前缀保留
- [x] 3.1 `NhentaiDownloadedComic.id` getter 直接返回 `comicID`，不做前缀截断
- [x] 3.2 移除 `id` getter 中任何前缀截断逻辑

## Task 4: 增强磁盘扫描（支持平铺图片目录）
- [x] 4.1 `scanDirectoryForComics` 能识别根目录直接包含图片的文件夹
- [x] 4.2 对平铺目录生成章节 `"第1章"`，标记为已下载
- [x] 4.3 避免重复调用 `entry.listSync()`，使用缓存的 `subEntries`

## Task 5: 实现 download_.txt 导入功能
- [x] 5.1 在 `DownloadManager` 中添加 `importFromTxt(String txtPath)` 方法
- [x] 5.2 在 `getAll()` 中，当 `db.total == 0` 且存在 `download_.txt` 时自动触发导入
- [x] 5.3 导入完成后重命名 txt 为 `.imported` 后缀避免重复导入

## Task 6: 编译验证
- [x] 6.1 `flutter build windows` 编译成功（picakeep.exe 已生成）
