# 043 · 多页先看图，详情面板按两种路径展开

用户用五张参考图说明：“多页先完整看图；真实滚到末页后稍微换位接普通详情；头像旁按钮可提前上折成只到评论的面板；点击露出的图片与收起按钮是同一个关闭功能；回到看图后正常再向下滑，才能再次进入完整详情和相关推荐。”本次按该顺序替代041把图库缩成有限首图封面的旧误实现。代码、离线widget与Flutter引擎截图验证完成；用户报告已完成实机验收，基础行为无其他问题。作者栏随图库移动的位置/触感细节依用户要求留到明天微调；本次源码仍保持当前固定入口，不把该项记为已实现。

## 交互契约

- **先看图。** 在线多页作品默认只挂载纵向自然比例的所有图片、图片序号、顶部工具和底部紧凑作者入口。作品详情、作者补充内容、评论、相关推荐在这一刻不构建也不自动请求。单图及本地旧Shell的默认开关为false，原详情流保持兼容。
- **末页自然接详情。** 只有当前活动作品的真实向下拖动／惯性抵达图库末端，才创建普通详情Sliver流。使用原主ScrollController；在第一次handoff对作者标题做一次受界限的180ms局部对齐，之后不在任意idle反复snap。末页、普通详情、作者作品、四条评论、相关推荐成为完整可连续向下滚动的普通路径。实际截图的像素位置925、标题距安全顶450、计数3/3；详情已读评论一次、相关推荐当时仍为0。
- **头像按钮提前展开专用面板。** 看图中头像旁的48dp箭头打开75%视口圆角、主题色详情面板。它可滚到四条评论，但明确不包含相关推荐。使用独立面板ScrollPosition；评论同一个SliverMainAxisGroup临时迁入，不重复创建全局key、不重读根评论。面板打开时author/detail主体位于图片背景之后；收藏、下载、忙状态票据仍共用单一原控件。测试打开后评论请求1、相关推荐0，面板高750dp。
- **收起按钮和点图等价。** 面板下箭头和点露出的图片都走相同恢复路径，不开启阅读器。若从已经handoff的普通详情打开面板，关闭后回到当前末图起点，计数3/3；从图库中部打开/关闭则保留原位置。ScrollController与图片／评论缓存不清。截图记录handoff打开时offset925，关闭后恢复末图起点1125（same controller=true），当前页3/3，阅读回调0、评论仍只读一次、推荐仍0。极短页面内容导致Flutter正常clamp时保同一个controller和当前页，不声称任意情况下offset数字都不变。
- **普通流双向交界。** 普通详情中真实向上滚回图库边界时“牵回”图片和紧凑作者入口，详情／评论／相关推荐sliver撤出活动树但停泊缓存；再次向下真实越界时再“放开”同一个完整详情子树。程序jump、首次布局或单纯idle不反向切换，评论根不重读、推荐不会从已读重置。回向路径另有[真实手势测试](../../../test/pixiv_detail_panel_handoff_test.dart)与scale1／2截图。
- 新图片批次重置该作品的图库状态；同批刷新保留面板。邻近Pager项由当前entry/TickerMode保护，不得替非活动页触发handoff或评论／推荐自动读。读取/分享/下载/收藏动作保持原入口。

## 实际离线截图

以下都是375×1000 Flutter引擎 `RenderRepaintBoundary.toImage` 截图，已用 `C:/Windows/Fonts/msyh.ttc` 与 MaterialIcons；插图是明确标注的内存离线fixture/占位图，仅用于检查自然比例、遮罩与布局，不是Pixiv线上作品内容。

![初始纵向浏览多页](375-normal-look-images.png)

![真实末页手势后的局部衔接](375-normal-last-page-handoff.png)

![75%详情面板与四评论](375-normal-detail-panel.png)

![点击露图收回后恢复当前页和底部入口](375-normal-back-to-images.png)

![普通详情上滑越过交界后牵回图库与作者入口](375-normal-scroll-up-return-to-gallery.png)

另有2倍字号与对比规格：375px字号2、240px暗色窄屏字号2、812px横向布局；详见[截图清单](targeted-tests-final.log)和同名PNG/JSON组。本次panel四评论在750dp以内已可完整显示，所以普通字号“详情面板”与“四评论”两张PNG实际内容相同，JSON分别保留对应面板与读评论测量，不谎称滚动不同。普通字号handoff后页面计数设为当前最后页3/3；真实手势完成后截图headerTop450，夹具lastImageStart1125、offset925。关闭恢复JSON记pixels1125、sameMainPosition=true、commentRequests1、recommendationRequests0。正常尾部JSON记pixels2159、commentRequests1、recommendationRequests1；反向滚回JSON记sameMainPosition=true、commentRequests1和recommendationRequests1，详情、评论和推荐没有重复请求。截图坐标是该指定夹具，不是对真机像素的保证。

## 验证

| 测试组 | 实际结果 | 日志／用例 |
| --- | --- | --- |
| Shell＋041兼容用例＋043新入口/手势/两套截图 | 41／41，通过；pwsh-740退出码0 | [最终测试日志](targeted-tests-final.log)、[新面板测试](../../../test/pixiv_detail_panel_handoff_test.dart)、[替代后的图库兼容测试](../../../test/pixiv_detail_gallery_collapse_test.dart) |
| 面板三目标静态分析与格式 | No issues found，退出码0 | [分析记录](analyze.log) |
| 含默认推荐轮次的在线入口＋session | 30／30，通过，pwsh-741退出码0 | [最终在线集成](../pixiv-related-rounds-042/online-integrations-final.log) |
| 本轮所有修改及新增Dart文件 | 32个文件 `dart analyze` No issues found；`git diff --check`退出0 | [总分析日志](../pixiv-related-rounds-042/final-analysis.log) |

所有表中测试均是在反向handoff最终实现后重跑；多图41／41与在线集成30／30均通过。面板三个目标Dart文件和本轮全部修改／新增的32个Dart文件分别执行analyze，最终日志均为No issues found；`git diff --check`退出0。分组范围有共享测试背景，不将各组测试数字相加冒称一次全仓通过。

详情面板截图曾真实触发Flutter Semantics断言，已补`explicitChildNodes`并重新测试；真实handoff最初未对齐的超调保护也按用户目标修正，通过drag后的headerTop450实测。测试和截图均不访问HTTP，测试夹具主动拒绝HTTP调用。

## 当前限制

用户报告当前实机版本的基础交互已验收，除手感与细节微调外无其他问题；这条反馈来自用户，本代理本轮没有构建或安装，也不把用户实机反馈当作真实Pixiv接口请求证据。作者栏“随图库内容一起滚动”的选择已确认，但该位置微调尚未改入源码，依用户要求留到明天；当前源码仍使用固定在底部的紧凑作者入口。其余待调项为上下交界触发时机与180ms动画手感，下一次在现有通过基础上微调并重新验收。请求参数边界见[042网络证据](../pixiv-related-rounds-042/network-evidence.md)。
