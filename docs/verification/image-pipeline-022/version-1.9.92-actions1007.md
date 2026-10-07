# 1.9.92+9 / 022 本次版本行动总记录

回写时间：2026-10-07 20:43（Asia/Singapore）。范围：2026-10-05进入022执行至2026-10-07最后一次正常Profile交付，以及本次文档收束。用户要求“暂时告一段落，回写本次版本的全部行动”；后续实施、构建和设备验收暂停，等待用户明确继续。

**状态：部分完成，阶段收束；022原P0--P10尚未整体验收。** 本文汇总已实施行为、调查、候选取舍、测试、产物和剩余事项；各轮原始结果、失败和输入身份保留在所链接报告中。同一版本号有多份APK，以入口、SHA和安装时间区分，不能仅凭1.9.92判断代码一致。

## 当前交付

最新包是正常 `lib/main.dart`、无诊断Dart defines的Android Profile，版本 `1.9.92+9`，不是性能runner。

| 项目 | 最后已完成的事实 |
| --- | --- |
| APK | [picakeep-large-open-first-normal-profile1007.apk](D:/picakeep-image-pipeline-022-work/picakeep-large-open-first-normal-profile1007.apk)，61,906,601 bytes |
| SHA-256 | `C1BB13A72E01937BAB239AFA31722A0D79687EA44D7AF927CFF90793BAA1F895`；本次收束只读核对仍一致 |
| 应用/签名 | `lingxue.picakeep`，versionCode9 / versionName1.9.92；签名SHA `31b4434516ccc1f58add7cc5cd4b6786e995c957d5891d3685e4c75a7a58d7c7` |
| 构建 | clean、offline pub get后Profile构建108.9秒；872项产品源/快照SHA、451项实际compiler输入hash一致；三ABI native库与最终harness及上一自适应正常包逐字节一致；版本、签名、ZIP CRC通过 |
| 主力机 | `192.168.5.12:5555` / `f294cd23`，19:59:17显式 `install -r --no-start` 成功；首次安装时间2026-10-01 23:32:23不变；前后同一QQ SplashActivity实例，未切换当前界面 |
| 备用机 | `192.168.5.3:5555` / `8021129d`，20:00:25显式 `install -r` 成功；首次安装时间2026-06-29 16:42:23不变；正常MainActivity PID22690和客户端设置界面可见，启动error/fatal过滤为空 |
| 安装证据 | [产物身份](D:/picakeep-image-pipeline-022-work/large-open-1007/first-normal-identity1007.json)、[主力安装](D:/picakeep-image-pipeline-022-work/large-open-1007/first-normal-f294cd23-install1007.json)、[备用安装](D:/picakeep-image-pipeline-022-work/large-open-1007/first-normal-8021129d-install1007.json) |

最后两台手机均保留上述正常包。前一份 `1DDA9985…` 是18:57阶段产物，已被本包替代。主力机旧地址 `.4`、较早“未操作主力机”和旧诊断入口只描述各自历史轮次；不能作为当前设备状态。最新备用截图是客户端设置界面，不能写成最新主页历史/下载数量验收。

## 022基础实现与验证行动

| 范围 | 实际完成内容 | 证据与覆盖边界 |
| --- | --- | --- |
| 原资源身份与原图操作 | 原文件、显示派生、质量/几何身份分离；工作/章节/页绑定，选页和异步操作持有原件lease；保存/分享/收藏使用目标原文件，显示缩略图不回写成原图；接入清晰优先/预览优先及设置迁移 | [真实来源工作流](source-real-download-results.md)、[全量回归](final-after-candidates-regression.md)。本地/HTTP JPEG与ZIP三布局×两模式12工作流和输出SHA已验；替身系统对话框不计真实UI通过 |
| 原生后端 | Android/Windows原生插件、probe/estimate/区域解码、方向/alpha处理、原像素backing及受控读取；premultiplied RGBA经Flutter ImageDescriptor显示；固定最多2个持久worker、队列128，取消/失败分类和drain | [原生结果](native-results.md)、[prepared候选](native-prepared-read-candidate.md)。静态sRGB8测试不证明所有HDR/广色域/16-bit面板能力 |
| 调度与所有权 | Native/Flutter/network工作有界；预算ticket、源lease、取消、迟到结果与pending/resident分账；修同进程服务端/客户端共用执行预算的依赖死锁，网络lane保留独立上限 | [来源链](source-real-download-results.md)、[磁盘配额](disk-quota-results.md)。内部归零与真实OS/GPU驻留分别计量 |
| 派生缓存与空间 | 普通缩放层/tiles统一purpose与源版本；原子发布、临时/active/publish/idle状态和配额准入；原文件保护及旧缓存域协同；native磁盘空间查询，Windows junction归实际卷、Android共享物理空间保守扣减 | [存储布局](storage-layout.md)、[空间接口](native-disk-space-interface.md)、[配额结果](disk-quota-results.md)。正常后台入库/清缓存/低空间交错仍需产品压力验收 |
| 来源与服务 | 普通文件、下载/归档原件受控流式物化、限额/取消/源复核；自建服务提供变体、manifest、tiles与原文件，含鉴权、304/202/409、断连与版本恢复 | [封面/服务](cover-server-results.md)、[真实下载](source-real-download-results.md)。正常Profile `--server` 13个HTTP场景和实际Remote ReadingData链已验；正常远程App UI、新旧能力组合未全部关闭 |
| 画布、原像素与动画 | 稳定原图坐标/密度升级、三阅读布局、原像素定位；避免preview与透明tile重复srcOver；sourceRect显示覆盖与rasterRect采样gutter分离；整数原尺寸裁片走整数平移none，缩放/分数坐标保留medium；递增像素缓存版本拒绝旧错误裁片 | [画布质量](surface-quality-results.md)、[色彩/动画](color-animation-profile-results.md)。双端66区域/缓存及代表Reader矩阵有exact证据；Android独立冷codec裁片控制仍失败，Float32路线有能力不支持项，不能宣布整体精度通过 |
| 正常UI与原生系统操作 | 隔离正常App任务、真实原像素操作；备用Android实际保存JPEG到MediaStore2229、打开MIUI分享后取消、收藏1项并重启仍存在；源/保存桥返回URI/收藏副本字节审计；手机真正全屏按钮已有Windows条件，四角箭头是原始像素按钮 | [正常UI设施](normal-ui-isolated-entry.md)、[当前接续](CHECKPOINT.md)、[Android字节审计](normal-ui-android-v10-byte-audit1006.json)。仅单页sharpFirst JPEG；分享未选接收者，不能宣称送达；其他选页/布局/权限恢复未完整UAT |
| 生命周期、OS与构建恢复 | 多轮内部资源/租约/配额退出归零，增加同PID OS RSS/PSS旁路；处理AOT缺失、构建长路径/磁盘临时目录和产物校验；Windows测试短路径与rename重试问题分别留证 | [OS采样](os-rss-sampling.md)、[默认生命周期](reader-final-default-lifecycle.md)、[Android构建恢复](android-aot-build-recovery1006.md)、[v9回归记录](final-v9-regression1006.md)。稳定warm基线、十轮增长门槛与真实系统内存压力仍未关闭 |
| 极小预算失败诊断 | 三次CRT abort定位到本任务MSVC Debug STL noexcept iterator分配；普通/prepared入口增加32MiB元数据早拒，仅本DLL Debug target调整iterator配置；不是安装或修改系统运行库 | [低预算故障及修复](native-prepared-read-candidate.md)。原始失败保留，明确code3拒绝不能吞成无界写路径回退 |

2026-10-06早期冻结版本曾完成 **2881 passed / 15 skipped / 0 failed** 的整个 `test` 目录与全范围analyze。其后v9全量实际为 **2877 passed / 34 skipped / 4 failed**，章节续传、迁移计数、Windows codec长路径和rename失败各自保留。后续 **34通过/1能力skip仅为native/真实来源fixture补测**，不包含这四项失败场景；codec短路径另有3项通过，Windows有限rename处理有实现/测试源码，章节/迁移断言只是增加底层失败reason，不能称四项全部已修复验证。没有新全量绿色。两次全量都早于10月7日续修，不能当作最新APK全量通过。平台/能力skip、失败及定向结果各自保留，未降低像素阈值或删除失败。

### 拟提交前的行为与证据订正

- **Pixiv正式阅读来源**：当前 `PixivReadingData.originalQuality` 默认true，正式页面优先original；`parsePixivPages`不再以regular填充缺失的original。缺original只能标记 `bestAvailable/isOriginal=false`，不得借原始尺寸宣称原图。旧交接“在线仍regular/没有true调用”属于历史口径，当前行为已订正。保存/下载原文件权威与显示预览分开，不自动重下旧已下载作品。
- **Windows重命名**：`retryWindowsRename`接入下载迁移及Pixiv根迁移，仅Windows errno5/32/33额外等待25/75/200/500ms重试；持续拒绝及其他错误仍throw，不复制、不删除目标、不伪报成功。新增真实不共享删除句柄fixture测试存在，但本次未找到这些场景可定位的执行通过日志，不能由源码存在声称四个历史失败已关闭。
- **推荐瀑布流测试**：仅修跨页面已记忆ranking的请求次数断言、FakeAsync设置IO隔离及manager释放，未新增探索业务；24项执行记录见 [封面/服务结果](cover-server-results.md)。`--verification-data-root`为本次正常服务的隔离诊断入口，非普通用户设置；来源见 [真实来源](source-real-download-results.md)。
- **提交与实际安装分开**：本次基点已是V1.9.92；用户随后独立批准V1.9.93，项目 `pubspec.yaml` 同步1.9.93+10，阶段说明/身份摘要按批准清单放行。本报告的已验证/已安装APK仍为1.9.92+9，版本元数据调整不产生新的已验APK；提交整理没有构建/设备操作，不推送，也不改写既有提交。

## 10月7日按反馈继续实施

下表是本版本的实际续修顺序，前后动作均已发生。每行测试数只属于该轮，重复覆盖不累计为本版本独立总用例数。

| 轮次 | 行动、发现与处理 | 验证及交付 |
| --- | --- | --- |
| 正常主程序交付 | 按用户要求从正常main构建Profile，核源码输入、AOT、签名与设备身份后覆盖主力安装 | 初始正常包 `AEABEE52…`，保留数据并启动；仅构建/安装/启动smoke，不等于全部阅读通过，见[CHECKPOINT历史交付](CHECKPOINT.md) |
| 侧会话果核调查接收 | 334项证据逐SHA核对0差异；对照参考程序静态机制和隔离DLL样本，形成恢复/分流/显示连续性/缓存判断 | [调查对照](guohe-investigation-handoff1007.md)。不是参考程序完整GUI或PicaKeep真机速度验证，不盲搬6000px阈值 |
| 阅读与漫画封面恢复 | typed队列暂满最多补试2次，取消不落终态坏页；源重选拒绝迟到、修普通同文件peer lease自等待；漫画封面5秒一次有界补试，稳定provider防父重建绕过次数，路由隐藏/退出取消 | 142通过/1能力skip、native池/取消验证；正常包 `5CFBE69B…` 安装备用；用户那一本原始故障尚未确定根因，见[恢复报告](reader-cover-recovery1007.md) |
| 分块显示连续性和回滚 | 有界本地普通静态图默认整页原像素，巨图保留旧有效层直到清晰块替换；透明区不双叠；会话像素LRU64MiB/128项与active/pending共用192MiB，128项元数据缓存；延迟500ms显示转圈 | 141通过/1能力skip，普通File回滚无需重复解码且像素一致；正常包交付备用。归档/远程临时原件不自动获得同样跨widget复用，见[连续性报告](reader-display-continuity1007.md) |
| 主力已下载封面修复 | 缓存记录存在但持久文件已消失时重新解析源封面，修遗漏恢复分支；没有删除用户下载或清数据 | 161项回归；正常包覆盖主力，截图5本封面恢复且用户确认“已下载正常”，见[主力封面修复](main-cover-repair1007.md) |
| 插画新图等待和重进复用 | 源指纹/宽度档/代次稳定键，不随卡片占位几何改变；只用已完成内存图；可见队列优先于可选PNG写盘；增加1024宽档；阅读器退出保留列表封面缓存；单文件少做无效目录探测 | 124通过；主力同首屏重进9 memoryHit，新原图读取/probe/codec均0；正常 `AAB57CE1…` 交付。普通权限真实读文件仅十几ms，不能把秒级等待归因Root/Shizuku，见[冷暖报告](illust-cold-warm1007.md) |
| 插画滚动卡顿 | 去除每scroll重新构建全屏卡片的SliverLayoutBuilder；稳定测宽/复用child；暖PNG进入预算cover队列；普通大JPEG严格有界目标解码；可选PNG持久化等连续空闲400ms | 172通过；主力暖UI P95 7.154→4.491ms、BUILD scopes2282→281；raster P95未同步改善，初次仍有23.318ms布局长帧。正常 `D5250610…` 交付，见[滚动报告](illust-scroll-smoothness1007.md) |
| 插画原图复制开销 | 可读普通外部原图直接有界解码，免整图复制；有效内部缓存仍优先；ZIP已物化封面免二次复制，未加密包核源/成员后提前命中 | 128通过；备用6匿名作品5单图+1双页ZIP可见，重进6内存命中/新codec0；仍有ZIP提取约569ms/codec最高292ms。正常 `5AC40AE1…` 交付两机，见[直读报告](illust-direct-source1007.md) |
| 超RAM长列表回看 | 用户16:55采样显示192MiB淘汰与主isolate缓存排序；无空间压力跳过排序，有压力在worker预计算rank/排序，删除权限仍逐项复核；复用32MiB待写clone，超预算项放256条元数据空闲补盘队列；暖PNG保留前台槽和真实visible claim；修清队列竞态 | 106通过；备用96图768×1152封面总324MiB，端点往返覆盖，重进15内存命中；实驱逐回看33暖/0冷，完整下行/回看各40暖/0冷。每swipe停2.5秒及边界空闲，不证明首次冷列表立即反转；正常 `BF217B13…` 交付两机，见[长列表报告](illust-long-list-return1007.md) |
| 大图分块补齐 | 分析用户17:58 CPU/Timeline，缓存Painter immutable层键，JPEG header改64KiB有界块扫描；合格baseline JPEG奇数尺寸whole fit采用ceil(source/d) IDCT，避免先全尺寸backing；native/session像素版本递增；按格式和密度选512/1024 | 原生32项、新大源独立参考及既有22项方向/alpha/取消/源变验证；固定网格36样本、最终adaptive18样本全完整/FrameTiming匹配/资源归零。正常 `1DDA9985…` 两机交付，见[大图报告](large-image-open1007.md) |
| 瀑布流点入首幅 | 既有封面provider通过原阅读工厂传递；单张普通文件核work/page/URL/当前源stat及已证明的内部副本绑定，clone已完成图作为display-only；miss不resolve/不新解码；首次只放一个estimate/decode，真正首paint后放余块，保留初始预览/切模式旧图并拒绝迟到代次 | 147个不同定向用例通过，18样本配对及最新正常 `C1BB13A7…` 交付两机；其首幅与正式完整分开计时，见[首幅报告](large-image-first-raster1007.md) |

本次手机测试素材/任务配置按各轮证据恢复：源件前后SHA核对、profile-options原字节恢复、任务DB备份/integrity核验、默认Pixiv目录恢复；只移除已核验的任务namedfiles，未递归删用户目录。真实保存项2228/2229与原有用户数据保留。Root/Shizuku当前主力开关均0；全部文件权限路径的采样不能解释为实际特权桥成本。

## 已采用的默认与否决的候选

| 决策 | 依据与当前行为 |
| --- | --- |
| 清晰优先与原文件权威 | 预览可先显示，正式层依据原文件密度补齐；保存/分享/收藏仍取绑定原件。两模式的最终质量契约相同，不允许停留在被放大的缩略图 |
| 普通整页与巨图分流 | 10月7日有界本地普通整页策略已默认接入，仍受静态格式、ICC/方向/尺寸、encoded/decoded预算和纹理条件约束；超预算继续ROI。不能把旧64MiB opt-in研究阈值当当前普通默认16MiB准入 |
| 适屏1024、原像素512 | 8000×12000固定512/1024对照发现PNG和baseline fit可受益，但1024原像素ROI显著回退；生产仅PNG/已验证baseline的缩放使用1024，density1及progressive/未知JPEG/远端仍512，不全局扩大网格或预算 |
| 首幅复用封面 | 只clone已解码且核对当前源/绑定的prepared封面，独立计费及释放；不充当原件、desired complete或原像素session/disk缓存；多图/归档/不明绑定保守回退 |
| prepared-read/admission继续关闭 | 配对N30相对改善约24%--49%，但Android绝对P95仍约443--658ms级，超过100--200ms目标；另准入单场景中位未改善。只读已有backing不等于冷backing消失。组别以[配对诊断](prepared-read-performance-diagnosis.md)和[准入/ROI对照](prepared-admission-and-roi-diagnostics1006.md)为准 |
| 其他显式性能候选不全局开启 | raw-sync、viewport-region、early-original/native-large-fit、bounded-PNG-fit与native-encoded-cover等保留默认关闭/研究证据。早期native-large-fit开关和10月7日合格JPEG后端IDCT修订是不同层次的改动 |
| encoded封面/Texture/阈值 | native缩小后编码PNG候选四组冷P95回退，关闭；未引入Texture/零拷贝路线。32MiB封面阈值比较较差，保留64MiB策略；不混同32MiB持久clone预算 |
| 质量与历史失败保留 | opaque RGB3/row-skip出现alpha254偏差的方案否决；采用保持精确alpha的优化。Android16-bit采样/冷裁片失败各自记录，不用最大差1容差、改参照或缩截图掩盖 |

## 最后大图两轮的可量化结果

最终adaptive、8000×12000 PNG/baseline/progressive、每条件N3共18样本：fit中位1849.754 / 1610.136 / 11050.149ms，原像素ROI中位330.043 / 987.906 / 291.379ms；baseline第一次原像素升级4137.567ms仍慢。固定512/1024的36样本和这批最终默认样本分开归档，不能合并成同一N30或声称所有PNG稳定提速。

最后首幅实验同一最终harness包、single/sharpFirst、默认adaptive，两条件均在计时外先准备768封面，只切是否借用；各N3、共18样本。这里“首幅”不保证不借条件已有完整全图，可能只是一个正式块。

| 格式 | 不借→借封面首幅中位 ms | 不借→借完整清晰层中位 ms |
| --- | ---: | ---: |
| PNG | 1018.932→27.889 | 1633.977→1584.163 |
| baseline JPEG | 218.798→29.727 | 1652.210→1609.871 |
| progressive JPEG | 13391.407→43.013 | 14403.567→14606.756 |

九个借用样本首幅24.223--44.704ms；渐进JPEG正式完整仍13.550--15.449秒，**没有证明补齐改善**。18样本实际首幅/完整FrameTiming均匹配、errors0、surface/pending/jobs/working/temp/source lease/native active/queued/disk active退出全0。两idle worker是有界持久池，不冒称每次自动退出worker0。源SHA/config原字节恢复、cleanupErrors空。

这些是备用机匿名固定素材、小样本和已准备封面的实验，OS cache/温度未控制；不是旧包/新包完整对比、首次冷封面N30或主力用户三张原图验收。两张内容相同但路径不同的原件仍各自核源，不无条件合并身份。

## 回归与实现落点

最新147个不同用例来自135项reader/原件操作/会话/卡片/源封面回归、6项缓存桥接、6项新增Surface消费回归；最后首次准入文件12项单独重跑不再次累计。最终定向analyze无问题。最新代码没有重新跑整个项目的全量suite；10月6日2881/15/0和各续轮测试独立记录。

| 模块 | 本版本职责 |
| --- | --- |
| `lib/foundation/image_pipeline/` | 原件身份、lease、Native/Flutter/remote后端、调度/内存/磁盘预算、派生store、像素与元数据缓存 |
| `packages/picakeep_image_engine/` | Android/Windows插件、原生worker/磁盘接口、codec/region/backing、合格JPEG有界IDCT |
| `lib/foundation/cover_thumbnail_cache.dart`、`local_cover_cache.dart` | 源版本封面、稳定目标档、冷/暖解码、失效恢复、clone/空闲持久化、只读已完成封面桥 |
| `lib/foundation/cache_file_inventory.dart`、`local_library*.dart` | 空间压力排序/实际删除复核、本地源/成员/内部副本索引及阅读工厂绑定 |
| `lib/pages/local_library_illust_view.dart`、`local_library_illust_card.dart`、`illust_work_queue.dart` | 瀑布流测宽/稳定child、可见工作与滚动空闲、封面点击入读 |
| `lib/pages/reader/reader_page_image.dart`、`reader_image_surface.dart` | 源ready/恢复、普通整页/ROI、连续旧图与透明覆盖、第一幅准入及首幅/完整呈现分开 |
| `lib/pages/reader/reading_data.dart`、`comic_reading_page.dart`、`image_view.dart` | 不同来源契约、路由会话生命周期、单普通文件核源封面回调和原图操作 |
| `lib/server/server_app_images.dart`及既有server/network模块 | 本地服务原件/变体/tile协议、兼容和真实客户端读取 |
| `lib/tools/android_original_gallery.dart`、`save_image.dart`及Android MainActivity | 原字节导出、真实MediaStore桥、权限/空间与返回结果；不把显示预览导出 |
| `tools/image_pipeline_022_*`、`test/` | 快照/身份/像素/阶段/FrameTiming/OS证据、隔离正常UI、真实来源和有界失败回归 |

上表记录022实际职责，不宣称当前dirty worktree的每个修改都由本轮产生；没有回退其他用户修改、commit或push。

## 阶段收束与未完成项

1. **用户真实体验及冷速度**：已下载漫画封面由用户确认恢复；插画新图、无停顿冷长列表立即反转、主力真实三大图及首个原像素升级尚无最终同条件验收。progressive冷backing/补齐仍慢；最终封面20%、普通10%、ROI100--200ms及帧P95/P99/超帧比例门槛未全部关闭。
2. **显示精度/格式压力**：已测Reader sRGB8 exact不覆盖Android独立冷codec裁片失败、原16-bit/HDR面板保真、所有超长/动画/EXIF/alpha/纹理预算与平台矩阵。未经验证的系统能力保留fallback/明确未验。
3. **正常产品完整流程**：单页JPEG保存、取消分享、单收藏重进已有实际证据；其他布局/多页选页/异步切章/权限恢复、PNG保存和桌面系统dialog、远程正常App/GUI服务仍未全部验收。
4. **OS与真实压力**：内部资源归零已多轮验证；同PID稳定warm基线、十轮RSS/PSS增长判定及真正didHaveMemoryPressure/前后台恢复尚未收口，不拿Dart账代替OS/GPU。
5. **受限来源与缓存产品边界**：App UID的Root/Shizuku实桥授权/拒绝/恢复及大源复制待具备环境；本地普通File回滚不能外推归档/远程Deferred跨widget复用；正常扫描入库/后台派生/清缓存/低空间竞争需补验。
6. **最终版本全量与桌面**：最新代码仅定向绿色；重新开始后根据实际新增修改安排最终统一回归和原验收。桌面按用户要求暂缓；共享Flutter/native机制可能受益，Android测量不证明最新桌面体验。

本次回写只读检查本地产物和编辑文档，不新增构建、测试、手机/电脑UI或原图处理。此前仅debug/profile构建、显式设备/已核APK的覆盖安装；没有release、卸载、清应用数据或改用户原图。保留主力既有forward21173，当前没有本轮需等待的运行命令。

后续实施须以用户明确继续为前提，先核分支/工作区、最新正常APK和设备身份，再按这些未完成项接续；不按历史“下一步”段自动启动任务。计划原质量、性能与P0--P10出口保持原样。长期交接同步见完整版§210、经验版§188及[精简版](../../../交接文档-精简最新版.md)；阶段原始时间线见[CHECKPOINT](CHECKPOINT.md)，022计划的事实/经验已蒸馏到本文及长期交接，不依赖易失计划文件的路径。
