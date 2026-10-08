# Pixiv 收藏动效 033 → 034 实施与离线验收

执行者：Codex · 2026-10-08 18:34 +08:00

034 即时动作已实现；033 页面局部胶囊、在线统一范围、视觉生命周期的未完验收已接续完成。原始确认后动效、250ms 旋转等待和300ms取消参数由用户确认的034替代，不能宣称033旧参数仍全部生效。

## 结果与证据

- 18份相关测试：**266/266通过**，见[完整回归日志](regression.log)。
- 20个修改范围内的源码／测试文件定向 `flutter analyze --no-pub`：**No issues found**，见[分析日志](analyze.log)。
- 本轮修改范围 `git diff --check` 通过；既有未提交的下载／网络／库页面等修改保留。
- [实际Flutter动作关键帧](flutter-motion-frames.png)：由生产卡片的RepaintBoundary导出原始2×像素，添加与取消0/50/100/150/200/250/300/500ms；未用CSS或vector重画。
- 页面内胶囊：[浅色](light-phone.png)、[深色](dark-phone.png)、[1.2秒等待文案](waiting-phone.png)、[2倍字体完整失败原因](large-text-error.png)、[横屏](landscape.png)、[桌面](desktop.png)。对应 `*-geometry.txt` 保存实际矩形。全部已读取检查。

## 最终行为

| 工作流／边界 | 实现与运行证据 |
| --- | --- |
| 已知添加 | writer入口立即begin；100ms余弦收缩至0.1，200ms tension=2回弹；后200ms环扩散并淡出。0ms、700ms、2500ms完成均不重播 |
| 已知取消 | 立即空心；500ms恢复主心大小；落心36°、下移一个iconSize，透明度300ms淡出；48dp卡片／56dp详情位置与热区不变 |
| 持续慢写 | pendingVisualTarget仅发起按钮可见；motion结束后保留目标，原busy到真实请求结算才释放；重复卡片仍显示原真实确认值 |
| 未知态 | accepted中性，不猜方向；原state read确认false→一次添加、true→一次取消；读失败／不可收藏零写入。writer仍沿原toggle语义 |
| 快返回首帧 | settle携同opId begin，按钮补消费尚未消费的开始事件；已消费及首绑不重播 |
| 写失败 | 140ms淡变回最新权威known值，包含本次读到true或busy期间Store新true；不反向动作、不补偿POST |
| 1.2秒等待 | 当前票据超过1200ms显示读取／提交／取消文字，中性省略号图标；快完成取消timer，结果替换等待；旧操作不能覆盖或清除新消息 |
| 页面／账号／作品失效 | Host identity/current/active epoch清旧胶囊与timer，传入button.visualEpoch清pending；返回不会复活。视觉条件不并入业务writer／确认谓词 |
| 减少动态效果 | 无回弹／落心／环／平移动作；pending静态目标保留到结算，语义明确尚未确认，权威toggled不乐观变更 |
| 平台收藏菜单 | 保留菜单与取消确认，确认前零写；实际成功删除对应条目并胶囊，失败留条目及具体原因；其他源原SnackBar保持 |
| 本地与非收藏 | shell默认未启用在线动效；本地滚动显隐／关注／复制与其他源静态按钮回归通过 |

## 验收范围

[生产导航测试](../../../test/explore/pixiv_bookmark_feedback_navigation_test.dart)实际使用NaviPane→嵌套Navigator/AppPageRoute→ExploreRouteScope→NaviPaddingWidget→ExplorePage，未额外包Scaffold。胶囊实际getRect处于375dp手机底栏58dp上方，浅深、2倍字体、横屏及桌面均在内容边界内；切源、页签、榜期、路由往返后旧票据失效。此组直接捕获生产Host票据显示反馈，不声称通过真实账号POST验收。

[卡片集成测试](../../../test/pixiv_bookmark_card_motion_test.dart)走生产OnlineRecommendationCard→Controller.toggle→注入writer→事件→生产OnlineWaterfallCard/button/Host，检查即时动作、真实确认后共享静态同步、未知读true失败和active往返迟到成功。截图使用缺省封面占位，未发真实图片／收藏请求。

[平台菜单测试](../../../test/pixiv_network_favorites_feedback_test.dart)真实长按菜单→取消项→确认dialog→注入FavoriteData删除流程，封面HTTP明确离线拒绝。路由迟到成功仍删项，结果保持静默；迟到失败亦静默。

[详情共享测试](../../../test/pixiv_detail_bookmark_shared_test.dart)、[详情滚动测试](../../../test/pixiv_online_detail_scroll_test.dart)覆盖快慢添加、500ms取消、私密长按、最新Store失败恢复、路由与邻Entry往返、账号拒绝、登录无触觉、scroll显隐。Pager的current项会同步更新EntryScope.isActive与TickerMode。

[反馈测试](../../../test/pixiv_bookmark_feedback_test.dart)实际检查1200ms门槛、归属timer、单liveRegion、popup不离页、减少动效、字体与尺寸；键盘280dp、375×720下，Host位于Scaffold外／body内均测得胶囊bottom=424dp，只避让一次。默认成功2s、失败3.5s、私密3s，字体与accessibleNavigation延长阅读时间。

## 复跑

从仓库根目录运行（Windows PowerShell）：

```powershell
New-Item -ItemType Directory -Force .dart_tool/034-temp | Out-Null
$env:TEMP = Join-Path (Get-Location) '.dart_tool/034-temp'
$env:TMP = $env:TEMP
$tests = @(
  'test/pixiv_bookmark_button_test.dart'
  'test/pixiv_bookmark_feedback_test.dart'
  'test/pixiv_bookmark_card_motion_test.dart'
  'test/explore/pixiv_bookmark_feedback_navigation_test.dart'
  'test/pixiv_network_favorites_feedback_test.dart'
  'test/explore/online_recommendation_card_test.dart'
  'test/explore/recommendation_waterfall_test.dart'
  'test/online_waterfall_card_test.dart'
  'test/pixiv_author_bookmark_test.dart'
  'test/pixiv_detail_bookmark_shared_test.dart'
  'test/pixiv_detail_session_test.dart'
  'test/pixiv_online_detail_scroll_test.dart'
  'test/pixiv_bookmark_shared_state_test.dart'
  'test/pixiv_bookmark_network_sync_test.dart'
  'test/pixiv_detail_shell_test.dart'
  'test/pixiv_detail_favorite_visibility_test.dart'
  'test/pixiv_author_follow_test.dart'
  'test/pixiv_bookmark_state_flow_test.dart'
)
flutter test --no-pub --concurrency=1 @tests
```

## 当场经验与限制

- UI票据失效只影响视觉，不能让writer包装因页面失效早return。否则accepted未知读完以后会漏真正写入。Controller、Store及网络策略本轮未改造。
- begin与settle两个setState可能被同一帧合并；显式携原begin解决首遍动作丢失，不延迟业务请求、不猜测外部bool翻转。
- Flutter动画精确duration帧已达到视觉终值，但SDK `_InterpolationSimulation.isDone` 使用严格 `time > duration`。测试精确帧值，再多推进1ms检查Ticker结束；不要把边界一帧误判成泄漏。
- Host使用自有epoch为AnimatedSwitcher置key，生命周期失效立即销毁outgoing旧胶囊；普通结果替换仅显示当前child，避免两颗胶囊／两次liveRegion。
- 初次Host包测试SizedBox，Stack.expand将卡片撑到整个页面，引发测试溢出；夹具加入Align保留原180dp，生产滚动列表不受影响。切active的测试也必须复用同一comic对象，不能意外替换业务身份。
- 初次可视测试缺Material文本继承造成默认测试字体方块和红色下划线；补真实Material并加载本机微软雅黑／MaterialIcons后重导，已读图确认。字体只用于验收，未加入生产依赖。
- 定向analyze发现跨对象直接调用protected notifyListeners，已改为Controller自己的通知方法；工厂失败消息和代码块风格提示亦修正，最终零问题。
- UI减少动效尊重MediaQuery，不绕过系统偏好。没有新动效依赖、官方图标资源、乐观共享确认、重试或反向补偿。
- 未构建／安装APK，未真机运行，未进行真实账号收藏写入。受控响应证明本地行为，线上延迟、振动硬件和设备合成性能仍需设备复验；本轮不把离线渲染当真机截图。
