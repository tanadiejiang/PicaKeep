# Tasks

- [ ] Task 1: 修复 SmoothCustomScrollView 的 ScrollController 问题
  - 检查 scrollable.dart 中 ScrollController 的使用
  - 修复 ScrollController 未附加到 scroll view 的问题
  - 编译验证

- [ ] Task 2: 修复 "我" 页面已下载组件数量显示
  - 查看 me_page.dart 中已下载组件的实现
  - 添加漫画数量显示（如"已下载 (12)"）
  - 编译验证

- [ ] Task 3: 修复漫画大小显示格式
  - 查看 download_page.dart 中 size 显示逻辑
  - 确保格式与原项目一致（如"123.45 MB"）
  - 编译验证

- [ ] Task 4: 测试验证
  - 运行应用进入阅读器
  - 验证无 ScrollController 错误
  - 验证 UI 显示正确

# Task Dependencies

- Task 2 和 Task 3 可并行执行
- Task 4 依赖 Task 1、2、3
