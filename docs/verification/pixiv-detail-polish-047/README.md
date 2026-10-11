# 047 · Pixiv 详情细节离线验收记录

执行者：Codex，2026-10-09 17:36 +08:00。基线：`ca1ba3a`（V1.9.96），本轮改动保留在工作树；未提交、构建或安装应用，未调用真实账号接口。

最终一次整合运行覆盖14个测试文件，225/225通过，退出码0；7个修改文件定向分析无问题，退出码0。早期诊断日志用于保留定位过程，不累计为最终通过数。

## 可复跑命令

工作目录为项目根目录。SDK：`E:/SDK/flutter_windows_3.38.5-stable/flutter/bin`。

```powershell
flutter test --no-pub test/pixiv_detail_shell_test.dart test/pixiv_detail_gallery_collapse_test.dart test/pixiv_detail_panel_handoff_test.dart test/pixiv_detail_favorite_visibility_test.dart test/pixiv_online_detail_scroll_test.dart test/pixiv_follow_recommendations_sheet_test.dart test/pixiv_detail_session_test.dart test/pixiv_author_preview_bookmark_test.dart test/pixiv_follow_recommendations_test.dart test/pixiv_follow_recommendations_network_test.dart test/pixiv_comments_preview_test.dart test/pixiv_detail_feeds_test.dart test/pixiv_related_rounds_test.dart test/pixiv_detail_feed_settings_test.dart --reporter expanded

dart analyze lib/pages/online_comic/pixiv_detail_shell.dart lib/pages/online_comic/pixiv_online_detail_view.dart lib/pages/online_comic/pixiv_follow_recommendations_sheet.dart lib/pages/online_common/online_recommendation_card.dart test/pixiv_detail_panel_handoff_test.dart test/pixiv_online_detail_scroll_test.dart test/pixiv_follow_recommendations_sheet_test.dart

git diff --check
```

最终日志：[整合回归](<regressions-complete.log>)、[静态分析](<analyze-complete.log>)。`git diff --check`退出0；只有Git的LF转CRLF提示，无空白错误。

## 结果与证据

| 验收对象 | 观察结果 | 证据 |
| --- | --- | --- |
| 头像来源和时机 | 非空资料URL优先，否则作品URL；活跃多图缺源只补一次资料，作者作品/评论/底部feed未提前读取；失败显式重试、刷新隔离旧回包 | [入口测试](<../../../test/pixiv_online_detail_scroll_test.dart>)与整合日志 |
| 作者头连续性 | 单个可操作头，正常字号72dp；箭头→32dp头像→标题/作者两行→原下载；同一主ScrollPosition、同一头Element | [普通交界截图](<375-normal-last-page-handoff.png>) |
| 真实双向慢拖 | 375普通/375字号2/240暗色字号2/812横屏逐帧验证`top=min(galleryEnd-pixels,H-h)`，误差≤1dp；手指不松开时完成接入和反向；静止1秒无自动对齐 | [375帧](<anchor-375-scale1.json>)、[375大字帧](<anchor-375-scale2.json>)、[240帧](<anchor-240-scale2.json>)、[812帧](<anchor-812-scale1.json>) |
| 图像比例晚到 | 未知图暂高500dp，解析后变250/1000dp；仅局部correctBy几何差，作者头均保持840dp；同一Position且交界回调不重复 | [缩小记录](<late-ratio-250.json>)、[增长记录](<late-ratio-1000.json>) |
| 旋转/字号/减少动态效果 | 375×1000转812×375，图库内保持同图归一化位置、作者头随流时保持可见头坐标；字号变更不触发交界/读取；减少动态效果继续跟随真实滚动 | 整合日志中`rotation and text scale keep geometry`两项与四场景帧测试 |
| 下载 | 与基线核对`_galleryAction`实现一致；图标18、文字12、配色/圆角/padding/48dp最小触区、点击/长按及忙态保留；移动作者头进入浮动爱心区域时避让 | [Shell](<../../../lib/pages/online_comic/pixiv_detail_shell.dart>)、交界/面板/大字测试 |
| 页内作者发现 | 关注成功后在作者预览后、评论前显示；不弹modal、不自动滚动；正常375dp实测244dp，3个88dp方槽、contain、单外层横向列表 | [本地三比例截图](<inline/375-local-images-panel.png>)、[尺寸与0HTTP记录](<inline/375-local-images-panel.json>) |
| 发现生命周期 | 独立读写锁；关闭不pop且晚GET不复开；父控制器重挂恢复横向位置；专用面板→普通详情→子作品→返回/关闭保持数据；子作者session不因父route被覆盖而失效 | 入口与发现区测试、整合日志 |
| 异步关注快照 | 资料读期间成功关注/取消关注后，晚回资料不能覆盖已确认写入；双向Completer测试通过 | 入口测试`late avatar metadata cannot overwrite a confirmed follow write` |
| 大字/明暗/窄屏 | 240dp字号2状态错误可增高无overflow；375明暗字号1/2与812布局通过；关闭/关注/心形触区≥48dp；图片高度不随视口高增长 | [暗色大字](<inline/375-dark-scale2-viewport.png>)、[普通明色](<inline/375-light-scale1-viewport.png>) |
| 既有契约 | 单图/本地、阅读/下载/收藏，评论4条与offset、作者和跨作者feed独立、数量模式/原子轮次/120dp下拉、严格推荐解析及网络adapter回归通过 | 14组最终整合日志 |

截图使用真实CJK字体和Flutter `RenderRepaintBoundary.toImage`。作品/头像均为本地绘图或离线夹具，并有HTTP拒绝/缓存预置；这些截图不能证明真实Pixiv账号头像交付或设备上的手感。

## 实施范围与归因

生产修改四个文件：[详情Shell](<../../../lib/pages/online_comic/pixiv_detail_shell.dart>)、[在线入口](<../../../lib/pages/online_comic/pixiv_online_detail_view.dart>)、[关注发现](<../../../lib/pages/online_comic/pixiv_follow_recommendations_sheet.dart>)、[共享卡片](<../../../lib/pages/online_common/online_recommendation_card.dart>)；迁移/新增三个相应测试文件。原modal类已移除，文件名保留；没有两份独立关注逻辑。共享卡仅新增可选`compactImageFit`，默认cover保留。

图库使用已知自然extent的`SliverVariedExtentList`和精确总长delegate，仍懒构建并使用原图片provider、缓存和质量设置。唯一作者头绘制层在layout中读取位置，避免post-frame位置读数落后一帧。永久占位只计一次头高；延后详情仍保唯一GlobalKey树，按真实输入接入/停泊。

先前失败包括旧450dp/头部交换断言、把lazy详情key当行为状态、固定短拖距离、pending spinner下pumpAndSettle超时。分别修订为连续几何/回调状态/真实末端拖动/有限帧。真实缺口另包括迟到比例锚点、普通ScrollController跨detach不保横向位置、旧资料快照覆盖成功关注；均已修正并有对应测试。

仅验证离线受影响范围。设备包修订、真实头像请求和真实账号操作不在本轮授权内；后续设备验证需另行授权并按项目debug/profile与保数据规则执行。
