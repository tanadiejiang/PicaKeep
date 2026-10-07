# 022 普通清晰首显与大图边界补充调研

当前优先测普通静态PNG“64MiB范围内直接保持完整原像素image”的候选；JPEG、超过64MiB的4000×6000及特殊色彩格式继续分别处理。候选先保留profile开关，不能把所有原图无界交给Flutter。本文为只读分析及独立native实验，没有变更生产源码或替主任务选择默认。

## 为什么完整普通PNG值得试

已有Redmi普通3000×4000 alpha PNG，baseline约94ms、当前适屏约158ms，目标尚未达到。两者都从原文件读；当前backend增加source/metadata阶段、派生lookup/capture和target resize，需用主任务新的阶段数据分辨各项，不能把64ms差距全归resize。

本地SDK实际engine revision为 `425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb`，`FileImage._loadAsync`及现FlutterReaderBackend均用 `ImmutableBuffer.fromFilePath`，改方法名字不会省掉I/O。`ImageDescriptor.instantiateCodec`可指定完整尺寸。[精确Skia实现](https://raw.githubusercontent.com/flutter/flutter/425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb/engine/src/flutter/lib/ui/painting/image_decoder_skia.cc) 在codec缺少有效缩小尺寸时会先解码，再额外resize；原尺寸可免resize。此推断要同codec/同设备实测，不能声称PNG已经证明必然更快。

[精确Impeller实现](https://raw.githubusercontent.com/flutter/flutter/425cfb54d01a9472b3e81d9e76fd63a4a44cfbcb/engine/src/flutter/lib/ui/painting/image_decoder_impeller.cc) 显示，压缩codec可能先分配decode bitmap，涉及premultiply还会分配转换bitmap；GPU路径先原纹理，再resize纹理并生成mips。保留完整普通image能省resize资源，但其原图上传/纹理仍在。JPEG若能直接codec缩小，完整image反而可能增加decode/upload，所以要按格式测。texture尺寸被engine限制，极长但总像素小的图片也不能因低于64MiB就当完整1:1安全路径。

## 必须保留的边界

| 情形 | 静态RGBA8基础字节 | 策略/需要核验 |
| --- | ---: | --- |
| 3000×4000 | 48,000,000 B（45.78MiB） | 单surface64MiB与全局192MiB内可试完整PNG；两页至少91.55MiB基础resident，还需decode/GPU transient预算 |
| 4000×6000 | 96,000,000 B（91.55MiB） | 超过普通完整策略阈值，仍native适屏/ROI；不得为跑分放宽Flutter门槛 |
| 8000×12000 | 384,000,000 B（366.21MiB） | native有界层/ROI，完整raw是磁盘派生层，不能当可无界image resident |
| ICC广色域/透明HDR | 可能8或16 B/像素 | `width*height*4`不是实际engine显存；广色域透明可能F16。先维持专门兼容/质量路径，避免把本实验扩大到RGBA8假设不成立的源 |
| 动画/16bit | 多帧/转换成本不同 | 不混进静态普通PNG性能结论，原解码/质量能力须分别验收 |

现ordinary-full仍受file≤64MiB和decoded≤64MiB界限，已结合工作调度、单surface64MiB、全局192MiB；Flutter backend估算原图12B/px+file×2+需求12B/px，不要为了并发变小到只计resident的4B/px。这是准入估算，不是所有engine峰值严格等式，OS旁路应覆盖两页快速进出及原图尺寸边缘。若内存/纹理边界失败，回有界ROI并清楚报告，不能悄悄将低密度预览当原清晰层。

preview-first目前仍会请求预览和完整候选。对PNG两者可能各自decode整源，并不必然提前更快。应在同一profile A/B单独比较sharp完整、preview+完整、当前adaptive；若preview使正式清晰结果变慢，保留模式选择但控制同时工作的优先级，不得更换含糊正式画面。完整普通image超过ReaderRasterCache的4M像素上限，因此12M原image不会写lossless raster；其“disk warm”可以只有OS文件热，必须真实记录命中，不能把原缓存上限一并放宽。

## 超64MiB的实际native开销

`quick_png_fit` 每行PNG解码后由AreaRescaler遍历输入像素premultiply，再area导入/导出，最后遍历输出unpremultiply；内存为输出+行/工作数组，避免整图内存，但原始扫描和逐像素CPU成本仍完整存在。PNG8、无ICC、非Adam7、方向1、完整整图缩小才走该quick path。其它情况用raw backing，再原像素/area采样。1:1路径不经过area，其exact原像素测试与缩小滤波容差分开。

JPEG baseline8bit且非progressive可用1/2、1/4、1/8 IDCT，再crop/skip；有原像素层时现实现走backing采样。缩小适屏因此可能因已有层反而变慢。progressive要管coefficient工作区与磁盘，不应拿baseline JPEG峰值代替。ICC、16bit、alpha和方向继续保留已有能力边界。PNG/JPEG encoder本身主要按行处理，但输入完整RGBA、输出sink增长时旧/新输出同时存在，encode峰值必须计输入+codec+扩容，不只看编码文件小。`pki_encode_rgba`已有native硬预算，Dart还有输入+TTD复制；后台raster PNG的engine编码应继续受clone/Pending32MiB/单image4M像素和调度预算限制。

## 本轮独立4000×6000实验

Windows native Debug DLL SHA `d07fc3648c8e8488c89b9c6a05e193136cc3c588137819f89a48892dd2285f2f`，8000图共享读修正版相同DLL。这里调用既有 `benchmark_fit.py`，每组N30，没有独立不计时预热，OS cache未控制，不包含Flutter/UI/GPU，不是正式用户首显达标证据。原PNG与baselineJPEG尺寸相同而内容/编码不同，不以两格式时长证明普遍格式排名。

PNG原文件SHA `eb8c0b0309bfc032fd1914a3479740a0be5bb1bb4288757948b4e84236def28`，JPEG为 `f2737cf1379d48e3cfecc7fb6cfb653c247f1bd497bdf0b4be3c01b6c2a9e172`，既有脚本SHA `5eddc93e0f29148fa04ee81a33df630e94da5e4040b8ccc4790b3e55a0d922d0`。Windows桌面主任务可能并行运行，prepare样本有727.634ms的长尾原样保留，正式比较应隔离并加入不计时预热；不删除该长尾或声称native达标。脚本已清理本实验生成raw，仅保留两6MB fit RGBA与JSON。

| 源 / 组 | P50 / P95 ms | native工作峰值 | disk |
| --- | ---: | ---: | ---: |
| PNG quick cold fit1000×1500 | 171.385 / 176.091 | 6,129,850 B | 0 |
| PNG prepare原像素层 | 99.731 / 105.869 | 1,162,442 B | 96,000,128 B |
| PNG raw层warm fit1000×1500 | 188.929 / 202.004 | 6,048,016 B | 96,000,128 B |
| JPEG quickIDCT1/4 cold fit | 61.418 / 64.803 | 6,034,600 B | 0 |
| JPEG prepare原像素层 | 112.347 / 249.051 | 1,185,800 B | 96,000,128 B |
| JPEG raw层warm fit | 181.420 / 189.937 | 6,048,016 B | 96,000,128 B |

Evidence：`native-ordinary-4000x6000-png-fit-30.json`（SHA `fd695f4b0c02475e2e5c254b3f5526779870d8a37133022aa1aaa9923e053a44`）、JPEG报告（SHA `86e7f5c2182c28b40e4f111a0c4fa86e49373240ca356ef0919c2ea41becdbc7`）。Finding：本实验已有raw不保证适屏更快；特别JPEG quick-fit本身disk0，raw层warm-fit近3倍耗时。Path：压缩原文件→受控quickIDCT/area→单适屏级；缩放到1:1→独立raw/region读取，不把缩小副本用于原图导出。

PNG1000×1500输出另与独立4×4整数area均值比较max1、mean0.00475、28,500/6,000,000通道不同，属于缩小rounding输出观察，不作为1:1无损判据。既有1:1 exact验证继续有效。当前raw fit与PNG cold area不是“同codec逐字节一致”声明；本脚本并未做Flutter对照。

复現（项目根、输出E，现有fixture/DLL前提）：

```powershell
$env:PICAKEEP_IMAGE_ENGINE_LIBRARY = 'C:/Users/tanad/.codex/tmp/picakeep-native-022-build/windows/Debug/picakeep_image_engine.dll'
$env:PICAKEEP_IMAGE_ENGINE_ARTIFACTS = 'E:/picakeep-native-022-artifacts/picakeep-ordinary-study'
python packages/picakeep_image_engine/native/tests/benchmark_fit.py E:/picakeep-image-pipeline-022-fixtures/4000x6000.png --width 1000 --height 1500 --samples 30 --label ordinary-study
python packages/picakeep_image_engine/native/tests/benchmark_fit.py E:/picakeep-image-pipeline-022-fixtures/4000x6000-baseline.jpg --width 1000 --height 1500 --samples 30 --label ordinary-study
```

## PNG闲时准备的具体候选

优先缓存已显示的小适屏level（无损可再生），而不是阅读每张PNG自动铺raw。raw后台资格只给当前清晰页面的明确放大意图，或稳定停留后且未有完整原image的当前页；最多一个实际准备任务，可见任务随时协作取消。不对所有相邻/目录图片开展96MPraw准备。

在准备前计算最终raw `128+encodedW*encodedH*4`，并计构建临时峰值：旧层替换可能同时旧+partial，16bit/Adam7可能额外precision层，progressive JPEG另coefficient。现2GiB ImageTemporaryPool只是进行中workspace上限，500MiB全局缓存只做事后LRU；两者不能替代“准备前持久盘配额准入”。后台应先由一个原子容量预留控制总派生层+预计最终+必要临时空间、当前可清理unleased容量及磁盘空闲保留；不满足时跳过idle准备保留正常cold路径，不能先写384MB再等trim扫盘。

主任务可测三候选：A维持无PNGraw idle；B只当前page稳定停留且配额准入后准备；C捕获放大动作/意图后准备。每项同时记录原像素初建、明确prepared后warm、完整盘字节、cancel后partial0、用户马上放大及60次进出OS内存。A/B必须保持同源、同ROI、同密度、同cache说明，不能通过隐式准备消掉失败样本。
