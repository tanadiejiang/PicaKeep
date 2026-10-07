# 022 当晚接续点

## 最新状态 · 2026-10-07 20:43 · 本版本阶段收束

用户要求“暂时告一段落，回写本次版本的全部行动”。本次只整理文档及只读核验本地APK，暂停后续实施、构建、测试与设备操作；022为**部分完成、阶段收束，未整体验收**，恢复需用户明确继续。下方各日期的“仍主动执行/下一步”均为历史状态，不能覆盖本节。

- 完整行动/证据/实验取舍/回归及剩余项见 [1.9.92+9版本总记录](version-1.9.92-actions1007.md)；已同步022计划双层回写、完整版§210、经验版§188及 [精简交接](../../../交接文档-精简最新版.md)。计划经验已在可入库文档留存，不依赖易失文件路径。
- 已覆盖原资源/原图操作、Native/Flutter区域后端、调度/磁盘配额/派生store、服务端和真实来源链、alpha/gutter/整数采样、动画与OS观察、正常UI单页JPEG保存/取消分享/收藏，以及10月7日阅读恢复、分块连续性/回滚、已下载封面恢复、插画冷暖/滚动/直读/长列表回看、大图adaptive和首幅借封面。
- 最新正常main/noDefines Profile：61,906,601B，SHA `C1BB13A72E01937BAB239AFA31722A0D79687EA44D7AF927CFF90793BAA1F895`，9/1.9.92；本次只读hash再次一致。19:59:17主力f294cd23保留数据install-r --no-start，20:00:25备用8021129d保留数据install-r；两机最终均为此包。主力QQ当前实例未切换；备用客户端设置UI可见；旧1DDA包已被替代。
- 最新147个不同定向用例通过/定向分析无问题；早期2881/15/0全量及后来v9的2877/34/4失败只对应当时快照，不宣称最新全量绿。34通过/1skip是native/真实来源fixture补测，不含四项失败；codec短路径另3项通过，其他失败未由这组补测证明关闭。借用首幅24.223--44.704ms仅已准备封面、N3/条件；渐进补齐仍13.550--15.449秒。
- 用户已确认下载漫画封面恢复。主力真实插画/三大图、渐进冷backing/首次原像素、绝对速度/帧门槛、冷codec/16-bit/HDR显示边界、完整系统操作/远端UI、App UID特权桥、真实OS压力及稳定warm基线仍开放。桌面按用户要求暂缓，不因共享代码宣布桌面验收通过。
- 没有release、卸载、清用户数据、改用户原图、commit/push；无本轮仍运行的工具命令。主力原forward21173保留。后续接续以本节和版本总记录为准。

## 历史记录 · 2026-10-06 00:05

收束时间：2026-10-06 00:05（Asia/Singapore）。用户要求休息后明天继续；本任务暂时停止测试，022仍为执行中，未验收完成。正常应用构建约162秒，使收尾略超20分钟窗口。

- 当前工作目录 `D:\Flutter_Projucts\PicaComic\PicaKeep`，branch `main`，无提交/推送。修改仍保留在工作区。
- 完整测试 `all-tests-checkpoint-2354.log`：2736通过、14跳过、0失败；`analyze-checkpoint-final.log`：lib/test/tools/native Dart无问题。
- 原生持久worker池已实现，最多2个worker、排队128，probe/estimate/decode复用。独立FFI smoke和池测试通过，报告 `native-worker-pool-regression.json`。未验：强排队取消、强制启动失败/致命退出、Android新池首显速度。不能把独立测试或旧N30当作新池性能证据。
- 最新Android正常应用入口 `lib/main.dart` profile构建成功（162.2秒），APK路径为 `C:\Users\tanad\.codex\tmp\picakeep-022-flutter-build\build\app\outputs\flutter-apk\app-profile.apk`，83,054,305 B，SHA-256 `E44AF23204B6C68865DA848C348505E82505077D8F6D419C9BFF218A489711E0`，versionCode9/versionName1.9.92，既有debug证书SHA-256 `31b4434516ccc1f58add7cc5cd4b6786e995c957d5891d3685e4c75a7a58d7c7`。验证后`adb -s 8021129d install -r`成功，数据保留。安装后应用已force-stop，未启动正常UI，手机无需前台待命。主力机未安装/启动应用。
- Redmi旧池矩阵 `reader-redmi-fixed-30.json`完整：570样本，errors0，每项真实raster匹配，退出时resident/job/lease/临时与工作预算0。六组1:1 ROI P95为444–536ms，未达到100–200ms；baseline single sharp P95 98.314ms，自适应cold174.019ms，普通首次仍退步。
- Windows旧池矩阵 `reader-windows-fixed-30.json`连续模式第7样本几何失败已保留，profile harness已修actual viewport反投影及先滚动目标行；该修复尚未复测。先复跑Windows连续ROI，保留两原像素误差判据。
- 32MiB封面候选双端N30 cold退步：Redmi baseline/cold/warm P95 289.234/465.102/48.263ms，Windows 122.499/149.128/22.078ms。阈值已恢复64MiB，报告 `cover-server-results.md`。热缓存速度有收益，冷首显20%提升仍未达标。
- 主力机已下载正文JPEG及Pixiv ZIP匿名复制到新机 `/data/local/tmp/picakeep-image-pipeline-022-real-source`；源前后size/mtime/SHA、host和新机SHA相同。仅只读取样，不改源文件或下载状态。来源及明日命令见 `source-real-download-results.md`；不必重复连主力机取样。复制不是正式reader/Root MethodChannel验收。
- 合成素材 `E:\picakeep-image-pipeline-022-fixtures`，独立源码快照 `C:\Users\tanad\.codex\tmp\picakeep-022-flutter-build`，其build为E盘junction。大构建和日志继续E盘；收束余量C3.92/D17.24/E3.28GB（十进制）。快照脚本只复制普通文件，不跟随plugin链接。Android/Windows Flutter构建必须串行，不能让不同target覆盖同一flutter_assets。

下一次优先顺序：确认用户继续→复跑worker池同条件Android/Windows ROI N30及普通首显→修Windows连续ROI→4000×6000、96MP/超长图三布局实际UI、原像素缝隙/alpha/方向核验→真实下载JPEG/ZIP阅读及保存分享收藏原字节闭环→缓存压力/受控磁盘失败和正式服务端GUI/headless入口→最后正常双端profile构建与完整P0–P10验收。必要时继续metadata复用、tile尺寸/批量候选；Texture/sync raw仅有依据时A/B，不能为压时间牺牲原像素或取消预算。

不启动自动任务，不在用户休息时继续设备测试。明天在本线程继续即可，执行结果只向022末尾追加，不修改原验收标准。

## 同次执行已恢复 · 2026-10-06 上午

用户已回复继续并解锁空闲机，当前主动推进022。上方00:05停止状态属于历史接续点，当前已重新进入profile测试；不应依据历史段停止当前已授权任务。

- 新两端reader池完整矩阵各570样本、0errors、全部raster，Windows连续第7目标已修复实证；普通Redmicold仍回退，详reader-results.md，不能最终验收。
- shared native3f41... + pool47df...已双端构建；Windows512/1024各360ROI+prepared全部完成，512手机360已完成，1024手机正在运行。文件docs reader-shared-{512,1024}-windows-30 / reader-shared-512-redmi-30。prepared组明确计时外准备，旧初建组保留。
- 普通3000 PNGadaptive/full双端N30已完成，full只改善手机相对adaptive但仍比基线慢，Windows退步，defaultfalse。resolved original handoff候选正由cover_perf加入source绑定/lease/版本核验减少重复open，不提前无预算decode。
- Windows真实surface44case全部逐像素一致，报告reader-surface-quality-windows-44.json；第一次因debugNeedsPaint仅debug可用44错误记录保留。新helper加显式surface-cache-quality重复组验证persisttrue/hit画布，待双端构建运行，Android当前APK还含第一次helper错误（不要拿它跑quality，只跑普通/ROI）。
- Windows4000×6000 PNG390样本已完成，cold185.63ms比baseline127.64ms慢，diskwarm36.80ms；JPEG390正在跑。两fixture已copyspare/hostsha一致。
- Cover afterframe双端各90样本已完成，Windows15%冷改善、Redmi7.5%回退；schema5真实JPEG/ZIP+768/512卡片quality参数已freeze，但未运行。封面阈值64保持。native opaque PNG缩图优化候选曾RGB3 extreme2px出现alpha254差异，否决；当前只测opaque-row-skip保持finishalpha，生产尚未freeze新hash。
- source/server真实本地12组合18tests、远程12组合49tests均完成；同进程sharedexecution死锁已修network lane。反向审查发现headblocked dependency、缓存超量读、body stall取消、404原图lease/实际预算4问题，source_workflow继续修并62+5定向已过，待最终freeze与正常--server入口实测。
- 新OS RSS工具只读已验证，Android Dart极小RSS不能当验收；最终lifecycle/pressure须独立OS旁路，性能A/B当前未启用采样，避免混入observer开销。
- Windows/Android build由root串行，所有agent测试用独立E DLL，不能锁runner DLL。快照仍C:\Users\tanad\.codex\tmp\picakeep-022-flutter-build（build→E junction），日志E。仅debug/profile，无uninstall/clear/commit/reset。currentphone安装reader profile SHA452B793F...D90DB，数据保留；正式正常APK将最终另行构建恢复。
- 尚未完成：以上新候选实际两端、全部格式三布局质量/动画、系统saveexport新bridge真实验证、最终预算/压力/完整回归、正常server与GUI入口、最终正常双端构建及全P0—P10验收。保持执行中，不以分项完成标全计划完成。

## 同次执行候选接续 · 2026-10-06 12:00

当前仍主动执行，未暂停/结束。以此节替换上方历史运行状态判断，不覆盖旧记录。

- spareUSB8021129d已解锁且常亮，当前reader旧快照APK仍跑4000×6000 JPEG390组，runId2026-10-06T03-43-40-064644Z/PID12691，进度连续previewcold约20，不要安装cover打断。报告完成后capture`reader-4000-jpeg-redmi-30.json`。首次误填不存在fixture名失败已保留first-failed JSON，当前正确名4000x6000-baseline.jpg。
- 新raw viewport Windows360全部actualraster/0error，全部组P95<=200；Redmi360完整但single513/538ms、cont520/644、double561/817，未达到目标且单/连续回退；两端报告reader-viewport-region-*-30.json，不默认全局改viewport。native opaque-row-skip核心11a006保持像素，通过native质量/取消矩阵。
- Windows真实surface-cache66全exact，Redmi66仅14exact、43最大RGB差1—2、9长图宽多列801vs800，报告reader-surface-cache-quality-redmi-66.json必须保留失败。root已增加exactreadback子RenderBoundary：只收整数extent避免ceil多列，不resize截图。cover_perf生产Painter限定density1且真实localToGlobal+DPR投影两轴>=1、axisaligned，FilterQuality.none；缩小/旋转medium，15surface+6backend通过、DPR2.75原像素checker/alpha区域2×240000精确，手机新包仍未跑。
- rootharness新增texture-capacity实际端点6探针（仅长边下限非大二维内存证明）；bounded-png-fit开时先自动探针并只使用本run结果；raw-sync显式false默认；format-layouts单独22输入×3布局×2模式fit/原像素pan，参考精确像素仍独立surfacequality组，尚未build跑。harnessprepared/reference已改真实memoryscheduler+NativeDiskWork准入、诊断quota/账清理；四工具analyze clean。
- 旧冻结schema5 cover Windows4×90已跑：真实JPEG352卡片384 cold16.555 baseline27.284ms；同卡76828.454 baseline30.616。真实ZIP正文PNG768卡片768 cold82.146/warm16.840 baseline97.682，故意不足384 cold80.950/warm32.555 baseline124.591且upscale1.2973。这四报告仅旧quota前生产，quality差图不设容差/主观通过，cover-server-results.md已记录。Android cover旧快照profile已build验证shaFDF848...B9AD2/version9/debugcert，尚未install，待reader结束。
- 正常lib/main.dart Windows profile旧quota前已build并实际--server+verificationroot启动，13外部HTTP/实际原字节/并发tile/加密/版本全pass，server-production-headless-before-quota.json。task进程30548已停，当前Windows无应用测试进程。库/account/主力机均未启动/改动。
- source_workflow所有writer新quota/defaultheadroom接入12quota+9inventory通过，但真实remote ZIP layout4/5三项失败正在修，不能snapshot半成品。native新增readonly空间API已freeze，Windowsjunction归真实GUID，AndroidCLI shell域实际/data与emulated逻辑id不同同物理容量，quota保守总扣Android所有pending解决alias，不假造物理UUID。appUID空间查询须后续新版profile实际验证。
- raw sync helper独立模块/test已freeze11/11，Android optin+packedROI<=4MP，仅真实Skiaunsupported一次回退，其他错误透传；stillcopies+deferredGPU不等于显示。sourcebackend/page已接默认false，未来真机N30/strictquality/RSS未测。native_pool正在单独optin early-original-raster handoff（小static sRGB8 PNG+fullOrdinary），Page/Surface编辑窗口已交其，sourceowner不再改Surface；等待统一freeze后capture/build。
- 当前snapshot仍旧quota前immutable代码，root不copylive未冻结。其APK现在cover entry，Windowsexe正常main，明确workdir专用snapshot/串行构建。E/C余量约2.1/1.9GiB；不得删用户原文件/未drainbacking，旧taskAPK可再生但当前还保留，无clean/uninstall/release/Git写操作。

接续优先：手机JPEG完成capture→verifyexistingcoverAPK后install-r两端真实cover384/768→sourcequota最终三项失败修复+rawhelper/earlyhandofffreeze→全源static/analyze→capture一次snapshot→reader双端profile新quality/texture/rawsync/early/bounded A/B及OS memory→正常main新server/GUI真实workflow→全suite+finalnormalprofile恢复。022仍执行中，没有改变原验收。

## 同次执行接续 · 2026-10-06 13:28

仍主动执行，未结束或暂停，计划022未全部验收。以下以本节为当前状态，旧失败及候选证据均保留。

- 双端最终 reader 画布与缓存66/66逐像素一致，原文件未变，资源/租约/工作/临时/磁盘账退出全零。报告 `reader-final-quality-redmi-66.json` 与 `reader-final-quality-windows-66-recovery.json`；边界为native sRGB8/alpha黑底与引擎区域读回，不冒充HDR或全部正常UI。
- 最新一次完整回归2857通过、14文件系统平台跳过、0失败；全范围analyze无问题。日志 `final-all-tests1006-verified.log` 与 `final-analyze1006.log` 在E work。该绿色状态先于随后新增的export staging准入及两个opt-in性能实验，新增改动需独立检查并再次统一回归。
- Redmi同APK raw-sync/async各360样本全部raster、errors0；sync清晰ROI P95 512–579ms、async609–655ms，均未达200ms。native失败返回分别243/231，未保存逐错误code，不统称正常取消。sync仍false默认；新同步strictquality在PID17135运行，旧APKsha98667B...9A8，不安装其它包打断。
- Windows format-layouts两次受controller边界阻止任意目标居中，停止任务进程保留日志；这不是已证实的生产像素失真。helper仅格式组改成受限边缘目标实际可见+native complete记录，常规ROI两像素中心标准保留，修正版需新构建重跑。
- normal main Android profile已构建并核签/version9，未安装：独立保留 `D:/picakeep-image-pipeline-022-work/normal-profile1006-before-export-quota.apk`，65,572,820B / SHA7E5375656976CED30F0D5E62351DB0B8B7571CB631BABB8212F377E809AE13AA。它不含随后export准入和候选改动，不能作为最终交付包。
- 三路继续：cover opt-in native缩小后无损PNG再Fluttercodec；native opt-in prepared backing严格只读入口；source临时原字节分享物化按实际磁盘准入及isolated正常UI target。所有默认候选关闭；不为凑速度改变原像素或全局预算。
- 构建实际已转D，E保留旧入口junction；TEMP/TMP使用D任务目录。手机只spareUSB8021129d，主力机未安装/启动/清数据。后续仍仅profile/debug、显式APK+设备install-r；未提交/推送/清用户数据。

接下来：收齐syncquality→各owner最终freeze及定向→统一snapshot→先reader双端format/readonlyN30/RSS，再cover encoded及默认N30→isolatedactualUI/native系统操作与正常headless服务→全scope回归→最终正常profile双端恢复。性能、全部格式布局、正常产品UI及十轮OS回收仍有缺口，保持执行中。

## 同次执行接续 · 2026-10-06 14:00

用户新截图中的三次CRT abort来自本轮极小预算测试，已诊断为MSVC Debug STL noexcept iterator proxy分配失败，非已证实的运行库安装损坏。普通/prepared入口32MiB早拒及仅核心MSVC Debug target的iterator级别修复已落地，原三个宿主已正常退出；native_pool仍完成旧符号回退/诊断/analyze/hash，root尚未capture或构建这批新核心，不安装未冻结候选。

- 原生证据日志 `E:/picakeep-image-pipeline-022-work/prepared-failure-probe.log`，详细修复测试由native_pool候选文档汇总。所有fatal诊断仅本任务子进程，不改系统registry/CRT全局策略。
- 手机PID17322自然完成96MP默认lifecycle/disk-space，run `2026-10-06T05-31-28-176561Z`，报告 `reader-final-default-lifecycle-redmi.json` / SHA8967e356510b6b6bb3dd44839ef583ff00c2d8c03b8ce8a0d2c710bacbc946c7。60次退出全部资源/空间账0，native3151/0fail；两个idle worker仍在。不改变手机options/start/install，报告已捕获。
- OS补采60秒已完成/0error，`os-rss-final-default-lifecycle/android-lifecycle-final-minute.jsonl`实际为完成后空闲，非最后一分钟循环。smaps约253MiB稳定，status异常0.7MiB保留；全60轮RSS增长门槛仍待配对观察，详 `reader-final-default-lifecycle.md`。
- 正常headless quota新版Windows13HTTP全部通过并停任务server，详 `server-production-headless-quota-profile.json`。正常GUI tools入口最终SHA430e78e241605d96086462a6e224fd71d89695ef0a3cc749a219b8e7deb20cfe、path/prefs适配器f9f0...，10/10及analyze clean；仍未实际启动GUI。export生产SHAa981...，34/34已过。
- Cover native-encoded候选固定false默认，freeze哈希和24/24见cover文档。后续每端两素材×default/candidate四轮，各baseline/cold/warm N30，再按自身组raster/卡片质量判读，不能宣称未测收益。默认4K PNG384无source用harness自生同SHA，真实ZIP PNG768指定member-index1。
- 全部exec采样进程已结束。下一步仍等待native全部冻结→统一snapshot→串行reader profile双端/格式与prepared性能→cover四轮双端→隔离正常UI/系统操作→全scope及最终正常profile。022执行中，未全验收，未清用户数据/提交/发布。

## 同次执行接续 · 2026-10-06 14:56

仍主动执行，未暂停。native最终freeze后的fullsuite2881/15skip/0fail与analyze clean已完成，详final-after-candidates-regression.md，不需要无改动重复全量。

- 手机新包SHA9ecb0bd9…已核3ABI intermediate/libs.jar/APK AOT、既有debugcert/version9后install-r成功；原缺AOT包不再用。构建恢复诊断android-aot-build-recovery1006.md。当前源码snapshot的build→D/flutter-build-v2、compiler cache→D/flutter-compiler-cache-v2，都是单跳；旧alias/cache/task.gradle留存。所有后续串行构建使用此v2布局，仅debug/profile。
- 新prepared质量66/66 exact、源未变、资源/配额0，112native错误全为code5 miss安全fallback，native-prepared-read-candidate.md已追加。报告reader-flat-v2-prepared-quality-redmi-66.json，run06-47-29-348065Z。
- Redmi当前PID19718运行sameAPK prepared-on N30，run2026-10-06T06-52-11-292020Z，options本地reader-flat-v2-prepared-on-options.json；完成后capture reader-flat-v2-prepared-on-redmi-30.json，再push off-options并force-stop/start（不安装、不清数据）做配对。不要拿短logcat过滤没新行推断卡死，先看真实前台和完整log。
- Windowsv2 reader build393.8秒成功，exeSHAe0ee4da7…；PID57720执行surface/cachequality+完整format-layouts，samples1/preparedtrue，输出D work/reader-flat-v2-quality-formats-windows.json/log/stderr。完成并检查status/pixels后关闭本任务window，再同exe跑prepared-off/on各360N30。格式helperSHA81387ebe…已同步snapshot，生产hash未变。
- 正常UI PID46932实际图集/real-jpeg/章节/阅读器fit已观察，taskroots/prefs隔离；窗口已正常关闭。系统save/share dialogs仍未验，详normal-ui-isolated-entry.md，不能以10/34测试或toolbar可见替代。
- 待验优先：两端prepared配对→封面PNG encoded四轮/端（cover入口须先Android+Windows串行构建，保存当前reader runner的完整复制才能并行host）→普通early/full/JPEG最终A/B→所有格式/色彩/动画/系统操作/OS回收压力→最终正常main两端profile。cover默认仍false；不要重复已合格真实JPEG384矩阵。

022保持执行中；无commit/push/release/uninstall/用户数据clear。当前C约0.9GB、D29GB、E2.8GB，构建及TEMP均D。主力机未安装/启动。

## 2026-10-06 Surface修复与封面A/B续测

- `reader_image_surface.dart` 修复 per-variant 终态失败保留与显式重试、以及异步来源复核后重复有界准入。定向测试25/25，`dart analyze lib/pages/reader/reader_image_surface.dart test/reader_image_surface_test.dart` clean；生产SHA `36DBDA0A601F73ECD7684FC5AA74716D16EF15C63009945A7F97D058B269A9D4`、测试SHA `64A46257D1599F90DA947FCB3F64330E654D5E769222E742D4AD0F03C98518A7`。原N30/真机失败仍要新APK重跑，不能只据复现测试归因。
- 新 profile build `reader-flat-v2-surface-fix1006.apk` 为84,413,474B，SHA `F48874C599C788EDDA0A8C60841AFB739F4843AEAD16A5DF23158D2945B31FCD`；APK三 ABI `libapp.so` 非空，arm64 6,423,472B、armv7 7,029,340B、x86_64 6,489,008B；既有签名 SHA `31b4434516ccc1f58add7cc5cd4b6786e995c957d5891d3685e4c75a7a58d7c7`，版本9/1.9.92。`adb -s 8021129d install -r` 已成功，无卸载/清数据。修复版on/off各360样本、错误0、missing raster 0；12同名组on P95改善27%–52%，但P95绝对值仍466–684ms。新包 surface/cache-quality 66/66 exact、源不变、错误0。原始报告与哈希见 `native-prepared-read-candidate.md`。
- 封面候选最终四组N30均完整：Windows/Android各跑4096 PNG→384和真实ZIP member1 PNG→768，源SHA一致、编码候选30/30确认为native encoded。默认/候选冷P95（ms）：Win PNG 104.379/129.735，Android PNG 232.979/338.911；Win ZIP 80.736/225.293，Android ZIP 192.403/475.305。完整raw数据在 `cover-server-results.md` 与八份 JSON。候选明显回退，继续默认false。
- Android新候选ZIP JSON：`cover-android-zip-default1006.json` SHA `1F211427FC989EAF80F77FCA06A7C4183A2F05E23091E8ACF125D44F3C57C531`；candidate SHA `A87263F0F791752B6AE14391BD1A82C912836EF729CBDE917DDAC4407B67A5E9`。两者member1解出图SHA均为`8811fe1a50a009f754b59cc169e73f3a506564baba77b6415ae127856f753ffe`。
- `tools/image_pipeline_022_color_animation_main.dart` 新增ICC/16-bit/动画独立Reader逐像素和1:1投影测试入口，SHA `5EB46B24D3EBAE889482E03AAEF0B9E95C6C0746722E3B97CDB28A31895C0D3E`，analyze clean；尚未build或profile run。下一步在当前空闲机执行色彩/动画专项，并补Windows修复版矩阵。

继续执行中；所有性能候选保持关闭，主力机未装/启动，不做release、不清用户数据、不提交/推送。

## 2026-10-06 17:26 · 色彩动画、Windows paired与Android OS续测

- 当前继续022，不改变目标或门槛。根因已确认但生产alpha Painter修复仍未freeze：preview whole与density=1 tiles同屏时重复srcOver半透明原件，Windows Flutter precision probe专门重复画两次精确复现RGB16/gray16误差；同一原件ROI medium/none单层和tile mosaic均exact。RGB16 sharp残余最大差1仍未定位。生产 owner 当前按higher layer遮挡lower coverage方案实施，需验证missing preview/alpha/seam再构建，不能用本次旧APK宣布修复。
- 最新phone test APK `D:/picakeep-image-pipeline-022-work/color-animation-v3-1006.apk` 84,413,474B / SHA6755F8E626C1558C3ACBA1DC49BE94309B8FFF13E641D1C6A761E71210D64DB6，version9/1.9.92，既有签名和三ABI AOT都校验，spare `8021129d` install-r成功。surface fix生产SHA36DBDA0A…B269A9D4、色彩工具SHA C913AE270C7E91498F05C52C93D701BCC9A4BC954D72EFE8C44AE47A2A552623。36/36测量完整、0 errors/source changed 0，但RGB16/gray16 preview大偏差仍存在；两种GIF/WebP在三布局×两模式各确认两不同原文件帧、像素exact。完整差异表和16个PNG在 `color-animation-profile-results.md`。
- Windows同主checkout build后runner隔离副本，prepared on/off各360，错误/missing/target/focus均0。Windows12对应组P95改善32.9%–52.3%，但on绝对191.455–225.093ms；报告 `reader-windows-surface-fix1006-prepared-on/off.json`，是否保留候选，不全局默认。完整表、构建hash和运行边界见color动画报告。
- Android Surface fix同App PID28814、startTimeTicks97529859，3000×4000 PNG的60次退出/进入completed/errors0；每次Surface/jobs/working/temp/lease/cache/disk计数归零。外部OS脚本75 samples/0 errors覆盖26秒运行和49秒尾静稳；运行RSS241–477MB/PSS153–388MB，尾部RSS约282.6MB±45KB/PSS194.2MB±54KB。没有运行前稳定基线，所以不宣称达到十轮32MB/10%增长验收。原始报告在 `reader-lifecycle-os-redmi-surfacefix1006.json` 与 `android-lifecycle-surfacefix1006.jsonl`。
- precision Flutter test `tools/image_pipeline_022_color_precision_probe_test.dart` 1/1、6秒pass；完整88 comparison原件与artifact已保留。original/repeated codec、target-full、透明whole/crop/grid路径全部exact；overlay-twice控制复现preview误差。sharp max1差异probe未复现且不能容差通过。
- 当前缺口优先：收source owner alpha patch与surface unit测试→main Android/Windows新profile重测ICC/alpha/66像素质量及动画→sharp16残差→prepared Android修复后paired→正常GUI真实原图操作→稳定warm baseline/十轮RSS→全范围回归→最终正常Android/Windows profile包/应用入口恢复。质量/内存/正常workflow验收未完成时，022保持执行中。主力机未安装/启动；无release/uninstall/clear data/commit/push。

## 2026-10-06 18:36 · v6真机记录与双端特殊色彩复核

- Android v6 profile 的ICC/16-bit/动画Reader矩阵已完成36/36，RGBA16最大逐通道差1、gray+alpha16最大差1，P3/Adobe和两种动画均exact；内部资源与配额账退出全零。完整APK、素材与差异统计见 `color-animation-profile-results.md` 和 `color-animation-alpha-v6-redmi1006.json`。结果不代表16-bit/HDR端到端保真，也没有v6配对N30。
- v6同时修复分数缩放时本地tile滤波采样边沿：rasterRect向采样侧增加有限gutter，sourceRect仍独占可见coverage；server negotiated tile不扩请求。256像素多瓦片与全图合成测试逐像素相同。Native backend gutter专测在当前Windows Flutter tester因目标fixture/library不可用而skip，仍待合适环境补验。
- 当前Android空闲机 `8021129d` 前台仍为PicaKeep进程，但上述v6矩阵已在18:23结束；没有把前台/存活状态写成正在测量。Windows没有运行中的PicaKeep/Flutter测试窗口。D盘剩余约26.8 GB；Windows快照源码约58 MB，编译输出junction指向D盘`flutter-build-v2`，可继续按既有隔离目录执行。
- 下一项是用同一组固定哈希的匿名合成素材跑Windows profile 36项ICC/16-bit/动画矩阵，核对Windows实际Reader与Android v6的质量边界；之后继续Android速度N30、sharp单级差定位、OS稳定warm基线及正常UI文件操作。计划保持执行中。

## 2026-10-06 18:46 · Windows v6特殊色彩与动画矩阵

- Windows当前alpha/gutter源码快照profile构建成功；runner真实Reader色彩/动画矩阵36/36 measured、0 errors、49帧都与FrameTiming匹配、原文件SHA前后不变。四种ICC/16-bit色彩组与两种动画在三布局/两模式的RGBA8读回均逐帧exact；可用float读回也exact。报告SHA `CF5E8E4F7069CD679E0773F16CFA0F8F9A8DD5DD8D4633E99A339C6C30D72039`，完整数据见 `color-animation-profile-results.md`。
- Windows结果参考各自平台Flutter原文件codec与sRGB画布，不代表16-bit/HDR面板端到端保真，也不等于跨设备广色域一致。Native GIF probe的9次code4走已实现Flutter codec兼容fallback，错误列表仍空；测试结束所有应用内部资源与配额账归零。
- C盘仅剩约1.15 GB，因此沿用固定58 MB源码快照，编译目录junction指向D盘 `flutter-build-v2`，TEMP/TMP指向D盘任务目录；构建后D盘仍约26.8 GB可用。Windows 36项不是大图性能N30，Android配对速度、16-bit sharp一阶差、OS稳定warm基线及正常UI保存/分享仍待验；计划继续执行中。

## 2026-10-06 19:16 · native gutter补验与Android速度配对

- Windows Flutter tester显式提供固定native DLL与fixture后，`native_reader_prepared_read_test.dart` 为4 passed / 1按能力skip / 0 failed；扩边ROI原坐标像素契约实际通过。DLL SHA `039E09EAE0A232418865E7F308637712C9AAED2ACDEFC7A59AB75225B09114B4`，日志D盘 `native-gutter-wrapper1006.log` SHA `786DF7F06BD26B85DB511890205362419C375195898CE299799FA02DD079A51D`。此前的native gutter skip已补上，不改写旧跳过事实；缺符号库的兼容分支在当前带符号DLL按设计skip。
- 当前v6生产源码的`profile_main` profile APK已核三ABI、version9/1.9.92与既有debugcert并仅install-r到 `8021129d`。APK `D:/picakeep-image-pipeline-022-work/reader-v6-profile1006.apk`，98,029,730 B，SHA `CE20249A28949E44481E52BE1AF82ECEC45C42298D30C5E3CDDFB78AFB9849EF`。on轮360/360 completed、errors0；报告 `reader-v6-prepared-on-redmi1006.json` SHA `6C229363280BEB997D108F25C9DA8F00789C2A71075B07E0AB78E84548CD237D`。P95为443–658ms，不能因relative收益候选而记200ms达标；off仍运行。
- Android一阶色彩差诊断只增加tools参考控制：保留旧reference，另渲染同图/同几何/同filter、`isAntiAlias=false`的独立参考；可选precision-probe追加固定640×960 original/transparent crop/mosaic精度控制。tools入口analyze clean；新diagnostic profile APK已build、还未安装，不打断off。生产Painter未改。

## 2026-10-06 19:25 · 当前交接快照

- Android v6 prepared-read 配对已完整结束：同一 profile APK、设备 `8021129d`、同一 `8000x12000-interlaced.png`、`roi,roi-prepared`、512 tile、各30样本，prepared on/off 各360/360，均 `completed`、0 errors、0 missing raster。on 报告 `reader-v6-prepared-on-redmi1006.json` SHA `6C229363280BEB997D108F25C9DA8F00789C2A71075B07E0AB78E84548CD237D`；off 报告 `reader-v6-prepared-off-redmi1006.json` SHA `E689F20DB2E2FB1EE04B0B3F566FD9A9E123EC5AFDAE06037FDDD16583351279`。
- on 的 prepared ROI P95 为 `442.78–619.52 ms`，off 为 `694.57–1132.28 ms`，相对下降约 `36.3%–49.0%`；普通 ROI 下降约 `24.1%–48.1%`。绝对值仍超过计划 `100–200 ms`，所以 prepared 继续 `opt-in/default-off`。OS 文件缓存未控，on 先于 off，结论是候选收益证据，不是跨设备保证。
- 两轮退出时 resident、surface/job、working/temp reservation、原件 lease、raster cache、disk quota 均归零。native code2/code5、取消和 worker 统计保留在原始 JSON，不能把失败样本折算为成功。
- Windows v6 色彩/动画矩阵已归档：36/36、49帧、0 errors、FrameTiming匹配、源SHA不变；ICC/16-bit、P3、Adobe RGB、GIF、WebP在同平台sRGB Canvas参照下逐帧exact。报告 `color-animation-alpha-v6-windows.json` SHA `CF5E8E4F7069CD679E0773F16CFA0F8F9A8DD5DD8D4633E99A339C6C30D72039`。不外推为16-bit/HDR面板保真。
- native gutter 后端补验已实际执行：`native_reader_prepared_read_test.dart` 4 passed / 1 capability skip / 0 failed；gutter ROI逐字节匹配原图坐标。DLL SHA `039E09EAE0A232418865E7F308637712C9AAED2ACDEFC7A59AB75225B09114B4`，日志 SHA `786DF7F06BD26B85DB511890205362419C375195898CE299799FA02DD079A51D`。
- 工作树工具入口 `tools/image_pipeline_022_color_animation_main.dart` 增加诊断性 `isAntiAlias=false` 参考与可选 `precision-probe`，已 `dart analyze` clean；没有修改生产 Painter。诊断 profile APK 已构建但未安装，避免打断已完成的 off 轮。
- 当前环境：主力机未安装/启动；空闲机只使用 `8021129d`；无 uninstall、clear data、release build、commit/push。C盘约1.15 GB，D盘约26.7 GB；快照源码约58 MB，Windows build junction 指向D盘 `flutter-build-v2`，TEMP/TMP 指向D盘任务目录。
- 继续顺序：1）如需确认Android一阶差，安装诊断APK并只跑 precision-probe；2）拆分冷源/磁盘热/解码热并建立OS warm baseline；3）定位16-bit sharp一阶差；4）正常UI原图放大、保存、分享、收藏闭环；5）全范围回归与最终正常Android/Windows profile恢复。022仍执行中，不能宣布P0–P10完成。

## 2026-10-06 · 手机续测当前快照

继续执行022，用户要求本轮只测手机，Windows/Desktop验证暂缓。下面记录为本轮最新状态；旧报告与候选结论保留，不视为P0–P10完成。

- 当前备用Android设备为 `8021129d`。安装的是Reader v9 profile诊断包 `D:/picakeep-image-pipeline-022-work/reader-v9-continuation.apk`，SHA `7BFDA9A61756CB51A21B7AA1BD4EACB8A866DDED6D5028AD2B1CB76E4E14DDF0`；version 9 / 1.9.92。通过 `adb install -r`恢复，不卸载、不清数据；主力手机未操作。
- Android v9 surface quality为66/66像素exact，见 `reader-v9-surface-quality-redmi1006.json`。v10 Android Reader专项36/36 case、48/48帧exact，0错误、源未变、结束资源归零；独立precision probe仍有冷codec网格差异。Float32 raw readback因引擎报 `Failed to get color type from pixel format.` 被如实记为8项unsupported。报告、逐路线结果及hash见 `color-animation-profile-results.md`。
- prepared-admission手机配对只覆盖 `single/sharpFirst`、同一8K×12K源文件、每组30样本。开启后P50为197.528ms、P95为247.142ms；关闭为194.752ms、268.082ms。估算工作从计时样本内350次降到0，但中位数未改善；性能候选继续默认关闭。详见 `prepared-admission-and-roi-diagnostics1006.md`。
- Lifecycle profile完成10轮、38个phase event、0错误；每轮退出后的内部resident、job、surface、lease、reservation及disk quota账均归零。OS旁路采样120秒/120样本/0错误，但采样开始于 `2026-10-06T21:35:21.980713+08:00`，内部15秒baseline已于约21:35:16结束，因此没有外部OS baseline。smaps RSS中位约214.3MiB、PSS中位约134.6MiB；`/proc/status` VmRSS读数与smaps明显不一致，分别记录，不作内存阈值或泄漏判定。详见 `reader-v9-lifecycle-os-redmi1006.json` 和对应JSONL。
- 生产色彩/绘制代码本轮未因precision诊断改变。Float32不可用与冷codec不一致均仍是明确边界。系统级保存/分享/收藏的正常UI闭环、更多手机速度场景、稳定OS基线、最终全回归与正常profile恢复仍待完成。
- Windows/Desktop本轮未继续或运行验证。Flutter层共享的图像加载、瓦片与缓存改动有机会同时惠及桌面；Android native/backend及系统交互不能据此推定通过，桌面仍须独立验证。

本轮所有测试及采样进程已结束。最新手机状态见本文件末尾“Android v10正常UI续测”。电脑端测试按用户要求暂缓。遵守debug/profile限制，不执行release构建、卸载、清数据、commit或push。

### 手机OS基线对齐补测

同一Reader v9 profile APK、同一设备/PID `9871`、同一 `3000x4000.png` 与 `single/sharpFirst` 生命周期重新补采：warmup后先有60秒baseline，再进行10轮退出/进入与每轮3秒idle，最后20秒tail；OS sampler从预热前开始覆盖，150/150样本、0错误，PID startTime全程一致。报告为 `reader-v9-lifecycle-baseline-armed-redmi1006.json`、`reader-v9-lifecycle-baseline-armed-redmi1006.jsonl`，对齐分析为 `reader-v9-lifecycle-baseline-armed-os-analysis-redmi1006.json`。

- 10/10轮 `afterExit` 的 resident、active jobs/surfaces、queued jobs、working/temp reservation、original lease、pending raster cache 与 disk quota均为0。
- baseline末20秒 smaps RSS/PSS中位数为304.816/225.117 MiB，tail末20秒为278.127/198.103 MiB，变化分别为-26.690/-27.014 MiB；闭环采样窗口内十轮idle中位数没有严格单调上升。按本次对齐的 `max(32 MiB, 10%)` 量级比较，尾段没有超过基线。
- 但baseline末20秒RSS/PSS波动范围约49.7MiB，不能称稳定warm基线；首轮至末轮idle的RSS中位数约227.2→276.3MiB，约增49.1MiB，中间有涨跌。没有严格单调增长不等于排除持续增长。本次已补时间覆盖，OS稳定基线及回收验收仍未收口。
- `/proc/status` VmRSS中位数同样从43.371降至31.701 MiB，但它与smaps是不同OS计数，仍单独记录，不能相互替代。该结论只覆盖本次Android Reader单布局/单模式和此设备，不扩展为所有正常UI、GPU或系统级内存验收。
- 新报告与JSONL原始SHA：JSON `F6AC3E7103EB9096436FC1BE40905FF25CD5137B25D3D1745FB4EA4600CA76FA`，JSONL `153310B5BA473B59E9DFA8C8F311F41F315E077CA7715D703D43447FE26B14AA`，对齐分析 `E8E7225E49B6BA75B7AE216AAB7EEE468D01B59C3D89B308BECC2E794BBF53FD`。

### 手机MediaStore保存桥复验

同一Reader v9包运行独立 `export` 组，`reader-v9-original-export-redmi1006.json`（SHA `D3FD9D5CF31207E597B36DD662E25707B78305BC70D6DED87BA435181DD67286`）为completed、errors=[]。真实Android MediaStore桥保存固定合成PNG，返回 `content://media/external/images/media/2228`；源与产物各10237字节，桥读取本次返回URI核得SHA均为 `d9070a909d982cb52e1380b3af4a089a953b3edcae2de0a56f0c98acbd5f9034`，源前后未变。该专用测试媒体项保留；不扫描用户相册。

独立 `adb content read` 被Android shell UID的SecurityException拒绝，未获得图片字节，不把错误文本当产物。此项验证保存桥的真实调用和原字节校验，不替代正常阅读器按钮、权限恢复、系统分享与收藏UI闭环。当前Root/Shizuku均不可用；主力机未操作。

### Android v10正常UI续测（2026-10-06）

用户明确要求本轮手机优先，电脑端暂缓。使用隔离任务 `normal-ui-022-android-v10-1006`，真实PicaKeepApp profile target，仅操作备用设备 `8021129d`。APK `D:/picakeep-image-pipeline-022-work/normal-ui-android-v10-profile1006.apk`，156,668,066 bytes，SHA `2EDE7C83B4D3FC097F8E28F906FFBA2F85F79751A4E910752981D610993D73A2`，package `lingxue.picakeep`、version 9 / 1.9.92、签名匹配既有应用。

- 实际从正常资源库打开 `real-jpeg`。点击原始像素按钮后controller倍率为0.3636364（设备密度下每原图像素映射1个physical pixel），目标瓦片齐全。注意手机四角箭头是原始像素按钮；真正的全屏控件由`App.isWindows`限制，不显示在Android。
- 点击阅读器保存按钮创建MediaStore项 `content://media/external/images/media/2229`，`Pictures/PicaKeep`、JPEG、504,752 bytes、1062×1500。应用bridge成功前比较源及本次返回URI的SHA和字节数；shell读回权限不足，未获得独立外部hash。该项保留。
- 点击分享后真实MIUI系统面板打开；observer核到分享输入文件为原JPEG固定SHA，点击取消后原生结果`dismissed`，没有选择接收者，也不声称接收端送达。
- 点击收藏后正常收藏列表出现1项；退出并重启同一隔离任务后仍存在。observer同时记录metadata与收藏JPEG副本SHA。手机隔离任务的run-as只读归档快照经 `image_pipeline_022_normal_ui_audit.py --source-task-root /data/data/lingxue.picakeep/files/normal-ui-022-android-v10-1006` 审计，报告 [normal-ui-android-v10-byte-audit1006.json](normal-ui-android-v10-byte-audit1006.json)：`byteAuditPassed=true`、favoriteCount=1、13固定输入全匹配；`fullAcceptanceComplete=false`。
- 屏幕截图及UI hierarchy在 `D:/picakeep-image-pipeline-022-work/normal-ui-android-v10-evidence/`；手机私有隔离任务只读快照在 `D:/picakeep-image-pipeline-022-work/normal-ui-022-android-v10-1006-snapshot/`。真实MediaStore项目和隔离任务数据保留。
- 实测结束后通过`adb install -r`恢复此前Reader v9 profile APK `reader-v9-continuation.apk`（SHA `7BFDA9A61756CB51A21B7AA1BD4EACB8A866DDED6D5028AD2B1CB76E4E14DDF0`）；version 9 / 1.9.92，app data未清理，测试进程已停止。旧独立export测试项2228和本次UI保存项2229都仍在MediaStore。

此正常UI仅单页sharpFirst JPEG，并覆盖真实原像素操作、保存、打开后取消分享、单条收藏及重启持久化。PNG保存、其他布局/质量组合、手机性能N30、OS稳定warm baseline、权限恢复和全范围回归仍缺，022继续执行。桌面验证按用户要求暂停；共享Flutter管线可能给桌面带来收益，但Android平台桥和UI证据不外推为桌面通过。

## 2026-10-07 · 主力机正常 Profile 交付

用户明确要求构建正常可用版本并安装到主力机。默认入口 `lib/main.dart`，使用 `flutter build apk --profile --target-platform android-arm64`；不是诊断 runner。当前工作区的1309项输入复制到 D 盘隔离源码快照，共58,373,290 bytes，逐文件哈希核对0差异；未改产品源码、未覆盖既有测试构建目录。

- APK：[picakeep-main-phone-profile-1007.apk](D:/picakeep-image-pipeline-022-work/picakeep-main-phone-profile-1007.apk)，61,775,529 bytes，SHA-256 `AEABEE52C1263B8B6A58643669356E85804DED3B9CD5FA57874F1E7DFDC1A864`。package `lingxue.picakeep`，versionCode 9 / versionName 1.9.92，arm64 Dart AOT 已核验。
- 安装前只读拉取主力机既有 APK，双方签名 SHA-256 均为 `31b4434516ccc1f58add7cc5cd4b6786e995c957d5891d3685e4c75a7a58d7c7`。显式设备 `192.168.5.4:5555`（22127RK46C，serial `f294cd23`）执行 `adb install -r` 成功，未卸载、未清应用数据。
- 正常 `.MainActivity` 启动成功，安装后核对版本及前台 Activity，观察 PID23946；该次启动的过滤日志无 Flutter/FATAL 错误。此记录只证明构建、覆盖安装与启动，不等于正常数据集的完整阅读/封面/保存/分享验收。
- 备用机及桌面本轮未操作；未执行 release 构建、commit 或 push。此前“主力机未操作”的记录只代表各自历史轮次，本次已由用户授权覆盖安装。

## 2026-10-07 · 果核调查接收与后续顺序

侧会话调查已接收，详细对照与实施判断见 [果核调查与022对照](guohe-investigation-handoff1007.md)。本会话重新核对334项证据，哈希0差异；综合报告 SHA 与侧会话最终检查一致。它提供参考程序的静态机制与隔离 DLL 样本结果，不是 PicaKeep 用户故障复现或022验收结果。

下一轮先复现本地漫画错误及已下载封面缺失，记录源身份、页面/会话、取消原因、错误码与缓存阶段；再针对现有链路处理有界恢复、封面持久命中、普通页与巨图分流、缺块回退及合并重绘。需要区分正常主程序与默认关闭的实验候选；保留既有清晰优先、原文件权威与质量/资源验收门槛。用户反馈的根因仍未确认，022保持执行中，桌面验收继续暂缓。

## 2026-10-07 · 阅读与封面恢复已实现并交付备用机

用户随后明确要求“继续做”，本轮已实际改产品代码、验证并构建正常主程序。详见 [实现与回归](reader-cover-recovery1007.md)，不能再把当前状态写成仅接收调查。

- 源/metadata解析与可见tile只对明确队列暂满各最多额外补试2次；native worker满队列有独立typed异常，不把所有status3硬预算失败重试。native解码/backing准备取消统一为ImageWorkCancelled，避免写入终态页错误。换源/退出清timer与过期结果。
- 本地漫画封面5秒后补试一次，清该失败字节/显示key并重挂Image；相同源与解码目标保留provider，父重建不绕过上限。后台/隐藏路由/销毁取消，恢复前台只补失败项。已确认的“新CoverDecodeTarget让父重建绕过预算”回归被测试捕获并修复；未放宽期望。
- RPI串行重选源保护临时原件清理；复核另发现普通同文件peer lease会阻塞当前页重试，已在选中源/晚到源两个分支补修：确切普通FileReaderPageSource继续后台dispose，不将跨页全局drain作为重选源前提；公共文件保护/Deferred拥有临时文件的排空契约保留。两项真实临时文件/peer lease回归均通过，源测试最终13/13。
- 不同Flutter回归合计142通过/1按能力跳过，最终analyze无问题；真实native DLL取消、pool饱和与worker smoke/lifecycle均通过。原alpha/gutter/原像素和调度/原件交接回归包含在本次范围中。不是完整手机性能或用户漫画源验收。
- 正常 `lib/main.dart` Profile：隔离快照868项/38,777,679 bytes、0输入哈希差异，隔离目录clean+offline pub get后 `flutter build apk --profile --target-platform android-arm64` 成功，assembleProfile127.0秒。APK [picakeep-reader-cover-recovery-profile1007.apk](D:/picakeep-image-pipeline-022-work/picakeep-reader-cover-recovery-profile1007.apk)，61,841,065 bytes，SHA `5CFBE69B1E61217255EE621A5D6410EF02CB6174942881D5590AE46D1686157F`。package `lingxue.picakeep`、version9/1.9.92，arm64 AOT23,200,688 bytes；三ABI的native engine库与上一正常包逐项SHA相同，未改native ABI。
- 安装前从备用机 `8021129d` 只读拉取既有APK，双方签名SHA均为 `31b4434516ccc1f58add7cc5cd4b6786e995c957d5891d3685e4c75a7a58d7c7`，核既有version9后显式 `adb -s 8021129d install -r` 成功，无卸载/清数据。正常主页及已下载列表实机可进入，前台 `.MainActivity`、PID25640，观察logcat无E/flutter/FATAL；首个XML为锁屏不作App证据，唤醒后另取正常UI XML。只读UI/版本与启动记录 [recovery-device-startup1007.json](D:/picakeep-image-pipeline-022-work/recovery-device-startup1007.json)。未打开个人漫画页，用户故障仍未复现。

当前备用机保留这份正常主入口Profile，取代此前Reader v9诊断入口；既有任务数据及MediaStore2228/2229保留。主力机仍为先前已交付的正常包，本轮未覆盖；桌面应用UI/性能仍暂缓。无release、用户数据清理、commit或push。下一步继续真实源错误诊断、普通页/巨图分流与缺块观感、速度/稳定OS基线及全范围验证；022继续执行中。

## 2026-10-07 · 分块显示连续性与本地回滚复用

用户反馈分块接入后阅读观感变差、已看页面回滚重新加载。本轮已实际修共享阅读代码，详细行为、证据及边界见 [显示连续性验证](reader-display-continuity1007.md)。

- 默认对有界本地静态JPEG/PNG/WebP使用整页原像素；局部可见的巨图适屏在输出16MiB/纹理边界内仍整页，超过预算走ROI。清晰优先保留有效旧画面直到清晰块逐区替换，透明像素不双叠；仅可见层参与差集重绘。远程Raster仍保留协商网格及原75%可见规则。
- 新路由级像素LRU64MiB/128项，闲置缓存与active/pending共享192MiB预算、可见工作优先；路径/源身份/stat/geometry/pixel处理完全一致才复用，缓存不持原件lease。另有128项元数据/codec准入缓存，回看仍open/stat，免重复probe/descriptor；等待布局沿用尺寸提示。源及Surface转圈延迟500ms。
- 刷新/内存警告/退出以epoch拒绝迟到旧结果回填，普通File原件回滚实际测试无新增解码、像素一致；文件变更重新解码、退出所有账归零。归档/远程/受限目录Deferred临时原件仍未解决跨widget回滚缓存，不能声称全部来源已经修复。
- 不同回归141通过/1能力分支跳过，分析无问题。正常PNG入口卸载回看无需probe/descriptor/codec且无短转圈，原生DLL取消/队列/prepared资源释放9项通过。12文件组合中仅新测试旧resident口径断言失败，已按包含会话缓存的新口径修正并重跑该8项全过；native worker idle timer在widget体结束前关闭。原像素、alpha/gutter、六布局与导出冻结回归通过；用户作品帧耗时尚未实测。
- 正常 `lib/main.dart` Profile经隔离目录clean/offline pub get重建118.0秒，869输入/38,805,440 bytes、构建前后哈希0差异；APK [picakeep-reader-continuity-profile1007.apk](D:/picakeep-image-pipeline-022-work/picakeep-reader-continuity-profile1007.apk)，61,841,065 bytes，SHA `ACC866077394931559EC152767D46CAA20BD3F3514D63C15EB7C88905007118E`，9/1.9.92，签名相同。三个native ABI库不变；Dart AOT SHA已改变且核验包含本轮缓存，ZIP最大封装间隙0。
- 显式设备 `192.168.5.3:5555` 核对serial8021129d及APK存在后 `adb install -r` 成功。首次安装时间保持2026-06-29 16:42:23；正常MainActivity前台PID27720，主页与既有下载计数显示，所筛启动日志无Flutter/FATAL。未打开用户漫画页，尚未完成真实阅读体验验收。主力机离线保留此前正常包；桌面UI/性能仍暂停。无卸载、清数据、release、commit或push。

当前备用机已更新为这份正常显示连续性Profile。022仍执行中；下一步需结合用户内容来源定位归档/远程回滚，以及真实漫画/巨图显示和帧时间对比。

## 2026-10-07 · 主力机已下载封面恢复

已复现持久来源缓存指向被删除的应用内封面，修下载页惰性解析恢复；配额优先清闲置backing，插画坏缩略图/过期准备图补有限重建。161项封面回归全部通过，分析无问题。正常lib/main Profile D55E3076…经869产品SHA/450编译输入核验后保留数据安装主力机f294cd23；真实已下载首屏原五张错误封面均恢复，用户确认正常。详见 [本轮修复](main-cover-repair1007.md)。

剩余问题明确为插画滑到新图慢、返回重新进页又加载。主力机只用Android全部文件权限，Root/Shizuku设置均0；此前把特权fallback静态成本当当前设备根因不准确，已撤回。不能把已下载恢复称插画速度达标。当前开始真实普通文件冷/热阶段采样；022仍执行中，桌面继续暂缓。

## 2026-10-07 · 插画冷/暖修复与主力机正常包更新

真实滑动采样发现解码排队最长2.13s、后台PNG编码最长2.05s；同时确认未落盘时忽略已解码内存、比例变化改变wrapper键、reader退出清共享图像缓存。已实施有界准备图稳定键与完成缓存复用、可见封面/滚动期间延后编码、1024宽度档及退出保留封面，单图先判文件也省无效检查。124项不同回归通过、15文件分析无问题；不是开启默认关闭的native encoded实验。

主力机同一插画首屏退出再重进，9张命中内存，原图读取/原生probe与解码/Flutter冷暖codec均0；来源验证1.101–6.877ms是阶段时间，不代表整页首帧。此前第一固定窗口包含新图，不能计算前后改善百分比。最终正常lib/main无计时开关Profile `AAB57CE1…` 经869源SHA/450编译输入核验、clean122.0秒构建后保留数据安装主力机f294cd23，版本9/1.9.92，首次安装时间不变；正常插画页面封面可见，VM转发已移除。详见 [冷/暖验证与产物](illust-cold-warm1007.md)。新图绝对性能/巨图冷解码和022其余完整门槛未验收，桌面继续暂缓。

## 当前接续 · 2026-10-07 15:34 · 插画加载滚动续修

用户继续反馈上一份包加载稍慢、滚动卡顿。本轮已消除 SliverLayoutBuilder 每scroll更新重建全屏卡片，磁盘暖PNG解码进入预算cover队列，大普通JPEG增加受限目标尺寸解码，后台PNG等待连续空闲400ms且恢复滚动时释放slot后重试。172项定向通过、6文件分析无问题。

主力机同页暖6swipe窗口：UI P95 7.154→4.491ms，max13.431→6.496ms，BUILD scopes2282→281；新255UI帧无processing超8.333ms，但raster P95 1.471→2.279ms、超预算1→2，不能宣称所有指标改善。新首次混合窗口仍有23.318ms（layout19.741）长帧，无GC/cover交叠，不归因二者。两个合格大JPEG确实走Flutter target，getNextFrame239.753/543.137ms不是呈现时间；归档暂存/特殊巨图仍慢，未做N30或峰值RSS门槛。

最终正常main/no userdefines Profile已核验并install-r主力机192.168.5.4:5555/serial f294cd23，保留首次安装时间2026-10-01 23:32:23，更新时间15:33:44。APK D:/picakeep-image-pipeline-022-work/picakeep-illust-scroll-profile1007.apk，61,841,065B，SHA256 D5250610FD7BEDA7217E43D1A071A58534EBCDB475BFFD8DFD8720753C00E328；870产品SHA与计时包/工作区一致，451compiler输入哈希一致，profile/version9/signature/CRC/maxgap0通过，native三ABI未改。正常首屏六张封面已查看，pid444错误过滤0，VM38123转发移除，其它转发未动。无release/uninstall/clear/commit/push。当前主力机就是此正常包；桌面仍暂缓，022仍执行中。

完整证据见 [插画滚动续修](illust-scroll-smoothness1007.md)。后续仍以用户实际体验为准；首次未知文字/geometry布局长帧、冷加载严格对照及完整原计划门槛开放，不依据本轮局部帧采样关闭022。


## 当前接续 · 2026-10-07 16:46 · 插画封面源件复制续修

用户明确仍慢的是图集入口内的「插画」瀑布流。本轮普通可读文件通过32字节可读/版本探测后直接进入已有有界缩略图解码，省去完整原件缓存复制；有效旧内部缓存仍优先保持缩略图身份。已经物化到统一covers的ZIP封面直接复用，避免第二次managed封面复制；未加密归档在核源可打开、指纹、索引及成员后先查缓存，密码/权限不确定仍保留旧验证回退。外部hint仅不写managed来源索引，通用toJson仍可包含它。不同定向回归128项通过、5文件分析无问题；早期helper编译和4项缺路径插件测试夹具均已修复，原失败日志保留。

备用机匿名样本经正常设置选应用自有任务目录，5原图+1双页ZIP逐个源SHA一致，实际6张封面均可见。有效首轮5个direct事件、6次codec，无source.read/store/persist整件暂存；仍有90.130ms可读探测长尾、ZIP首次提取568.911ms及codec13.846–292.462ms。返回重进6张memory命中，nativeProbe/冷暖codec/新缩略图解码均0，source.total1.353–6.063ms；不能把archive.extract1.320ms事件直接当成员读取次数。首次exec-in tar样本被截断并缺项的试验已作废，改adb push+run-as cp及所有源SHA复核。备用机Android10私有普通文件样本不替代主力机外部全部文件权限、用户作品或前后速度验收。

最终正常lib/main、无诊断define的Profile经隔离clean/offline pubget构建110.5秒，870产品源/快照SHA及451实际编译hash一致；APK [picakeep-illust-direct-source-profile1007.apk](D:/picakeep-image-pipeline-022-work/picakeep-illust-direct-source-profile1007.apk)，61,841,065 bytes，SHA `5AC40AE133DBE24CE2D1AB8C242A37614DBBCD8FF23D61C0B376F47339CC7B54`，1.9.92/code9、签名与native三ABI不变，ZIP CRC/间隙0核验通过。16:22:55显式主力机192.168.5.4:5555/f294cd23 install-r成功，首次安装时间不变；未启动或切换PicaKeep，既有com.dragon.read ReaderActivity前后完全一致。16:45:44备用机192.168.5.3:5555/8021129d install-r同正常包成功、PID7561正常主页可见，原下载计数3与历史11保持；正常UI恢复默认Pixiv路径且不迁移，任务样本逐项校验后移除、插画恢复为空。VM38123转发移除，原main6521保留。无卸载/用户数据清理/release/commit/push。

详见 [插画直接源验证](illust-direct-source1007.md)。当前两机均是本轮正常包；主力机真实新图体验仍待用户验证，大图codec和归档首次物化等待尚未消除，022仍执行中，桌面UI/性能继续暂缓。

## 当前接续 · 2026-10-07 17:45 · 插画长列表回看与配额排序

用户两份16:55 DevTools采样确认解码缓存接近192MiB、42次CoverDecodeKey和6次FileImage驱逐，以及最长9.809秒listener等待；CPU 24.29% inclusive样本含缓存候选排序，原逻辑即使无空间压力也在主isolate反复全量排序。未把listener时长当首帧呈现时长，也未将inclusive计数相加。本轮空间足够直接跳过排序，有压力时worker预计算路径rank并排序，删除授权仍在原isolate逐项检查。封面保持32MiB持久化clone预算，回看复用现有pending像素；已消费但超预算项进入256条元数据空闲补盘队列，暖PNG使用前台保留槽且持有真实可见工作claim。源版本/代次/取消/磁盘额度规则保留，并修await空闲时清队列的竞态。

最终冻结代码定向65项与配额库存41项均通过（共106项），7文件静态分析无问题。正常lib/main、无诊断define的Profile构建154.6秒；870产品输入SHA与快照一致，451实际compiler hash一致，version9/1.9.92、既有签名与native三ABI、ZIP CRC/间隙0核验通过。APK [picakeep-illust-return-profile1007.apk](D:/picakeep-image-pipeline-022-work/picakeep-illust-return-profile1007.apk)，61,906,601 bytes，SHA `BF217B139C1D639D01C75A17995F010B3053F104B511A3396B1AF0AA1EE0CD39`。主力机DHCP地址已改为192.168.5.12:5555，实际serial f294cd23；17:29:57显式install-r --no-start成功，首次安装时间2026-10-01 23:32:23不变，com.dragon.read ReaderActivity前后同一实例，原forward21173保留。

备用机96张匿名普通JPEG经正常UI进入插画，源件/数据库/manifest共98文件SHA全部一致，设置任务目录时未勾迁移。实际768×1152封面全量324MiB超过192MiB；初次重进15项memoryHit且冷解码0。实际端点096–088→009–001→096–088完成往返；一批7个逐swipe窗口33次warmFirstFrame、0冷backend，ImageCache实驱逐33次，warmFirstFrame15.182–46.831ms。另完整向下14窗口40次warm、回看14窗口40次warm，均0冷backend；帧/阶段配对无异常。每次swipe有2.5秒停顿和边界空闲，因此只证明超过RAM容量且补盘后正常停顿回看复用，不声称首次冷长列表无停顿立即反转已通过，也不把阶段时间当first-paint。暖UI/raster仍有超120Hz8.333ms预算帧，无同条件改前/改后比例；主力真实作品体验继续待用户确认。

17:43:41备用正常UI已恢复默认Pixiv目录，未勾迁移；清理前两份任务目录各98文件逐SHA核对，任务DB仅增加本轮96作品的schema/文件夹元数据，先备份并核PRAGMA integrity_check通过，再只rm明确namedfiles/alias、空rmdir，无递归删除、无cacheclear或用户DB修改。17:45:01备用机8021129d install-r同正常包成功，firstInstallTime不变，PID15743；两机均已交付本轮正常main Profile。原main forward21173保留，仅移除备用VM38123。本轮无release、卸载、用户数据清理、commit或push；022保持执行中，桌面验证暂缓。完整证据见 [长列表回看修订](illust-long-list-return1007.md)。

## 当前接续 · 2026-10-07 18:57 · 大图打开与分块补齐

用户提供 17:58 三次打开/CPU 捕获，明确主要慢在“分块补齐”。已确认 Painter 重复 variant 格式化和 JPEG header 小 IO 的主 isolate 样本，修为 immutable 层键复用、64KiB 有界 header 块扫描；未把 inclusive 样本相加或把 texture upload 次数当原图 decode。合格完整 SOF0/8bit/无 ICC/orientation1 的奇数尺寸 JPEG whole fit 使用 ceil(source/d) 的有界 IDCT，避免先写完整 RGBA backing；32 项原生回归、大源独立全 scanline 逐字节参考及既有 22 decode/方向/alpha/取消/源变化验证通过。native/session pixelVersion 递增，原像素 backing 格式未变，跨路径身份不合并。

备用机 8000×12000 PNG/baseline/progressive 固定网格六次 run、36 个 fit/ROI 样本全部完整/实际 FrameTiming。fit 512→1024 中位 PNG 1738.897→1585.638ms、baseline 4906.700→1598.928ms；progressive 未证明收益。固定 1024 原像素 ROI 明显更慢，故生产仅 PNG/已验证 baseline JPEG 的缩放用 1024，density1、progressive/未知 JPEG、远端保留 512，显式 harness 配置仍可覆盖。baseline hint 的源前后 size/mtime/ctime、encoded axes 和实际 SOF0 均核对，未知保守，预算及并发未扩大。

最终默认策略另完成 18 样本，fit desired PNG/baseline 6、progressive 24，全部原像素 desired15/native阶段[30,10,10]，全部完整、ROI目标可见、FrameTiming匹配、错误0、退出全部账0。最终 fit 中位 PNG1849.754/baseline1610.136/progressive11050.149ms，ROI中位330.043/987.906/291.379ms；baseline首次原像素升级4137.567ms仍慢。两批未控制OS cache/温度，不能声称PNG稳定提速、原像素端到端完全恢复或用户真实三图已通过。源码、分类、网格旧图连续性/迟到取消释放、disk预算回归及定向分析通过；多批存在重叠，不累计为不同测试数。

正常 `lib/main.dart`、无诊断define Profile clean/offline pub get 后构建120.4秒；872产品源/快照SHA、451实际compiler输入hash一致，三个native ABI与最终手机harness逐字节同一版本，签名/版本/ZIP CRC通过。交付 [picakeep-large-open-adaptive-normal-profile1007.apk](D:/picakeep-image-pipeline-022-work/picakeep-large-open-adaptive-normal-profile1007.apk)，61,906,601B，SHA `1DDA99859E657E50A0153F4551BB337F80DE058D0462B252822F05205FBAFDB0`，9/1.9.92。18:56:29主力192.168.5.12:5555 / f294cd23 install-r --no-start成功，首次安装时间不变，前后同一com.dragon.read ReaderActivity实例；18:57:05备用192.168.5.3:5555 / 8021129d install-r成功，正常MainActivity PID20149、主页历史11/下载3/图集0可见，启动错误筛查0。

备用两批 profile-options exact bytes恢复、fixture源SHA不变、cleanupErrors空，先恢复旧正常BF217B后再安装本轮最终正常包；当前两机都是新正常包。主力未启动PicaKeep、原forward21173保留；未卸载、清数据、改用户源件、release、commit或push。桌面实际UI/性能继续暂缓。详细依据见 [大图分块补齐验证](large-image-open1007.md)。后续优先定位冷backing与首次原像素升级关键路径，再用用户三图同素材捕获及N30验证；022仍执行中，不能以本轮fit分项完成宣布全计划达标。

## 当前接续 · 2026-10-07 20:03 · 瀑布流点入大图首幅

用户明确所有大图从插画瀑布流打开，有些快、有些首图仍慢。主力 settings[165] 只读确认插画 sharpFirst，未改设置。旧入口未带已显示 provider，且封面路径可能为内部副本。本追加经既有条目阅读工厂传入 prepared provider，单张普通文件核 work/page/URL/源 snapshot；精确原路径及现有指纹索引证明的内部副本可 clone。cache miss 不 resolve/不新增原图解码；多图、归档或绑定不明确回退。预览独立预算，不当原件/正式 complete、不污染 session/disk 原像素缓存。

无首次像素时请求泵仅放一个 estimate/decode，真正首 paint 后才放行其余块；初始 preview 跨 pan 保留，失败继续、迟到源代次/退出释放。回归发现 paint 前 pan 会误报首图，已在 post-frame 再核实际可见区域修复；模式切换保留旧图，已呈现会话换网格不重置首次限制。新 onFirstRasterPresented 与完整 onPresented 分开，各自 build 时间匹配实际 FrameTiming。

135 项 reader/原件操作/会话/卡片及源封面回归、6 项缓存桥接、6 项 Surface 缓存消费新增，共147不同用例通过；定向分析无问题。备用同一最终 profile APK、三种8000×12000、single/sharpFirst、默认 adaptive，两个条件都在请求计时外准备并消费768封面，只切借用，N3/条件，共18完整样本。首幅不借→借中位：PNG1018.932→27.889ms、baseline218.798→29.727ms、progressive13391.407→43.013ms；九借用首幅范围24.223–44.704ms。完整中位分别1633.977→1584.163、1652.210→1609.871、14403.567→14606.756ms；渐进补齐仍13.550–15.449秒，未证明改善。非借用首幅可能只是一个正式块，不是全图；这不是旧包/新包或冷封面N30，OS cache/温度未控制。

全部首幅/完整实际raster、errors0，surface/pending/jobs/working/temporary/original leases/native active/queued/disk active退出全0。profile-options原字节恢复、fixture host/device SHA不变、cleanupErrors空。正常 main/noDefines profile构建108.9秒，872产品源/快照SHA、451实际compiler hash一致；native三ABI与harness及上一自适应正常包逐字节相同，签名/版本/CRC通过。最新 [picakeep-large-open-first-normal-profile1007.apk](D:/picakeep-image-pipeline-022-work/picakeep-large-open-first-normal-profile1007.apk)，61,906,601B，SHA `C1BB13A72E01937BAB239AFA31722A0D79687EA44D7AF927CFF90793BAA1F895`，9/1.9.92。

19:59:17主力192.168.5.12:5555/f294cd23显式install-r --no-start成功，首次安装时间不变，前后同一QQ SplashActivity实例；20:00:25备用192.168.5.3:5555/8021129d显式install-r成功、正常MainActivity PID22690、客户端设置UI可见，该PID启动error/fatal过滤为空。最后两机均为此正常包。未卸载、清应用数据、改用户原图、release、commit/push；原main21173未操作，桌面仍暂缓。完整报告、原始18样本和身份见 [首幅画面续修](large-image-first-raster1007.md)。用户真实三图、渐进冷backing、首次原像素及全P0–P10仍开放，022保持执行中。

## 2026-10-07 20:55 · 用户要求阶段收束的最终回写

本版本全部行动已汇总到 [版本总记录](version-1.9.92-actions1007.md) 并同步三份长期交接与022计划事实/经验层。当前为**部分完成、阶段收束，后续暂停**，以本文件顶部最新状态为准；本次仅文档与本地只读核验，没有新增测试/构建/设备操作。最终两机正常C1BB包、原验收标准和未完成项保留，等待用户明确继续后再接续。
