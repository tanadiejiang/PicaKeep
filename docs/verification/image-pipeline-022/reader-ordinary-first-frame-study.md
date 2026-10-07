# 普通 PNG 原始首显与 Image.file 链路差距 · 2026-10-06

结论：推荐的单一后续候选是“Page resolved 后立即经原预算提交全原图 first-raster ticket，并把它交给正常 Surface”，已按 root 授权实现为 `earlyOriginalRaster=false`，详见 `reader-early-original-native-large-fit.md`。再次切换到另一个 FileImage API 不会获得不同的 engine 解码实现；首个解码对 viewport 的等待可以省去，完整原图的 GPU 上传仍存在。是否达到普通图不回退和约 20% 优化，必须继续实测，当前没有这一结论。

## 原始 JSON 证据

五份报告同为 3000×4000、8-bit、无 ICC、69,669 B PNG，每组 N30、single、sharpFirst，错误数均 0。数字使用与 harness 相同的 nearest-rank 分位数；raster 首显从 request 到匹配真实图像 build 的 engine rasterFinish，不能把 post-frame callback 当最终首显。

| 报告 / 组 | 首显 P50/P95 ms | pageResolve P95 ms | codec P95 ms | 每样本剩余 P95 ms | postFrame→rasterFinish P95 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Redmi adaptive baseline | 81.927 / 99.657 | — | — | — | 6.286 |
| Redmi adaptive cold | 128.738 / 166.556 | 6.067 | 100.602 | 74.037 | 42.360 |
| Redmi adaptive warm | 82.505 / 106.018 | 9.999 | cache decode 38.873 | 45.923 | 5.060 |
| Redmi full baseline | 82.763 / 102.282 | — | — | — | 9.272 |
| Redmi full cold | 100.599 / 121.373 | 8.015 | 84.400 | 39.690 | 5.914 |
| Redmi full warm | 114.000 / 139.572 | 9.827 | 89.694 | 50.983 | 3.109 |
| Windows adaptive baseline | 51.322 / 55.474 | — | — | — | 3.333 |
| Windows adaptive cold | 47.519 / 52.995 | 1.373 | 35.897 | 16.754 | 0.425 |
| Windows full baseline | 51.302 / 54.550 | — | — | — | 3.255 |
| Windows full cold | 59.443 / 70.479 | 1.687 | 49.101 | 18.293 | 5.371 |
| Windows resolved adaptive baseline | 53.980 / 59.556 | — | — | — | 2.362 |
| Windows resolved adaptive cold | 50.744 / 75.124 | 1.653 | 34.939 | 41.020 | 0.516 |

剩余是先对每个 sample 计算 `rasterPresentationMs − pageResolveUs/1000 − flutterCodecWallUs/1000 − rasterCacheLookupUs/1000 − rasterCacheDecodeUs/1000`，再取 P95，**没有把各分位数相加或相减**。old `ordinary-cold-results.md` 的“剩余”用的是 post-frame elapsed，因此数字较小；这里改用正式 raster 首显并明确算法，旧数据不改写。

Redmi adaptive cold 的 request→真实 image build P95 为 130.717ms，而 full 为 118.790ms；adaptive post-frame 后仍有 42.360ms 长尾，不能全部归 metadata 或等待下一帧。full 的 metadata 单独 P95 为 3.622ms、sourceFile 为 1.048ms、sourceResolve 为 4.145ms；各分位数不可相加。full 的每次输出 12MP 超过现 lossless raster cache 4MP 门槛，所以其所谓 warm 仍解原 PNG，不是盘中派生图命中。Windows adaptive fit density0.25（0.75MP），Redmi为0.5（3MP）；两平台不可把输出像素相差四倍的 fit 当同一缩放成本。

## 可以避免的等待

当前 Page 从 source 打开原文件并 probe，`setState` 后下一个 build 创建 Surface。已 resolved 的 Surface 虽然同步取得 file/metadata，仍由 `_scheduleViewport` 先等待 post-frame 计算真实投影，才 `_request`、await 工作估算、submit scheduler，然后作业做 backing admission/目录、源快照检查，再进入 backend。完整原图的尺寸、坐标和 density=1 已知，无需等 projection 才估算/解码。

`FlutterReaderRasterBackend` 的 `flutterCodecWallUs` 计时从 `ImmutableBuffer.fromFilePath` 返回以后才开始；因此“剩余”还包含该文件载入、估算/源 stat、backing 相关工作、调度和展示。原 JSON 没有这些阶段绝对时间，不能把 39.690ms 都标成可省的空帧。新 handoff 记录提交、开始、ready、Surface 消费的 Timeline timestamps，保留同一 request/raster 时间，能检查解码是否提前且候选真正被消费。

root 已移除第二次原文件 open 的 resolved handoff 是生命周期改进，但 Windows 最新 adaptive P95 75.124ms 仍比本次 baseline59.556ms 慢。它与较早 adaptive52.995ms 属于不同 run，不能把变化全归单一修改，更不能凭代码推导宣布首显已更快。

## FileImage 与完整原图组件

本 SDK engine `425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb` 的 FileImage 先 await file.length，再 `ImmutableBuffer.fromFilePath`；调用 PaintingBinding `instantiateImageCodecWithSize`，它内部仍是 encoded descriptor、instantiateCodec、getNextFrame。空 target 会转换为实际源尺寸，和现 fullOrdinary 的显式原尺寸最终传入相同 codec 尺寸。Image widget 监听静态 codec 第一帧后 setState，静态 MultiFrameImageStreamCompleter 不额外等动画 frame callback。因此直接 provider 不省 PNG 解压/texture upload。

本 SDK Impeller PNG 的 scaled_dimensions 常为源尺寸；若 target 较小，会先上传源纹理和 mips，再建立 target texture、ResizeTexture 和 target mips。fullOrdinary 已避免 target resize，但 Windows全原图要保留48MB纹理；原 adaptive750×1000只有3MB最终显示层，所以 Windows full 变慢有实测依据。无论新 provider 或新 component 都不能自动消除完整纹理工作。

直接复用 FileImage 还需补正常 scheduler 准入、完整 source version、源 pre/post stat、取消实际 codec drain、resident 与 post-frame retirement。SDK FileImage key 只比较 path/scale，同路径替换可能读到旧 cache；全局 ImageCache 的 live/keepAlive 另有生命周期，应用在 main 把 cache 上限提高到192MiB，而 profile harness不一定运行这一 main。增加 provider 会把原有 Surface 所有权复制一遍，并增加未计存活图像风险。因此最小候选保留当前 full backend 与 Surface，只提前提交并明确 transfer。

本地 SDK关键证据：`packages/flutter/lib/src/painting/image_provider.dart:1589`（FileImage）、`lib/src/widgets/image.dart:1197`（Image resolve/listen）、`lib/src/painting/image_stream.dart:1084`（静态帧直接emit）、`bin/cache/pkg/sky_engine/lib/ui/painting.dart:2570`（encoded wrapper）和 `:8467`（空target转源尺寸）、`engine/src/flutter/lib/ui/painting/image_decoder_impeller.cc:344`（decompress），`:436`（resize_info）及 `:459`（upload/mips）。均位于 `E:/SDK/flutter_windows_3.38.5-stable/flutter/`，未依赖其他版本文档。

## 同条件 A/B

以同一最终 snapshot 在 Windows/Redmi各跑 single sharpFirst、同原 PNG、decoded-cold、OS file cache仍标不可控、真实120/240Hz/DPR和真实 image build对应rasterFinish：baseline原直接Image.file、adaptive、full、full+earlyOriginalRaster，各N30并报告独立OSRSS。主目标仍是全链路不回退/约20%，不把仅从already-resolved时刻开始的子阶段时间替换它。

补充已 resolved 相同 PhotoView geometry 的子阶段诊断，可以量化包装与提交等待；它作为附加 control，不覆盖历史直接 baseline。首显验收仍等待正式 full-density layer，preview不算完成；真正1:1与旋转/非整数DPR的滤波沿现 painter原规则。两页并发、clear-generation、cancel-before/after-codec、原图替换、退出drain与source导出SHA另测。

当前 harness baseline 在 `_run` 中固定 `single`，在 `_reader` 中直接一个Image.file、只收left，没有PhotoView/Surface/source/metadata预算；候选double会收left+right、continuous含scroll。即使手动给baseline写layout=double，它仍只画一页。因此现普通single comparison可作为整体参考，不能声称double或continuous也同比通过。baseline callback硬编码density=1/nativePixels=true仅表示解码全原图，其fit屏幕的真实密度仍<1；不可把这字段和候选1:1投影 callback当同一证据。
