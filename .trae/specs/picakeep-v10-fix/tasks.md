# Tasks

- [x] Task 1: 修复阅读器图片加载问题
  - 检查 `ReadingData.loadEp()` 方法是否正确返回所有图片
  - 检查 `ComicReadingPage.loadInfo()` 加载逻辑
  - 确保漫画所有页面被正确加载和显示
  - 编译验证

- [x] Task 2: 修复工具栏按钮功能
  - 检查 `showSettings` 调用链
  - 检查 `StateController.find<ComicReadingPageLogic>()` 返回值
  - 验证所有工具栏按钮回调正确连接
  - 编译验证

- [x] Task 3: 修复数据库扫描空数据问题
  - 检查 `DownloadManager` 扫描逻辑
  - 添加空数据过滤
  - 确保只写入有效漫画数据
  - 编译验证

- [x] Task 4: 修复扫描后 UI 刷新问题
  - 检查 `DownloadPageLogic` 状态更新
  - 在扫描完成后调用 `logic.reload()`
  - 确保页面立即刷新显示
  - 编译验证

- [x] Task 5: 修复已下载数量显示问题
  - 检查 `me_page.dart` 中数量获取逻辑
  - 确保数量显示与原项目一致
  - 添加实时更新机制
  - 编译验证

- [x] Task 6: 综合测试验证
  - 运行 flutter analyze
  - 确保无编译错误

# Task Dependencies

- Task 1、2、3、4、5 可并行执行
- Task 6 依赖 Task 1、2、3、4、5
