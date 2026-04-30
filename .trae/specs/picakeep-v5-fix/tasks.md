# PicaKeep 已下载不显示修复 v5 - Task List

## Task 1: 重写 _getComicFromJson 使用 ID 前缀判断类型
- [ ] 1.1 将 `_getComicFromJson` 的类型判断逻辑改为与原项目一致的 ID 前缀判断
- [ ] 1.2 保留 JSON key 判断作为 fallback（用于处理非标准数据）
- [ ] 1.3 确保每种类型调用正确的 fromJson/fromMap 工厂构造函数

## Task 2: 修复 Picacg JSON 解析
- [ ] 2.1 验证 `DownloadedComic.fromJson` 能正确解析原项目的 JSON 结构
- [ ] 2.2 确保 `chapters` 和 `downloadedChapters` 从根级别读取
- [ ] 2.3 处理 `comicItem` 内部字段的映射

## Task 3: 修复 E-Hentai id 问题
- [ ] 3.1 修改 `DownloadedGallery` 的手动构造分支，正确设置 `id`
- [ ] 3.2 确保 `getDirectory()` 查询时使用的 `id` 与数据库一致
- [ ] 3.3 添加 `id` 参数到手动构造的 `DownloadedGallery`

## Task 4: 修复 JM 解析
- [ ] 4.1 正确处理原项目存储的 `{"comic": JmComicInfo.toJson()}` 结构
- [ ] 4.2 验证 `DownloadedJmComic.fromMap` 能正确解析

## Task 5: 修复 getAll() 初始化顺序
- [ ] 5.1 确保 `getAll()` 中 `_db == null` 时先获取 `path` 再打开数据库
- [ ] 5.2 将 `_initDb()` 改为异步或确保 `path` 已设置

## Task 6: 增强错误日志
- [ ] 6.1 在 `_getComicFromJson` 中记录每条记录的解析结果
- [ ] 6.2 在 `getAll()` 中记录总数和成功/失败数量

## Task 7: 编译验证
- [ ] 7.1 `flutter build windows` 编译成功
- [ ] 7.2 运行应用验证已下载列表能显示漫画
