# 012 · 推荐瀑布流来源范围修复

用户发现禁漫推荐被切为瀑布流，明确只要Pixiv推荐改版。本fork只修此范围错误，不处理011详情改版。基线为main `aa186c00d1d5bdd124b377171325978d207e7eea`（1.9.90+7）。

## 修复行为

`explore_page.dart`原overview和paged展示都只判断入口类型recommend，导致全部来源共用瀑布流。现在统一判断来源key为pixiv且入口为recommend；两种展示和Pixiv详情回程保内容条件共用此谓词。

JM、Picacg、E-Hentai、Nhentai、Komiic及未知来源推荐重新使用既有ListView/OnlineComicListItem。分组标题、错误/重试、查看更多、分页footer、懒加载、屏蔽、本地收藏态及按源图片headers都沿原列表路径。loadOverview仍覆盖各来源推荐，不混淆数据读取类型与视觉范围。榜单、分类和查看更多结果页维持原布局。

Pixiv保留头像、标签、快捷平台收藏、显示设置刷新和详情返回深滚动保护；其它来源不会因瀑布流列数/推荐标签设置而变布局或重发请求。共享卡片/网络/下载/其它页面无产品修改。没有重置配置或安装到设备。

## 回归证据

正向瀑布流fixture由误用JM模型改为真实PixivComicBrief/pixiv来源。原7项保留，补六个非Pixiv来源×overview/paged共12项负向检查，以及overview/paged两项跨七源切换隔离；每项实际挂载ExplorePage并检查卡片类型、controller/offset、缓存内容及请求身份。

既有JM切源滚动及500条分区懒加载改回ListView/OnlineComicListItem断言。联合探索、路由、推荐账号交互和共享卡片测试为75通过、1跳过（targeted-tests.txt）。首轮explore-tests.txt因测试改卡片类型时漏替换import编译失败，补实际列表组件import后联合重跑通过；保留首次日志，不用失败结果冒充通过。

独立只读复核确认三处分流足够，非Pixiv原路径完整保留，未发现需要改provider或请求链的理由。来源矩阵均采用离线fixtures，无真实站点/账号操作。

## 产物验证

analyze/profile、源码输入校验和APK身份完成后在此追加。构建仅 `flutter build apk --profile --target-platform android-arm64`，不使用release、不卸载/清数据、不安装。

最终验证（2026-10-04 16:15）：联合75通过、1跳过；规范清理后21项来源专项再次通过。`flutter analyze lib test`无问题，退出0；全目录检查的既有临时预览脚本6条info和1条unused actionRow warning保留，未越界修改。

profile构建101.6秒，780项应用输入构建前后完全一致。归档[app-after012-profile.apk](../../../build/verification/recommend-source-012/app-after012-profile.apk)，版本lingxue.picakeep 1.9.90/code7，50,793,398 bytes，SHA256 `5284550B6455AA6992C034AC49616DFD424F16D32A83C5A0015A6A8B642422D5`。构建期间Git HEAD/暂存状态由其它工作改变，本fork未干预；用实际源输入哈希证实包与本轮代码一致。应用及测试没有后续产品修改，未安装设备。

011调研当前SHA256为 `476683E909C9DD57CEB54B782F3A4A1E54891EAFAEE4C38DA742D13894DEFDD1`，本fork仅记录未改动证明，不调查或执行其中内容。修改前快照保存在before目录；原009已完成正文不改，另写012修复计划及执行回写。
