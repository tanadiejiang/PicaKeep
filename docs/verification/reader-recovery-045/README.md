# 045 阅读器修复复验记录

记录时间：2026-10-09 12:23（Asia/Singapore）。045 状态为部分完成：图片首次读取的快照误判和连续首尾导航缺陷已修复，两档热页设备补测已完成；reader 内画质入口的既有空占位尚未修复，两档首次读取和其余设备矩阵尚未完成，交由 046 补齐。

## 结论与证据

| 证据 | 观察 | 结论与处理路径 |
| --- | --- | --- |
| 修改前真实 ReaderLogic + PhotoView + 连续列表测试 | 长尾图越界后 leading 从 -2.0 变为约 0.10625 | 无下一章仍显式定位末项导致重锚；连续边界改为无操作，分页哨兵另保留 |
| [旧书事件](reader-events-initial.json) | JM-A 第 35 至 41 页发生 sourceValidation/sourceChanged；第 39 页显式重试 attempt=2 后呈现恢复 | 是实际 reader 错误；仅 source 成功没有被记作恢复，需保留同页可见恢复日志 |
| [新书首次阅读事件](reader-events-stat.json) | JM-B 第 2 至 5 页只有 changedMatches=false；type/size/mtime/accessed/sourceIdentity 均相同 | 原件快照在首次实际读取前建立，之后 ctime 刷新被误认为原件变化 |
| 同一外部文件系统的隔离副本实验 | 五次 stat 稳定；只读 open/close 不变；首次实际读取使 ctime 增加 4 至 8 ms，其中 read(1) 对照增加 8 ms，全文 hash 对照增加 4 ms；后续读取稳定，size/mtime/hash 相同 | 用只读 read(1) 后快照建立基线，随后 probe/decode/present 前的严格检查保留。仅 open 不足以解决 |
| [修复后边界事件](reader-events-fixed.json) | 连续尾部三次 overscroll 均拒绝 noAdjacentChapter，前后 pixels/anchors/scale/position 完全一致 | 真机尾端没有程序化重定位；反向拖动可回到此前页面 |

这锁定了本设备上的快照时序误判；没有证明 Android 文件系统为何刷新该元数据的内部实现。没有将先前网络 502、文件非零检查边界或解码器缺陷判定为此次根因。

## 样本与冷/热边界

设备 Android 14（SDK 34），型号 22127RK46C；包 lingxue.picakeep，1.9.95/versionCode 12。使用 profile，阅读模式 topToBottomContinuously，漫画画质 previewFirst。

| 样本 | 映射与操作 | 证据边界 |
| --- | --- | --- |
| JM-A | 用户此前第一本，单章 42 页；严格对应 1.png 至 42.png，无重复或非数字页 | 已经读过部分内容；第 39 页重试恢复不能当作全书首次读取成功 |
| JM-B | 用户最后截图指定的刚下载书，单章 38 页，52.71 MB；严格对应 1.png 至 38.png | 首次打开前只查数据库，没有 hash/打开新页；真实捕获第 2 至 5 页失败。修复后这些页已热，另以此前未读取的第 6 页起页面验证首次读取路径 |

修复后从第 1 页快滚至尾部（最后视口包含第 36 至 38 页），没有出现图片失败提示，也没有 ReaderImage failure。第 6 页及之后的页面没有在此前诊断中读取；不能把这一记录扩展为“所有缓存均清空”。没有清应用缓存、清数据、重下载或写入下载原件。

下面 hash 是读取之后的只读取证，没有失败前 JM-B hash；故不能将 hash 表冒充“首次失败前后字节完全一致”的证明。首次失败日志已经独立证明第 2 至 5 页 size/mtime 不变。后续读取的指定页仍与失败记录的 size/mtime 相同。

JM-A 第 39 页同样没有失败前 hash；失败与 recovered 事件的 versionHash/length/mtime 一致，显式重试事件发生在重选 source 前，这些字段为 unavailable。页 39 的 SHA256 `cefede6a0cfb93d83c534ba0aadbb7fdc21b7044466cff04311d54b688b7bc15` 是恢复后读取所得，只能用于随后稳定性及副本对照。

| JM-B 页 | 字节数 | PNG 尺寸 | mtime（Unix ms） | SHA256（读取后） |
| --- | --- | --- | --- | --- |
| 2 | 963597 | 817×1148 | 1791516259490 | 139f8c09b469670c1c43ad4aa0290dce703da2b396106d0bdc2c00fc020a3499 |
| 3 | 1563681 | 1044×1500 | 1791516260298 | c78d248aea43c1ce968b0567d4d30a27a26bb952575fa0eb20899c2998db0beb |
| 4 | 1461573 | 1044×1500 | 1791516261198 | 51002226c94ce3a5b54805f1fee18a8e04e961be688edc32201b3b095b2c0f1f |
| 5 | 1422874 | 1044×1500 | 1791516259926 | 162eb688e0786f822b85839954524f37ae59b59529893400b9e3ddd78e791b56 |
| 6 | 1314321 | 1044×1500 | 1791516260874 | 06a727e5c8a76f4cff085e3768f28635d98298b208e627df4f1ad8f205d4ecef |
| 11 | 1560296 | 1044×1500 | 1791516262690 | 702c34afeb79fbbe211d449d51804b3c7c00dc26cc89dc9eafc46c0486cb124b |
| 38 | 1784626 | 1280×904 | 1791516273338 | b8ac1f3997d2d93c6ca3942f839e93ab920f98dd06e870196b11ca4ac924af8f |

首次失败时 ctime 的 expected/current 差值：页 2 为 8 ms，页 3 为 12 ms，页 4 为 8 ms，页 5 为 4 ms。日志字段名使用 Micros，Dart FileStat 在本设备返回的是毫秒精度，不声称具有微秒测量分辨率。

JM-B 页 2 与相应衍生 PNG、既有 backing 文件的路径和设备/inode 均不相同。没有证据表明 reader 缓存覆写了原件。这里只核对选定样本，没有扫描全库。

## 实现约束

- `captureReaderOriginalSnapshot` 在原件 lease 下依次 stat → 只读 open → read(1) → stat → finally close，拒绝空读和初始窗口中 type/size/mtime 变化；以读后 stat 为基线。
- 原件验证后续仍检查 type/size/mtime/ctime/identity。初始窗口内仅 ctime 的变化允许进入基线，不能区别于保持 size/mtime 的同窗替换；这是明确的剩余风险，未通过删除全程 ctime 校验扩大范围。
- 章边界导航以一个物理 pointer 手势为单位共用准入锁；过滚和松手不会各换一次章，多指/取消/缩放/加载期/旧章通知有明确拒绝路径。
- ReaderImage 日志使用会话加盐匿名页键、独立版本摘要和 attempt；只记录失败链事件，256 页限流、单条 JSON 至多 3000 字符，遵守 recordingEnabled，日志失败不影响读图。取消及 prepared-read miss 不当作坏图。
- 尺寸不符、资源准入不足、来源变化和 backing 错误分开记录；resident 拒绝使用实际请求和局部/全局可用值。没有扩大内存或重试预算。

## 自动化验证

在项目根目录执行，完整定向回归 230 项通过（最后一个 EOF 测试补入前）：

```powershell
flutter test --no-pub test/reader_original_snapshot_test.dart test/reader_continuous_boundary_test.dart test/reader_failure_diagnostics_test.dart test/reader_page_image_recovery_test.dart test/reader_image_surface_test.dart test/reader_image_quality_test.dart test/reader_image_pipeline_settings_test.dart test/reader_zoom_test.dart test/reader_full_workflow_022_test.dart test/reader_first_raster_admission_test.dart test/flutter_reader_raster_backend_test.dart test/reader_session_raster_cache_test.dart test/image_work_scheduler_test.dart test/chapter_download_manager_test.dart test/reader_original_raster_handoff_test.dart
```

最终 read(1) EOF 拒绝与计时位置调整后，受影响测试 38 项通过；这与上面的 230 项有重叠，不相加为独立数量：

```powershell
flutter test --no-pub test/reader_original_snapshot_test.dart test/reader_page_image_recovery_test.dart test/reader_first_raster_admission_test.dart
```

定向 `dart analyze` 无问题；`git diff --check` 通过。首尾工作流测试 34 项使用真实 ReaderLogic/PhotoView/连续列表，覆盖长/短/一屏、单章/无章、触摸/鼠标、取消/多指/加载/反向/重建，以及单页三个方向、双页两个方向和首页单页映射；不能据此称所有输入已在 Android 真机验证。

## 构建、安装与最后烟测

```powershell
flutter build apk --profile --no-pub
Test-Path -LiteralPath 'build\app\outputs\flutter-apk\app-profile.apk'
Get-FileHash -LiteralPath 'build\app\outputs\flutter-apk\app-profile.apk' -Algorithm SHA256
adb -s 192.168.5.13:5555 install -r 'D:\Flutter_Projucts\PicaComic\PicaKeep\build\app\outputs\flutter-apk\app-profile.apk'
```

最后包大小 173297826 字节，构建时间 2026-10-09 11:49:21；SHA256 `B1FAA8FE8A86FCB8E11847AB0462DE3E9C7A61A482552914D07D41ADE2FAD6AC`。安装输出 Success；lastUpdateTime=11:51:19，用户 firstInstallTime 仍为 2026-10-01 23:32:23。构建、包身份和签名已核实后覆盖安装，未卸载。

最终包启动后重入 JM-B 的第 34/38 页，正常显示；该页已读过，属于热路径烟测。最终 session `picakeep-log-20261009_115315.txt` 未见 ReaderImage failure。首次读取和尾端完整取证在紧邻的上一版 profile 完成，最后版仅增加 EOF 守卫和 sourceFileUs 计时调整，没有再次制造首次读取样本。

随后通过全局设置实际控件完成漫画 previewFirst→sharpFirst→previewFirst 的设备补测，详见 [两档热页摘要](device-modes-hot.json)。清晰优先重入第 34/38 页，快滚至包含第 36 至 38 页的尾视口，再上拉及反向回第 35 页，均未见失败提示。12:12:16.412 和 12:12:36.492 的两条 noAdjacentChapter 请求 before/after 完全一致，scale=1、x/y=0。双击实际放大、短 pan 后再双击恢复已观察，但没有数值 scale/新 raster density 证据，不算像素升档完整验收。

恢复预览优先后有限正反滚动和双击往返正常；最终核对漫画 previewFirst、插画 sharpFirst、readingMethod=4，停在 JM-B 35/38 的正常适配视图。本 session 没有 ReaderImage 事件；结论同时依赖实际可见页面观察，不能只凭无日志证明每一页的解码。两档均为已读样本的热路径。

设置前后对比还发现 index 17 最终为 1，是 `jm_network.dart` 现有网络自动选域写回，未通过 UI 或手工数据修改该项。漫画设置已恢复；其余设置摘要均一致。不声称所有设置值完全未变。

## 剩余验收

reader 内 `ReadingSettings` 的图片显示使用旧 `Select`；当前工作区与 HEAD 中 `_SelectState.build` 均返回空 `SizedBox`。真机该行没有选择控件。全局设置页使用另一正常的 `components/select.dart`，可以切档；这属于 reader 局部入口缺陷。未通过改设备数据文件绕过 UI。046 应仅修复阅读器这个入口并补齐两档首次读取和剩余完整工作流。

其他来源本地页的真机对照、滚轮/触控板真机验证、失败前后屏幕记录及隔离副本的独立全页实际 codec 对照没有全量完成。当前有原生 reader 实际呈现和脱敏持久日志，但不能用头签名、尺寸或 hash 代替这些尚缺的验收项。

原始完整应用日志含其他模块数据，不复制入版本库；本目录事件 JSON 仅保留 ReaderImage/ReaderBoundary 的白名单字段。原件图像、认证信息与用户书名不写入本报告。既有 `device-before-home.png` 仅作本地基线，不提交。
