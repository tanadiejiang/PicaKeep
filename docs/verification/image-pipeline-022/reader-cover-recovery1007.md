# 本地阅读与漫画封面失败恢复

2026-10-07（Asia/Singapore）。022继续执行中。本轮根据果核调查接收后的代码对照，实际修复可复现的恢复机制缺口；尚未复现用户那份本地漫画的具体故障，因此不把这些缺口等同于该数据集的根因。

## 本轮行为变化

1. **队列暂满自动补试。** Dart native worker满队列现在返回独立的 `ImageEngineQueueExceeded(limit)`，保留status3兼容。native backend把它转换为 `ImageWorkQueueExceeded`；内存/磁盘不足等普通status3仍原样失败，不按错误文本判断。ReaderPageImage源/metadata解析最多额外补试2次（120/240ms），Surface当前可见瓦片最多补试2次（150/450ms）。达到上限显示正常重试入口，手动操作重置额度；换源/退出取消旧等待。
2. **取消与坏图分开。** 普通/prepared解码及backing准备的native status2统一成为 `ImageWorkCancelled`，由已有代次/取消逻辑处理。其它native错误保持原样。取消后的真实token、图片、工作预留、文件租约与配额仍在既有finally释放。
3. **源重选保护清理。** 同一页面的resolve串行进行，旧source迟到/metadata迟到不发布到新页。临时Deferred与自定义source等待真实清理；确切普通 `FileReaderPageSource` 不拥有或删除原件，其全局路径lease排空在后台完成，避免邻页引用同一文件时阻塞当前页重载。公共lease和源dispose契约未改。
4. **本地漫画封面有限恢复。** `DownloadedComicTile` 的普通FileImage及local_cover/local_file provider错误后5秒补试一次：只清该provider原始失败字节/显示缓存，再重挂Image。相同源与解码目标保留显示provider实例，父重建或重新构造同key provider不绕过额度；换源复位，后台/隐藏路由/销毁取消timer，恢复前台只给失败项一次机会。既有物理尺寸目标、普通文件快路和非本地来源行为保留。

缺失原文件、身份变化、真实解码错误或硬预算失败仍准确报错，不自动无限循环。本文不声称降低所有图片耗时，也没有启用ordinary full、prepared-read、native encoded PNG等性能候选。

## 证据、发现与调用路径

| Evidence | Finding | Path |
| --- | --- | --- |
| [修复前队列回归](D:/picakeep-image-pipeline-022-work/reader-queue-before1007.log)确实失败：队列暂满后出现TextButton；[修复后](D:/picakeep-image-pipeline-022-work/reader-queue-after1007.log)3项通过 | F-01 shared scheduler拒绝短暂满队列曾进入永久tile失败集 | P-01 当前可见variant→估算/队列准入→typed暂满→有界延迟→重新准入→完整画面；持续满载保留显式恢复 |
| [Reader/native/调度组](D:/picakeep-image-pipeline-022-work/reader-recovery-tests1007.log)62通过/1能力跳过；真实既有DLL SHA `039E09EAE0A232418865E7F308637712C9AAED2ACDEFC7A59AB75225B09114B4` | F-02 native取消原先以ImageEngineException(2)透传；native worker queue与硬预算同status3缺少类型区分 | P-02 native token取消/worker准入拒绝→typed backend结果→取消不写失败/队列有限恢复→finally账归零。真实token取消覆盖不等于任意长解码即时取消 |
| [源/封面/原图交接组合](D:/picakeep-image-pipeline-022-work/source-cover-recovery-tests1007.log)76通过；[源最终13项](D:/picakeep-image-pipeline-022-work/source-recovery-shared-lease-final1007.log)全部通过 | F-03 metadata前失败原先只能手动；串行恢复还须避开普通文件的跨页面全局drain | P-03 选源→打开/metadata→队列分类→旧attempt/拥有临时文件的source清理→当前generation重新选源；普通文件peer lease不阻塞重载/晚到源切换 |
| [封面初次组合](D:/picakeep-image-pipeline-022-work/cover-recovery-tests1007.log)51通过/1失败；[最终封面7项](D:/picakeep-image-pipeline-022-work/cover-recovery-final1007.log)通过 | F-04 ImageCache驱逐不让已挂载错误ImageState重读；新建CoverDecodeTarget又让父重建绕过补试额度 | P-04 本地失败→等待负缓存TTL后清该失败字节→显示key驱逐→受次数限制重挂Image；相同显示目标保留provider，永久失败最多初次+一次补试 |
| [真实native worker smoke](D:/picakeep-image-pipeline-022-work/worker-pool-recovery1007/smoke.log)、[私有lifecycle故障注入](D:/picakeep-image-pipeline-022-work/worker-pool-lifecycle-recovery1007/lifecycle-result.json)status=passed | F-05 新typed满队列保持limit128/status3兼容，工作池其它失败恢复未回退 | P-05 隔离生成的private pool测试→启动/退出/排队失败→原像素恢复→排空；不是Android性能或活跃FFI强杀证明 |

最终不同Flutter回归合计142通过、1按能力跳过。重复运行的回归没有重复计入总数。测试包含真实PNG/StreamImageProvider/FileImage解码、真实native DLL取消和pool饱和、源/metadata晚到、常失败上限、同文件peer租约、换源及退出清理，以及既有alpha/gutter/原像素/调度/原件交接与卡片显示回归。[最终分析](D:/picakeep-image-pipeline-022-work/recovery-analyze-final1007.log)和[源末轮分析](D:/picakeep-image-pipeline-022-work/source-recovery-final-analyze1007.log)均无问题；新增代码已格式化。

## 实现入口

| 文件 | 职责 |
| --- | --- |
| [ReaderPageImage](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/pages/reader/reader_page_image.dart) | metadata前重试、串行选源、源清理与generation |
| [ReaderImageSurface](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/pages/reader/reader_image_surface.dart) | 当前可见variant有界恢复、timer回收及诊断 |
| [reader_raster_backend](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/foundation/image_pipeline/reader_raster_backend.dart) | 明确typed队列转换、native取消归一化、资源finally |
| [engine Dart API](D:/Flutter_Projucts/PicaComic/PicaKeep/packages/picakeep_image_engine/lib/picakeep_image_engine.dart)和[worker_pool](D:/Flutter_Projucts/PicaComic/PicaKeep/packages/picakeep_image_engine/lib/src/worker_pool.dart) | 独立的Dart满队列异常类型；不改native ABI |
| [comic_tile](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/components/comic_tile.dart) | 本地失败封面重挂、稳定显示provider及恢复额度 |

## 构建与剩余工作

正常 `lib/main.dart` Profile产物由D盘隔离快照构建；输入清单为 [recovery-profile-inputs1007.json](D:/picakeep-image-pipeline-022-work/recovery-profile-inputs1007.json)，868项/38,777,679 bytes，逐文件核对0差异。源修复后的最终包及备用机安装/启动证据由 [CHECKPOINT](CHECKPOINT.md) 本轮记录给出。初次增量构建115.8秒成功，但最终在隔离目录clean、离线恢复依赖后重新构建，避免保留旧APK封装空洞；没有清理工作区/用户数据或卸载应用。

下一步仍需在用户真实本地漫画记录实际源身份/页面/阶段/错误、复现缺失下载封面，并检验手机快速翻页、缺块过渡与清晰收敛。ordinary整页/巨图策略、速度绝对门槛、稳定OS warm baseline、完整正常UI和最终全回归尚未完成。Windows应用UI/性能验证仍暂缓；本轮Windows Flutter测试/隔离DLL只验证共享代码机制，不宣称桌面应用已验收。
