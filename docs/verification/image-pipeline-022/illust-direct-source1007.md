# 2026-10-07 · 插画瀑布流封面直接读取源件

用户确认仍慢的是插画瀑布流。本轮移除普通可读源件首显前的完整缓存复制，并让归档封面在读取成员前查已验证的统一缓存。128项定向测试通过，正常 profile 已保留数据安装到主力机，备用 Android 匿名样本证实直接源读取与六张封面重进内存复用；尚无本轮与旧包同条件的主力机封面量测，022 仍执行中。

普通 Android 全部文件权限是当前主力机实际路径。备用机原有插画数据为零，后续使用仅属本任务的匿名文件在应用私有目录取样；该 Android 10 目录访问不代表主力机全部文件权限下的外部路径，也不作跨设备速度比较。主力机前台第三方阅读器在正常包安装前后保持同一个 ActivityRecord，未为采样切换页面。

**实现及调用路径**

`prepareIllustCover → _resolveIllustCoverSource → CoverThumbnailCache.prepareProvider` 继续使用已有输出尺寸限制、共享解码队列、内存预算、源 stat 与发布取消检查。已登记且指纹有效的原件缓存优先复用，保留对应缩略图与内存缓存。

普通权限下，单图、命名封面或扫描解析出的绝对文件路径通过 `stat → open → read(32) → close → stat` 验证可读性与版本；有效后直接交给已有有界文件 buffer 解码。32 字节探测只验证入口可读，后续 codec 仍需读取压缩图像并可能失败。源件在探测中变更或页面取消时停止当前发布；无法直接读取、非普通文件路径或启用 Root/Shizuku 的路径继续走已有内部暂存链。

ZIP 解出的封面本来就位于统一 `covers` 根，本轮直接复用该文件，省去再次读出整份字节、写到另一个 managed cover 键并保存来源索引的工作。`ArchiveReadingService.extractCoverToCache` 同时把缓存查询移到成员读取之前：校验归档可打开、索引及成员有效、当前 size/mtime/changed 一致后，未加密包可直接复用封面。加密包仍读取成员以验证当前密码；源不可访问、索引不确定、缓存丢失或源版本变化继续按原合同恢复，不能用旧缓存绕过密码或访问检查。暖命中仍有 stat、打开和索引验证，不等于零归档 IO。

代码依据：[插画源解析](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/foundation/local_library.dart:1317)、[有界可读探测](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/foundation/local_library.dart:1425)、[归档缓存早查](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/foundation/archive/archive_reading_service.dart:267)。

直接源路径会回写 `item._localCoverPath`，作为当前页面和详情尺寸解析的 hint。本轮这条直接路径不会写入 managed source-cache 索引；公共 `resolveCoverPathForItem` 仍负责已登记的内部 managed cover。通用 `LocalLibraryComicItem.toJson()` 仍可包含 `localCoverPath`，所以“hint 不持久化”的边界仅指本轮 managed source-cache 写入，不能扩大为所有序列化或持久化场景。参考 [toJson](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/foundation/local_library.dart:423) 与 [来源索引写入](D:/Flutter_Projucts/PicaComic/PicaKeep/lib/foundation/local_library.dart:1146)。

**旧首轮 trace：证据 → 判断 → 修复路径**

下面是上一轮 `illust-scroll-fixed-first1007` 的已完成异步阶段，单位 ms。四条按唯一 source.bytes 及后续 backend 时间窗口排列，图像分别为 PNG 3007×4629、JPEG 5299×3240、JPEG 2591×3624、JPEG 5072×8848；事件没有共享源 ID/SHA，不能用它做跨版本同原图配对，也不是 first paint 测量。

| 源字节数 | source.total | source.resolve | source.read | source.store | source.persist | Flutter getNextFrame |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 4,916,814 | 175.871 | 100.567 | 7.707 | 39.540 | 3.623 | 164.658 |
| 9,900,972 | 262.369 | 0.074 | 74.226 | 116.789 | 17.557 | 239.753 |
| 5,657,064 | 168.178 | 0.090 | 48.977 | 84.609 | 6.973 | 135.873 |
| 18,377,140 | 426.083 | 246.044 | 30.756 | 118.092 | 5.973 | 543.137 |

`source.store` 包含 quota admission、字节写入及 flush、rename、统一 JSON 索引保存；此 trace 没有细分这些子阶段，不能断言全部耗时来自磁盘写或 JSON。它在 prepareProvider 前被 await，因此普通文件直接读取能移除这段首显前的工作；具体主力机收益仍需后续同条件测量。

两条 ZIP 的 `archive.extract` 分别为95.262/240.579ms，已包含归档成员读取及第一次写入统一缓存，不能全称为解压时间。旧链路之后又做第二次 `source.read + source.store + source.persist`，分别额外等待 **50.870/154.821ms**。复用已物化文件明确移除了这段重复调用；归档首次成员读取及首次缓存写入仍存在。

四次 Flutter buffer 为8.018–14.923ms，descriptor 为61–141μs，instantiateCodec 为7–12μs；真正取得首个解码帧仍耗135.873–543.137ms。源码调用直接体现等待在 `getNextFrame`，这段 wall scope 可以包含后台等待，不能当作隔离的 CPU 耗时。移除源件复制不保证消除这段 codec 延迟，也不能宣称“秒开”。

源件缓存保留原始 JPEG/PNG 压缩字节和扩展名；仅缩略派生缓存固定为 PNG。旧 trace 的四次新图 codec 最晚在相对时间3.681s完成，后台 `persistEncode` 到4.089s才开始。四段完整 PNG 编码320.582–392.870ms，合计1.465s，第五段在录制结束时仍未完成；后台编码确实较长，但没有与这四次新图 codec 交叠，不能据此归因首轮出图慢。可见工作结束后连续空闲400ms再编码的机制在此窗口生效。

最大队列等待1.816192s的入队发生在 capture 之前，对应此前 nativeRaster 的起点也被截断；它不能归因于某张当前图或 PNG 编码。本次 PNG 的119.786ms队列等待与上一 nativeRaster 完成对齐，其余三张新图的队列等待14/21/18μs。嵌套阶段不可相加，事件时间交叠也不能证明因果。

| 证据 | 内容与 SHA256 |
| --- | --- |
| [E-001 原始 VM trace](D:/picakeep-image-pipeline-022-work/illust-scroll-fixed-first1007.json) | `E352BF8E0275F977474D25EE4691A63D08E281AE8D8A75C9CED9C1DA6FA77284` |
| [E-002 阶段汇总](D:/picakeep-image-pipeline-022-work/illust-scroll-fixed-first1007.summary.json) | `DA2ED023086914F1100E29BC4CD6C95CA092F3D2B71625685652FD209219E3D2` |
| [E-003 上一轮帧与阶段对照](D:/picakeep-image-pipeline-022-work/illust-scroll-comparison1007.json) | `4EC6014C01554779B017CCE2818ADA73C5068D8077EDB1C603E2706962599A24` |

本机离线复核命令读取原 trace，禁止覆盖已有证据文件：

```powershell
& 'D:/Anaconda3/python.exe' 'D:/picakeep-image-pipeline-022-work/capture-illust-vm-timeline1007.py' analyze --input 'D:/picakeep-image-pipeline-022-work/illust-scroll-fixed-first1007.json' --summary 'D:/picakeep-image-pipeline-022-work/illust-direct-source-baseline-review1007.json'
```

运行需要保留上述外部工作目录；阶段配对按异步 ID 与嵌套进行，capture 边界未闭合阶段不计完整时长。F-001（E-001/E-002）：首显前 source copying 是已观察到的等待；P-001：普通可读源直接进入有界 decoder，ZIP 已物化封面进入同一 decoder。F-002（E-001/E-002）：PNG 持久化位于该批新图 codec 之后，当前数据不足以把它判为首次出图延迟来源。

**定向验证与当前构建状态**

本轮不同测试共 **128项通过**：11个封面回归文件98项（含直接源11项），加此前同核心运行中独立通过的归档缓存6项、原件 streaming10项、Pixiv目录集成14项；重复运行的直接源测试不重复计数。覆盖真实 JPG/PNG 绘制、零 Dart readAsBytes 整件暂存、原件不改写、已有缓存优先、回滚内存命中、强制读取失败及权限模式暂存回退、取消、源替换、预算拒绝不重新暂存、真实 ZIP 暖命中不再次读成员、跨归档/成员隔离及坏缓存恢复。主机测试的权限分支不替代 Android Root/Shizuku 真机验收。

早期 archive 运行遇到未冻结 helper 的 nullable三元返回推断为Object，导致该测试文件未编译；改为显式 if/return 后核心运行的归档6项全通过。核心组早期另有4个新测试 fixture 缺少 path_provider，补齐 fixture 后直接源11项在98项回归中全通过。旧失败日志保留，不写成整组通过。

- [最终封面回归98项](D:/picakeep-image-pipeline-022-work/illust-direct-source-cover-tests1007.log)、[核心运行及4项fixture失败记录](D:/picakeep-image-pipeline-022-work/illust-direct-source-core-tests1007.log)、[早期编译失败记录](D:/picakeep-image-pipeline-022-work/illust-direct-source-archive-tests1007.log)。
- [5文件静态分析](D:/picakeep-image-pipeline-022-work/illust-direct-source-analyze1007.log)：No issues found。

本轮诊断 `lib/main.dart` profile 已独立核验并复制，只有 `PIKAKEEP_COVER_DIAGNOSTICS=true` 一个用户define，Dart AOT仅arm64。870项当前产品/快照 SHA 与451项实际 Flutter编译输入hash均一致，既有包名、1.9.92/code9及签名匹配；ZIP CRC通过、最大gap0，三个native ABI库与上一基线相同。诊断事件仅表示准备阶段，不能作为可见首帧证明。

[诊断身份记录](D:/picakeep-image-pipeline-022-work/illust-direct-source-timing-profile-identity1007.json)记录61,906,601 bytes及APK SHA256 `AAA5C9B59DBE4E5BB334871DA9DA0A8AA4AA09890F5E610875D18EA35B078A34`；[源输入清单](D:/picakeep-image-pipeline-022-work/illust-direct-source-fixed-inputs1007.json)和[独立核验脚本](D:/picakeep-image-pipeline-022-work/verify-illust-direct-source-timing-profile1007.py)保留。

**备用 Android 匿名样本**

仅本任务创建的6个匿名作品为640×960 PNG、1024×1536 JPEG、1200×1800 PNG、4000×6000 baseline JPEG、1600×8000 baseline JPEG，以及一个封面1600×2400 JPEG的两页未加密ZIP。经本地完整解码、DB检查及 [手机传输SHA记录](D:/picakeep-image-pipeline-022-work/illust-direct-source-spare-fixture-transfer1007.json)核对，6个源文件长度与SHA全部一致。有效采样从修复传输并核对文件之后开始。

备用机Android 10在普通访问模式下不能列出最初尝试的外部样本目录，故转为task-only的 `files/picakeep-022-illust-direct1007`，通过 `files/illustfixture` 链接和正常设置UI选择该样本。测试编排以ADB `run-as` 搬运到本应用目录，没有启用Root/Shizuku或新增权限；因此本轮只验证该普通可读私有源路径的应用行为。

早期 `spare-first` / `spare-bottom` trace及其首轮截图含错误素材：最初通过tar/exec-in传输的大JPEG被截断，且部分文件缺失。该素材的2010624 bytes不等于期望2118477 bytes。后改为ADB push到临时目录再run-as复制，逐件核SHA，弃用此前first/bottom的速度与失败结论；它们只保留为传输失败过程记录，不作为有效基线。

| 有效窗口 | source.direct | provider.ready | memoryHit | 新thumbnail backend / probe / codec | source.read / store / persist |
| --- | ---: | ---: | ---: | --- | --- |
| SHA核对后首次进页 | 5 | 6 | 0 | 6 / 6 / 6 | 0 / 0 / 0 |
| 返回再进同页 | 5 | 6 | 6 | 0 / 0 / 0 | 0 / 0 / 0 |

首次五个普通文件的source.total为1.640、2.180、4.144、6.722、90.506ms。其中90.130ms在可读探测阶段，是不能忽略的wall scope长尾。ZIP的source.total580.910ms含archive.index10.963ms、首次archive.extract568.911ms，首次归档物化仍慢。六次Flutter getNextFrame为13.846–292.462ms；4000×6000 JPEG实际走ordinaryJpegScaledFit，输出768×1152，长图输出768×3840，最小PNG输出640×960，全部继续遵守已有输出与预算限制。

六次完整PNG持久化编码52.138–428.277ms，首段开始在最后cold codec完成403.441ms之后，两者没有交叠。首次阶段计数中的source.store为0仅指插画复制链没有再执行；ZIP首次archive.extract内部仍写一份统一原件缓存，不能宣称整个窗口没有缓存写入。

返回重进六张均memoryHit，source.total1.353–6.063ms；nativeProbe/nativeRaster、Flutter buffer/descriptor/codec/getNextFrame、磁盘暖buffer/codec/getNextFrame、PNG persistEncode/persistWrite均0次。archive.extract仍有一次1.320ms，archive.index0.287ms：事件名称覆盖整个 `extractCoverToCache` 方法，含有效缓存早返回，不能把这1.320ms标成解压时间。真实ZIP测试证明暖命中跳过成员读取；此trace没有独立readEntry事件，因此“跳过成员读取”以代码早查合同和测试支持，不能仅从阶段时长或事件缺失推断零归档IO。

两份原始trace独立配对均无IllustCover未闭合/错误配对。六张封面在 [有效首次截图](D:/picakeep-image-pipeline-022-work/illust-direct-source-spare-ui1007/timing-fixture-verified.png)可见，返回重进 [截图](D:/picakeep-image-pipeline-022-work/illust-direct-source-spare-ui1007/timing-fixture-reentry.png)保留。这是阶段机制与绘制存在性验证，未测同原图旧包前后、未测主力外部存储延迟、未得到首次屏幕呈现时间，不能据此宣称主力秒开或全部滚动体验达标。

- [有效首次trace](D:/picakeep-image-pipeline-022-work/illust-direct-source-spare-verified1007.json)、[首次阶段](D:/picakeep-image-pipeline-022-work/illust-direct-source-spare-verified1007.summary.json)。
- [返回重进trace](D:/picakeep-image-pipeline-022-work/illust-direct-source-spare-reentry1007.json)、[重进阶段](D:/picakeep-image-pipeline-022-work/illust-direct-source-spare-reentry1007.summary.json)。
- [独立阶段核对及原件/trace证据SHA](D:/picakeep-image-pipeline-022-work/illust-direct-source-spare-stage-evidence1007.json)、[离线核对脚本](D:/picakeep-image-pipeline-022-work/analyze-illust-direct-source-spare1007.py)。脚本输出拒绝覆盖已有证据，保留全部stage样本和probe长尾。

**正常包与主力机安装**

clean、offline pub get后正常 `lib/main.dart` profile arm64构建110.5秒成功，无用户Dart define/诊断target。独立核验870项产品源/快照/本轮诊断manifest SHA完全一致，451项实际编译器hash一致，1.9.92/code9及既有签名匹配、ZIP CRC通过且最大gap0、三个native ABI库一致，Dart AOT更新且IllustCover事件前缀不存在。

- [正常APK](D:/picakeep-image-pipeline-022-work/picakeep-illust-direct-source-profile1007.apk)：61,841,065 bytes，SHA256 `5AC40AE133DBE24CE2D1AB8C242A37614DBBCD8FF23D61C0B376F47339CC7B54`；[身份记录](D:/picakeep-image-pipeline-022-work/illust-direct-source-profile-identity1007.json)。
- 主力显式设备192.168.5.4:5555/serial f294cd23，在核APK存在和SHA后install-r成功。firstInstallTime仍为2026-10-01 23:32:23，lastUpdateTime16:22:55，无卸载/清数据。[安装记录](D:/picakeep-image-pipeline-022-work/illust-direct-source-normal-f294cd23-install1007.json)。
- 安装前后 `com.dragon.read/.reader.ui.ReaderActivity` 保持同一ActivityRecord，未启动或force-stop PicaKeep；这次主力安装没有提供PicaKeep视觉或性能验收。[前台记录](D:/picakeep-image-pipeline-022-work/illust-direct-source-main-foreground1007.json)。

备用显式设备192.168.5.3:5555/serial 8021129d也已恢复同SHA的正常no-define profile：install-r成功，firstInstallTime仍为2026-06-29 16:42:23，lastUpdateTime16:45:44，进程7561正常启动。[安装记录](D:/picakeep-image-pipeline-022-work/illust-direct-source-normal-8021129d-install1007.json)。[最终主页](D:/picakeep-image-pipeline-022-work/illust-direct-source-spare-ui1007/normal-final-home.png)可见历史11条、原有下载3部；[最终插画页](D:/picakeep-image-pipeline-022-work/illust-direct-source-spare-ui1007/normal-final-empty-illust.png)恢复原先为空的状态。该视觉检查不作为新冷封面性能样本。

主任务通过正常设置UI恢复默认Pixiv路径，迁移已下载数据选项未勾选；按文件名单及hash验证逐文件移除本任务的私有、外部Download和临时三个样本目录，再移除别名链接，保留本地证据与fixture DB备份，没有直接编辑用户下载DB、清应用数据或改变权限。[清理记录](D:/picakeep-image-pipeline-022-work/illust-direct-source-spare-fixture-cleanup1007.json)。本轮38123 VM转发已移除，主力原有6521转发保留。未运行release或提交/推送；两机均保留正常profile。本文未更新CHECKPOINT或交接文档，不将备用样本当作主力同条件量测。
