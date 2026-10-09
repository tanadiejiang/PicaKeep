# 039 作者缩略图平台收藏

实现仅修改 [OnlineRecommendationCard](<D:/Flutter_Projucts/PicaComic/PicaKeep/lib/pages/online_common/online_recommendation_card.dart>)，增加 compactPreview=false。启用时父布局提供固定120dp高度：只显示封面和多页角标，右下保留48dp点击区／22dp图标的 PixivBookmarkButton，颜色来自原favoriteStyle。图片与爱心点击区独立，不显示标题、作者或标签行。

收藏切换、详情打开、account/work identity、反馈票据、haptic、重复请求保护和读写守卫均复用原实现。compact 首次构建不自动解析未知收藏状态，只有点击爱心才按需确认；缺失 capability 后可读态的作者 brief 不被直接当成永久不可收藏。

已检查 parser：缺 bookmarkData 时 bookmarkStateKnown=false、canLoadBookmarkState=true。控制器在 state unknown 且 canLoadBookmarkState 时允许按需读取；已知不可收藏且未收藏的卡片隐藏爱心。

图片使用原onlineCoverProvider和headers，先使用保持比例缩略图，失败后最多尝试一次原thumb，再显示占位。没有新增网络端点或单独收藏控制器。

[独立测试](<D:/Flutter_Projucts/PicaComic/PicaKeep/test/pixiv_author_preview_bookmark_test.dart>)覆盖固定布局与点击隔离、共享成功状态、失败回滚／重复点击一次写入、未知状态首次不读且点击按需、读到capability=false不写、inactive／disabled禁动作、账号变化丢弃过期确认，以及另一个共享controller带来的状态更新。所有fixture封面为空，读写为fake Future，不访问真实HTTP。

补充动态绑定保护：可选 ownerIsCurrent 在点击执行前和异步读写继续前重新求值。旧卡片尚未重建时，即使按钮上一帧 enabled=true，owner 已失效也不能用新账号发起读／写或打开旧详情。账号管理返回、反馈票据、自动读态也检查归属。详情返回阶段使用独立 owner 检查，保留原本“刷新暂禁动作但仍可读取同账号收藏权威态”的语义。

初版7个缩略图用例与既有40项已 **47/47、exit 0**，见[初版测试日志](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-author-preview-heart-039/targeted-tests.log>)。新增“不pump就直接调用旧按钮／图片回调”和“pending read 后 owner 失效”两项后，最终为 **9个缩略图用例＋40项既有回归，49/49、exit 0**，见[动态owner回归日志](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-author-preview-heart-039/owner-tests.log>)。组件与新测试定向 dart analyze 为 **No issues found、exit 0**，见[静态分析日志](<D:/Flutter_Projucts/PicaComic/PicaKeep/docs/verification/pixiv-author-preview-heart-039/analyze.log>)。scoped git diff --check 通过。

首次执行在进入测试前遇到并行设置文件编辑中间态：引用的_PixivDetailFeedCountTile构造函数当时尚未落盘；该失败任务已收集。主会话确认集成稳定后执行上述47项有效测试，没有重复运行正在执行的任务。所有后台任务结果均已收齐。

```powershell
$tempPath = 'D:\Flutter_Projucts\PicaComic\PicaKeep\.dart_tool\039-heart-temp'
New-Item -ItemType Directory -Force -Path $tempPath | Out-Null
$env:TEMP = $tempPath
$env:TMP = $tempPath
flutter test --no-pub --reporter expanded test/pixiv_author_preview_bookmark_test.dart test/explore/online_recommendation_card_test.dart
```

没有构建、安装、真实收藏GET/POST或用户数据删除。作者横排和关注列表的页面集成由主会话完成，本记录仅负责共享 compact 卡片和收藏交互回归。
