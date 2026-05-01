# PicaKeep UI样式与功能修复 Spec

## Why

当前 PicaKeep 项目存在多个 UI 样式和功能问题，与原项目 PicaComic 不一致，需要全面修复以确保用户体验与原项目一致。

## What Changes

- 修复"我"页面样式，使其与原项目一致
- 修复历史记录功能，确保阅读后能正确保存和显示
- 修复已下载页面封面显示异常和文件路径问题
- 修复已下载页面加载逻辑，启动时直接读取本地缓存
- 完善"收藏"页面功能
- 实现顶部搜索实时搜索功能
- 修复阅读器翻页方式
- 修复下载页PC端展示效果
- 修复阅读器工具栏按钮功能

## Impact

- Affected specs: "我"页面、已下载页面、收藏页面、阅读器、搜索功能
- Affected code:
  - `lib/pages/me_page.dart`
  - `lib/pages/download_page.dart`
  - `lib/pages/history_page.dart`
  - `lib/pages/favorites/`
  - `lib/pages/reader/`
  - `lib/pages/local_search_page.dart`
  - `lib/foundation/history.dart`
  - `lib/foundation/download.dart`

---

## ADDED Requirements

### Requirement: "我"页面样式与原项目一致

"我"页面应完整复制原项目 PicaComic 的样式和布局逻辑。

#### Scenario: 窄屏布局
- **WHEN** 屏幕宽度 <= 600px
- **THEN** 垂直布局：历史记录 → 已下载 → 图片收藏 → 工具

#### Scenario: 宽屏布局
- **WHEN** 屏幕宽度 > 600px
- **THEN** 左右两栏布局：左侧(历史记录 + 已下载)，右侧(图片收藏 + 工具)

#### Scenario: 历史记录卡片
- **WHEN** 存在历史记录
- **THEN** 显示水平滚动的封面缩略图列表
- **THEN** 点击封面可跳转至漫画详情

#### Scenario: "已下载"卡片
- **WHEN** 显示"已下载"卡片
- **THEN** 显示"共 @a 部漫画"格式的描述

---

### Requirement: 历史记录功能完整

系统 SHALL 确保阅读漫画后能正确保存历史记录，并在"我"页面和历史记录页面正确显示。

#### Scenario: 阅读保存历史
- **WHEN** 用户完成阅读漫画
- **THEN** 阅读器退出时自动保存历史记录
- **THEN** 更新 `HistoryManager` 中的数据

#### Scenario: "我"页面显示历史
- **WHEN** "我"页面加载
- **THEN** 调用 `HistoryManager().getRecent()` 获取最近阅读
- **THEN** 显示封面和标题缩略图

#### Scenario: 历史记录页面
- **WHEN** 打开历史记录页面
- **THEN** 使用网格布局展示漫画卡片
- **THEN** 支持搜索和清除功能

---

### Requirement: 已下载页面封面正常显示

系统 SHALL 确保已下载漫画的封面能正确显示，且文件路径异常时不会崩溃。

#### Scenario: 封面加载
- **WHEN** 加载已下载漫画封面
- **THEN** 使用 `DownloadManager().getCover(id)` 获取本地文件路径
- **THEN** 如果文件不存在，显示占位图标

#### Scenario: 文件路径异常处理
- **WHEN** 漫画目录名包含特殊字符（日文、中文、特殊符号等）
- **THEN** 在 `getDirectory()` 方法中对目录名进行 `sanitizeFileName` 处理
- **THEN** 将特殊字符替换为下划线

#### Scenario: 图片加载异常处理
- **WHEN** 调用 `getImage()` 或目录不存在
- **THEN** 捕获 `PathNotFoundException`
- **THEN** 返回友好错误信息而非崩溃

---

### Requirement: 已下载页面加载逻辑

系统 SHALL 确保启动时直接读取本地缓存的漫画数据。

#### Scenario: 启动加载
- **WHEN** 应用启动
- **THEN** `DownloadPage` 初始化时直接调用 `DownloadManager().getAll()`
- **THEN** 显示加载指示器直到数据就绪

#### Scenario: 刷新功能
- **WHEN** 用户点击刷新按钮
- **THEN** 重新加载漫画列表
- **THEN** 保持排序和筛选状态

---

### Requirement: 收藏页面功能完善

系统 SHALL 实现完整的本地收藏功能，包括文件夹管理和漫画收藏。

#### Scenario: 收藏夹管理
- **WHEN** 用户在收藏页面
- **THEN** 可创建/删除/重命名收藏夹
- **THEN** 可在收藏夹间移动漫画

#### Scenario: 漫画收藏
- **WHEN** 用户添加漫画到收藏
- **THEN** 保存漫画信息到 SQLite 数据库
- **THEN** 在收藏页面网格展示

---

### Requirement: 顶部搜索实时搜索

系统 SHALL 实现全局搜索的实时搜索功能。

#### Scenario: 搜索触发
- **WHEN** 用户在搜索框输入内容
- **THEN** 每次按键后立即搜索（去抖动 300ms）
- **THEN** 搜索范围：漫画名、作者、标签

#### Scenario: 搜索结果展示
- **WHEN** 显示搜索结果
- **THEN** 使用与"已下载"页面相同的网格布局
- **THEN** 显示封面、标题、作者、来源标签

---

### Requirement: 阅读器翻页方式完整

系统 SHALL 支持与原项目一致的翻页方式。

#### Scenario: 翻页方式
- **WHEN** 阅读器加载
- **THEN** 支持以下翻页方式：
  - `leftToRight` - 左至右
  - `rightToLeft` - 右至左
  - `topToBottom` - 上至下
  - `topToBottomContinuously` - 从上至下连续滚动
  - `twoPage` - 双页
  - `twoPageReversed` - 双页反向

#### Scenario: 工具栏按钮
- **WHEN** 点击工具栏按钮
- **THEN** 章节切换按钮正常工作
- **THEN** 自动翻页按钮正常工作
- **THEN** 设置按钮打开阅读设置

---

### Requirement: 下载页PC端展示效果

系统 SHALL 确保PC端下载页面的展示效果与原项目一致。

#### Scenario: PC端详情视图
- **WHEN** 在PC端点击漫画
- **THEN** 显示侧边栏（`showSideBar`）而非对话框
- **THEN** 侧边栏宽度 400px
- **THEN** 显示章节网格

#### Scenario: 章节列表
- **WHEN** 显示章节列表
- **THEN** 网格布局，每项 4:1 宽高比
- **THEN** 已下载章节高亮显示

---

### Requirement: 阅读器工具栏完整功能

系统 SHALL 确保阅读器的所有工具栏按钮都能正常工作。

#### Scenario: 工具栏按钮
- **WHEN** 阅读器显示
- **THEN** 底部工具栏：章节切换滑块、自动翻页、收藏图片、章节列表、保存、分享
- **THEN** 顶部工具栏：返回、标题、设置

#### Scenario: 设置按钮
- **WHEN** 点击设置按钮
- **THEN** 打开阅读设置面板
- **THEN** 可修改翻页方式、预加载数量等

---

## MODIFIED Requirements

### Requirement: MePage 布局重构

**原需求**: 使用简单的垂直布局

**新需求**: 根据屏幕宽度动态切换单栏/双栏布局，与原项目 PicaComic 保持一致

### Requirement: HistoryManager 保存逻辑

**原需求**: 同步保存

**新需求**: 确保 `saveReadHistory()` 方法正确调用，且 `updateMePage` 参数能正确触发"我"页面更新

### Requirement: DownloadManager 路径处理

**原需求**: 直接使用数据库中的 directory 字段

**新需求**: 对 directory 进行 `sanitizeFileName` 处理，确保特殊字符被正确替换

---

## REMOVED Requirements

无

---

## Technical Implementation Notes

### 文件路径处理

```dart
static String _sanitizeFileName(String name) {
  return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
}
```

### 历史记录保存

```dart
void _updateHistory(ComicReadingPageLogic? logic, bool updateMePage) {
  // ... 更新历史逻辑
  HistoryManager().saveReadHistory(history!, updateMePage);
}
```

### 实时搜索

```dart
Timer? _debounceTimer;
void onSearchChanged(String keyword) {
  _debounceTimer?.cancel();
  _debounceTimer = Timer(Duration(milliseconds: 300), () {
    _performSearch(keyword);
  });
}
```
