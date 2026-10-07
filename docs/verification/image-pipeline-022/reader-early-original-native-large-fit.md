# 首个原图提前交接与 JPEG 完整适屏候选 · 2026-10-06

本次冻结两个显式 profile 候选，默认均关闭：

- `earlyOriginalRaster`：只在 `fullOrdinaryImage=true` 时生效。Page 已确认权威原文件、FileStat 和完整元数据后，提前提交一个完整原坐标、density=1 的首个 PNG 原图作业。
- `nativeLargeFit`：只对 Native backend 的静态 8-bit JPEG 完整适屏生效，解决已测 4000×6000 JPEG density 0.5 输出 24MiB、超过旧 16MiB whole-fit 门槛后退回多 ROI 的情况。

两者都不改变原文件、原始像素、1:1 放大路径、Surface painter、`onPresented` 语义或默认路由。profile 参数由 harness 显式传入；真实设备 A/B 完成前不应打开默认值。

## 早交接候选

`ReaderOriginalRasterHandoff` 在同一次 Page resolve 中保存 `File`、`FileStat`、元数据、backend 和 source lease。它先用普通 `ImageWorkScheduler` 估算并预留 `working + outputPixels*3`，再做源一致性检查和有限 PNG header 扫描：要求 PNG、静态、8-bit RGB/RGBA、无 ICC/cHRM/cICP/HDR/EXIF/动画块，gamma 只能是 sRGB 45455，尺寸必须再次匹配已解析元数据，文件和解码 RGBA 总量均不超过 64MiB。未满足任一条件立即走原有 Surface 路径。

前置元数据条件不满足时不创建 handoff，保留原有 Surface 路径；已创建 handoff 后若完整 header、源快照或 codec 校验失败，则明确显示错误，不把回退成功算成候选通过。

作业完成后，图像会留在 handoff 中，直到 Surface 完成 resident 预算检查、再次校验源文件并同步调用 `take()`。这段等待仍保留 scheduler reservation 和原文件 lease，避免“codec 返回即释放”造成峰值漏记。切页、卸载、源替换、队列取消和 Surface 预算失败都会取消 ticket；如果底层 backend 已开始，必须等它实际返回后再 dispose image、释放预算和 source lease。Surface 接管后才由现有 layer/retire 负责 image 生命周期。handoff 不触碰 native backing writer，也不提前启动未准入的大图 GPU 解码。

最终 Surface 还将普通瓦片和 handoff 图像的“待接收”阶段纳入同一 resident 上限：完成的 `ui.Image` 在等待淘汰帧、源校验或 widget 卸载时继续占用 pending 计账，接管、取消和失败路径均只释放一次。淘汰帧等待仍在 scheduler 工作预算内，并与 cancellation future 竞速；取消后无需再等待一帧才能结束该作业。解码成功后若背板维护 IO 失败，Surface 会在把结果交给 scheduler 前销毁该图像，避免异常路径遗留 GPU 资源。

## JPEG 完整适屏候选

Surface 仅在以下条件同时满足时把 JPEG fit 作为一个完整 `ReaderTileDemand`：Native backend、非远端 locator、format=`jpeg`、静态、8-bit、无色彩 profile、density<1、当前可见 source area 至少 75%、目标输出不超过 32MiB，且两个输出边均不超过实际 texture capacity probe 的 `textureEdgeLowerBound`。未经过 probe 的 0、过小 cap、ICC 或 partial continuous viewport 都保留原 tile/grid 路径。转为 1:1 后仍使用原 native ROI；候选不会把适屏图放大冒充原像素。

native backend 的 JPEG quick path 仍负责解码和尺寸，Surface 继续按相同 scheduler 预算、source stat、lease、resident 64MiB / global 192MiB 限制运行。候选没有把 25MP 原图整张上传 GPU，也没有改变 idle backing 版本或持久 cache key。

## 验证边界

`test/reader_original_raster_handoff_test.dart` 的 14 项覆盖：ready 后预算和 lease 仍在、转移一次、运行中取消、ready 未消费取消、scheduler 全局取消、排队取消、估算期间取消、预算拒绝、backend 失败恢复、源在 decode 中替换、源在 Surface 等待时替换、PNG chunk/尺寸拒绝、真实 Surface 首显/retire，以及 Surface 直接拒绝 resolved identity 时的 ready 图像取消/drain。`test/reader_image_surface_test.dart` 新增 3 项 JPEG 路由覆盖：准入的 2000×3000 完整图、cap/ICC/default/partial guard、1:1 回到 ROI grid。

Windows Flutter test 四文件组合结果为 47/47 通过（当时 handoff 12、Surface 18、backend 6、完整工作流 11），日志 `E:/picakeep-image-pipeline-022-work/early-original-native-large-fit-regression.log`。最后补入 scheduler 全局取消传播 hook 和 Surface resolved 校验早退 cancel 后，独立 handoff 再测为 14/14，通过全部新旧用例；相关 5 个源码文件最终 analyze clean。该结果证明生命周期、像素尺寸和路由边界；不证明 Android Impeller 的首帧时延、GPU 上传或 OS RSS。

普通图已有数据仍以 `reader-ordinary-*-30.json` 为准：baseline 只测 single 直接 `Image.file`；double/continuous 的普通图基线未覆盖，不能外推。Redmi 4000×6000 JPEG 证据见 `reader-4000-jpeg-redmi-30.json`，旧候选退回 grid 的性能不能直接作为新候选的通过结论。新候选必须在相同 source、cache mode、layout、DPR、texture probe 和 OS RSS 旁路采样下重新 N30。

## 冻结来源

- `reader_original_raster_handoff.dart` SHA256 `668f70a314cb01c20792690be8afa34c9f97af82c26b775c0b9d707784070c84`。
- `reader_page_image.dart` SHA256 `cf41fdd625affc6f1049a306980c70dbe09f9ac85460047523a6be37ce2387f1`。
- `reader_image_surface.dart` SHA256 `d853116d6286092cfde3ea22e3add401ffd1919b8555e886d3024365a4c8b180`。
- `reader_original_raster_handoff_test.dart` SHA256 `9db11f27aef5049d136faf6aab0654d700ec8f9fe913c36e854a717d12d3560b`。
- `reader_image_surface_test.dart` SHA256 `8962ea0ba1b07e4615e55b88424db1eb520f6a70f6322e9bc037859392a6b7a3`。
- `image_core.cpp` SHA256 `11a0063e451188e4d9852d403563b164b537b0ef104646d640a114007a6f5b07`，本候选没有修改。

本轮没有执行 Flutter application build/run，也没有操作 Android 设备；仅运行 Surface/hand-off widget tests。两文件组合共 36 项通过，三文件 `dart analyze` 无问题。

最终异常所有权维护还覆盖了 `ReaderRasterCache.load` 在缓存 codec 已创建图像、复核源 FileStat 抛错时的释放，以及 Native/Flutter backend 在 cache persistence 初始化失败时对尚未返回图像的释放。实际 codec 故障注入、正常像素/alpha/cache、raw unsupported/cancel 组合测试 22/22 通过，相关四文件 analyze 无问题。新增测试在 E 盘 TEMP/TMP 重跑；首次 C 盘 compiler temp ENOSPC 的尝试不计通过。

- `reader_raster_cache.dart` SHA256 `612b19b77b7df422454b604376ee71324ad4fc886616344a2106f120ace56300`。
- `reader_raster_backend.dart` SHA256 `9b18acaaf884e3bd8ef296dc8fbb317cb38ac803b38656f942bea14d5871540d`。

## raw 同步路径隔离参数

新增 `ReaderPageImage.persistRaster`，默认 `true`；profile harness 用 `--persist-raster=false` 禁用 local Native/Flutter/Bounded backend 的读写 raster cache，JSON 同时记录 `persistRaster`。普通 Flutter backend 切换到 native ROI 也转发该值，避免适屏关闭缓存、放大却意外启动 GPU 回读。

`ReaderRasterCache.save` 在 bounded diagnostics 中记录 `rasterCachePngEncodeStartedUs`、`rasterCachePngEncodeEndedUs`、`rasterCachePngEncodeWallUs`、像素数与 PNG 输出字节数。开始记录没有对应结束记录只能表明编码未返回，不能单凭此宣布泄漏、GPU 失败或首帧完成。真实缓存 codec/编码诊断回归 4/4 通过，相关源码与 harness analyze 无问题。

显式 backing 的 profile 清理还移除了一处自等待：临时 `FileReaderPageSource.dispose()` 等同一原文件所有租约清空，其中既有显式 probe 租约，也有当前可见 Surface 的 resolved lease；同步等待会卡在后续 `_close()` 之前。现在 prepare 完成后只释放 probe 自己的两个租约，Surface 留到正常 `_close()` 清理。原始 PNG/JPEG 数据与应用生命周期未改。先前 rawSync 停滞不能因此直接归因为 Impeller，同 snapshot 的 `persistRaster=false/true` 与 backing estimate/submit/ready 标记才可定位。

- `image_pipeline_022_profile_main.dart` SHA256 `c9d2c6dd5f8928231a39236abb08f682baf550572f8d4ac1de6c3032a651e79e`。
