# PicaKeep 已下载不显示修复 v3 - Verification Checklist

## Task 1: Picacg JSON 检测与解析
- [x] 1.1 `_getComicFromJson` 中有 `data.containsKey("comicItem")` 检测（第一个分支）
- [x] 1.2 `comicItem.id` → `comicId`，`comicItem.title` → `title`，`comicItem.author` → `author`
- [x] 1.3 `data["chapters"]` → `chapters`（章节列表），`data["downloadedChapters"]` → `downloadedChapters`
- [x] 1.4 `data["comicItem"]["tags"]` → `tagList`

## Task 2: E-Hentai 解析修复
- [x] 2.1 `gallery.title` → `galleryTitle`，`gallery.subtitle` → `subtitle`
- [x] 2.2 `gallery.tags` 为 Map 时展开为 List
- [x] 2.3 `gallery.link`、`gallery.uploader`、`gallery.coverPath` 正确映射

## Task 3: NHentai ID 前缀保留
- [x] 3.1 `NhentaiDownloadedComic.id` getter 直接返回 `comicID`，不做前缀截断
- [x] 3.2 `id` getter 不包含 `replaceFirst`、`substring` 等截断逻辑

## Task 4: 磁盘扫描平铺目录
- [x] 4.1 `scanDirectoryForComics` 能识别根目录直接包含图片的文件夹
- [x] 4.2 对平铺目录生成章节 `"第1章"`，标记为已下载

## Task 5: download_.txt 导入
- [x] 5.1 `DownloadManager` 有 `importFromTxt()` 方法
- [x] 5.2 `getAll()` 初始化时自动检测并导入 txt（db为空时先检查txt）
- [x] 5.3 txt 中每条记录正确解析 7 个 Tab 分隔字段

## 编译验证
- [x] 6.1 `flutter build windows` 编译成功（picakeep.exe 已生成）
