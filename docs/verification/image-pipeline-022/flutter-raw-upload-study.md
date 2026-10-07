# bounded native RGBA 到 Flutter 图像路线 · 2026-10-06

`ui.decodeImageFromPixels`不能作为少复制优化：本SDK中它就是现 `ImmutableBuffer.fromUint8List → ImageDescriptor.raw → instantiateCodec → getNextFrame` 的包装。值得单独A/B的是Android Impeller的 `ui.decodeImageFromPixelsSync`，它仍复制/上传，但换成raster deferred upload且本实现只建1个mip。是否改善必须用真实raster测量；sync返回对象不代表图像已上传或可见。当前没有修改生产renderer/ABI、没有实现Texture，也没有执行新的Flutter构建或设备候选。

SDK实际 engine revision `425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb`。cache `sky_engine/lib/ui/painting.dart` 与本地engine源painting.dart完全同SHA `daa0e9b949a1172d2c89c14ccf96046dc0ced8bee8877712efc81f29d4568cab`，确实含sync API。源文件hash列表在 `flutter-raw-upload-sdk-evidence.json`；此研究不假设手机GPUcap，也不把native16384上限当实际设备cap。

## 复制、上传与上下文证据

| 路线 | 本SDK实际行为 | 本轮结论 |
| --- | --- | --- |
| 当前raw descriptor | ImmutableBuffer复制到SkData；RGBA进入bitmap/hostVisible readPixels，再GPUdevicePrivate upload与mips | 有额外CPU复制及GPU工作，但已限定ROI；不能靠重命名API移除 |
| async decodeImageFromPixels | Dart包装调用相同buffer/descriptor/codec/getNextFrame | 不造重复候选，不声称zero-copy |
| sync decodeImageFromPixelsSync | SkData::MakeWithCopy；RasterFromData；deferred raster任务MakeTextureImage，hostVisible readPixels并upload，mip_count=1 | Android Impeller-only独立候选；copy仍在，可能减少mips/调度，未实测 |
| Windows PixelBuffer Texture | nativecallback→glTexImage2D上传，再release_callback | 能绕TTD/SkData/codec层，但仍上传，不是跨端统一直接画内存 |
| Android external Texture | Surface/SurfaceProducer或ImageTextureEntry拥有Image/HardwareBuffer与consumption生命周期 | 要实现平台插件/同步/压力/失效恢复，不能把C++malloc指针当Texture直接交出 |

实际可点击SDK证据：

- [async包装](/E:/SDK/flutter_windows_3.38.5-stable/flutter/engine/src/flutter/lib/ui/painting.dart:2707)；[ImmutableBuffer拷贝](/E:/SDK/flutter_windows_3.38.5-stable/flutter/engine/src/flutter/lib/ui/painting/immutable_buffer.cc:37)。
- [RGBA bitmap路径](/E:/SDK/flutter_windows_3.38.5-stable/flutter/engine/src/flutter/lib/ui/painting/image_decoder_impeller.cc:180)；[所谓zero-op只适用R32Float](/E:/SDK/flutter_windows_3.38.5-stable/flutter/engine/src/flutter/lib/ui/painting/image_decoder_impeller.cc:266)；[async纹理mip_count](/E:/SDK/flutter_windows_3.38.5-stable/flutter/engine/src/flutter/lib/ui/painting/image_decoder_impeller.cc:461)。不要把同文件的zero-op fast path误套到RGBA。
- [sync复制与Skia不支持](/E:/SDK/flutter_windows_3.38.5-stable/flutter/engine/src/flutter/lib/ui/painting/image.cc:93)；[deferred raster upload](/E:/SDK/flutter_windows_3.38.5-stable/flutter/engine/src/flutter/lib/ui/painting/pixel_deferred_image_gpu_impeller.cc:124)；[sync single-mip纹理](/E:/SDK/flutter_windows_3.38.5-stable/flutter/engine/src/flutter/shell/common/snapshot_controller_impeller.cc:188)。
- [Windows PixelBuffer上传](/E:/SDK/flutter_windows_3.38.5-stable/flutter/engine/src/flutter/shell/platform/windows/external_texture_pixelbuffer.cc:83)；[buffer/texture callback生命周期](/E:/SDK/flutter_windows_3.38.5-stable/flutter/engine/src/flutter/shell/platform/common/public/flutter_texture_registrar.h:60)。

现worker `TransferableTypedData.fromList`仍会把native malloc输出复制到transferable空间；主isolate materialize拥有该buffer，ImmutableBuffer又MakeSkDataWithCopy。sync也要Uint8List，并仍做SkData拷贝，不移除worker→Dart链路。使用FFI `asTypedList`也不能省掉后续SkData复制；若跨isolate传native指针则改变现worker独立所有权，必须另建引用/取消/异常退出/防悬垂机制，本轮不扩展。

## 真实Windows跨context告警

`E:/picakeep-image-pipeline-022-work/reader-shared-{512,1024}-windows-stderr.log`、cover-after-frame、4000 PNG/JPEG、viewport-region等日志确实有 `GrBackendTextureImageGenerator: Trying to use texture on two GrContexts!`。它表示同texture在另一个Ganesh context仍被借用时被不同context请求，返回空proxy；不是原图已糊或插件原像素错误的证明。该条件见 [Skia原始实现](https://skia.googlesource.com/skia/+/5a635f2211ce/src/gpu/ganesh/GrBackendTextureImageGenerator.cpp)，此链接只说明告警语义，没有将其revision冒充当前SDK锁定的Skia依赖。

本SDK [image_encoding_skia.cc](/E:/SDK/flutter_windows_3.38.5-stable/flutter/engine/src/flutter/lib/ui/painting/image_encoding_skia.cc:68) 明确跨context texture不能直接makeRasterImage，改在raster thread画入surface，再去IO编码。Impeller [image_encoding_impeller.cc](/E:/SDK/flutter_windows_3.38.5-stable/flutter/engine/src/flutter/lib/ui/painting/image_encoding_impeller.cc:175) 创建readback hostVisible buffer、GPUblit纹理、等command completion后Invalidate并编码，仍需render context current。

产品 `ReaderRasterCache.save`把image.clone延到postFrame，之后 `clone.toByteData(PNG)`；clone共享底层图像，下一visible decode/paint仍可能同时发生。由代码推断它是值得隔离的竞争来源，但日志缺少调用栈/起止时间，不能断言全部告警或Redmi UI长尾由它引起，也不能声称toByteData一定没有受engine线程协调保护。

最小诊断是同boundedROI候选保持persistRaster=true/false A/B，单独记录toByteData开始/结束、native/image返回、FrameTiming、cachehit和告警次数。关闭持久写只隔离竞争，不能拿没有diskWarm功能的版本直接最终验收。质量toByteData读回放在计时组结束后，避免读取本身干扰速度。

## 独立helper A/B方案

下一由root安排的helper只对已完成native 1:1 bounded region（≤4MP、每边≤16384、packed premultiplied RGBA8、stride=width*4）改变image construction，原decodeRegion、native坐标、TTD、工作预算/原lease、source/version、viewport完整性全部相同。两路线`rawDescriptor`与`impellerDeferredSync`，default仍rawDescriptor；不加入等价async wrapper。

helper接口可为 `Future<RawUploadMeasurement> buildBoundedRawImage(NativePixelBuffer pixels, RawUploadRoute route, bool Function() cancelled)`。先验证输入/取消，计 `SkDataCopyAndObjectUs` 或现 `immutableBufferUs + uiImageCreationUs`，产出image后验证width/height、generation/取消，失败dispose；调用方现afterFrame retire/预算所有权保持。sync输入buffer已同步copy，native/Dart源可在函数返回后依原流程释放，但deferredimage/GPU任务预算不能在对象返回时提前放掉。unsupported Skia/candidate失败明确report，不静默fallback来掩盖候选缺失。

Android Impeller sync没有rowBytes参数，非packed stride必须明确拒绝或回原路线；不会缩小pixels、改变alpha或滤镜。Windows Skia不测sync速度，source明确不支持；仅保留原renderer并测cache隔离。一个ROI约2.13MP，CPU输入8.52MB，候选至少另SkData和hostVisible同量级，纹理单mip，仍需要过渡预算/OS RSS。不能以少mip为由把原圖pixelzoom的采样或1:1尺寸下调。

同源512 grid/viewport候选确定后，再在同一snapshot比较rawDescriptor vs sync N30：两次nativeScale+pan完整等待不变；分别保留原cold build与prepared组。主结论以匹配FrameTiming的完整原密度画面为准，另记录sync对象返回到真实raster的间隔、120Hz frame stalls、OS RSS、cancel/unmount→drain、磁盘/原lease。读取alpha0/1/128/255、隐藏RGB、ICC归一后原像素、8EXIF、邻接边缘、1:1高频线条做实际paint输出严格比对。sync对象ready但texture尚未上传或空图不得触发完成验收。

## Texture和直接Canvas的取舍

Flutter公开Canvas的drawImage/drawImageRect/drawAtlas接收ui.Image，没有公开“从native pointer绘制像素”入口；Canvas合批可减少drawcall但先前每块image建设已发生，不能省掉上传。PixelBuffer是平台embedding接口，不是Dart Canvas通用API。

Texture若后续有明确收益，需要至少双buffer或有限ring：decoder写未被raster消费的slot，atomic publish generation和exact整数sourceRect，raster callback持有slot直到release/frame-consumed，cancel只阻发布并等待实际consumer退出后释放。Windows texture registrar unregister是异步并有completion callback；unregister前不能释放callback/state。AndroidImageTextureEntry明确push后caller不能close Image，丢弃旧帧由engine消费处理；SurfaceProducer必须处理surface destroyed/recreated、trim-memory、foreground resume与GPUcontext失效。两平台还需RGBA/BGRA、premul、裁剪/旋转/色彩、滤波、实际cap、可见屏幕与截图质量方法。

因此下一先测已有公开sync接口和cache竞争，只有真实raster仍受上传瓶颈且收益空间明确时才独立Texture原型。预算不限不等于可以跳过原像素/释放/取消证据；Texture不会自动让解码/CPU→GPU零复制。
