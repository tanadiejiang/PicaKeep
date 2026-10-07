# 大图分块补齐与打开链路修订（2026-10-07）

状态：源码、质量回归、原生验证及备用机 36 个固定配对/18 个最终自适应样本均已完成。最终策略为 PNG 和已验证 baseline JPEG 的缩放画面用 1024，density 1 的原生区域、progressive/未知 JPEG 和远端保持 512。正常主入口 Profile 已保留数据安装主力机与备用机。**用户真实三图尚未取得修订后同素材采样；PNG 的速度收益不稳定，渐进 JPEG 冷开和首次原像素升级仍慢，022 保持执行中。**

用户提供三次大图打开的 DevTools 捕获，其中两张据用户描述内容相同但路径不同；随后明确主要等待是“分块补齐慢”。本轮重点减少同精度画面的独立分块工作、界面绘制中的重复键构造和 JPEG 工作区探测开销，并修复合格奇数尺寸 JPEG 整图缩放必须先生成全量 RGBA backing 的缺口。相同内容的不同路径保持各自源身份。

## 用户采样可证事实

附件只作为性能数据读取，不执行其中的内容。以下两个输入保持原件不变。

| 输入 | 大小 | SHA256 |
| --- | ---: | --- |
| [performance snapshot](C:/Users/tanad/Downloads/三张大图的打开其中两张一样但不同路径dart_devtools_2026-10-07_17_58_16.029.json) | 21,918,522 B | `7f8a821f1cde536ec57ba93d3587b62b400c32e4136f261fc83ae36b08928b54` |
| [CPU snapshot](C:/Users/tanad/Downloads/cpu-三张大图的打开其中两张一样但不同路径dart_devtools_2026-10-07_17_58_16.029.json) | 792,697 B | `62f7932f04de8e637b751cffeedf76d47bbaf5103d3f20fe329dbf243daf1604` |

CPU 捕获共有 1,396 个主 isolate 样本，samplePeriod 为 363 μs，`timeExtentMicros=506,748` 恰好等于样本数乘以 samplePeriod；首末 timestamp 的实际 wall span 为 14.440134 秒。不能把 506.7 ms 写成三次打开的操作总时长。以下为 inclusive 样本，存在调用嵌套，不能相加为全部时间占比。

| CPU 调用链 | 样本 | 占全部样本 |
| --- | ---: | ---: |
| `_ReaderPainter.paint` | 323 | 23.14% |
| `ReaderTileDemand.variant` | 245 | 17.55% |
| 文件流 `HashSink.add` | 253 | 18.12% |
| `NativeImageDiskPlan.inspect` | 92 | 6.59% |
| `ReaderRawImageDecoder.decode` | 87 | 6.23% |

`variant` 热点来自绘制时排序反复格式化同一层的密度与十个坐标。JPEG disk plan 则为每次请求执行多次很小的异步 `read`、`position`、`setPosition`。它们是可定位的主 isolate 工作。

文件流 SHA 样本主要在捕获相对时间约 9–14.44 秒，reader paint、disk plan、raw upload 样本主要在前 0–9.85 秒。源码中的派生 PNG 读写会做完整性校验，这与后段活动吻合；但跨异步文件流的 CPU 栈丢失具体 caller/path，**不能据此把 SHA256 判为首屏慢的原因**。完整性校验没有关闭。

Performance 为 Android Flutter 3.41.6 profile、120 Hz 捕获。Perfetto 保留 37.860281 秒、70,251 个事件、35,103 个完整 slice；Flutter 模型有 446 帧，timeline 配对到 437 个完整 Frame。Flutter build P95 5.464 ms、最大 13.992 ms；raster P95 3.419 ms、最大 12.186 ms。本捕获不能支持“主线程连续数秒被阻塞”的结论。

`UploadTextureToPrivate` 共 169 次，合计 1,072.596 ms；`DecompressTexture` 169 次合计 321.780 ms。`EncodeImage` 共 44 次、合计 1,967.362 ms，发生在引擎 `1.io` 线程，不能等同于主 isolate CPU 或认定全部来自阅读 tile。下表采用 reader 将 ImageCache 配额改为 96 MiB 的事件作阅读状态代理；它不是手指点击或原图解码开始标记。

| 阅读代理窗口 | 起点至恢复/捕获末尾 | 配置后首个 texture upload | 窗口内 upload |
| --- | --- | ---: | ---: |
| 1 | 0.987093–10.949514 s | 839.085 ms | 47 |
| 2 | 13.029434–21.478972 s | 291.239 ms | 60 |
| 3 | 21.995999–37.860281 s | 547.766 ms | 60 |

47/60/60 是 texture 事件计数，可能含其他图像，不能写成原图解码次数、分块数或屏幕首像素耗时。各窗口持续 texture 活动跨数秒，与用户分块补齐反馈吻合，但正常应用没有 Reader 阶段 Timeline、source ID、路径、几何或点击标记，无法逐张确定 native wait、backing、排队和 raw 上传的完整关键路径。也无法从捕获判断哪两次是相同图片。

## 修订后的行为与边界

| 触发条件或开销 | 修订后的行为 | 质量与资源约束 |
| --- | --- | --- |
| 合格本地原件缩放画面需要多块补齐 | `ReaderPageImage.tilePixels` 改为可空配置；PNG 与已验证 baseline JPEG 的 density<1 网格默认 1024；progressive/未知 JPEG、其它格式和远端仍为 512。`nativeTilePixels` 令 density 1 的原生区域默认 512，测试或 profile caller 可显式覆盖 | 原 `ReaderViewportDemand` 精度级别、原坐标和 gutter 不变；没有降低密度。16 MiB/4096 整图 fit、每 surface 64 MiB、全局 192 MiB 与 scheduler 准入保持原限值 |
| 每次新块到达绘制都重新格式化排序键 | `_ReaderLayer` 在 immutable demand 建层时保存一次 `variant`，Painter 使用已有键排序 | density、active-request、inverse-area 和 variant tie-break 顺序保持；透明接缝及原像素绘制方式保持 |
| JPEG 每个请求用大量小异步 IO 扫 SOF | disk plan 使用一个 64 KiB 块扫描 JPEG marker，最高扫描 8 MiB；长 metadata payload 用 seek 跳过；native source probe 使用同一 parser 一次分类 `baselineJpeg` | 没有跨路径 header 缓存；分类以原 engine 的 encoded 两轴校验，读取前后核 size/mtime/ctime 与 probe 前 snapshot。其它 SOF、未知、非法、截断、源改变或读取失败不启用更大的 JPEG 网格。普通页面已验证 metadata 可依现有 session 身份复用 |
| 例如 6001×9001、density 1/8 的 whole fit 输出 751×1126，旧整数除法得不到分母 8 | Native 按 `d ∈ {2,4,8}` 匹配两个输出轴是否分别等于 `ceil(source/d)`，将实际 d 传入 JPEG scaled IDCT | 仅完整原源、x/y 为 0、orientation 1、8 bit、无 ICC、实际 SOF0、无现存 backing 时新增快路；不扩大 whole fit 输出容量，不改变 1:1 或原 exact ROI 路径 |
| 新缩放策略可能命中旧派生 PNG | native raster 的 pixelVersion 更新为 `native-srgb-premultiplied-rgba8-fit-filter-v4`；session pixelIdentity 更新为 `reader-pixels-v2` | Flutter 自身像素版本保持；旧 native 原像素 RGBA backing 格式不改，因为其原像素未改变；源件不会被修改 |

新增 native SOF0 确认只在符合新的 whole-ceil 几何候选时执行；使用有界 stdio marker 读取和 seek，拒绝 extended SOF1、lossless SOF3 等其它 SOF。它没有给任意 ROI/tile 增加扫描，也不聚合 JPEG 编码像素。Dart disk plan 的省写盘条件同步匹配 native；native 最终预算、取消、源 pre/锁后/post stamp 与 backing 锁校验仍执行。

这轮没有将试验用 `nativeLargeFit` 默认开启、没有硬填未实测的 8192 纹理边界，也没有对两条不同路径直接合并缓存。当前 native backing 的 fingerprint 只覆盖文件前 4096 字节，无法证明两条路径的全文件内容一致；Dart raster/session key 保留 path、源版本、完整几何与像素处理身份。

## 已完成的质量验证

根任务完成 [基础回归日志](D:/picakeep-image-pipeline-022-work/large-open-1007/reader-base-tests1007.log) 的 73 项测试，及 [最终定向回归日志](D:/picakeep-image-pipeline-022-work/large-open-1007/reader-final-tests1007.log) 的 39 项测试。两批存在重叠，不能写成 112 项不同测试。覆盖 source/lease、原像素绘制、cache/source replacement、budget/cancel、zoom/viewport、原源与远端路径等行为。

[reader_tile_grouping_test.dart](D:/Flutter_Projucts/PicaComic/PicaKeep/test/reader_tile_grouping_test.dart) 在 2048×2048 原生密度画面分别运行 512 与 1024 网格，完整截图的 16,777,216 个 RGBA 字节逐项相等，原生覆盖面积相同，透明接缝样本正确。请求从 16 变为 4，最终常驻像素同为 16 MiB，退出后 resident/pending/scheduler/source lease 均归零。这是分组质量与资源验证，不能直接当作真实 JPEG 手机上的提速倍数。

产品与测试的三份 Dart analyze 均为 `No issues found`：[产品](D:/picakeep-image-pipeline-022-work/large-open-1007/analyze-product1007.log)、[JPEG header 与 surface](D:/picakeep-image-pipeline-022-work/large-open-1007/analyze1007.log)、[新增测试](D:/picakeep-image-pipeline-022-work/large-open-1007/analyze-tests1007.log)。

原生独立 CMake **Debug** DLL：`D:/picakeep-image-pipeline-022-work/large-open-1007/native-build/Debug/picakeep_image_engine.dll`，SHA256 `78042f584552df5652a574f5bc5dfd5683aecf3c5eec9bdca04eb5bcff258013`。其 standalone 测试不构建或启动 Windows 应用。[32 项 JPEG 回归](D:/picakeep-image-pipeline-022-work/large-open-1007/native-jpeg-ceil/jpeg-ceil-fit-verification1007.json) 已通过：

- 643×967 的 RGB 4:2:0、RGB 4:4:4、gray，各 d=2/4/8，共 9 例。与独立的同版本 libjpeg-turbo 全 scanline decoder 比较，全图所有字节相等，包含奇数尺寸末行末列；参考工具不调用 native region/crop/backing 实现。
- 3 例原整除 scaled fast path、4 例 exact 1:1 ROI 与旧 DLL 输出逐字节相等。
- progressive、ICC、EXIF6、extended SOF1 各 d=2/4/8，共 12 例仍创建原 backing；partial-ceil 也保持原 backing。
- 2 例 memory/cancel 拒绝正确；1 例 6001×9001 大源新增 fit 不创建 backing，源 SHA 不变。

Pillow IJG 9.0 同 IDCT 分母结果作为附加比较保存，部分高频 4:2:0 输入与 vendored libjpeg-turbo 存在跨 codec 色度差异，不能称跨 codec 逐像素相等。PASS 的精确参考是独立同 vendor 全 scanline decoder；最终 1:1 ROI 同旧版零差。

[额外大源全图像素对照](D:/picakeep-image-pipeline-022-work/large-open-1007/native-jpeg-ceil/large-ceil-full-reference1007.json) 将 6001×9001 d=8 的 751×1126 RGBA 同独立 full scanline reference 逐字节比较，零差；源 SHA 未变、diskBytes=0。既有 [verify_pixels.py 回归](D:/picakeep-image-pipeline-022-work/large-open-1007/native-pixel-regression1007.log) 同新 DLL 再次通过，包含 22 条成功 decode 记录、8 个 EXIF 方向、alpha、tile seam、并发、取消、budget 和源版本变更。

32 项测试中的本机大源单次 native 时间为旧版 488,904 μs、新版 167,765 μs；工作区写盘从 216,060,132 B 变为 0。它没有 Flutter 布局、调度、raw 上传或屏幕显示测量，且仅一次本机原生样本，**不得写成手机打开时间缩短到三分之一**。

## 手机配对结果与最终策略

备用机显式 `192.168.5.3:5555`、serial `8021129d` 上运行独立 profile harness，原件均为 8000×12000 匿名本地 PNG、baseline JPEG、progressive JPEG，host/device SHA 一致。每种源分别以固定 512 与固定 1024 网格运行，六次 harness run 各包含 3 次冷 fit 和 3 次原生区域，共 36 个完成样本。[配对原始与汇总](D:/picakeep-image-pipeline-022-work/large-open-1007/paired-20261007T102855664966Z/paired-summary.json)、[设备和原件 SHA 记录](D:/picakeep-image-pipeline-022-work/large-open-1007/paired-20261007T102855664966Z/session.json) 保留。

| 原件 | 冷 fit：固定 512 / 1024 的 matched raster 中位数 | 原生区域：固定 512 / 1024 中位数 | 结论 |
| --- | --- | --- | --- |
| PNG | 1738.897 / 1585.638 ms | 229.257 / 474.641 ms | 缩放补齐受益有限，原生区域固定 1024 明显更慢 |
| baseline JPEG | 4906.700 / 1598.928 ms | 560.319 / 2448.033 ms | 此素材缩放补齐明显受益；原生区域固定 1024 更慢 |
| progressive JPEG | 12938.478 / 14032.689 ms | 304.643 / 1746.319 ms | 冷原生解码/backing 主导，不能声称缩放提速；原生区域也不采用固定 1024 |

两种固定配置冷 fit 均 density 0.25、complete=true、覆盖同一完整源；fit native 阶段从 24 降至 6。分块 gutter 导致解码输出像素略有差异（固定 512 的 6,076,240 对固定 1024 的 6,028,032），画面采样密度未改变。native ROI 目标都实际位于 presentedSourceRect，density 1、complete/nativePixels 均通过；但是固定 1024 读取的额外周边像素显著增多，因此最终代码保留 512 原生网格。

这些值把 complete callback 的 build timeline 与实际 FrameTiming.rasterFinish 配对，不等于 compositor 扫描输出或手指点击到屏幕首像素。N=3 只是工程对照，不能当 N=30/P95 验收；两批 OS page cache 未控制，native 阶段和预取可能重叠，不能累加为关键路径。比较使用最终 SOF0 native 但固定 tile 配置；最终默认策略的另外 18 个样本在下节单独报告，不能把固定 1024 所有指标直接当最终正常包指标。

`ReaderRasterMetadata.baselineJpeg` 为可空字段，默认 null；只有 native probe 对当前原源完成有界 SOF0 分类且源 snapshot 一致时为 true。Progressive/unknown JPEG 为 false，非 JPEG 保持 null。原 SOF0 header 解析在 encoded 两轴上检查，即使 EXIF6 的展示轴互换也不会误判；没有 native ABI 变更。[分类测试源码](D:/Flutter_Projucts/PicaComic/PicaKeep/test/reader_baseline_jpeg_metadata_test.dart) 包括 SOF0/2/1/3、轴不符、截断、源替换、缺文件和实际 baseline/progressive/旋转 JPEG，[四项运行全部通过](D:/picakeep-image-pipeline-022-work/large-open-1007/native-baseline-metadata-tests1007.log)。

最终自适应版本另完成 [36 项既有回归](D:/picakeep-image-pipeline-022-work/large-open-1007/reader-adaptive-existing-tests1007.log)、[5 项实际 native disk 预算回归](D:/picakeep-image-pipeline-022-work/large-open-1007/native-disk-adaptive-tests1007.log) 和 [2 项网格质量回归](D:/picakeep-image-pipeline-022-work/large-open-1007/reader-adaptive-grouping-tests1007.log)。第一份日志原注册的 5 个 native 环境跳过项已由第二份配置正确 fixture 后全数通过；不把跳过算通过，也不与前述批次重复累加。网格测试包含 fit→native 切换时保留旧像素、解码未完成时跨区平移、迟到取消结果释放、返回 fit 全画布相同及最终资源归零。最终产品/工具与 header 静态分析均无问题。

### 最终自适应默认策略补验

最终 adaptive profile harness SHA `9B9521EE28B54D96C679C908C883F37A738EF298D9E1C78FB0E78E014C37EFB6` 在同一备用机完成三次 run，各含 N3 冷 fit 与 N3 原生区域，共另外 18 个样本。`adaptiveNativeTiles=true` 经报告核实，`ReaderPageImage.tilePixels=null` 实际走生产默认策略。[自适应原始结果与汇总](D:/picakeep-image-pipeline-022-work/large-open-1007/paired-20261007T105325747590Z/paired-summary.json)、[详细结论和限制](D:/picakeep-image-pipeline-022-work/large-open-1007/paired-20261007T105325747590Z/adaptive-findings.md)、[安装和恢复记录](D:/picakeep-image-pipeline-022-work/large-open-1007/paired-20261007T105325747590Z/session.json) 单独保留，未覆盖原固定 512/1024 记录。

| 原件 | 冷 fit 实际 desired/native 次数 | 冷 fit matched raster（ms，N3） | 原生区域 actual desired | 原生区域 matched raster（ms，N3） |
| --- | --- | --- | --- | --- |
| PNG | 6 / 6，1024 网格 | 1604.171 / 1849.754 / 1876.127 | 15，512 网格 | 1023.268 / 330.043 / 241.638 |
| baseline JPEG | 6 / 6，1024 网格 | 1591.321 / 1610.136 / 1615.742 | 15，512 网格 | 4137.567 / 987.906 / 907.517 |
| progressive JPEG | 24 / 24，512 网格 | 8375.617 / 11050.149 / 11449.389 | 15，512 网格 | 865.042 / 291.379 / 253.604 |

三种 fit 均 density 0.25；所有原生区域均 density 1，native 阶段数 `[30,10,10]`、输出像素 `[7864320,2621440,2621440]` 与保留的 512 原生网格一致。18 个样本 complete=true、均匹配实际 image build 的 FrameTiming，rasterPresentationMs 无缺失；9 个 ROI 的 nativePixels 和目标在 presentedSourceRect 中检查均通过。几何与真实 raster frame 验证不代替精确画布像素/接缝质量测试。

本轮不是严格的版本前后速度 A/B。最终 adaptive PNG/baseline ROI 的部分 wall time 高于原固定 512，尽管区块/像素计数保持同样 512；baseline 初次原像素升级仍为 4.14 秒，progressive 冷 fit 仍 8.38–11.45 秒。当前可以证明默认策略避免全局 1024 产生的额外原像素区块，并减少 PNG/baseline 缩放的独立请求，不能声称所有素材提速或已达 N30 门槛。

全部报告 completed、errors 空。每次最终 resident、activeSurfaces、active/queued jobs、working reservations、originalFileLeases 和 pending raster bytes 均归零。finally 已将原 profile-options exact bytes 恢复、重新核对 fixture SHA 不变，并保留数据恢复 BF217B 旧正常包，firstInstallTime 未变、cleanupErrors 空；主力机未参与此 harness。

## 手机与交付状态

| 验证或交付项 | 最终状态 | 完成依据 |
| --- | --- | --- |
| 最终 SOF0 native guard 的固定网格 profile harness | 872 项产品输入核验通过，已用于上述 36 样本 | [固定网格 harness 输入](D:/picakeep-image-pipeline-022-work/large-open-final-harness-inputs1007.json)、[核验记录](D:/picakeep-image-pipeline-022-work/large-open-1007/harness-identity1007.json) |
| 旧 guard harness | 已隔离，不用于最终算法证据 | `harness-pre-sof0-guard-profile1007.apk` 与对应 record |
| 手机固定 512/1024 同 fixture 配对 | 已完成六次 run、36 个样本，促使保留原生 512 与 progressive 512 | 原始与 summary 上表链接；N3 工程对照，OS cache 未控制 |
| 最终自适应策略 probe 与 quality tests | 18 个实际手机样本、分类及网格回归通过 | [最终 harness 核验](D:/picakeep-image-pipeline-022-work/large-open-1007/adaptive-harness-identity1007.json)，实际默认网格及资源释放见上节 |
| 正常 `lib/main.dart` no-define profile | clean/offline pub get 后构建成功，120.4 秒 | [正常包核验](D:/picakeep-image-pipeline-022-work/large-open-1007/adaptive-normal-identity1007.json)：872 产品输入与快照 SHA 一致，451 实际编译输入一致，APK CRC/签名/版本通过，三个 ABI native 与最终 harness 逐字节相同 |
| 主力正常 profile 覆盖 | 18:56:29，显式 192.168.5.12:5555 / f294cd23 install-r 成功，未启动应用 | [主力安装记录](D:/picakeep-image-pipeline-022-work/large-open-1007/adaptive-normal-f294cd23-install1007.json)：首装时间不变，同一 com.dragon.read ReaderActivity 前后台实例保持 |
| 备用正常 profile 覆盖 | 18:57:05，显式 192.168.5.3:5555 / 8021129d install-r 成功并启动正常 MainActivity | [备用安装记录](D:/picakeep-image-pipeline-022-work/large-open-1007/adaptive-normal-8021129d-install1007.json)：首装时间不变；正常主页历史 11、下载 3、默认图集 0 可见，启动错误筛查 0 |
| 用户真实三图分块补齐 | 尚未取得同素材修订后捕获 | 匿名 harness 无法代替此体验结论 |

只有 debug/profile 应用构建被授权。本轮不使用 release 构建或等价 wrapper；安装必须先验证 APK 存在并使用显式设备，`adb install -r` 保留数据。手机配对测试只使用任务匿名样本；正常主力包不会包含 harness 或改入口。

交付 APK：[picakeep-large-open-adaptive-normal-profile1007.apk](D:/picakeep-image-pipeline-022-work/picakeep-large-open-adaptive-normal-profile1007.apk)，61,906,601 B，SHA256 `1DDA99859E657E50A0153F4551BB337F80DE058D0462B252822F05205FBAFDB0`，versionCode 9 / 1.9.92，既有证书 SHA256 `31b4434516ccc1f58add7cc5cd4b6786e995c957d5891d3685e4c75a7a58d7c7`。先前 pre-SOF0、pre-adaptive 和 pre-freeze APK 均为隔离历史构建，未交付或安装主力机。测试配置恢复后两个手机都是本轮正常包；原 main forward 21173 保留。未卸载、清数据、修改用户文件、提交或推送；桌面实际 UI/性能继续暂缓。

## 证据链与复跑

### 插画瀑布流到阅读页的已解码封面衔接（追加）

用户进一步说明等待较慢的大图均从插画瀑布流进入，且部分图快、部分图慢。本追加将点击时实际的 `_illustCovers[entry.id]` 经条目现有 `createReadingPage`/`createLocalReadingData` 工厂传给 `ReadingData.loadCachedPreview(ep, page, url, ReaderResolvedOriginal)`，由 `image_view` 接入 Page/Surface 的可选缓存预览接口。普通打开入口和阅读数据构造仍可省略该参数。

`CoverThumbnailCache.cloneCachedReaderPreview(provider, original:, snapshot:, originalSize:, validatedAliasPath:)` 仅借用已完成的 Flutter ImageCache、provider 已解码首帧或已有待持久化图像，返回独立 owned clone。它不调用 provider.resolve/loadImage，不读编码像素、不打开新 codec、不等待未完成图像；miss 返回 null，原图工作照常继续。已暂停瀑布流的 canContinue 不影响既有像素复用，清缓存代数和源 snapshot 仍有效。

复用限定已核实的普通单文件、单页、episode/page/work/path 身份相同且 reader source 为 authoritative FileReaderPageSource。压缩包、多页、多章节、preview-only 或异路径均拒绝。内部副本只能由 LocalLibraryManager 使用 `_coverCacheEntryKey(item)` 或 `_illustCoverStageEntryKey(item, originalPath)` 的当前 LocalCoverCache 指纹索引核实；仅同名、同尺寸或某个自定义 cover path 不构成关系。clone 前后校验原文件与 cover provider 所捕获的 size/mtime/ctime，图像限 4096 边/4 MP且展示比例匹配。

预览是低密度 display-only 层，Surface 独立检查源和资源预算；不写原图/session cache，不使正式 desired 分块提前 complete，不用于保存、分享或收藏的原件。正式像素补齐后可淘汰预览，退出或拒绝时释放所借句柄。没有宣称降低最终清晰度或解决渐进 JPEG 的原生 backing 冷等待。

[reader_cached_cover_preview_test.dart](D:/Flutter_Projucts/PicaComic/PicaKeep/test/reader_cached_cover_preview_test.dart) 包含六组用例：暂停后的已显示 cache 命中及 clone 释放、未知 provider/已驱逐缓存不启动 decode、待持久化像素独立 ownership、形状/源/snapshot/代数失效、两种索引的单文件副本与 stale 拒绝、work/page/URL/多图错误绑定。追加产品和测试 Dart analyze 无问题。20:00 已完成 147 项相关回归、同包 18 样本首幅/补齐手机对照及正常 APK 双机安装；九个已有封面复用首幅 24.223–44.704ms，渐进完整仍 13.550–15.449秒。最新正常包为 C1BB13A7…，本文件前述 1DDA9985… 交付属于上一阶段。完整条件、范围与身份见 [首幅画面续修](large-image-first-raster1007.md)。

| Evidence | Finding | Path |
| --- | --- | --- |
| CPU 的 Painter/variant 栈及 disk plan 小 IO 栈 | 多块补齐时重复键构造和 JPEG header 读取是实际主 isolate 开销 | 建层键只计算一次；64 KiB 有界 header 扫描；本地分组减独立请求 |
| 用户分块补齐反馈、三段持续 texture 代理活动 | 应验证同精度完整画面更少独立 native/UI 图像交付 | 512/1024 全 bitmap 质量比较、36 固定网格和 18 最终默认手机样本；真实三图及 N30 仍待验 |
| 源 6001×9001 与 ceil 输出、旧分母判定、新旧 native 记录 | 合格 whole-ceil JPEG 旧路径先写完整 backing | 严格 SOF0/无 ICC/orientation 1/完整源的有界 IDCT fit；独立全 scanline 像素验证 |

原生回归使用本机已验证路径；以下调用必须先具备 Debug DLL 和独立 reference executable，生成内容仅位于显式 task artifact 目录。

```powershell
& 'D:/Anaconda3/python.exe' 'D:/Flutter_Projucts/PicaComic/PicaKeep/packages/picakeep_image_engine/native/tests/verify_jpeg_ceil_fit.py' --library 'D:/picakeep-image-pipeline-022-work/large-open-1007/native-build/Debug/picakeep_image_engine.dll' --baseline-library 'D:/picakeep-image-pipeline-022-work/flutter-build-v2/windows/x64/runner/Profile/picakeep_image_engine.dll' --scaled-reference 'D:/picakeep-image-pipeline-022-work/large-open-1007/native-build/Debug/pki_jpeg_scaled_reference.exe' --artifact-dir 'D:/picakeep-image-pipeline-022-work/large-open-1007/native-jpeg-ceil' --large
```

离线分析保留 [CPU 结构化结果](D:/picakeep-image-pipeline-022-work/large-open-1007/large-open-cpu-analysis1007.json)、[CPU 分段与解释](D:/picakeep-image-pipeline-022-work/large-open-1007/large-open-cpu-findings1007.md)、[Perfetto 结果](D:/picakeep-image-pipeline-022-work/large-open-1007/user-perfetto-summary.json)、[slice 明细](D:/picakeep-image-pipeline-022-work/large-open-1007/user-perfetto-summary.slices.json)、[代理阅读窗口](D:/picakeep-image-pipeline-022-work/large-open-1007/reader-cache-windows.json)、[trace 解释](D:/picakeep-image-pipeline-022-work/large-open-1007/user-perfetto-findings.md)。这些文件分别描述采样栈、引擎事件和源码行为，不把其中一种证据替代另外一种。
