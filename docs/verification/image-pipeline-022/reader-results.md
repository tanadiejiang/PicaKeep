# 022 阅读器验证记录

本文件按轮次保留 profile 与质量证据。最新两端矩阵已完成，各570个真实呈现样本；普通图冷性能与部分ROI尾延迟仍未达目标，不能视为022完整验收。较早smoke与失败记录保留原状态。

## 首轮 smoke

输入是任务目录中的 3000x4000 原文件，profile 模式运行，布局为 single，显示策略为 `sharpFirst`。没有读取用户设置、阅读历史或用户图片。

| 平台 | 刷新率 / DPR | 原文件基线（回调耗时） | 原生 surface 冷（回调耗时） | 原生 surface 磁盘热（回调耗时） | 结果 |
| --- | ---: | ---: | ---: | ---: | --- |
| Android | 120 Hz / 3.5 | 73.090 ms | 442.035 ms | 116.582 ms | 数据完整，但首轮没有可匹配的 rasterFinish |
| Windows | 240 Hz / 1.5 | 108.202 ms | 278.846 ms | 31.152 ms | 数据完整，但首轮没有可匹配的 rasterFinish |

这些数字是从原文件解析请求到 `ReaderPresentedFrame` 回调的墙钟时间，不应被称作 GPU 首帧时间。对应报告为 `reader-android-first-smoke.json` 和 `reader-windows-first-smoke.json`。冷、热含义是任务目录派生层的状态；操作系统文件缓存未清空。

首轮还记录到 Android surface 冷路径 native worker 约 389.511 ms、Flutter image 创建约 10.175 ms；Windows 对应约 252.550 ms 和 3.788 ms。这个比例说明首轮瓶颈主要在原生解码/准备阶段，不代表最终呈现延迟。

首轮的 `missingRasterPresentationSamples=3` 是测量器的时钟关联错误：`onPresented` 在 post-frame callback 中执行，可能已经晚于 `FrameTiming.buildFinish`。这不表示没有绘制，也不表示 raster 失败。现已在 `ReaderPresentedFrame` 记录图片实际 build 时刻 `frameBuildTimelineUs`，后续匹配使用该时刻落在对应 engine build 区间内；匹配不到仍保留为错误，不用邻近帧猜测。

时间关联修复后，Android 新 smoke (`reader-android-final-smoke.json`) 每组 1 次测得真实 engine rasterFinish：原文件基线 106.052 ms、自适应 surface 冷 85.288 ms、任务缓存保留组 100.942 ms，三项都没有缺失 raster 关联，最终图像驻留、作业、临时预算和原文件租约均归零。普通整图这两组实际都走 Flutter codec，约 57.123 / 58.209 ms；缓存保留组名称不代表发生了磁盘派生层命中。该 N=1 smoke 只证明修复后的测量链可运行，不是完整性能分位数结论。

基准与 surface 使用同一个 3000x4000 文件和相同 single/contain 视口。基准完整解码后缩放显示；surface 解码到不低于物理屏幕需求的 0.5 密度（1500x2000），放大到原像素的独立 ROI 组再验证 1:1。这里比较的是适屏清晰画面所需耗时，不能把 0.5 密度的首屏结果当作已完成原像素 ROI。双页组同时显示两页，连续组的视口几何也不同，因此不能把这些组与单页基准直接当作同负载速度对照。

## 像素质量对照

`tools/image_pipeline_022_pixel_checks.dart` 对 9 类 640x960 素材，每类比较非 MCU 边界的 512x512 原像素区域。Flutter `ImageDescriptor` 解码结果和原生区域解码结果都保留真实尺寸、stride、颜色空间、alpha 及逐通道差异；没有设置容差后伪造通过。

- JPEG 4:4:4、JPEG 4:2:0、EXIF 6、PNG8 RGB、透明 PNG、PNG16 ICC、Adam7 PNG16 ICC：首轮样本逐通道零差。
- PNG8 灰度 ICC：实际 Flutter 与原生 ICC 转换最大通道差 1。
- PNG16 灰度 ICC：最大通道差 2，同时存在 alpha 量化差异。
- EXIF 6 的 Flutter 和原生尺寸都为规范化后的 960x640，编码尺寸仍记录为 640x960；没有按编码方向误判尺寸。

灰度/16-bit 差异是两个解码器色彩管理和 8-bit 显示量化的事实记录。它不能被笼统称为“完全逐字节无损”，也不应因此把 JPEG/普通 PNG 的零差结果降级。最终产品策略必须继续使用同一原文件和原像素坐标，针对广色域、高位深素材明确显示能力边界。

## 当前路线和边界

普通小图在工作集不超过 64 MiB 时使用 Flutter codec 解码整图，再按实际解码尺寸映射原图坐标裁切；裁切不会把原图重新压缩。奇数尺寸透明 PNG 的整图/裁切逐像素回归已通过（`test/flutter_reader_raster_backend_test.dart`，2/2）。非整图需求交给受预算约束的原生区域路径，避免重复整图驻留；1:1 原像素密度不降采样。

大图继续使用原生区域解码、文件租约、取消令牌和有界工作集。96 MP、渐进式 JPEG、Adam7 PNG、WebP 的首轮准备成本和磁盘工作区已经在 `native-results.md` 中单独记录；复杂格式不能为了首屏速度偷偷回退到无界整图或有损缩图。

## 首次完整矩阵的失败记录

`reader-android-matrix-first.json` 和 `reader-windows-matrix-first.json` 保存完整原始报告。两端均完成单页基线 30 个样本，以及三布局 × 两模式 × 冷/缓存保留 × 30，共 360 个 surface fit 样本；390 个已记录样本均有真实 raster 时刻。60 次退出重进完成，最终 resident、activeSurfaces、queued/running jobs、working/temporary reservations 和原文件租约均归零。

六个 ROI 组都在第一个样本超时（120 秒），完整矩阵状态仍为 `incomplete`。最后回调已是完整的 `density=1` 原像素区域，且任务队列为空，但记录区域的中心停在升档后的初始位置；这些原始报告的平移目标尚未通过验收，不能把完整 fit 数据当作 ROI 通过，也不能取消两原像素误差判据。

工具已追加仅该进程的 `PICAKEEP_022_ROI_TRACE` / `PICAKEEP_022_ERROR`，记录升档完成、控制器位置、原图矩形、目标和每次平移完成阶段，供下一轮定位。根因修复后必须再跑原像素 ROI，并复核实际产品的一次平移行为，才可接受阅读器矩阵。

后续只读 trace 已确认控制器位置与实际 RenderBox 变换到达目标（Android 原像素中心约 1200/1440），所以问题不能直接归因于外部位置被 PhotoView clamp 清零。`test/reader_single_pan_postframe_test.dart` 覆盖同步呈现回调及 async continuation、DPR 1/3.5 的一次合法平移，不补第二次通知，4/4 通过。该测试使用精确请求尺寸的 fake raster 后端，只验证产品坐标/通知/图层生命周期，不能替代实际原生后端的 ROI 验收。

profile 现场诊断已确认根因：画面已经正确平移，新视口所需图层全部完成，`tickets=0`、`estimating=0`、`error=null`；但呈现去重标记把 `visibleSourceRect` 隐式转换为字符串。在 profile 模式中，该 `Rect.toString()` 只得到 `Instance of 'Rect'`，不同矩形在同一页、密度及完成状态下产生相同标记，合法的新区域回调因此被去重。修复使用 `left/top/right/bottom` 数值构建标记，诊断矩形也改为数值数组。此次问题影响呈现通知和验收等待；现有 trace 不支持“原像素画面未移动或未清晰”的判断。

debug widget 回归中的 `Rect.toString()` 含坐标，故 4/4 单次平移通过不能覆盖这项 profile 差异。修复后的 Android/Windows 真正 profile ROI 正在复验；本记录不会在原始首轮报告上改写成功状态，也不会用测试中伪造字符串行为代替实机证据。稳定身份、缓存键和去重键应取明确数值及版本，不能依赖对象用于调试的 `toString()`。

Windows profile 的连续阅读第 7 个 ROI 样本还暴露了基准工具的另一项几何错误。目标原图坐标是 `(1200, 3720)`；之前将裁切后可见矩形中心作为真实 viewport 焦点，连续页在竖向滚动与 PhotoView 缩放合成后，焦点停在 `(1200, 3391.76)`。后续修正重复使用这个偏移，控制器位置没有变化，因此目标差 328.24 像素，严格的 2 像素判据正确地报失败。这不应通过放宽误差来掩盖。工具现在用实际 RenderBox、contain 绘制区和 viewport 的屏幕坐标反投影焦点；连续模式先滚动目标行进入视口，再做原像素缩放和平移。新的 profile 矩阵尚未完成，故这里只记录根因和修复方案，不记为 ROI 已通过。

`reader-windows-fixed-30.json` 为修复字符串去重后、修复连续几何前的原始 profile 报告，仍是 `incomplete`。该次实际记录 522 个样本：390 个 fit/基线加 132 个原像素 ROI；single 和 double 两模式各 30 个 ROI 样本完成，continuous 两模式只完成前 6 个。所有已记录样本都有 raster 时刻；60 次生命周期检查和最终全部图像/队列/租约/缓存写入预算归零。Windows single sharp 的原文件基线 P95 为 56.222 ms，自适应冷为 51.671 ms，磁盘热为 32.363 ms；这项具体设备结果不能替代尚未完成的 Android 普通冷性能和 4000x6000 必测矩阵。

4000x6000 必测图按 RGBA8 的未缩放完整图工作集是 96,000,000 字节（约 91.6 MiB），大于目前 Flutter 整图自适应路线的 64 MiB 上限，因此该图会选择原生区域路线；这个判定取决于未缩放工作集，不取决于 PNG/JPEG 文件压缩后的字节数。可按 demand density 用 Flutter codec 整图下采样到屏幕适配尺寸，但要重新定义且实测解码器内部峰值预算，不能只用输出像素估算就宣称安全。最高 1:1 ROI 仍需原文件区域后端。

Native 元数据 probe 目前每次通过 `Isolate.run` 执行；native PNG probe 顺序读 PNG chunk header，并在 IDAT 前停止，不解码压缩像素，所以“probe 读完整 PNG”不是已观测问题。隔离启动、动态库/绑定初始化、文件 stat 与 PNG/JPEG/WebP metadata parsing 是可能开销项，但本轮没有拆分计时，不能断定其中任何一个造成约 30% 冷首显退步。下一次冷路径诊断应分别记录 source resolve/stat、isolate 启动与 probe、Flutter codec、首个 build/raster 和缓存持久化；随后比较复用单个 metadata worker、复用已验证 source metadata、以及安全的有界文件头快速路径。快速路径至少必须正确处理尺寸、EXIF 方向、动画标志和 ICC；信息缺失或头部超出限制时退回权威 probe。PNG 的 8 字节签名和 IHDR 可在很小的读取量中取得宽高/位深，但仅检查固定前 33 字节不能判定位于 IHDR 后的 APNG、ICC、EXIF ancillary chunks，不能把它直接当作所有 PNG 的完整 metadata。

普通动图兼容路径仍由 Flutter `Image.file` 提供多帧显示；`ReaderPageImage` 沿用已 probe 的原始方向尺寸作为 PhotoView child 坐标，并继续登记原像素倍率，工具栏原像素操作仍通过 controller 缩放。该路径不提供区域 tile 升档，且大于 64 MiB 工作集的兼容图会明确拒绝，避免回退到无界整图分配。静态原生不支持格式也只有在 Flutter codec 可解析且不超界时才进入兼容路径。

新增独立 `source-copy` 检查只在显式指定组时读取任务 fixture：先以 Root `stat` 验证源大小，再把大于 64 KiB 的 PNG 分块复制到 harness 私有缓存，比较完整 SHA-256、长度和文件签名，最后删除唯一临时副本。Root 不可用时记录 `rootUnavailable` 并跳过，不改用户权限设置；新 USB 设备尚未具备 Root。Dart 侧复制测试覆盖上限、stat 前取消、复制途中取消、部分文件删除和原文件保留；文件租约测试验证暂停的原图流在消费者取消前阻止临时源清理。当前这些定向 Flutter 测试 16/16 通过，Android Root MethodChannel 的实际设备验证仍待有权限的设备执行。随后用户另行授权从主力机只读复制少量已下载样本；已有 `su uid=0` 可用，但应用 Root 开关仍为 0、未更改，也未启动应用，具体输入与边界见 `source-real-download-results.md`，该 ADB 复制不能代替本 helper 的 MethodChannel 闭环。

当前代码定向回归：单次平移 4、surface 图层/取消 3、完整阅读页 11，共 18/18 通过；完整页包含三布局 × 两模式 × 10 次退出重进（60 次）和保存/分享/收藏冻结目标。这里使用隔离任务文件和数据库，不读写用户库、不调用用户相册。它不等价于实机已安装产品 UI 的 60 次自动操作。日志为 `E:/picakeep-image-pipeline-022-work/reader-three-current-regression.log`。

## 2026-10-06 线程池双端完整矩阵

原始证据：`reader-pool-windows-full-30.json`、`reader-pool-redmi-full-30.json`，各570样本、19组各30、60次退出；均completed、errors=0、missingRasterPresentationSamples=0。Windows连续阅读先以每模式8次复现跨第7个目标的几何，再跑完整N30；已到合法目标，未放宽2原像素焦点判据。构建为profile，同一3000×4000 PNG普通原文件和8000×12000 PNG原像素区域，隔离任务源/缓存；Windows与Redmi设备各自同轮对照。

下表为请求至对应engine rasterFinish的P95，单位ms。两端不可横向当作同设备收益；单页基线只与单页普通适屏同负载比较。

| 场景 | Windows | Redmi K30i 5G |
| --- | ---: | ---: |
| 普通single全原图基线 | 65.980 | 94.334 |
| single清晰冷 / 磁盘热 | 56.290 / 26.390 | 158.417 / 154.562 |
| single预览冷 / 磁盘热 | 53.970 / 27.050 | 148.027 / 162.502 |
| continuous清晰冷 / 磁盘热 | 240.630 / 76.170 | 169.097 / 158.455 |
| continuous预览冷 / 磁盘热 | 240.240 / 106.330 | 178.261 / 178.480 |
| double清晰冷 / 磁盘热 | 58.380 / 25.890 | 200.270 / 112.560 |
| double预览冷 / 磁盘热 | 112.690 / 66.510 | 340.494 / 214.767 |
| single清晰 / 预览原像素ROI | 173.000 / 177.610 | 318.236 / 383.882 |
| continuous清晰 / 预览原像素ROI | 271.330 / 292.790 | 629.698 / 652.267 |
| double清晰 / 预览原像素ROI | 540.600 / 541.470 | 1843.840 / 1275.561 |

表中Windows保留三位小数仅为统一排版，精确值应查原始JSON，四舍五入不改变验收。普通cold Windows改善约14.7%，Redmi退步约67.9%；不能宣布20%目标或双端不回退已达到。ROI这个既有组连续计入从fit升原像素再平移的完整工作，包含首次原像素层构建，不应被叫作“全部纯warm tile”。

诊断依据：Redmi double index0和5包含约0.98—1.13秒codec与工作峰值比输出多约177KiB，随后样本多为输出缓冲峰值，符合左右原像素层首次建立；PNG fit快速stream缩图不生成完整backing，当前PNG后端也未进行idle准备。`source warmed by fit`只证明读取过压缩源，不证明完整原像素层已热。旧报告原文与样本保留，后续显式准备的warm ROI应另起组，不删初建数据。共享稳定backing并行读已在native独立N30通过且原像素一致，但这批应用矩阵仍用之前独占版本，不能将独立测试收益移植到此表。

所有60次退出后resident、active surfaces/jobs、队列、源租约、working/temporary和pending raster persistence归零。Windows分组10次afterExit RSS第三至末次变化均在32MiB以内，连续预览从202.57至213.09MiB，不能只用末次计数排除长期增长，仍需最终候选重复验。Android Dart ProcessInfo.currentRss出现0.70MiB等不合理读数，不能用这些数做内存验收；将补/proc status与smaps_rollup旁路采样，保留原报告，不把异常读数称作泄漏或通过。

下一路径：ordinary source/meta/cache/codec各阶段诊断、已冻结shared native与不同tile尺寸的实际应用A/B、4000×6000强制基线、真实surface像素/接缝/alpha与各巨图/长图、最后正常入口及用户可见工作流。独立读取原像素和同一Canvas参考不等于所有三布局产品已经验过所有格式；source与server真实集成证据另见对应文档。

## 2026-10-06 原图整层与瓦片候选对照

普通3000×4000 PNG候选仅在Flutter64MiB上限内请求完整原图层（ordinary-full=true），默认产品仍关闭。分别同轮N30 baseline/cold/diskWarm：Redmi adaptive 99.657/166.556/106.018ms，full 102.282/121.373/139.572ms；Windows adaptive 55.474/52.995/24.231ms，full 54.550/70.479/63.323ms。Redmi完整层降低adaptive冷成本，但仍慢于自己的baseline约18.7%，Windowscold退步约29.2%；不选为正式双端默认。完整12MP超过4MP派生缓存上限，full的diskWarm没有派生层命中，实际仍读原codec；名称不当作热派生事实。输入分辨率/纹理/坐标没有降低。

Evidence：reader-ordinary-{adaptive,full}-{redmi,windows}-30.json，每报告90样本全部matched raster、errors0。source/metadata/cold cacheLookup多为1—10ms，小于codec和额外帧等待；不能只优化metadata声称解决cold退步。后续小候选在PageImage已开原文件/验证metadata后传绑定来源的resolved对象给Surface，保持lease/generation/scheduler，只省重复open和布局帧等待。

共享backing稳定读+tile尺寸的完整ROI对照：reader-shared-512-windows-30.json、reader-shared-1024-windows-30.json、reader-shared-512-redmi-30.json，各12组N30=360样本，真实raster全部匹配、errors0。旧native_roi保留fit→原像素→pan全工作；新增native_roi_prepared显式在计时外准备两页完整backing，原源与ROI不变。准备成本不能被称作免费，cold首次层数据保留。

| 平台/瓦片 | 单页清晰/预览P95 | 连续清晰/预览P95 | 双页清晰/预览P95 | 显式prepared双页清晰/预览P95 |
| --- | ---: | ---: | ---: | ---: |
| Windows512 | 154.740/175.310 | 179.180/168.140 | 564.860/548.970 | 109.420/117.980 |
| Windows1024 | 135.170/174.960 | 159.800/175.480 | 120.350/128.370 | 131.730/125.000 |
| Redmi512 | 318.200/359.450 | 361.120/411.620 | 1390.680/1665.540 | 411.800/445.380 |

Windows共享读后的连续尾延迟满足200ms组目标，双页512初建仍慢；1024版本双页同轮达到200ms。这些差异尚有OScache/布局次序影响，1024的更多像素纹理和缓存复用必须在Redmi也完成A/B，不据此全局默认换档。Redmi512包括显式prepared仍未达到100—200ms，后续查小块跨FFI图像创建/缓存命中等待及1024候选。图像与租约归零不是手机RSS验收，OS旁路单独跑。

Redmi1024候选已完成360样本、0errors、全部raster，报告`reader-shared-1024-redmi-30.json`。single清晰/预览P95为450.71/620.01ms，continuous615.06/670.87ms，double386.43/556.65ms；对应prepared为585.41/616.44、623.61/649.26、358.28/535.56ms。双页初建部分改善，单页/连续比512更慢，不能全局默认1024。单页1024 per-tile native codec P95约11.43ms而UIimage创建约86.07ms、PNG缓存decode约95.18ms，实际覆盖像素因grid外扩多于viewport；加和不是critical-path，stage缺起止不能断言全部重叠关系。

新增仅原像素density1的viewportRegion候选，默认关闭：整数外扩实际可见区域、单边<=16384、输出<=4MP，远程manifest仍原tilegrid，其它情况fallback原grid。harness保留先升原像素中心、再pan目标两次完整等待；不删pan或降低密度。目标是减少1024grid多余像素与多次图像创建，同时每pan仍受原坐标/version/lease/memory/cancel约束，真实速度和像素测试待验。

Windows视口候选实测：`reader-viewport-region-windows-30.json`，12组×N30=360样本、errors0、全部实际raster匹配。单页清晰/预览原像素ROI P95为51.68/104.04ms，连续106.34/94.22ms，双页107.19/113.76ms；显式prepared对应112.21/107.97、96.02/87.43、99.70/107.85ms。该轮使用resolved original交接和native opaque-row-skip的11a006像素核心，未含正在接入的统一磁盘quota；不将本轮数值当最终整包验收。Redmi相同候选正在测，尚不能选为两端默认。

4000×6000同尺寸原文件组：Windows PNG baseline/清晰single冷/磁盘热P95为127.643/185.633/36.800ms；JPEG为345.370/142.220/93.440ms。Redmi PNG163.300/1008.180/319.860ms，普通冷首显明显回退；PNG适屏2000×3000层24MiB超过旧16MiBwholeFit门槛，触发多个原生ROI及首次原像素backing。保持失败证据`reader-4000-{png,jpeg}-windows-30.json`、`reader-4000-png-redmi-30.json`，不以JPEG收益掩盖PNG回退。

新的boundedPngFit候选仍默认关闭：仅静态sRGB8 PNG、原图RGBA不超过128MiB、压缩文件不超过64MiB、源两轴不超过本次run实际纹理端点探针下限；请求完整原坐标适屏层不超过32MiB，density1仍走原生原像素ROI。source工作估计20B/px加output16B/px和encoded两份，仍由共享1GiB工作预算准入；resident64MiB/全局192MiB不扩大。读头拒绝动画、ICC/非sRGB扩展和高精度，不能把engine纹理长边探针称为大二维图内存安全证明。29项定向测试及analyzer已过，尚待实际双端N30/质量/OS内存A/B，未选正式默认。

Redmi视口候选同轮完整结果：`reader-viewport-region-redmi-30.json`，360样本、errors0、缺失raster0。single清晰/预览P95为513.022/538.162ms，continuous519.652/643.548ms，double561.246/816.897ms；prepared分别464.261/554.317、523.884/557.796、748.583/812.532ms。相对512grid，single/continuous回退，双页部分改善但仍远高于100—200ms；不能选为Android默认。最终resident/jobs/lease/working/temp0；worker统计有67个失败返回与2个执行前取消，UI各样本仍完成，后续需按取消生命周期核查这些返回，不能将统计抹去。UI图像创建阶段累计约native wall的3—4倍仅是分段证据，不是关键路径因果证明。

Redmi4000 JPEG第一次输入路径误填不存在的`4000x6000-ordinary.jpg`，尚未产生性能样本即失败；报告`reader-4000-jpeg-redmi-first-failed.json`保留。已改为设备实际存在的`4000x6000-baseline.jpg`复跑，不把工具参数错误记为产品codec失败。

Redmi4000 JPEG正确输入完整390样本：`reader-4000-jpeg-redmi-30.json`，errors0、全部raster。baseline单页P95=577.274ms，single清晰冷/磁盘热1841.419/485.245ms，preview1876.066/585.249ms；continuous清晰1891.386/491.157ms、preview2114.139/539.601ms；double清晰321.889/222.626ms、preview320.382/213.279ms。single/continuous明显回退，double因适屏输出较小改善不能掩盖其余布局。旧16MiB whole-fit门槛在手机单页2000×3000层24MiB落到多ROI，触发JPEG原像素backing。拟测static sRGB8 JPEG原生完整区域quick-fit、输出<=32MiB且实际纹理探针支持、保留75%可见约束与所有budget；只作为defaultfalse候选，不把96MP铺全Flutter GPU。

## 2026-10-06 JPEG完整适屏候选真机实测

`reader-native-large-fit-jpeg-redmi-30.json`：统一快照APK `2B8D34DC...141BEB`、profile、4000×6000 baseline JPEG、native-large-fit=true，run `2026-10-06T04-35-06-515504Z`。390样本、13组各N30、errors0、matched raster缺失0，两轴16384窄纹理端点probe通过。candidate仍默认关闭，输出32MiB/可见75%/ICC等保护保留；超出源原像素倍率仍使用native ROI，不将fit图当原始细节。

同轮single全原文件baseline P95=530.827ms；single清晰cold333.268ms、diskWarm346.168ms，预览cold351.079ms、diskWarm376.270ms。清晰cold相对本轮baseline改善37.2%；旧1841ms跨包结果仅用于诊断，不当作同轮A/B收益。continuous清晰/预览cold366.719/361.927ms、diskWarm344.995/394.191ms；double cold312.167/316.866ms、diskWarm210.521/222.671ms。原始JSON保留准确精度，本文显示值按三位小数。

该次实际原文件与请求密度未变，resident/surface/job/lease/working/temp/persistence最终0，quota active/claims/operations0；worker统计34个失败返回、0执行前取消，UI样本均完成，但这些返回仍须按取消/闲时准备审查，不抹为0。其源码不包含后续Surface pending/异常释放及cache/backend ownership修正，因此收益不能直接替代最终包验收。OS内存旁路、原像素zoom及同源码defaultfalse对照仍待完成。

raw-sync第一次完整矩阵停在single sharp ROI30之后、下一warm fit/explicit backing交界，超过五分钟无最终报告，已保存`reader-raw-sync-first-stall-redmi.json`与原log。旧harness在显式backing estimate/排队/执行间没有标记；无法据此确定UI阻塞、GPU readback或native preparation。新harness追加阶段标记，默认仍false，不能将没有完成的候选声称速度通过。

后续已查明该停滞的确定性工具根因：explicit backing helper在持有自己`ReaderPageFileLease`时先等待`source.dispose()`，dispose又等待该lease，形成自锁。修正释放顺序后必须重新实测；首轮不能作为rawSync引擎失败证据。SDK deferred upload/readback上下文问题仅为仍待隔离的候选风险，不等于本次停滞根因。

## 2026-10-06 有界PNG适屏候选真机实测

`reader-bounded-png-fit-redmi-30.json`，run `2026-10-06T04-40-40-707080Z`，同APK、4000×6000 PNG、bounded-png-fit=true，390样本、errors0、matched raster全部。single原文件baseline P95=161.708ms，清晰cold278.835ms/diskWarm299.559ms；预览cold460.084ms/diskWarm374.240ms。continuous清晰cold316.687ms/diskWarm284.021ms，预览412.320/342.045ms；double清晰399.610/119.289ms，预览363.763/119.455ms。相对之前多ROI的1008ms冷路径有跨包诊断改善，但同轮仍显著慢于baseline，不能默认启用或宣称20%达标。

最后resident/jobs/lease/working/temp0，quota active/claims/operations0，native497个完成、0失败。初次保存报告时文件名误标JPEG-final，核对JSON的boundedPngFitCandidate=true及runId后仅重命名为上述PNG名称，未改原数据；它不是更新资源修正版APK的JPEG重跑。

## 2026-10-06 13:12 最终画布质量与同步隔离候选

`reader-final-quality-redmi-66.json` 与 `reader-final-quality-windows-66-recovery.json` 均为 profile、completed、66/66 exact，尺寸与 RGBA 差异为零，66 项来源 size/mtime/SHA 未变。Windows recovery run 为 `2026-10-06T05-09-23-843887Z`；先前低磁盘空间拒绝的记录仍留在 work 区，未覆盖。最终两端 resident、surfaces、jobs、队列、working、temporary、originalFileLeases、pendingRasterCacheBytes 与 quota active/idle/claims/operations 全为零；native 完成 Windows 1030 / Redmi 1046，失败与启动失败均零。

这是实际 ReaderImageSurface 绘制及持久缓存重开的像素证据，范围是 sRGB8、premultiplied alpha on black、最多 1024×1024 引擎画布读回。参考来自独立原文件区域解码，可共享已验证 backing；不能替代独立 codec 色彩对照、系统扫描显示、宽色域/HDR、所有格式三布局或正常产品操作验收。原图低于本身分辨率的细节不作额外生成承诺。

`reader-final-raw-sync-no-persist-redmi-30.json`：run `2026-10-06T05-03-18-618660Z`，APK SHA-256 `98667BF06B1B143887EA28774DCBAA7493C1DC94A7F42F5ADEED09851E1409A8`，raw-sync=true、persist-raster=false，以排除 PNG 持久编码/readback 的影响。12 组各 N30、360 样本、errors=0、缺失 raster=0，1:1 原像素呈现 complete。此候选未达到 100–200ms 目标，仍默认 false。

| 原像素组 | 单页清晰 / 预览 P95 ms | 连续清晰 / 预览 P95 ms | 双页清晰 / 预览 P95 ms |
| --- | ---: | ---: | ---: |
| fit 后升档及平移 | 511.986 / 650.320 | 579.238 / 666.909 | 578.575 / 585.427 |
| 显式准备 backing 后 | 558.877 / 631.347 | 588.518 / 690.279 | 556.862 / 715.240 |

退出资源与 quota 计数归零，native completed=29060、jobsFailed=243、startupFailures=0。worker 的 jobsFailed 混计 error 返回（包含取消），其中 242 次增量集中于双页组；当前报告未保存逐次错误 code，不能把它们全部解释为正常取消或全部解释为 codec 故障。UI 零错误不抹除该计数。当前数值仅为同步候选自身完成结果，异步同条件矩阵正在运行，未先宣称同步相对收益；此前停滞已定位 helper 自租约等待，不是本次 engine deadlock。

### 异步隔离对照已完成

`reader-final-raw-async-no-persist-redmi-30.json`，run `2026-10-06T05-15-23-070521Z`，与上文同 APK、同设备和原文件、raw-sync=false、persist-raster=false，360/360 actual raster、errors=0；退出各资源/空间账为零，native completed=29154、jobsFailed=231、startupFailures=0。同步相对异步在清晰 ROI 的单页/连续/双页 P95 分别缩短 16.4%/11.6%/4.9%，prepared 双页清晰缩短 20.1%，prepared 双页预览却慢 1.9%；两个版本均未达到手机 100–200ms 目标。不同模式与 prepared 成本仍分组，不用单个胜出组替代整体门槛。

异步连续组运行期间叠加了一次 60 秒 OS 只读采样，同步组没有该采样；两轮也未锁定温度/频率，因此上述是已记录条件下的顺序对照，不能当作无观察干扰的最终速度验收。原始分组数字如下：

| 异步原像素组 | 单页清晰 / 预览 P95 ms | 连续清晰 / 预览 P95 ms | 双页清晰 / 预览 P95 ms |
| --- | ---: | ---: | ---: |
| fit 后升档及平移 | 612.630 / 710.368 | 655.251 / 729.068 | 608.516 / 746.359 |
| 显式准备 backing 后 | 633.964 / 719.821 | 688.429 / 787.897 | 696.587 / 702.164 |

OS 原始旁路为 `E:/picakeep-image-pipeline-022-work/os-rss-final-raw-async/android-raw-async.jsonl`，固定 PID16555、60 samples/0 errors。smaps_rollup RSS 为 199,675,904–275,697,664 B，PSS 为 132,065,280–208,074,752 B；同一设备的 status VmRSS 有 3 次小于 2MiB，同时 smaps RSS 仍约 200MiB，保留两个原始计数，不能把 VmRSS 异常低值当回收通过。该记录是活动阶段观察，不是十轮退出回收验收。

## 2026-10-06 最终默认 96MP 生命周期与 app UID 空间 query

`reader-final-default-lifecycle-redmi.json` 已从 USB `8021129d` / PID17322 的明确任务 run `2026-10-06T05-31-28-176561Z` 完整捕获（311,675 字节，SHA-256 `8967e356510b6b6bb3dd44839ef583ff00c2d8c03b8ce8a0d2c710bacbc946c7`）。profile、completed、errors=0，UTC05:31:28–05:46:56；输入为 8000×12000 静态 Adam7 PNG8。512 tile、所有候选开关 false、persistRaster=true。三布局×两模式×10=60 次退出，每一条和最终 resident/surfaces/jobs/queue/working/temp/source lease/pending raster persistence，以及 quota active/idle/claims/operations 都为0；native completed3151、failed0、startupFailures0，保留2个idle worker。任务文件/cache/未创建深层目标三次 app UID query成功、可用93,536,899,072 B、同logicalId66322，query未创建目标。

本轮只执行 lifecycle/disk-space，fit 的 measure=false，samples=[] / summary={}；没有首显速度或原像素ROI成绩。退出收尾会等待持久编码/写入、真实源lease与quota，再清本轮自己的缓存，因此 idle0 的证据不等于正常产品 LRU 总要清空。详细数字和边界见 `reader-final-default-lifecycle.md`。

180秒 OS 旁路只覆盖初期single约20轮：smapsRSS192,278,528–235,610,112 B、PSS125,573,120–168,841,216 B、180samples/0errors。另60秒名为final-minute的旁路实际在报告结束29秒后开始，是空闲阶段：smapsRSS265,187,328–265,216,000 B（约252.9MiB，分钟内波动约28KiB）、PSS198,209,536–198,258,688 B、60samples/0errors，PID/starttime未变。后段status VmRSS及Dart currentRss都报704,512 B、RssAnon0，和smaps不一致，不能把0.7MiB当回收通过。两窗口没有全程逐退出的配对OS样本，尚不能确认60轮OS RSS增长≤32MiB；内部计数归零与OS驻留分别记录，不推导“OS内存全部归零”。捕获过程未打断设备，未改options/cache或构建。
