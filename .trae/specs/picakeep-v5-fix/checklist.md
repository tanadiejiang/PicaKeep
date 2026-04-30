# PicaKeep 已下载不显示修复 v5 - Verification Checklist

## Task 1: 重写 _getComicFromJson 使用 ID 前缀判断类型
- [ ] 1.1 `_getComicFromJson` 使用 ID 前缀判断类型
- [ ] 1.2 保留 JSON key 判断作为 fallback
- [ ] 1.3 每种类型调用正确的工厂构造函数

## Task 2: 修复 Picacg JSON 解析
- [ ] 2.1 `DownloadedComic.fromJson` 能正确解析原项目 JSON
- [ ] 2.2 `chapters` 和 `downloadedChapters` 从根级别读取
- [ ] 2.3 `comicItem` 内部字段映射正确

## Task 3: 修复 E-Hentai id 问题
- [ ] 3.1 手动构造的 `DownloadedGallery` 使用正确的 `id`
- [ ] 3.2 `getDirectory()` 查询使用的 `id` 与数据库一致

## Task 4: 修复 JM 解析
- [ ] 4.1 `DownloadedJmComic.fromMap` 能正确解析原项目 JSON
- [ ] 4.2 `comic` 字段的嵌套结构正确处理

## Task 5: 修复 getAll() 初始化顺序
- [ ] 5.1 `getAll()` 中 `_db == null` 时先获取 `path`
- [ ] 5.2 数据库打开前 `path` 已设置

## Task 6: 增强错误日志
- [ ] 6.1 每条记录的解析结果有日志记录
- [ ] 6.2 `getAll()` 记录总数和成功/失败数量

## Task 7: 编译验证
- [ ] 7.1 `flutter build windows` 编译成功
- [ ] 7.2 应用运行时已下载列表显示漫画
