# 022 v9 全量回归与诊断 · 2026-10-06

本次全量 **2877 passed / 34 skipped / 4 failed**，5分15秒、exit 1；不能记为绿色回归。`dart analyze lib test tools packages/picakeep_image_engine/lib` exit 0，No issues found。运行仅测试既有工作树，没有构建/安装应用、清数据、native 核心编辑或 Git 写操作。

## 本次环境和完整证据

命令 `flutter test --no-pub --concurrency=2`；TEMP/TMP 为项目 `build/picakeep-022-continuation/regression-temp`。独立原生 DLL 和固定 fixture 显式设置：

```powershell
$env:PICAKEEP_IMAGE_ENGINE_LIBRARY='E:/picakeep-image-pipeline-022-work/prepared-read-native-build/Debug/picakeep_image_engine.dll'
$env:PICAKEEP_IMAGE_ENGINE_FIXTURES='E:/picakeep-image-pipeline-022-fixtures'
```

DLL SHA `039E09EAE0A232418865E7F308637712C9AAED2ACDEFC7A59AB75225B09114B4`。其 prepared、encoded cover 和 server native 路线实际运行；缺少另外的 explicit real-source/thin/normal fixture 环境变量导致 19 项跳过，下方逐项分开。

| 证据 | SHA-256 |
| --- | --- |
| E-001 `build/picakeep-022-continuation/final-v9-all-tests.log` | `3CAE506A90E136D88C4A977E66F85CCA4559A319B0048F265A72BC3E3E89479A` |
| E-002 `build/picakeep-022-continuation/final-v9-analyze.log` | `A103B1FCC987CEC77B60B2C15C77764E85361D8D9E8EC12FE83637E32C1B73BE` |
| E-003 `build/picakeep-022-continuation/final-v9-regression-source-manifest.json`，699 Dart 文件 | `680ABC7F0642AB57BE33EA756204D40747BA0455A93277AADC59F39F370799CE` |

manifest UTC 12:21:57，完整测试日志结束 UTC 12:26:06。中途核验 699 项没有源码变化。测试结束后的 UTC 12:29:27，precision owner 为失败诊断修改了 `test/flutter_reader_raster_precision_test.dart`，生产源码仍冻结；结束后再次核 manifest 的这一项变化不代表全量执行期间发生改动。

## 四项失败

| 文件 / 场景 | 原始观察 | 当前处理 |
| --- | --- | --- |
| `chapter_download_resume_test.dart` 主动状态检查发现手删尾页 | helper `enqueueSource` line209，currentEp expected20 / actual18，尚未开始手删部分 | workflow owner 保留原日志并复现真实底层 error |
| `download_directory_migration_test.dart` 漫画目录递归搬走 | line181 movedEntries expected2 / actual1 | workflow owner 复现复制/搬移底层失败 |
| `flutter_reader_raster_precision_test.dart` 拒绝旧 sampler raster | line182 已成功 put 的旧 raster 随后 load 返回 null | precision owner 已证实 key/store lookup 有效，Flutter ImmutableBuffer.fromFile 不能读取大于260字符路径；仅测试 fixture 采用短 `.pkc-`，同原长 TEMP 定向3/3通过 |
| `pixiv_root_recovery_test.dart` published 后 root relocation | 预期注入 StateError，实际 Directory.rename PathAccessException errno5 拒绝访问；路径 `target_3.pixiv_pending_*` | workflow owner 定向复现 Windows 临时目录失败 |

F-001：E-001 证明四项断言失败，尚不能将它们归为本轮 reader 回归或同一个 Windows 根因。重跑必须保留此次原失败，不能覆盖日志或只据定向通过宣布全量通过。TEMP 路径深度、Windows rename/codec 能力与并发 IO 是诊断变量，生产修复需先证实。

## 34 项跳过的准确分类

| 数量 | 文件 / 条件 | 边界 |
| ---: | --- | --- |
| 13 | `download_directory_visibility_test.dart` | Windows 尾部空格/控制字符目录命名平台 skip，保留原条件 |
| 1 | `explore/explore_page_test.dart` | 未设置 compile-time `EXPLORE_QA_DIR`，可选截图输出 skip |
| 1 | `native_reader_prepared_read_test.dart` | 当前 DLL 有 prepared symbol；无符号旧库的互斥兼容分支 skip |
| 13 | `real_download_original_workflow_022_test.dart` | 未设置 `PICAKEEP_022_REAL_SOURCE_ROOT`；1 source 字节闭环 + JPEG/ZIP×3布局×2模式12 reader cases skip |
| 1 | `image_pipeline_task_storage_test.dart` | 同一匿名 real-source env 缺失，prepare-only 固定 source hashes 场景 skip |
| 4 | `native_image_disk_plan_test.dart` | 未设置 `PICAKEEP_022_THIN_JPEG_FIXTURES`，2薄图尺寸×2sampling skip |
| 1 | `native_image_disk_plan_test.dart` | 未设置 `PICAKEEP_022_NORMAL_JPEG_FIXTURES`，ordinary 4:2:0 progressive skip |
| **34** | **15 既有平台/互斥 skip + 19 fixture env skip** | **不能表述为 34 全部平台 skip** |

本次 `PICAKEEP_022_REMOTE_WORKFLOW` 也未设置，因此 remote source 与 remote reader cases 没有注册；未注册项不计入 skipped。旧全量 2881/15/0 的环境显式启用了这些 source fixtures 与 remote workflow，本次命令环境不同，不能按两个 passed 数相减推导 regression 新增/减少。

## 补测缺失 fixture 的命令

root 已确认下方 fixture 路径存在；单独补测不替代全量绿色结果。使用短 task TEMP，实际 native/anonymous fixtures 前后只读，不操作用户库。

```powershell
$env:TEMP='D:/picakeep-image-pipeline-022-work/test-temp'
$env:TMP=$env:TEMP
$env:PICAKEEP_IMAGE_ENGINE_LIBRARY='E:/picakeep-image-pipeline-022-work/prepared-read-native-build/Debug/picakeep_image_engine.dll'
$env:PICAKEEP_IMAGE_ENGINE_FIXTURES='E:/picakeep-image-pipeline-022-fixtures'
$env:PICAKEEP_022_REAL_SOURCE_ROOT='E:/picakeep-image-pipeline-022-work/real-download-source'
$env:PICAKEEP_022_REMOTE_WORKFLOW='1'
$env:PICAKEEP_022_SOURCE_REPORT=Join-Path (Get-Location) 'build/picakeep-022-continuation/final-v9-real-source-directed.json'
$env:PICAKEEP_022_THIN_JPEG_FIXTURES='E:/picakeep-image-pipeline-022-work/quota-thin-3000-fixtures'
$env:PICAKEEP_022_NORMAL_JPEG_FIXTURES='E:/picakeep-image-pipeline-022-work/quota-normal-progressive-fixtures'
flutter test --no-pub --concurrency=2 --reporter expanded test/native_reader_prepared_read_test.dart test/native_image_disk_plan_test.dart test/image_pipeline_task_storage_test.dart test/real_download_original_workflow_022_test.dart
```

## 已完成的真实来源与原生补测

上方四文件命令于本日实际完成 **34 passed / 1 skipped / 0 failed**，52秒、exit 0；保留的1项 skip 仍为有 symbol 的 DLL 下无 symbol 兼容分支。固定 DLL、thin/normal 5项、task-storage real source、prepared warm decode，以及原文件通过 production source 与本机HTTP远程源闭环均已运行。

| 证据 | SHA-256 |
| --- | --- |
| E-004 `build/picakeep-022-continuation/final-v9-real-native-directed.log` | `FCB04C02941D0D4AA3B2CE01244F7326DA475BD6D2085B4B87A242C06350B00A` |
| E-005 `build/picakeep-022-continuation/final-v9-real-source-directed.json` | `D5C27BE9DD0B0341A89AA433D64A237F15C7E28322DF441402D399DFB99E4CF7` |

E-005 记录 `complete=true`、`sourcesUnchanged=true`、12个 reader workflow；remote JPEG/ZIP各3布局×2模式，36次保存/分享/收藏均保留原字节SHA。系统文件对话框和分享出口在测试中 mock，不能代替真机系统操作验收。

F-002：`real_download_original_workflow_022_test.dart` line321 按 `REMOTE_WORKFLOW` 在本地12例与远程12例之间选择，远程模式并非额外注册12例；只额外注册1项 remote production source。补测中的 real byte闭环和 remote12已通过，本地12需另以 `PICAKEEP_022_REMOTE_WORKFLOW='0'`、独立 SOURCE_REPORT 补验，不能用该34项通过声称原34项skip全补齐。

P-001：完整测试与 manifest E-001/E-003 → 原失败按 owner 独立复现 → 缺 env 的 19 fixture checks 与 remote workflows 显式补验 → 根因修复冻结 → 短 TEMP、concurrency1 的完整回归 → 合并最终正常 debug/profile 构建证据。剩余设备速度、OS 回收和正常系统文件操作验收不由单元测试通过推导。
