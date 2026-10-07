# 最终默认阅读器生命周期与磁盘 query（2026-10-06）

## 原始报告

报告 `reader-final-default-lifecycle-redmi.json`，311,675 字节，SHA-256 `8967e356510b6b6bb3dd44839ef583ff00c2d8c03b8ce8a0d2c710bacbc946c7`；run `2026-10-06T05-31-28-176561Z`，Android profile，USB `8021129d`、PID `17322`。开始 UTC `05:31:28.202844`、结束 `05:46:56.529455`，15 分 28 秒，状态 `completed`、errors=[]。

仅使用既有 profile harness 的任务源/任务缓存，输入为 `/data/local/tmp/picakeep-native-022/8000x12000-interlaced.png`，1,209,123 压缩字节、8000×12000、静态 PNG8、无 ICC、Adam7；该输入的原像素 RGBA8 工作集为 384,000,000 字节，不能按小压缩文件长度当作小图。报告 DPR 2.75、刷新率约 120Hz。

本轮实际选项：tilePixels=512；ordinary-full、viewport-region、bounded-png-fit、raw-sync、native-large-fit、early-original-raster 均 false；persistRaster=true。只有 lifecycle/disk-space 组。生命周期 fit 的 measure=false，所以 `samples=[]`、`summary={}` 是设计上的未计时状态，不是有 0 错误就取得首显速度/原像素 ROI 成绩。`requestedSamplesPerGroup=1` 也不改变 lifecycle 内固定的每组合 10 次。

报告通过现有 `tools/capture_image_pipeline_022_android_report.ps1` 从明确 run-as 任务路径读取，保持设备报告原始字节；JSON 校验了 schema、runId、完成状态、六组各 10 条及每一条资源字段。最初使用旧 Windows PowerShell 5 启动脚本因 `.ArgumentList` 不存在而在进程构造前失败；随后在当前 PowerShell 运行相同脚本成功。没有修改 capture 脚本，没有 force-stop、安装、启动、改 options、清缓存或构建。本记录只捕获测试自然结束的结果。

## 60 次退出回收

single、continuous、double × sharpFirst、previewFirst，每组合 10 次，总计 60 次。逐条 `afterExit` 和最终诊断均校验以下值为 0，字段缺失也按校验失败处理：

- residentBytes、activeSurfaces、activeJobs、queuedAndRunningJobs。
- reservedWorkingBytes、reservedTemporaryBytes、originalFileLeases、pendingRasterCacheBytes。
- diskQuota activeBytes、idleBytes、pendingClaims、pendingOperations。
- native activeJobs、queuedJobs、jobsFailed、workerStartupFailures。

原生作业 completed=3151，failed=0、cancelledBeforeExecution=0、startupFailures=0；线程池仍保留 2 个 idle worker，不能把“作业与预留归零”写成线程也全部销毁。queuePeak=23。全轮 diskQuota rejectedCount=0、lastRejection=null。

退出前单页/连续 active raw 上限 384,000,128 字节，双页 768,000,256 字节，分别是一个/两个原像素 backing 的实际持有；active 临时额度与 idle LRU 是不同用途。退出前 resident 上限清晰单页/连续 24,000,000、预览 30,000,000、双页 12,000,000 字节。退出过程还会 drain raster 编码/写入、源 lease 和 quota，再清除本轮记录的 backing 和 reader cache；因此退出后的 idleBytes=0 不能替代正常产品保留缓存时的 LRU 行为验证，也不是未等待 IO 就提前释放预算。

退出耗时包括 drain/任务缓存收尾，不是首显指标。每组 N10 的 P50 / 最大值（单位 ms）：

| 布局 | 清晰优先 | 预览优先 |
| --- | ---: | ---: |
| single | 1348.307 / 1404.521 | 1583.945 / 1612.193 |
| continuous | 1367.461 / 1846.704 | 1690.208 / 2197.068 |
| double | 394.633 / 408.620 | 406.761 / 423.993 |

## App UID 磁盘查询

对任务 files、任务 cache、cache 下尚未创建的深层目标，三次 query 均成功，availableBytes=93,536,899,072、logicalVolumeId=`posix-device:66322`，targetCreatedByQuery=false。该结果证明 app UID 的真实 query 能沿最近存在祖先读取余量而不创建查询目标。它没有给其他进程锁住磁盘，也不是主动磁盘不足/跨 Android FUSE 域别名压力测试。

## OS 旁路观察

两段记录均只读同一 PID `17322`、startTimeTicks=`96166193`，以 `run-as cat stat/status/smaps_rollup/stat` 检查进程身份，没有 PID 重用；原始 status、smaps 字段同时保留，各窗口 summary 明确“不评估内存验收”。两个计数是顺序 OS 读取，不是与 Dart 同时采样。

| 记录 | UTC 覆盖 | 样本 / 错误 | smaps RSS 字节范围 | smaps PSS 字节范围 |
| --- | --- | ---: | ---: | ---: |
| `android-lifecycle.jsonl` | 05:31:45.175855–05:34:44.177411 | 180 / 0 | 192,278,528–235,610,112 | 125,573,120–168,841,216 |
| `android-lifecycle-final-minute.jsonl` | 05:47:25.603564–05:48:24.613135 | 60 / 0 | 265,187,328–265,216,000 | 198,209,536–198,258,688 |

首段只覆盖初期 single 阶段，约最初 20 轮，没有持续覆盖 continuous/double 全部退出；它的 status VmRSS 范围 87,449,600–180,264,960 字节，64 个样本 RssAnon=0，与同刻附近 smaps 明显不一致。

名为 final-minute 的第二段实际上**始于报告 finishedUtc 之后约 29 秒**，是完成后的空闲观察，不是最后一分钟生命周期活动。smaps RSS 首个 265,216,000、末个 265,187,328 字节（约 252.9 MiB），该分钟波动约 28 KiB；PSS 首个 198,258,688、末个 198,224,896。但 status VmRSS 全 60 条都是 704,512 字节、RssAnon=0，Dart 最终 currentRss 同为 704,512。不能把这项异常低值当作回收完成或真实进程只剩 0.7 MiB。

空闲分钟稳定和 60 次应用内计数归零分别支持自己的范围。两个 OS 窗口之间没有逐退出的配对 RSS/PSS，活动负载/准备状态也不同；首段到末段的差值不能直接定为泄漏或回收收益，**尚不能确认全部 60 轮 OS RSS 增长不超过 32 MiB**。native 堆/GPU/引擎缓存可能继续驻留，应用预算归零不意味着 OS RSS 归零。

OS 文件在 `E:/picakeep-image-pipeline-022-work/os-rss-final-default-lifecycle/`：

| 文件 | SHA-256 |
| --- | --- |
| `android-lifecycle.jsonl` | `01b27e688f579a660981018e8872507431aa6308a3dd8731358d3affa791c6df` |
| `android-lifecycle-final-minute.jsonl` | `0c156430018b1fcd663a60b3478daee0c407690a9bfa8ddbec2938e285c67e9c` |

## 证据边界

这轮证明既有 profile ReaderPageImage/Surface 默认策略在指定 96MP Adam7 输入、三布局两模式下反复退出能等待真实工作和持久化收尾，60 次内部资源/空间计数归零，原生失败为零。它不是正常 `PicaKeepApp` 导航/保存/分享验收，不包含原像素 pan 或画布像素比对，也没有给出首显性能结果。此前独立像素/原文件/协议证据继续由各自报告承担。
