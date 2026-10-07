# 插画长列表回看与封面等待修订（2026-10-07）

状态：最终冻结代码的 106 项定向回归及静态分析通过，正常 profile 已保数据安装主力机和备用机；备用机 96 项匿名列表正常停顿往返的磁盘暖加载机制已验证，样本清理与设置恢复已收束。用户真实捕获确认了全局图片缓存驱逐及封面请求秒级等待；本轮针对磁盘配额排序、尚未落盘像素复用、持久化溢出补盘与磁盘暖加载调度修订。**主力真实 PNG/ZIP 长列表、持续快扫且未等补盘就反向、进页布局/GC/语义长尾仍未达成完整体验验收，不将本轮当作 022 全计划通过。**

用户反馈发生在正常 profile 包：启动进入“图集 → 插画”等待加载，退出再进入，滚动未看过内容仍慢；从头滚到底再回头，部分已看封面也重新加载且慢。上一轮仅六个匿名作品全部 memoryHit 的验证，覆盖不到这个超过解码缓存容量的真实长列表场景。

## 用户证据与分析边界

| 原始证据 | 大小 | SHA256 |
| --- | ---: | --- |
| [performance snapshot](C:/Users/tanad/Downloads/插画滚动等待封面dart_devtools_2026-10-07_16_55_55.295.json) | 47,756,850 B | `c676c462320d8f036ab8e418ad2111c30ab422a2a77d8715e03baa205bdca8e9` |
| [CPU snapshot](C:/Users/tanad/Downloads/cpu-插画滚动等待封面dart_devtools_2026-10-07_16_55_55.295.json) | 4,629,907 B | `14ea64a73b9e2c69f9b4b6c6f015cc86634dac81ce11bff741536992e935e546` |

两份 snapshot 为 DevTools 2.54.2、Android Flutter 3.41.6 profile 应用的捕获。performance 保存 2,985 条 Flutter frame metrics，120 Hz；其 Perfetto traceBinary 含 137,014 个 TrackEvent。CPU 保存 9,345 个 samples，全部来自同一主 isolate/UI 线程。CPU timestamp 实际跨度 46.9518 秒；导出的 `timeExtentMicros=3,027,780` 等于 sampleCount × 324 μs，是采样累计尺度，不能说用户操作只持续 3 秒。

### 解码缓存容量与回看重载

performance 的 END annotations 提供直接缓存证据：

- 34 个完整 `checkCacheSize` 中有 31 次驱逐，合计 42 个 `CoverDecodeKey`、6 个 `FileImage`。整理后的全局缓存只有 35–46 张，195,679,008–201,270,048 B，接近 192 MiB 上限。
- 34 个完整 listener 的单张解码内存中位数 5,961,728 B（约 5.69 MiB），范围 2,568,192–7,749,632 B。多数封面需要约 5–7 MiB，因此内存保留数十张后会淘汰旧封面。
- 54 个完整 `ImageCache.putIfAbsent` 中 20 个返回 `keepAlive`，34 个完成 listener；其中 15 个 `syncCall=true`、19 个 `syncCall=false`。同步 listener 可复用全局缓存之外已有的解码像素，不能将这 34 个全部计为新增解码。

驱逐与用户完整列表回看反馈一致；但键的字符串只有 `Instance of 'CoverDecodeKey'`，没有作品 ID，不能逐件证明哪个被驱逐作品触发了哪次后续请求。

### 等待发生在异步图片链路

完整图片请求中，9 次等待超过 1 秒，4 次超过 5 秒，最长 9.808688 秒。后段 11 个异步请求在相近时间启动，完成被逐步拉开；最长八条在 trace 起点后 46.21–47.07 秒启动，等待 1.604、2.096、2.140、4.658、7.179、7.656、7.759、9.809 秒。这是图片请求到 listener 完成的 wall span，包含排队、读取、解码等等待，不能当作 UI CPU 连续运行时长。

native `DecompressTexture` 共 21 个完整跨度，中位 5.888 ms、最大 456.217 ms；`UploadTextureToPrivate` 中位 10.576 ms、最大 21.056 ms。后段多数解压只有约 1–6 ms，部分 60–155 ms，而图片请求仍等待数秒，因此 native 解压之前的排队和准备阶段也必须检查。

保存的 2,985 条 frame metrics 中，build P95 为 1.826 ms、最大 11.154 ms，2 条超过 120 Hz 的 8.333 ms；raster P95 为 1.918 ms、最大 22.213 ms，4 条超过 8.333 ms。最长 9.809 秒图片请求期间有 218 条 frame metrics，build P95 1.194 ms、最大 1.895 ms，raster P95 1.888 ms、最大 14.007 ms。该区间没有证据表明 UI 连续卡住数秒。

该导出有缺段：Perfetto 仅配对到 1,311 个 `Frame`，不能与 2,985 条完整 frame metrics 等同。跨缺段的朴素栈配对伪出 16.970671 秒 `Frame`、3.389188 秒 `PAINT`、6.539297 秒 `SEMANTICS`，期间实际分别记录了 1,119、172、498 个 frame 起点。离线脚本标记这些不一致跨度，不把它们引用为单帧耗时。过滤后 1,310 个 timeline Frame 最大为 10.474 ms。

用户正常包 trace **没有 `IllustCover.*` 阶段事件**，也没有页面进出、滚动方向、作品 ID 标记。无法从此文件直接分离原图解码、缩略图暖解码、磁盘命中、持久化或首次显像时间。性能数值不会被解释为所有封面均在某一具体队列等待。

### CPU 捕获确认不必要的磁盘缓存排序

CPU 捕获的 inclusive 样本：

| 链路 | samples | 全部样本占比 |
| --- | ---: | ---: |
| `PipelineOwner.flushSemantics` | 2,633 | 28.18% |
| `compareCacheEvictionCandidates` | 2,270 | 24.29% |
| `ImageDiskQuota._trimIdle` | 2,236 | 23.93% |
| `_evictionRank` | 2,203 | 23.57% |
| `PipelineOwner.flushPaint` | 846 | 9.05% |
| `PipelineOwner.flushLayout` | 535 | 5.73% |
| masonry package 任意 frame | 307 | 3.29% |

inclusive 计数可以嵌套，不得相加为总占比。旧 `_trimIdle` 在确认是否需要删除文件之前，每次 admission、commit、abort 都复制并排序整个库存；comparator 每次重新 `p.dirname`、`p.split` 解析两条路径。CPU 栈明确保留 microtask completion → admission/commit/abort → `_trimIdle` → `List.sort` → `_evictionRank` 的主 isolate 调用链，属于真实同步 CPU 工作。按相邻 quota 样本分组可见约 30–52 ms 的活跃采样窗口；这些不是直接量出的完整函数时长。

`flushSemantics` 仍是明显热点，尚未单独修复。不会用关闭无障碍语义的方式掩盖问题。CPU 文件没有 native 编码 wall duration，不能据此称 PNG 持久化占用主 isolate 大量 CPU，也不能用低 CPU 样本占比证明异步 IO 或解码等待很短。

## 本轮实现

| 问题与触发条件 | 修订后的行为 | 保留的边界 |
| --- | --- | --- |
| 没有磁盘额度或物理空间压力，仍排序全部缓存 | `_trimIdle` 和通用库存整理先判断压力，无需删文件时直接返回；有压力时在 `cache-eviction-order` worker isolate 预计算每个路径一次 rank，再排序 | worker 只返回候选顺序；root、ownership、stat、lease、partial、safeParents 和删除授权仍在调用 isolate 核验，await 后再次核对 root |
| 封面已解码并等待 PNG 落盘，但全局 ImageCache 淘汰其像素；回看又从原件解码 | 复用现有持久化任务持有的像素 clone；按 destination、source stamp、publication generation 核验，新的 provider 持有独立 clone 与新页面 callback | 持久化像素预算仍为最多 32 项、合计 32 MiB；没有增加全局 192 MiB 解码缓存，也没有额外扩大常驻像素预算 |
| 长滚动期间超过 32 MiB 持久化 clone 预算，看过的余下封面不再补盘 | 已实际消费首帧的溢出项进入最多 256 个源元数据记录的待补队列；可见工作停止且稳定空闲后，先排空已有像素持久化，再逐项解码、编码、原子发布 PNG | 256 项是源路径、stamp、bucket 等元数据，非 256 张像素；仅同时持有一张临时有界 backfill raster。超限丢弃最早元数据，未显像项不入队；源变化、清缓存或 generation 失效阻止旧结果发布 |
| 返回重进或回头使用磁盘缩略图时，暖解码排在慢原图/后台工作之后 | warm thumbnail decode 使用 `ImageWorkPriority.visible` 的保留前台槽，同时持有可见工作 claim，推迟可选 PNG 持久化 | 仍预留 encoded input 与最坏合法输出预算；不绕过输出/内存限制、不把后台任务全部提升优先级。已开始的 native 编码无法抢占 |

pending raster 和补盘队列解决的对象不同：预算内已经持有的像素可在落盘前即时复用；超预算项只保留元数据，需要等空闲补盘后才获得磁盘暖加载能力。用户在长滚动中立即反向回看、或后台队列尚未排空时，仍可能发生原件重解码。不能承诺所有列表无限保留，也不能声称首次大图解码已消失。

补盘在提交前及 worker 实际开始时核验可见工作 revision；前台工作回来就释放后台槽并等待下一次稳定空闲。回写继续执行 source stat、publication generation、取消、磁盘 admission、`.part` 写入和 rename 规则；返回页面不会沿用旧页面取消 callback。

相关代码：[缓存库存排序](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/foundation/cache_file_inventory.dart)、[磁盘额度](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/foundation/image_pipeline/image_disk_quota.dart)、[封面准备与持久化](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/foundation/cover_thumbnail_cache.dart)。

## 回归检查记录

最终冻结后的 cover 回归与既有本轮 quota 回归共 106 项通过，定向静态分析无问题。早期 freeze 前 37 项通过及 3 个 lint 只保留为过程日志，不替代最终结果。

| 检查 | 当前可证实结果 | 证据 |
| --- | --- | --- |
| 排序与磁盘额度相关回归 | 41 项通过 | [quota-tests1007.log](D:/picakeep-image-pipeline-022-work/cover-return-1007/quota-tests1007.log) |
| cover persistence、pending clone、暖槽与恢复回归 | 最终 freeze 后 65 项通过 | [final-cover-tests1007.log](D:/picakeep-image-pipeline-022-work/cover-return-1007/final-cover-tests1007.log) |
| 最终定向静态分析 | No issues found | [final-analyze1007.log](D:/picakeep-image-pipeline-022-work/cover-return-1007/final-analyze1007.log) |

测试检查了无压力不排序、worker 精确目录排序且不改变输入、既有缓存租约与保护目录；pending 像素在 ImageCache 被清空及新页面 callback 下复用；超过 clone 预算的已显示封面空闲补盘，再清解码缓存后从磁盘读；未显示项不保留 clone 或元数据；暖加载实际排队时推迟可选编码；源变化、publication generation 失效和有限元数据队列。对应 [排序测试](D:/Flutter_Projucts/PicaComic/PicaKeep/test/cache_eviction_sorting_test.dart)、[长列表补盘测试](D:/Flutter_Projucts/PicaComic/PicaKeep/test/cover_thumbnail_backfill_test.dart)、[暖加载槽测试](D:/Flutter_Projucts/PicaComic/PicaKeep/test/cover_thumbnail_warm_scheduler_test.dart)。这些是受控回归，不能替代手机完整瀑布流观察。

## APK 与手机验证状态

在同一最终冻结产品快照上依次执行 clean、offline pub get、profile 构建。诊断构建 120.5 秒成功，正常构建 154.6 秒成功，均为 `lib/main.dart`、profile、arm64 Dart AOT。两个独立身份核验结果确认 870 项当前产品/快照 SHA 对齐，451 项实际 Flutter 编译输入 hash 对齐，没有差异；既有包名 `lingxue.picakeep`、1.9.92/code9 和签名一致，ZIP CRC 通过、最大 gap 0，三个 native ABI 库与基线相同。

| 包 | 大小 | SHA256 | 身份记录 |
| --- | ---: | --- | --- |
| [诊断 profile APK](D:/picakeep-image-pipeline-022-work/picakeep-illust-return-timing-profile1007.apk) | 61,906,601 B | `353E39A0DFB1F06EEC7ECCBE6516FF7B9567DD00E052993119D6F5346757F41D` | [timing identity](D:/picakeep-image-pipeline-022-work/illust-return-timing-profile-identity1007.json) |
| [正常 profile APK](D:/picakeep-image-pipeline-022-work/picakeep-illust-return-profile1007.apk) | 61,906,601 B | `BF217B139C1D639D01C75A17995F010B3053F104B511A3396B1AF0AA1EE0CD39` | [normal identity](D:/picakeep-image-pipeline-022-work/illust-return-profile-identity1007.json) |

诊断包仅启用 `PIKAKEEP_COVER_DIAGNOSTICS=true` 一个 define；正常包无用户 define 或替代入口，正常 AOT 不含 `IllustCover.` 事件前缀。source.total 字符串的存在本身不代表诊断开关开启。构建时间以 [timing build log](D:/picakeep-image-pipeline-022-work/illust-return-fixed-build1007.log) 和 [normal build log](D:/picakeep-image-pipeline-022-work/illust-return-normal-build1007.log) 为证。

主力机先前 ADB 离线，重新连接后实核 DHCP 新地址 `192.168.5.12:5555` 对应 serial `f294cd23`，没有沿用旧地址猜测设备。核 APK 存在和 SHA 后，17:29:57 正常包显式 install-r 成功，firstInstallTime 仍为 2026-10-01 23:32:23，无卸载或清数据；`--no-start` 未启动或 force-stop PicaKeep。[主力安装记录](D:/picakeep-image-pipeline-022-work/illust-return-normal-f294cd23-install1007.json)。根任务现场核对安装前后 `com.dragon.read/.reader.ui.ReaderActivity` 保持同一 ActivityRecord；[本轮前台记录](D:/picakeep-image-pipeline-022-work/cover-return-1007/main-normal-foreground1007.json) 的 before 行转录自本轮安装前实际 adb tool 输出，after 来自安装后重新实时查询，记录注明 provenance。这次后台安装没有产生主力 PicaKeep 视觉或性能验收。记录中的安装前 lastUpdateTime 17:26:48 只作为实际观察，不推测其来源。

备用机 `192.168.5.3:5555`、serial `8021129d` 在 17:26:56 install-r 本轮诊断包成功，firstInstallTime 仍为 2026-06-29 16:42:23，无卸载或清数据；[备用诊断安装记录](D:/picakeep-image-pipeline-022-work/illust-return-timing-8021129d-install1007.json)。本轮 96 个匿名普通文件样本、无 ZIP；[fixture manifest](D:/picakeep-image-pipeline-022-work/cover-return-1007/long-list-fixture/fixture-manifest.json) 与 [传输 SHA 记录](D:/picakeep-image-pipeline-022-work/cover-return-1007/long-list-spare-fixture-transfer1007.json) 保留。全部 source 为测试私有目录可读的普通 JPEG，当前 thumbnail 输出 768×1152；若 96 张全部以此尺寸解码，其像素合计 324 MiB，超过 192 MiB 全局解码缓存容量。

正常 UI 实际滚到了列表两端：[底端 XML](D:/picakeep-image-pipeline-022-work/cover-return-1007/spare-ui/bottom.xml) 包含作品 009–001，[回到顶端 XML](D:/picakeep-image-pipeline-022-work/cover-return-1007/spare-ui/returned-top.xml) 包含 096–088；对应 [底端截图](D:/picakeep-image-pipeline-022-work/cover-return-1007/spare-ui/bottom.png) 与 [顶端截图](D:/picakeep-image-pipeline-022-work/cover-return-1007/spare-ui/returned-top.png) 保留。端点与实际缓存驱逐共同支持列表超过内存容量的往返验证；不把经过范围等同于 96 张逐件冷解码和首像素均验收通过。

| 项目 | 当前状态 |
| --- | --- |
| 最终冻结源文件与编译输入 hash | 两身份记录确认 870 项 source/snapshot、451 项 compiler hash 全部一致 |
| 诊断 profile APK、SHA、签名、ZIP CRC | 独立核验通过，阶段事件不能替代首像素时间 |
| 正常 `lib/main.dart` profile APK、SHA、无用户 define | 独立核验通过，已安装主力 |
| 主力显式设备、serial、安装前后 firstInstallTime | `.12:5555` 实核 f294cd23；17:29:57 install-r 成功，首装时间不变 |
| 备用机长列表首次、回头、退出重进 trace 与截图 | 已证实滚到 001 后返回 096；正常停顿暖加载机制成立，完整持续快扫与无等待反转未严格量测 |
| 备用机恢复与清理 | 默认 Pixiv 路径恢复、未迁移；任务样本精确清理并备份运行 DB，正常 profile 17:45:01 覆盖，首装时间不变 |
| 同条件改前/改后数字 | 尚无，不能宣称具体提速比例 |

### 已取得的备用阶段样本

以下是已闭合并独立配对的窗口。不能将 15 张重进或数十次暖加载写成 96 张全部显示完成。

| 观察窗口 | 图片机制 | UI scope | raster scope |
| --- | --- | --- | --- |
| 初次进页后退出再进，[reentry trace](D:/picakeep-image-pipeline-022-work/cover-return-1007/spare-reentry1007.json) | 15 个 provider.ready 均 memoryHit；无 nativeDecompress 或冷缩略图 backend | 74 个完整 Frame，P95 12.941 ms，最大 45.996 ms | 74 个完整 scope，P95 14.963 ms，最大 17.870 ms |
| 长列表反向慢滚动 up-b，7 份逐 swipe capture，[独立汇总](D:/picakeep-image-pipeline-022-work/cover-return-1007/spare-up-b-pooled-independent1007.json) | 33 次完整磁盘 warmFirstFrame，0 冷 thumbnail.backend、0 backfillEncode；ImageCache 请求跨度 20.404–76.032 ms，P95 67.940 ms；warmFirstFrame 15.182–46.831 ms，P95 43.344 ms | 806 个完整 Frame，P95 6.539 ms，最大 24.073 ms；18 个超过 8.333 ms | 806 个完整 scope，P95 8.909 ms，最大 17.872 ms；76 个超过 8.333 ms |
| 再次完整向底端扫描 complete-down，14 份逐 swipe，[独立汇总](D:/picakeep-image-pipeline-022-work/cover-return-1007/spare-complete-down-pooled-independent1007.json) | 40 次 warmFirstFrame，0 冷 backend 或 backfillEncode；warmFirstFrame 14.491–40.588 ms，P95 38.269 ms；ImageCache 81 次请求含缓存命中，最长 74.876 ms | 1,611 个 Frame，P95 6.481 ms，最大 24.946 ms | 1,611 个 scope，P95 8.555 ms，最大 20.127 ms |
| 随后向顶端回看，文件名 immediate-up-a/b，14 份逐 swipe，[独立汇总](D:/picakeep-image-pipeline-022-work/cover-return-1007/spare-immediate-up-pooled-independent1007.json) | 40 次 warmFirstFrame，0 冷 backend 或 backfillEncode；warmFirstFrame 13.995–39.860 ms，P95 35.566 ms；ImageCache 81 次请求含缓存命中，最长 65.678 ms | 1,612 个 Frame，P95 6.263 ms，最大 12.001 ms | 1,612 个 scope，P95 8.484 ms，最大 15.834 ms |

up-b 七份窗口均配对异常为 0，retained range 分别约 2.00–3.03 秒。VsyncProcessCallback 的 StartTime/TargetTime 明确给出 8,333.333 μs 预算，因此该备用样本也是 120 Hz。本批有缓存驱逐后的磁盘暖读取，未记录再次使用原件解码的 backend 阶段；这些请求跨度为几十毫秒，但不是屏幕首像素测量，也不能与用户主力捕获直接计算提速比例。[每份窗口分析脚本](D:/picakeep-image-pipeline-022-work/cover-return-1007/analyze-spare-return-captures1007.py) 保留实际窗口长度和配对限制。

complete-down 和随后回看各 14 份逐 swipe 窗口也均为 0 配对异常。在这些复看窗口中，零 cold backend 表明已经从磁盘缩略图读取，而不是重新原件解码；不能据此说该批又首次生成了 96 张封面。采样每次 650 ms swipe 后停 2.5 秒，整段末尾又停 3 秒，加上工具/命令边界的空闲，补盘已经有执行机会。**`immediate-up` 只是文件名，不能解释为持续快扫、不停顿、未等补盘就立刻反向的严苛场景已经验证。**

重进样本仍有进页帧长尾：45.996 ms Frame 内含 15.845 ms LAYOUT、12.904 ms BUILD、10.132 ms COMPOSITING；30.152 ms Frame 内含 17.899 ms LAYOUT；21.571 ms Frame 内含 16.472 ms CollectNewGeneration，并出现在 19.402 ms SEMANTICS 范围内。**封面 memoryHit 不代表进页布局、GC、语义或 120 Hz 流畅门槛已通过。** 该设备采用 profile diagnostics，UIAutomation 读取还可能激活或影响语义树；没有同设备同素材旧包对照，不能把这些数值全归因于本轮产品改动，或推断主力的改善比例。

早期 down-a/b/c 把数次 swipe 合成一份捕获，但每份约 32,600 events 接近 VM ring buffer 容量，实际仅保留 6.063、5.752、4.830 秒。b/c 后段没有 ImageCache 请求，不证明其整个 7 次 swipe 都没有解码。后续 up-b 改为逐 swipe 获取并分别存盘，避免把丢失前段当作零工作。[down-a 独立结果](D:/picakeep-image-pipeline-022-work/cover-return-1007/spare-down-a1007.independent-analysis.json) 中直接保留 8 个 CoverDecodeKey 驱逐，作为匿名样本确实触发容量淘汰的局部证据。

已通过正常设置 UI 恢复默认 Pixiv 下载路径 `/data/user/0/lingxue.picakeep/files/download_pixiv`；“转移已下载的数据”未勾选，没有迁移原有作品。[恢复对话框 XML](D:/picakeep-image-pipeline-022-work/cover-return-1007/spare-ui/restore-default-empty.xml)、[默认路径恢复](D:/picakeep-image-pipeline-022-work/cover-return-1007/spare-ui/default-root-restored.xml) 为证。清理前 [主页 XML](D:/picakeep-image-pipeline-022-work/cover-return-1007/spare-ui/home-restored-before-cleanup.xml) 仍显示历史 11 条、原有下载 3 部。

逐文件核对任务 manifest 的 96 张图片及 2 个任务文件，共 98 个命名文件；两处任务 root 与 alias 精确清理，无递归删除。图片与 manifest SHA 未变化，任务 `download.db` 被正常应用添加管理表后改变，先保存 [运行时 DB 备份](D:/picakeep-image-pipeline-022-work/cover-return-1007/fixture-runtime-backup1007/download.db) 再清理；该 DB 仍只有 96 个匿名下载，新增的管理表属于任务样本。未修改用户数据库、清应用缓存或卸载。[清理记录](D:/picakeep-image-pipeline-022-work/cover-return-1007/long-list-spare-fixture-cleanup1007.json) 保存逐文件 SHA、任务 DB 变化与 exact-file 删除范围。

备用机 17:45:01 install-r 同 SHA 的正常 no-define profile 成功，firstInstallTime 仍为 2026-06-29 16:42:23，PID 15743；[正常覆盖安装记录](D:/picakeep-image-pipeline-022-work/illust-return-normal-8021129d-install1007.json)。最终 [正常主页 XML](D:/picakeep-image-pipeline-022-work/cover-return-1007/spare-ui/final-normal-home.xml) 与 [截图](D:/picakeep-image-pipeline-022-work/cover-return-1007/spare-ui/final-normal-home.png) 仍显示历史 11 条、下载 3 部；根任务及设备验证 agent 的 PID 15743 错误过滤为空。该结果只是正常启动与数据可见性检查，不是新一轮封面速度样本。本任务备用 VM 转发 38123 已移除，主力原有 21173 转发保留；[最终收束记录](D:/picakeep-image-pipeline-022-work/cover-return-1007/spare-ui-closure1007.json) 保存端点、样本容量、限制、恢复、清理、正常安装与转发状态。

本轮结论限于机制：没有内存缓存的已看封面在匿名普通 JPEG 列表上走磁盘暖加载，正常停顿往返不再重复原件解码；必要的磁盘淘汰排序离开主 isolate，无压力时不执行排序；超过原有 clone 预算的已显示封面可在空闲补盘。尚需在主力真实 PNG/ZIP、首次长列表持续快扫、补盘未执行前立即反向时量测 source、pendingRasterHit、diskHit、cold/warm decode 与屏幕可见延迟，并单独处理进页布局/GC/语义长尾。没有同条件旧包对照，不宣称改善倍数或全部 120 Hz 帧达标。正常交付始终只使用 debug/profile，安装前核 APK 和显式设备，保留数据。

## 离线分析复跑与证据路径

本轮只读取用户捕获，未修改输入。离线脚本映射已与本机 Flutter SDK 内 DevTools bundled Perfetto decoder 核对，保存 END annotations；标记跨缺段的伪大帧。

```powershell
& 'D:/Anaconda3/python.exe' 'D:/picakeep-image-pipeline-022-work/cover-return-1007/analyze-devtools-cover-return.py' 'C:/Users/tanad/Downloads/插画滚动等待封面dart_devtools_2026-10-07_16_55_55.295.json' --output 'D:/picakeep-image-pipeline-022-work/cover-return-1007/user-perfetto-summary.json'
```

- [Perfetto 结构化结论](D:/picakeep-image-pipeline-022-work/cover-return-1007/user-perfetto-summary.json)、[完整配对明细及 END args](D:/picakeep-image-pipeline-022-work/cover-return-1007/user-perfetto-summary.slices.json)、[配对异常](D:/picakeep-image-pipeline-022-work/cover-return-1007/user-perfetto-summary.anomalies.json)、[分析说明](D:/picakeep-image-pipeline-022-work/cover-return-1007/user-perfetto-findings.md)。
- [CPU 结构化结论](D:/picakeep-image-pipeline-022-work/cover-return-1007/cover-return-cpu-analysis1007.json)、[CPU 分析说明](D:/picakeep-image-pipeline-022-work/cover-return-1007/cover-return-cpu-findings1007.md)、[CPU 分析脚本](D:/picakeep-image-pipeline-022-work/cover-return-1007/analyze-cover-return-cpu1007.py)。

证据链分别为：END args 驱逐与秒级 listener 等待 → 失去解码缓存后回看仍昂贵 → pending 像素复用、有限元数据空闲补盘和暖槽修订；主 isolate CPU 排序调用栈 → 无压力也重复解析排序 → 跳过无效排序并将必要排序交 worker。二者不等价，不能将单个修订宣称为已解决全部封面体验。
