# 022 封面、派生缓存与远程图像协议验证

本记录覆盖 P4/P7/P8。实现已经写入工作区；性能验收以独立 profile 入口产出的实际 30 次报告为准。原 64 MiB 阈值与 32 MiB 原生候选都已在 Android/Windows 完成同入口、同图、同卡片的 profile N=30；候选冷首显退步，当前代码阈值已回到 64 MiB。

## 已落实的行为

封面冷加载先返回可绘制 `ui.Image`，PNG 编码、落盘及全局配额检查在后续事件中进行。缓存命中直接读缩小版本。卡片按实际编码比例、目标物理宽高和 BoxFit 选择采样尺寸，小图不放大，长边不超过 4096、输出不超过 4 MP。

本地封面派生键已升为 `thumb-v3-area-fit`，路径入口及旧预处理入口都区分新滤波结果；服务派生键使用 `algorithmVersion=2`，manifest 传递该版本，remote reader缓存按版本隔离，封面 URL 带 `a=2`。缺少此字段的旧服务 manifest 按算法1兼容解析。原生封面解码的硬内存上限与共享队列为本 job 预留的 native estimate 相同，不使用全队列总预算；估计和实际解码共用同一输出尺寸。

服务 renderer 同样接收 `jobBudgetBytes`，将 decode 与 encode 的原生上限限制为该任务的 probe estimate 加输出 RGBA，并继续服从 renderer 自身总上限。共享队列另预留输出传输/编码副本，源文件在 estimate 与 decode 之间变更时不能借用全队列总内存；更高工作空间要求返回有限错误，不发布缓存，预算释放后可重试。

封面正式入口是 `CoverThumbnailCache.prepareProvider`。普通且无 ICC 的源在 64 MiB 原 RGBA 工作集以内使用 Flutter codec 目标尺寸解码；超限、EXIF 旋转、ICC 或高位深走受控原文件区域解码。无原生插件的平台仍将受控 Flutter 路径限制在 64 MiB 内，超界拒绝解码。共享队列先按原生 estimate 准入。失败、过期 provider 或清缓存后的重载不会转为无限制原图解码。正式阅读使用原文件坐标及无损 PNG 分块，封面 JPEG 不参与阅读。

自建服务 `/status` 发布 v1 能力。新增 manifest、无损层/分块与显式封面 variant，旧无参封面和原图路由保留。原生服务显式支持 PNG/JPEG/WebP 封面，默认 opaque JPEG85、透明 PNG；显式 WebP 使用无损编码。正式阅读固定无损 PNG。Flutter 小图兼容后端只发布 PNG/JPEG 及有限像素能力。

202 是短租准备状态，持续轮询共享同一工作；客户端不将 JSON 存为图像。304 有有效本地正文才复用，正文丢失时取消条件头重取一次。封面 409 刷新作品 detail 后重试新版本一次，落盘使用新 URL/version；阅读 409 获取新 manifest 后通知页面重新解析，避免旧新版本混图。

后台预处理在下载最终提交、导入 transfer complete、本地快照发布与服务快照发布后非等待入队。客户端队列最多 32 个待处理路径，服务每轮最多准备 12 个变化封面；失败不回滚下载/导入。共享队列保留前台执行空间。预处理使用缩小封面，不提前铺满全书最高层。

## 缓存与空间边界

| 用途 | 目录 | 清理规则 |
| --- | --- | --- |
| 本地封面缩略图 | `App.dataPath/local_library_cache/covers/thumbs` | 来源 stamp 和宽度桶区分版本，完成后异步 LRU |
| 已登记本地封面副本 | `App.dataPath/local_library_cache/covers` | 仅登记的可再生文件；不删除未知收藏或用户文件 |
| 远程封面 | `App.dataPath/cache/remote_library_covers` | 新版本重新命名，清理 generation 阻止旧任务重新发布 |
| 服务派生图与完整索引 | `App.dataPath/cache/image_pipeline_v1/server/{cover,readerLevel,readerTile}` | 原文件版本/用途/算法版本哈希；长度和 SHA-256 校验；原子完成索引 |
| 服务暂存原图、ZIP member | 服务派生根 `inputs` | 按实际 stat/member 大小预留；单源最多 512 MiB；ZIP stage 解出后即释放 |
| 远程阅读无损缓存 | `App.dataPath/cache/image_pipeline_v1/remote_reader` | 服务器 scope/page/version 分离，ETag 和租约保护 |
| 本地阅读原生 backing | `App.cachePath/image_pipeline/native_backing` | 活跃 lease 保护，本任务 root 管理 |
| 封面原生 backing | `App.cachePath/image_pipeline/cover_backing` | 同源 stamp 复用；保护 `.partial`、`.coeff-*`、`.png16` sidecar |
| 本地阅读无损派生层/分块 | `App.dataPath/cache/image_pipeline_v1/local_reader` | actual源stat/完整rect/输出尺寸/颜色及滤波版本键；PNG/SHA验后命中可绕原生backing缩放 |

持久缓存沿用设置 35，默认 500 MB，多个用途共同统计。活跃任务另有全局 2 GiB 临时池，单次 reservation 最高 2 GiB；原生 job 当前预留 1 GiB，源文件及发布输出另外按实际/上限计费。活跃文件不作为 LRU 候选，完成后异步维护。池是准入上限，不代表磁盘必有空间：实际磁盘不足会终止任务，保留原文件，返回有限错误。

工具页显示封面、预览、阅读层、阅读分块、原图暂存、处理空间和其它缓存；统计走 IO isolate。清除缓存先失效 writers，遍历不跟随链接，活跃租约不会被删除。服务派生图也有 headless 配额维护，发布不等待扫描。

网络原图的 `OnlineImageCache.lease` 同时保护正文和配套 JSON，并桥接 `DerivedImageStore` 全局租约。全局 LRU 与手动清缓存均保留每个活跃消费者的源文件；独立释放且幂等，最后一个消费者释放后才可清理。PNG 8 bit、非交错、无 ICC、无旋转的原生整图缩小使用逐行 area-fit，实际 `diskBytes=0`，不写 backing 或 sidecar；1 GiB 临时 reservation 是保守准入，不代表写出 1 GiB。

## 证据与结果

| Evidence | Finding | Path |
| --- | --- | --- |
| 最后一次完整定向静态分析 `No issues found` | 新模块与现有入口类型匹配；不等于运行验收 | `lib/foundation/image_pipeline`、`lib/server`、封面/本地manager/remote/inventory/tools及新测试和profile入口 |
| 首轮真实运行 `derived_image_store_test` 5 项通过 | 损坏正文、跨 scope、迟到发布、lease、配额、正式层拒绝有损受保护 | `test/derived_image_store_test.dart` |
| 首轮真实运行 `cover_decode_target_test` 2 项通过 | 宽图在竖框使用 cover 不只看宽度；真实编码尺寸匹配 | `test/cover_decode_target_test.dart` |
| root 统一旧快照回归返回 45 passed / 1 failed | 唯一失败是 HTTP test 在 test zone 外创建 HttpClient；已改 setUpAll 真实 HttpOverrides，等待新快照回归 | `test/image_protocol_http_test.dart` |
| 最新真实回归 HTTP/derived/target/inventory 合计 23 passed | 原路由字节一致、权限、最高层逐像素、202 单 job、304 丢正文、旧服务、新 cover 409、远程 tile 不先拉原图、用途统计均通过 | `test/image_protocol_http_test.dart`、`derived_image_store_test.dart`、`cover_decode_target_test.dart`、`cache_file_inventory_test.dart` |
| 最新真实回归 thumbnail/Pixiv folder 合计 22 passed | PNG 持久化屏障未释放时已有实际 RawImage；源图替换、warm不读源、共享消费者、外部暂存与重试通过 | `test/illust_thumbnail_test.dart`、`test/pixiv_folder_cover_integration_test.dart` |
| 推荐瀑布流整文件 24 passed，含 teardown | 记忆上次ranking造成原测试额外请求假设错误；按ranking是否已访问验证仍恰一次，测试设置IO隔离解决FakeAsync遗留文件句柄 | `test/explore/recommendation_waterfall_test.dart` |
| 新本地无损缓存 testWidgets 3 passed | 实际 frame 前不编码；frame 后无损 RGBA 完全一致；原文件在 decode/persist 间替换、损坏正文、geometry/color版本均不会复用 | `test/reader_raster_cache_test.dart` |
| 专项冷绘制→清Flutter内存→warm绘制 testWidgets 1 passed | 修复 decoder callback 已处置 buffer 后二次处置的 disposed native peer；真实warm图尺寸正确且无异常 | `test/illust_thumbnail_test.dart` |
| 当前工作区完整 suite：2716 passed / 14 skipped / 0 failed | 最后一轮完整回归已通过；此前 HTTP zone 与测试接口问题已修正 | `E:\picakeep-image-pipeline-022-work\all-tests-final.log` |
| 随后审计修复定向 20 passed；对应静态分析无问题 | 无 native 的48 MiB RGBA原图输出384×512；超过64 MiB受控拒绝；活跃网络原图及JSON经过LRU/clear仍保留，最后释放后清掉 | `cover_fallback_regression_test.dart`、`online_image_cache_global_lease_test.dart`、`cache_file_inventory_test.dart`、`illust_thumbnail_test.dart` |
| 算法/预算审计修复后定向 33 passed；全lib/test静态分析无问题 | 注入旧封面缓存和旧算法服务tile后，仍重新生成当前正确像素；manifest算法字段缺失兼容；网络原图用途归original | 前述4文件、`image_protocol_http_test.dart`、`derived_image_store_test.dart`，`E:\picakeep-image-pipeline-022-work\analyze-final-after-audit.log` |
| 审计后最终完整 suite：2721 passed / 14 skipped / 0 failed | 缓存损坏测试按当前identity选正文，避免把多个合法旧版本当作夹具错误；完整绿色证据保留 | `E:\picakeep-image-pipeline-022-work\all-tests-final-green.log` |
| 随后服务任务预算修复定向9 passed；全lib/test静态分析无问题 | 模拟estimate后源工作空间增加时拒绝且无缓存发布；预算释放后重试成功；完整HTTP8项保持通过 | `image_derivative_job_budget_test.dart`、`image_protocol_http_test.dart`、`E:\picakeep-image-pipeline-022-work\analyze-final-server-budget.log` |

需要统一回归的具体文件：`image_protocol_http_test.dart`、`illust_thumbnail_test.dart`、`derived_image_store_test.dart`、`cover_decode_target_test.dart`、`cache_file_inventory_test.dart`、`local_cover_cache_test.dart`、`local_library_illust_card_test.dart`、`remote_service_transport_lifecycle_test.dart`、`online_waterfall_card_test.dart`、`pixiv_folder_cover_integration_test.dart`、`explore/recommendation_waterfall_test.dart`，以及 root 的 reader/source/native 测试。root 授权后上述最新定向测试在原仓库运行；Flutter 构建始终由 root 从独立快照串行运行，避免插件生成文件及产物冲突。

## 30 次封面 profile 复现

专用入口 `tools/image_pipeline_022_cover_profile_main.dart` 只建立自己的 fixture/cache/report，不初始化用户作品库。Windows 工作根固定在本任务工具目录 `E:\picakeep-image-pipeline-022-cover-profile`，Android 使用应用自身 temporary/cache。每轮使用相同的 4096×4096 PNG、128×128 dp contain 卡片和运行设备相同 DPR。

```powershell
flutter run -d windows --profile --target tools/image_pipeline_022_cover_profile_main.dart
```

root 统一从 E 盘构建快照启动此命令，不能同时在共享原工作区运行其它 Flutter build/test。Android 指定实际 `adb devices` 得到的设备 id，保留既有数据，仅使用 debug/profile。

入口先排除一次 engine/shader warmup，再交替记录全原图 baseline、正式入口 cold384、warm384 各 30 次。冷样本只改来源 mtime，编码字节和可见图像相同；因此是派生缓存冷加载，OS 文件缓存可能已温热。Image.frameBuilder 的 Timeline 值必须落入某条 FrameTiming 的 buildStart..buildFinish 精确区间，该帧 rasterFinish 减请求 Timeline.now 测实际栅格完成；不使用 provider ready 或 PNG 落盘完成当作首显。

输出 `cover-profile-30.json` 含原始逐次数据、p50/p95、DPR、源字节数、RSS 前后与进程 peak RSS，并以 stdout `PICAKEEP_COVER_022` 打印 summary/reportPath。时间为 engine 栅格完成；没有声称测到 OS compositor 实际扫描显示。进程 peak RSS 是累计高水位，不能直接当某模式独占峰值。曾遇 strict vsync 匹配超时、Windows窗口未show与warm buffer重复dispose，已修并完成以下正式30样本。失败记录保留 `cover-profile-failed.json` / stdout时间诊断，不作为性能结果。

32 MiB候选入口的 schema2 记录32/64 MiB阈值、`thumb-v3-area-fit`、原生支持/实际可用状态、原生源 metadata、源正文 SHA-256、decoded宽高与物理卡片尺寸字段；后续确认其decoded字段实际为0，不能作为尺寸证据。probe和SHA计算发生于样本计时之外，原4096²fixture和计时区间保持不变。保留正式产品的异步持久化及配额维护；它们可能与首帧竞争，没有给测试专设阻塞屏障。每轮App data/cache均在独立workspace内，维护扫描不会遍历用户正式缓存。

fixture只有渐变与周期颜色边缘，不能替代真实插画和细线文字的视觉验收。本入口固定384像素输出以对照旧30样本；Android DPR3.5时128dp卡片实际448物理像素，因此固定384方案本身不是原像素密度展示，不能据此宣布所有封面均达到细节质量目标。

### 原64 MiB阈值实测

4096² RGBA 正好 64 MiB，严格 `>64 MiB` 走 Flutter。因此下列 cold 结果是 Flutter 的真实正式入口，不能当作原生32 MiB候选的结果。

| 平台/模式 | P50 ms | P95 ms | 相比原图P95 |
| --- | ---: | ---: | ---: |
| Android DPR3.5 原图 | 263.709 | 288.724 | 基准 |
| Android cold384 | 254.163 | 280.013 | 改善3.0%，未达20% |
| Android disk warm384 | 14.481 | 22.226 | 改善92.3% |
| Windows DPR1.5 原图 | 208.207 | 237.823 | 基准 |
| Windows cold384 | 183.518 | 206.696 | 改善13.1%，未达20% |
| Windows disk warm384 | 14.271 | 19.435 | 改善91.8% |

原始逐次文件：[Android Flutter cold 30](cover-android-flutter-cold-30.json)、[Windows Flutter cold 30](cover-windows-flutter-cold-30.json)。结论是派生已就绪时明显提升，首次生成尚未达到冷加载目标，不能整体宣布20%达标。32 MiB 原生候选继续同入口、同图、同卡片、各30次对照，保持首次显示不等待编码。

本地 `ReaderRasterCache` 保存时捕获 decode 前的 actual源身份，并在实际 frame 结束后开始 PNG 编码；clone 总待写 RGBA 不超过32 MiB，单图不超过4 MP。没有frame时2秒放弃写入，释放clone与 `ReaderPageFileLease`，避免离页或暂停保留原文件。默认原生像素版本为 `native-srgb-premultiplied-rgba8-fit-filter-v2`；自适应 Flutter 路径使用独立 `flutter-srgb-rgba8-adaptive-v1`，不能互相复用。正式阅读root集成该helper，封面与服务decoder显式禁用重复本地阅读缓存。

### 32 MiB 原生候选复测与阈值决策

两端均运行 profile `tools/image_pipeline_022_cover_profile_main.dart`，对相同 SHA-256 的合成 4096×4096 PNG，各执行 baseline / cold384 / warm384 各30次，按首幅实际 Flutter engine `rasterFinish` 计时；持久化不阻塞首帧。Android Redmi K30i 5G (`8021129d`, DPR2.75，128dp=352px) 和 Windows (DPR1.5，192px) 分开记录，OS 文件缓存不清空，样本图为色彩渐变与周期边缘，不等于真实插画观感。

| 平台 | 模式 | P50 ms | P95 ms | 同轮 baseline P95变化 |
| --- | --- | ---: | ---: | ---: |
| Android | full 4K baseline | 264.610 | 289.234 | 基准 |
| Android | 32 MiB candidate cold384 | 436.238 | 465.102 | 慢60.8% |
| Android | 32 MiB candidate warm384 | 43.919 | 48.263 | 快83.3% |
| Windows | full 4K baseline | 115.537 | 122.499 | 基准 |
| Windows | 32 MiB candidate cold384 | 136.314 | 149.128 | 慢21.7% |
| Windows | 32 MiB candidate warm384 | 8.420 | 22.078 | 快82.0% |

三种模式每组均有30个成功呈现记录，源哈希均为 `11db732775cdb2497f108e0502ee4993e38b1e781231de81a7fca88e01361630`，报告中的 codec 真实输出宽高字段为0（wrapper未向 frameBuilder 暴露 `RawImage`），不可据此声称验过真实封面解码尺寸或视觉质量。Android/Windows原始报告分别为[Redmi candidate N30](cover-redmi-native32-30.json)与[Windows candidate N30](cover-windows-native32-30.json)。旧64 MiB同入口结果见上表：其冷 P95 分别为280.013 / 206.696 ms，热 P95 22.226 / 19.435 ms。因32 MiB候选冷首显相对各自同轮 baseline 回退，而旧64 MiB策略冷路径未回退、热命中均显著更快，代码阈值恢复64 MiB，32 MiB不继续作为产品默认值。首次生成仍未达到原计划的20%冷首显提升目标，P4不能据此验收通过。

当前自适应 Flutter 普通阅读层已经接入此无损PNG缓存；无ICC图片使用独立Flutter像素版本保存及读取，ICC资源保留原codec路径，避免将携带不同颜色含义的像素误写为普通sRGB。此更新只描述当前实现，不替换此前真实样本中的策略。

原生 encoder 双端比较由 native agent 单独记录，适合选编码默认值；不能替代本入口的正式封面首显测量。当前不默认 lossy WebP；高频色线样本的质量不足，opaque JPEG 和 alpha PNG 的原生编码支持已接入。

## 尚需现场验证

真实 NAS 网络与目标设备的 profile 首显、10 秒稳定清晰、快速滚动、持续内存、后台中断、服务重启、复杂 ICC/高位深、特权与加密归档 HTTP 路径仍需要完整联合验收。密码与外部原文件接口由 source agent 实现，服务采用有界 copy/materialize，不整份读入大资源；本文不将 source 层测试当作已经验证全部服务 HTTP 组合。

## 2026-10-06 接续：封面编码竞争候选

读码确认原冷入口在返回provider前已创建`Future(event)`PNG持久化任务，准备图像被`Future.value`异步交付。两者可能把PNG编码和额外一次图像交付延后放到首帧路径；这是一项待profile量化的机制判断，旧N30不能归因到其中某一项。

当前候选保留64 MiB阈值、缩放尺寸、PNG像素及`thumb-v3-area-fit`键，仅作以下调度调整：准备好的cold图像用`SynchronousFuture`交给Image stream；provider被实际load后才登记UI postFrame，下一event把编码/落盘提交到共享background队列。未消费或2秒内没有frame则释放持久化clone和源租约，多个同key provider共享消费信号。待写像素仍限制32 MiB/32项。清缓存generation、源stat替换、任务取消均拒绝发布；已启动encoder的取消会等待实际run结束再释放clone，避免ticket先完成导致native仍使用已释放图像。UI postFrame只说明该帧UI构建结束，不证明GPU已显示；首显仍由profile的真实`FrameTiming.rasterFinish`判定。

另外，warm目标存在性与长度改成一次`File.stat`，cold解码复用入口已取得的source stat，保留解码后及发布前的来源复核。未缓存元数据、未跳过原生probe或源版本检查。无原生平台的metadata与Flutter codec路径继续受原64 MiB预算控制。

profile入口schema3沿`Image.frameBuilder`的`SingleChildRenderObjectWidget`包装找到实际`RawImage`；缺少真实image尺寸会失败，不能再静默记录0。原SDK的默认`Semantics`正是旧尺寸为0的原因；新入口保留默认语义包装和原卡片绘制，不另加第二条image stream。报告新增providerReady与请求局部阶段：source/cache stat、native probe、queue wait、Flutter buffer/descriptor/codec/frame、native raster、warm codec与PNG编码/写入。阶段是诊断耗时，不能替代首显；`stagesObservedAtRasterTiming`可能含已在UI postFrame后结束的后台阶段，不能相加当作首显串行路径。

| Evidence | Finding | Path |
| --- | --- | --- |
| 当前候选4文件定向29 passed / 0 failed | cold准备未绘制不启动编码；无frame放弃；源替换和清generation不发布旧像素；真实Pixiv widget绘制后落盘并在清Flutter cache后复用；fallback、目标尺寸及既有staging保持 | `E:\picakeep-image-pipeline-022-work\cover-after-frame-regression.log`；`test/illust_thumbnail_test.dart`、`pixiv_folder_cover_integration_test.dart`、`cover_fallback_regression_test.dart`、`cover_decode_target_test.dart` |
| 当前候选4文件Dart analyze无问题 | cover实现、schema3入口及改动测试类型/调用匹配 | `E:\picakeep-image-pipeline-022-work\cover-after-frame-analyze.log` |
| 旧Pixiv非widget测试首次27 passed / 2 failed后修正 | 仅resolve/decode且不绘制的消费者不应产生派生cache；两失败项改为实际pump Image，并保留内部路径、源读取次数及尺寸断言；不是删除验收 | 同一最终回归日志；`test/pixiv_folder_cover_integration_test.dart` |

新候选尚未完成两端profile N30，不宣布cold提升20%。下一步由root从独立快照串行构建同4096²fixture入口，保持相同首显计时、卡片与三组N30，并依据stage判断剩余probe/codec/栅格瓶颈；真实插画、文字细线与物理密度封面验收仍需另补。

### 同源 after-frame N30 实测

root随后从快照运行schema3入口，两端每模式30次，实际RawImage宽高均为baseline4096²、cold384²、warm384²，源SHA仍为`11db732775cdb2497f108e0502ee4993e38b1e781231de81a7fca88e01361630`。这是尺寸证据，不是细线插画视觉验收；PNG全幅解压与目标缩小仍有成本，不能用warm结果代替cold门槛。

| 平台 | 模式 | P50 ms | P95 ms | 同轮 baseline P95变化 |
| --- | --- | ---: | ---: | ---: |
| Windows | baseline4096² | 113.042 | 115.212 | 基准 |
| Windows | after-frame cold384² | 96.222 | 98.440 | 快14.6%，未达20% |
| Windows | after-frame warm384² | 9.382 | 11.849 | 快89.7% |
| Redmi | baseline4096² | 226.425 | 252.346 | 基准 |
| Redmi | after-frame cold384² | 245.940 | 271.223 | 慢7.5%，未达20% |
| Redmi | after-frame warm384² | 51.256 | 70.905 | 快71.9% |

原始报告：[Windows after-frame 30](cover-windows-after-frame-30.json)、[Redmi after-frame 30](cover-redmi-after-frame-30.json)。表中Windows P50从报告实际summary取值，跨轮运行、GPU/电源/热状态可能变化，不能把旧轮绝对耗时差归因成某改动的收益。

schema3阶段统计将耗时瓶颈缩小到以下范围。各列P95来自不同逐次序列，不能相加当作同一最慢样本；nativeProbe每轮一次，均小于2ms，不足以解释20%缺口。

| 平台/模式 | providerReady P95 ms | codec getNextFrame P95 ms | providerReady之后直到rasterFinish P95 ms | matchedFrame raster P95 ms |
| --- | ---: | ---: | ---: | ---: |
| Windows cold | 94.352 | 92.516 | 5.379 | 0.810 |
| Windows warm | 0.821 | 1.685 | 11.250 | 0.356 |
| Redmi cold | 254.236 | 245.365 | 25.816 | 15.136 |
| Redmi warm | 5.824 | 9.190 | 68.356 | 21.791 |

Redmi cold主要耗时在Flutter缩小codec；warm正文很小、providerReady及getNextFrame明显短，但实际UI/GPU交付较慢，不能把70.905ms称为磁盘或PNG解码70ms。旧AndroidDPR3.5 warm22.226ms来自原机，与当前RedmiDPR2.75不同；同Redmi上一轮native32 warm48.263ms也有调度、电源/GPU状态与策略变化，不能据此断言某一处必然导致回退。

Redmi schema3所有cold样本在FrameTiming回调送达时都已记录persistEncode（P50/P95 29.340/42.637ms），Windows仅9/30记录该阶段。FrameTiming回调可能晚于实际rasterFinish，schema3没有绝对stage起止，不能证明这些编码在首raster之前发生。因而后续只加schema4诊断：每stage `timelineStartUs/timelineFinishUs`、providerConsumed/UI postFrame/persistSubmitted瞬时事件及每sample request/imageBuild/matchedFrame build/raster绝对Timeline。调度/像素/阈值不再更改，便于直接判断编码是否与首raster时间区间重叠；诊断时长不会冒称新的速度结果。

P4仍未验收。下一项有依据的实验应补真实JPEG及带文字/细线封面、物理卡片密度选桶，再分别检查codec缩小路径、GPU交付与预生成命中收益；PNG既定20%目标保留，不能用新JPEG样本替换原门槛。

schema4诊断仅新增观测字段后的回归为illust+Pixiv共25 passed，cover实现/入口及surface grid test Dart analyze无问题。证据分别为`E:\picakeep-image-pipeline-022-work\cover-stages-timeline-regression.log`与`cover-stages-timeline-analyze.log`。未再次跑schema4 profile，不将其称为新性能结果。

### schema5 显式真实来源、物理卡片与独立观感证据

为复用已授权匿名真实样本，cover profile入口新增可选配置，生产封面代码不改。无参数仍生成旧4096² PNG、requested384、128×128逻辑卡片、三组各30次，mode名称保持原名。Android只读任务路径`/data/local/tmp/picakeep-native-022/cover-profile-options.json`；Windows入口读取`main(List<String> arguments)`的`--key=value`。

| 配置 | 默认值 | 行为 |
| --- | --- | --- |
| `source` / `fixture` / `fixtures` | 未设置 | 显式输入文件；若为目录，必须同时传`fixture-name` |
| `member-index` | 0 | ZIP/CBZ的第几个图片成员；bounded DartZipBackend物化，拒绝加密成员，报告仅保留成员名称SHA |
| `requested-width` | 384 | 正式prepareProvider请求宽，仍按生产384/768等桶解码；mode名称代表请求宽，不冒称实际解码宽 |
| `logical-width` / `logical-height` | 128 / 128 | 逻辑卡片尺寸 |
| `physical-width` / `physical-height` 或 `physical` | 未设置 | 显式物理像素除DPR得到逻辑尺寸；覆盖对应logical配置，最大1024每轴 |
| `samples` | 30 | 每个baseline/cold/warm组样本数；1–1000，短诊断不能代替N30 |
| `label` | 按generated/external区分 | 使用匿名用途标签；不写原作品名 |
| `quality` | false | 矩阵之后独立实际卡片capture与原codec单幅缩小参考，不混性能样本 |

外部单图先记录源size/mtime/SHA，复制到task workspace并核验副本SHA；ZIP仅对副本成员流式物化到task文件（单成员最多64MiB），原ZIP只读。cold只改变task单图mtime，不改外部源。结束和finally重新核验外部size/mtime/SHA，任何变化保留失败。配置报告隐藏source/fixture路径，避免披露个人作品名。baseline/独立观感reference要解码整幅Flutter原图，原RGBA超64MiB则本工具拒绝运行；巨图交由bounded reader surface质量helper，不在封面benchmark无界解码。

每sample记录实际decoded宽高、physicalCard、contain后实际物理图像尺寸、`displayUpscaleFactor`和`displayNeedsUpscale`；source SHA在两端同输入时必须相同。固定512或768物理卡片与原默认128dp卡片是不同验收组，不能将新组替换此前PNG20%门槛。

`quality=true`在性能矩阵后增加黑底RepaintBoundary，等待同样build/raster匹配后读回真实封面。performance matrix保持原widget布局，不加这个boundary。reference独立Flutter原文件codec按原尺寸解码，再用同Canvas contain/center/default low缩到实际物理卡片；PNG对比逐通道精确记录，没有假设缩小滤波必须零差，没有“允许误差即过关”阈值。另记录相邻RGB梯度总量供判断细线变化；梯度更大也可能是混叠，不能自行视为更清晰。实际/参考两张tiny PNG始终保存到task workspace方便视觉复核，不保存原文件截图成原图。该rawRgba8证据不能声称保留广色域/HDR。

Windows真实JPEG512物理卡片的启动参数示例（已构建入口exe路径由root决定）：

```text
--source=E:\picakeep-image-pipeline-022-work\real-download-source\page-001.jpg
--requested-width=512
--physical-width=512
--physical-height=768
--samples=30
--label=real-page001-cover512
--quality=true
```

Android示例配置只涉及本任务副本，不操作主力机：

```json
{
  "source": "/data/local/tmp/picakeep-image-pipeline-022-real-source/archive-001.zip",
  "member-index": 0,
  "requested-width": 768,
  "physical-width": 768,
  "physical-height": 768,
  "samples": 30,
  "label": "real-archive001-cover768",
  "quality": true
}
```

当前schema5入口Dart analyze无问题，证据`E:\picakeep-image-pipeline-022-work\cover-options-quality-analyze.log`；还未运行profile，不宣布真实JPEG/ZIP的速度或观感已验证。原输入传输/CRC证据见[source-real-download-results](source-real-download-results.md)。
# 2026-10-06 磁盘准入集成补记

CoverThumbnailCache 的 prepared-provider后台持久化、prepareDisplay 和 legacy 三个 PNG 写入入口均在写入 `.part` 前申请统一 ImageDiskQuota publication ticket，rename 后按实际文件 commit，失败或取消则清理自身 partial 后 abort。没有空闲空间/无法查询磁盘时放弃可再生PNG，已准备出的首帧image仍可显示；不删除原封面、已下载来源或用户库。native-cover 外层固定1GiB临时池占位已移除，交由 native decoder 内按真实 raw/coeff/precision plan 申请，避免重复计费。

该变更未修改 source generation、源替换stat验证、clone32MiB、实际消费后的持久化时序或64MiB decode阈值。新增磁盘拒绝测试覆盖prepared首显仍可绘制、display/legacy返回null、pending/active计费归零与原文件保留。`cover-disk-quota-verified-regression.log` 32/32（illust、Pixiv真实文件/ZIP工作流、quota core）通过；三文件 analyze clean。测试空间provider仅用于隔离单测，生产未知空间不放行。

既有 schema5 真实 JPEG/ZIP cover profile 来自早先冻结快照，未包含本次quota接入，因此两版性能应分别报告。上述测试不代表本次新quota版首显速度达标。

## 可见卡片目标与动态大小只读核查

本地插画实际用户路径不是固定384：`LocalLibraryPage.didChangeDependencies` 用屏宽/列数×真实DPR×1.35准备bucket，`IllustCard` 又用紧约束两轴和 encoded aspect 的 `CoverDecodeTarget`；ComicTile裁切 cover 取两轴最大需求，插画 contain 取最小需求。384实验只代表一个卡片物理尺寸，必须和512/768以及实际decoded维度对照，不能描述为所有封面都无放大。

只读时发现的动态情况（现已落实下述修复）：列数设置变更的 `_handleDisplaySettingsChanged` 只重建及reset队列，没有重新算 `_illustThumbWidth`；viewport/DPR变化虽然走didChangeDependencies计算新宽，但没有重新请求已有 `_done`/`_illustCovers`。因此列数减少或横屏放大可能仍展示原来较小bucket。`CoverDecodeTarget` 的 decoder callback只作用于warm路径；prepared cold first是直接已有image，不能凭wrapper补回缺失细节。

建议用统一的可见目标bucket在布局/列数/DPR变化时重排可见cover、generation拒绝旧任务，保留旧provider至新目标prepared完成；两轴/源比例与纹理4MP边界仍保留。本次只读未修改page/provider；需原图、实际卡片捕获和窗口/列数切换工作流验证。文件证据：`local_library_page.dart` 的didChangeDependencies与displaySettingsChanged、`local_library_illust_card.dart`目标框、`cover_decode_target.dart`、`cover_thumbnail_cache.dart` prepared first消费路径。

### 动态卡片尺寸修复与回归

LocalLibraryPage现在在SliverLayoutBuilder中按真实内容宽度计算列宽，统一扣除瀑布流padding4dp、列间距、卡片padding6dp，和IllustCard共享真实DPR×1.35两轴目标helper；共享原384/768/1536/3072/4096 bucket选择，未统一抬到768。Page按item记录已准备与所需bucket，只有更大目标才对该可见key调用既有queue.retry；较小布局继续复用较大provider，同bucket及纯显示设置不重排。旧provider保持至更大provider完成；旧metadata/解码受queue revision/generation拒绝，旧image错误回调还要匹配当前provider，避免迟到错误删新图。新增页数字段只定向补缺失元信息，可直接复用足够尺寸provider。来源刷新与前后台读取会重新验证来源，不跳过已有source lease、quota或源替换检查。

新增真实registered-folder/download.db/1200×1800 PNG→LocalLibraryPage工作流3项：实际生产列数SelectSetting菜单3→2将decoded384升级768；DPR1→2.75升级到原1200；较小布局保留该provider；内容窗口800→1200升级且同bucket1100不重复；MediaQuery全窗口1600与真实内容800分离仍先取384；缺失封面有界失败/dispose无迟到报错，原文件size/mtime不变，任务结束active磁盘计费归零。队列新增连续384→768→1536在飞升级测试，旧384迟到丢弃，只启动最新1536且peakActive=1。新测试和既有queue/card/sliver/thumbnail合计128/128通过，证据`E:\picakeep-image-pipeline-022-work\cover-dynamic-resize-verified-regression.log`。

这些为生产生命周期/布局回归，不代表新quota版真机cold20%速度或卡片逐像素观感已达标；设备旋转、实际DPR和最终冻结构建仍应复核。早期失败日志保留：初始测试等image尚null、卸载直接await旧FakeAsync zone导致等待，以及跨fixture索引IO的测试时钟问题；最终fixture在suite真实zone完成来源索引预备，页面仍使用自己的实际布局queue准备/解码/绘制封面。

## 2026-10-06 真实素材schema5 Windows实测

均为旧冻结快照profile、N30三模式各30、原输入只读复制到独立task后修改副本stamp，外部JPEG/ZIP的size/mtime/SHA前后相同。`cover-real-jpeg-384-windows-30.json`：352×352物理卡片，1062×1500原JPEG，baseline/cold384/warm384 P95为27.284/16.555/16.559ms；同卡片改768后`cover-real-jpeg-768-at352-windows-30.json`为30.616/28.454/27.275ms，解码纹理384×543与768×1085，均无显示upscale。不能无条件增大默认尺寸：此素材384速度收益较好，768额外成本明显。

真实ZIP第1正文PNG（3007×4629，SHA8811fe...ffe）在768×768物理卡片：`cover-real-zip-png-768-windows-30.json` baseline/cold768/warm768 P95=97.682/82.146/16.840ms，纹理768×1183，不放大。故意欠采样384的对照`cover-real-zip-png-384-at768-windows-30.json`=124.591/80.950/32.555ms，纹理384×592、实际upscale1.2973，放大后边缘诊断更弱。不同run基线波动保留，不能用两轮绝对baseline直接计算一条总收益；较大物理卡片按目标尺寸取派生层，不能固定所有卡片384。

质量报告保留独立Flutter原文件→单Canvas参考与实际widget差图。缩略图经过缩小滤波后与直接原图GPU缩小有明显逐像素差异；JPEG384参考边缘量15455081/candidate8089027、7688457223，数值既受aliasing影响也受滤波影响，不作为“越大越清晰”或容差通过判据。ZIP768参考9385926/candidate7758682，欠采样384为7160392。此处证实分辨率/upscale/原文件未改，正式观感仍须检查实际缩小图。封面允许质量与速度折中；这些证据不得作为阅读原图画质结论。

## 2026-10-06 正常main headless实际入口

正式`lib/main.dart` Windows profile（旧quota前冻结快照）已构建，实际独立进程以`--server --verification-data-root=E:\picakeep-image-pipeline-022-work\server-022-headless-real-source`启动，监听127.0.0.1:27439。`server-production-headless-before-quota.json`记录13项全部通过：native能力、独立路径/授权、真实JPEG原字节与cover/304、ZIP正式stream提取与3个原像素tile精确相同、8个并发消费者、typed409/source替换版本失效、加密归档先拒绝后解锁原字节。只修改/恢复独立task中的来源副本；检查结束停止该自有进程，未启动正常用户GUI/库。

这是正常应用构建实际入口证据，补上原先只在Flutter测试进程中启动server的边界；仍未包含新quota、实际GUI服务按钮、完整remote reader产品界面以及强断连接native取消。构建、stdout/stderr与外部检查报告在E盘022 work目录，正式最终版本应再次验证。

Android schema5同条件真实素材补齐：`cover-real-jpeg-384-redmi-30.json` baseline/cold384/warm384 P95=84.743/55.022/43.617ms；`cover-real-jpeg-768-at352-redmi-30.json`=87.724/74.356/60.244ms。352物理卡片均无upscale，384冷改善约35.1%，无需全局改768。ZIP正文在768物理卡片：`cover-real-zip-png-768-redmi-30.json`=220.662/197.905/65.256ms；`cover-real-zip-png-384-at768-redmi-30.json`=218.903/207.267/62.984ms，后者upscale1.2973。ZIP正确分辨率768冷仅改善约10.3%，未达到20%组目标；实际source/version与外部输入前后SHA相同，各90样本真实raster匹配，缩略图差异和原始图均保留。此旧快照APK是profile、version9与既有debug签名一致，显式8021129d install-r保留数据；四轮后停止测试应用，未清数据。

另产品路径反查：插画列表改列数或DPR/旋转后的bucket没有使已完成queue/provider升级，可能把旧小纹理放大。正在按真实Sliver横向可用空间重新算bucket、仅需求变大时排可见项、保留旧图至新provider成功，并用generation拒绝迟到任务。此流程修复未影响上述旧快照证据，须单独UI回归与新版本profile验收。

## 2026-10-06 高DPR封面与服务页真实入口回归

ComicTile现在使用共享的两轴物理目标计算（真实卡片约束×DPR×1.35），不再把DPR限制在3倍；`CoverDecodeTarget`在provider实现`CoverTargetProvider`时先解析目标变体，再按原图比例和`BoxFit`计算解码尺寸。DPR4.5的真实`DownloadedComicTile`回归确认解码纹理覆盖物理卡片两轴，切换到DPR2.75后会降到新的目标且没有迟到异常。服务页回归使用隔离task目录、独立配置、真实`ServiceInfoPage`按钮和loopback HTTP，验证启动、重启、状态响应、停止后的端口拒绝、配置快照以及原始文件size/mtime/字节均保持不变。封面目标、远程变体和服务页组合测试最终8项通过，日志为`E:\picakeep-image-pipeline-022-work\cover-high-dpr-service-gui-final-regression.log`。

远程封面provider按两轴物理目标和`BoxFit`选择第一个足够的服务端宽度，横向图片会因高度不足继续升级；目标变体进入URL、内存和磁盘key，原图或不足的服务端变体才回退。真实HTTP和Flutter DPR1→4回归为3/3通过，完整组合回归为35/35通过。服务端没有足够尺寸时仍使用原URL，避免把低分辨率响应当成清晰封面。

Android阅读器长图质量报告的9个非零项（800×30000 PNG/JPEG/渐进JPEG的中心、底部、磁盘缓存）均为最大RGB差1、alpha差0，且冷/缓存结果完全重复；实际和参考尺寸均为800×1024，源文件未变。差异集中在高频渐变的边缘采样位置，独立参考路径在已按原尺寸解码的ROI上仍使用`FilterQuality.medium`，而正式密度1且轴对齐的阅读绘制使用`FilterQuality.none`保留原像素，因此该报告是参考滤波策略差异，不能作为放宽逐像素质量标准的依据。后续若重跑质量helper，应让1:1参考采用与正式绘制相同的none滤波，再继续零容差比较。

## 2026-10-06 历史进行中状态补正

上文真实素材实测后写到动态列数/DPR封面修复“正在”进行，是当时的历史状态。当前该修复及高DPR、远端两轴/BoxFit变体已实现并冻结；真实LocalLibraryPage的列数、内容宽度、DPR升档及缺失封面流程已有上述回归。随后完整suite暴露的本地resize和ServiceInfoPage测试退出残留native idle Timer，已仅在fixture卸载与实际IO完成后显式关闭worker、等待`workersAlive==0`，关闭前断言active/queued job为0。使用真实独立native DLL组合复测本地3项及服务页1项，4/4通过、无pending Timer，两文件静态分析无问题：[4项回归原始日志](E:/picakeep-image-pipeline-022-work/cover-service-timer-cleanup-1006.log)。生产封面代码未因该fixture修复而改变；最终统一设备包上的封面cold性能和真实旋转观感仍待验，不能用这4项通过替代。

上文Android长图9项差异及“后续重跑”的描述同样属于旧报告状态。新helper在1:1独立参考中使用不重采样绘制，保持实际整数截图尺寸和同源原区域、没有颜色容差；最新Android profile已完成22输入×中心/右下/缓存复读66项，全部逐通道相同，`differentPixels=0`、seam差异0、尺寸错误0、源文件前后不变66项，退出时resident/job/lease/工作与磁盘待写计费均归零。详见[最新66项原始报告](reader-final-quality-redmi-66.json)和[真实画布质量记录](surface-quality-results.md)。它证明本次所测原像素区域与缓存往返，不替代全格式三布局/ICC-HDR/正常产品全流程或最终封面性能验收；旧失败报告和差图保留。

## 2026-10-06 PNG冷路径诊断与显式编码候选

直接从现有N30逐次数据提取P95，得到下表；各列P95不相加冒充同一最慢样本。ZIP正文已在矩阵计时前流式物化，下面的cold不含ZIP解包时间。

| 旧冻结素材/平台 | 实际首raster ms | providerReady ms | Flutter getNextFrame ms | providerReady后至raster ms |
| --- | ---: | ---: | ---: | ---: |
| 合成4096² PNG Redmi | 271.223 | 254.236 | 245.365 | 25.816 |
| 合成4096² PNG Windows | 98.440 | 94.352 | 92.516 | 5.379 |
| 真实ZIP PNG768 Redmi | 197.905 | 173.654 | 160.695 | 29.656 |
| 真实ZIP PNG768 Windows | 82.146 | 77.989 | 74.058 | 5.705 |

真实ZIP两端nativeProbe的P95仅1.841/0.465ms、queueWait仅0.115/0.012ms；缩小codec是主要关键路径。schema5 ZIP两端cold30/30均在首rasterFinish前记录`persistSubmitted`，Redmi提前量P95为17.092ms、Windows0.352ms。不过这只是提交事件，完成stage快照并未包含这些样本的`persistEncode`/`persistWrite`结束时间，因此不能把全部提前量归因为编码成本。schema3缺绝对起止，不能用其42.637ms persistEncode反推首raster重叠。合成PNG手机codec本身245.365ms已经超过同轮baseline252.346ms的20%目标201.877ms，即使完全消除stat/probe/提交竞争也不足以据此保证目标。保留原cold原provider并后台准备派生只可作为不退步/提高后续命中的候选，不能将原provider的baseline时间算20%改善，更不能把预生成命中重新命名为cold。

本次小范围实现一个默认关闭的同质量候选：`CoverThumbnailCache.prepareProvider(..., nativeEncodedFit: true)`，独立profile入口使用`--native-encoded-fit=true`（Android独立options JSON同名字段）。仅静态、8-bit、无ICC、orientation1、非交错PNG、完整源区域且双轴缩小可用；显式实验将符合条件的PNG交给现有native区域解码器、既有`encodePixels(PNG, lossless:true)`，再将小PNG交给Flutter encoded codec，避免raw ImageDescriptor构建。默认64MiB选择、reader原像素、native ABI/core、原文件和其它格式路线保持现状。候选独立缓存后缀`thumb-v3-area-fit-native-encoded-png-v1`，不复用或覆盖默认Flutter缩略结果，provider重新解析时仍保留候选选择。

输出RGBA记为O（最多16MiB），encoded上限L=`min(32MiB,max(64KiB,2O))`；encoder预算=`min(128MiB,2O+2L+8MiB)`，共享job预留native estimate加encoder预算、6O、3L和32MiB余量，继续服从总1GiB。解码沿用实际NativeDiskWork准入；input/backing保护、generation与source stat核验保持，取消贯穿native decode/encode并在实际返回后释放。取消后创建的ui.Image也明确dispose，native pixel与encoded buffer在finally释放。此路线仍有RGBA/TTD/FFI复制与额外PNG encode/decode，不能称零复制或预期必快；旧native32 Android465.102ms和Windows仅约11%的native热循环收益都不足以证明它胜出。

真实独立native DLL下候选7项通过：opaque/alpha的encoded→Flutter实际premult RGBA逐字节等同独立native thumbnail；diskwarm相同；候选/default缓存隔离；编码后取消/实际ui.Image建立后取消（handle确已dispose）；取消一个共享消费者另一消费者继续；native编码期间源替换拒绝旧结果；JPEG保持默认后端。连同fallback、两轴目标和既有thumbnail共24/24、0 skipped；三文件静态分析无问题：[最终候选回归日志](E:/picakeep-image-pipeline-022-work/cover-native-encoded-fit-final-regression.log)。首次fixture因App路径未初始化加载失败记录保留，未计入通过项。

下一A/B必须来自同一冻结源，两端分别交替默认与显式候选，保留合成4096² PNG384和真实ZIP PNG768物理卡片每组三模式N30，同源SHA、实际image尺寸、原图只读、engine raster时点不变。新增绝对stage分开`nativePngDecode/nativePngEncode/nativePngBuffer/nativePngDescriptor/nativePngCodec/nativePngFirstFrame`，同时记录native worker/codec、encoder峰值和工作预留；实际画布与独立同native thumbnail无损参考继续精确比较，原文件全幅缩小仅用于封面观感。OS内存/取消/退出归零与正常快路径无明显回退一并检查。只有最终实际收益与质量通过才讨论默认；本节没有运行设备或构建，也没有改变20%原验收标准。

## 2026-10-06 13:36 新配额正常headless入口

Evidence：专用冻结快照正常 `lib/main.dart` 的 Windows profile 构建，实参 `--server --verification-data-root=E:/picakeep-image-pipeline-022-work/server-022-quota-profile`，任务端口46538，进程56560。原始报告 [server-production-headless-quota-profile.json](server-production-headless-quota-profile.json)，外部Python实际HTTP13项全部通过；服务启动/构建日志保留E工作目录。此快照已包含最终writer精确长度、progressive准入及cover index保护，不含随后export暂存与默认关闭候选修改。

Finding：真实下载JPEG完整原字节、封面384×542及304、真实ZIP生产成员提取、三处1:1瓦片每像素等同独立原PNG、8并发消费者同响应、旧版本409 JSON、任务文件替换失效、加密归档拒绝后解锁原字节均成功；任务数据根隔离与鉴权通过。没有打开用户数据根、GUI或主力机。请求完成后只停止已核实任务进程。

Path及产物：`normal-server-quota-profile-windows-build-retry.log` 成功；exe SHA `A61B0E1C4B987EDC675E93AAE0762EAB06D063E9F5D8B763FAFD795E8E06E1F6`，实际Dart AOT `data/app.so` SHA `B2C538E7ACFD75CED702A2E35F08DD9B06C66468BDC4B2C11061C130844D84C2`，native DLL SHA `8DDB4AD445E67E0B2C6BCCD67656E955FAC4E4768129A87C4AB2C7C4F8617F5C`。exe自身是runner，不能仅以其相同hash推断Dart应用代码相同。首次build缺app.so失败保留，同快照顺序重试成功；无需改源码、release或清用户数据。

这补足最终writer/quota版本正常headless入口的独立证据；GUI真实按钮、App远端页面、断连后原生强取消、202任务启动次数仍由各自集成/正常UI证据验证，13HTTP不替代这些项目，也不代表封面20%性能达标。

## 2026-10-06 native encoded PNG 双端最终 N30

本轮对两端相同输入分别执行默认与显式 `native-encoded-png` 候选，每份报告各有同轮原图 baseline、冷封面和暖命中各30样本。4096 PNG 的源 SHA 为 `11db732775cdb2497f108e0502ee4993e38b1e781231de81a7fca88e01361630`；真实 ZIP 的归档 SHA 为 `0d65012191602d018fcb14b5fb909c7da74691365b468d90e3c89e92377ccd35`，成员1解出 PNG SHA 为 `8811fe1a50a009f754b59cc169e73f3a506564baba77b6415ae127856f753ffe`。ZIP 冷封面 768×1183 落在768×768卡片内，无放大。下表为实际匹配引擎 raster 的 P95 毫秒：

| 设备 / 输入 | 模式 | 原图 baseline | 冷封面 | 暖命中 |
| --- | --- | ---: | ---: | ---: |
| Windows / 4096 PNG → 384 | 默认 | 121.595 | 104.379 | 12.629 |
| Windows / 4096 PNG → 384 | native encoded | 117.344 | 129.735 | 9.515 |
| Android / 4096 PNG → 384 | 默认 | 217.266 | 232.979 | 69.426 |
| Android / 4096 PNG → 384 | native encoded | 245.943 | 338.911 | 56.681 |
| Windows / ZIP member1 PNG → 768 | 默认 | 101.481 | 80.736 | 17.065 |
| Windows / ZIP member1 PNG → 768 | native encoded | 104.290 | 225.293 | 17.939 |
| Android / ZIP member1 PNG → 768 | 默认 | 202.709 | 192.403 | 64.214 |
| Android / ZIP member1 PNG → 768 | native encoded | 196.351 | 475.305 | 58.568 |

编码候选四组都实测走了 `native-encoded-png`，30/30；它在两个设备、两种素材上都没有达到冷首显收益门槛，ZIP候选冷 P95 为同轮默认的2.79倍（Windows）及2.47倍（Android）。4096 PNG 候选也比默认分别慢24%与45%。默认阈值/缓存算法不变，`nativeEncodedFitCandidate` 继续默认关闭，不把暖命中更快用于支持冷路径。

原图对照画布逐像素差异只作记录，没有人为阈值；独立Flutter整图解码后再缩小与原生区域缩图采用不同重采样过程，因此该比较不能单独当作候选有损的证明。ZIP候选最大通道差到131（Windows）/159（Android），同时其实际冷速度明显回退；即使封面优先速度，也没有理由纳入默认。报告保留Android四份完整逐样本 JSON `cover-android-{4k,zip}-{default,candidate}1006.json` 与Windows四份 `cover-{4k,zip}-*1006.json`，系统文件缓存状态未受控，设备内结果按同轮候选对照理解，不外推所有图片格式。
