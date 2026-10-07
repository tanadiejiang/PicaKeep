# 正常隔离UI v8 Windows启动核对（2026-10-06 20:24）

本记录是已启动正常应用的只读核对，不操纵UI、不触发原图操作、不清缓存、不修改运行任务。主任务的Computer Use应用授权等待超时，后续界面操作仍未执行。

## 实际证据

- Windows profile构建成功，日志`D:/picakeep-image-pipeline-022-work/normal-ui-v8-windows-build.log`：84.2秒、AMD64。PID10588实际路径为`D:/picakeep-image-pipeline-022-work/normal-ui-v8-runner/picakeep.exe`，启动时间2026-10-06 19:59:18（Asia/Singapore），只读检查时仍在运行。
- 实际stdout`normal-ui-v8-actual.log`记录`PicaKeepApp`、`MainPage`、`MePage`及真实firstPostFrame、essential/deferred appdata初始化；stderr为空。`PICAKEEP_022_NORMAL_UI`明确列出本次task/data/cache/preferences/server配置根。
- 任务为`D:/picakeep-image-pipeline-022-work/normal-ui-022-v8-system-flow`，标记scope/version/root均匹配。`preferences.json`只有`picakeep022.firstUse/settings/implicitData`键；实际support/settings的22/152下载根、91图集根、118合集map全部在该任务内。75为currentOnly，90原应用根为空，client模式97、remote98和server端口100均指向loopback `127.0.0.1:12869`。
- 实际server配置的managedDataRoot、currentDownloadRoot、customLibraryRoots均位于task；originalDownloadRoot为空，host只监听`127.0.0.1`。这证明所检查的持久设置/日志路径隔离，工具不是OS级沙箱，不能推断未记录的任意手动选择也受隔离。
- 13个固定素材副本逐文件流式SHA核对全部匹配`workflow-fixtures.json`。原ZIP14,486,148字节，JPEG504,752字节，PNG1/2分别4,916,814/4,652,232字节；两章的第2/3页确实互换，两个作品的同名`1.png`内容不同。
- `normal-ui-audit.jsonl`在19:59:21记录`readerOpen:false`、Surface/job/lease/temp/disk账均0、favorite空；20:00:56记录真实`inactive`事件。活DB以SQLite `mode=ro`打开只做SELECT后关闭：`favoriteCount=0`、`historyCount=0`，exports为空。

因此本次可以记为**正常profile实际启动、任务隔离和素材oracle核验**；尚无列表→阅读→原始像素→保存/分享/收藏→退出重进操作证据，也无OS memory pressure回调。不能以进程仍存活、按钮理论存在、源码/工具测试或初始资源归零替代完整UAT。

| 本次构建身份 | SHA-256 |
| --- | --- |
| Windows build log | `1afc3204c11153d9150a60a2d9bf9a48a9a692aa274a6ec5175f6ebd8379a815` |
| profile runner exe | `e0ee4da717332e62419216d4450dcbe359d37770da6d1424dda01f9ed1c420f0` |
| `data/app.so` Dart AOT | `4c4fae860b3e7dd43ab312b5d5404a4d82c368befb79acd8e20ffbeeb7dbadc6` |
| image engine DLL | `7fe08942863b5e97421c6943bc922df94716ede64f5d50057671949f2f06aee1` |

运行中的stdout文件被进程以写入方式占用，本轮不强取固定日志hash；结束后主任务可计算最终hash。exe相同不能证明Dart代码相同，以AOT/hash和冻结输入为准。

## 保存和P7边界审查

桌面`saveImage`使用真实保存对话框返回的用户目的路径，并直接`file.copy(path)`；不重编码，也不聚合Dart整份字节。该用户永久输出没有进入应用cache quota或LRU，这与[配额记录](disk-quota-results.md)的边界一致。但当前目的路径没有实际卷余量预留、源size/mtime/SHA后验；copy异常只写LogManager，不向用户展示失败。因此已有34/34临时分享副本/配额回归不能外推为桌面低空间保存完整验收。此审查未新增生产变更，实际目的文件仍须按[正常UI步骤](normal-ui-isolated-entry.md)核字节。

P7生产链已具备提交后的`ImageBackgroundNotifications`通知、`BackgroundImagePreparer.activate`、实际封面准备与清缓存代次失效；下载/Pixiv事务/LocalLibrary快照均有挂点，`eraseCache`先失效derived/cover/local/remote/background再删可再生文件。当前test目录没有直接覆盖callback→真实prepare→清缓存的完整生产组合，本次正常窗口也尚未进入资源库，不将启动视为后台派生已经完成。现有writer/source/server绿色证据保留，正常导入、慢派生、清缓存和可见原源lease竞争仍待各自真实流程证据。

## 平台验证库存

既有[ROI修复APK结构报告](android-native-16kb-roi-fixed.json)对应旧APK SHA `7f771bb3…0ef9182`：zipalign返回0、全部64-bit LOAD满足16KiB；本插件三ABI的LOAD/RELRO均满足检查。预编译libc++、dartjni、datastore和sqlite的六条RELRO末端检查仍未全部满足，`runtime16KiBDeviceTested:false`。该旧报告记录devicePageSize4096/deviceApi29，不能作为当前v9 APK或16KiB设备运行结论。

已有APK可以用以下只读脚本复核；输入APK、输出的新报告路径与设备API应来自本次实际快照，不复用旧构建身份：

```powershell
python packages/picakeep_image_engine/native/tests/check_android_alignment.py --help
```

脚本参数是`<已有APK> --output <新JSON> --zipalign <本机zipalign.exe>`，可附`--device-page-size`和`--device-api`。本轮只盘点能力和已有报告，没有再跑同一旧APK的重复结构检查。

独立native行为测试位于`packages/picakeep_image_engine/native/tests`：`pki_validate`、`verify_pixels.py`、Dart smoke/worker lifecycle/prepared测试；项目native CMake没有注册`ctest`测试，不能把空`ctest`作为平台通过。既有结果见[native记录](native-results.md)、[prepared记录](native-prepared-read-candidate.md)及[gutter补验](color-animation-profile-results.md)。Windows当前runner目录实际含Flutter、sqlite、image engine、file_selector和share_plus DLL；干净目录长路径/Unicode及所有平台运行组合仍不能由DLL存在单独证明。
