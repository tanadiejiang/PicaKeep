# PicaKeep 已下载不显示修复 v4 - Verification Checklist

## Task 1: getAll() 自动初始化
- [x] 1.1 `getAll()` 开头有 `_db == null` 检查和 `_initDb()` 调用
- [x] 1.2 `getAll()` 中无 `download_.txt` 相关代码

## Task 2: _getComicFromJson 防止死锁
- [x] 2.1 ~~`_getComicFromJson` 检查~~ — 通过 `getAll()` 的 `_initDb()` 调用来兜底

## Task 3: Picacg chapters Map 解析
- [x] 3.1 chapters 解析支持 Map 类型（`{"0": {...}, "1": {...}}`）
- [x] 3.2 从 Map 的 value 中提取 title 字段

## Task 4: E-Hentai 检测顺序
- [x] 4.1 `gallery` 分支在 `galleryTitle` 分支之前
- [x] 4.2 `gallery` 分支使用手动构造

## Task 5: txt 导入移除
- [x] 5.1 `importFromTxt()` 方法已删除
- [x] 5.2 `getAll()` 中无 `download_.txt` 相关代码

## 编译验证
- [x] 6.1 `flutter build windows` 编译成功（picakeep.exe 已生成）
