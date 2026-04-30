# PicaKeep 已下载漫画无法显示修复 v6 - Task List

## Task 1: 修复 `_getPath()` 路径读取逻辑
- [x] 1.1 将 `_getPath()` 从读取 SharedPreferences 改为直接读取 `appdata.settings[22]`
- [x] 1.2 移除对 SharedPreferences 的依赖（`_getPath` 中不再需要）
- [x] 1.3 确保默认路径回退逻辑正确（空路径或目录不存在时使用应用默认目录）
- [x] 1.4 添加打印日志输出当前使用的下载路径

## Task 2: 修复 `DownloadedGallery.fromJson` 兼容原项目 JSON 格式
- [x] 2.1 修改 `DownloadedGallery.fromJson` 为 factory 构造函数，检测是否有 `"gallery"` 包装键
- [x] 2.2 从 `json["gallery"]` 中提取 galleryTitle/subtitle/uploader/link/coverPath/tags 等字段
- [x] 2.3 从根级别提取 `json["size"]`
- [x] 2.4 正确解析 tags（原项目 Gallery.tags 是 `Map<String, List<String>>` 格式，使用已有 `_parseTags` 展开）
- [x] 2.5 保留对扁平格式的兼容（无 `gallery` 键时直接读根字段）

## Task 3: 修复 `DownloadedComic.fromJson` 标签解析
- [x] 3.1 添加 `_parseTagsList` 静态方法安全转换 tags 为 `List<String>`
- [x] 3.2 处理 tags 可能为 `List<dynamic>` 的情况

## Task 4: 改进 DownloadPage 空状态提示
- [x] 4.1 当列表为空时，添加"重新扫描磁盘"按钮
- [x] 4.2 点击按钮调用 `scanDirectoryForComics()` 并刷新列表
- [x] 4.3 显示当前使用的下载路径提示文字

## Task 5: 编译验证与功能测试
- [x] 5.1 `flutter build windows --debug` 编译成功
- [ ] 5.2 验证设置自定义路径后能正确读取已下载漫画 (需用户运行验证)
- [ ] 5.3 验证各类型漫画（Picacg/E-Hentai/JM/NHentai/Custom）均能正确显示 (需用户运行验证)
- [ ] 5.4 验证漫画封面能正确加载 (需用户运行验证)
- [ ] 5.5 验证点击漫画能进入阅读器 (需用户运行验证)

# Task Dependencies
- Task 2 和 Task 3 可并行执行
- Task 4 依赖 Task 1-3 完成
- Task 5 依赖 Task 1-4 全部完成
