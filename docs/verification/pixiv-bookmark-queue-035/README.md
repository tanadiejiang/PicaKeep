# Pixiv 收藏悬浮爱心队列 · 035 验收

执行者：Codex · 2026-10-08 19:26 +08:00

用户提供现有胶囊截图，要求参考三角洲／战地连续击杀反馈的排队显隐。现在连续接受的收藏操作以爱心排成一列，分别等待、确认、失败；完成短停后从左端退出。每个操作只改变自己的项，慢请求不被后来的结果吞掉。

## 实际效果

- [动态演示](queue-animation.gif)：真实Flutter Host和3张操作票据，29张实际PNG合成，逻辑时序3420ms。
- [六阶段对比](queue-stages.png)：等待3项→B/C先完成→A完成→A左退→B/C推进→最后项退出。
- [浅色](queue-light.png)、[深色](queue-dark.png)、[全等待](queue-waiting.png)、[单条](queue-single.png)、[320dp与2倍字长错误](queue-large-error.png)、[横屏2倍字长错误](queue-landscape.png)。
- [每帧原始数据](animation/frames.json)保留operation/work、状态、时刻、exit平移／透明度／宽度、entry平移／透明度、完成scale／fill以及实际胶囊矩形。GIF必须按10ms量化，原PNG与JSON不改变实测时间；同一时间的帧和1ms边界在GIF最少展示10ms。

本轮截图均为实际Flutter离线渲染。纯视图样例用于布局与浅深比较，29帧演示由生产Host/controller真实计时驱动；卡片集成测试另走生产toggle。没有伪造设备或真实账号请求截图，034历史证据保留。

## 最终行为

| 状态／流程 | 实现 |
| --- | --- |
| 接受操作 | 立即排入浅色空心等待项＋省略号，180ms从右侧进入。capture本身、登录或busy拒绝不入队 |
| 添加确认 | 实心玫瑰爱心＋确认角标，160ms填色与轻回弹；只在真实结算后标完成 |
| 取消确认 | 空心爱心＋确认角标；保留真实添加／取消方向 |
| 私密确认 | 添加心附锁，成功停留3s |
| 写入失败 | 错误角标，完整返回原因可见；保留最新失败，较新成功不抹掉当前失败文字 |
| 乱序回包 | 排列与退出按接受先后；最近文本／失败按实际结算序号取，B先失败、A后失败时显示A原因 |
| 完成停留 | 公开／取消至少2s，私密3s，失败3.5s；沿用大字体／accessibleNavigation阅读时间延长 |
| 左端退出 | 只有队首已结算且停留结束才240ms左移24dp＋淡出＋水平收窄，移除后180ms推进下一颗；不跨过等待中的队首 |
| 数量多 | 最多5颗可见，窄宽度动态减少，余项＋N；完整模型与所有状态计数不丢弃任何已接受操作 |
| 页面作用域 | 原active／route／identity epoch失效清整个队列和计时；迟到业务仍按原账户条件结算，返回不复活 |
| 减少动态效果 | 等待／完成静态保留，继续正常停留；入场、完成或退出中途切换均立即停所有Ticker |
| 兼容 | 保留034主按钮节奏、Controller／Store／网络策略、本地与其他源行为；平台菜单确认后显示同样等待项 |

## 运行结果

- **22份定向测试，304/304通过**，最终[回归日志](regression.log)结尾为 `00:42 +304: All tests passed!`。
- **14个本轮生产／测试文件定向分析无问题**，见[分析日志](analyze.log)。
- 本轮修改范围 `git diff --check` 通过。

核心新测试：

- [视图帧／布局22项](../../../test/pixiv_bookmark_queue_widget_test.dart)：入场0/90/180、完成0/80/160、退出0/120/240ms实际数值、head/tail、单多项状态保留、全量计数、折叠、减少动画／dispose、窄屏大字、6张真实截图。
- [生产卡片集成10项](../../../test/pixiv_bookmark_queue_integration_test.dart)：三个不同作品A/B/C并发，B/C先确认、A等待与本地目标，真实Store仅确认时变；精确1999+1／239+1／179+1边界；busy去重、未知读true取消失败、具体错误、active／route／identity失效与迟到共享确认、7项折叠、私密／减少动画。
- [真实Host截帧1项](../../../test/pixiv_bookmark_queue_capture_test.dart)：生产Host+3票据，29帧与矩形检查。
- [Host中途减少动画3项](../../../test/pixiv_bookmark_queue_reduced_host_test.dart)：入口30ms、完成80ms、退出60ms切换，停Ticker且不重置保留／推进计时。
- [反馈17项](../../../test/pixiv_bookmark_feedback_test.dart)：除原生命周期／键盘／截图外，新增两项失败反序与退场、推进内连续append／cancel，原240/180ms期限不延后。
- 原探索无Scaffold生产导航、菜单确认、推荐卡片、详情共享／滚动／Pager、Store／网络离线adapter及本地shell／其他源／关注兼容回归全部通过，完整清单如下。

## 复跑

仓库根目录，Windows PowerShell：

```powershell
New-Item -ItemType Directory -Force .dart_tool/035-temp | Out-Null
$env:TEMP = Join-Path (Get-Location) '.dart_tool/035-temp'
$env:TMP = $env:TEMP
$tests = @(
  'test/pixiv_bookmark_queue_widget_test.dart'
  'test/pixiv_bookmark_queue_integration_test.dart'
  'test/pixiv_bookmark_queue_capture_test.dart'
  'test/pixiv_bookmark_queue_reduced_host_test.dart'
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

## 当场经验与边界

- 原单条Host的owner只接受最新操作，必须替成ticket.opId独立项；不能把旧timer/newer-message判断简单改松，否则后来的结果仍会被提前清掉。
- 接受次序决定FIFO视觉位置，结算次序决定最新原因，两者不能共用一个index。后接受的B先失败、先接受的A后失败，倒序找entries会永远漏展示A，已加settlementSequence与可见／语义回归。
- 停留用每项Timer→ready；队首退出与180ms推进用独立Timer。初版DateTime.now计算剩余停留会在Flutter fake timer下扣实际执行耗时，1999ms／2999ms提前退出；改为Timer驱动后精确边界通过，生产计时也更直接。
- Host外层旧AnimatedSwitcher即使把新duration改零，同child已有controller仍继续180ms入场。已移除多余外层动画，用epoch KeyedSubtree负责生命周期；队列项自己的180／160／240ms运动响应减少动画。
- SizeTransition仅收缩本页浮层里的已完成首项，不触发原瀑布流卡片布局，不截获点击。等待心不旋转，不用长期Ticker表达网络状态。
- 既有测试按“唯一favorite_border”查整个页面，会把新增装饰心误算成业务按钮；改为主按钮key。单条text相等断言在多项caption含计数后改为包含具体完整原因，未弱化失败真实性。
- 独立只读审查发现并修复上述减少动画／结算顺序两处确定问题，未发现新业务确认问题；进一步append/cancel/退场期限已回归。
- 既有共享Store的unknown状态GET失败因resolve返回void只能提供通用读取失败文案；本轮保留这一网络契约，不声称还原所有GET原始错误。写入接口提供的具体错误在队列可见。
- 阅读时长在结算时按当前字体／accessibleNavigation计算；结算后系统字号改变不会重新开始该项停留。
- 未做应用打包／安装、真机运行、真实账号收藏写入或设备帧率测试。仅受控网络fixture、真实本地Controller／Store与Flutter视图验收。AGENTS规定只debug／profile构建、安装保数据，本轮无构建安装。
