# 022 实际阅读画布原像素验证

2026-10-06接续增加`tools/image_pipeline_022_surface_quality_checks.dart`。当前仅完成实现及Dart静态分析，尚无Android/Windows实际运行结果，不能据此宣称拼接、96MP纹理或“不糊”已验收。

## 调用与范围

独立debug/profile入口在自身reader已卸载后调用：

```dart
final surfaceQuality = await runImagePipeline022SurfaceQualityChecks(
  context,
  fixtureRoot,
);
```

`context`必须位于Navigator下方，素材根只取本任务合成图片。helper不读设置、账户、作品库或下载数据。主入口可把结果写入既有JSON报告的`surfaceQuality`字段，并提供显式`surface-quality`group；默认性能矩阵不隐式混入本组。两端仍只允许debug/profile，由root从独立快照串行构建、验证设备与APK后启动。

输入固定22个fixture，分别检查原坐标中央区域和右下边缘，共44case：PNG RGB/alpha、JPEG444/420/progressive、EXIF1–8、96MP PNG/JPEG/progressive/WebP有损/无损/Adam7、800×30000 PNG/JPEG/progressive。参考与candidate均来自同一原文件，源size/mtime/SHA-256前后相同才记录`sourceUnchanged=true`。

## 实际测量链

每case通过零动画临时route挂载正式`ReaderImageSurface`。OverflowBox保持整幅原坐标几何，按设备DPR把原像素映射到物理像素，移动至整像素ROI。viewport以ClipRect裁区，RepaintBoundary仅覆盖ROI。最大capture1024×1024；小源/设备不足1024时使用512或源可用宽高，不创建整幅96MP Flutter bitmap。

使用正式sharpFirst和512×512 tile，包装原生backend只记录请求/实际`ui.Image.width/height`及预算，不改codec/坐标/像素。禁用本组可选持久阅读缓存与idle全图准备，确保实际native tile路径被观测。等待`complete && nativePixels && density==1`，sourceRect投影误差限1e-6只约束浮点几何。随后按onPresented的真实build Timeline落入某个FrameTiming.buildStart..buildFinish，取得rasterFinish，才执行引擎RepaintBoundary读回。UI callback、native完成或provider ready均不能代替此帧匹配。

参考另一次从同原文件请求完整ROI，输出尺寸与ROI相同，最多1024²；参考不是从candidate瓦片拼接或抽取。此调用可复用相同受控原像素backing，以避免再次铺满复杂格式的数百MB磁盘输出；报告明确该复用。单幅ROI通过Flutter raw ImageDescriptor建立image，在同Flutter Canvas的黑底上绘制。candidate与参考均读取rawRgba，逐通道精确比较，没有颜色/像素容差或自动“合格”阈值。

这验证原坐标区域、实际解码纹理尺寸、正式CustomPaint拼接和黑底premultiplied alpha合成的一致性。它隔离native codec/Flutter渲染差异，不能替代原有“独立Flutter原文件codec vs native区域”的小源质量报告，也不能证明源ICC扩展色域/HDR保真；本组native参考固定sRGB8。不同像素数、最大RGBA差异、跨tile边界±1像素差异和前16个差异位置均原样保留。零差不能被外推到未检查像素。

## 边界与证据

原生ROI只返回有限区域Flutter图像；复杂96MP WebP/progressive/Adam7仍可能使用约384–960MB原像素/系数backing，不能描述为不需要全图处理。正式共享内存队列与2GiB临时池照常准入，reference预留1GiB临时空间，native memory cap来自estimate；不足返回错误，不无限回退或放宽像素要求。

每fixture单独建立task子目录，源/自有backing租约保留到实际消费者结束；route卸载和source drain完成后验证解析绝对路径仍在helper workspace内，再只删除自有backing目录。异常capture及非零差case的actual/reference/amplified16 RGB差图PNG留在`App.cachePath/surface-quality-022/run-*`，Windows由主入口E盘cache承载；原文件永不删除。后台task超时或错误逐项记录，不改为通过。

| Evidence | Finding | Path |
| --- | --- | --- |
| 新helper Dart analyze无问题 | route/render/source/backend接口类型匹配，仅静态证据 | `E:\picakeep-image-pipeline-022-work\surface-quality-helper-analyze.log`；`tools/image_pipeline_022_surface_quality_checks.dart` |
| tilePixels生命周期回归4 passed | 在飞512→256取消后旧backend仍实际返回image，但被丢弃；完成grid256→1024清旧resident；两轮400×600全240000像素对源坐标8像素checker精确一致；实际纹理尺寸/desired一致，退出resident/queue/budget/source lease为0 | `E:\picakeep-image-pipeline-022-work\surface-grid-regression.log`；`test/reader_image_surface_test.dart` |
| grid test与helper Dart analyze无问题 | 动态grid harness和像素观测类型匹配 | `E:\picakeep-image-pipeline-022-work\surface-grid-analyze.log` |
| 尚未profile实测 | 真实capture尺寸、44case精确差异和最终lease/resident/budget零值仍待报告 | root独立profile入口的`surfaceQuality`字段 |

实测报告必须保留native availability、设备DPR、view physicalSize、capture/reference尺寸、原文件哈希、实际每tile image尺寸、真实FrameTiming、所有errors，以及退出时resident、activeSurface、work/temp预算和source lease。必须分别评估几何/拼接、alpha和codec/色域；不能以测试数量或平均误差掩盖某case非零差异。

## 2026-10-06 Windows真实画布实测

Evidence：`reader-surface-quality-windows-44.json`，profile、shared native稳定读取版本，44/44实际CustomPaint/RepaintBoundary捕获、44/44逐像素零差，errors=0。包含22个输入各中心跨瓦片/右下边缘：PNG/alpha、JPEG4:2:0/progressive、EXIF1—8、六类96MP和三类800×30000长图。每项nativeDensity1、实际ui.Image尺寸、原文件SHA前后一致与matched engine rasterFinish均保留；输出最多1024×1024，未建立96MP完整Flutter image。结束resident/activeSurface/work/temp/sourcelease均0。

Finding：所测区域的实际拼接、方向与黑底alpha合成同独立broad-region→单Canvas参考精确一致；这项成立于本Windows/DPR/fixture区域。参考同native色彩后端，不能外推未测像素、Android、宽色域/HDR、全部产品布局或Flutter独立codec质量。source-color对照仍使用独立pixelChecks，不能用44零差覆盖灰度ICC的既有舍入差异。

Path：原文件→有限native ROI→真实ReaderImageSurface拼接→engine raster匹配→readback→独立同源宽区域绘制比较。第一轮44项失败因工具读取Flutter的debugNeedsPaint，在profile getter内部Local result未初始化；失败原样保留`reader-surface-quality-windows-first-failed.json`，修工具将该读取只保留assert，profile以实际raster匹配为读回时机。不能把第一轮错误写成产品画面失真，也不能把静态分析通过当实测。

## 2026-10-06 持久缓存与Android反向核验

Evidence：`reader-surface-cache-quality-windows-66.json`，22个输入各中央、右下边缘、中央磁盘缓存复读，共66/66逐像素零差，errors0，退出全部resident/job/lease/working/temp归零。中央repeat有真实磁盘命中诊断；Windows stderr仍出现一次跨GrContexts纹理警告。所测读回没有黑图或非零像素，不能据此排除其他并发场景的驱动/纹理问题。

Evidence：`reader-surface-cache-quality-redmi-66.json`，Redmi K30i 5G、profile、DPR2.75，66case中14精确一致、43非零差、9尺寸错误；不得标Android质量验收通过。非零差项最大逐通道RGBA差异不超过2级，实际图与单Canvas参考均未重编码源文件。640×960中央PNG12452差异像素，从跨tile行288开始；96MP PNG右下区域2817差异像素，两项最大RGB差均1级。超长图三种编码各三case截图801×1024而参考800×1024，Flutter OffsetLayer按`ceil(DPR * logicalWidth)`取整使800/DPR浮点往返多出列；这一项属于截图extent问题，后续只修读回边界，不缩放截图。双线性采样差异仍需生产滤波核查和真机复测，不用颜色容差消除。

Path：Android差图原始路径保留于报告，两个代表区域已只读复制到`E:\picakeep-image-pipeline-022-work\android-quality-artifacts`；原报告及失败图不覆盖。新`tools/image_pipeline_022_exact_readback.dart`从RenderRepaintBoundary子类读取相同场景，只将读回物理extent限定在整数目标内极小epsilon以避免ceil多列，不改变scene transform，不对图像resize，尚待新profile实测。相关harness四文件analyze无问题。

Android同run原图保存bridge实际返回`content://media/external/images/media/2227`；仅读取该返回URI，10237字节PNG保存前后SHA-256均`d9070a909d982cb52e1380b3af4a089a953b3edcae2de0a56f0c98acbd5f9034`，源文件前后SHA相同，MediaStore pending原子发布成立。保留一项合成测试相册图片；它证明该设备原字节保存bridge，不代替真实作品的完整菜单操作/系统分享验收。

## 原像素画布采样修复与回归

2026-10-06 已冻结生产 Painter 修复，尚待上述Android66case同源复测。仅 `layer.density==1` 且两条源单位轴的完整物理投影轴对齐、长度至少1像素时使用 `FilterQuality.none`；更低密度、实际缩小、旋转/剪切/透视仍 medium。物理判据来自既有 RenderBox.localToGlobal 投影乘DPR，涵盖composited祖先；paint同时读取 Canvas.getTransform 检查实际累计矩阵的affine/axis条件，不把widget逻辑尺寸猜作物理scale。1e-6仅用于几何roundoff，像素比較仍严格零差。

Evidence：`native-pixel-filter-and-bounded-verified-regression.log` 21/21（Surface15、Flutter backend6）、三文件 analyze clean。新增DPR2.75中心跨tile与8001×12001奇数源右下边缘，各400×600全240000像素与独立同原坐标alpha checker在黑底上精确一致；图像层实际输出完整pixel尺寸，截取extent以RenderRepaintBoundary测试子类限定整数，不resize图像。density量化到1但实际投影0.9仍有中间过滤色，实际1.2且非轴对齐旋转仍有中间过滤色，保证没有把缩小/旋转全改nearest。

该回归为Flutter test引擎证据，不能宣称Redmi43非零差已消失。原Android报告与差图保留，下一profile同时比较真实Canvas尺寸、同源ROI逐通道差和退出lease/resident/job预算。由source_workflow同步确认 Surface backing hold只适用于真实filebacking或支持闲时native准备的execution backend；无磁盘需求的fake backend不申请写盘workspace，真实adaptive/native保持准入。

## 2026-10-06 统一快照 Android 复测

Evidence：`reader-unified-quality-redmi-66.json`，runId `2026-10-06T04-23-56-460517Z`，Redmi K30i 5G / profile / DPR2.75。APK 98,586,786字节，SHA256 `2B8D34DC8FC8F34974EB3F6014F3C9A5A1166F66485F33CE7563FEB962141BEB`，versionCode9/name1.9.92，既有debug证书；显式USB8021129d以install-r保留数据安装。该源码快照包含quota、raw-sync默认关闭、early/native-large-fit默认关闭及Painter `58471b59...`；不包含随后发现的post-decode异常释放与pending-image记账修复。

Finding：66项全部完成、errors0、尺寸错误0、原文件66项前后SHA一致。57项逐像素一致；剩余9项集中在800×30000 PNG、baseline/progressive JPEG，各中央、右下、缓存重复。中央3402个差异像素、右下3242或3243，最大RGBA为1/1/1/0，接缝差异总计264个像素；三编码相同分布指向绘制/投影链，需要继续定位，不能直接据此断定解码器或通过质量验收。此前普通与96MP的43项差异以及9项截图宽度错误均未在此次复现，保留旧报告作为修复前证据。

Path：同原文件、原坐标density1的正式画布→匹配实际raster→整数extent读回→独立宽ROI黑底Canvas精确比较。完成时resident/surface/jobs/working/temp/sourcelease/persistence均0，native worker1044成功、0失败。quota active/pendingClaims/pendingOperations为0，idle为104,091,764字节；此快照尚未包含cleanup后的强制refresh，因此idle账不用于证明所有磁盘文件已清空。只读容量probe在应用UID下三项成功、未创建不存在路径，约93.95GB可用；两轴16384长边端点probe成功，仅证明有限窄纹理端点，不代表16384平方纹理内存安全。

## 2026-10-06 更新阅读器快照 Android 精确复验

Evidence：`reader-final-quality-redmi-66.json`，run `2026-10-06T05-00-24-418942Z`，APK 104,976,546字节 / SHA256 `98667BF06B1B143887EA28774DCBAA7493C1DC94A7F42F5ADEED09851E1409A8`，profile、Redmi K30i 5G、DPR2.75。既有debug证书、version9/name1.9.92、USB8021129d保留数据覆盖安装。Surface `d853116d...`、Page `cf41fdd6...`、backend `9b18acaa...`、cache `612b19b7...`，含异常释放/pending记账/取消竞速；rawSync=false、持久cache=true，reference仅1:1不滤波，截图未resize。

Finding：22个输入×中央/右下/缓存复读=66项，66项实际像素与独立单区域参考逐通道完全一致，尺寸错误0、differentPixels0、seam differences0、errors0、sourceUnchanged66。此前9个长图±1参考滤波差异已不再复现；未用像素或颜色容差。结束resident/activeSurface/jobs/working/temp/sourcelease/cachePending全部0，quota active/idle/pendingClaims/pendingOperations全部0，native1046成功/0失败。

Path及限制：依然是同原文件native sRGB8 ROI和正式画布的精确区域对照，并有实际FrameTiming匹配；它证明所测区域的原像素拼接、方向、alpha、缓存往返。不是整个原文件每个像素的穷尽比较，也不等于所有三布局/动态缩放流程、ICC/HDR或OS显示scan-out验收。当前APK未包含随后单独收束的服务端暂存/index writer修正；reader部分来源hash可复核，最终正常应用包仍须统一构建。

### 独立原PNG差异点核查

Evidence：直接用独立Pillow读取任务原文件`E:\picakeep-image-pipeline-022-fixtures\800x30000.png`，按上述报告的`sourceRect + firstDifferentPixels`恢复原坐标。中央、右下和缓存复读各16个已公开差异点，共48个：正式画布的48个RGBA全部与原PNG字节精确相同；参考的48个均与原PNG不同，最大RGB差1，alpha相同。例如原坐标(104,14488)为(0,255,143,255)，正式画布相同而参考为(1,255,143,255)；(432,14488)原图和正式画布为(72,0,164,255)，参考为(72,1,164,255)；(480,14488)原图和正式画布为(120,255,167,255)，参考为(120,254,167,255)。右下原坐标(432,28976)和(480,28976)也分别保持原图(224,0,46,255)与(16,255,49,255)，参考边缘相差1。

Finding：这48个点证明当前差异至少包含参考滤波引入的颜色变化，不是正式画布损失这些原像素。该旧helper将已按原尺寸解码的ROI以`FilterQuality.medium`绘制，正式density1且物理轴对齐画布则使用`FilterQuality.none`；高频长图在参考路径出现边缘采样舍入，和报告中冷/缓存及三编码重复分布一致。root已把1:1独立参考改为none，保持相同原区域和严格零容差，待新双端profile重跑。

Path：本核查只读任务合成PNG与现有JSON，没有读取私人素材，没有修改原文件、画布、报告或设备。它只覆盖报告公开的48个点，未核查其余约3400个差异像素，也未独立核查JPEG压缩后的原像素，因此不能将66项整体写成通过。原66报告和旧差图继续保留；完成相同滤波参考下的全区域精确比较之后，才能更新最终质量结论。

## 2026-10-06 13:28 双端与同步候选复核

Evidence：Windows `reader-final-quality-windows-66-recovery.json`，run `2026-10-06T05-09-23-843887Z`，profile/DPR1.5；Android `reader-final-raw-sync-quality-redmi-66.json`，run `2026-10-06T05-27-03-054989Z`，profile/DPR2.75，APK SHA与上文最终reader快照一致。同步候选显式rawSync=true，verifyPersistence=true；不是将异步结果当同步质量证据。

Finding：两份报告各66/66 exact、零尺寸错误、零通道/接缝差异、原文件66项不变。Windows native1030完成/0失败，Android同步native1034完成/0失败。结束驻留/画布/作业/队列/working/temp/原文件租约/待写缓存及quota active/idle/claims/operations全部零。由此，上方48点核查及旧helper“待复验”状态已经获得全区域复跑支持；旧失败报告继续保留。

Path：保持独立单区域原文件解码、整数物理截图extent、1:1无滤波参考与严格零容差。Windows最初三个96MP渐进JPEG区域因E盘余量被准入拒绝，构建产物迁D并保留headroom后另起recovery全部通过。仅说明当前所测engine画布区域/缓存与同步上传路线精确，不代替三布局完整手势、OS扫描显示、wide-gamut/HDR或正常应用菜单操作验收。同步候选速度尚未全面达标，因此仍不修改产品默认。
