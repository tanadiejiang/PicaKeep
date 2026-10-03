# 下载进度通知与后台下载验收记录

日期：2026-10-02。对应第十八轮 44 号计划，并兼容 46 号 Pixiv 自定义目录与跨目录任务。

**当前状态：应用代码和定向自动化已落地，Android 真机验收尚未执行。** 本记录不把桌面测试当作锁屏、Doze、厂商省电或系统时限的真机通过证据。未安装、卸载或清除设备应用数据。

## 使用与实际行为

1. 从任意支持的漫画/插画来源启动下载，出现一条聚合进度通知。
2. 标题 `正在下载 0/3 本` 表示已完成 0 本、当前正在下载第一本；第一本完成后是 `1/3`。分母随着队列增删变化，包括暂停、失败和取消的记录。
3. 进度条始终属于真实正在执行的任务，置顶候选任务不会抢走当前进度。正文显示当前标题和下载速度。
4. 点通知主体进入下载管理器；点“打开”进入本地已下载漫画列表。不会改写用户上次记忆的远程/聚合视图设置。解锁完成后才消费待跳转目标。
5. 全部完成后退出前台服务，完成通知继续保留；点击通知主体也保留，直到用户手动划掉。新下载开始才再次创建进行态通知。
6. 下载管理器右上角“后台下载与通知”提供通知权限及电池优化入口，并显示当前受限原因。只有用户点击“设置”才请求权限或打开系统页。

## 后台工作边界

| 场景 | 本轮实现 | 尚需真机确认 |
| --- | --- | --- |
| 按 Home、锁屏或切换应用 | 独立 `dataSync` 前台服务，活动下载持有限时 CPU 锁 | Android 不同版本和厂商的网络/省电策略 |
| 当前默认网络断开 | 取消当前网络流，保留任务与其目标目录，显示等待网络 | Wi-Fi/移动网络/VPN 实际切换时序 |
| 网络恢复 | 只恢复因网络等待的任务；用户暂停的任务仍暂停 | 后台网络回调与目标站点可达性 |
| 等待网络期间 | 保持服务等待回调，释放 CPU 锁，Dart 每 30 秒发送心跳 | 长时间 Doze 仍受系统联网策略限制 |
| 正常结束、暂停或取消 | 释放 CPU 锁，退出服务，转可划掉的终态通知 | 通知渠道/权限/系统 UI |
| 系统 FGS 时限、后台启动受限 | 记录受限说明；后台时暂停未完成队列，提示返回应用继续 | Android 15+ 时限触发与厂商限制 |
| 从最近任务移除/Flutter 引擎结束 | 停止保护并保留任务；孤儿服务缺少心跳超过 90 秒会收尾 | 进程被系统直接结束时没有执行回调的保证 |
| 重新打开应用 | 读取持久化队列，任务以暂停状态恢复，由用户继续 | 用户实际存储权限/介质可用性 |

CPU 锁每次最多 120 秒，60 秒后续约；30 秒 watchdog 同时检查 Dart 心跳。等待网络、终态、超时和服务销毁都会释放锁。没有设置屏幕常亮，也没有自动更改电池优化、联网权限或系统限制。

本轮没有把 Flutter 执行引擎迁移到独立原生后台 worker。因此，应用进程/引擎被彻底销毁后不继续联网；恢复入口是保存的队列。现有“服务端保活”仍使用通知 ID 9527；新下载使用 9528，渠道也独立。两种 `dataSync` 服务仍共享应用级后台时间预算，合并类名或通知不会消除该限制。

## 证据、结论与代码路径

| 证据 | 结论 | 路径 |
| --- | --- | --- |
| 队列开始、进度、控制和六源 finally 的同一通知入口 | 覆盖现有在线下载器的六种来源 | [online_download_manager.dart](../../../lib/foundation/online_download_manager.dart) |
| 独立 activeTask 身份、任务快照、串行 IPC 和 1 秒节流测试 | 当前进度不受重排与同作品不同目录副本影响 | [download_notification_controller.dart](../../../lib/tools/download_notification_controller.dart) |
| 状态机涵盖运行/等待/暂停/失败/完成/空队列 | 冷启动暂停队列不会伪装为正在下载 | [通知状态测试](../../../test/download_notification_controller_test.dart) |
| 两个已有物理副本、断网排队、只恢复未手动暂停项 | 网络恢复保持 46 号 folderId/operationId，不退回裸 workId | [后台队列集成测试](../../../test/download_background_queue_test.dart) |
| 失败流、暂停、短响应、旧 `.part`、已有目标保护六例 | 半文件不再发布成可续传的最终图片 | [原子流写入](../../../lib/foundation/download_stream_file.dart)、[测试](../../../test/download_stream_file_test.dart) |
| Native retained intent + Dart readiness 队列 | 冷/热启动与身份验证不会直接在未就绪 Navigator 上 push | [通知路由](../../../lib/tools/download_notification_routes.dart) |
| `forceLocal` 的远程/聚合设置回归 | “打开”进入本地页且不改变持久化偏好 | [目的地测试](../../../test/download_notification_destination_test.dart) |
| `DETACH` 后普通通知、完成态 `autoCancel=false` | 完成通知保留并允许划掉 | [PicaKeepDownloadService.kt](../../../android/app/src/main/kotlin/lingxue/picakeep/PicaKeepDownloadService.kt) |

## 自动化记录

第一组定向回归执行完成：**50 通过，无失败**。该组包含当时 19 个新增测试，以及 46 号任务身份持久化、EH 响应流、下载根和已下载包装类的 31 个既有测试。

```powershell
flutter test --no-pub test/download_notification_controller_test.dart test/download_stream_file_test.dart test/download_background_queue_test.dart test/pixiv_download_target_queue_test.dart test/eh_download_limit_page_test.dart test/online_download_roots_test.dart test/online_downloaded_custom_test.dart
```

对应 13 个 Dart 应用/测试文件定向 `dart analyze`：**No issues found**。第一次执行出现两个测试结束时未停止 FakeAsync 心跳的测试清理问题和一处大括号 lint，修正后上述组全通过。

随后补充了“Activity/engine 重建收尾孤儿通知”“通知进入本地页保留上次视图设置”“迟到 status 不重置通知会话”和“恢复前网络/后台事件不写空队列”四个回归。44 号最终新增测试共 **23 项**。

最后一组定向回归：**54 通过，无失败**，覆盖上述 23 项及既有 31 项。原始输出见 [targeted-final-tests.log](targeted-final-tests.log)。

```powershell
flutter test --no-pub test/download_notification_controller_test.dart test/download_notification_destination_test.dart test/download_stream_file_test.dart test/download_background_queue_test.dart test/download_background_startup_test.dart test/pixiv_download_target_queue_test.dart test/eh_download_limit_page_test.dart test/online_download_roots_test.dart test/online_downloaded_custom_test.dart
```

主代理统一全量测试第一轮：**2121 通过、14 跳过、1 失败**；唯一失败为 `ai_conversation_test.dart:631`，对照既有交接记录确认是已知基线失败。本轮没有修改该 AI 模块。此次全量早于最后两项初始化竞态修复，所以明确保留“全量当时点 + 修复后 54 项定向复验”两份证据，不声称最后修复后已重跑全量。原计划的历史 `2035/14/1` 不是本次结果。

初始化复核还修正了两处时序问题：异步 native status 不得覆盖已经开始的通知会话标记；初始化网络回调不再保存队列，生命周期保存遇到尚未读盘且内存为空时不写入。恢复后显式清空以及用户新入队后的严格持久化仍照常执行。

## 用户真机验收步骤

仅使用已确认存在的 debug/profile 包并显式选择设备，保留现有应用数据；本记录不执行安装。

1. 前台加入三个下载，检查 `0/3`，中途加入第四个检查总数立即更新；确认当前标题、速度与页级进度和应用内一致。
2. 暂停当前项、置顶另一个候选项、继续、取消；核对真实执行项和通知进度，尤其验证同作品不同目录的两个任务。
3. Home/锁屏后持续下载，再断网、联网；确认网络等待状态和自动恢复。另有一项手动暂停时它必须继续暂停。
4. 队列完成后点通知主体，再返回通知面板，完成通知仍存在；手动划掉后不会自行出现。新建下载才再次出现。
5. 分别在应用前台、后台、冷启动、应用锁开启时点击通知主体与“打开”。主体到队列，“打开”到本地已下载，解锁前不显示私有列表。
6. 通知权限拒绝时确认无崩溃；从下载管理器打开后台支持页面，检查通知/电池状态与系统设置返回后的刷新。
7. 验证系统后台时限和省电限制时，记录系统版本、可见提示与队列状态，不把“显示通知”单独当作后台联网通过。
8. 中断图片接收并重新打开，确认 `.part` 不进入图片列表、不被当作已完成页；继续后得到完整产物。

## 官方限制核验

本次核对 Android 官方资料：

- [Foreground service timeouts](https://developer.android.com/develop/background-work/services/fgs/timeout)：Android 15+ 同类型 `dataSync` 共享应用级后台预算，需要及时处理 `onTimeout(int,int)`。
- [Changes to foreground services](https://developer.android.com/develop/background-work/services/fgs/changes)：后台启动和类型权限要求仍需遵守，不能靠多建服务绕过。
- [Use wake locks](https://developer.android.com/develop/background-work/background-tasks/awake/wakelock)：锁须有边界并及时释放；不是永久保活保证。
- [Optimize for Doze and App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby)：Doze 可能推迟 CPU 与联网活动。
- [Service API](https://developer.android.com/reference/android/app/Service)：使用单参数 `stopForeground(flags)`；三参数重载属于 `startForeground`。

本记录的设备行为仍以实际真机结果为准。

## 最终统一复验 · 2026-10-02 13:28

主代理在最后两处初始化竞态修复之后重新执行了全量检查，子代理已读取日志及 APK 校验值核对。此节是最终结果；上方 50/54 定向及 2121 全量为执行过程的较早证据。

| 检查 | 最终结果 | 原始证据 |
| --- | --- | --- |
| `dart analyze lib test` | **No issues found** | [analyze-final.txt](../combined-44-46-47/analyze-final.txt) |
| 完整 `flutter test --no-pub` | **2123 通过、14 跳过、1 既有失败** | [full-tests-final.txt](../combined-44-46-47/full-tests-final.txt) |
| 44 与下载链路定向复验 | **54 通过** | [targeted-final-tests.log](targeted-final-tests.log) |
| 47 专属迁移恢复回归 | **12 通过** | 由主代理统一记录在 47 号结果中 |
| `flutter build apk --debug --no-pub` | **成功**，Gradle 66.1 秒 | [debug-build-final.txt](../combined-44-46-47/debug-build-final.txt) |

全量唯一失败仍为 `ai_conversation_test.dart:631`，与既有交接基线一致；不表述为全量全部通过。

debug APK：`build/app/outputs/flutter-apk/app-debug.apk`，215,516,627 字节，文件修改时间 2026-10-02 13:28:28。

```text
SHA256 8EA5FB92625B87332943B03EF2E535DA8F282927AB4D09D6D8C6D4E685EB84C0
```

本次 debug 编译已验证新增 Kotlin 服务、Manifest 和 Flutter 接线可构建。**仍未安装或操作设备，锁屏/Doze/厂商省电限制等真机验收未执行，计划保持部分完成。**
