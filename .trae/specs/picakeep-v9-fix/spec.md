# PicaKeep 阅读器工具栏修复 v9 Spec

## Why

阅读器工具栏存在两个关键问题：

1. **CustomSlider NaN 错误**：`BoxConstraints has NaN values` - 当漫画只有一页时（divisions=0 或 1），百分比计算产生除零错误
2. **工具栏功能未实现**：单击屏幕后，顶部和底部工具栏的所有功能（设置、收藏、自动翻页等）都无法正常工作

## What Changes

- **修复 CustomSlider**：添加除零保护，防止 NaN 值
- **修复工具栏依赖**：确保 StateController 正确注册和访问
- **验证工具栏功能**：检查所有按钮的 onPressed 回调是否正确连接

## Impact

- Affected code: `lib/components/custom_slider.dart`, `lib/pages/reader/`
- **BREAKING**: 无

## ADDED Requirements

### Requirement: CustomSlider 除零保护
系统 SHALL 确保 `CustomSlider` 在 divisions 为 0 或 1 时不会产生 NaN 值。

#### Scenario: 漫画只有一页
- **WHEN** 漫画只有一页时进入阅读器
- **THEN** CustomSlider 不会崩溃
- **THEN** 滑块显示为禁用状态或最小化

### Requirement: 工具栏功能正常
系统 SHALL 确保阅读器工具栏的所有按钮功能正常工作。

#### Scenario: 单击屏幕显示工具栏
- **WHEN** 用户单击阅读器屏幕
- **THEN** 工具栏正确显示
- **THEN** 所有按钮（设置、收藏、自动翻页等）可点击并触发正确功能

## MODIFIED Requirements

### Requirement: CustomSlider 组件
[完整修改] 修复 NaN 计算问题

## REMOVED Requirements

无

## Technical Notes

问题 1 的根因分析：
- `CustomSlider` 第 187 行: `constrains.maxWidth * ((value - widget.min) / (widget.max - widget.min))`
- 当 `widget.max == widget.min` 时（只有一页漫画），分母为 0
- 当 `divisions == 0` 时，第 125-126 行的 gap 计算也会产生问题

问题 2 的根因分析：
- 需要验证 `StateController.find<ComicReadingPageLogic>()` 返回的 logic 不为 null
- 需要验证 `showSettings` 函数能正确获取到 context
