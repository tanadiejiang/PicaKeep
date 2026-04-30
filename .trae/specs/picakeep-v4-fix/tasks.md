# PicaKeep 已下载不显示修复 v4 - Task List

## Task 1: 修复 getAll() 自动初始化
- [x] 1.1 在 `getAll()` 开头增加 null 检查：`if (_db == null) { _initDb(); }`
- [x] 1.2 移除 txt 导入相关代码

## Task 2: 修复 _getComicFromJson 防止死锁
- [x] 2.1 ~~`_getComicFromJson` 增加 `if (_db == null)` 检查~~ — 注：free function 无法访问 `_db`，通过 Task 1 的 `getAll()` null 检查来兜底

## Task 3: 修复 Picacg chapters Map 解析
- [x] 3.1 在 `data["chapters"]` 解析部分，增加 Map 类型支持
- [x] 3.2 从 Map 的 value 中提取 title 字段

## Task 4: 修复 E-Hentai 检测顺序（gallery 优先）
- [x] 4.1 移动 `data.containsKey("gallery")` 分支，使其在 `data.containsKey("galleryTitle")` 之前
- [x] 4.2 保留 `gallery` 分支的手动构造逻辑

## Task 5: 移除 txt 导入逻辑
- [x] 5.1 删除 `importFromTxt()` 方法
- [x] 5.2 从 `getAll()` 中移除 `download_.txt` 检查的代码块

## Task 6: 编译验证
- [x] 6.1 `flutter build windows` 编译成功（picakeep.exe 已生成）
