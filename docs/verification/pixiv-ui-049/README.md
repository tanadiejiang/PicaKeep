# 049 · Pixiv推荐作者布局与图库固定收藏显隐

状态：源码与离线验收完成（2026-10-09 21:51 +08:00）；17套、284项测试全部通过，8个文件静态分析 No issues found，三项命令退出码均为0。真实设备未验，049计划按原约束标为部分完成。所有截图均为离线 Flutter 渲染，不是真机、CDN 或真实账号验收。

## 实际改动

- [推荐区](../../../lib/pages/online_comic/pixiv_follow_recommendations_sheet.dart)：作者项宽度 `W-32`、三张正方形槽 `(W-48)/3`、两个 8dp 间隙，使用 `BoxFit.cover`。作者项取消额外横向 padding 与卡片边框，背景使用主题 surface；相邻作者间 24dp 间隔居中绘制 1dp、`outlineVariant` 55% 透明度分隔线。
- 关注按钮普通字号可见胶囊为 32dp 高，Material padded 命中区至少 48dp；按“处理中”测量宽度，三态和大字独立行均保持稳定宽度。240/375/812 宽度、字号 2 的三态文字适配有真实 widget 矩形断言。
- [详情壳层](../../../lib/pages/online_comic/pixiv_detail_shell.dart)：只有 `galleryCollapsible && !panelOpen && naturalHeaderTop >= dockTop`，即作者条实际停泊时，绕过旧作者边界和停泊 exclusion band 显示已有大爱心。提前 24dp 的详情 handoff 不会提前隐藏；未停泊状态完全保留原显隐表达式。
- 大爱心仍是同一个固定悬浮控件，`right:16`、原 bottom 算法、56dp 外圈、28dp 图标、颜色、阴影、忙态、长按和收藏反馈均未改；没有新增底部留白、移动下载按钮或修改 048 的滚动／面板状态机。
- 原图、比例 360 框 URL、master 路径、回退和缓存策略不变。`cover` 的边缘裁切只影响推荐方槽展示，不影响作品详情和下载。

## 证据入口

| 场景 | PNG | 几何／隔离记录 |
| --- | --- | --- |
| 真实本地竖图、横图、方图满槽 | [推荐预览](follow/375-local-images-panel.png) | [JSON](follow/375-local-images-panel.json) |
| 横向相邻作者的淡分隔 | [相邻作者](follow/375-local-images-divider-panel.png) | [JSON](follow/375-local-images-divider-panel.json) |
| 浅色、375宽、字号1 | [浅色推荐区](follow/375-light-scale1-panel.png) | [JSON](follow/375-light-scale1-panel.json) |
| 深色、375宽、字号2 | [大字推荐区](follow/375-dark-scale2-panel.png) | [JSON](follow/375-dark-scale2-panel.json) |
| 图库中间页大爱心 | [看图中](gallery/middle-page.png) | [JSON](gallery/middle-page.json) |
| 详情已提前挂载、作者条仍停泊 | [提前交接](gallery/early-handoff-docked.png) | [JSON](gallery/early-handoff-docked.json) |
| 程序滚动超过停泊位，保留下载点击 | [程序滚动](gallery/programmatic-undock-download.png) | [JSON](gallery/programmatic-undock-download.json) |
| 短图库顶部正常显示 | [短图库](gallery/short-gallery-top.png) | [JSON](gallery/short-gallery-top.json) |
| 短图库顶部真实交集，保留原下载保护 | [短图库交集](gallery/short-gallery-top-overlap-download.png) | [JSON](gallery/short-gallery-top-overlap-download.json) |

本地图片上出现的彩色细边是画入 fixture 素材的边框，不是 `contain` 背景带。灰色无图预览是原生产占位；不声称这些图来自 Pixiv CDN。

375dp、字号1记录：作者项343dp；方槽109×109、起点x=16/133/250，最后一张止于359，左右各16dp；关注胶囊57.5×32，命中框57.5×48。400×800图库记录：大爱心布局框为 `(328,664,56,56)`；提前交接时pixels716.667、实际停泊边界738.667，已挂载详情但仍显示爱心。

截图由生产组件、本地 MemoryImage／缓存 fixture 和 `RenderRepaintBoundary.toImage` 产生。图库 JSON 分别记录固定布局框与受 AnimatedScale 影响的绘制框；隐藏时后者可为0×0，但布局坐标没有移动。新图库和推荐 fixture 的 HTTP 尝试数为0。

## 回归与过程记录

[最终合并回归](regressions-final.log)：17套、284项全部通过（退出码0，无异常／警告）。[最终静态分析](analyze-final.log)：8个变动文件 No issues found（退出码0）。[Diff检查](diff-check-final.log)：退出码0，只有Git现有LF/CRLF转换提示，无空白错误。覆盖推荐区、关注发现、作者收藏、共享收藏、正文边界、图库折叠、面板交接、048动效、详情会话、评论预览、独立feed和推荐轮次。新增图库16项和原motion20项也在 [独立物理停泊回归](gallery-motion-physical-dock-final.log) 中36/36通过；未修改旧下载点击点。

- [首次合并日志](regressions-final-first.log) 保留首次发现的真实程序滚动遮下载问题及旧共享收藏夹具缺失相关依赖的问题，不抹去失败。
- [共享收藏隔离验证](shared-bookmark-isolated.log)：16项全部通过，退出码0。仅向旧夹具注入4个空推荐加载器，避免无关生产网络／原生cookie store初始化；收藏断言未削弱。
- [第一次静态分析](analyze.log) 保留两条新增测试 lint 提示；修正并完成物理停泊分支收窄后的 [最终静态分析](analyze-final.log) 为8个文件 No issues found、退出码0。
- [图库第一次](gallery-tests-first.log)、[第二次](gallery-tests-second.log)、[第三次](gallery-tests-third.log)、[第四次](gallery-tests-fourth.log) 日志记录新测试的观察方式修正；第四次13项通过，最终另增3项实际交集保护。

048回归截图输出改到本轮独立目录，旧048归档未覆盖；两个原测试的逻辑和旧下载点击位置不变。

## 已验证经验与边界

1. **图库显隐不能仅看handoff标记。** 提前24dp已挂载详情但仍物理停泊；程序滚动也可能越过停泊位却未handoff。只有实际 `G-pixels >= H-h` 可用于停泊豁免。`!handoff` 和笼统 `atTop` 例外都被碰撞测试否决；不通过移动按钮或改旧测试点击点绕开。
2. **固定坐标与绘制缩放分开测量。** `tester.getRect` 包含 paint transform；隐藏后 scale0 的绘制框不能用来判断悬浮锚点是否移动，位置应测动画上游的布局框。
3. **完整挂载树不等于可见 Finder 结果。** 提前handoff的详情还在viewport下方，需 `skipOffstage:false` 并联合transition和实际停泊几何判断；实际语义树需遍历SemanticsNode，不能只找仍保留的Semantics Widget。
4. **真实反向拖动需跨过slop再发送ScrollUpdate。** 不把只启动手势的首个move当作真实反向交接。
5. **预览URL规则不扩展。** 360框不等于CDN实际返回1200像素；目录与后缀规则、真实网络成功率和设备表现仍是独立验证边界。

本轮没有构建、安装、清应用数据／SDK缓存、升级依赖或真实账号写入。真实设备版本、Pixiv CDN、登录账号与触控手感均未验。遵循 [049计划](../../../Z-plan/新需求-主线-第十九轮/049-修复-Pixiv页内关注作者推荐图片尺寸与图库收藏按钮显隐.md)，计划不得因离线通过而标为全部已完成。

## 最终复现命令

现有SDK不升级；以下命令只有离线测试、分析和diff检查，不构建或安装应用：

```powershell
$flutter = 'E:\SDK\flutter_windows_3.38.5-stable\flutter\bin\flutter.bat'
$tests = @(
  'test/pixiv_detail_shell_test.dart',
  'test/pixiv_detail_gallery_collapse_test.dart',
  'test/pixiv_detail_panel_handoff_test.dart',
  'test/pixiv_detail_favorite_visibility_test.dart',
  'test/pixiv_online_detail_scroll_test.dart',
  'test/pixiv_follow_recommendations_sheet_test.dart',
  'test/pixiv_detail_session_test.dart',
  'test/pixiv_author_preview_bookmark_test.dart',
  'test/pixiv_follow_recommendations_test.dart',
  'test/pixiv_follow_recommendations_network_test.dart',
  'test/pixiv_comments_preview_test.dart',
  'test/pixiv_detail_feeds_test.dart',
  'test/pixiv_related_rounds_test.dart',
  'test/pixiv_detail_feed_settings_test.dart',
  'test/pixiv_detail_motion_test.dart',
  'test/pixiv_gallery_favorite_049_test.dart',
  'test/pixiv_detail_bookmark_shared_test.dart'
)
& $flutter test --no-pub @tests --reporter expanded
$changed = @(
  'lib/pages/online_comic/pixiv_follow_recommendations_sheet.dart',
  'lib/pages/online_comic/pixiv_detail_shell.dart',
  'test/pixiv_follow_recommendations_sheet_test.dart',
  'test/pixiv_online_detail_scroll_test.dart',
  'test/pixiv_detail_motion_test.dart',
  'test/pixiv_detail_panel_handoff_test.dart',
  'test/pixiv_gallery_favorite_049_test.dart',
  'test/pixiv_detail_bookmark_shared_test.dart'
)
& $flutter analyze --no-pub @changed
git diff --check
```

