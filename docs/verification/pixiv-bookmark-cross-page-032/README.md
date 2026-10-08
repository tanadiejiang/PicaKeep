# Pixiv 收藏跨页回显补修（032）

2026-10-08：代码与自动化回归完成，`1.9.95+12` profile 已保留数据覆盖安装到主力机并启动；真实账号界面复验待用户观察。本轮接续 031 的真机反馈，不改变下载管理器和原有收藏写入端点。

## 现场与根因

用户在在线详情收藏后返回，所有卡片短暂呈半透明实心爱心；随后只有当前作品正确。离开页面后重进或重新加载，已收藏作品仍可能变为空心。

- 证据：推荐卡片将 `!actionsEnabled` 合入 `favoriteBusy`；列表刷新临时禁用操作，瀑布流组件把 busy 画成半透明实心。结论：列表刷新被误显示成全体收藏操作中。路径：[推荐卡片](../../../lib/pages/online_common/online_recommendation_card.dart)、[瀑布流按钮](../../../lib/pages/online_common/online_waterfall_card.dart)。
- 证据：每个 Feed 独立持有确认态，普通刷新及销毁会丢弃；Pixiv 榜单通常不提供 `bookmarkData`。结论：031 只保护了同一入口的回程状态，未处理跨页与重新进页。路径：[Explore](../../../lib/pages/explore/explore_page.dart)、[榜单解析](../../../lib/network/pixiv_network/pixiv_parsing.dart)。
- 证据：详情收藏原先只更新私有 `_favorite`，网络层未发布共享状态。结论：邻作和其他入口无法同步成功操作。路径：[详情](../../../lib/pages/online_comic/pixiv_online_detail_view.dart)、[网络](../../../lib/network/pixiv_network/pixiv_network.dart)。

## 改动

1. 分离 `favoriteEnabled` 与 `favoriteBusy`。刷新只禁用交互，保留原图标与颜色；按钮仍消耗点击，避免误进入详情，无障碍语义同步禁用。
2. 增加按当前登录会话隔离的 [共享确认状态](../../../lib/foundation/pixiv_bookmark_state.dart)。成功收藏、取消以及严格详情读态同步所有入口。最多保留 2000 条，列表字段缺失或旧摘要不能覆盖已确认值。
3. Explore、作者页和在线详情接入共享状态。页面销毁/重建、普通刷新不清除会话确认；账号身份统一采用 token，不随后续补齐 UID 而改变，凭据不写日志。
4. 已构建的可见/预取卡片对未知或过期状态按需确认：最多同时读取 2 个，相同账号/作品去重，3 分钟有效期、失败 30 秒冷却；不进行收藏写入，不呈现收藏操作中。点击未知爱心时复用在途确认，基于确认值执行一次添加或取消。
5. 旧读态、账号切换、刷新和新确认有版本保护；成功取消保留网络最新 capability/privacy，避免取消后失去再次收藏入口。

## 验证

- 14 份相关 Flutter 测试文件合跑：179 项全部通过。覆盖共享状态、真实详情按钮与邻作、账号隔离、失败保留、重新进页、旧摘要/迟到响应、限流与请求复用，以及详情滚动、作者关注和会话回归。
- 16 个产品/测试文件定向 `dart analyze` 无问题；`git diff --check` 无新增空白错误。
- [完整测试输出](tests.log)保留合跑证据；本次只声明相关回归通过，没有声明全仓库全量测试。

```powershell
flutter test --no-pub --concurrency=1 --reporter expanded test/explore/online_recommendation_card_test.dart test/explore/recommendation_waterfall_test.dart test/pixiv_bookmark_shared_state_test.dart test/pixiv_bookmark_network_sync_test.dart test/pixiv_detail_bookmark_shared_test.dart test/online_waterfall_card_test.dart test/pixiv_author_bookmark_test.dart test/pixiv_ranking_bookmark_state_test.dart test/pixiv_detail_network_test.dart test/pixiv_detail_session_test.dart test/pixiv_bookmark_state_flow_test.dart test/pixiv_online_detail_scroll_test.dart test/pixiv_author_experience_test.dart test/pixiv_author_follow_test.dart
flutter build apk --profile --target-platform android-arm64 --no-pub
```

## 主力机复验

`build/app/outputs/flutter-apk/app-profile.apk` 已构建成功；aapt 确认包名 `lingxue.picakeep`、版本 `1.9.95+12`，apksigner 确认原 debug 签名。APK SHA-256 为 `6A0F28772C53829637F031F27F8D7563DAB97C1A93272213249441B7A0BA6CCA`。

已用明确主力机 ID `192.168.5.4:5555` 执行 `adb install -r`，未卸载、未清理数据；安装后 `dumpsys package` 核对版本 12 / 1.9.95，MainActivity 成功启动，近期 AndroidRuntime 错误日志为空。这里只证明构建、安装和启动，以下真实网络/账号动作尚未代用户执行。

1. 榜单/推荐选择未收藏作品，在详情收藏后返回：其他卡片保持原状态，当前作品显示实心。
2. 进入作者页或其他页面再回到榜单，刷新、重新进入后仍显示实心。
3. 详情切到邻作后收藏，返回时对应邻作同步；取消后显示空心且可再次收藏。
4. 在其他页面或平台已有的收藏，未知榜单卡片读取后显示实际状态；切账号不会沿用前账号状态。

共享确认只存于本次应用进程，重启后由可见卡片重新读取；本轮不宣称真实账号/网络界面复验已完成。
