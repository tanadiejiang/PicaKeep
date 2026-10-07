# 022 Reader 色彩与动画实际画布验证

## 2026-10-06 Android 修复采样后的完整测量

本节是实际测量结果，不是全部质量验收通过。工具使用真实 `ReaderPageImage` / `ReaderImageSurface`，单页、连续、双页各跑清晰优先与预览优先，独立 Flutter 原文件 codec 作为参考。没有加载日常设置、账户或下载库。

- APK `D:/picakeep-image-pipeline-022-work/color-animation-v3-1006.apk`，84,413,474 B，SHA-256 `6755F8E626C1558C3ACBA1DC49BE94309B8FFF13E641D1C6A761E71210D64DB6`。三 ABI `libapp.so` 非空，arm64 6,161,328 B、armv7 6,767,196 B、x86_64 6,292,400 B；版本9/1.9.92，既有 debug signer `31b4434516ccc1f58add7cc5cd4b6786e995c957d5891d3685e4c75a7a58d7c7`。仅 profile，核验后对空闲机 `8021129d` 执行 install-r，未卸载或清数据。
- 构建工作目录是主工作区 `D:/Flutter_Projucts/PicaComic/PicaKeep`，不是旧 C 盘冻结快照。Surface SHA `36DBDA0A601F73ECD7684FC5AA74716D16EF15C63009945A7F97D058B269A9D4`；工具 SHA `C913AE270C7E91498F05C52C93D701BCC9A4BC954D72EFE8C44AE47A2A552623`，analyze clean。
- 原始报告 `color-animation-v3-redmi1006.json`，SHA `36432566CB50B67A2856F42A7FBC50843D3A716C5DB4C1515BB9F58EA0676A31`。PID27991，UTC 09:07:31.390534–09:07:45.940011，36/36 measured、errors=[]、36次源SHA保持。`measured` 只说明采样完整，`automaticQualityAcceptance=false`。
- 截图全部实际1:1物理投影；24个静图画布为512×512，动画单/连续16×16、双页32×16。每次观测均有 paint Timeline 对应的 FrameTiming，不宣称已测系统扫描输出。
- 最终 surface、resident/pending、调度、working/temp、source lease、cache pending、disk active/pending、ImageCache 均0，worker shutdown后0。原生45完成、9 code4（GIF不受原生区域probe支持，走真实Flutter兼容动画）、0非原生失败/启动失败。

| 输入 | sharpFirst 三布局最大 RGBA 差 | previewFirst 单页/连续/双页最大 RGBA 差 | 结论 |
| --- | --- | --- | --- |
| sRGB RGBA16 PNG + ICC | 每布局 `[1,1,0,0]` | `[38,64,18,0]` / `[38,64,18,0]` / `[143,144,44,0]` | 未通过 exact，需分别诊断中间裁片精度与多层alpha合成 |
| gray+alpha16 PNG + ICC | 每布局 `[1,1,1,0]` | `[32,32,32,0]` / `[32,32,32,0]` / `[126,126,126,0]` | 未通过 exact，不能设置容差掩盖 |
| RGB8 P3 ICC PNG | 三布局 exact | 三布局 exact | 与此引擎的原文件sRGB参考一致 |
| RGB8 Adobe RGB ICC PNG | 三布局 exact | 三布局 exact | 与此引擎的原文件sRGB参考一致 |
| 双帧 GIF | 全部观测 exact | 全部观测 exact | 每个实际显示部件均观测原文件两个帧 |
| 双帧动画 WebP | 全部观测 exact | 全部观测 exact | 每个实际显示部件均观测原文件两个帧 |

动画12组合累计25次画布观测（GIF双页清晰优先需3次，其余各2次），每次逐像素相同，左右部件各确认原文件frame0、frame1。原文件帧时间120/180ms、无限循环。观测间隔含100ms轮询与画布读回，不把它作为帧时长精度或卡顿验收；目前素材也未覆盖复杂帧依赖与超预算动画终态。

## 已定位的生产 alpha 问题

预览优先的 whole preview 与清晰 tile 长期同时 resident，Painter对全部层使用默认 srcOver。被清晰tile覆盖的半透明源会重复与黑底合成，双页还保留0.5 whole及1 whole，偏差更大。只按density排序不能解决遮挡问题。

已用同SHA原文件的独立8bit规范化读取核对：RGB16源 `(64,64)` 为 `[128,0,8,128]`，一次对黑底约 `[64,0,4]`，两次约 `[96,0,6]`，与报告 reference/actual 一致；gray16 `(64,224)` 为 `[244,244,244,19]`，一次约18、两次约35，同样匹配。该诊断不宣称独立读取保留了全部16bit精度。P3/Adobe素材是不透明RGB，因此其exact结果不能排除alpha缺陷。

生产Surface已加入覆盖集合裁剪：图层按密度与当前需求排序，每个低层绘制前扣除更清晰层的source-space覆盖区域；透明像素仍与页面背景合成，未到瓦片仍保留preview。没有全局BlendMode.src或整页离屏层。定向Surface 28/28通过，覆盖半透明、同/不同密度、缺失tile及非整数DPR拼缝；日志SHA `F2E3512D0B3AB565BF819E91D19BC5FCA64621FDB12AEBEE7F7AE6B38B5CDC63`。生产SHA `C89120D2D6EA089E98A4AAB4DB92FEA8CE3A8115B7D93F9D26AA0BB1283E3922`，测试SHA `F4EE86E6D7B73F472FFA6FA11D7E055C1CD015FF53CFCF052F468928ADAE9C12`。以上是定向像素回归；ICC/16-bit实际Reader画布仍需新profile包复测。sharp最多1级差目前仍独立未解决。

## Windows 修复版 Surface prepared-read 对照

同一个 2026-10-06 profile runner副本、8000×12000 Adam7 PNG、tile=512、原始像素ROI，prepared-read开/关各360条（12场景×30）；OS文件缓存不可控制。两组均completed，0工具错误、0 missing raster、目标/焦点错误0、Dart资源/任务/预算/lease/磁盘计数退出清零；各组均有实际raster。它是同日顺序A/B，不锁CPU/GPU或OS缓存，性能优势应结合重复验证看待。

| 布局/模式/缓存状态 | prepared开 P95 ms | 关 P95 ms | 变化 |
| --- | ---: | ---: | ---: |
| 单页 sharp，ROI | 205.952 | 380.72 | -45.9% |
| 单页 sharp，prepared ROI | 212.431 | 375.85 | -43.5% |
| 单页 preview，ROI | 208.718 | 384.60 | -45.7% |
| 单页 preview，prepared ROI | 225.093 | 387.24 | -41.9% |
| 连续 sharp，ROI | 195.886 | 373.25 | -47.5% |
| 连续 sharp，prepared ROI | 191.455 | 373.76 | -48.8% |
| 连续 preview，ROI | 196.019 | 410.69 | -52.3% |
| 连续 preview，prepared ROI | 199.742 | 398.42 | -49.9% |
| 双页 sharp，ROI | 221.070 | 329.32 | -32.9% |
| 双页 sharp，prepared ROI | 198.974 | 326.90 | -39.1% |
| 双页 preview，ROI | 220.531 | 375.86 | -41.3% |
| 双页 preview，prepared ROI | 200.544 | 360.03 | -44.3% |

这组支持保留prepared-read候选继续研究，不足以把所有可见场景称为已达到100–200ms：若按200ms作上沿，部分仍越界；Android也须用同一修复版本另测。原始on/off JSON分别SHA `7F8518157EFCABFACF5B937C42BC4287BB37AC2BEA583F7F73131E8E0947C9AB` 与 `7FF52B5CD16EF48EE7F97B948121AC510B77D740773347A816125D0914EA2E6C`。

## Android 60轮退出及OS观察

修复版Surface profile任务针对3000×4000 PNG，三布局×两显示模式、各10次，总60轮，run UTC 09:18:44.841740–09:19:10.104488，completed、errors=[]。每轮 `afterExit` 的resident、surface、active/queued job、working/temp reservation、lease、cache pending、disk active/pending均为0；idle worker可保留1–2个。内部报告 `reader-lifecycle-os-redmi-surfacefix1006.json` SHA `9AB192047F7AEABFF0E15A183E58E1EED6743E03ED92A5A95441DD799C7BD1C5`。更早同配置的内部重复亦60/60 completed、0 error：`reader-lifecycle-internal-redmi-surfacefix1006.json` SHA `6996D2F680BAA625515AE8B88243F9C6428EDD1A786756783D06C830A8ABC050`。

独立只读OS采样同一Android PID 28814/startTimeTicks 97529859，75个smaps/status读数、0采样错误，覆盖全部26秒测试及后续49秒空闲。测试期间smaps RSS 241,111,040–476,622,848 B、PSS 152,749,056–388,226,048 B；最后49秒空闲RSS 282,583,040–282,673,152 B、PSS 194,180,096–194,288,640 B。空闲段约90 KiB的范围很窄，但当前run没有生命周期前稳定warm基线，所以**这并不是按 `max(32MiB,10%)` 算出的回收验收通过**。Android `/proc/status` 与smaps值明显相异，故以smaps单列；Dart currentRss也不用于否定系统RSS。原始OS JSONL `android-lifecycle-surfacefix1006.jsonl` SHA `D450620A803BBB25D2C957534B3B0FFE5EE57A6720C97CD4607011ED57736283`。

## 16位PNG精度对照

Windows独立Flutter engine诊断4素材×2个整数512² ROI，每处11条controlled Canvas路线，共88项；报告 `color-precision-flutter-tester1006.json` SHA `0BECA75B56A30F7D8BE5E97119F351CF0A4A947D644302FA3D7701BE9B367CEF`，Flutter test 6秒、1/1 pass、errors=[]、所有sourceSHA不变，工具 `image_pipeline_022_color_precision_probe.dart` SHA `EB34AF1B6DE9F60F31CB3E16C201BF7FD509FB8C680E9C79D32EE6EF60D50AE6`。

- sRGB RGBA16和gray+alpha16的重复原文件解码、显式原尺寸target解码、直接整数ROI、`medium/none`透明whole/crop、512网格mosaic均与单层原文件opaque-black参照逐像素exact。P3/Adobe四组控制也全exact。
- 唯独“同一半透明原文件区域显式连续source-over两次”产生与Surface测量几乎相同的区域错误：RGBA16 max `[38,64,18,0]`、259,109/262,144像素；gray max `[32,32,32,0]`、246,818/262,144。此精确控制确认双层重复alpha合成足以导致预览质量差；结合Surface层快照中同density preview+tiles共存，production重复覆盖为根因。
- 两次完整scan中 P3/Adobe仍exact，sharp16 PNG仍有最大1级差。精度探针没有复现sharp的1级差，因此不支持此前“透明裁片量化”猜测；该一位差仍待进一步定位。RGBA8/float输出也不能证明原16-bit端到端精度。

16项重复合成差异图在 `color-precision-artifacts-redmi1006/`。报告尚未形成所有静态格式的零额外差质量验收。

## 先前采样失败保留

`color-animation-surface-fix-redmi1006-incomplete.json`，SHA `2931B9D754C186D409F4105873C4A3EED1BE71F2EC0E2593C6BD45825F7E8E40`，30/36组合、16个错误：15次工具完成等待超时及GIF原生probe不支持的fixture错误。实际工具问题包括读回future已移除后FrameTiming才到达、外层observer未随嵌套RawImage重绘、双页动画换帧不同时最多2次观察不足。新工具使用完成future与FrameTiming共同收束、有界强制observer重绘、最多8次观察、固定截图瞬间几何。两次更早的入口参数失败分别是任务根前缀和Android `/data/user/0` 链接祖先拒绝，未进入素材测量。

完整重测消除了这些采样错误，并复现了相同16bit预览alpha偏差，因此不能把偏差归因于工具超时。

## 精度边界

实际与参考 imageColorSpace 都是sRGB，float读回可用但 referenceOutOfSrgbComponents=0。结果证明这些输入在当前Flutter/设备画布上的相对表现，不证明保留原16bit文件的所有位深、不证明Display P3/HDR面板输出；源字节保持与显示精度分开记录。最高原文件分辨率和动画保留要求继续有效，不能由本节推出全部P0–P10已通过。

## Android v6 alpha 与采样边沿复测

v6测试包包含source coverage分区、采样raster gutter及双页clip修正。它是profile包，不是最终正常应用交付包。

- APK `color-animation-alpha-v6-1006.apk`，84,413,474 B，SHA-256 `C00DC765144CA6F98FD53E77B0D544E896E10AE7ACE4E26BDD15ED1F4A70914C`。arm64/armv7/x86_64 `libapp.so` 分别6,161,328 / 6,783,580 / 6,292,400 B，debug证书与现有测试安装一致，版本9/1.9.92。核验后只更新空闲机 `8021129d`。
- 真实Reader矩阵36/36 measured，`errors=[]`、所有原素材SHA未变，`automaticQualityAcceptance=false`。报告：[color-animation-alpha-v6-redmi1006.json](color-animation-alpha-v6-redmi1006.json)，SHA-256 `44D97598A44823A94CE2B6CB1BE28D82EDB6C90509F25717F21F18B54B899408`。

| 输入 | sharpFirst 单页/连续/双页最大 RGBA 差 | previewFirst 单页/连续/双页最大 RGBA 差 | 观察 |
| --- | --- | --- | --- |
| sRGB RGBA16 PNG + ICC | 每布局 `[1,1,0,0]` | 每布局 `[1,1,0,0]` | 原先大面积重复alpha差异消失；仍留一阶量化差 |
| gray+alpha16 PNG + ICC | 每布局 `[1,1,1,0]` | 每布局 `[1,1,1,0]` | 重复合成差异消失；仍留一阶量化差 |
| RGB8 P3 ICC PNG | 三布局 exact | 三布局 exact | 只代表当前sRGB画布读回 |
| RGB8 Adobe RGB ICC PNG | 三布局 exact | 三布局 exact | 只代表当前sRGB画布读回 |
| 双帧 GIF | 三布局两个原文件帧 exact | 三布局两个原文件帧 exact | 实际Reader兼容播放分支 |
| 双帧动画 WebP | 三布局两个原文件帧 exact | 三布局两个原文件帧 exact | 实际Reader兼容播放分支 |

16-bit RGBA各模式差异像素数累计为580、最大每通道差1；gray累计253、最大每通道差1；P3/Adobe/动画的差异像素均0。双页previewFirst曾在v5回归到明显色块/错位，复核差异图后发现无扩边图层也额外应用了coverage clip；v6只在`rasterRect != sourceRect`时添加该clip后恢复上述范围。这个中间失败保留为调试证据，不算最终通过。

额外回归：reader surface 29/29、Flutter codec/backend 7/7、raster cache 4/4、server boundary 4/4；相关Dart静态分析无问题。分数缩放高频图案的256px多tile对比单个whole raster逐像素相同。Flutter codec扩边ROI也逐像素匹配源原图坐标。Native backend的同契约测试受Windows Flutter tester当前缺少可用image-engine fixture/library影响而跳过；后续应在装有目标native库的环境补执行。

v6结束时应用内部resident、active surface/job、working/temp reservation、原件lease、持久raster cache与disk quota账均为0。测试报告记录的系统RSS/peak仅为观测值，不替代稳定预热基线下的OS生命周期验收。采样gutter按变换情况启用，增加少量局部纹理字节；本轮没有重跑v6 Android N30配对，因此不推断新的大图速度。

代码快照：`reader_image_surface.dart` SHA-256 `A4ECC1FAA719172877D586AC498DE06AD47D29798AB74D59F8B88A8A2C3CEB04`；`reader_viewport.dart` SHA-256 `DEF208B0C833A41345E99FFEAB1A6D36A4EDCC7B08C52A7DF0864C9741847C3D`；Surface regression test SHA-256 `805BCFC3CB7945BE9D323868A4D0DDAEF59359B69CF6C85EEB3929D3F676C518`。以上结论仍限于报告所列素材与sRGB8画布回读，不证明原16-bit/HDR屏幕端到端精度，也不完成P0–P10总验收。

## Windows v6 alpha/ICC/动画矩阵

Windows使用同一alpha/gutter生产代码快照和固定合成素材，profile构建及Reader矩阵于2026-10-06 10:43:44–10:43:52 UTC完成。profile executable SHA-256 `E0EE4DA717332E62419216D4450DCBE359D37770DA6D1424DDA01F9ED1C420F0`；image engine DLL `713CB5CFE58F58670F16339C7B1A03507008646417434D24D6361E235BC05144`；插件DLL `8281D3AC50612F9E0FD346A1FCB9E5092CDDE05F135BB0A9BC1A7048C296AEE9`。构建日志SHA `12951C0D4FE57C5CC84E83E6915B3A1E1943EE8F7359E57ED82DB892DC7B93ED`。全部路径位于隔离snapshot和D盘任务目录，没有触碰日常Windows app data。

原始报告：[color-animation-alpha-v6-windows.json](color-animation-alpha-v6-windows.json)，SHA-256 `CF5E8E4F7069CD679E0773F16CFA0F8F9A8DD5DD8D4633E99A339C6C30D72039`，347,807 B。

| 输入 | 组合 | 结果 | 说明 |
| --- | --- | --- | --- |
| sRGB RGBA16 PNG + ICC | 三布局×两模式，6项 | 全部 measured；RGBA8与可用float读回均逐帧exact | 画布比较不证明原16-bit码值端到端保留 |
| gray+alpha16 PNG + ICC | 三布局×两模式，6项 | 全部 measured；RGBA8与可用float读回均逐帧exact | 同上 |
| RGB8 Display P3 ICC PNG | 三布局×两模式，6项 | 全部 measured、逐帧exact | 目标与参照为sRGB画布，不代表P3面板输出 |
| RGB8 Adobe RGB ICC PNG | 三布局×两模式，6项 | 全部 measured、逐帧exact | 目标与参照为sRGB画布，不代表Adobe RGB面板输出 |
| 双帧GIF | 三布局×两模式，6项 | 每项观察到frame 0、1；逐帧exact | 一个双页预览组合额外采到一帧，仍只有两个不同原帧 |
| 双帧动画WebP | 三布局×两模式，6项 | 每项观察到frame 0、1；逐帧exact | 逐帧exact |

总计36/36 case、49帧、errors=[]、素材SHA前后相同、matched FrameTiming 49/49，`automaticQualityAcceptance=false`。实际/参考`imageColorSpace`均为sRGB；RGBA8每通道最大差0，可用float每通道最大差0；`referenceOutOfSrgbComponents=0`。Native GIF probe出现9次预期code 4，入口明确用Flutter codec兼容读取，`jobsFailedNonNative=0`。最终surface、job、worker活跃任务、working/temp reservation、lease、raster cache、disk quota账均为0。

边界：实际Reader像素对照的是Flutter original-file codec投影到同一sRGB Canvas，不是与原始16-bit样本直接比特级比较，也不是显示器面板采样。该组比Android v6少一阶画布差异，但两个平台codec/reference各自独立，不能由此声称跨设备广色域/HDR一致。此次不是大图速度N30；Android配对N30、16-bit sharp一阶残差定位、Native backend gutter测试和正常应用放大/保存/分享闭环仍未完成。

### Native gutter测试补验

2026-10-06 19:16接续时，为Windows tester提供固定独立DLL `E:/picakeep-image-pipeline-022-work/prepared-read-native-build/Debug/picakeep_image_engine.dll`（SHA `039E09EAE0A232418865E7F308637712C9AAED2ACDEFC7A59AB75225B09114B4`）和fixture根后，`native_reader_prepared_read_test.dart` 实际4 passed、1按能力skip、0 failed。新gutter测试已执行：可见sourceRect31/73/129/137保留，rasterRect29/71/133/141输出133×141并逐字节匹配同原图native ROI。prepared只读无写准入、miss完整准入与取消回收、低预算非miss错误不隐藏均通过。带prepared符号库下，缺符号兼容分支按设计skip。日志 `D:/picakeep-image-pipeline-022-work/native-gutter-wrapper1006.log` SHA `786DF7F06BD26B85DB511890205362419C375195898CE299799FA02DD079A51D`。这是后端契约证据，不替代真机速度或分数缩放整页的所有native压力场景。

## Android v7 一阶残差定位及整数裁片修复

2026-10-06 19:38（Asia/Singapore）诊断实际完成。v7保留独立原文件codec参照、原有严格逐像素比较，并新增同参照的`isAntiAlias=false`控制。Android profile APK SHA `5578FDF761CE658B0BA4EF9CEF0CD72D6D535E0A83200B85CD5F346B4BE40834`，在空闲机 `8021129d` 实际运行；仍无卸载或清数据。

| Evidence | 实际观察 | 原始文件及 SHA-256 |
| --- | --- | --- |
| E-COLOR-V7-READER | 36/36 measured、errors=[]；16-bit全部布局/模式残差重复；参照AA开/关不同像素均0；源未变，退出全部内部资源账0 | [color-diagnostics-v7-redmi1006.json](color-diagnostics-v7-redmi1006.json)，`73FFFBFDB64594060E4CA55C04AFF4E81DBADA5DA18EA7D56B381609DE0E8A7D` |
| E-COLOR-V7-PROBE | 同Android engine、固定4素材×2整数512² ROI×11路线；原文件重复解码/显式原尺寸解码 exact；none透明裁片/whole/512网格全部exact；medium网格重现Reader的逐通道误差规模 | [color-precision-v7-redmi1006.json](color-precision-v7-redmi1006.json)，`F2DEFA9FF05CB6DD05EAEA2213BCC31D58528C19EDAFDD99A0DACE4ED9D5E50E` |

以下控制只改变中间裁片的`FilterQuality`，输出都以一次source-over绘制到不透明黑底。网格原尺寸、整数坐标、1:1输出；没有缩图、阈值或最大差1的容差。

| 输入/原图ROI | medium网格不同像素/最大RGBA差 | none网格不同像素/最大RGBA差 | 对应Reader实际残差 |
| --- | --- | --- | --- |
| RGBA16，`64,224,512,512` | 173 / `[1,1,0,0]` | 0 / `[0,0,0,0]` | 单页两模式各173 |
| RGBA16，`64,64,512,512` | 225 / `[1,1,0,0]` | 0 / `[0,0,0,0]` | 连续两模式各225 |
| gray+alpha16，`64,224,512,512` | 64 / `[1,1,1,0]` | 0 / `[0,0,0,0]` | 单页两模式各64 |
| gray+alpha16，`64,64,512,512` | 107 / `[1,1,1,0]` | 0 / `[0,0,0,0]` | 连续两模式各107 |

**Finding F-COLOR-V7-INT-CROP**：E-COLOR-V7-READER与E-COLOR-V7-PROBE把残差定位到Android原尺寸整数裁片中的medium采样。以上单页/连续两模式共8项，其不同像素数、各通道绝对差之和以及首12个差异像素的坐标/actual/reference值全部与相应medium网格控制相同。`Paint.isAntiAlias`对控制参照没有影响；透明中间`Picture.toImage`在none路线可以保持本次所测精确像素。定位的是当前engine的滤波路线差异，不推断GPU内部数学实现或16-bit/HDR最终面板码值。

**Path P-COLOR-V7-INT-CROP**：原文件Flutter codec → 原尺寸decoded image → backend裁片 → Surface原像素绘制 → 独立原文件黑底参照。E-COLOR-V7-PROBE中前两步重复解码exact；裁片采用medium时出现上述误差，采用none时exact；E-COLOR-V7-READER确认生产路线有同规模残差。

v7 raw JSON已在更新安装前完整归档。PNG附件当时留在Android `code_cache`任务目录，后续install-r被系统清除；事后capture的错误文本单独保留为`.capture-error.txt`，不能当作PNG。因而上述reader/probe对应关系以JSON中的计数、通道总差和首12差异像素为依据，不声称已对两份完整PNG逐字节核对。后续画布附件应在更新安装前导出。

生产 `FlutterReaderRasterBackend.decode` 已改为仅当`scaled.width/height`与输出像素尺寸严格相同、`scaled.left/top`为整数时采用`FilterQuality.none`；缩放或分数源坐标继续使用medium。没有修改Surface预算、原图分辨率、动画分支或参照。Flutter缓存像素版本从`flutter-srgb-rgba8-adaptive-v2`升级为`v3`，使已持久化的旧采样裁片在更新后不能复用；ICC原有禁持久化行为保留。生产文件当前SHA `FB43E2CA74D9946EEE14E93B2C1988EECBB9E62DDB42CA09F39D42C057EED89A`，其中同时包含另一路prepared准入候选改动。

定向验证初轮44/44通过（新增16-bit ICC RGB/gray严格ROI两项、backend、Surface及精度探针）。随后新增真实旧v2缓存投毒回归，精度测试3/3通过：自生成真实sRGB ICC 67×73 RGBA16/gray-alpha16 PNG，与独立原文件codec的黑底ROI逐字节相同且源字节未变；旧v2缓存存在且可单独命中，新backend输出仍来自原文件。新测试无需外部素材盘。精度probe测试还对所有单层none路线断言`rgba8Exact=true`，重复alpha控制继续保留差异。

- 测试文件：`test/flutter_reader_raster_precision_test.dart` SHA `93ACB32FDE08D15F5C77BA73A12D68FA4E6FAF3C0C358AAAA1362FF6F0971465`；probe测试 SHA `0A4D44FEFD960AAC54435F2B0709E3DB6CA952251BA6E44736574F509F60532E`。
- 日志：`build/picakeep-022-continuation/precision-test.log` SHA `321C22878258D1F62B412C574A694DEFB1E632A6FF4937185E588DA5BCB8CDAB`；`precision-cache-test.log` SHA `482B80B3D4A4CB4B94DBE2AF9316098F6AAFB7CF02249F390988E1494ED470BC`。
- 相关backend/tool/新测试 `dart analyze` 无问题。tool main SHA `6278008710778804BE4CAB35A5986BB1C9A3DBD5D104B5F9336398C0EB9C82D0`；诊断probe SHA仍为 `EB34AF1B6DE9F60F31CB3E16C201BF7FD509FB8C680E9C79D32EE6EF60D50AE6`。

复核命令（项目根目录、已安装Flutter SDK；Windows TEMP沿本任务配置指向D盘）：

```powershell
flutter test --no-pub --concurrency=1 test/flutter_reader_raster_precision_test.dart test/flutter_reader_raster_backend_test.dart test/reader_image_surface_test.dart tools/image_pipeline_022_color_precision_probe_test.dart --reporter expanded
```

Windows tester通过与Android修复后的实际画布验收是两个独立证据。当前v7是修复前诊断APK，不能拿该报告宣布生产修复真机已通过；下一步必须新profile包完整三布局×两模式36项逐像素复测，保留此前v6/v7失败。022仍执行中。

## v8 实际冷启动裁片失败与整数平移候选

v8 profile APK SHA `897CD082CB12CD5538A4CF53A0040F891DA47CB408F210F257F2110845798876` 使用上述 `FB43...` 整数none `drawImageRect`候选。完整矩阵及同APK新任务目录重复均36/36 measured、48帧、errors=[]、原件不变，但首个RGBA16单页sharp组合均有18,432个不同像素，最大RGBA差 `[249,255,53,0]`；另35组合/47帧全部exact。这两次不能标为整组质量通过。

| Evidence | 原始文件 | SHA-256 |
| --- | --- | --- |
| E-COLOR-V8-FIRST | [color-v8-redmi1006-first.json](color-v8-redmi1006-first.json) | `B72B7CDA6D924555885623E6EA71C47FF681BC1CD01921A64593865FE3535E16` |
| E-COLOR-V8-REPEAT | [color-v8-redmi1006-repeat.json](color-v8-redmi1006-repeat.json) | `EBD32B32FD4CA32EE6FC66814779E11D7649D6855F731A93C4DD34BE082356FC` |
| E-COLOR-V8-PNG | `build/picakeep-022-continuation/color-v8-artifacts.tar`，PNG已在更新安装前导出且可实际解码 | `EF829FE6EFF3133E14FFC123F3C046678151CAE51E89086C4A12D488EFDBB55D` |
| E-COLOR-V8-PNG-REPEAT | `build/picakeep-022-continuation/color-v8-repeat-artifacts.tar` | `FB7B0E40FA49525BAA7041599D6AEC67764EAB3F3EC88CED6723BAEE63F3C5B2` |

**Finding F-COLOR-V8-COLD-TILE（待定位）**：差异矩形严格为画布`x448..511,y0..287`，即源`x512..575,y224..511`的右上512网格裁片可见部分；该块出现错位/压缩颜色图案，其余画布逐像素相同。真实Surface快照记录4个目标原像素tile均resident，sharp无preview，AA参照控制仍相同。因此已有证据不支持简单“瓦片没到”或沿用原先最大1差的解释。两个重复确定该启动条件可复现，尚未证实底层GPU/codec或采样内部机制。

两份tar分别解码PNG为RGBA8后，actual原始像素SHA同为`DA8DC98FA80670070B143D67F82EC179CD4DE88B8236DC9735ABB23466D9BE0A`，reference同为`67B92CDB08003D89AC58031BA82A354BD2E0686A309998EC8E0C78FD86CBE045`。完整PNG复核证明两次错误画布逐像素相同；错块呈16像素分块重排，不能用单一源矩形平移解释。离线脚本`build/picakeep-022-continuation/inspect_color_v8_artifacts.py`采用tarfile/Pillow/numpy逐像素mask，输出`color-v8-offline-tile-analysis.json` SHA `4B21DAF510E9483DF25423DD6F4C103DD83316CFF206B1EDBFDCE67F839B9EE1`。此离线观察不等于已定位engine内部故障。

原精度probe在裁片前对原件调用`toByteData`，与实际生产第一次解码顺序不同。probe现已增加每tile独立原尺寸codec、在任何源像素读回之前完成的`cold-codec-grid512-rect-none`和`cold-codec-grid512-translate-none`，保留原11条路线及原参照。schema为`image-pipeline-022-color-precision-v2`、每ROI13条路线；它测试新的codec未预先读回，不保证整个GPU/进程未被前面的Reader矩阵预热。

候选生产整数路径现改成`drawImage(whole,-scaled.topLeft,Paint.none)`，输出Picture的整数大小截取原像素；分数坐标/缩放仍走medium `drawImageRect`。该候选避免额外源矩形采样路径，并未引入readback同步、全图纹理旁路或额外分辨率。Flutter像素缓存版本升级`v4`，新SHA `BCD716371E0B9775FC54F1E3CC020608F9F53D7DFF7E10BC21B184B3457F5305`。v3失败证据保留，候选仍需Android新profile实际矩阵检验。

本次候选 Windows 定向44/44通过，日志 `precision-draw-image-test.log` SHA `104CE4D966928CF1EEBC2F8C8B0F5B831FB35CD8492CBFB8BD09A20C8B76A546`；新冷codec探针1/1通过、所有单层none路线严格exact，日志 `precision-cold-grid-test.log` SHA `E0D28AF6C54BD62030BD2F0EBD64C1FFC0EBFAE44636B88C243987A8BC6115A5`。相关Dart analyze无问题。probe SHA `5AEFD2FE0FAF74AD146CA053904E6D9A974B459ED11C928BA0D0ABC2802E2395`、probe测试 SHA `F13770E2B86174975198DA33EC5DA91A578B9D3D18FA6CC8561DD0D440F2ED69`。

**Path P-COLOR-V8-RECHECK**：E-COLOR-V8-FIRST/REPEAT完整源与画布保留 → 单独整数drawImage平移候选 → 新profile首例及全部36组合严格比较；最后一步未完成时不宣布修复真机通过，022继续执行。

## v9 Reader exact与独立冷codec失败分别记录

2026-10-06 20:25–20:26（Asia/Singapore），v4整数平移生产路径的实际Android Reader矩阵36/36 measured、48帧，全部RGBA8与可用float读回逐像素exact、FrameTiming48/48、errors=[]，36次原件SHA均不变。报告 [color-v9-redmi1006.json](color-v9-redmi1006.json) SHA `23CBC143F1D571BD1F690AC9DDF557947074C5173361182A6CF2FBE025510FCF`。最终resident/pending/surface/job/working/temp/原件lease/raster cache/disk账/ImageCache均0，worker shutdown后0；native45完成、9次GIF probe code4兼容分支、0非原生错误。这个结果覆盖本次真实Reader三布局/两模式，不能覆盖所有冷codec路径。

随后同run独立精度probe13路线/ROI的冷codec控制仍失败。报告 [color-precision-v9-redmi1006.json](color-precision-v9-redmi1006.json) SHA `63A85E270CE9085C15FAC552D2923D4C8447E189D23BB54F5D9942020A433B33`，4素材、8ROI均measured、errors=[]、源未变；`measured`并不等于严格质量通过。

| 输入/ROI | 冷rect-none不同像素 | 冷translate-none不同像素 | 离线PNG实际差异范围（LTRB exclusive） |
| --- | ---: | ---: | --- |
| RGBA16 `64,224,512,512` | 14336 | 14336 | `[448,288,512,512]` |
| RGBA16 `64,64,512,512` | 4096 | 4096 | `[448,448,512,512]` |
| gray-alpha16 `64,224,512,512` | 14336 | 14309 | `[448,288,512,512]` |
| gray-alpha16 `64,64,512,512` | 4096 | 4081 | `[448,448,512,512]` |
| P3/Adobe RGB各两个ROI | 0 | 0 | 无差异 |

所有8个16-bit冷控制的差异均位于右下128×448边缘tile的可见范围。RGBA16的rect/translate两个路线完整actual像素相同；gray路线差异范围相同但像素不同。有效附件包`build/picakeep-022-continuation/color-v9-precision-artifacts.tar` SHA `43CA9CE7075BB03AE8F36EB4AD5E65A4C194EE1A1C96279D8822EF38924CDF0F`，由tarfile/Pillow/numpy解码PNG后独立比较，已在下一次安装前导出。最初一次不完整tar流保留为传输失败，不能用来判定像素。

因此v9支持本次实际Reader矩阵exact，但**不支持“所有冷codec裁片精度已通过”**，也没有证实源矩形API就是全部根因。生产版本仍为v4，未用全图旁路或同步读回来掩盖失败。诊断probe现增加保持原始`ui.Image`至全部mosaic读回结束、每tile原图rawRGBA预读控制，以及rawRGBA8/float32 ROI重构；均限固定640×960和已有诊断工作预算，生产未启用。probe schema v3，16–17路线/ROI，SHA `6C0C02BC96E2B3FF1A9A5DA1B603E027D1A9D85B4DD9BB92D1AD8915A38EBF8F`，Windows探针1/1通过（10秒）、相关analyze clean，仍待Android实际诊断。

## 全量回归中缓存投毒测试的路径修正

新精度测试在全suite的长TEMP `build/picakeep-022-continuation/regression-temp` 环境下，旧v2缓存独立load为null。定向同环境复现确认旧key/token未变、store.lookup已完整发布；直接`ImmutableBuffer.fromFilePath`报`Could not load file`，缓存PNG由两段SHA组成，其完整路径超过Windows codec路径边界。原失败日志与直接解码复现保留：`precision-same-env-repro.log` SHA `A53CC946B519F891A5E80D14CA345E544E824DD76AD1FF71818AE0A4F3F1D0F6`，`precision-same-env-decode-repro.log` SHA `ACA517E65C68163C16A07FC7DC1302AC33CC441605DA134748369C82C8BB09B6`。

测试fixture已改为Windows项目根下唯一`.pkc-*`短目录，退出删除；保留“旧key稳定、旧持久条目存在、旧v2确实可加载、新backend拒绝旧像素”全部断言。同fullsuite TEMP条件重新3/3通过、analyze clean；测试SHA `97DC0192CC5DF51199E5E48416DAE2FC3BC84EEE79D6ADF5A48ECC4D9F7435CF`。这只修正测试路径，未更改生产缓存路径或吞掉失败；长路径codec行为不能据此视为生产已修复。完整回归的其他失败由对应owner继续处理，022不以此节声明总验收完成。

## Android v10 Reader与冷codec读回控制

2026-10-06，v10诊断包只含工具侧读回能力处理，没有改生产Renderer或backend。Profile APK SHA `51900ABFFB27D5ED71A5D1182BE4E08EDAA286377DA874C6BA25EF99C95E4263`，Android设备 `8021129d`；当前已恢复安装v9 Reader profile包，v10诊断包留在任务工作目录。工具源码 `tools/image_pipeline_022_color_precision_probe.dart` SHA `117A8642EF231BCC72D8CF82F62475D18416B4E64778507F20D74E8CF8124972`，analyze clean。

| Evidence | 观察 | 原始文件 SHA-256 |
| --- | --- | --- |
| E-COLOR-V10-READER | Android profile，36/36 case、48/48帧RGBA8逐像素exact、errors=[]、素材SHA未变；结束时surface、job、lease、reservation、cache、disk quota及worker均归零 | [color-animation-v10-float-readback-capability-redmi1006.json](color-animation-v10-float-readback-capability-redmi1006.json) · `C3D74404D2F83C2F4B6A0D0559A8B85391FEE5C92A7A840FD050E7D7B9C9987D` |
| E-COLOR-V10-PRECISION | 4素材、8个ROI、136个variant条目；128项measured、8项Float32 unsupported；errors=[]、无阈值、`automaticQualityAcceptance=false` | [color-precision-v10-float-readback-capability-redmi1006.json](color-precision-v10-float-readback-capability-redmi1006.json) · `5F726CB16BCF6EC7D2DAA9EC6F89EFC3C0DEC2F2133060DE5BE4EA44137BCD6F` |
| E-COLOR-V10-ARTIFACTS | 有效precision附件包，93项，已校验可列出 | [color-precision-v10-float-readback-artifacts.tar.gz](color-precision-v10-float-readback-artifacts.tar.gz) · `51D04CE8BCFC736B70804F464841676031D5831BA0C9C592405ED67EFD3890B2` |

precision路线逐ROI结果：`cold-codec-grid512-retain-original-none`、重复whole-none、透明crop/whole/grid的none路线及RGBA8源读回均8/8 exact。`cold-codec-grid512-rect-none`仅4/8 exact；两个独立translate冷路线各3/8 exact。`source-readback-roi-float32`的8项均明确记录为unsupported，Android Flutter engine报 `Failed to get color type from pixel format.`；这不是质量通过或精度失败像素。`medium`与重复alpha控制仍有不同像素，作为采样/合成控制保留，不用于放宽阈值。

retain控制将每tile的全尺寸源 `ui.Image` 保留至该fixture全部ROI读回后；生产backend在每次裁片返回时释放该次whole/codec/descriptor/buffer，两者生命周期不同。8/8 exact只为生命周期/顺序/资源影响提供线索，不足以定位原因或验证生产修复，不能直接延长生产原图驻留而绕开既有预算。

结论只限本次Android Reader矩阵和这些固定ROI。Reader矩阵exact不能覆盖冷codec裁片路线；precision整体仍未通过。该诊断也不是原始16-bit精度、HDR面板或compositor scan-out验收。v9 Reader surface独立报告仍为66/66 exact，见 [reader-v9-surface-quality-redmi1006.json](reader-v9-surface-quality-redmi1006.json)。
