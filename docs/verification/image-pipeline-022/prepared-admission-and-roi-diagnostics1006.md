# 022 · Prepared 准入与单步 ROI 诊断候选

2026-10-06，继续执行中。新增候选已补Android `single/sharpFirst` 单场景各30样本；Windows性能与手机完整六组合尚未补齐，不能代替v6的 `442.78–619.52 ms` 或宣布达到 `100–200 ms`。结果见末尾“Android v9准入单场景N30”。生产 `preparedReadAdmission` 和 profile `prepared-admission` 均默认 `false`；prepared read 本身也保持默认关闭。native 核心没有修改。

## 已实现的候选

已有完整原像素 backing 时，每 tile 的独立 native estimate 可以消除。Surface 只在持有原件 lease、绑定 `ReaderResolvedOriginal` 且 `verifyCurrent()` 成功后，使用 `32 MiB + outputRGBA + max(normalizedWidth, normalizedHeight) × 32` 的保守内存准入。native 的公式使用 encoded row width；EXIF 转置时 normalized width 可能更小，因此使用长边覆盖原 encoded width。

新调用只允许读已有 backing。native status 5 被转换为 `ReaderPreparedReadMiss`，没有在 warm 内存额度内创建 backing。旧 scheduler ticket 完成并释放 reservation 后，Surface 重新验证源、调用完整 estimate，再创建独立 cold ticket；磁盘 quota、临时 workspace、existing raw occupancy、source/backing lease 和 native 最终检查全部保留。源变化、内存不足、取消和非 status-5 错误不被隐藏。没有 resolved source 的 remote raster locator 不使用此捷径。

Flutter backend 只在其已经选择 native 的 tile 路线上支持此准入；whole Flutter codec、ICC 和默认 backend 路径保持自己的估算。要实际启用，须同时指定 `prepared-read=true` 和 `prepared-admission=true`。

单步 ROI 只新增独立 profile groups：`roi-onestep` 和 `roi-prepared-onestep`。每个目标仅一次 `PhotoViewController.updateMultiple(scale, position)`，等待实际完整原像素画面后检查 viewport source centre 距目标不超过 2 像素，再用真实 image build timestamp 匹配 FrameTiming。单步失败不执行补偿 pan 后冒充成功；原 `roi` / `roi-prepared` 两步组保持不变。连续布局仍在计时前将目标行滚入可见 viewport。

## 证据与契约复现

| 证据 | 观察 | 文件 SHA-256 |
| --- | --- | --- |
| E-001 | Surface 34/34 passed，新增 warm、miss、source-change、cancel、default 五组 | `build/picakeep-022-continuation/prepared-admission-surface-test.log` · `CFF8D8CBC2ACA7877950B5280033FD5C32C3F5005787213F1B554AEADB7CF480` |
| E-002 | native backend 5 passed / 1 missing-symbol 能力 skip / 0 failed；warm read RGBA 精确、无独立 estimate，status-5 miss 不写 backing | `build/picakeep-022-continuation/prepared-admission-native-test.log` · `9B75A302B20705F154F40C8F7272E348C2EF3B1D6E0ED6EE75A314F194042F9C` |
| E-003 | 相关 production、profile、test Dart analyzer clean | 下方完整 analyze 命令，2026-10-06 本轮实际运行 |

F-001：E-001 的 miss 测试在 cold estimate 时断言 scheduler `reservedBytes=0`，cold decode 获得新的 64 MiB 额度，之前的 warm decode 为 32 MiB。source-change 不 estimate、不 cold decode；取消不补提交；default 不尝试新 prepared 路线。这验证独立 reservation/source 所有权，尚不证明设备耗时改善。

F-002：E-002 使用固定 DLL `E:/picakeep-image-pipeline-022-work/prepared-read-native-build/Debug/picakeep_image_engine.dll`，SHA `039E09EAE0A232418865E7F308637712C9AAED2ACDEFC7A59AB75225B09114B4`。warm bound 大于等于 native estimate，真实 decodePrepared 不提交 estimate job，输出与同原件 native RGBA 完全一致。miss 时磁盘 space 适配器被设置为抛异常以阻止写准入，目录保持空、lease/quota 全零。

P-001 调用路径：绑定原件与 metadata → source lease + verifyCurrent → 保守 warm scheduler admission → 仅 native prepared read → miss 则释放 warm ticket → 再验证与完整 estimate → 单独 cold memory/disk admission → decode → source 再核验 → resident/presentation → 退出清理。对应证据 E-001、E-002。剩余风险为设备性能/OS RSS/单步实际控制器几何，需 root 的新 profile 包实测。

下列命令从项目根目录运行。独立 Flutter 测试进程不共享 runner DLL，也不构建/安装应用。宿主 sandbox 的 `.bat` 环境曾使 Dart 挂起，本轮通过已授权 routine verification 的执行环境完成；不是测试失败或应用挂起。

```powershell
$taskTemp = Join-Path (Get-Location) 'build/picakeep-022-continuation/test-temp'
New-Item -ItemType Directory -Path $taskTemp -Force | Out-Null
$env:TEMP = $taskTemp
$env:TMP = $taskTemp
dart analyze packages/picakeep_image_engine/lib lib/foundation/image_pipeline/reader_raster_backend.dart lib/pages/reader/reader_image_surface.dart lib/pages/reader/reader_page_image.dart tools/image_pipeline_022_profile_main.dart test/reader_image_surface_test.dart test/native_reader_prepared_read_test.dart
flutter test --no-pub --concurrency=2 test/reader_image_surface_test.dart
```

```powershell
$taskTemp = Join-Path (Get-Location) 'build/picakeep-022-continuation/test-temp'
$env:TEMP = $taskTemp
$env:TMP = $taskTemp
$env:PICAKEEP_IMAGE_ENGINE_LIBRARY = 'E:/picakeep-image-pipeline-022-work/prepared-read-native-build/Debug/picakeep_image_engine.dll'
$env:PICAKEEP_IMAGE_ENGINE_FIXTURES = 'E:/picakeep-image-pipeline-022-fixtures'
flutter test --no-pub --concurrency=2 test/native_reader_prepared_read_test.dart
```

## 同包对照选项

先在新 profile 包运行 `samples=1` 的 `roi-prepared-onestep` 全六布局/模式 smoke，核对 errors、missing raster、target/focus 与实际 raster；通过才运行 N30。新工具选项不可在旧 APK 里外推为生效。

所有组固定 `large=8000x12000-interlaced.png`、`tile-pixels=512`、`raw-sync=false`、`persist-raster=false`、`prepared-read=true`、`samples=30`、`layouts=single,continuous,double`、`modes=sharpFirst,previewFirst`。fixture SHA `AF84CBDFA6C67FF61CFBC8747BB0B5F33BBED0A267F1E7A8777D1C00F99FEC0D`。

| 对照 | groups | prepared-admission | 测量意义 |
| --- | --- | --- | --- |
| A | `roi-prepared` | `false` | 既有只读 decode 候选 + 原两步 scale/pan |
| B | `roi-prepared` | `true` | 保守准入省 estimate + 原两步 scale/pan |
| C | `roi-prepared-onestep` | `false` | 单步 controller 操作，保留独立 estimate |
| D | `roi-prepared-onestep` | `true` | 单步操作 + 保守 prepared 准入 |

Android `/data/local/tmp/picakeep-native-022/profile-options.json` 内容可使用下方 D 配置；A/B/C 只按表改变对应两个选项。Windows profile runner 接受同名 `--key=value` 参数。root 管理构建、APK 校验、显式设备 id 与 install-r，不执行卸载或清数据。

```json
{
  "groups": "roi-prepared-onestep",
  "large": "8000x12000-interlaced.png",
  "samples": 30,
  "layouts": "single,continuous,double",
  "modes": "sharpFirst,previewFirst",
  "tile-pixels": 512,
  "prepared-read": true,
  "prepared-admission": true,
  "raw-sync": false,
  "persist-raster": false
}
```

四组按同包/同源配对，建议交错顺序并记录各自源 SHA、runId、APK/EXE/AOT/native hash、OS file-cache 边界。`roi-prepared` 在计时外准备 backing，仍可能复用 decoded resident tiles。另用 `roi` / `roi-onestep` 测首 backing miss；其文件已被 fit 读过，不称为冷 source。所有 miss、取消、失败都保留，不从分布里删除。

## operation 计数与 OS 对齐

worker diagnostics 新增四种 operation 后缀 `Probe`、`Estimate`、`Decode`、`DecodePrepared` 的 `jobsSubmitted`、`jobsCompleted`、`jobsFailed`、`jobsCancelledBeforeExecution`、`workerExecutionMicroseconds`、`workerQueueMicroseconds`。新计数统计进入 pool 的 job；队列入口直接拒绝没有被记作已提交。native execution/queue 对收到 reply 的失败也计时；致命退出或启动失败没有 execution reply，不能视为零耗时成功。

每个 ROI sample 的 `nativeWorkerOperationDelta` 是 request 到完整 presentation 的计数差，包含该窗口内的后台真实工作；`rasterStages` 另保留 `preparedAdmissionEstimateSkipped`、`preparedAdmissionUsed`、`preparedAdmissionMiss`、`preparedAdmissionColdRequeue` 和内存 bound。worker 总计数是进程累计；不可把所有 job 归为 estimate。summary 尚未聚合 operation delta，可从 samples 离线求和。

仅 lifecycle 可指定：warmup cycles `0..10`、baseline seconds `0..60`、exit idle seconds `0..30`、tail seconds `0..60`；全部默认 0。可选 `3/20/3/20` 每组增加 3 次计时外 warmup、closed idle baseline、每次退出 idle 与末尾 idle，原每 layout/mode 的 10 个 measured cycles 不变。所有 phase 保存 same PID、UTC、TimelineUs 和内部 diagnostics，并打印有界 `PICAKEEP_022_LIFECYCLE_PHASE`。

```json
{
  "groups": "lifecycle",
  "baseline": "3000x4000.png",
  "samples": 30,
  "layouts": "single",
  "modes": "sharpFirst",
  "prepared-read": false,
  "prepared-admission": false,
  "lifecycle-warmup-cycles": 3,
  "lifecycle-baseline-seconds": 20,
  "lifecycle-exit-idle-seconds": 3,
  "lifecycle-tail-seconds": 20
}
```

`lifecyclePhases` 的 `event=closed` 是每次退出即时 diagnostics；有 exit idle 时 `lifecycle[].afterExit` 为 idle 后 diagnostics，`idle-end` 标记可对齐 OS。默认 0 时仍直接记录退出状态。旁路 OS sampler 由 root 启动，读取 smaps_rollup / WorkingSet；工具不会将 Dart 极低 RSS 当作合格，也不自行宣称十轮增长门槛已通过。

## 源码冻结

以下为性能 owner 冻结时 SHA-256。backend 同文件还含 precision owner 的 integer crop 修复；其后缓存版本更新需以 root 最终 snapshot manifest 为准，不能用本表替代最终构建 manifest。

| 路径 | SHA-256 |
| --- | --- |
| `packages/picakeep_image_engine/lib/src/worker_pool.dart` | `59B0C9942F5FA6E2A0E111273F8C128FFCB91F8F5055975678A6A3831CCB48C2` |
| `lib/foundation/image_pipeline/reader_raster_backend.dart` | `FB43E2CA74D9946EEE14E93B2C1988EECBB9E62DDB42CA09F39D42C057EED89A` |
| `lib/pages/reader/reader_image_surface.dart` | `2D31902271B2547D8B127535469C03E03A68E9C35AFC656921688AF1E708DE6E` |
| `lib/pages/reader/reader_page_image.dart` | `06BC2FC4087D916DB2D28A012F3530B878CCDC0A62E4281D51BF68C52251814F` |
| `tools/image_pipeline_022_profile_main.dart` | `FB002192500049A1AE32D91D35D8B0F0C5672E8EF8E3F6AE4C7901B91A0AEC5C` |
| `test/reader_image_surface_test.dart` | `513B39D1F7F2B341B8FEDCBE8ACC1AFA6EDFDC4874E743D3E24969C8637D1E2F` |
| `test/native_reader_prepared_read_test.dart` | `1EDE59F0AB8D2BB309CC91E48865DF8629F1288DA8C202626C58C2494F9E7FD5` |
| native core，未改 | `9110413EEAE496707CDF3239C4F4371BBE060C42430976EE3E79613824834087` |

## 后续 native 去重观察

只读源码 review 发现：`decode_region_impl` 在 shared backing lock 内已经执行 `make_header(path, info)` 与 `backing_matches(backing, before)`，随后 `estimate_working` 又读取 source fingerprint 与 backing header。可以在 `backing_shared=true` 时直接使用 native warm 公式 `32 MiB + outputRGBA + before.width × 32`，继续保留 inspect、锁内首次校验、读取后 source/header 校验、cancel、available-memory 检查与 cold 分支。此项仅为后续候选，当前未编辑或构建，不能计作已有性能收益。

## Android v9准入单场景N30

2026-10-06在备用机 `8021129d` 使用同一Android profile APK、同一8K×12K interlaced PNG fixture（SHA `AF84CBDFA6C67FF61CFBC8747BB0B5F33BBED0A267F1E7A8777D1C00F99FEC0D`），各跑30次 `single/sharpFirst`。两组都启用 `prepared-read`，只切换 `prepared-admission`；其余固定为单步ROI、512像素tile、`raw-sync=false`、`persist-raster=false`。这是窄范围手机对照，不代替六布局/模式全矩阵。

| 对照 | 报告 | presentation p50 / p95 / p99 | 帧超预算 | 样本与错误 |
| --- | --- | --- | --- | --- |
| 准入关闭 | [reader-v9-admission-off-n30-redmi1006.json](reader-v9-admission-off-n30-redmi1006.json) · `326A202114F5CEAE935AC3510E2BDE6719AE384F9C882F6E9792188C7CB626BC` | 194.752 / 268.082 / 272.174 ms | 85/572（14.86%） | 30/30呈现，无missing raster，errors=[] |
| 准入开启 | [reader-v9-admission-on-n30-redmi1006.json](reader-v9-admission-on-n30-redmi1006.json) · `B58BDB17FD065ED8302A439CD06F2374000DA377D9581A2C3448EBA2C203B51D` | 197.528 / 247.142 / 251.622 ms | 82/557（14.72%） | 30/30呈现，无missing raster，errors=[] |

本组on相对off的presentation中位数约高1.4%，P95约低7.8%。30个计时样本内，off提交350个Estimate与350个DecodePrepared；on提交0个Estimate、350个DecodePrepared，准入使用350次、估算跳过350次，miss与cold requeue均为0。两组结束时resident、jobs、lease、working/temp reservation与disk quota均为0。进程累计code5计数不等同于该计时窗口的admission miss；窗口数据和错误列表均保留在原始报告。

这只能说明该手机单场景减少了重复估算工作，端到端中位数没有改善，P95有一定下降；不是整体速度验收。性能候选继续默认关闭。Windows/Desktop没有在本续测中验证，需分别跑平台测试后才能形成桌面结论。
