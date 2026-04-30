# PicaKeep 已下载漫画无法显示修复 v6 - Checklist

## 下载路径
- [x] `_getPath()` 直接从 `appdata.settings[22]` 读取路径
- [x] 用户通过设置界面浏览选择的路径被正确使用
- [x] 路径为空时回退到应用默认 download 目录
- [x] 控制台打印当前使用的下载路径

## E-Hentai 解析
- [x] `DownloadedGallery.fromJson` 能解析 `{"gallery": {...}, "size": ...}` 格式
- [x] `DownloadedGallery.fromJson` 能解析扁平 `{"galleryTitle": ..., "subtitle": ..., ...}` 格式（兼容）
- [x] 正确解析 `gallery.tags`（Map<String, List<String>> -> 扁平 List<String>）
- [x] `id` 从 `gallery.link` 正确提取

## Picacg 解析
- [x] `DownloadedComic.fromJson` 通过 `_parseTagsList` 安全转换 tags 为 `List<String>`
- [x] `chapters` 从根级别和 `comicItem.chapters` 都能正确读取

## 用户可见改进
- [x] 空列表时显示"重新扫描磁盘"按钮
- [x] 空列表时显示当前下载路径
- [x] 点击"重新扫描磁盘"能正确扫描并刷新列表

## 编译
- [x] `flutter build windows --debug` 编译无错误
- [x] `flutter analyze` 无 error 级别问题
