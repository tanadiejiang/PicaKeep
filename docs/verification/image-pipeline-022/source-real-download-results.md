# 022 真实下载来源样本记录

本次只完成真实输入取样、只读复制和完整性检查。没有把复制成功当作阅读器、权限 MethodChannel、三布局动画或保存/分享/收藏 UI 的验收成功。

## 输入与权限状态

主力机为 `192.168.5.4:5555`，空闲 Redmi 为 `8021129d`，所有 ADB 命令均显式指定设备。先依据项目读取侧的下载根规则，仅抽取主力机当前设置中与下载目录有关的字段，确认在线漫画和 Pixiv 使用配置的外部下载根；没有导出设置、账户、Cookie、令牌、书名、作者或文件原名。默认应用私有下载根仅有下载数据库和队列，未从数据库导出整库。

主力机已有 `su -c id` 返回 `uid=0`；应用自身 Root / Shizuku 设置仍为 `0`。本轮未改变这些开关、未请求新授权、未查看账户凭据、未安装或启动主力机应用。取样只搜索已确认的两个下载根，限制目录深度、候选大小，并选取一张非封面正文页及一个 ZIP；没有递归导出整个漫画库。

新机本轮先前实际 profile 状态记录 Root / Shizuku 均不可用。复制过程没有重新请求权限、没有安装、启动、停止或重启该机应用；只创建并写入任务目录 `/data/local/tmp/picakeep-image-pipeline-022-real-source`，不打断当时进行的 cover profile。新机资料目录、图库、下载记录、用户设置均未改动。

## 匿名样本与完整性

原文件名只在取样脚本内用于读取。报告仅使用匿名编号，源定位另以 SHA-256 表示，不在文档中披露个人内容名称。

| 样本 | 来源类别 | 实际格式 / 尺寸 | 字节数 | SHA-256 |
| --- | --- | --- | ---: | --- |
| `page-001.jpg` | 在线漫画已下载正文页，排除 cover | JPEG / RGB / 1062×1500；1 帧；无 ICC；EXIF 方向 1 | 504,752 | `d5dec8bd5d19d8170b21a725c4b4e025751f1b22ed9ac6f62293c51e83aef690` |
| `archive-001.zip` | Pixiv 已下载多页产物 | ZIP；3 个 PNG 成员；无加密；stored 压缩方法 | 14,486,148 | `0d65012191602d018fcb14b5fb909c7da74691365b468d90e3c89e92377ccd35` |

两个样本均从已有 Root 的只读 `cat` 通道复制到 E 盘，再推送到新机任务目录。主力机复制前后分别计算文件大小、mtime 和 SHA-256，三者都一致；E 盘和新机 SHA-256 与源一致。没有移动、重命名或删除主力机源文件，也没有改其下载状态。

ZIP 的中央目录检查得到 3 个成员、全部为图片，总未压缩字节数 14,485,860；首个成员实际 PNG 3007×4629、1 帧，成员大小与 stored 大小均为 4,916,814 字节。独立 Python `ZipFile.open` 按 64 KiB 分块读完这个成员并完成 CRC 校验，SHA-256 为 `8811fe1a50a009f754b59cc169e73f3a506564baba77b6415ae127856f753ffe`。这个事实验证样本本身及传输后的 ZIP 成员完整性；尚未执行应用 Dart ZIP 后端或 `ReadingData.resolvePageSource` 的该真实文件验证。

| 位置 | JPEG | ZIP |
| --- | --- | --- |
| E 盘匿名副本 | `E:\picakeep-image-pipeline-022-work\real-download-source\page-001.jpg` | `E:\picakeep-image-pipeline-022-work\real-download-source\archive-001.zip` |
| 新机任务副本 | `/data/local/tmp/picakeep-image-pipeline-022-real-source/page-001.jpg` | `/data/local/tmp/picakeep-image-pipeline-022-real-source/archive-001.zip` |

匿名 JSON 清单位于 `E:\picakeep-image-pipeline-022-work\real-download-source\manifest.json`。辅助脚本为 `tools/image_pipeline_022_copy_real_source.py`；本轮已完成取样，不需重复读取主力机。

## 下一轮直接使用

明天先用已有匿名新机副本，不必再次连主力机。下面只读验证这两个副本；不运行设备上的应用：

```powershell
adb -s 8021129d shell sha256sum /data/local/tmp/picakeep-image-pipeline-022-real-source/page-001.jpg /data/local/tmp/picakeep-image-pipeline-022-real-source/archive-001.zip
```

阅读器 benchmark 现有 `baseline` 参数可直接指定真实 JPEG。准备新一轮独立配置时，保留合成素材根用于质量检查，把真实 JPEG 作为 fit / 基线 / 生命周期的输入：

```powershell
$sourceOptionsPath = 'E:\picakeep-image-pipeline-022-work\real-download-source\reader-options.json'
@{
  groups = 'baseline,fit,lifecycle'
  baseline = '/data/local/tmp/picakeep-image-pipeline-022-real-source/page-001.jpg'
  fixtures = '/data/local/tmp/picakeep-native-022'
  samples = 30
  layouts = 'single,continuous,double'
  modes = 'sharpFirst,previewFirst'
  'cache-mode' = 'cold,warm'
} | ConvertTo-Json | Set-Content -LiteralPath $sourceOptionsPath -Encoding utf8NoBOM
adb -s 8021129d push $sourceOptionsPath /data/local/tmp/picakeep-native-022/profile-options.json
```

以上配置需要已核验的最新 reader benchmark **profile** APK，且应在本轮 cover 运行结束后由主任务统一安排启动。它只使用 benchmark 独立 data/cache 路径，不读写正常应用库和设置。APK 若需重建，沿用主任务独立构建快照与 E 盘产物约束，禁止 release、卸载或清数据。当前没有 `archive` benchmark group，不能通过填一个未实现的组名声称 ZIP 已验。

后续待验：真实 JPEG 三布局 × 两模式的冷/热首显、1:1 原像素按钮和放大焦点；真实 ZIP 经应用流式成员提取 → 原文件来源 → 阅读画布 → 保存/分享/收藏的哈希闭环；超限与取消时半成品清理；缺失权限状态明确提示与重试。当前 Root copy MethodChannel helper 只对显式 `source-copy` 组运行，具备 Root 的任务设备才测实际 stat、64 KiB 复制、超限拒绝和 SHA-256；新 Redmi 的 `rootUnavailable` 不能记为通道已测通过。Shizuku 也须以真实 binder 和 permission 状态为依据，不能凭包存在推断可用。

本次结束时，主力机源内容、mtime、下载状态与权限设置保持原状，未启动应用；空闲机仅增加上述独立任务目录及两个副本，没有安装或启动应用，没有改用户库/设置/图库。按主任务要求，样本已足够本轮收束，未追加真实 UI、权限或阅读性能测试。

## 2026-10-06 · 真实来源、完整阅读器组件与服务客户端闭环

本轮完成 Windows Flutter widget 环境中的真实来源与原图操作闭环；使用现有 E 盘匿名副本，不再连接主力机。完整 `ComicReadingPage`、实际元信息/Flutter raster、SQLite 图片收藏、保存文件与分享输入均走生产调用链。系统保存路径选择和系统分享投递由捕获替身接收；不能据此宣称 Windows 原生保存对话框、手机分享面板或真机正常应用 UI 已验。

真实 ZIP 的 3 个图片成员实际是独立 `cover.jpg`（内容为 PNG）与 **2 个正文 PNG**；此前记录的 3 个成员不等于 3 页正文。`LocalPathReadingData.loadEp` 正确排除封面。本轮发现正式 server scanner 直接列出 3 页；已通过统一 `archiveReadingPageUris` 排除单独封面，并保留只有封面的归档仍可读一页、章节顺序、密码及封面选择语义。真实 server 客户端再次验证正文页数为 2。

| 证据 | 实际结果 | 位置与边界 |
| --- | --- | --- |
| E-S01 本地真实来源 | 5 个隔离路径测试 + 13 个真实来源/完整阅读器测试，18/18 通过；JPEG 1 页、ZIP 2 正文页均哈希匹配 | `real-source-full-workflow.json`；日志 `E:\picakeep-image-pipeline-022-work\real-source-full-workflow.log`，SHA-256 `ae5e94b4c626abf46cf2030772aa27d410a002d0fff7d219ccc0db13a58f4fe5` |
| E-S02 同进程远端完整闭环 | `LocalServerRuntime` → 真 HTTP / 原生 renderer → `RemoteLibraryClient` → `RemoteLibraryReadingData` → `ComicReadingPage`；JPEG/ZIP × 三布局 × 两模式共 12 组，各保存/分享/收藏 SHA 同原文件，共 36 次输出 | `real-source-remote-workflow.json`：complete=true、completedWorkflows=12；相关 4 文件测试 49/49 通过，日志 `real-source-remote-workflow.log`，SHA-256 `eaf5c3d90fd0c9fae27c516ba0ed576d5db82c93217c2e0d295e2335152465b5` |
| E-S03 完整远端读图暴露的问题 | 旧共享 execution 队列中，2 个 UI HTTP 等待占满 native slot，服务端 probe/派生无法启动；多次 202 后画布无 raster。诊断保留 resident 空、真实 202 错误 | `real-source-remote-workflow-diagnostic.log`，SHA-256 `eafc8102d03f05aaa8f3ed16e88f7b87d89ebcbe2bc2038b9eb00dbe21a27bc0`；不是渲染像素质量失败 |
| E-S04 预算与失败回收 | execution/network 共用总内存账，分别最多 2 并发、128/32 在队任务；跨队列依赖、取消保留到清理完成、前台优先、总预算不足明确失败测试通过；HTTP declared/chunked 超限连续 8 次拒绝后第 9 次正常收图 | `image_work_scheduler_test.dart` 8/8；`image_protocol_http_test.dart` 10/10；budget + 初始化 7/7，日志 `source-server-budgets-final.log`，SHA-256 `4d4166d28bc38501e129b6be652b429b46ddd2ebe648c1b5a9df0f06cc525573` |

F-S01（依据 E-S03/E-S04）：HTTP 等待应使用独立有界 network lane，同时原生解码/服务派生继续 execution lane。两者共用原有 1 GiB 工作预算，没有提高原生并发、取消预算或提前释放正在清理的响应。服务依赖在 network 保留内存导致无法启动、且没有 execution 作业可完成释放预算时立即返回资源失败，不无限 202。网络 raster 仍计入编码正文、解码像素、Flutter 图片创建的工作集；响应按请求图像尺寸约束，最大 32 MiB，服务端控制状态正文最大 64 KiB。

P-S01（依据 E-S01/E-S02）：匿名只读下载文件 → 实际 `LocalPathReadingData` 或服务端归档流式物化 → 原始页身份/原文件 → 完整阅读画布 → 当前可见原页选择 → 保存/分享捕获/SQLite 收藏 → SHA-256 一致 → 退出后取消 job、释放 file lease 与提取预算。所有 12 组结束时画布与 image job/lease 为 0；同进程 service 自己持有的 30 秒归档输入缓存不冒充 reader 泄漏，测试停止独立服务后再核查全部预算为 0。原始匿名输入 size、mtime、SHA 前后相同。

### 可复跑命令

先把本次合法 debug/profile 原生 DLL 复制到独立任务位置，避免测试进程锁住随后需要重建的 Flutter runner DLL。本轮独立 DLL `E:\picakeep-image-pipeline-022-work\test-native-library\picakeep_image_engine.dll` SHA-256 为 `a5351afd7f17c004f4c93d21d59666fdfc8a23f46ff950c082aa9bf65888e9e2`。以下在仓库根运行；不构建 release，不触用户库。匿名输入属于本地离线资料，第三方须提供本报告相同 SHA 的样本才可复跑真实素材组。

```powershell
$env:PICAKEEP_022_REAL_SOURCE_ROOT = 'E:\picakeep-image-pipeline-022-work\real-download-source'
$env:PICAKEEP_IMAGE_ENGINE_LIBRARY = 'E:\picakeep-image-pipeline-022-work\test-native-library\picakeep_image_engine.dll'
$env:PICAKEEP_022_SOURCE_REPORT = 'E:\picakeep-image-pipeline-022-work\real-source-full-workflow.json'
flutter test --no-pub test/verification_server_paths_test.dart test/real_download_original_workflow_022_test.dart --reporter expanded
$env:PICAKEEP_022_REMOTE_WORKFLOW = '1'
$env:PICAKEEP_022_SOURCE_REPORT = 'E:\picakeep-image-pipeline-022-work\real-source-remote-workflow.json'
flutter test --no-pub test/image_work_scheduler_test.dart test/image_protocol_http_test.dart test/pixiv_artifact_reading_test.dart test/real_download_original_workflow_022_test.dart --reporter expanded
```

`PICAKEEP_022_REAL_SOURCE_ROOT` 未显式设置时真实素材组跳过，普通完整测试不依赖个人素材。两模式均通过原始像素按钮和三个原文件操作，但本测试不报告显示速度，也不能以 widget pump 的时钟声称手机 1:1 ROI 已达 100–200ms。

### 正式无可见窗 server 入口准备

新增显式诊断参数 `--verification-data-root=绝对任务目录`，只允许与 `--server` 配合；data/cache/config 均位于该根内且禁用既有用户数据迁移，不访问正常应用 support/cache。普通 `--server` / `--config` 的语义保持不变。`App.init` 的隔离路径测试让正常 path_provider 方法直接抛错，确认该参数不会查询真实用户目录。正式入口还需主任务用正常应用 profile 构建后启动与外部 HTTP 验收；本节是准备记录，尚不是运行通过记录。

`tools/image_pipeline_022_server_acceptance.py prepare` 已创建独立 `E:\picakeep-image-pipeline-022-work\server-022-headless-real-source` 配置与只读匿名副本，监听 `127.0.0.1:27439`。主任务以已核验的正常 Windows profile exe 启动以下参数后，可执行校验脚本。脚本不启动/关闭应用，仅访问明确 loopback task 服务；源替换只修改任务副本并恢复，报告显示未覆盖 GUI 控件/系统分享 UI / 断连强制取消等边界。

```powershell
# 正常应用 profile exe 参数：
# --server --verification-data-root=E:\picakeep-image-pipeline-022-work\server-022-headless-real-source
python tools/image_pipeline_022_server_acceptance.py verify --task-root E:/picakeep-image-pipeline-022-work/server-022-headless-real-source --entry-label normal-main-profile-server --report E:/picakeep-image-pipeline-022-work/server-022-headless-real-source-report.json
```

后续仍需：主任务记录正式 Windows main `--server` 的真实进程/插件能力/原字节与瓦片验收，GUI 服务入口的独立数据验收，真机实际阅读与系统保存/分享流程；当前不会把这些缺口记为通过。

### 冻结前反向审查：并发、响应正文与原文件回退

本轮继续沿“两个 HTTP 作业占用总预算 → 服务依赖 → 版本/认证/取消 → 原文件回退 → 连接与文件回收”审查。生产执行并发仍为 2，network 并发为 2，两队列工作内存合计仍不超过 1 GiB；在飞正文不是零工作集。保留前台优先与后台暂停，没有提高全局并发来隐藏循环等待。

| 证据 | 发现与修复 | 已完成验证 |
| --- | --- | --- |
| E-S05 队列头阻塞 | network 预留 60/100 后，普通前台 50 排在服务依赖 20 前面，旧 drain 不会启动可容纳的依赖。允许同级或更高优先级的显式 `servesNetwork` 依赖跨过被预算阻塞的普通任务；仍无法容纳且没有 execution 可以释放内存时明确失败 | 单独 Dart 复现原先 pending=3、execution=0，修复后返回 `[1,2,3]`；scheduler 9/9 |
| E-S06 条件正文超限与身份 | 304 本地正文不可先整文件读入才检查长度。现在核对本次请求捕获条目与再次查找条目的 digest/ETag/bytes，持有 cache lease，先检查声明/实际长度，分块限额并核 SHA；超限、损坏、请求期间同 key 重新发布都回到无条件请求 | 三个独立缓存场景通过；损坏场景使用低于限额的小正文，替换场景重新发布同 key 的另一份有效 PNG，避免共用超限体掩盖身份问题 |
| E-S07 收到头后取消 | 仅 `request.abort()` 无法保证已经收到头且正文停住的 Dart 响应及时结束。全程绑定 abort，并取消响应流 subscription，连接 permit 由同一幂等 release 回收 | 真 loopback HTTP 连续 3 次发送 16 字节后停住正文；每次取消在 2 秒内完成，随后正常请求返回完整原字节；declared/chunked 连续 8 次超限后第 9 次亦正常 |
| E-S08 404 原文件回退 | 远端 tile 的小正文预算不足以承担原文件解码；外层 surface 的占位文件 lease 也不能保护下载的真实文件。原文件取得后单独 lease，按实际 probe/estimate 提交 execution 依赖，计入全局账和输出图片工作集；排队取消由外层释放，已运行 native 由实际 finally 释放 | 700×650 原图在外层 8 MiB 参数下按实际 native 预算解码出 512×512；排队退出与 4000×6000 原图已运行后退出均不会提前删除原文件，收尾后 file lease、工作内存和临时池为 0 |

E-S05–E-S08 定向回归：`server_reader_boundary_022_test.dart` 6/6（本机显式原生 DLL 与既有合成大图已设置，0 skipped）、scheduler 9/9、HTTP 11/11、服务预算 2/2、隔离启动 5/5，合计 **33/33**。日志 `E:\picakeep-image-pipeline-022-work\remote-boundary-final.log` SHA-256 `1341632d304d1964b6eda761aa314362b7ec67668e8e6213fca6481561dea32c`。20 个涉及生产/测试文件静态检查 `No issues found`，日志 `source-server-final-analyze.log` SHA-256 `2bac9c894f5878d88673e6812dbbbdc9b75c598b7a77390f1d6b9b441f46abe8`。

E-S09 冻结版本全量相关回归：上述 33 项加实际来源/远端完整组件 14 项与 Pixiv 原文件链 17 项，总计 **64/64，0 skipped、0 error**，85 秒完成。日志 `E:\picakeep-image-pipeline-022-work\source-server-frozen-final.log` SHA-256 `536b96c1a92f27a51f9c947be3878000fd6e29a2ffe359ceed2d8ec7cf54f2c6`。归档报告 [`real-source-remote-workflow-final.json`](real-source-remote-workflow-final.json) SHA-256 `d5c27be9dd0b0341a89aa433d64a237f15c7e28322df441402d399dfb99e4cf7`，complete=true、completedWorkflows=12、39 条记录（3 个来源记录 + 36 次输出）、sourcesUnchanged=true。冻结前后两模式和三布局均走同进程真 HTTP，不以之前旧版本测试替代最终远端结果。

404 回退测试的 404 响应由请求捕获替身提供，原始文件、原生解码、排队、取消和清理是真实执行；不能把该场景表述为外部正常 server 的 HTTP404验收。停住正文与连接恢复则使用实际 HTTP；同进程真实素材组件闭环仍使用生产 `LocalServerRuntime` 与客户端，系统路径/分享对话框仍为替身。原生能力未显式启用时三个 native 回退组跳过；大图运行中退出组还要求本次 E 盘合成大图存在。

F-S02（依据 E-S05–E-S08）：有界 HTTP lane 需要显式服务依赖的调度通路、正文全程取消、条件缓存身份校验与原文件实际解码账。少一个都可能表现为持续准备、旧正文、退出卡住或提前删除输入；明确失败优于把低清预览当成原图。当前审查没有剩余可复现缺陷，认证 403/版本 409 不进入 404 原文件回退，也不会作为图片缓存；外部正式入口和 GUI/系统 UI 仍按上节由主任务验收。

可复跑上述边界：在仓库根设置本节前述独立原生 DLL 环境变量后，执行：

```powershell
flutter test --no-pub test/server_reader_boundary_022_test.dart test/image_work_scheduler_test.dart test/image_protocol_http_test.dart test/image_derivative_job_budget_test.dart test/verification_server_paths_test.dart --reporter expanded
flutter analyze --no-pub lib/foundation/image_pipeline/image_work_scheduler.dart lib/foundation/image_pipeline/server_reader_page_source.dart lib/foundation/image_pipeline/reader_raster_backend.dart lib/foundation/image_pipeline/reader_page_source.dart lib/foundation/image_pipeline/image_derivative_service.dart lib/foundation/remote_library_data_source.dart lib/server/server_app_images.dart lib/server/local_resource_scanner_custom.dart lib/foundation/archive/archive_episode_builder.dart lib/foundation/local_library_static.dart lib/foundation/verification_server_paths.dart lib/foundation/app.dart lib/main.dart lib/pages/reader/reader_image_surface.dart test/server_reader_boundary_022_test.dart test/image_work_scheduler_test.dart test/image_protocol_http_test.dart test/image_derivative_job_budget_test.dart test/verification_server_paths_test.dart test/real_download_original_workflow_022_test.dart
```

### 2026-10-06 · 空间准入后的真实来源重验

新增空间准入不扩用户空闲缓存额度；原文件物化、native 工作区、派生发布、封面下载使用实际卷余量和有限预留。详细证据、保留的低空间失败、恢复原因、MCU 极窄 JPEG 和远端高 DPI 封面见 [disk-quota-results.md](disk-quota-results.md)。

真实闭环空间版重新通过 **14/14**：`E:/picakeep-image-pipeline-022-work/disk-quota-real-workflow-recovery.log`，SHA-256 `aac3cc958503cabbaeefec9f4872da062a1323ecd06b10da1cbc10bec1e1c504`。报告 `E:/picakeep-image-pipeline-022-work/docs/real-source-remote-workflow-quota-final.json` 为 complete=true、completedWorkflows=12、records=39、sourcesUnchanged=true。之前 C 盘 1.22 GiB 下 3 个失败原样保留；原流丢失 Content-Length 导致重复按 512 MiB 预留，现远端原文件采用声明长度准入、逐字节限额、最终 exact length，未知长度继续原 512 MiB 合同。不是降低原文件质量或把预览替代正文。

随后又发现远端封面固定请求 768 的真实缺口，已接物理 frame 两轴/fit 和独立缓存身份，高档不足取原图；此封面变更在较早 reader 性能快照之后。真 HTTP + ImageProvider.resize/DPR 回归及 source/quota 合并 35/35，通过项不冒充正常手机 UI。主任务后续统一快照必须标明包含该 remote cover 版本。

远端封面再次冻结后的真实来源重跑 **14/14、0 skipped**，日志 `E:/picakeep-image-pipeline-022-work/source-remote-unified-quota-final.log` SHA-256 `c69ae15c4360bf436ae0de521fbbaa159d551ba481209384409e9f2e516bfaab`，最新 `real-source-remote-workflow-unified-quota-final.json`（E 盘 docs）complete=true、12 组、39 记录、sourcesUnchanged=true。使用明确 D 盘 TEMP/TMP；这段只补结果，未改变生产版本。
