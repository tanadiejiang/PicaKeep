# 022 派生空间准入与原文件链路验收

2026-10-06。此记录覆盖 Dart 空间准入、真实 HTTP 原文件流、任务隔离的 Windows 组件验证和远端封面尺寸。正常应用 GUI、手机相册保存、系统分享投递以及新手机上的实际磁盘压力，须以主任务单独记录为准。生产源码已冻结；不把较早快照的手机性能数据当作本次空间准入验收。

## 已落地的边界

所有图片写入在首次写文件之前，查询目标卷对当前调用者可用的真实空间。Windows 保留 512 MiB、Android 保留 256 MiB 余量；查询失败或旧 DLL 不含可选 query 符号时明确拒绝，不能把“不支持”解释为无限空间。原生查询是只读操作，不创建目录或更改原图。

| 账目 | 范围 | 上限与转移 |
| --- | --- | --- |
| 持久空闲缓存 | App cache、data/cache、注册的派生目录、可再生封面；不包括用户原下载 | 使用现有 `cacheLimit`，默认 500 MiB，无新增设置或静默扩额；发布前计入尚未落盘的持久承诺 |
| 活跃工作区 | 原文件流式物化、原生 RGBA 背板、渐进 JPEG 系数、PNG 精度临时文件及发布过程 | 延续 2 GiB 有限工作区；同一路径多个活跃持有者合计使用最大峰值，不重复计算同一文件 |
| 真实卷余量 | 未落盘预留及下一次写入增量 | 已实际写入的文件已占用 OS free，不再次扣除；仍未落盘的峰值从可用空间扣除 |
| 转为空闲 | 原生调用与最后一个画布持有者完成后 | 放入现有空闲 LRU 并立即裁剪；活跃的两份 96 MP RGBA 可超过 500 MiB 空闲额度，但仍受 2 GiB 活跃硬上限和真实余量约束 |

Windows 通过实际卷 ID 合账，包括路径跨 junction 后的实际卷。Android `st_dev` 只代表逻辑文件系统；真机已发现 `/data` 与 `/storage/emulated/0` 的 ID 不同但共享 userdata 容量。因此 Android 对所有逻辑域的未落盘承诺共同扣除，再查询每个目标自身的余量，不能凭不同 `st_dev` 新开独立容量池。

准入覆盖 cover 三个 PNG 入口、本地封面复制、远端封面下载、在线原图缓存、ReadingData 原文件物化、归档密码验证、server 输入 staging、native reader/idle/renderer 与 DerivedImageStore 发布。文件生成前后保留来源身份、取消信号、文件 lease、generation 检查和原子重命名；用户原图、下载文件不进入可删除候选。

## 原生工作区估算

背板按编码尺寸计 `128 + encodedWidth * encodedHeight * 4`，不是每项固定预留 1 GiB。能够走 native 无文件的 baseline JPEG ROI 或非交错 PNG whole fit 时不申请原生背板空间。已有背板缺少公开的“在 native 锁内验证 readiness”接口，因此保守计入现存文件和可能的新背板，不能根据单纯 `exists()` 直接抵扣或删除旧文件。

渐进 JPEG 解析实际 SOF 分量采样因子：`ceil(width / (8 * maxH)) * ceil(height / (8 * maxV)) * sum(H_i * V_i) * 128`，再留 256 KiB 系数文件头余量；准入取这个 MCU 上界与 native writer 的 `pixels * 6` 物理保护值的较大者。未知采样保守按双轴 32 像素对齐、每像素 8 字节计。此前单用 `pixels * 6 + 256 KiB` 对极窄图的 MCU padding 不构成上界，本次已修复。交错 16-bit ICC PNG 另计 8 字节/像素精度工作文件。

## 证据、发现与路径

| 证据 | 不可变观察 | 结论与位置 |
| --- | --- | --- |
| E-Q01 | `image_disk_quota_test.dart` 14 项均通过：同卷承诺、已写字节不重复扣、Android 别名共扣、活跃背板转空闲、替换峰、并发发布、共享持有者、低空间拒绝、根切换、未知 registry fail-closed、全局 LRU lease | F-Q01：真实余量、持久配额与活跃峰需要共同准入；`image_disk_quota.dart` |
| E-Q02 | 最终相关集成 74/74，0 skipped；随后独立核心重跑 71/71；包含缓存/流式 ZIP/服务 HTTP/响应取消/调度/renderer 预算 | F-Q02：源 staging、native 作业及派生发布已共用准入，失败不留下成功条目或预算；`disk-quota-source-integration-final-verified.log`、`disk-quota-core-final.log` |
| E-Q03 | 真实 JPEG/ZIP × 三布局 × 两模式，14/14；12 完整工作流、39 记录、36 次保存/分享/收藏输出哈希一致，原始匿名素材 size/mtime/SHA 不变 | P-Q01：真实 ReadingData → 原字节 → 同进程 LocalServerRuntime/native HTTP → 完整 ComicReadingPage → 原文件操作 → 退出释放；`real-source-remote-workflow-quota-final.json` |
| E-Q04 | 第一次实际低空间运行 11 passed / 3 failed，画布已有正确 tile，但 favorite 失败；日志保留 `last=磁盘剩余空间需保留余量`，C 盘余量约 1.22 GiB | F-Q03：通用原文件流丢弃 HTTP Content-Length，每份几 MiB 输入按 512 MiB 预留，两份并发正确触发余量保护；不是图像变糊或死锁 |
| E-Q05 | 新 HTTP 测试在只够一份真实正文的余量下连续 4 次精确长度物化通过；余量设为 0 后 4 个已收到头、正文停住的响应在 2 秒内拒绝；恢复后继续读完整原字节 | F-Q04：Remote ReadingData 使用 declared bytes 准入，途中限额且结束核实际长度；拒绝/取消必须 abort 请求并取消响应流、幂等释放 permit；未知长度继续旧 512 MiB 上限 |
| E-Q06 | 1×3000、3000×1、1×30000、30000×1，各 4:4:4/4:2:0 progressive 共 8 次 native 成功；30,000 极窄图准入 1,822,272，native 实际峰 120,128，原 SHA/mtime 不变 | F-Q05：SOF/MCU padding 估算修复已通过极窄输入；本组 64 MiB 内存足以保留系数，实际系数落盘未发生，不能声称已实测全部 spill 峰值 |
| E-Q07 | 远端封面真 HTTP + 真实 ImageProvider 解码 3/3；同 URL 300×225 → 1200×900 → 重复小档 → 2000×1500，实际 image 尺寸一致，请求依次 `w=384`、`w=1536`、原 URL，缓存 3 个独立文件 | F-Q06：远端不能固定取 768；卡片物理两轴/BoxFit 必须进入 encoded variant 与缓存身份。landscape cover 高度不足升档，contain 留小档；高于所有 advertised 档取原图 |
| E-Q08 | E-Q07 加 HTTP 12、server boundary 6、quota 14，合计 35/35、0 skipped；涉及最终 Remote/target/provider/test 静态检查 `No issues found` | P-Q02：CoverDecodeTarget → CoverTargetProvider → Remote 实际尺寸 → advertised 档或原文件 → 独立版本缓存 → Flutter 两轴下采样，避免放大旧 768 字节 |
| E-Q09 | writer/quota 回归 63/63：共享封面索引独立准入且拒绝时保留旧索引/手工文件；ZIP 源替换时复制与解压均受观察到的原始长度限制 | F-Q07：索引与 server staging 不再有固定上限之外的无账写入；`final-writer-quota1006-verified.log` |

失败日志不会覆盖通过日志。早期未显式使用最新 native DLL 的测试以 `无法核验该磁盘可用空间` 拒绝，这是旧库不含空间 query 的明确行为；后来 unit/protocol 用显式 task volume fixture，真实来源组使用新的独立 DLL 和实际 OS query。单元 fixture 不计作 OS 空间查询实测。

新增 quota prefix lease 曾让 DerivedStore 自己的失败 `.part` 被识别为受保护文件，独立 `clear invalidates in-flight publisher` 回归捕获；现清理仅忽略该写入自己的 1 份 prefix protection，其他 reader/store owner 的 lease 仍有效。修复后该组及最终 74 项均通过。

## 证据文件

所有日志位于 `E:/picakeep-image-pipeline-022-work/`；体积很小。匿名原始素材沿用既有只读副本，没有再次访问主力机。

| 文件 | SHA-256 |
| --- | --- |
| `disk-quota-source-integration-final-verified.log` | `0bfbd0c8f8a5dcbdda2e0d508da5fad57bcc266d5b4da51d473b873781482a74` |
| `disk-quota-core-final.log` | `18770cebf46e2c46376d97e34179a2270da8f48a83f4f3cdeda8ddb25446b8ac` |
| `disk-quota-real-workflow-final.log`，保留低空间失败 | `7daf53b71f24921a064f6041f76fcc9ab30063cb3fda99e85602be9b1782cb49` |
| `disk-quota-real-workflow-recovery.log`，真实闭环恢复 | `aac3cc958503cabbaeefec9f4872da062a1323ecd06b10da1cbc10bec1e1c504` |
| `disk-quota-native-thin-progressive.log`，3,000 组 | `135fe00f4cc0b5476306a84be3aa51b07fd46d58c750a5dc8c9743de2747433b` |
| `disk-quota-native-thin-30000.log`，30,000 极窄组 | `0f420f65c091cfd16666cc51d662622a37974033caa7706633d36612e80bfcc7` |
| `remote-cover-source-quota-final.log` | `d047ef64d1e037a618afdb171de797155ad31ec51c569f4282a9adce0a043b1c` |
| `remote-cover-target-regression.log`，3/3 | `4bc426e760c604dd27b0704038623401fbccc44f0b4d3c3560203ceff81f1cb5` |
| `source-remote-unified-quota-final.log`，真实来源14/14 | `c69ae15c4360bf436ae0de521fbbaa159d551ba481209384409e9f2e516bfaab` |
| `final-all-tests1006.log`，2845 passed / 18 skipped / 4 failed，保留中途版本与清理失败 | `381f05d752979920f8561ab9ba63de169b1acf8c9bc5078a0f84bbc8e170bade` |
| `final-native-ownership-plan1006.log`，77/77、0 skipped | `854a964d694d6c1b85a3fa7bebc8254fbd2be41524ae56a1d55c55eef7d7fd18` |
| `final-writer-quota1006-verified.log`，63/63、0 skipped | `816279799698c0cf6c6da8f347d5332fb05feded4cf6046dc4741cf18bfc4a05` |
| `final-pure-dart-core1006.log`，101/101 | `e5dc70845ddf5799f376fced4f8b03f9fd2f879e466fc3c499b8b6b4cd6428de` |
| `final-all-tests1006-verified.log`，2857 passed / 14 skipped / 0 failed | `3d27556f74e4cb423759756df86d9b5ed0ee256d6b159e249f67c5c20541eb9b` |
| `final-analyze1006.log`，lib/test/tools/native Dart 全范围静态检查 | `a103b1fcc987cec77b60b2c15c77764e85361d8d9e8ec12fe83637e32c1b73be` |

最新空间 query DLL：`E:/picakeep-image-pipeline-022-work/test-native-library/picakeep_image_engine_disk.dll`，SHA-256 `2b4b6caf2cbfe51701e1623700fc81a2de7b514e64c5486f86eb18964c392f11`。测试使用该独立 DLL，不锁随后构建的 Flutter runner。native 图像核心像素版本保持既有冻结版，空间 query 是附加 ABI1 可选符号。

本轮最后补充的两个写入边界也已冻结：server 对本地原文件、归档源暂存和归档成员解压传入各自已准入的 stat/central-directory 长度，并在交付前再次核对物化长度；共享 `covers_index.json` 使用独立的持久 publication ticket，只登记索引本身，`.part` 受保护，手工封面和下载原件仍不属于可删除候选。

最终 progressive 估算还用实际 3000×3000 SOF2 4:2:0 输入复核，测试解析输出的采样因子确为 `0x22,0x11,0x11`；原 native writer 像素保护值为 54,000,000 字节，准入 90,262,272 字节，native 实际 disk peak 63,144,320 字节（包含真正的渐进系数 spill），完成后 raw 长度 36,000,128，输入 SHA/mtime 不变。这次 native 5 项和所有权/画布/交接/空间边界组合共 77 项通过，0 skipped。

全量 `flutter test --no-pub --concurrency=1` 运行 9 分 8 秒，2845 passed、18 skipped、4 failed。两项所有权新测试先于对应修复被编译进该轮 runner，已在最终 77 项组合重测通过；本地封面 resize 与 ServiceInfo GUI 两项在 native worker 的 10 秒空闲 Timer 清理上失败，fixture 增加明确卸载、原生作业 drain 与 shutdown 后，4 项组合和 writer 63 项组合均通过。该全量日志仍计为失败证据，不宣称它是最终全绿；18 个 skip 中 13 个是既有 Windows 特殊目录、1 个是既有 explore fixture，4 个 native thin 是该轮误设 `_ROOT` 环境名而不是 `_FIXTURES`，已在最终 native 5 项独立启用且均通过。

writer 第一轮日志 `final-writer-quota1006.log` 的 61 passed / 1 failed 是新 ZIP 失败收尾测试错误地要求全局暂存归零；此前 warm ZIP 仍合法持有 3257 字节。更正为恢复调用前的预算/claim baseline 后，最终 63 项全通过。没有通过扩大 quota 或删除原文件绕过该断言。

随后完整冻结版本全量重跑 `final-all-tests1006-verified.log` **2857 passed、14 个既有平台 fixture skipped、0 failed**，11 分 27 秒，进程 exit 0。4 个 native thin 加普通 4:2:0 progressive 均实际启用；真实远端 JPEG/ZIP 工作流记录 `docs/real-source-final-fullsuite1006.json` 仍为 complete=true、12 完整工作流、39 记录、sourcesUnchanged=true。`dart analyze lib test tools packages/picakeep_image_engine/lib` 为 No issues found。此全量结论对应 writer/guard 最终冻结版；其后新增 opt-in cover 或 export 暂存变动必须用自己的验证记录，不能借用本次全绿。

远端封面首次生产 freeze 后再跑真实素材，`source-remote-unified-quota-final.log` **14/14、0 skipped**，43 秒；`E:/picakeep-image-pipeline-022-work/docs/real-source-remote-workflow-unified-quota-final.json` 仍为 complete=true、completedWorkflows=12、records=39、sourcesUnchanged=true。这次 TEMP/TMP 明确在 D 盘任务目录，不再因为 C 盘临时物化余量影响成功路径。该轮 production/source/quota/remote/新增测试 9 项静态检查 `No issues found`；其后的 writer 精确上限、共享索引和 progressive guard 收敛单独以本报告最终 63/77 项及主任务下一统一 snapshot 为准。最终 writer/plan 与对应测试 8 项静态检查也为 `No issues found`。

## 可复跑

### 原图导出临时复制补充（2026-10-06）

`save_image.dart` 的格式识别临时副本现按原文件 stat 长度，在实际临时目录所在卷调用 `ImageTemporaryPool.reserveOnDisk`；复用已有有界复制 API，源增长不能超过准入长度，复制后核对源 size/mtime 和副本长度。临时副本、原文件 lease 与空间 ticket 保持到系统分享调用实际返回，再在取消、失败和完成路径统一释放。最终用户选择的保存目的地/系统图库仍是用户输出，不进入应用缓存淘汰额度。

补充 `original_export_disk_quota_test.dart` 四项覆盖低磁盘拒绝、分享取消、系统插件失败、复制中源增长。与原文件操作/特权有界复制/真实远端 JPEG-ZIP 阅读闭环一起 **34/34、0 skipped**，1 分 52 秒、exit 0；两个修改文件静态检查 No issues found。分享/文件选择系统对话框仍使用 channel mock，真实原生交互由正常 UI 入口另验。

- `save_image.dart` SHA-256 `a981a1e280e203777eb9de1a9d4315cdd6f94927af3e1e7fd3f303fe0b0d49d0`。
- `final-export-quota1006-verified.log` SHA-256 `4f20e3d9b02dd45fd6ba293e0f11e0cb871fbe91518dbcb5894619184ced28c3`。
- 首次日志 `final-export-quota1006.log` 保留为失败证据：并行 cover 构造函数编辑中导致编译失败，0 项测试运行；编译窗口冻结后重跑得到上述 34 项通过。

在项目根使用 debug/profile DLL。相关单元/HTTP 测试不依赖用户素材；真实素材组须有本报告匿名 SHA 相同文件。下面的 TEMP/TMP 只影响该终端的测试临时文件，避免继续挤 C 盘。

```powershell
New-Item -ItemType Directory -Path D:/picakeep-image-pipeline-022-work/test-temp -Force
$env:TEMP = 'D:/picakeep-image-pipeline-022-work/test-temp'
$env:TMP = $env:TEMP
$env:PICAKEEP_IMAGE_ENGINE_LIBRARY = 'E:/picakeep-image-pipeline-022-work/test-native-library/picakeep_image_engine_disk.dll'
flutter test test/image_disk_quota_test.dart test/cache_file_inventory_test.dart test/server_reader_boundary_022_test.dart test/image_work_scheduler_test.dart test/archive_streaming_original_test.dart test/derived_image_store_test.dart test/image_protocol_http_test.dart test/remote_service_transport_lifecycle_test.dart test/flutter_reader_raster_backend_test.dart test/image_derivative_job_budget_test.dart --reporter expanded
flutter test test/remote_cover_target_test.dart --reporter expanded
$env:PICAKEEP_022_REAL_SOURCE_ROOT = 'E:/picakeep-image-pipeline-022-work/real-download-source'
$env:PICAKEEP_022_REMOTE_WORKFLOW = '1'
$env:PICAKEEP_022_SOURCE_REPORT = 'E:/picakeep-image-pipeline-022-work/real-source-quota-recheck.json'
flutter test test/real_download_original_workflow_022_test.dart --reporter expanded
```

极窄合成 fixture 生成入口 `tools/image_pipeline_022_make_thin_jpeg.py` 使用现有 Pillow，拒绝覆盖已有文件；fixture 不是用户下载。native thin test 需显式 `PICAKEEP_022_THIN_JPEG_FIXTURES`；30,000 组另设 `PICAKEEP_022_THIN_JPEG_LONG=1`，使用已经生成的 `quota-thin-fixtures`。未指定 fixture 时明确 skip。

## 证据边界

- Windows 完整阅读器使用实际生产组件、SQLite 和真 HTTP，但保存路径与系统分享投递仍由替身捕获；不声称原生对话框或手机分享 UI 已测。
- 每次删除前重验当前 roots、ownership、lease、手工封面保护、文件 stat，并检查到 managed root 的父目录都不是链接。外部进程在检查与系统 delete 之间替换父目录的极短竞争仍不能由 Dart 路径 API 原子消除，不宣称具备操作系统句柄级隔离。
- 查询时的 OS 余量不是对其他进程的磁盘锁。其他程序抢占空间仍可能造成 native 或 IO 失败；失败不得替换原图，自己的半成品在 finally 收尾，实际未删文件继续占账。
- 现有已验证背板 readiness 未公开，warm 路径保守重算可能拒绝本来不需要重建的工作，不通过盲目删除或扩大用户缓存额度规避。
- unit/protocol tests 显式 deterministic task volume 用来隔离宿主盘压力；真实素材恢复组使用实际 OS space query。D/E 两盘目前也需持续留意任务构建产物，图片 quota 不负责删除 Flutter/SDK build cache。
- 本记录不以 widget pump 秒数当性能指标；手机速度、1:1 放大画面质量与正式 GUI/headless 入口由主任务继续验收。
