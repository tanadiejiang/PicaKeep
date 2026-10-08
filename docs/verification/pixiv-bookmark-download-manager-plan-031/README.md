# Pixiv 榜单收藏态与下载管理器修复计划（031）

状态：已执行，待主力机功能复验。代码、测试和 profile APK 已完成；安装过程保留了主力机应用数据，未卸载应用。

2026-10-08 真机续报：031 收藏修复仅覆盖同入口回程，未覆盖全页 busy 误显示和跨页/重新进入丢失。已由 [032 补修记录](../pixiv-bookmark-cross-page-032/README.md) 接续，最新主力机包为 `1.9.95+12` profile。以下保留 031 调查与执行历史，不将此前测试通过视为全部收藏场景关闭。

## 范围与约束

- 目标设备为 Android 主力机，执行阶段只允许 `debug` 或 `profile` 构建。
- 不迁移或重写既有下载任务数据。`OnlineDownloadTask.totalEps` 继续表示源站完整章节数，章节原始索引继续保持稳定；只修正显示投影和完成状态。
- 收藏态以详情接口的确认结果为权威；榜单响应缺少 `bookmarkData` 时不能把已有确认态降级为空心。
- 下载完成必须同时体现在文件、下载记录、队列任务和系统通知中；任一阶段失败都要进入明确错误状态，不能无限停在接近 100% 的运行中状态。

## 一、Pixiv 榜单返回后收藏态丢失

### 调查结论

榜单卡片点击详情后会触发父级刷新：[explore_page.dart:1385](../../../lib/pages/explore/explore_page.dart:1385) 的 `onDataRefresh` 调用 `_load(preserveContent: true)`。刷新开始时会暂时禁用卡片操作，刷新完成的概览和分页分支又分别在 [explore_page.dart:1200](../../../lib/pages/explore/explore_page.dart:1200) 与 [explore_page.dart:1259](../../../lib/pages/explore/explore_page.dart:1259) 无条件调用 `_bookmarks.reset()`。

Pixiv 榜单解析允许响应不带收藏字段：[pixiv_parsing.dart:666](../../../lib/network/pixiv_network/pixiv_parsing.dart:666)。因此刷新重建卡片时，已由详情确认的收藏状态会被清空。与此同时，卡片在 `actionsEnabled` 从可操作变为不可操作时递增 `_generation`：[online_recommendation_card.dart:281](../../../lib/pages/online_common/online_recommendation_card.dart:281)。详情返回后的 `loadBookmarkState` 仍要求旧 generation：[online_recommendation_card.dart:383](../../../lib/pages/online_common/online_recommendation_card.dart:383)，只要刷新跨过一帧，就可能提前返回，形成“有时丢失”的竞态。

既有契约要求详情返回刷新并读取最新收藏态（`docs/verification/features-006-010`、`pixiv-ranking-card-015`），但现有测试只统计刷新回调，没有覆盖父级真实加载、动作锁和 generation 变化。[online_recommendation_card_test.dart:928](../../../test/explore/online_recommendation_card_test.dart:928)

### 实施计划

1. 将回程刷新分为“保留已确认卡片状态”和“提交新响应”两个阶段。`preserveContent` 路径在新响应提交前保留 `confirmed`，不能用无参数 `reset()` 把它们清成未知；普通手动刷新仍可按现有策略使未确认状态失效。
2. 调整详情返回后的异步读态保护：仍校验 mounted、账号和作品 ID，但不要让父级为刷新而产生的旧 generation 单独取消这次权威读态。真正过期的作品、账号切换和卡片替换仍必须丢弃结果。
3. 让详情返回的确认结果覆盖旧确认值，包含“明确取消收藏”的 `false`；缺少 `bookmarkData` 的榜单摘要只能表示未知，不能覆盖已确认值。
4. 补齐测试：概览和分页榜单、刷新跨帧和快速完成、详情内收藏与取消、读态成功与失败、深滚动邻作切换、账号切换和过期响应。断言返回后仍会调用真实 `loadBookmarkState`，且不会由摘要缺字段降级为空心。

### 验收标准

- 已收藏作品从榜单进入详情再返回，爱心持续为实心；返回期间可以短暂禁用操作，但不会显示错误的未收藏。
- 在详情取消收藏后返回，榜单显示为空心；重新收藏后显示实心。
- 概览、分页、滚动加载和账号切换都不会把另一张作品的异步结果写回当前卡片。

## 二、下载管理器

### 2.1 长按选择样式统一

当前下载队列在 [downloading_page.dart:255](../../../lib/pages/downloading/downloading_page.dart:255) 使用左侧 `Checkbox`，本地已下载页则使用整项选中遮罩、主色边框和选择态 AppBar（[download_page.dart:891](../../../lib/pages/download_page.dart:891)、[download_page.dart:1299](../../../lib/pages/download_page.dart:1299)）。这造成同一应用中两套选择语义。

实施内容：

- 复用本地已下载页的选择态 AppBar：`primaryContainer` 背景、关闭按钮、“已选择 N 个项目”和 `more_horiz` 菜单。
- 移除队列行左侧 Checkbox，改为整行点击切换和整项选中反馈：主色半透明遮罩、约 1.6px 主色边框和现有圆角/渐变。
- 保留下载队列专有的暂停、继续、取消、移除动作，并放入选择态溢出菜单；空选择时退出选择态。
- 不改变任务 ID、队列排序、下载中的操作和用户数据。

测试与验收：长按进入选择态后，标题、关闭按钮、菜单和整行遮罩与本地已下载页一致；点击任意位置都能选中/取消；暂停、继续、取消、移除仍作用于所选任务。

### 2.2 章节分母按实际选择显示

章节选择页明确记录“共 44 章，已选 12 章”：[chapter_download_selection.dart:443](../../../lib/pages/online_comic/chapter_download_selection.dart:443)。任务模型同时保存完整源站总数和显式选择索引：[online_download_manager.dart:229](../../../lib/foundation/online_download_manager.dart:229)。队列行却直接显示 `currentEp/totalEps`：[downloading_page.dart:326](../../../lib/pages/downloading/downloading_page.dart:326)，所以选择 01–12 时出现 `第 2/44 章`。

实施内容：

- 增加纯显示投影：对显式选择，用 `requestedChapters` 中 `currentEp - 1` 的位置显示 `第 2/12 章`；没有显式选择的历史全量任务继续显示源站总数。
- 保留 `totalEps` 和原始章节索引，不改恢复、去重、断点续传和数据库结构。
- 对稀疏选择（例如 01、03）、旧任务、当前游标不在选择集合的异常数据添加安全回退。

下载详情头部另有一处独立问题：[download_page.dart:2254](../../../lib/pages/download_page.dart:2254) 直接用 `eps.length`，而 Komiic 写入会保存完整 44 个标题、只在 `downloadedEps` 保存已完成的 12 个索引（[online_download_manager.dart:1324](../../../lib/foundation/online_download_manager.dart:1324)）。因此详情面板也应显示“已下载 12 / 共 44 章节”（归档型全部内含时保留归档语义），删除一章后立即按实际完成索引减一；不压缩或重编号章节列表。

测试与验收：覆盖全量任务、显式连续选择、稀疏选择、恢复任务和删除章节。截图场景中选择 12 章时，队列分母为 12，详情面板的实际完成数为 12；完整下载后显示 44/44。

### 2.3 文件已完成但通知停在“正在下载 0/1 本”

截图中的 Android 通知表示任务仍处于 running：Dart 在 [online_download_manager.dart:3044](../../../lib/foundation/online_download_manager.dart:3044) 依据 `task.completed` 生成通知；章节进度在 [online_download_manager.dart:311](../../../lib/foundation/online_download_manager.dart:311) 依据已完成章节计算，所以最后一个文件已经接近 100% 时，仍可能卡在最终提交边界。每章结束还要经过 `_commitChapter` 的文件核验、下载记录写入和队列保存（[online_download_manager.dart:1368](../../../lib/foundation/online_download_manager.dart:1368)），任务完成后才会进入 `_finishActiveTask` 和终态通知。Android 服务收到 `finish` 后才把标题切换为“下载完成 · 1/1 本”并结束前台服务（[PicaKeepDownloadService.kt:161](../../../android/app/src/main/kotlin/lingxue/picakeep/PicaKeepDownloadService.kt:161)）。

静态调查尚不能把现场唯一归因于文件写入、数据库提交、队列保存或 Dart→原生通知交接；当前最可能的故障边界是“文件已存在但最终提交/通知终态尚未完成”，而不是单纯进度计算错误。执行阶段按以下顺序收口：

1. 在最后一个章节的文件核验、`_commitChapter`、`task.completed = true`、`_finishActiveTask`、`_notify` 和原生 `finish` 交接处加入可关闭的阶段日志与耗时字段，记录任务 ID、已完成章节数、文件存在性、提交结果和异常。
2. 使终态发布顺序明确：完成记录成功后立即产生 `completed=true` 的 100% 快照，再执行不影响用户可见状态的清理；清理失败不得把已完成任务重新发布为 running。
3. 检查通知控制器的心跳、节流和过期快照，确保 `finish` 后不会被旧 heartbeat 或迟到的 running 更新复活；若最终提交失败，发布可见错误并结束无期限的假进度。
4. 补充 Dart 通知控制器、下载管理器和 Android 服务的回归测试：`0.99 -> completed -> finish`、取消、暂停、提交异常、进程恢复，以及旧快照晚到的顺序场景。

真机验收以文件和记录为准：全部选定章节存在且可打开时，队列任务必须标记完成，通知显示完成 `1/1` 或被正常收起；不能留下“正在下载 0/1 本”的运行通知和接近满格的静止进度条。若提交确实失败，必须显示错误原因并允许重试。

## 执行结果

### 已落地的改动

- 榜单返回时保留已确认收藏态；详情返回使用独立的权威读态保护，避免刷新 generation 竞态和缺少 `bookmarkData` 的摘要把实心爱心降级为空心。
- 下载管理器改为与本地已下载页一致的整行长按选择样式，选择态提供全选、暂停、继续、取消和移除操作。
- 显式章节选择按实际选择集合显示队列位置和分母；详情头部按有效 `downloadedEps` 显示已下载/总章节数，归档任务保留归档语义。
- Komiic 等不需要标签翻译收集的任务不再等待该辅助流程；下载记录落盘后异步处理翻译标签，减少完成边界等待。
- 完成快照固定为 100%，队列切换会清理旧心跳和迟到进度；前台恢复时会重试未交付的终态通知。Android 服务不会用迟到的生命周期回调把已完成任务改回运行中，并保留完成阶段日志。

### 验证结果

- 下载管理器核心与续传测试 `30` 项、选择/流程/通知基础测试 `46` 项，选择样式、章节计数、通知终态和榜单收藏态回归 `91` 项，合计 `167` 项 Flutter 测试通过。
- 目标文件 `dart analyze` 无问题，`git diff --check` 无新增空白错误。
- 已构建 `build/app/outputs/flutter-apk/app-profile.apk`，并核对 APK 存在、签名和路径。
- 已使用明确设备 ID `192.168.5.4:5555` 执行覆盖安装，未执行卸载或清理数据；安装后确认 `versionCode=11`、`versionName=1.9.94`，主 Activity 可启动。

### 待真机复验与限制

- 仍需在主力机上按现场路径复验：榜单进详情返回、长按下载任务、只选 12 章时的 `12` 分母，以及最后一章完成后通知是否收起/显示完成。当前自动化覆盖了状态边界，无法替代系统通知栏和真实网络下载。
- Android 原生服务本轮只做 Dart 回归、Kotlin 静态检查和 APK 构建验证，没有单独的原生单元测试框架。
- 详情内切换到邻作后修改收藏，仍只确认原入口作品；该边界未扩大到本计划范围。

## 执行顺序与交付

1. 先加收藏态竞态回归测试，再修复榜单回程状态保留和权威读态保护。
2. 完成下载队列选择态统一、章节分母投影和详情头部实际完成数，并分别补纯逻辑/Widget 测试。
3. 加入完成边界日志与通知终态修复，跑 Dart/Flutter 测试和 Android 原生编译检查。
4. 按项目规则构建 `profile` APK，保留主力机数据，安装前核对 APK 路径和明确设备 ID；只在手机上复验榜单返回、长按选择、12/44 显示和通知终态。
5. 执行阶段结束后回写本计划的实际改动、测试结果、真机证据和剩余限制。

本计划已完成代码修改、测试和 profile 构建安装；后续仅需按上面的真机清单观察现场行为并记录结果。
