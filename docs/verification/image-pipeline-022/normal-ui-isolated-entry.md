# 正常界面隔离验证入口（022，2026-10-06）

## 用途和当前状态

`tools/image_pipeline_022_normal_ui_main.dart` 启动实际 `PicaKeepApp`、`MainPage`、正常资源库/阅读器/设置/服务页面，并保留真实 window_manager、文件选择、分享和图库插件。它仅用于 debug/profile 验证，不修改正常 `lib/main.dart` 的启动语义。

本轮已完成入口编译（由 Flutter test 引入）、任务持久存储及真实匿名素材的 prepare-only 验证，**10/10、0 skipped、exit 0**。随后主任务实际启动了 Windows profile 入口并完成了一次真实界面导航：进入图集、`real-jpeg`、章节和阅读器，看到了真实 JPEG 适屏画面，阅读器工具栏显示保存/分享入口。完整 `dart analyze lib test tools packages/picakeep_image_engine/lib` 为 No issues found。该次操作没有点击保存/分享系统对话框，也没有把 UI 浏览冒充导出闭环或像素精确验收。

普通主入口的 `--verification-data-root` 只支持 `--server`；对正常 GUI 传这个选项会在 App 初始化前明确拒绝。环境变量 `PICAKEEP_DATA_DIR` 也只用于 headless。仅传 `App.init(dataPathOverride: ...)` 不足以隔离正常 UI，因为 SharedPreferences 与部分 path_provider 调用仍会读取默认系统路径。因此使用独立 tools target 的显式任务适配器。

## 隔离范围

入口必须传绝对 `--work` 和绝对 `--sources`，没有默认用户目录。任务根名必须是 `normal-ui-022-*`，不能是文件系统根；第一次要求目录不存在，再次启动必须有路径身份和版本匹配的 `normal-ui-verification-022.json`。已存在但没有该标记的目录拒绝使用。任务路径、标记、设置文件和服务配置读取前会拒绝链接祖先/链接文件。

- 设置通过实际 `SharedPreferencesStorePlatform` JSON adapter 持久存储到任务根 `preferences.json`，键前缀 `picakeep022.`。不会委托 OS/user store，不使用内存 mock；prefix/allow-list 获取、清除、typed values、串行更新、重启重读都覆盖测试。写入 `.part` 后保留 `.previous` 做失败回滚；启动遇到未完成恢复文件明确拒绝并保留证据。
- path_provider 的 support/cache/temp/documents/download/external 路径全部返回任务根下实际目录。Dart `Directory.systemTemp` 通过入口 zone 指向任务 `temporary`，临时导出复制和 Dart 暂存也在该处；Flutter binding 初始化与 `runApp` 保持在同一 zone。
- `App.init` 指向任务 `support` 和 `cache`，`migrateExistingData:false`；managed root 为任务 support、currentOnly。用户原应用目录为空，当前/Pixiv 下载根均明确在任务内，资源库只有任务 library。恢复既有任务时核验设置/服务配置所有根仍在该任务内。
- 仅复制现有匿名 JPEG/ZIP，逐次核对固定 SHA；已有副本 SHA 不同则拒绝覆盖。JPEG 放入 `library/real-jpeg/1.jpg` 与 `cover.jpg`，ZIP 放入 `library/archive-001.zip`。没有复制用户账户、设置、下载数据库或 cookies；已下载页可以为空，真实素材从资源库正常入口打开。
- 默认 client 模式，正常设置/服务页面可切 server 模式并启动服务。服务配置只监听 `127.0.0.1`，首次取一个空闲端口（实际启动前仍可能被别人占用），remote address 指向同一任务服务；验证后台口令 `verification-only-022` 仅用于这个 loopback 任务。
- 正常启动的 essential/deferred appdata、cookie DB、ComicSource、AI/online queue、ExploreBindings、translation、background image preparer 和正常窗口初始化均使用任务存储。自动 JM 域名探测预热在这个 tools 入口省略并明确输出日志；手动在线导航仍是真实功能。

这不是操作系统文件沙箱。用户在真实文件选择器中选别处、手动更改设置、登录账号或触发在线页面仍可能访问对应资源；验证操作只使用标记任务目录。native 插件内部管理的 OS 临时文件由真实插件负责，不宣称已被 Dart 路径适配器重定向。缓存路径检查与系统 IO 之间也不宣称具有句柄级、抗外部恶意替换的原子隔离。

## 启动参数

Windows 桌面示例由主任务在其独立 snapshot 构建，再启动对应 exe。构建限 profile/debug：

```powershell
flutter build windows --profile --target=tools/image_pipeline_022_normal_ui_main.dart
& .\build\windows\x64\runner\Profile\picakeep.exe `
  '--work=E:/picakeep-image-pipeline-022-work/normal-ui-022-gui-final' `
  '--sources=E:/picakeep-image-pipeline-022-work/real-download-source'
```

首次不要提前创建末级 `normal-ui-022-gui-final` 目录；入口自己创建任务标记和目录。上级 022 工作目录可已存在。附加 `--prepare-only=true` 可只生成/核验任务副本、preferences 和 server config，不调用 `App.init`/`runApp`/正常窗口或 native UI 插件；之后用同一 root 去掉该参数即可正常启动，已有任务设置保留。

Android Flutter 启动没有 argv 时，入口读取操作者明确准备的 `/data/local/tmp/picakeep-native-022/normal-ui-options.json`，内容示例：

```json
{
  "work": "/data/user/0/lingxue.picakeep/files/normal-ui-022-gui-final",
  "sources": "/data/local/tmp/picakeep-native-022/real-download-source"
}
```

`sources` 必须是设备上现有、当前 app UID 可读、SHA 匹配的匿名副本实际路径；上述路径只是候选，主任务应按实测位置填写。末级 work 也必须由入口首次创建。构建仅 `flutter build apk --profile --target=tools/image_pipeline_022_normal_ui_main.dart` 或 debug；安装前核实实际 APK，显式设备 ID、保留现有应用数据。此文档没有授权 uninstall、clear data 或正常账户迁移。

正常启动会输出 `PICAKEEP_022_NORMAL_UI` JSON，记录 task/data/cache/prefs/config 路径、素材 SHA 和隔离边界。prepare-only 输出 `PICAKEEP_022_NORMAL_UI_PREPARED`，带 `uiStarted:false`，不能将这条日志解释为 UI 已验收。

## 验证证据

真实源 JPEG SHA-256 `d5dec8bd5d19d8170b21a725c4b4e025751f1b22ed9ac6f62293c51e83aef690`；ZIP SHA-256 `0d65012191602d018fcb14b5fb909c7da74691365b468d90e3c89e92377ccd35`。prepare-only 的真实输入/副本逐字节比对、源 size/mtime 保持，重新打开仍保留任务设置；没有生成 cookies/download DB，也没有调用正常 App 初始化。

### Windows profile 实际界面启动

主任务用 profile 版本启动入口，进程 PID `46932`，随后通过正常窗口关闭流程退出。实际任务根为 `E:/picakeep-image-pipeline-022-work/normal-ui-022-gui-final`，数据根、缓存根、preferences 和 server config 均由入口 JSON 指向该任务根；任务目录内实际生成的 `cookies.db`、`history.db`、`local_favorite.db`、`download.db`、封面缓存、native backing 和日志均留在任务根，没有切换到日常用户目录。

日志 `E:/picakeep-image-pipeline-022-work/normal-ui-isolated-final-windows.log` 记录：essential/deferred appdata 完成、`PicaKeepApp`/`MainPage`/`MePage` 首帧启动、任务下载目录路径、真实库加载，以及 JPEG/ZIP 相关页面加载。操作者实际进入图集、`real-jpeg`、章节和阅读器，看到真实 JPEG fit 画面；工具栏中的保存和分享入口可见。日志中的 `GrBackendTextureImageGenerator: Trying to use texture on two GrContexts!` 是引擎诊断输出，不能在这次短流程中解释为像素损坏；本轮也没有把它归类为通过或失败。

这次是正式 `PicaKeepApp` 的 Windows profile smoke/navigation，不是完整 UI 验收：没有点击保存或分享、没有接收系统文件选择/分享 dialog 返回值、没有验证图库投递，也没有对该窗口做像素读回或原图放大后的逐通道比较。关闭窗口后不再运行 host/ADB，也没有重启、安装、清理任务数据。后续 UI 证据必须继续使用同一任务根并单独记录实际插件交互。

本次过程中有用户短时操作，因此不作为无人干预的严格全自动复跑记录。主任务已通过 `CloseMainWindow` 正常关闭任务窗口，之后把 build 链接从 C 盘调整到 D 盘新的物理 v2 目录，并使用 `compiler-cache-v2` 隔离缺 AOT 的构建产物；这些构建收尾不增加上述 UI 已验范围，也不重写既有 2881 全量报告。

### 证据层次

- **10/10**：`image_pipeline_task_storage_test.dart`，持久 JSON preferences、路径适配器、标记/链接拒绝和匿名素材 prepare-only；不启动 `PicaKeepApp`。
- **34/34**：导出临时副本/原图操作定向测试；系统分享 channel 是替身，证明额度、lease、取消和原字节边界，不证明系统 dialog。
- **Windows profile smoke**：实际 `PicaKeepApp`、资源库、章节和阅读器导航已执行；保存/分享入口仅可见，系统交互尚未执行。
- 全量 2881/15/0 回归：验证冻结代码的单元、协议和集成测试，不替代上述真实 profile UI 或原生 dialog。

| 记录 | SHA-256 |
| --- | --- |
| `tools/image_pipeline_022_normal_ui_main.dart` | `430e78e241605d96086462a6e224fd71d89695ef0a3cc749a219b8e7deb20cfe` |
| `tools/image_pipeline_022_task_storage.dart` | `f9f0cf9bce90f02a48978e404da4d60a7a9552f9a8b5921636c9c132b9660599` |
| `test/image_pipeline_task_storage_test.dart` | `99c0713d1e478a94ae2c89f172354cd7183dd5c1295f5384f096c66e4b78e834` |
| `E:/picakeep-image-pipeline-022-work/normal-ui-task-storage1006-final-zone.log`，10/10 | `8306b069109584520a18d1a51d496d79d76eeb7cbdd19ab21dbfc51214c8fa2e` |

全范围静态检查记录 `E:/picakeep-image-pipeline-022-work/final-export-normal-ui-analyze1006.log`，当前包含导出磁盘准入、tools 入口、最新 opt-in cover 候选代码。候选合并后的最终全量记录另见 `final-after-candidates-regression.md`：2881 passed / 15 skipped / 0 failed；它仍不替代真实 profile UI 和原生 dialog 证据。

```powershell
$env:TEMP='D:/picakeep-image-pipeline-022-work/test-temp'
$env:TMP=$env:TEMP
$env:PICAKEEP_IMAGE_ENGINE_LIBRARY='E:/picakeep-image-pipeline-022-work/test-native-library/picakeep_image_engine_disk.dll'
$env:PICAKEEP_022_REAL_SOURCE_ROOT='E:/picakeep-image-pipeline-022-work/real-download-source'
flutter test --no-pub --concurrency=1 test/image_pipeline_task_storage_test.dart --reporter expanded
```

未给 real source 环境变量时，真实素材 prepare-only 那项明确 skip；其余适配器验证不需要用户素材。该套件不启动界面，真实文件选择/分享/图库对话框、正式 GUI 服务控制和设备端完整原图操作仍需主任务另记录。

## 2026-10-06 19:56 多页、原图操作与OS事件设施

新增[`image_pipeline_022_normal_ui_observer.dart`](../../../tools/image_pipeline_022_normal_ui_observer.dart)及[只读审计脚本](../../../tools/image_pipeline_022_normal_ui_audit.py)，不改变正常主入口。入口/observer/两个测试静态分析无问题；实际匿名素材启用后的`--no-pub --concurrency=2`定向组合**12 passed、0 skipped、exit 0**。测试的TEMP/TMP均位于本仓库`build/022-workflow-test-temp`。prepare-only仍不启动UI。

初次种子启用任务library的合集图集模式，服务配置使用相同路径map。其余直接图片目录仍走正常leaf fallback；已存在任务保留原设置，若旧任务尚未启用合集模式，应在真实界面开启该任务library的模式，或使用新的标记任务根。

| 正常库素材 | 真实页序和用途 | SHA oracle |
| --- | --- | --- |
| `real-jpeg/1.jpg` | 原JPEG单页；保存/分享/收藏首个流程 | JPEG `d5dec8bd…aef690` |
| `archive-001.zip` | 原归档正文两页；真实生产提取链 | ZIP `0d650121…ccd35`，成员1/2为下面的PNG1/2 |
| `real-workflow/chapter-1` | `1.jpg`原JPEG、`2.png`PNG1、`3.png`PNG2 | `[JPEG, PNG1, PNG2]` |
| `real-workflow/chapter-2` | `1.jpg`原JPEG、`2.png`PNG2、`3.png`PNG1 | `[JPEG, PNG2, PNG1]`；同一页名换章后内容不同 |
| `same-name-1/1.png`、`same-name-2/1.png` | 两作品同名但不同字节；各自cover只是独立原图副本 | PNG1 `8811fe1a…53ffe`、PNG2 `c8686361…58990` |

完整SHA在任务`workflow-fixtures.json`。PNG由实际`DartZipBackend.materializeEntry`受控流式提取，每成员限5 MiB、64 KiB块、CRC及固定SHA核验；只操作任务原归档副本。既有目的文件内容不同则拒绝覆盖，没有图像重编码、用户库遍历或账户种子。

### 操作者完成正常流程

1. 用profile/debug正常入口启动新task，保存启动JSON及构建身份。实际进入任务图集、`real-jpeg`、章节与阅读器；点按工具栏“原始像素”，待画面稳定再平移，保留截图和对应`reader-state`记录。状态日志的ROI/density/complete是辅助证据，实际decoded尺寸和画布精确性仍由独立质量报告验证。
2. 点击“保存图片”，在真实Windows保存对话框中明确选task的`exports/jpeg-save.jpg`，完成后核字节；Android点击后走真实MediaStore原字节桥，需保留该次新项目的返回URI或实际产物哈希证据。不能用“已保存”提示代替输出核验。
3. 点击“分享”，观察真实系统分享界面并取消。新observer将SHA/MIME输入、真实返回或错误写入`normal-ui-audit.jsonl`；`dismissed/unavailable`分别照实记录。这证明插件交互和原图准备边界，不证明外部接收者已消费；本次不向他人发送文件。
4. 点击“收藏图片”，实际退出阅读器，进入图片收藏查看，并关闭再用相同task root启动。observer记录收藏文件哈希及作品/章/页/URL/源版本，离线审计再核持久化DB。原图收藏属于用户输出，验证后保留，不用清缓存删除。
5. `real-workflow`两章各三页用于正常阅读设置的“从上至下(连续)”“双页”“双页(反向)”及两种展示模式；连续模式让两页同时可见，选择另一张非当前页；双页明确选第二页，另看奇数末页/首张单页。实际操作保存到`exports/png-save.png`，对应明确所选章/页SHA。切章后同名`2.png`应切换到另一个PNG；异步切章身份冻结仍须实际等待中的操作或已有组件回归佐证，不能仅看静态列表。
6. 分别在`same-name-1`/`same-name-2`收藏`1.png`，关闭应用后核两条记录与两个独立文件，各自匹配PNG1/2。再实际重进同一作品，核历史章页及设置模式保持。

observer每秒仅在状态变化时记录控制器、页章、原像素倍率、Surface源ROI/density及resident variants、job/lease/temp/disk账；收藏变化时才流式核SHA。它保留真实share注册实现并委托调用，不安装mock channel、不伪造结果。它还记录真实`didChangeAppLifecycleState`和`didHaveMemoryPressure` UTC事件；后者来自Flutter binding，工具从不主动调用该回调。

Android由主任务使用显式授权设备`8021129d`实际派发OS trim事件：

```powershell
adb -s 8021129d shell am send-trim-memory lingxue.picakeep RUNNING_CRITICAL
```

派发后需在日志实际观察`os-memory-pressure`，核当前页原源保护、内存收缩和重新达到需求，并实际前后台恢复。命令返回或有事件日志不能单独算压力恢复通过。进程RSS/PSS另用同PID/startTime的smaps预热稳定基线和十轮退出配对；此observer没有使用Dart currentRss替代OS指标。

### 关闭后的字节与DB核验

Windows正常关闭任务应用后，在项目根执行以下例子。文件名对应上文真实保存操作；报告是新文件，不会覆盖旧报告：

```powershell
python tools/image_pipeline_022_normal_ui_audit.py `
  --task-root E:/picakeep-image-pipeline-022-work/normal-ui-022-gui-final `
  --expect-export jpeg-save.jpg real-jpeg/1.jpg `
  --expect-export png-save.png real-workflow/chapter-1/2.png `
  --report docs/verification/image-pipeline-022/normal-ui-real-operations-byte-audit1006.json
```

脚本只读取合法标记任务内文件，拒绝链接祖先/逃逸路径；DB以SQLite只读immutable方式打开并显式关闭，若有非空WAL先拒绝，避免误读仍运行的持久化状态。它核所有固定来源SHA、指定保存输出SHA/真实格式、收藏文件SHA和sourceKey/id/page/url/sourceVersion，报告列明实际exports/favorites数量。同名作品未实际收藏时`sameBasenameIndependent`不会冒称通过。

脚本独立smoke使用本仓库临时task和真实匿名字节：正确保存/两同名收藏通过，故意换成另一PNG的导出失败，DB句柄释放；该smoke的UI/DB记录为测试fixture，不算实际用户操作。脚本`fullAcceptanceComplete`始终为false，`byteAuditPassed`仅证明本次读取和指定记录的字节/元数据；不证明全部正常UAT、真实raster像素、分享接收、权限恢复或性能。

诊断I/O会影响时间；正常UI target用于完整工作流证据，不拿它的每秒采样或SHA时间作N30速度结果。GUI服务控制只用同task的`support/picakeep_server.data`，应实际在设置/服务页启动和停止、核loopback状态，再用正常远端页面消费任务作品；旧headless十三HTTP和ServiceInfo组件按钮回归仍分别保留自己的边界。

本次最终harness SHA-256：入口`9a8965029488f1ee1ffc75a4f54f14a47ad4e4a92f4af057f8a4ee62a06d7c1c`；observer`19bff8f0088bdcb3534d61a5fd62348f2a7c6ab3a84202901dee84eab240a526`。上文430e78…旧入口哈希对应此前Windows smoke，不覆盖本次多页/observer快照。

## 手机续测边界

### 2026-10-06 Android v10 正常 UI 实机续测（更新状态）

本轮仅继续手机，Windows/Desktop按用户要求暂缓。已在备用机 `8021129d` 通过 `adb install -r` 安装并运行隔离UI profile APK：`D:/picakeep-image-pipeline-022-work/normal-ui-android-v10-profile1006.apk`，156,668,066字节，SHA-256 `2EDE7C83B4D3FC097F8E28F906FFBA2F85F79751A4E910752981D610993D73A2`；package `lingxue.picakeep`、version 9 / 1.9.92、签名与既有app相同。主力机未操作。

- 正常进入PicaKeep主界面、资源库与真实JPEG阅读器。点击“原始像素”后controller scale从适屏`0.3697997`变为`0.3636364`，诊断显示density=1且需求瓦片齐全。手机上的四角箭头是原始像素按钮；代码中的“全屏”按钮仍限Windows显示。
- 点击“保存图片”后，MediaStore新建 `content://media/external/images/media/2229`，位于`Pictures/PicaKeep`，格式JPEG、504,752字节、1062×1500。产品桥成功返回前会校验源与新URI的字节数和SHA相同；但Android shell UID无法读取URI，本次没有独立读回的SHA。该媒体项目保留。
- 点击“分享”打开真实MIUI分享面板，observer记录源JPEG为504,752字节、SHA `d5dec8bd5d19d8170b21a725c4b4e025751f1b22ed9ac6f62293c51e83aef690`，最终状态`dismissed`；点击取消，未选择接收方。
- 点击“收藏图片”后列表显示1条。退出阅读器后，observer记录持久收藏的作品/章/页/路径与SHA；同一task重启后收藏仍在，主界面计数仍为1。只读快照审计报告 [normal-ui-android-v10-byte-audit1006.json](normal-ui-android-v10-byte-audit1006.json)：`byteAuditPassed=true`、1条收藏、固定素材13份匹配，`fullAcceptanceComplete=false`。
- 屏幕截图与UI hierarchy在 `D:/picakeep-image-pipeline-022-work/normal-ui-android-v10-evidence/`，只读任务快照在 `D:/picakeep-image-pipeline-022-work/normal-ui-022-android-v10-1006-snapshot/`。手机任务数据及图库项目均保留。

验收后通过显式设备ID和`adb install -r`恢复Reader v9 profile包 `D:/picakeep-image-pipeline-022-work/reader-v9-continuation.apk`（SHA-256 `7BFDA9A61756CB51A21B7AA1BD4EACB8A866DDED6D5028AD2B1CB76E4E14DDF0`），未卸载或清除数据，测试进程已停止。当前正常UI只覆盖single/sharpFirst JPEG的一次阅读、保存、取消分享、收藏及重启持久化；PNG保存、其他布局/画质、性能N30、稳定OS warm基线、权限恢复和全回归仍未完成，022继续执行中。

以下此前的独立MediaStore桥记录仍有效；其测试项目`2228`与本次真实JPEG按钮生成的`2229`不同，均保留。

2026-10-06用户要求电脑端验证暂缓。当前手机仍安装Reader v9 benchmark profile入口，现有 `normal-profile1006-before-export-quota.apk` 是较早正常主入口产物，不包含这里最新隔离UI入口/observer，未安装该旧包来冒充正常UI验收。最新target仍需独立debug/profile构建、核验后仅安装到备用机 `8021129d`；为避免影响用户游戏，本轮没有再构建该入口。

同v9 Reader包的独立 `export` 组已实际调用Android MediaStore保存桥，固定合成PNG的源/返回URI产物均10237字节、SHA一致、源未变，报告 [reader-v9-original-export-redmi1006.json](reader-v9-original-export-redmi1006.json)，SHA `D3FD9D5CF31207E597B36DD662E25707B78305BC70D6DED87BA435181DD67286`。本次媒体项 `content://media/external/images/media/2228` 保留；哈希由应用桥读取自己返回URI核验。独立shell读回被Android权限拒绝，未获得图片字节。此证据不替代正常UI按钮调用、系统分享面板或持久收藏闭环。
