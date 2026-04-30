# Tasks

- [ ] Task 1: 修复 main.dart 数据库初始化
  - 在 main() 中添加 `HistoryManager().init()` 和 `LocalFavoritesManager().init()` 调用
  - 验证编译通过

- [ ] Task 2: 复制 SliverAppbar 组件
  - 从 PicaComic 复制 `components/appbar.dart` 中的 `SliverAppbar` 相关代码
  - 创建 `lib/components/appbar.dart` 或将代码添加到 `components.dart`
  - 确保使用正确的 import（translations, ui_mode 等）

- [ ] Task 3: 更新 download_page.dart 使用自定义 SliverAppbar
  - 替换 Flutter 原生 SliverAppBar 为自定义 `SliverAppbar`
  - 保持所有功能不变（搜索、排序、多选等）
  - 编译验证

- [ ] Task 4: 测试验证
  - 运行应用进入已下载页面
  - 点击漫画进入阅读器，确保不再报 LateInitializationError
  - 验证 UI 样式与原项目一致

# Task Dependencies

- Task 2 依赖 Task 1（需先了解 components.dart 结构）
- Task 3 依赖 Task 2（需要 SliverAppbar 组件可用）
- Task 4 依赖 Task 1 和 Task 3（修复完成后测试）
