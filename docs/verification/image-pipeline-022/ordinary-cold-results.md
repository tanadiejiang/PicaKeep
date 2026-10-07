# 022 普通冷首显、同步原文件交接与有界 PNG 适屏候选

2026-10-06。本文记录已执行的回归及待设备 A/B 的候选；不改变原验收标准。默认 `fullOrdinaryImage=false`、`viewportRegion=false`、`boundedPngFit=false`，普通 Flutter 原图阈值仍为 64MiB。纹理细条探针和有界 PNG 候选尚未经过本轮设备验证，不能标速度或质量通过。

## 冷首显证据

同源 3000×4000 PNG、Redmi、每组 N30，正式首显为匹配真实图像 build 的 engine rasterFinish 减 request timestamp。各阶段分位数不可相加；下面的剩余时间按每个样本扣减之后再统计。

| 策略/组 | 正式首显 P95 ms | pageResolve P95 ms | Flutter codec P95 ms | 每样本剩余 P95 ms |
| --- | ---: | ---: | ---: | ---: |
| 原完整 Flutter baseline（full 矩阵） | 102.282 | — | — | — |
| full ordinary cold | 121.373 | 8.015 | 84.400 | 38.495 |
| full ordinary warm | 139.572 | 9.827 | 89.694 | 49.719 |
| 原完整 Flutter baseline（adaptive 矩阵） | 99.657 | — | — | — |
| adaptive cold | 166.556 | 6.067 | 100.602 | 39.528 |
| adaptive warm | 106.018 | 9.999 | cache decode 38.873 | 45.157 |

Evidence：`reader-ordinary-full-redmi-30.json`、`reader-ordinary-adaptive-redmi-30.json` 的 `rasterStages`。adaptive cold lookup P95 1.829ms、warm lookup P95 20.256ms。剩余包含调度、其他异步阶段、UI build 和 raster，不可全归一次空帧。12MP 完整 image 超过既有 ReaderRasterCache 的 4MP 限制，full 的 warm 仍解原文件，不能称实际派生盘命中。

原链路 Page.resolve → setState/build → Surface.openOriginalFile → post-frame viewport → decode → build/raster，第二次 open 返回晚于首次 viewport 时会多等待一个 frame。仅先移除该重复等待，不提前无预算启动 decoder。

## 已冻结的同步交接

`ReaderResolvedOriginal` 只由 PageImage 实际原文件及同次权威元信息构建，保存 source 实例、stable identity 与 metadata 之前的 FileStat。父页面 handoff lease 与 Surface lifetime lease 覆盖首个 decoder 启动前、所有 frame 与 disposal；每个 decoder 的原文件 lease 继续保留。remote `RasterReaderPageSource` 的 locator 拒绝进入该模型。

Surface 同步拿到 file/metadata 后仍等真实布局计算 viewport，再经既有全局预算开始解码。解码前后 stat 核对 size、modified、changed 和 source identity，换源则丢弃解出的 image。切页、刷新、dispose 与候选参数切换均增加 generation；旧异步 metadata 结果只在 generation 仍匹配时发布 backend/compatibility 状态。未提供 resolved 的 fake/source 路径继续原有 open。

验证：`reader-resolved-original-final-regression.log` 中 21/21（surface 8、全工作流 11、Flutter backend 2）；相关三文件 analyze clean。包含不重复 open、无在飞 decoder 时仍保护原文件、旧 identity 拒绝、decode 中替换源不发布，以及原应用读取/保存/复制工作流。性能尚待同源 N30 A/B；不能把 38ms 剩余全算作已省时间。

## 4000×6000 的实际差距

| 同源 PNG / 设备 | baseline P95 ms | native cold 适屏 P95 ms | native diskWarm P95 ms |
| --- | ---: | ---: | ---: |
| Windows | 127.643 | 185.633 | 36.803 |
| Redmi | 163.3（主任务四舍五入） | 1008.18 | 319.86 |

Evidence：`reader-4000-png-windows-30.json`、`reader-4000-png-redmi-30.json`，精确值以 JSON 为准。Redmi 适屏 density0.5 得到 2000×3000、24,000,000 B，超过现 wholeFit16MiB，所以多原生 crop 需要构建/读取原像素 backing。previewFirst cold 约1614ms；预览不能代替正式清晰层。Windows 独立 native quick-fit P95 176.091ms 只含 native，并非 UI 首显。完整 Flutter 实测127.643ms，不使用“肯定低于100ms”的推测。

## 引擎边界与独立纹理探针

本地 SDK engine stamp 为 `425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb`；其 [Skia generator](https://github.com/flutter/flutter/blob/425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb/engine/src/flutter/lib/ui/painting/image_generator.cc) 调用 codec 的 scaled dimensions；[Skia resize 路径](https://github.com/flutter/flutter/blob/425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb/engine/src/flutter/lib/ui/painting/image_decoder_skia.cc) 在不支持预缩小时先解完整再缩小。指定目标尺寸不能当作解压内存上限。

[Impeller 代码](https://github.com/flutter/flutter/blob/425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb/engine/src/flutter/lib/ui/painting/image_decoder_impeller.cc) 会限制 target 到设备最大纹理边长；source 超边长则 CPU resize。GPU resize 可同时保留解码 buffer、原纹理、目标纹理和 mips；特定色彩/alpha 转换还可增加中间 bitmap。[Vulkan allocator](https://github.com/flutter/flutter/blob/425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb/engine/src/flutter/impeller/renderer/backend/vulkan/allocator_vk.cc) 从真实 physical device 的 `maxImageDimension2D` 获取边长；[GLES capabilities](https://github.com/flutter/flutter/blob/425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb/engine/src/flutter/impeller/renderer/backend/gles/capabilities_gles.cc) 查询 `GL_MAX_TEXTURE_SIZE`。native 的16384输出 guard 不能代替设备 cap。

`tools/image_pipeline_022_texture_capacity_checks.dart` 的 `runImagePipeline022TextureCapacityChecks(BuildContext)` 独立生成6000/8192/16384×1和1×该边的 RGBA8 细条，每条最多64KiB，逐项占4MiB调度预算。真实 codec 输出记录尺寸与 colorSpace，再临时 Navigator route 匹配 build/raster，Canvas 首/末64个源像素扩展到128×64捕获；逐像素无容差比较。尺寸被缩小或任一像素不同均不计 verified，下界分横/竖和两轴分别报告，异常PNG只写本任务cache。

该探针仅说明被验证边长及首尾内容可绘制，不能证明16384×16384可分配、24MP PNG峰值安全或广色域正确。需要先有设备报告，才向下述候选传实测 `textureEdgeLowerBound`；默认0拒绝启用。

## 有界 PNG 适屏 profile 候选

`ReaderPageImage(boundedPngFit:false, textureEdgeLowerBound:0)` 显式开关；合格文件才选择 `BoundedPngFitReaderRasterBackend`。要求静态PNG、RGB/RGBA8、无ICC、原decoded≤128MiB、原文件≤64MiB、两条源边均≤实测texture下界。解码前在预算内逐 chunk 检查最多1MiB header，额外排除 cHRM/cICP/HDR、EXIF、动画和非sRGB gamma，避免 native metadata 仅标ICC而漏掉引擎色彩工作区。

仅 density<1 且完整原坐标的 fit 输出≤32MiB可用 Flutter；continuous 即使只可见原图的一小部分也可用同一有界完整fit级。到1:1或ROI、格式/尺寸/cap不满足时仍调用 native backend，正式原像素层绝不从fit放大。codec 实际尺寸/颜色变化报错，不默默复用较低分辨率。

工作估算为 `sourcePixels*20 + outputPixels*16 + encodedBytes*2`，Surface 另保留原先的3份输出字节交接收费；1GiB全局作业预算、单surface64MiB与全局192MiB resident保持。4000×6000、density0.5示例约648MB（另加encoded×2），远高于只计24MB显示image，因此并发可被队列阻止。此为保守准入估算，仍需OS旁路峰值证明；取消不等于 Flutter native codec 已结束，预算、codec和原文件 lease持续到实际完成再释放。

已验证：`bounded-png-fit-regression.log` 29/29（surface12、backend6、全工作流11），相关五文件 analyze clean。新增真实 codec 同原奇数alpha PNG缩小像素一致、1:1及未验证texture由native执行、预算不足不启动whole codec、非ICC色彩chunk拒绝、4000×6000 partial continuous仍获得真实2000×3000 image且回到1:1 ROI。没有用小fake bitmap冒充完整fit。

下一步由主任务统一冻结快照，先跑双端纹理探针，再同源N30比较适屏cold/warm/preview和OS内存；成功前不变默认、不抬阈值。需覆盖切页取消、两页并发、清缓存generation、原导出字节，以及放大正式层的真实原像素 capture。所有日志在 `E:/picakeep-image-pipeline-022-work/`，没有设备/build由本支线执行。
