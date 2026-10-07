# 最终候选合并后的全量回归（2026-10-06）

## 结果

在主工作树 `D:/Flutter_Projucts/PicaComic/PicaKeep`、生产代码和 prepared-read 低预算测试最终冻结后运行：

- `flutter test --no-pub --concurrency=1 --reporter expanded test`：**2881 passed、15 skipped、0 failed**，11 分 42 秒，进程 exit 0、All tests passed。
- `dart analyze lib test tools packages/picakeep_image_engine/lib`：**No issues found**，进程 exit 0。

没有更改生产代码、计划或 snapshot，没有构建/安装应用，没有清除用户数据/build；测试仅使用既有任务临时目录和独立原生 DLL。全部命令 sessions 已结束。期间 C 盘可用约 0.94–0.97 GB，没有 ENOSPC；不通过删除未知文件绕过压力。

这轮覆盖新增 prepared-read、native encoded cover 候选、导出暂存磁盘准入和 tools-only 正常界面隔离适配器，不能用此前的 2857/14/0 全量结果替代这次冻结版本。opt-in 候选测试通过只证明各自测试边界，不代表手机速度门槛或默认策略已改变。

## 运行环境和日志

原生库 `E:/picakeep-image-pipeline-022-work/prepared-read-native-build/Debug/picakeep_image_engine.dll`，2,702,848 字节，SHA-256 `039e09eae0a232418865e7f308637712c9aaed2acdefc7a59ab75225b09114b4`。测试前核实文件存在和 SHA，使用该独立库，不锁主任务构建的 runner DLL。

| 记录 | SHA-256 |
| --- | --- |
| `E:/picakeep-image-pipeline-022-work/final-unified-after-candidates-tests1006.log` | `4bd4b611d1b53b952c6f7a64638efc3bdf4f79346ea51022d426220f24f27996` |
| `E:/picakeep-image-pipeline-022-work/final-unified-after-candidates-analyze1006.log` | `a103b1fcc987cec77b60b2c15c77764e85361d8d9e8ec12fe83637e32c1b73be` |
| `E:/picakeep-image-pipeline-022-work/docs/real-source-final-unified-after-candidates1006.json` | `d5c27be9dd0b0341a89aa433d64a237f15c7e28322df441402d399dfb99e4cf7` |

完整日志保留既有 UI preview 的 tap hit-test 警告，不将其写成“零警告”；测试仍按原断言运行并通过，没有静音警告或修改测试。

## 跳过项

15 项逐类核实：

| 项数 | 范围 | 原因 |
| ---: | --- | --- |
| 13 | `download_directory_visibility_test.dart` 既有特殊目录名场景 | Windows 无法忠实创建尾部空格/控制字符等所需文件名；原平台 skip 保留。 |
| 1 | `explore/explore_page_test.dart` 既有截图输出场景 | 未指定 compile-time `EXPLORE_QA_DIR`，该可选截图夹具按原规则 skip。 |
| 1 | `native_reader_prepared_read_test.dart` “library without prepared symbol” | 本轮新 DLL 有 prepared symbol；专测旧库 fallback 的互斥分支按原规则 skip。旧库 fallback 独立验证已由 native owner 另记录，不计入本轮 passed。 |

四项 thin progressive 和普通 4:2:0 native disk plan 均显式启用并实际通过，不属于 skip。prepared-read 新库路径三项实际通过，包含 exact raw/无写准入、miss→全量准入/取消回收，以及预算 0/1/1024 的明确 code3 错误且不能吞成写路径回退。

## 实际新增验证

- native encoded cover 七项通过：无损 PNG 编码的逐像素/alpha/热缓存、编码后/图片创建后取消、共享消费者、源替换拒绝、JPEG 后端保持原行为。
- 原图导出临时磁盘准入四项通过：磁盘拒绝不复制/不打开分享、取消保持 lease 到平台返回、插件失败收尾、源增长不能超过已准入长度。
- 任务持久存储/正常 UI 入口十项通过：显式标记路径、拒绝错标记/逃逸、真实 SharedPreferences API 前缀与重启持久化、allow-list 清除和并发写入、损坏/半发布拒绝、任务路径/Dart temp、入口缺参数拒绝，以及匿名素材 prepare-only。该组未调用实际 `PicaKeepApp`/原生窗口或系统对话框，不能称为 GUI 已验。
- 真实 `LocalServerRuntime` HTTP → `RemoteLibraryClient` → `RemoteLibraryReadingData` → `ComicReadingPage` 的 JPEG/ZIP 三布局×两模式，共 12 完整工作流、39 记录；JSON 校验 complete=true、sourcesUnchanged=true。系统文件选择/分享通过替身捕获，实际原生 UI 单独验收。

匿名 JPEG SHA-256 `d5dec8bd5d19d8170b21a725c4b4e025751f1b22ed9ac6f62293c51e83aef690`；ZIP SHA-256 `0d65012191602d018fcb14b5fb909c7da74691365b468d90e3c89e92377ccd35`。真实素材组复核源 size/mtime/SHA 不变，原文件操作捕获输出保持原字节。

## 可复跑命令

在同一工作树使用已存在的任务临时目录和已验证的独立 DLL，标准 Flutter 测试命令不构建/安装应用：

```powershell
$env:TEMP='D:/picakeep-image-pipeline-022-work/test-temp'
$env:TMP=$env:TEMP
$env:PICAKEEP_IMAGE_ENGINE_LIBRARY='E:/picakeep-image-pipeline-022-work/prepared-read-native-build/Debug/picakeep_image_engine.dll'
$env:PICAKEEP_IMAGE_ENGINE_FIXTURES='E:/picakeep-image-pipeline-022-fixtures'
$env:PICAKEEP_022_REAL_SOURCE_ROOT='E:/picakeep-image-pipeline-022-work/real-download-source'
$env:PICAKEEP_022_REMOTE_WORKFLOW='1'
$env:PICAKEEP_022_SOURCE_REPORT='E:/picakeep-image-pipeline-022-work/docs/real-source-final-unified-after-candidates1006-recheck.json'
$env:PICAKEEP_022_THIN_JPEG_FIXTURES='E:/picakeep-image-pipeline-022-work/quota-thin-3000-fixtures'
$env:PICAKEEP_022_NORMAL_JPEG_FIXTURES='E:/picakeep-image-pipeline-022-work/quota-normal-progressive-fixtures'
flutter test --no-pub --concurrency=1 --reporter expanded test
dart analyze lib test tools packages/picakeep_image_engine/lib
```

本轮未另跑 `dart test`；pure Dart explore/core 已包含在整个 test 目录的 Flutter suite 内，不把另一个旧日期的独立 Dart 命令冒充本轮结果。设备 profile 性能/画布质量、OS RSS、正式 GUI/headless 系统交互继续查各自证据，不由全量测试通过推导。
